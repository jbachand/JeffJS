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
}
