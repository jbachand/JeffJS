// ObjectSizeRefLeakTests.swift
// JeffJS — perf/watch-object-size (2026-10-05): the refcount leaks that kept
// homedepot's heap at 3x its live size, and the compact object/string layouts.
// Each leak test runs a construct many times, drops everything, collects, and
// checks that the GC heap went back to where it was (objects) or that the
// value's count is exactly what its holders account for (strings).
//
//   swift test -c release --filter ObjectSizeRefLeakTests
//   JEFFJS_ZOMBIES=1 swift test -c release --filter ObjectSizeRefLeakTests

import XCTest
@testable import JeffJS

final class ObjectSizeRefLeakTests: XCTestCase {

    /// Define `body` (a JS function expression taking `i`), warm it up (shapes,
    /// atoms and inline caches it creates once are not leaks), then run it `n`
    /// times, collect, and return the growth of the GC list.
    private func objectGrowth(_ ctx: JeffJSContext, _ body: String, n: Int = 2000) -> Int {
        func run(_ src: String) {
            let r = ctx.eval(input: src, filename: "<leak>", evalFlags: 0)
            XCTAssertFalse(r.isException, body)
            r.freeValue()
            _ = ctx.rt.executePendingJobs()
            ctx.rt.runGC(); ctx.rt.runGC()
        }
        run("globalThis.__f = \(body); for (var i = 0; i < 50; i++) __f(i);")
        let before = ctx.rt.gcObjects.count
        run("for (var i = 0; i < \(n); i++) __f(i);")
        let growth = ctx.rt.gcObjects.count - before
        run("delete globalThis.__f;")
        return growth
    }

    private func withContext(_ f: (JeffJSContext) throws -> Void) rethrows {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        try f(ctx)
        ctx.free()
        rt.free()
    }

    func testBuiltinsDoNotLeakObjects() {
        withContext { ctx in
            let cases: [(String, String)] = [
                ("propertyIsEnumerable", "function(i){ var o = {a: {}}; Object.prototype.propertyIsEnumerable.call(o, 'a'); }"),
                ("getOwnPropertyDescriptors", "function(i){ Object.getOwnPropertyDescriptors({a: 1, b: {}}); }"),
                ("defineProperties(gOPDs)", "function(i){ Object.defineProperties({}, Object.getOwnPropertyDescriptors({a: {}})); }"),
                ("fromEntries", "function(i){ Object.fromEntries([['a', {}], ['b', 2]]); }"),
                ("for-of Set break", "function(i){ for (var x of new Set([{}, 2])) break; }"),
                ("destructure Map", "function(i){ var [[k, v]] = new Map([[{}, 2], [3, 4]]); }"),
                ("join objects", "function(i){ [{}, {}].join(); }"),
                ("object + string", "function(i){ var o = {toString: function(){ return 'x' + i; }}; var s = o + ''; }"),
                ("template of object", "function(i){ var s = `${[1, {}]}`; }"),
                ("relational on objects", "function(i){ var a = {valueOf: function(){ return i; }}; var b = a < {valueOf: function(){ return 2; }}; }"),
                ("loose equality", "function(i){ var a = {valueOf: function(){ return 'x'; }}; var b = a == 'x'; }"),
                ("Symbol.toPrimitive", "function(i){ var a = {[Symbol.toPrimitive]: function(h){ return h + i; }}; var s = '' + a; }"),
            ]
            for (name, body) in cases {
                // A per-call leak shows up as >= 2000; a few objects of one-time
                // state (a lazily materialised builtin property, the last
                // settled promise) are not leaks.
                XCTAssertLessThan(objectGrowth(ctx, body), 10, "\(name) leaked objects")
            }
        }
    }

    func testAsyncFunctionDoesNotLeakItsCapability() {
        withContext { ctx in
            XCTAssertLessThan(objectGrowth(ctx, "async function(i){ await 1; return {}; }", n: 500), 10,
                              "a suspending async call leaked its resolving functions")
        }
    }

    /// A string produced by ToString of an object must be owned by its one
    /// holder only (the leaks left one extra count per conversion).
    func testConversionResultsAreNotOverRetained() {
        withContext { ctx in
            let v = ctx.eval(input: """
                var o = { toString: function () { return 'abc'.repeat(20); } };
                var holder = { a: '' + o, b: `${o}`, c: [o, o].join('-'), d: String([1, 2]) + '' };
                holder
                """, filename: "<conv>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            for k in ["a", "b", "c", "d"] {
                let s = ctx.getPropertyStr(obj: v, name: k)
                XCTAssertEqual(s.stringBase?.refCount, 2, "holder.\(k): one count for the holder, one for this read")
                s.freeValue()
            }
            v.freeValue()
        }
    }

    /// The "object-literal property value keeps one count too many" note in
    /// RuntimeTeardownReleaseTests: a top-level literal's values.
    func testTopLevelLiteralValueCount() {
        withContext { ctx in
            let v = ctx.eval(input: "var keep = { list: [], s: 'abc'.repeat(50), t: 'x' + 1 }; keep",
                             filename: "<lit>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            for k in ["s", "t"] {
                let s = ctx.getPropertyStr(obj: v, name: k)
                XCTAssertEqual(s.stringBase?.refCount, 2, "keep.\(k): one count for keep, one for this read")
                s.freeValue()
            }
            v.freeValue()
        }
    }

