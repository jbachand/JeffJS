// VarBindingPushConformance.swift
// JeffJS — conformance groups found by the app's spec ladder on the wiki
// fixture (MediaWiki MobileFrontend's webpack runtime never started):
//
//   "VarBindings" (ES §14.3.2 VarDeclaredNames, §10.2.11
//   FunctionDeclarationInstantiation 27-28, B.3.4): a `var` is one
//   function-scoped binding per name. A `var` naming a parameter, an earlier
//   `var` or a function declaration was a fresh, undefined local
//   (`function f(o) { var o; return o }` returned undefined); a `var` in a
//   block was a second binding; `var` patterns and `for (var … in/of)` heads
//   at the top level of a script created no global.
//
//   "ArrayPushOverride" (ES §13.3.6 EvaluateCall): `arr.push(x)` must call
//   whatever `arr.push` is. The interpreter's push fast paths assumed
//   Array.prototype.push for every array — webpack's JSONP chunk array
//   (`o.push = callback`), subclasses, setPrototypeOf, a replaced
//   Array.prototype.push; and appended to non-extensible arrays or a
//   read-only `length` (those now take the builtin).
//
//   "PlainCallThis" (ES §13.3.6.1 EvaluateCall, §10.2.1.2): a call whose
//   callee is not a property reference gets `this` undefined (the global
//   object in a sloppy callee). The interpreter took `this` from a get_field
//   directly before any plain call, so `s(o.x)` ran `s` with `this` = `o`
//   (MediaWiki's loader: `script($, $, require, registry[m].module)`).
//
//   "ElementLangDir" (HTML §3.2.6.2 / §3.2.6.4): `lang` and `dir` reflect.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let varBindingCases: [(String, String)] = [
        ("var redeclaring a parameter is the parameter",
         "(function(o){ var o; return o; })(3) === 3"),
        ("var in a dead block keeps the argument",
         "(function(e, o){ if (0) { var o = 1; } return o; })(0, 5) === 5"),
        ("var pattern redeclaring parameters (webpack runtime)",
         "(function(e, o, n, s){ var seen = o; if (!o) { for (var [o, n, s] = [[1], 'N', 0], f = !0, l = 0; l < o.length; l++) ; } return seen; })(0, [569], 'cb')[0] === 569"),
        ("object pattern, rest and for-in/of heads bind the parameter",
         "(function(a, b, c, d){ var {a} = {a: 1}; var [...b] = [2]; for (var c in {k: 0}) ; for (var d of [4]) ; return a === 1 && b[0] === 2 && c === 'k' && d === 4 && arguments[0] === 1; })(9, 9, 9, 9)"),
        ("a closure over the parameter sees the var's store",
         "(function(o){ var g = function(){ return o; }; { var o = 7; } return g(); })(1) === 7"),
        ("a var in a block is the function's one binding",
         "(function(){ var x = 1; { var x = 2; } return x; })() === 2"),
        ("a block var closed over outlives the block",
         "(function(){ { var x = 1; var g = function(){ return x; }; } x = 2; return g(); })() === 2"),
        ("var in a catch block initialises the catch parameter (B.3.4)",
         "(function(){ try { throw 1; } catch (e) { var e = 2; var z = e; } return e === undefined && z === 2; })()"),
        ("var after a function declaration keeps the function",
         "(function(){ function g(){} var g; return typeof g; })() === 'function'"),
        ("strict, async and generator functions",
         "(function(x){ 'use strict'; var x; return x; })(4) === 4 && (function*(x){ var x; yield x; })(6).next().value === 6"),
        ("top-level var patterns and for-in/of heads are globals",
         "(0, eval)('var [__vbA] = [1]; var {__vbB} = {__vbB: 2}; for (var __vbC in {k: 0}) ; for (var [__vbD] of [[4]]) ; 0') === 0 && globalThis.__vbA === 1 && globalThis.__vbB === 2 && globalThis.__vbC === 'k' && globalThis.__vbD === 4"),
    ]

    static let arrayPushOverrideCases: [(String, String)] = [
        ("an own push on an array is called",
         "(function(){ var a = [], got; a.push = function(x){ got = x; return 'own'; }; var r = a.push(1); return r === 'own' && got === 1 && a.length === 0; })()"),
        ("an own push is called in a loop (fast paths)",
         "(function(){ var a = [], n = 0, x = 3; a.push = function(){ n++; }; for (var i = 0; i < 5; i++) { a.push(x); a.push(i); a.push(7); } return n === 15 && a.length === 0; })()"),
        ("a bound push (webpack JSONP chunk array)",
         "(function(){ var o = [], seen = []; var cb = function(parent, chunk){ seen.push(chunk); return parent(chunk); }; o.push = cb.bind(null, o.push.bind(o)); o.push([1]); o.push([2]); return seen.length === 2 && o.length === 2; })()"),
        ("a subclass push and a swapped prototype",
         "(function(){ class A extends Array { push(){ return 'sub'; } } var b = []; Object.setPrototypeOf(b, { push(){ return 'p'; } }); return new A().push(1) === 'sub' && b.push(1) === 'p'; })()"),
        ("a replaced Array.prototype.push is called, the original restored",
         "(function(){ var orig = Array.prototype.push, n = 0; Array.prototype.push = function(x){ n++; return orig.call(this, x); }; var a = []; for (var i = 0; i < 4; i++) a.push(i); Array.prototype.push = orig; a.push(9); return n === 4 && a.length === 5 && a[4] === 9; })()"),
        ("an own accessor push is called",
         "(function(){ var a = []; Object.defineProperty(a, 'push', { get(){ return function(){ return 'acc'; }; } }); return a.push(1) === 'acc'; })()"),
        ("deleting the own push restores the intrinsic",
         "(function(){ var a = []; a.push = function(){}; delete a.push; a.push(1); return a.length === 1 && a[0] === 1; })()"),
        ("plain push still appends",
         "(function(){ var a = [], x = 2; for (var i = 0; i < 100; i++) a.push(i); a.push(x); return a.length === 101 && a[100] === 2 && a[99] === 99; })()"),
    ]

    static let plainCallThisCases: [(String, String)] = [
        ("s(o.x) does not bind this to o",
         "(function(){ var o = {x: 1}, f = function(){ return this; }; var s = f, r1 = s(o.x), r2; r2 = f(1, o.x); var r3 = (function(){ return s(o['x']); })(); return r1 === globalThis && r2 === globalThis && r3 === globalThis; })()"),
        ("strict callee sees undefined",
         "(function(){ var o = {x: 1}, f = function(){ 'use strict'; return this; }; var r = f(o.x); var r5 = f(1, 2, 3, 4, o.x); return r === undefined && r5 === undefined; })()"),
        ("the loader pattern, hot",
         "(function(){ var reg = {}, bad = 0; for (var i = 0; i < 200; i++) reg['m' + i] = { module: {}, script: function(){ if (this !== globalThis) bad++; } }; function run(m){ var script = reg[m].script; try { script(1, 1, 2, reg[m].module); } catch (e) { bad += 1000; } } for (var j = 0; j < 200; j++) run('m' + j); return bad === 0; })()"),
        ("method calls keep their receiver",
         "(function(){ var o = {x: 1, m: function(){ return this; }}; var a = o.m(), b = (o.m)(), c = o.m(o.x), d = o['m'](), e = o.m(1, 2, o.x); return a === o && b === o && c === o && d === o && e === o; })()"),
    ]

    static let elementLangDirCases: [(String, String)] = [
        ("lang reflects the attribute, empty when absent",
         "(function(){ var d = document.createElement('div'); var r = d.lang === ''; d.setAttribute('lang', 'en-x-mtfrom-de'); r = r && d.lang === 'en-x-mtfrom-de'; d.lang = 'fr'; return r && d.getAttribute('lang') === 'fr' && typeof document.documentElement.lang === 'string'; })()"),
        ("dir is limited to known values, lowercase",
         "(function(){ var d = document.createElement('p'); var r = d.dir === ''; d.setAttribute('dir', 'RTL'); r = r && d.dir === 'rtl'; d.setAttribute('dir', 'sideways'); r = r && d.dir === ''; d.dir = 'Auto'; return r && d.getAttribute('dir') === 'Auto' && d.dir === 'auto'; })()"),
    ]

    mutating func testVarBindings() {
        runTrueCases("VarBindings", JeffJSTestRunner.varBindingCases)
    }

    mutating func testArrayPushOverride() {
        runTrueCases("ArrayPushOverride", JeffJSTestRunner.arrayPushOverrideCases)
    }

    mutating func testPlainCallThis() {
        runTrueCases("PlainCallThis", JeffJSTestRunner.plainCallThisCases)
    }

    mutating func testElementLangDir() {
        var outcomes: [(Bool, String)] = []
        let run = {
            MainActor.assumeIsolated {
                let env = JeffJSEnvironment(configuration: .init(baseURL: URL(string: "https://www.example.com/")!))
                for (name, js) in JeffJSTestRunner.elementLangDirCases {
                    switch env.eval(js, filename: "<element-lang-dir>") {
                    case .success(let value):
                        outcomes.append((value == "true", "ElementLangDir: \(name) -> \(value ?? "undefined")"))
                    case .exception(let message):
                        outcomes.append((false, "ElementLangDir: \(name) threw \(message)"))
                    }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
