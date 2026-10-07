// DefineOverExistingConformance.swift
// JeffJS — conformance group "DefineOverExisting" (2026-10-07).
// Every native definition path (setPropertyGetSet, setPropertyFunc, definePropertyValue, the
// defineIntrinsic* helpers, jeffJS_defineBuiltinFunc / jeffJS_addGetterProperty,
// defineOrReplaceOwnProperty) over a name the object already owns must do what
// Object.defineProperty does (ES §10.1.6.3 ValidateAndApplyPropertyDescriptor): replace the
// property in place — one shape entry per key, same slot, same key position, data <-> accessor
// converted there, the replaced value / getter / setter released, inline caches that saw the old
// kind re-resolve — and leave a non-configurable property alone. setPropertyGetSet used to
// append a second shape entry for the key (listed twice, `delete` uncovered the old one), and the
// builtin installers wrote into the object's last slot.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testDefineOverExisting() {
        let (_, ctx) = makeCtx()
        func ev(_ js: String) -> JeffJSValue { ctx.eval(input: js, filename: "<DefineOverExisting>", evalFlags: JS_EVAL_TYPE_GLOBAL) }
        func check(_ name: String, _ js: String) {
            let r = ev(js)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "DefineOverExisting: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                assert(r.isBool && r.toBool(), "DefineOverExisting: \(name) -> \(ctx.toSwiftString(r) ?? "?")")
            }
            r.freeValue()
        }
        func noPending(_ name: String) {
            let pending = !ctx.rt.currentException.isNull && !ctx.rt.currentException.isUndefined
            if pending { ctx.getException().freeValue() }
            assert(!pending, "DefineOverExisting: \(name) left an exception pending")
        }
        /// A native getter returning `n` (owned).
        func getterFn(_ n: Int32) -> JeffJSValue { ctx.newCFunction({ _, _, _ in .newInt32(n) }, name: "get", length: 0) }
        /// A native setter storing its argument in `this._s` (owned).
        func setterFn() -> JeffJSValue {
            ctx.newCFunction({ c, this, args in
                _ = c.setPropertyStr(obj: this, name: "_s", value: (args.first ?? .undefined).dupValue()); return .undefined
            }, name: "set", length: 1)
        }
        func slots(_ v: JeffJSValue) -> (shape: Int, values: Int) {
            guard let o = v.toObject() else { return (-1, -1) }
            return (o.shape?.prop.count ?? -1, o.propValues.count)
        }
        func atom(_ s: String) -> UInt32 { ctx.rt.findAtom(s) }

        ev("""
            function __doeNames(o) { return JSON.stringify(Object.getOwnPropertyNames(o)); }
            function __doeUnique(o) { var k = Reflect.ownKeys(o); return new Set(k).size === k.length; }
            function __doeDesc(o, k) { var d = Object.getOwnPropertyDescriptor(o, k); if (!d) return 'none';
              return ('value' in d ? 'data:' + (typeof d.value === 'function' ? 'fn' : String(d.value)) + ':w' + (d.writable ? 1 : 0)
                : 'acc:' + typeof d.get + ':' + typeof d.set) + ':e' + (d.enumerable ? 1 : 0) + ':c' + (d.configurable ? 1 : 0); }
            function __doeRead(o) { return o.k; }
            function __doeWrite(o, v) { o.k = v; }
            """).freeValue()

        // --- setPropertyGetSet over a data property ---
        let a = ev("var __doeA = { a: 1, k: 2, z: 3 }; for (var i = 0; i < 20; i++) __doeRead(__doeA); __doeA")
        let a0 = slots(a)
        ctx.setPropertyGetSet(obj: a, name: "k", getter: getterFn(42), setter: setterFn())
        noPending("getset over data")
        let a1 = slots(a)
        check("getset over data: replaced in place, listed once, accessor", """
            __doeNames(__doeA) === '["a","k","z"]' && __doeUnique(__doeA) && __doeDesc(__doeA, 'k') === 'acc:function:function:e1:c1' &&
              __doeA.k === 42 && (__doeA.k = 7, __doeA._s === 7)
            """)
        assert(a1.shape == a0.shape && a1.values == a0.values,
               "DefineOverExisting: getset over data kept the slot counts (\(a0) -> \(a1))")
        assert(a1.shape == 3, "DefineOverExisting: getset over data: 3 shape entries, got \(a1.shape)")
        check("getset over data: a warmed read site sees the accessor", "__doeRead(__doeA) === 42 && __doeRead(__doeA) === 42")
        check("getset over data: delete removes the key entirely", "delete __doeA.k && !('k' in __doeA) && __doeA.k === undefined && __doeNames(__doeA) === '[\"a\",\"z\",\"_s\"]'")
        a.freeValue()

        // --- setPropertyGetSet over an accessor: the old getter / setter are released ---
        let b = ev("var __doeB = { a: 1 }; Object.defineProperty(__doeB, 'k', { get: function(){ return 1; }, configurable: true, enumerable: false }); __doeB.z = 3; __doeB")
        let g1 = getterFn(10)
        let g1rc = g1.toObject()?.refCount ?? 0
        ctx.setPropertyGetSet(obj: b, name: "k", getter: g1.dupValue(), setter: nil)
        let g1held = g1.toObject()?.refCount ?? 0
        check("getset over accessor: in place, new getter", "__doeNames(__doeB) === '[\"a\",\"k\",\"z\"]' && __doeUnique(__doeB) && __doeB.k === 10 && __doeDesc(__doeB, 'k') === 'acc:function:undefined:e1:c1'")
        ctx.setPropertyGetSet(obj: b, name: "k", getter: getterFn(11), setter: nil)
        assert(g1held == g1rc + 1 && (g1.toObject()?.refCount ?? 0) == g1rc,
               "DefineOverExisting: replaced getter released (\(g1rc) -> \(g1held) -> \(g1.toObject()?.refCount ?? 0))")
        check("getset over accessor twice: still one entry", "__doeNames(__doeB) === '[\"a\",\"k\",\"z\"]' && __doeB.k === 11")
        assert(slots(b).shape == 3, "DefineOverExisting: getset over accessor: 3 shape entries, got \(slots(b).shape)")
        g1.freeValue()
        b.freeValue()

        // --- the replaced data value is released ---
        let held = ev("var __doeHeld = {}; var __doeC = { k: __doeHeld, z: 1 }; __doeHeld")
        let heldRc = held.toObject()?.refCount ?? 0
        let c = ev("__doeC")
        ctx.setPropertyGetSet(obj: c, name: "k", getter: getterFn(5), setter: nil)
        assert((held.toObject()?.refCount ?? 0) == heldRc - 1, "DefineOverExisting: replaced data value released (\(heldRc) -> \(held.toObject()?.refCount ?? 0))")
        held.freeValue()

        // --- accessor -> data through setPropertyFunc / definePropertyValue / the routine ---
        ctx.setPropertyFunc(obj: c, name: "k", fn: { _, _, _ in .newInt32(99) }, length: 0)
        noPending("func over accessor")
        check("func over accessor: method in place", "__doeNames(__doeC) === '[\"k\",\"z\"]' && __doeUnique(__doeC) && __doeDesc(__doeC, 'k') === 'data:fn:w1:e0:c1' && __doeC.k() === 99")
        _ = ctx.definePropertyValue(obj: c, atom: atom("k"), value: .newInt32(8), flags: JS_PROP_C_W_E)
        check("definePropertyValue over data: in place", "__doeNames(__doeC) === '[\"k\",\"z\"]' && __doeDesc(__doeC, 'k') === 'data:8:w1:e1:c1'")
        let gk = getterFn(3)
        assert(ctx.defineOrReplaceOwnProperty(c, atom: atom("k"), getter: gk, setter: nil, flags: JS_PROP_CONFIGURABLE | JS_PROP_GETSET),
               "DefineOverExisting: routine data -> accessor")
        gk.freeValue()
        check("routine data -> accessor: in place", "__doeNames(__doeC) === '[\"k\",\"z\"]' && __doeDesc(__doeC, 'k') === 'acc:function:undefined:e0:c1' && __doeC.k === 3")
        assert(ctx.defineOrReplaceOwnProperty(c, atom: atom("k"), value: .newInt32(4), flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE),
               "DefineOverExisting: routine accessor -> data")
        check("routine accessor -> data: in place", "__doeNames(__doeC) === '[\"k\",\"z\"]' && __doeDesc(__doeC, 'k') === 'data:4:w1:e0:c1' && __doeC.k === 4")
        assert(slots(c).shape == 2, "DefineOverExisting: four redefinitions, 2 shape entries, got \(slots(c).shape)")
        c.freeValue()

        // --- every kind combination agrees with Object.defineProperty ---
        // native: (from, to) on a native twin, JS: the same through Object.defineProperty.
        ev("""
            function __doeMake(kind) { var o = { p: 0 }; if (kind === 'data') o.k = 1;
              else Object.defineProperty(o, 'k', { get: function(){ return 1; }, set: function(v){}, enumerable: true, configurable: true });
              o.q = 2; return o; }
            """).freeValue()
        for from in ["data", "acc"] {
            for to in ["data", "acc"] {
                let o = ev("__doeMake('\(from)')")
                if to == "data" {
                    ctx.defineOrReplaceOwnProperty(o, atom: atom("k"), value: .newInt32(6), flags: JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE)
                } else {
                    ctx.setPropertyGetSet(obj: o, name: "k", getter: getterFn(6), setter: nil)
                }
                let g = ctx.getGlobalObject()
                _ = ctx.setPropertyStr(obj: g, name: "__doeO", value: o)
                g.freeValue()
                let js = to == "data" ? "{ value: 6, writable: true, enumerable: true, configurable: true }"
                                      : "{ get: function(){ return 6; }, set: undefined, enumerable: true, configurable: true }"
                check("kind \(from) -> \(to) matches Object.defineProperty", """
                    (function(){ var t = __doeMake('\(from)'); Object.defineProperty(t, 'k', \(js));
                      return (__doeNames(__doeO) === __doeNames(t) && __doeNames(t) === '["p","k","q"]' && __doeUnique(__doeO) &&
                        __doeDesc(__doeO, 'k') === __doeDesc(t, 'k') && __doeO.k === 6 && t.k === 6) ||
                        [__doeNames(__doeO), __doeNames(t), __doeDesc(__doeO, 'k'), __doeDesc(t, 'k'), __doeO.k, t.k].join(' | '); })()
                    """)
            }
        }

        // --- non-configurable: rejected, nothing changed, nothing pending ---
        let n = ev("var __doeN = { a: 1 }; Object.defineProperty(__doeN, 'k', { value: 5, writable: false, enumerable: true, configurable: false }); Object.defineProperty(__doeN, 'g', { get: function(){ return 1; }, configurable: false }); __doeN")
        let ng = getterFn(9)
        let ngRc = ng.toObject()?.refCount ?? 0
        ctx.setPropertyGetSet(obj: n, name: "k", getter: ng.dupValue(), setter: nil)
        noPending("getset over non-configurable")
        assert((ng.toObject()?.refCount ?? 0) == ngRc, "DefineOverExisting: a refused getter is not kept")
        ng.freeValue()
        ctx.setPropertyFunc(obj: n, name: "g", fn: { _, _, _ in .undefined }, length: 0)
        noPending("func over non-configurable accessor")
        assert(!ctx.defineOrReplaceOwnProperty(n, atom: atom("k"), value: .newInt32(6), flags: JS_PROP_ENUMERABLE),
               "DefineOverExisting: routine refuses a non-configurable change")
        assert(ctx.defineOrReplaceOwnProperty(n, atom: atom("k"), value: .newInt32(5), flags: JS_PROP_ENUMERABLE),
               "DefineOverExisting: routine accepts an identical non-configurable descriptor")
        let threw = !ctx.defineOrReplaceOwnProperty(n, atom: atom("k"), value: .newInt32(7), flags: JS_PROP_ENUMERABLE | JS_PROP_THROW)
        let exc = ctx.getException()
        assert(threw && ctx.toSwiftString(exc)?.contains("TypeError") == true, "DefineOverExisting: JS_PROP_THROW makes the refusal a TypeError")
        exc.freeValue()
        check("non-configurable: untouched", "__doeNames(__doeN) === '[\"a\",\"k\",\"g\"]' && __doeDesc(__doeN, 'k') === 'data:5:w0:e1:c0' && __doeDesc(__doeN, 'g') === 'acc:function:undefined:e0:c0' && __doeN.g === 1")
        n.freeValue()

        // --- non-extensible: an existing key is replaced, a new one refused ---
        let x = ev("var __doeX = Object.preventExtensions({ k: 1 }); __doeX")
        ctx.setPropertyGetSet(obj: x, name: "k", getter: getterFn(2), setter: nil)
        ctx.setPropertyGetSet(obj: x, name: "fresh", getter: getterFn(3), setter: nil)
        noPending("getset on non-extensible")
        check("non-extensible: replaced in place, no new key", "__doeNames(__doeX) === '[\"k\"]' && __doeX.k === 2 && !('fresh' in __doeX)")
        x.freeValue()

        // --- host-style redefinition of a prototype accessor (the DOM bridge / Safari surface pattern) ---
        let proto = ev("""
            function __DoeIface() {} var __doeP = __DoeIface.prototype;
            Object.defineProperty(__doeP, 'data', { get: function(){ return 'stub'; }, configurable: true, enumerable: true });
            __doeP.after = 1; var __doeI = new __DoeIface();
            function __doeReadData(o) { return o.data; } for (var i = 0; i < 20; i++) __doeReadData(__doeI); __doeP
            """)
        ctx.setOwnPropertyShadowable(proto, atom: atom("data"))
        ctx.setPropertyGetSet(obj: proto, name: "data", getter: getterFn(1), setter: setterFn())
        check("prototype accessor redefined: one entry, same place, instances (and warmed sites) see the new one", """
            __doeNames(__doeP) === '["constructor","data","after"]' && __doeUnique(__doeP) && __doeReadData(__doeI) === 1 &&
              __doeReadData(new __DoeIface()) === 1 && (__doeI.data = 4, __doeI._s === 4 && !__doeI.hasOwnProperty('data'))
            """)
        ctx.setPropertyGetSet(obj: proto, name: "data", getter: getterFn(2), setter: nil)
        check("prototype accessor redefined twice", "__doeReadData(__doeI) === 2 && __doeNames(__doeP) === '[\"constructor\",\"data\",\"after\"]'")
        assert(ctx.reorderOwnProperties(proto, order: [atom("after"), atom("data")]), "DefineOverExisting: reorder")
        check("reorder after redefinition keeps the current accessor", "__doeNames(__doeP) === '[\"after\",\"data\",\"constructor\"]' && __doeReadData(__doeI) === 2 && delete __doeP.data && __doeI.data === undefined")
        proto.freeValue()

        // --- host-deferred own properties: a definition before materialisation ---
        let lazy = ev("var __doeL = {}; __doeL")
        ctx.setLazyOwnProperties(lazy) { c, o in
            c.setPropertyGetSet(obj: o, name: "m", getter: c.newCFunction({ _, _, _ in .newInt32(1) }, name: "get m", length: 0), setter: nil)
            c.setPropertyFunc(obj: o, name: "f", fn: { _, _, _ in .newInt32(1) }, length: 0)
        }
        ctx.setPropertyGetSet(obj: lazy, name: "m", getter: getterFn(2), setter: nil)
        check("lazy host object: materialised first, then replaced in place", "__doeNames(__doeL) === '[\"m\",\"f\"]' && __doeUnique(__doeL) && __doeL.m === 2 && __doeL.f() === 1")
        lazy.freeValue()

        // --- the builtin installers replace in place instead of writing the last slot ---
        let bo = ev("var __doeBI = { a: 1, b: 2, last: 3 }; __doeBI")
        if let o = bo.toObject() {
            jeffJS_defineBuiltinFunc(ctx: ctx, obj: o, name: "a", length: 0) { _, _, _ in .newInt32(77) }
            jeffJS_addGetterProperty(ctx: ctx, proto: o, name: "b") { _, _ in .newInt32(88) }
        }
        check("builtin installers over existing names", "__doeNames(__doeBI) === '[\"a\",\"b\",\"last\"]' && __doeBI.a() === 77 && __doeBI.b === 88 && __doeBI.last === 3")
        bo.freeValue()

        // --- intrinsic links (internal mode) still replace a non-configurable link ---
        let ctor = ev("var __doeCtor = function(){}; Object.defineProperty(__doeCtor, 'prototype', { writable: false }); __doeCtor")
        let np = ev("({ np: 1 })")
        ctx.defineIntrinsicPrototypeLink(ctor: ctor, proto: np)
        check("defineIntrinsicPrototypeLink over an existing link", "__doeCtor.prototype.np === 1 && __doeCtor.prototype.constructor === __doeCtor && __doeUnique(__doeCtor) && __doeDesc(__doeCtor, 'prototype') === 'data:[object Object]:w0:e0:c0'")
        np.freeValue()
        ctor.freeValue()

        // --- a warmed write site after data -> accessor -> data ---
        let w = ev("var __doeW = { k: 0 }; for (var i = 0; i < 20; i++) __doeWrite(__doeW, i); __doeW")
        ctx.setPropertyGetSet(obj: w, name: "k", getter: getterFn(1), setter: setterFn())
        check("warmed write site calls the new setter", "(__doeWrite(__doeW, 30), __doeW._s === 30 && __doeW.k === 1)")
        ctx.defineOrReplaceOwnProperty(w, atom: atom("k"), value: .newInt32(0), flags: JS_PROP_C_W_E)
        check("warmed write site writes the data property again", "(__doeWrite(__doeW, 31), __doeW.k === 31 && __doeNames(__doeW) === '[\"k\",\"_s\"]')")
        w.freeValue()

        // --- the JS reference path: ToPropertyDescriptor reads presence, not the value ---
        check("Object.defineProperty: an explicit `set: undefined` clears the setter, keeps the getter", """
            (function(){ var o = {}; Object.defineProperty(o, 'k', { get: function(){ return 1; }, set: function(v){}, configurable: true });
              Object.defineProperty(o, 'k', { set: undefined }); var d = Object.getOwnPropertyDescriptor(o, 'k');
              return d.set === undefined && typeof d.get === 'function' && o.k === 1; })()
            """)
        check("Object.defineProperty: `{ get: undefined }` turns a data property into an accessor in place", """
            (function(){ var o = { a: 0, k: 1, z: 2 }; Object.defineProperty(o, 'k', { get: undefined }); var d = Object.getOwnPropertyDescriptor(o, 'k');
              return !('value' in d) && d.get === undefined && d.set === undefined && d.enumerable && d.configurable && o.k === undefined &&
                __doeNames(o) === '["a","k","z"]'; })()
            """)
        check("ToPropertyDescriptor: a non-callable getter / setter or accessor + value is a TypeError (Reflect too)", """
            (function(){ function t(f){ try { f(); return false; } catch (e) { return e instanceof TypeError; } }
              return t(function(){ Object.defineProperty({}, 'x', { get: 1 }); }) && t(function(){ Object.defineProperty({}, 'x', { set: {} }); }) &&
                t(function(){ Object.defineProperty({}, 'x', { get: function(){}, value: 1 }); }) &&
                t(function(){ Reflect.defineProperty({}, 'x', { set: function(){}, writable: true }); }) &&
                t(function(){ Object.defineProperties({}, { x: { get: 'no' } }); }); })()
            """)
    }
}
