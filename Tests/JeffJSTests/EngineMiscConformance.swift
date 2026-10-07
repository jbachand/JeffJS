// EngineMiscConformance.swift
// JeffJS — conformance group "EngineMisc" (2026-10-07). Four engine bugs and one spec gap:
//
// 1. RegExp `lastIndex` (ES §22.2.7.2): the builtins wrote slot 0 directly — the replaced
//    value was never released, a read-only `lastIndex` was overwritten instead of throwing,
//    and a non-number `lastIndex` read as 0 (no ToLength / valueOf). `setOwnPropertyValue`
//    (the native slot writer) also dropped the value it replaced.
// 2. Proxy [[Set]] without a `set` trap (ES §10.5.9 step 6): `target.[[Set]](P, V, Receiver)`.
//    It was a plain write on the target: a setter on the target's chain ran with `this` =
//    target, the proxy's getOwnPropertyDescriptor / defineProperty traps never ran.
// 3. The predefined atom table had nine names twice ("set", "of", "with", ...): the enum
//    named one id, `findAtom` (everything JS interns) answered the other.
// 4. Date's installer took four Swift retains on the constructor (one is ever given back);
//    the getter / setter calls took one per call: those functions outlived every runtime.
// 5. GlobalDeclarationInstantiation (ES §16.1.7): a global function declaration over a
//    non-configurable property replaced it outright; now value-only, or a TypeError.
// Expected values are JavaScriptCore's (`jsc`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testEngineMisc() {
        let (rt, ctx) = makeCtx()
        func ev(_ js: String) -> JeffJSValue { ctx.eval(input: js, filename: "<EngineMisc>", evalFlags: JS_EVAL_TYPE_GLOBAL) }

        // --- 3. every predefined atom interns to its enum id ---
        var seen: [String: UInt32] = [:]
        var misaligned: [String] = []
        var raw: UInt32 = 1
        while raw < JSPredefinedAtom.END.rawValue {
            guard let a = JSPredefinedAtom(rawValue: raw) else { misaligned.append("#\(raw) missing"); raw += 1; continue }
            let name = a.stringValue
            if let first = seen[name] { misaligned.append("'\(name)' at \(first) and \(raw)") }
            seen[name] = raw
            // Well-known symbols are symbol atoms: not reachable by name (JeffJSRuntime "Symbol Atoms").
            if !name.hasPrefix("Symbol.") {
                let interned = rt.findAtom(name)
                if interned != raw { misaligned.append("'\(name)': enum \(raw), findAtom \(interned)") }
                rt.freeAtom(interned)
            }
            raw += 1
        }
        assert(misaligned.isEmpty, "EngineMisc: predefined atoms misaligned: \(misaligned.joined(separator: "; "))")
        assert(JSPredefinedAtom.set_ == .set && JSPredefinedAtom.of_ == .of && JSPredefinedAtom.writable_ == .writable,
               "EngineMisc: the old duplicate case names alias the canonical atoms")
        // A native read through the enum sees what JS wrote (the "set" of a descriptor).
        let desc = ev("({ get: 1, set: 2, of: 3, with: 4, toGMTString: 5, return: 6, throw: 7, for: 8, proxy: 9, writable: 10 })")
        for a in [JSPredefinedAtom.get, .set, .of, .with_, .toGMTString, .return_, .throw_, .for_, .proxy, .writable] {
            assert(ctx.hasProperty(obj: desc, atom: a.rawValue), "EngineMisc: hasProperty(desc, JSPredefinedAtom.\(a)) sees '\(a.stringValue)'")
        }
        desc.freeValue()

        // --- 1. native slot writes release what they replace ---
        let held = ev("var __emHeld = {}; var __emObj = { k: __emHeld }; __emHeld")
        let heldRc = held.toObject()?.refCount ?? 0
        let holder = ev("__emObj")
        let kAtom = rt.findAtom("k")
        holder.toObject()?.setOwnPropertyValue(atom: kAtom, value: .newInt32(1))
        rt.freeAtom(kAtom)
        assert((held.toObject()?.refCount ?? 0) == heldRc - 1,
               "EngineMisc: setOwnPropertyValue released the replaced value (\(heldRc) -> \(held.toObject()?.refCount ?? 0))")
        holder.freeValue(); held.freeValue()

        let li = ev("var __emLI = { valueOf: function () { return 0; } }; var __emRe = /a/g; __emRe.lastIndex = __emLI; __emLI")
        let liRc = li.toObject()?.refCount ?? 0
        ev("__emRe.exec('a')").freeValue()
        assert((li.toObject()?.refCount ?? 0) == liRc - 1,
               "EngineMisc: exec released the lastIndex value it replaced (\(liRc) -> \(li.toObject()?.refCount ?? 0))")
        ev("__emRe.lastIndex = __emLI; __emRe.exec('b')").freeValue()   // no match: lastIndex = 0
        assert((li.toObject()?.refCount ?? 0) == liRc - 1, "EngineMisc: a failed exec released the replaced lastIndex too")
        li.freeValue()

        // --- 4. Date: two references (global, Date.prototype.constructor), no stray count ---
        let date = ev("Date")
        assert((date.toObject()?.refCount ?? 0) == 3, "EngineMisc: Date is held by the global and its prototype (+ ours), rc \(date.toObject()?.refCount ?? 0)")
        date.freeValue()

        // --- JS checks (each must answer true) ---
        let r = ev(#"""
            (function () {
            var R = [];
            function check(name, f) { var r; try { r = f(); } catch (e) { r = "threw " + e; } if (r !== true) R.push(name + " -> " + r); }
            function throwsType(f) { try { f(); return false; } catch (e) { return e instanceof TypeError; } }
            // --- Proxy [[Set]] without a set trap ---
            check("no-trap: inherited setter runs with this = proxy", function () {
              var seen; var proto = { set x(v) { seen = this; this._v = v; } };
              var t = Object.create(proto); var p = new Proxy(t, {}); p.x = 5;
              return seen === p && t._v === 5 && !t.hasOwnProperty("x");
            });
            check("no-trap: own setter on the target runs with this = proxy", function () {
              var seen; var t = { set x(v) { seen = this; } }; var p = new Proxy(t, {}); p.x = 1; return seen === p;
            });
            check("no-trap: Reflect.set receiver reaches the setter", function () {
              var seen; var t = Object.create({ set x(v) { seen = this; } }); var p = new Proxy(t, {}); var r = {};
              return Reflect.set(p, "x", 1, r) === true && seen === r;
            });
            check("no-trap: Reflect.set(proxy, k, v) without receiver", function () {
              var seen; var t = Object.create({ set x(v) { seen = this; } }); var p = new Proxy(t, {});
              return Reflect.set(p, "x", 1) === true && seen === p;
            });
            check("no-trap: a data write lands on the target", function () {
              var t = { a: 1 }; var p = new Proxy(t, {}); p.a = 2; p.b = 3; return t.a === 2 && t.b === 3 && p.b === 3;
            });
            check("no-trap: the receiver's defineProperty trap is reached (new key and existing key)", function () {
              var log = []; var t = { a: 1 };
              var p = new Proxy(t, { defineProperty: function (tt, k, d) { log.push(k + ":" + d.value + ":" + ("writable" in d)); return Reflect.defineProperty(tt, k, d); } });
              p.a = 2; p.b = 3;
              return log.join() === "a:2:false,b:3:true" && t.a === 2 && t.b === 3;
            });
            check("no-trap: the receiver's getOwnPropertyDescriptor trap is reached", function () {
              var log = []; var t = { a: 1 };
              var p = new Proxy(t, { getOwnPropertyDescriptor: function (tt, k) { log.push(k); return Reflect.getOwnPropertyDescriptor(tt, k); } });
              p.a = 2; return log.join() === "a" && t.a === 2;
            });
            check("no-trap: a refused write is false (sloppy) / TypeError (strict) / false (Reflect.set)", function () {
              var t = Object.freeze({ a: 1 }); var p = new Proxy(t, {});
              p.a = 2;
              var strictThrew = (function () { "use strict"; try { p.a = 3; return false; } catch (e) { return e instanceof TypeError; } })();
              return t.a === 1 && strictThrew && Reflect.set(p, "a", 4) === false;
            });
            check("no-trap: getter-only inherited accessor refuses", function () {
              var t = Object.create({ get x() { return 1; } }); var p = new Proxy(t, {});
              return Reflect.set(p, "x", 2) === false && p.x === 1 && !t.hasOwnProperty("x");
            });
            check("no-trap over a proxy: the inner set trap receives the outer proxy", function () {
              var recv; var inner = new Proxy({}, { set: function (tt, k, v, r) { recv = r; tt[k] = v; return true; } });
              var outer = new Proxy(inner, {}); outer.z = 1; return recv === outer;
            });
            check("no-trap over an array target: length follows", function () {
              var a = [1, 2]; var p = new Proxy(a, {}); p[3] = 9; return a.length === 4 && a[3] === 9 && p.length === 4;
            });
            check("a set trap still wins", function () {
              var t = {}; var p = new Proxy(t, { set: function (tt, k, v) { tt[k] = v * 2; return true; } }); p.q = 2; return t.q === 4;
            });

            // --- RegExp lastIndex ---
            check("exec on a frozen global regexp throws TypeError (match and no match)", function () {
              var r = Object.freeze(/a/g); var r2 = Object.freeze(/a/g);
              return throwsType(function () { r.exec("a"); }) && throwsType(function () { r2.exec("b"); });
            });
            check("a non-writable lastIndex on a sticky regexp", function () {
              var r = /a/y; Object.defineProperty(r, "lastIndex", { writable: false });
              return throwsType(function () { r.exec("a"); }) && r.lastIndex === 0;
            });
            check("a non-global, non-sticky exec does not write lastIndex (frozen is fine)", function () {
              var r = Object.freeze(/a/); return r.exec("a")[0] === "a";
            });
            check("String.prototype.replace / match with a frozen global regexp throw", function () {
              return throwsType(function () { "aa".replace(Object.freeze(/a/g), "b"); }) &&
                     throwsType(function () { "aa".match(Object.freeze(/a/g)); });
            });
            check("search on a frozen regexp whose lastIndex is 0 works", function () {
              return "xa".search(Object.freeze(/a/)) === 1;
            });
            check("search restores lastIndex", function () {
              var r = /a/g; r.lastIndex = 3; return "xxa".search(r) === 2 && r.lastIndex === 3;
            });
            check("lastIndex as a string is ToLength'd", function () {
              var r = /a/g; r.lastIndex = "1"; var m = r.exec("aa"); return m.index === 1 && r.lastIndex === 2;
            });
            check("lastIndex valueOf runs once per exec (sticky), and for a non-global exec too", function () {
              var n = 0; var r = /a/y; r.lastIndex = { valueOf: function () { n++; return 1; } };
              var ok1 = r.exec("ba") !== null && r.lastIndex === 2 && n === 1;
              var m = 0; var r2 = /a/; r2.lastIndex = { valueOf: function () { m++; return 0; } }; r2.exec("a");
              return ok1 && m === 1;
            });
            check("a throwing lastIndex valueOf propagates", function () {
              var r = /a/g; r.lastIndex = { valueOf: function () { throw new RangeError("x"); } };
              try { r.exec("a"); return false; } catch (e) { return e instanceof RangeError; }
            });
            check("global exec loop and empty-match advance still work", function () {
              var r = /a*/g, s = "baab", out = [], m, guard = 0;
              while ((m = r.exec(s)) && guard++ < 10) { out.push(m.index + ":" + m[0]); if (m[0] === "") r.lastIndex++; }
              return out.join() === "0:,1:aa,3:,4:" && "aXbX".replace(/X/g, "-") === "a-b-" && "a1b22".match(/\d+/g).join() === "1,22" &&
                Array.from("a,b".matchAll(/[a-z]/g)).length === 2 && "".replace(/(?:)/g, "x") === "x";
            });
            check("compile resets lastIndex; frozen compile throws", function () {
              var r = /a/g; r.lastIndex = 2; r.compile("b", "g");
              return r.lastIndex === 0 && throwsType(function () { var f = /a/; Object.defineProperty(f, "lastIndex", { writable: false }); f.compile("c"); });
            });

            // --- global function declarations over existing properties (ES §16.1.7) ---
            check("function over a configurable global: full definition", function () {
              Object.defineProperty(globalThis, "__emA", { value: 1, writable: false, enumerable: false, configurable: true });
              (0, eval)("function __emA() { return 7; }");
              var d = Object.getOwnPropertyDescriptor(globalThis, "__emA");
              return __emA() === 7 && d.writable === true && d.configurable === true;
            });
            check("function over a non-configurable writable enumerable global: value only, attributes kept", function () {
              Object.defineProperty(globalThis, "__emB", { value: 1, writable: true, enumerable: true, configurable: false });
              (0, eval)("function __emB() { return 8; }");
              var d = Object.getOwnPropertyDescriptor(globalThis, "__emB");
              return __emB() === 8 && d.writable === true && d.enumerable === true && d.configurable === false;
            });
            check("function over a non-configurable non-enumerable / read-only / accessor global: TypeError", function () {
              Object.defineProperty(globalThis, "__emC", { value: 1, writable: true, enumerable: false, configurable: false });
              Object.defineProperty(globalThis, "__emD", { value: 1, writable: false, enumerable: true, configurable: false });
              Object.defineProperty(globalThis, "__emE", { get: function () { return 1; }, configurable: false });
              return throwsType(function () { (0, eval)("function __emC() {}"); }) && __emC === 1 &&
                     throwsType(function () { (0, eval)("function __emD() {}"); }) && __emD === 1 &&
                     throwsType(function () { (0, eval)("function __emE() {}"); }) && __emE === 1 &&
                     throwsType(function () { (0, eval)("function NaN() {}"); }) && NaN !== NaN;
            });
            check("var then function at the top level", function () {
              return typeof (0, eval)("var __emF; function __emF() { return 1; } __emF") === "function";
            });

            // --- Date ---
            check("Date intrinsics", function () {
              return typeof Date === "function" && Date.prototype.constructor === Date && Date.name === "Date" && Date.length === 7 &&
                new Date(0).getTime() === 0 && Object.getOwnPropertyNames(Date).indexOf("prototype") >= 0 &&
                Date.prototype.toGMTString === Date.prototype.toUTCString;
            });

            return R.length ? R.join(" | ") : true;
            })()
            """#)
        if r.isException {
            let exc = ctx.getException()
            assert(false, "EngineMisc: threw \(ctx.toSwiftString(exc) ?? "?")")
            exc.freeValue()
        } else {
            assert(r.isBool && r.toBool(), "EngineMisc: \(ctx.toSwiftString(r) ?? "?")")
        }
        r.freeValue()
    }
}
