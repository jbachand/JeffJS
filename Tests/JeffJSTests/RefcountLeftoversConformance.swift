// RefcountLeftoversConformance.swift
// JeffJS — conformance group "RefcountLeftovers" (2026-10-07): the refcount and
// semantics hazards the EngineMisc fixer left.
//
// 1. `define_func` never released the closure it popped (every global function
//    declaration kept one count too many). The lazy prototype's `constructor` slot
//    is counted (materializeFunctionPrototype dups), so there was no hidden
//    use-after-free behind it; the stale "uncounted" comment is gone.
// 2. Error / NativeError / AggregateError: `message`, `cause` and `errors` kept one
//    count too many (definePropertyValue dups what the constructor already owned).
// 3. Strings a fresh runtime never gave back: the atom / typeof / int-key string
//    caches, symbol values in freed objects, primitive wrappers, toPropertyKey's
//    keys, tag strings, nested function bodies whose closures died first.
// 4. `makeObject` / `mkPtr` Swift retains never given back (array iterators run to
//    the end, Reflect.getPrototypeOf, deleted accessors, error stacks/messages,
//    promise settlements).
// 5. Semantics: CreateGlobalVarBinding / CreateGlobalFunctionBinding attributes
//    (ES §9.1.1.4.17-18), sloppy PutValue on a read-only global (`var NaN = 5`),
//    and a Proxy on an ordinary object's prototype chain ([[Get]], [[Set]],
//    [[HasProperty]] with the original receiver).
// Expected values are JavaScriptCore's (`jsc`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testRefcountLeftovers() {
        let (_, ctx) = makeCtx()
        func ev(_ js: String) -> JeffJSValue { ctx.eval(input: js, filename: "<RefcountLeftovers>", evalFlags: JS_EVAL_TYPE_GLOBAL) }
        func rc(_ v: JeffJSValue) -> Int {
            if let o = v.toObject() { return Int(o.refCount) }
            if let s = v.stringBase { return Int(s.refCount) }
            if v.isSymbol, let s = v.toPtr() as? JeffJSString { return Int(s.refCount) }
            return -1
        }

        // --- 1. a global function declaration: the global's count only ---
        let f = ev("function __rlF() {} __rlF")
        assert(rc(f) == 2, "RefcountLeftovers: a declared function is held by the global (+ ours), rc \(rc(f))")
        ev("__rlF.prototype").freeValue()
        assert(rc(f) == 3, "RefcountLeftovers: + its prototype's counted constructor slot, rc \(rc(f))")
        f.freeValue()

        // --- 2. Error members ---
        let cause = ev("var __rlC = {}; __rlC")
        let causeRc = rc(cause)
        ev("new Error('x', { cause: __rlC })").freeValue()
        ev("new RangeError('x', { cause: __rlC })").freeValue()
        assert(rc(cause) == causeRc, "RefcountLeftovers: a dropped error gives its cause back (\(causeRc) -> \(rc(cause)))")
        let held = ev("var __rlE = new Error('x', { cause: __rlC }); __rlC")
        assert(rc(held) == causeRc + 2, "RefcountLeftovers: a live error holds its cause once (\(causeRc) -> \(rc(held)))")
        held.freeValue(); cause.freeValue()
        let msg = ev("var __rlM = new Error('msg-' + 1); __rlM.message")
        assert(rc(msg) == 2, "RefcountLeftovers: an error holds its message once, rc \(rc(msg))")
        msg.freeValue()
        let errs = ev("var __rlA = new AggregateError([1], 'm'); __rlA.errors")
        assert(rc(errs) == 2, "RefcountLeftovers: an AggregateError holds its errors array once, rc \(rc(errs))")
        errs.freeValue()

        // --- 3. strings and symbols ---
        let key = ev("var __rlK = 'qq' + 'zz'; __rlK")
        let keyRc = rc(key)
        ev("Object.getOwnPropertyDescriptor({ qqzz: 1 }, __rlK); Object.hasOwn({}, __rlK); ({}).hasOwnProperty(__rlK); Reflect.getOwnPropertyDescriptor({}, __rlK)").freeValue()
        assert(rc(key) == keyRc, "RefcountLeftovers: property-key conversions give the key back (\(keyRc) -> \(rc(key)))")
        key.freeValue()
        let tag = ev("Promise.prototype[Symbol.toStringTag]")
        let tagRc = rc(tag)
        ev("Object.prototype.toString.call(Promise.prototype)").freeValue()
        assert(rc(tag) == tagRc, "RefcountLeftovers: Object.prototype.toString gives the tag back (\(tagRc) -> \(rc(tag)))")
        tag.freeValue()
        let sym = ev("var __rlS = Symbol('s'); var __rlSO = { k: __rlS }; __rlS")
        let symRc = rc(sym)
        ev("__rlSO = null").freeValue()
        assert(rc(sym) == symRc - 1, "RefcountLeftovers: a freed object releases the symbol it held (\(symRc) -> \(rc(sym)))")
        sym.freeValue()
        let prim = ev("var __rlP = 'abc' + 1; __rlP")
        let primRc = rc(prim)
        ev("new String(__rlP); Object(__rlP); String.prototype.__rlSelf = function () { return this; }; __rlP.__rlSelf(); 1").freeValue()
        assert(rc(prim) == primRc, "RefcountLeftovers: a dropped wrapper gives its primitive back (\(primRc) -> \(rc(prim)))")
        prim.freeValue()
        let flags = ev("var __rlRe = /a/g; __rlRe")
        let reRc = rc(flags)
        ev("'aa'.replaceAll(__rlRe, 'b'); [...'aa'.matchAll(__rlRe)].length").freeValue()
        assert(rc(flags) == reRc, "RefcountLeftovers: matchAll / replaceAll give the regexp back (\(reRc) -> \(rc(flags)))")
        flags.freeValue()

        // --- 5. semantics (JS checks, each must answer true) ---
        let r = ev(#"""
            eval("var __rlDV = 1; function __rlDF() {}");   // a direct eval in global code
            (function () {
            var R = [];
            function check(name, f) { var r; try { r = f(); } catch (e) { r = "threw " + e; } if (r !== true) R.push(name + " -> " + r); }
            function d(n) { var x = Object.getOwnPropertyDescriptor(globalThis, n); return x ? [x.writable, x.enumerable, x.configurable].join("/") : "none"; }
            check("script var: { writable, enumerable, non-configurable }", function () {
              (0, eval)("1"); return d("__rlE") === "true/true/false" && d("__rlC") === "true/true/false";
            });
            check("script function: { writable, enumerable, non-configurable }", function () { return d("__rlF") === "true/true/false"; });
            check("indirect eval var / function: configurable", function () {
              (0, eval)("var __rlIV = 1; function __rlIF() {}"); return d("__rlIV") === "true/true/true" && d("__rlIF") === "true/true/true";
            });
            check("direct eval at global level: configurable", function () {
              return d("__rlDV") === "true/true/true" && d("__rlDF") === "true/true/true";
            });
            check("delete of a script var fails, of an eval var succeeds", function () {
              return (delete globalThis.__rlE) === false && typeof __rlE === "object" && (delete globalThis.__rlIV) === true && d("__rlIV") === "none";
            });
            check("script vars and functions enumerate", function () {
              var seen = []; for (var k in globalThis) { if (k === "__rlE" || k === "__rlF") seen.push(k); } return seen.sort().join() === "__rlE,__rlF" && Object.keys(globalThis).indexOf("__rlC") >= 0;
            });
            check("sloppy var NaN / undefined / Infinity = x is silently ignored", function () {
              return (0, eval)("var NaN = 5; var undefined = 3; var Infinity = 1; NaN !== NaN && typeof undefined === 'undefined' && Infinity === 1 / 0");
            });
            check("sloppy assignment to a read-only global is ignored, strict throws", function () {
              Object.defineProperty(globalThis, "__rlRO", { value: 1, writable: false, configurable: true });
              (0, eval)("__rlRO = 2");
              var threw = false; try { (0, eval)("'use strict'; __rlRO = 2"); } catch (e) { threw = e instanceof TypeError; }
              var threw2 = false; try { (function () { "use strict"; NaN = 1; })(); } catch (e) { threw2 = e instanceof TypeError; }
              return __rlRO === 1 && threw && threw2;
            });
            check("Object.create(proxy).x = 1 reaches the set trap with the original receiver", function () {
              var log = []; var child;
              var p = new Proxy({}, { set: function (t, k, v, r) { log.push(k + "=" + v + ":" + (r === child)); return true; } });
              child = Object.create(p); child.x = 1;
              var grand = Object.create(child); grand.y = 2;
              return log.join() === "x=1:true,y=2:false" && !child.hasOwnProperty("x") && !grand.hasOwnProperty("y");
            });
            check("a proxy prototype without a set trap: OrdinarySet defines on the receiver", function () {
              var t = { a: 1 }; var c = Object.create(new Proxy(t, {})); c.a = 2; c.b = 3;
              return t.a === 1 && c.a === 2 && c.hasOwnProperty("a") && c.hasOwnProperty("b") && !t.hasOwnProperty("b");
            });
            check("a proxy prototype's setter runs with this = receiver", function () {
              var seen; var c = Object.create(new Proxy({ set q(v) { seen = this; } }, {})); c.q = 1; return seen === c;
            });
            check("a refusing set trap: false in sloppy code, TypeError in strict", function () {
              var c = Object.create(new Proxy({}, { set: function () { return false; } })); c.z = 1;
              var threw = false; try { (function () { "use strict"; c.z = 1; })(); } catch (e) { threw = e instanceof TypeError; }
              return !c.hasOwnProperty("z") && threw;
            });
            check("[[Get]] / [[HasProperty]] through a proxy prototype", function () {
              var c = Object.create(new Proxy({ a: 1 }, {}));
              var c2; var p2 = new Proxy({}, { get: function (t, k, r) { return k === "z" ? r === c2 : undefined; }, has: function (t, k) { return k === "h"; } });
              c2 = Object.create(p2);
              return c.a === 1 && typeof c.hasOwnProperty === "function" && "a" in c && c2.z === true && "h" in c2 && !("a" in c2) &&
                     typeof Object.create(new Proxy([], {})).push === "function";
            });
            check("Error cause / AggregateError", function () {
              var o = {}; var e = new Error("x", { cause: o }); var d = Object.getOwnPropertyDescriptor(e, "cause");
              return e.cause === o && d.enumerable === false && d.writable && d.configurable && new AggregateError([1, 2], "m", { cause: 7 }).cause === 7 &&
                     !("cause" in new Error("x", {})) && new Error("x", { get cause() { return 9; } }).cause === 9;
            });
            check("indirect eval frames are eval code", function () {
              return typeof (0, eval)("(function () { return 1; })") === "function";
            });
            return R.length ? R.join(" | ") : true;
            })()
            """#)
        if r.isException {
            let exc = ctx.getException()
            assert(false, "RefcountLeftovers: threw \(ctx.toSwiftString(exc) ?? "?")")
            exc.freeValue()
        } else {
            assert(r.isBool && r.toBool(), "RefcountLeftovers: \(ctx.toSwiftString(r) ?? "?")")
        }
        r.freeValue()
    }
}
