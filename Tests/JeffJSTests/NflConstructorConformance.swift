// NflConstructorConformance.swift
// JeffJS — conformance group "NflConstructor" (nfl.com never hydrated:
// "TypeError: Object is not a constructor (evaluating 'new s')" in Next.js's
// core-js polyfill chunk). Three engine defects chained there:
//   1. `new WeakMap(iterable)` / `new WeakSet(iterable)` ignored the iterable,
//      so core-js judged the natives broken and wrapped them;
//   2. Map/Set/WeakMap/WeakSet/Date held one constructor reference in two
//      places (prototype.constructor + the global): core-js replaced both
//      and the native constructor its wrapper closed over was freed;
//   3. a delete / flag change on a private shape kept its identity, so an
//      inline cache still matched the gone slot (core-js deletes and
//      redefines String.prototype.replace: `"x".replace` read undefined).
// Plus RegExpExec: @@match/@@replace/@@search/@@split and test() call a
// page's own `exec` (core-js replaced all four String methods otherwise).
// Cases run with zombie mode on so an over-release is counted as a touch.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    private mutating func evalNflNoFreedTouches(_ ctx: JeffJSContext, _ label: String, _ code: String) {
        let savedZombies = jeffJSZombiesEnabled
        let savedDebug = jeffJS_refDebugMode
        let savedNoPool = jeffJSObjectPoolDisabled
        jeffJSZombiesEnabled = true
        jeffJS_refDebugMode = true
        jeffJSObjectPoolDisabled = true
        let before = JeffJSZombieDebug.touches
        evalCheckBool(ctx, code, expect: true)
        let touched = JeffJSZombieDebug.touches - before
        jeffJSZombiesEnabled = savedZombies
        jeffJS_refDebugMode = savedDebug
        jeffJSObjectPoolDisabled = savedNoPool
        assert(touched == 0, "\(label): \(touched) touch(es) on freed values")
    }

    mutating func testNflConstructor() {
        // Constructor ownership: each builtin is its own runtime (deleting a
        // global constructor must not disturb the other cases).
        for name in ["Map", "Set", "WeakMap", "WeakSet", "Date"] {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            evalNflNoFreedTouches(ctx, "\(name) survives its global and prototype.constructor being replaced", """
                var s = \(name), c = s.prototype;
                c.constructor = function Wrapper() {};
                delete globalThis.\(name);
                globalThis.\(name) = c.constructor;
                var o = new s();
                typeof s === 'function' && s.name === '\(name)' && Object.getPrototypeOf(o) === c
                """)
        }
        // The core-js collection wrapper, as nfl.com's polyfill chunk runs it
        // (own runtime: it replaces the global WeakMap).
        let wrt = JeffJSRuntime()
        evalNflNoFreedTouches(wrt.newContext(), "core-js collection wrapper keeps the native WeakMap", """
            (function () {
              var s = globalThis.WeakMap, c = s.prototype, f;
              f = function () { var r = new s(); return r; };
              f.prototype = c; c.constructor = f;
              delete globalThis.WeakMap;
              Object.defineProperty(globalThis, 'WeakMap', { value: f, writable: true, configurable: true });
              var k = {}, w = new WeakMap(); w.set(k, 1);
              return w.get(k) === 1 && w instanceof s;
            })()
            """)
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        // `prototype` attributes (ES §24.1.2.1 etc.)
        evalCheckBool(ctx, """
            ['Map', 'Set', 'WeakMap', 'WeakSet'].every(function (n) {
              var d = Object.getOwnPropertyDescriptor(globalThis[n], 'prototype');
              return d.writable === false && d.enumerable === false && d.configurable === false &&
                     globalThis[n].prototype.constructor === globalThis[n];
            })
            """, expect: true)
        // WeakMap / WeakSet iterables
        evalCheckBool(ctx, """
            var k1 = {}, k2 = {};
            var wm = new WeakMap([[k1, 1], [k2, 2]]), ws = new WeakSet([k1]);
            wm.get(k1) === 1 && wm.get(k2) === 2 && ws.has(k1) && !ws.has(k2)
            """, expect: true)
        evalCheckBool(ctx, """
            // core-js checkCorrectnessOfIteration
            var ok = false, o = {};
            o[Symbol.iterator] = function () { return { next: function () { return { done: ok = true }; } }; };
            new WeakMap(o); var a = ok; ok = false; new WeakSet(o);
            a && ok
            """, expect: true)
        evalCheckBool(ctx, """
            // AddEntriesFromIterable closes the iterator on an abrupt completion
            var closed = false, it = {}; var n = 0;
            it[Symbol.iterator] = function () { return { next: function () { return { done: false, value: 1 }; },
                                                         return: function () { closed = true; return {}; } }; };
            var threw = false; try { new WeakMap(it); } catch (e) { threw = e instanceof TypeError; }
            threw && closed
            """, expect: true)
        // Inline caches after a delete / redefinition on a private shape
        evalCheckBool(ctx, """
            function get(s) { return s.replace; }
            for (var i = 0; i < 5; i++) get("a");
            var origReplace = String.prototype.replace;
            delete String.prototype.replace;
            Object.defineProperty(String.prototype, 'replace', { value: function myReplace() { return 'mine'; },
                                  writable: true, configurable: true });
            var a = get("a") === String.prototype.replace && "x".replace() === 'mine';
            delete String.prototype.replace;
            Object.defineProperty(String.prototype, 'replace', { value: origReplace, writable: true, configurable: true });
            a = a && get("a") === origReplace;
            function getHolder(o) { return o.trim; }
            var so = new String("q");
            for (var j = 0; j < 5; j++) getHolder(so);
            var t = String.prototype.trim; delete String.prototype.trim; String.prototype.trim = function () { return 'T'; };
            var b = getHolder(so)() === 'T';
            String.prototype.trim = t;
            a && b
            """, expect: true)
        evalCheckBool(ctx, """
            // a private (dictionary) shape: cached own slot, then the property is deleted and re-added
            var d = {}; for (var i = 0; i < 80; i++) d['k' + i] = i;
            function rd(o) { return o.k40; }
            for (var j = 0; j < 5; j++) rd(d);
            delete d.k40; d.k40 = 'again';
            function wr(o, v) { o.k41 = v; }
            for (var j = 0; j < 5; j++) wr(d, j);
            Object.defineProperty(d, 'k41', { writable: false });
            wr(d, 'blocked');
            rd(d) === 'again' && d.k41 === 4
            """, expect: true)
        // RegExpExec
        evalCheckBool(ctx, """
            var calls = 0, names = ['match', 'replace', 'search', 'split'];
            var all = names.every(function (m) {
              var hit = false, r = /a/;
              if (m === 'split') { r = {}; r.constructor = {}; r.constructor[Symbol.species] = function () { return r; };
                                   r.flags = ''; r[Symbol.split] = /./[Symbol.split]; }
              r.exec = function () { hit = true; return null; };
              r[Symbol[m]]('');
              return hit;
            });
            var t = /./; t.exec = function () { var a = []; a.groups = { a: '7' }; return a; };
            var named = ''.replace(t, '$<a>') === '7';
            var bad = /x/; bad.exec = function () { return 1; };
            var typeErr = false; try { bad.test('x'); } catch (e) { typeErr = e instanceof TypeError; }
            all && named && typeErr && 'a-b-c'.replace(/-/g, '+') === 'a+b+c' &&
              JSON.stringify('a,b,,c'.split(/,*/)) === '["a","b","c"]' && 'abcb'.match(/b/g).length === 2
            """, expect: true)
    }
}