    func testCompactLayouts() {
        // The point of the change: fail loudly if a field sneaks back in.
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSObject.self), 96)
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSString.self), 64)
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSStringRope.self), 64)
        XCTAssertEqual(MemoryLayout<JeffJSPropStorage>.size, 16)
        // Each at or under a malloc size class boundary (xzone: 16-byte steps
        // to 128, then 32): 192, 256, 112, 64, 64.
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSObjectAux.self), 192)
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSFunctionBytecodeCompiled.self), 256)
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSShape.self), 112)
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSAtomStruct.self), 64)
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSLazyFunctionInfo.self), 64)
        XCTAssertEqual(MemoryLayout<JeffJSICEntry>.stride, 40)
        XCTAssertEqual(MemoryLayout<JeffJSClosureVar>.stride, 16)
        // An entry is a transition or a prototype hit: the shared shape slot
        // answers only for its kind.
        let p = UnsafeRawPointer(bitPattern: 0x1000)!, q = UnsafeRawPointer(bitPattern: 0x2000)!
        let t = JeffJSICEntry(shapePtr: p, pc: 7, propOffset: 3, writable: true, nextShapePtr: q)
        XCTAssertEqual(t.nextShapePtr, q); XCTAssertNil(t.holderShapePtr); XCTAssertEqual(t.pc, 7); XCTAssertEqual(t.propOffset, 3)
        let h = JeffJSICEntry(shapePtr: p, pc: 9, propOffset: 1, writable: false, holderPtr: p, holderShapePtr: q)
        XCTAssertEqual(h.holderShapePtr, q); XCTAssertNil(h.nextShapePtr)
    }

    /// Plain objects never allocate the side box; a prototype read goes
    /// through the shape.
    func testPlainObjectsHaveNoSideBox() {
        withContext { ctx in
            let v = ctx.eval(input: "var p = {x: 1}; var o = Object.create(p); o.y = 2; [{a: 1}, o, Object.create(null)]",
                             filename: "<aux>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            for i in 0..<3 {
                let e = ctx.getPropertyUInt32(obj: v, index: UInt32(i))
                XCTAssertNil(e.toObject()?.aux, "element \(i) allocated a side box")
                e.freeValue()
            }
            let o = ctx.getPropertyUInt32(obj: v, index: 1)
            let x = ctx.getPropertyStr(obj: o, name: "x")
            XCTAssertEqual(x.toInt32(), 1)
            o.freeValue()
            v.freeValue()
        }
    }

    /// Recycled closures (jeffJS_recycleFunction) come back with nothing of
    /// their previous life: captures, name/length, `this`, prototype, props.
    func testRecycledClosuresAreFresh() {
        withContext { ctx in
            let v = ctx.eval(input: """
                var out = [];
                function mk(i) { var c = i; var f = function named() { return c; }; return f; }
                for (var r = 0; r < 3; r++) {
                    for (var i = 0; i < 300; i++) { var f = mk(i); f.name; f.length; f(); }
                }
                var o = { k: 7, m: function () { return (() => this.k)(); } };
                var g = mk(41);
                var h = function (a, b) { return a + b; };
                var arrow = (x) => x * 2;
                out.push(g(), g.name, g.length, h.name, h.length, h(1, 2), arrow.name, arrow(4), o.m(),
                         typeof g.prototype, Object.getOwnPropertyNames(arrow).join(','),
                         Object.keys(g).length, g.hasOwnProperty('x'));
                out.join('|')
                """, filename: "<pool>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            XCTAssertEqual(ctx.toSwiftString(v), "41|named|0|h|2|3|arrow|8|7|object|length,name|0|false")
            v.freeValue()
        }
    }

    /// Arrays keep their elements in the inline element store; the `.array`
    /// payload is a view of it, so an array has no side box. Recycled arrays
    /// (literal churn) come back empty.
    func testArraysHaveNoSideBoxAndStayCorrect() {
        withContext { ctx in
            let v = ctx.eval(input: """
                var out = [];
                for (var r = 0; r < 2000; r++) { var t = [r, r + 1, r + 2]; t.push(r); }
                var a = [1, 2, 3]; a.push(4); a[6] = 7; delete a[1];
                var b = []; var c = Array.from({length: 3}, (_, i) => i * 2);
                var d = [5, 6]; d.length = 1;
                out.push(a.length, 1 in a, a[6], JSON.stringify(a), b.length, c.join(','), d.join(','),
                         [].concat(a, c).length, Object.keys(c).join(','), [3, 1, 2].sort().join(''));
                [out.join('|'), a, b, c, d]
                """, filename: "<arrays>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            let s = ctx.getPropertyUInt32(obj: v, index: 0)
            XCTAssertEqual(ctx.toSwiftString(s), "7|false|7|[1,null,3,4,null,null,7]|0|0,2,4|5|10|0,1,2|123")
            s.freeValue()
            for i in 1...4 {
                let e = ctx.getPropertyUInt32(obj: v, index: UInt32(i))
                XCTAssertNil(e.toObject()?.aux, "array \(i) allocated a side box")
                if case .array = e.toObject()!.payload {} else { XCTFail("array \(i) has no .array payload view") }
                e.freeValue()
            }
            v.freeValue()
        }
    }
}
