// LargeObjectShapeTests.swift
// JeffJS — building one object with thousands of distinct properties must not keep a
// cached transition shape per property. Each new property on a hashed shape used to clone
// the whole property array into a new hashed shape that the transition table keeps (until a
// collection sweeps it), so an N-property object cost N shapes and N²/2 property slots:
// threes.day's live page grew +146 MB in 250 ms on the Apple Watch (16 835 shapes x 10.9 KB).
// Past `shapes.maxHashedProps` properties an object gets a private shape that grows in place
// (a dictionary-mode object), like quickjs's in-place `add_shape_property` on an owned shape.
//
//   swift test -c release --filter LargeObjectShapeTests

import XCTest
@testable import JeffJS

final class LargeObjectShapeTests: XCTestCase {

    /// Property slots held by every shape on the GC list (the cost the bug multiplied).
    private func shapeSlots(_ rt: JeffJSRuntime) -> Int {
        var n = 0
        for u in rt.gcObjects {
            let h = u.takeUnretainedValue()
            if h.gcObjType == .shape { n += unsafeBitCast(h, to: JeffJSShape.self).prop.capacity }
        }
        return n
    }

    func testBuildingLargeObjectsStaysLinear() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        // No collection meanwhile (the app's heap often does not reach the GC threshold
        // first): what is measured is what the transitions leave behind.
        jeffJS_gcDisable = true
        defer { jeffJS_gcDisable = false }
        let before = shapeSlots(rt)
        let r = ctx.eval(input: """
            var ok = true;
            for (var r = 0; r < 4; r++) {                       // four maps, distinct key sets
                var m = { first: 1 };
                for (var i = 0; i < 2000; i++) m['p' + r + '_' + i] = i;
                var copy = JSON.parse(JSON.stringify(m));         // and a parsed copy of each
                var spread = { ...copy };
                ok = ok && Object.keys(spread).length === 2001 && spread['p' + r + '_1999'] === 1999;
            }
            var big = { a: 1 };
            for (var i = 0; i < 300; i++) big['k' + i] = i;
            delete big.k10; big.k10 = 10;                         // delete + re-add on the dictionary
            var sum = 0; for (var k in big) sum += big[k];
            ok && sum === 44851 && big.k10 === 10 && Object.keys(big).length === 301
            """, filename: "<large-objects>", evalFlags: 0)
        XCTAssertTrue(r.isBool && r.toBool(), "large object semantics")
        r.freeValue()
        let slots = shapeSlots(rt) - before
        // Linear: tens of thousands of slots, not the ~16 M quadratic chain (190 MB).
        XCTAssertLessThan(slots, 200_000, "shape slots after building 4 x 2000-key maps: \(slots)")
    }
}

extension LargeObjectShapeTests {
    /// A dictionary object that an inline cache has seen (a prototype-method read through
    /// it) and that then gains an own property with that name reads the own property.
    func testPrivateShapeGrowthKeepsCachesCorrect() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let r = ctx.eval(input: """
            var d = {};
            for (var i = 0; i < 200; i++) d['k' + i] = i;      // past shapes.maxHashedProps: private
            function read(o) { return typeof o.toString; }       // caches "toString on the prototype"
            var a = read(d), b = read(d);
            d.toString = 7;                                       // own property appended
            var c = read(d);
            function def(o) { o.zz = 1; return o; }              // define on the dictionary
            def(d); def(d);
            a === 'function' && b === 'function' && c === 'number' && d.zz === 1 && d.k199 === 199
            """, filename: "<dict-ic>", evalFlags: 0)
        XCTAssertTrue(r.isBool && r.toBool(), "own property after a cached prototype read")
        r.freeValue()
    }
}
