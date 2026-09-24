// IndexArgumentConformance.swift
// JeffJS — "IndexArguments": builtins that turn a JS number into an index,
// count, offset or length.
//
// ToIntegerOrInfinity hands builtins NaN (→ 0), ±Infinity and huge finite
// values; the spec clamps them (relative index → [0, len], counts → [0, …]),
// or throws a RangeError (lengths, repeat counts). JeffJS converted them with
// `Int64(d)` / `Int(d)` / `Int32(d)` / `UInt32(k)`, which trap on exactly those
// values: homedepot.com called `arr.splice(i, Infinity)` through
// `Function.prototype.apply` and the app died with EXC_BREAKPOINT ("Double
// value cannot be converted to Int64 because it is either infinite or NaN").
// Same class: String repeat/lastIndexOf, Date.UTC/setFullYear with huge years,
// JSON.stringify's `space`, TypedArray/ArrayBuffer/DataView arguments, RegExp
// `lastIndex`, bound-function `length`, `apply` on huge array-likes, Intl
// digit options, timers, array-like indices past 2^32, and array `length`
// updates. Also: `accessor` was tokenized as a keyword (`{accessor: 1}` and
// `o.accessor` were SyntaxErrors; lowes.com's vendor bundles failed to parse).
//
// Every case is (name, JS expression that must evaluate to `true`); qjs agrees.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let indexArgumentCases: [(String, String)] = [
        ("splice(start, Infinity) deletes to the end",
         "JSON.stringify([1,2,3].splice(0, Infinity)) === '[1,2,3]' && JSON.stringify([1,2,3].splice(1, Infinity)) === '[2,3]'"),
        ("splice(Infinity) / splice(-Infinity, n) / splice(i, -1e20)",
         "JSON.stringify([1,2,3].splice(Infinity)) === '[]' && JSON.stringify([1,2,3].splice(-Infinity, 1)) === '[1]' && JSON.stringify([1,2,3].splice(1, -1e20)) === '[]' && JSON.stringify([1,2,3].splice(NaN, NaN)) === '[]'"),
        ("splice through Function.prototype.apply (homedepot)",
         "(function(){ var a = [1,2,3,4]; var r = Array.prototype.splice.apply(a, [1, Infinity]); return JSON.stringify(r) === '[2,3,4]' && a.length === 1; })()"),
        ("toSpliced clamps",
         "[1,2,3].toSpliced(-Infinity, Infinity).length === 0 && [1,2,3].toSpliced(Infinity, 1).length === 3"),
        ("slice / fill / copyWithin clamp",
         "JSON.stringify([1,2,3].slice(-Infinity, NaN)) === '[]' && JSON.stringify([1,2,3].slice(1e20)) === '[]' && JSON.stringify([1,2,3].slice(-1e20, 1e20)) === '[1,2,3]' && JSON.stringify([0,0,0].fill(1, -1e20, 1e20)) === '[1,1,1]' && JSON.stringify([1,2,3].copyWithin(Infinity, -Infinity)) === '[1,2,3]'"),
        ("indexOf / lastIndexOf / includes fromIndex",
         "[1,2,3].indexOf(1, -Infinity) === 0 && [1,2,3].indexOf(1, 1e20) === -1 && [1,2,3].lastIndexOf(3, -1e20) === -1 && [1,2,3].lastIndexOf(3, Infinity) === 2 && [1,2,3].includes(3, 1e20) === false && [1,2,3].includes(1, -Infinity) === true"),
        ("at / with / flat depth",
         "[1].at(-Infinity) === undefined && [1].at(1e20) === undefined && JSON.stringify([[1,[2]]].flat(Infinity)) === '[1,2]' && (function(){ try { [1].with(1e20, 0); return false; } catch (e) { return e instanceof RangeError; } })()"),
        ("array-likes past 2^32",
         "(function(){ var e = Array.prototype.slice.call({ length: 2**32 + 2, 4294967296: 'x', 4294967297: 'y' }, -2); return e.length === 2 && e[0] === 'x' && e[1] === 'y' && Array.prototype.at.call({ length: Infinity }, -1) === undefined && Array.prototype.lastIndexOf.call({ length: 1e20 }, 1, -1e20) === -1; })()"),
        ("array length: element writes never shrink it; index 2^31",
         "(function(){ var c = new Array(10); c[0] = 1; var b = []; b.length = 10; b[0] = 1; var d = []; d[2**31] = 5; return c.length === 10 && b.length === 10 && d.length === 2**31 + 1 && d[2**31] === 5 && d[0] === undefined; })()"),
        ("String lastIndexOf / substring / repeat",
         "'abc'.substring(NaN, Infinity) === 'abc' && 'aba'.lastIndexOf('a', -Infinity) === 0 && 'aba'.lastIndexOf('a', 1e20) === 2 && 'aba'.lastIndexOf('a', NaN) === 2 && (function(){ try { 'ab'.repeat(1e20); return false; } catch (e) { return e instanceof RangeError; } })() && (function(){ try { 'ab'.repeat(Infinity); return false; } catch (e) { return e instanceof RangeError; } })() && 'ab'.repeat(2) === 'abab'"),
        ("repeat runs valueOf once",
         "(function(){ var n = 0; var r = 'x'.repeat({ valueOf: function(){ n++; return 2; } }); return r === 'xx' && n === 1; })()"),
        ("JSON.stringify space: Infinity, NaN, -Infinity, 1e20",
         "JSON.stringify([1], null, Infinity) === '[\\n          1\\n]' && JSON.stringify([1], null, NaN) === '[1]' && JSON.stringify([1], null, -Infinity) === '[1]' && JSON.stringify([1], null, 1e20) === '[\\n          1\\n]'"),
        ("Date with huge years is NaN",
         "isNaN(Date.UTC(1e20)) && isNaN(new Date(0).setFullYear(1e20)) && isNaN(new Date(0).setUTCFullYear(-1e20)) && isNaN(new Date(1e20, 0).getTime()) && Date.UTC(2020, 0) === 1577836800000"),
        ("TypedArray subarray / slice / at / indexOf / lastIndexOf",
         "(function(){ var u = new Uint8Array([1,2,3,4]); return u.subarray(0, Infinity).length === 4 && u.subarray(1e20).length === 0 && u.slice(-Infinity).length === 4 && u.at(-1e20) === undefined && u.indexOf(1, 1e20) === -1 && u.lastIndexOf(4, Infinity) === 3 && u.includes(4, 1e20) === false; })()"),
        ("TypedArray fill(v, 3, 1) and copyWithin with an empty range return the array",
         "(function(){ var u = new Uint8Array([1,2,3,4]); var a = u.fill(9, 3, 1), b = u.copyWithin(1e20, -1e20); for (var i = 0; i < 1000; i++) u.copyWithin(4, 0); return a === u && b === u && Array.from(u).join() === '1,2,3,4'; })()"),
        ("ArrayBuffer / TypedArray lengths out of range are RangeErrors",
         "(function(){ function re(f){ try { f(); return false; } catch (e) { return e instanceof RangeError; } } return re(function(){ new ArrayBuffer(Infinity); }) && re(function(){ new ArrayBuffer(2**53); }) && re(function(){ new Uint8Array(1e20); }) && re(function(){ new Float64Array(2**31); }) && re(function(){ new ArrayBuffer(8).transfer(1e20); }) && new ArrayBuffer(8).slice(-Infinity, Infinity).byteLength === 8 && new ArrayBuffer(8).slice(1e20).byteLength === 0; })()"),
        ("DataView setters: ToInt32 / ToUint32 of NaN, Infinity, huge",
         "(function(){ var d = new DataView(new ArrayBuffer(8)); d.setInt32(0, NaN); d.setUint32(4, -(2**32)); d.setInt8(0, Infinity); d.setUint16(2, 1e20); var ok = d.getInt32(0) === 0 && d.getUint32(4) === 0; d.setInt32(0, 2**32 + 5); return ok && d.getInt32(0) === 5; })()"),
        ("DataView offsets out of range throw instead of trapping",
         "(function(){ var d = new DataView(new ArrayBuffer(8)); var n = 0; [Infinity, 1e20, 2**53].forEach(function(o){ try { d.getInt8(o); } catch (e) { n++; } }); return n === 3; })()"),
        ("RegExp lastIndex Infinity / 1e20 / -1e20",
         "(function(){ var r = /a/g; r.lastIndex = Infinity; var a = r.exec('aaa'); var r2 = /a/g; r2.lastIndex = 1e20; var t = r2.test('aaa'); var r3 = /a/y; r3.lastIndex = -1e20; var y = r3.test('aaa'); var r4 = /a/g; r4.lastIndex = 1e20; var n = 0; for (var m of 'aaa'.matchAll(r4)) n++; return a === null && r.lastIndex === 0 && t === false && y === true && n === 0; })()"),
        ("bound function length from Infinity / 1e20 / 2^53 / NaN",
         "(function(){ function L(v){ return Object.defineProperty(function(){}, 'length', { value: v }); } return L(Infinity).bind().length === Infinity && L(1e20).bind(null, 1).length === 1e20 - 1 && L(2**53).bind(null, 1).length === 2**53 - 1 && L(NaN).bind(null, 1).length === 0 && L(-Infinity).bind().length === 0; })()"),
        ("apply on a huge array-like is a RangeError, small ones work",
         "(function(){ var ok = false; try { Math.max.apply(null, { length: 2**32 + 1 }); } catch (e) { ok = e instanceof RangeError; } return ok && Math.max.apply(null, { length: 2, 0: 3, 1: 7 }) === 7; })()"),
        ("numeric literal keys use Number::toString (object, class, destructuring)",
         "(function(){ var q = { 1e21: 1, 4294967296: 2, 1.5: 3 }; var { 0: x, 1.5: y } = { 0: 'a', '1.5': 'b' }; class C { 1.5(){ return 'm'; } 4294967296(){ return 'n'; } } return Object.keys(q).join() === '1e+21,4294967296,1.5' && x === 'a' && y === 'b' && new C()['1.5']() === 'm' && new C()['4294967296']() === 'n'; })()"),
        ("optional calls accept spread arguments",
         "(function(){ var a = [1, 2], e = null, f = function(){ return arguments.length; }, o = { v: 10, m: function(x, y, z){ return this.v + x + y + z; } }, n = { b: { c: function(){ return [].slice.call(arguments).join(); } } }; return e?.(...a) === undefined && f?.(...a) === 2 && o.m?.(...a, 3) === 16 && f?.() === 0 && n?.b?.c?.(...a, 3) === '1,2,3' && n.x?.y?.(...a) === undefined && Math.max?.(...a, 5) === 5; })()"),
        ("'accessor' is an identifier and a property name",
         "(function(){ var o = { accessor: 1 }; class A { static accessor(e){ return e; } accessor(){ return 2; } } var accessor = 3; return o.accessor === 1 && A.accessor(4) === 4 && new A().accessor() === 2 && accessor === 3; })()"),
    ]

    mutating func testIndexArguments() {
        runTrueCases("IndexArguments", JeffJSTestRunner.indexArgumentCases)
    }
}
