// LazyPayloadConformance.swift
// JeffJS — conformance group "LazyPayload" (perf/lazy-payload): a large
// `JSON.parse` result (≥ json.lazyThresholdBytes, 16 KB) and a large pure-data
// literal (≥ compile.lazyLiteralMinBytes) are lazy payloads built level by level
// as they are read (JeffJSLazyPayload.swift). Every case checks that the result is
// indistinguishable from an eager parse (ES §25.5.1 JSON.parse, §13.2.5 object
// initializers): key order, identity, writes before any read, reviver, stringify
// round trip, unicode escapes, numbers, duplicate keys, `__proto__` keys, malformed
// input, big arrays, inline caches, proxies, private fields, literals.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// Helpers prepended to every case: `bigText(n)` is ~45 bytes per item, so
    /// n ≥ 400 is past the 16 KB threshold.
    static let lazyPayloadPrelude = #"""
        function lpItems(n){ var a = []; for (var i = 0; i < n; i++) a.push({ id: i, name: "n" + i, tags: ["t" + (i % 3), i % 2 === 0], sub: { x: i * 1.5, y: null, z: "é" + i } }); return a; }
        function lpText(n){ return JSON.stringify({ items: lpItems(n), meta: { count: n, "2": "two", "1": "one", neg: -1 } }); }
        function lpEq(a, b){ return JSON.stringify(a) === JSON.stringify(b); }
        """#

    static let lazyPayloadCases: [(String, String)] = [
        ("the text is past the lazy threshold and round-trips through stringify",
         #"(function(){ var t = lpText(600); return t.length >= 16384 && JSON.stringify(JSON.parse(t)) === t; })()"#),
        ("own key order: integer keys ascending first, then insertion order (keys, for-in, ownKeys, names)",
         #"(function(){ var t = lpText(600); var o = JSON.parse(t); var m = o.meta; var fi = []; for (var k in JSON.parse(t).meta) fi.push(k); return Object.keys(m).join() === '1,2,count,neg' && fi.join() === '1,2,count,neg' && Reflect.ownKeys(JSON.parse(t).meta).join() === '1,2,count,neg' && Object.getOwnPropertyNames(JSON.parse(t).items[3]).join() === 'id,name,tags,sub' && Object.keys(o).join() === 'items,meta'; })()"#),
        ("identity: the same path is the same object; two parses are distinct",
         #"(function(){ var t = lpText(600); var o = JSON.parse(t), p = JSON.parse(t); return o.items === o.items && o.items[7] === o.items[7] && o.items[7].sub === o.items[7].sub && o.items[7].tags === o.items[7].tags && o.items !== p.items && o.items[7] !== p.items[7]; })()"#),
        ("Array.isArray, typeof and toString tags without reading",
         #"(function(){ var o = JSON.parse(lpText(600)); var a = JSON.parse('[' + lpText(600) + ']'); return Array.isArray(a) && !Array.isArray(o) && typeof o === 'object' && Object.prototype.toString.call(a) === '[object Array]' && Object.prototype.toString.call(o) === '[object Object]' && Object.getPrototypeOf(o) === Object.prototype && Object.getPrototypeOf(a) === Array.prototype && a instanceof Array; })()"#),
        ("writes before any read: set, delete, defineProperty, accessor",
         #"(function(){ var t = lpText(600); var o = JSON.parse(t); o.items[3].name = 'w'; delete o.items[4].sub; o.items[5].extra = 1; Object.defineProperty(o.items[6], 'id', { value: 'd', enumerable: false }); var o2 = JSON.parse(t); Object.defineProperty(o2.meta, 'g', { get: function(){ return this.count * 2; }, enumerable: true }); return o.items[3].name === 'w' && !('sub' in o.items[4]) && Object.keys(o.items[4]).join() === 'id,name,tags' && o.items[5].extra === 1 && Object.keys(o.items[5]).join() === 'id,name,tags,sub,extra' && o.items[6].id === 'd' && Object.keys(o.items[6]).join() === 'name,tags,sub' && o2.meta.g === 1200 && JSON.stringify(o2.meta) === '{"1":"one","2":"two","count":600,"neg":-1,"g":1200}'; })()"#),
        ("freeze / seal / preventExtensions / setPrototypeOf on unread objects",
         #"(function(){ var t = lpText(600); var o = JSON.parse(t); Object.freeze(o.items[1]); Object.seal(o.items[2]); Object.preventExtensions(o.meta); 'use strict'; o.items[1].name = 'x'; o.meta.zz = 1; var p = { inh: 9 }; Object.setPrototypeOf(o.items[3], p); return Object.isFrozen(o.items[1]) && o.items[1].name === 'n1' && Object.isSealed(o.items[2]) && !Object.isExtensible(o.meta) && o.meta.zz === undefined && o.items[3].inh === 9 && o.items[3].id === 3 && Object.getPrototypeOf(o.items[3]) === p && Object.isFrozen(JSON.parse(t)) === false; })()"#),
        ("in, hasOwnProperty, entries, values, spread, assign, structuredClone",
         #"(function(){ var t = lpText(600); var o = JSON.parse(t); var s = { ...JSON.parse(t).meta }; var a = Object.assign({}, JSON.parse(t).items[9]); var c = typeof structuredClone === 'function' ? structuredClone(JSON.parse(t).items[10]) : { id: 10, name: 'n10', tags: ['t1', true], sub: { x: 15, y: null, z: 'é10' } }; return ('meta' in o) && !('nope' in o) && o.items[0].hasOwnProperty('sub') && !o.items[0].hasOwnProperty('toString') && JSON.stringify(Object.entries(JSON.parse(t).meta)) === '[["1","one"],["2","two"],["count",600],["neg",-1]]' && Object.values(JSON.parse(t).items[2]).length === 4 && lpEq(s, { 1: 'one', 2: 'two', count: 600, neg: -1 }) && lpEq(a, lpItems(10)[9]) && lpEq(c, lpItems(11)[10]); })()"#),
        ("reviver takes the eager path and sees every holder",
         #"(function(){ var t = lpText(600); var seen = 0; var r = JSON.parse(t, function(k, v){ seen++; return typeof v === 'number' ? v + 1 : v; }); return r.items[5].id === 6 && r.meta.count === 601 && seen > 600 * 8; })()"#),
        ("unicode escapes, surrogate pairs, lone surrogates and escaped keys",
         #"(function(){ var pad = new Array(5000).join('\"x\",'); var t = '[' + pad + '"\\u00e9\\ud83d\\ude00\\n\\t\\"\\\\\\/", "\\ud800", {"k\\u0065y": "\\u0041", "é€": "😀"}]'; var a = JSON.parse(t); var n = a.length; var o = a[n - 1]; return t.length > 16384 && a[n - 3] === 'é😀\n\t"\\/' && a[n - 3].length === 8 && a[n - 2] === '\ud800' && a[n - 2].length === 1 && o.key === 'A' && o['é€'] === '😀' && Object.keys(o).join() === 'key,é€'; })()"#),
        ("numbers: -0, exponents, Infinity, big integers, fractions",
         #"(function(){ var pad = new Array(3000).join('0,'); var a = JSON.parse('[' + pad + '-0, 0, -1, 1e400, -1e400, 12345678901234567890, 2147483647, 2147483648, -2147483648, -2147483649, 1.5e-7, 0.1, 1E5, -0.0]'); var n = a.length; return Object.is(a[n - 14], -0) && Object.is(a[n - 13], 0) && a[n - 12] === -1 && a[n - 11] === Infinity && a[n - 10] === -Infinity && a[n - 9] === 12345678901234567890 && a[n - 8] === 2147483647 && a[n - 7] === 2147483648 && a[n - 6] === -2147483648 && a[n - 5] === -2147483649 && a[n - 4] === 1.5e-7 && a[n - 3] === 0.1 && a[n - 2] === 100000 && Object.is(a[n - 1], -0) && String(a[n - 4]) === '1.5e-7'; })()"#),
        ("duplicate keys: last value, first position",
         #"(function(){ var t = lpText(600); var u = '{"a":1,"b":{"x":1},"a":2,"c":3,"b":{"y":2},' + t.slice(1); var o = JSON.parse(u); return Object.keys(o).join() === 'a,b,c,items,meta' && o.a === 2 && JSON.stringify(o.b) === '{"y":2}'; })()"#),
        ("a __proto__ key is an own property (eager path)",
         #"(function(){ var t = lpText(600); var o = JSON.parse('{"__proto__":{"x":1},' + t.slice(1)); return Object.getPrototypeOf(o) === Object.prototype && Object.keys(o)[0] === '__proto__' && o.x === undefined && o.__proto__.x === 1 && JSON.parse('{"__proto__":[]}').__proto__.length === 0; })()"#),
        ("malformed large input throws SyntaxError",
         #"(function(){ var t = lpText(600); var bad = [t.slice(0, -1), t + ',', t.slice(0, -2) + ',}}', t.replace('"n1"', '"n1\u0001"'), t.replace('"n2"', '"\\q"'), t.replace('"id":5,', '"id":05,'), t.replace('"id":6,', '"id":6.,'), '[' + t + ',]', t + ' x', t.replace('null', 'nul')]; return bad.every(function(b){ try { JSON.parse(b); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"#),
        ("big arrays: length, index, holes absent, mutation, sort, builtins",
         #"(function(){ var src = []; for (var i = 0; i < 50000; i++) src.push(i % 97); var a = JSON.parse(JSON.stringify(src)); var b = JSON.parse(JSON.stringify(src)); var c = JSON.parse(JSON.stringify(src)); var s = 0; for (var i = 0; i < a.length; i++) s += a[i]; b.push(5); b.length = 3; return a.length === 50000 && a[49999] === src[49999] && a[50000] === undefined && !(50000 in a) && (49999 in a) && s === src.reduce(function(x, y){ return x + y; }, 0) && b.length === 3 && b.join() === '0,1,2' && c.slice().sort(function(x, y){ return y - x; })[0] === 96 && c.indexOf(96) === 96 && c.includes(50) && [...JSON.parse('[' + JSON.stringify(src).slice(1, -1) + ']')].length === 50000 && Array.from(c).length === 50000 && c.map(function(v){ return v * 2; })[3] === 6; })()"#),
        ("inline caches: shared shapes with eager objects, own keys shadowing prototype methods",
         #"(function(){ function rd(o){ return o.name; } function ts(o){ return o.toString; } var e = { id: 0, name: 'e', tags: [], sub: {} }; rd(e); rd(e); ts({}); ts({}); var o = JSON.parse(lpText(600)); var ok = true; for (var i = 0; i < 600; i++) ok = ok && rd(o.items[i]) === 'n' + i; var p = JSON.parse('{"toString":"own",' + lpText(600).slice(1)); var q = JSON.parse('{"hasOwnProperty":1,' + lpText(600).slice(1)); return ok && ts(p) === 'own' && ts(p) === 'own' && typeof ts(o) === 'function' && q.hasOwnProperty === 1; })()"#),
        ("proxies and Reflect over unread objects",
         #"(function(){ var o = JSON.parse(lpText(600)); var px = new Proxy(o.meta, {}); var log = []; var px2 = new Proxy(JSON.parse(lpText(600)).items[1], { get: function(t, k){ log.push(k); return t[k]; } }); return Object.keys(px).join() === '1,2,count,neg' && px.count === 600 && Reflect.has(o.items[2], 'sub') && Reflect.get(o.items[3], 'id') === 3 && px2.name === 'n1' && log[0] === 'name' && Reflect.ownKeys(JSON.parse(lpText(600)).meta).join() === '1,2,count,neg'; })()"#),
        ("Object.create over an unread object and private fields added by return override",
         #"(function(){ var o = JSON.parse(lpText(600)); var c = Object.create(o.items[4]); class B { constructor(x){ return x; } } class C extends B { #p = 7; static has(x){ return #p in x; } static get(x){ return x.#p; } } var t = JSON.parse(lpText(600)).items[5]; new C(t); return c.name === 'n4' && Object.keys(c).length === 0 && C.has(t) && C.get(t) === 7 && Object.keys(t).join() === 'id,name,tags,sub' && JSON.stringify(t) === JSON.stringify(lpItems(6)[5]); })()"#),
        ("stringify with replacer and indent; toJSON on the prototype",
         #"(function(){ var t = lpText(600); var o = JSON.parse(t); var s1 = JSON.stringify(o.items[1], ['id', 'sub', 'x'], 2); var s2 = JSON.stringify(o.meta, null, '\t'); Object.prototype.toJSON = function(){ return 'J'; }; try { var s3 = JSON.stringify(JSON.parse(t).items[2]); } finally { delete Object.prototype.toJSON; } return s1 === '{\n  "id": 1,\n  "sub": {\n    "x": 1.5\n  }\n}' && s2 === JSON.stringify(JSON.parse(JSON.stringify(o.meta)), null, '\t') && s3 === '"J"'; })()"#),
        ("a large literal in source equals the parsed object; each evaluation is a fresh object",
         #"(function(){ var t = lpText(600); var f = new Function('return ' + t + ';'); var a = f(), b = f(); var c = eval('(' + t + ')'); return lpEq(a, JSON.parse(t)) && lpEq(c, a) && a !== b && a.items !== b.items && a.items[3] === a.items[3] && Object.keys(a.meta).join() === '1,2,count,neg'; })()"#),
        ("literal corners: duplicate keys, -0, unicode, writes, destructuring assignment untouched",
         #"(function(){ var t = lpText(600); var a = eval('({"a":1,"z":-0,"s":"\\u00e9\\ud83d\\ude00","a":2,' + t.slice(1) + ')'); var x, y; eval('[x, y] = [' + t + ', 2]'); a.items[0].name = 'w'; return Object.keys(a).slice(0, 3).join() === 'a,z,s' && a.a === 2 && Object.is(a.z, -0) && a.s === 'é😀' && a.items[0].name === 'w' && x.items.length === 600 && y === 2; })()"#),
        ("a literal with a __proto__ key still sets the prototype (eager compile)",
         #"(function(){ var t = lpText(600); var p = eval('({"__proto__": {"inh": 5}, ' + t.slice(1) + ')'); return p.inh === 5 && Object.keys(p).join() === 'items,meta'; })()"#),
    ]

    mutating func testLazyPayload() {
        let prelude = JeffJSTestRunner.lazyPayloadPrelude
        runTrueCases("LazyPayload", JeffJSTestRunner.lazyPayloadCases.map { ($0.0, prelude + "\n" + $0.1) })
    }
}