extension JeffJSTestRunner {
    /// Conformance group "UnicodeIdentifiers": IdentifierStartChar / IdentifierPartChar
    /// are Unicode ID_Start / ID_Continue (ES §12.7), not "is a letter" (cnn.com:
    /// `SyntaxError: Invalid character '℘'` on an inline script).
    mutating func testUnicodeIdentifiers() {
        let (_, ctx) = makeCtx()
        // Other_ID_Start: ℘ U+2118, ℮ U+212E, ゛ U+309B, ゜ U+309C; Nl: Ⅻ U+216B
        evalCheckBool(ctx, "var \u{2118} = 1, \u{212E}x = 2, \u{309B} = 3, \u{309C}y = 4, \u{216B} = 5; \u{2118} + \u{212E}x + \u{309B} + \u{309C}y + \u{216B} === 15", expect: true)
        // escaped forms
        evalCheckBool(ctx, "var \\u2118a = 6, \\u{212E}b = 7; \u{2118}a + \u{212E}b === 13", expect: true)
        // ID_Continue: combining marks (Mn U+0301, Mc U+0903), connector punctuation (Pc U+203F)
        evalCheckBool(ctx, "var e\u{0301} = 1, k\u{0903} = 2, a\u{203F}b = 3; e\u{0301} + k\u{0903} + a\u{203F}b === 6", expect: true)
        // still rejected: a math symbol that is not Other_ID_Start, and a combining mark as start
        evalCheckBool(ctx, "var bad = 0; try { eval('var \u{2200} = 1'); } catch (e) { bad += e instanceof SyntaxError ? 1 : 0; } try { eval('var \u{0301}x = 1'); } catch (e) { bad += e instanceof SyntaxError ? 1 : 0; } bad === 2", expect: true)
    }
}

extension JeffJSTestRunner {
    /// Conformance group "FoxnewsEngine": the arrow-parameter lookahead must stop on a
    /// token it cannot lex in its (wrong) goal — it spun forever on a regex after `)`
    /// (taboola's player on foxnews.com hung the page) — plus the Date
    /// behaviour foxnews and nfl read (the Intl ones are in IntlTests' environment).
    mutating func testFoxnewsEngine() {
        let (_, ctx) = makeCtx()
        evalCheckBool(ctx, "var e={a1:1,b:2},c=7,n=0; var r=(d=function(){for(var i in e)/\\d/.test(i)&&n++;return n},c); r === 7 && d() === 1", expect: true)
        evalCheckBool(ctx, "var q=(z=function(){if(1)/x\\/y/.test('x/y');return 2},3); q === 3 && z() === 2", expect: true)
        evalCheckBool(ctx, "var f=(a,b=(1,2))=>a+b; f(1) === 3", expect: true)
        evalCheckBool(ctx, "var ok=false; try { new Date(NaN).toISOString(); } catch (e) { ok = e instanceof RangeError; } ok", expect: true)
    }
}
