// OwnPropertyOrderConformance.swift
// JeffJS — conformance group "OwnPropertyOrder" (Safari surface parity, 2026-10-06).
// The host's two own-key primitives (Core/JeffJSOwnPropertyOrder.swift):
//  - a hidden own property is found by name but listed by no own-key enumeration
//    (getOwnPropertyNames, Reflect.ownKeys, getOwnPropertySymbols, keys/entries, for-in,
//    JSON, assign/spread); it stays hidden when redefined;
//  - reorderOwnProperties moves own properties (data, accessors, functions' lazy
//    name/length/prototype, symbols) without changing what they hold, and inline caches
//    that saw the old order still read the right slots.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testOwnPropertyOrder() {
        let (_, ctx) = makeCtx()
        func ev(_ js: String) -> JeffJSValue { ctx.eval(input: js, filename: "<OwnPropertyOrder>", evalFlags: JS_EVAL_TYPE_GLOBAL) }
        func check(_ name: String, _ js: String) {
            let r = ev(js)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "OwnPropertyOrder: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                assert(r.isBool && r.toBool(), "OwnPropertyOrder: \(name) -> \(ctx.toSwiftString(r) ?? "?")")
            }
            r.freeValue()
        }
        func atom(_ s: String) -> UInt32 { ctx.rt.findAtom(s) }

        // --- hidden ---
        ev("var __opoHidden = { a: 1, b: 2, c: 3 }; Object.defineProperty(__opoHidden, 'g', { get: function(){ return 7; }, enumerable: true, configurable: true }); globalThis.__opoGlue = function(){ return 42; }; var __opoSym = Symbol('s'); __opoHidden[__opoSym] = 5; function __opoReadB(o){ return o.b; }").freeValue()
        let ho = ev("__opoHidden")
        let g = ctx.getGlobalObject()
        assert(ctx.setOwnPropertyHidden(ho, atom: atom("b"), hidden: true), "OwnPropertyOrder: hide b")
        assert(ctx.setOwnPropertyHidden(ho, atom: atom("g"), hidden: true), "OwnPropertyOrder: hide g")
        assert(ctx.setOwnPropertyHidden(g, atom: atom("__opoGlue"), hidden: true), "OwnPropertyOrder: hide glue")
        assert(!ctx.setOwnPropertyHidden(ho, atom: atom("nope"), hidden: true), "OwnPropertyOrder: hide absent")
        check("hidden: not listed by any own-key enumeration", """
            (function(){ var o = __opoHidden, s = JSON.stringify, fi = []; for (var k in o) fi.push(k);
              return s(Object.getOwnPropertyNames(o)) === '["a","c"]' && Reflect.ownKeys(o).length === 3 && s(Object.keys(o)) === '["a","c"]' &&
                s(fi) === '["a","c"]' && s(o) === '{"a":1,"c":3}' && s(Object.assign({}, o)) === '{"a":1,"c":3}' && s(Object.keys({...o})) === '["a","c"]' &&
                s(Object.entries(o)) === '[["a",1],["c",3]]' && Object.keys(Object.getOwnPropertyDescriptors(o)).length === 2 &&
                Object.getOwnPropertyNames(globalThis).indexOf('__opoGlue') < 0; })()
            """)
        check("hidden: found by name, `in`, a bare identifier, hasOwnProperty and delete", """
            (function(){ var o = __opoHidden; return o.b === 2 && o.g === 7 && 'b' in o && o.hasOwnProperty('b') && __opoGlue() === 42 &&
              window.__opoGlue === __opoGlue && typeof __opoGlue === 'function' && __opoReadB(o) === 2 && __opoReadB(o) === 2; })()
            """.replacingOccurrences(of: "window.", with: "globalThis."))
        check("hidden: stays hidden when redefined or assigned", """
            (function(){ var o = __opoHidden; o.b = 20; Object.defineProperty(o, 'b', { value: 21, enumerable: true }); __opoGlue = function(){ return 43; };
              return o.b === 21 && __opoGlue() === 43 && JSON.stringify(Object.getOwnPropertyNames(o)) === '["a","c"]' && Object.keys(o).length === 2 &&
                Object.getOwnPropertyNames(globalThis).indexOf('__opoGlue') < 0; })()
            """)
        check("hidden: a deleted then re-added property is visible again", """
            (function(){ var o = __opoHidden; delete o.b; o.b = 9; return JSON.stringify(Object.getOwnPropertyNames(o)) === '["a","c","b"]'; })()
            """)
        assert(ctx.setOwnPropertyHidden(ho, atom: atom("g"), hidden: false), "OwnPropertyOrder: show g")
        check("hidden: shown again is listed (not enumerable)", "JSON.stringify(Object.getOwnPropertyNames(__opoHidden)) === '[\"a\",\"c\",\"g\",\"b\"]' && Object.keys(__opoHidden).indexOf('g') < 0")
        ho.freeValue()

        // --- reorder ---
        ev("var __opoR = { x: 1, y: 2 }; Object.defineProperty(__opoR, 'acc', { get: function(){ return this.x + 100; }, set: function(v){ this.x = v; }, enumerable: true, configurable: true }); __opoR.z = 3; __opoR[Symbol.toStringTag] = 'R'; function __opoRx(o){ return o.x + o.z; } __opoRx(__opoR); __opoRx(__opoR); function __opoF(a, b) {}").freeValue()
        let ro = ev("__opoR")
        assert(ctx.reorderOwnProperties(ro, order: [atom("z"), atom("acc"), atom("missing"), atom("z")]), "OwnPropertyOrder: reorder")
        check("reorder: listed in the new order, then the rest in the old order; values and accessors move with their keys", """
            (function(){ var o = __opoR; return JSON.stringify(Object.getOwnPropertyNames(o)) === '["z","acc","x","y"]' && o.acc === 101 &&
              (o.acc = 5, o.x === 5) && o.z === 3 && o.y === 2 && Object.prototype.toString.call(o) === '[object R]' && __opoRx(o) === 8 &&
              JSON.stringify(o) === '{"z":3,"acc":105,"x":5,"y":2}'; })()
            """)
        check("reorder: a later property appends", "(__opoR.w = 4, JSON.stringify(Object.keys(__opoR)) === '[\"z\",\"acc\",\"x\",\"y\",\"w\"]')")
        ro.freeValue()
        let fo = ev("__opoF")
        assert(ctx.reorderOwnProperties(fo, order: [atom("prototype"), atom("name"), atom("length")]), "OwnPropertyOrder: reorder function")
        check("reorder: a function's lazy own properties are placed too", """
            (function(){ var f = __opoF; return JSON.stringify(Object.getOwnPropertyNames(f)) === '["prototype","name","length"]' && f.length === 2 &&
              f.name === '__opoF' && f.prototype.constructor === f; })()
            """)
        fo.freeValue()
        assert(ctx.reorderOwnProperties(g, order: [atom("__opoR"), atom("Object")]), "OwnPropertyOrder: reorder global")
        check("reorder: the global object (global variable caches see the new slots)", """
            (function(){ var n = Object.getOwnPropertyNames(globalThis); return n[0] === '__opoR' && n[1] === 'Object' && __opoR.y === 2 &&
              typeof Object.keys === 'function' && __opoRx(__opoR) === 8 && __opoGlue() === 43 && n.indexOf('__opoGlue') < 0; })()
            """)
        g.freeValue()

        // --- host-deferred own properties ---
        var runs = 0
        func lazyOn(_ js: String) {
            let o = ev(js)
            ctx.setLazyOwnProperties(o) { c, obj in
                runs += 1
                let one = JeffJSValue.newInt32(1), two = JeffJSValue.newInt32(2)
                _ = c.definePropertyValue(obj: obj, atom: c.rt.findAtom("la"), value: one, flags: JS_PROP_C_W_E)
                _ = c.definePropertyValue(obj: obj, atom: c.rt.findAtom("lb"), value: two, flags: JS_PROP_C_W_E)
                one.freeValue(); two.freeValue()
            }
            o.freeValue()
        }
        ev("var __opoL1 = {}, __opoL2 = {}, __opoL3 = {}, __opoL4 = {}, __opoChild = Object.create(__opoL2);").freeValue()
        lazyOn("__opoL1"); lazyOn("__opoL2"); lazyOn("__opoL3"); lazyOn("__opoL4")
        assert(runs == 0, "OwnPropertyOrder: lazy materialisers ran early")
        check("lazy: getOwnPropertyNames materialises", "JSON.stringify(Object.getOwnPropertyNames(__opoL1)) === '[\"la\",\"lb\"]'")
        check("lazy: a read through a prototype chain materialises", "__opoChild.lb === 2 && 'la' in __opoChild")
        check("lazy: for-in materialises", "(function(){ var k = []; for (var x in __opoL3) k.push(x); return k.join() === 'la,lb'; })()")
        check("lazy: an own define keeps the deferred ones first", "(__opoL4.z = 5, JSON.stringify(Object.keys(__opoL4)) === '[\"la\",\"lb\",\"z\"]')")
        assert(runs == 4, "OwnPropertyOrder: lazy materialisers ran \(runs) times (want 4)")
    }
}
