// MetalGCVarRefTests.swift
// JeffJS — the GPU collector's view of detached closure var-refs.
//
// The Metal kernels are a port of the CPU collector's trial-decrement / scan /
// collect passes, with one thing the CPU side does that has no kernel:
// `gcSeedVarRefs`. Nothing maintains a var-ref's refcount — closures hold them
// through ARC and `JeffJSVarRef.init` leaves it at 1 however many closures
// capture the slot — so the CPU collector zeroes them and then skips them in
// the trial decrement. `gc_trial_decref` decrements every edge it is handed,
// so the snapshot has to seed a var-ref with its in-degree instead. Seeding it
// with the header's 1 sent any var-ref shared by two or more closures negative
// in phase 1 and freed it while those closures were still live; the variable
// they captured then read `undefined` forever, which is how a page whose
// module object was captured by ~30 closures rendered blank.
//
// Only the host app ever ran these kernels: a SwiftPM consumer has no Metal
// default library, so the CLI and this suite take the CPU path unless
// JEFFJS_GC_METAL=1 points the loader at the package's resource bundle.
//
//   swift test -c release --filter MetalGCVarRef

#if canImport(Metal)
import XCTest
@testable import JeffJS

final class MetalGCVarRefTests: XCTestCase {

    /// Every var-ref node in the GPU snapshot is seeded with the number of
    /// edges pointing at it, so phase 1 lands it on exactly zero — the state
    /// `gcSeedVarRefs` + the CPU trial decrement leave it in.
    func testVarRefNodesSeededWithInDegree() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }

        // Three closures over one variable, and a named function expression
        // that recurses by name over another: one var-ref with an in-degree of
        // three (the shape that used to be collected) and one with one.
        let src = """
            var holders = (function () {
                var n = { tag: "NS" };
                return [function () { return n.tag; },
                        function () { return n.tag; },
                        function () { return n.tag; }];
            })();
            var walk = (function () {
                var outer = 7;
                return function g(d) { return d ? g(d - 1) : outer; };
            })();
            holders[0]() + walk(4)
            """
        let r = ctx.eval(input: src, filename: "<metalgc>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(r.isException, "setup threw")
        r.freeValue()

        let snap = JeffJSMetalGC.shared.buildGraphSnapshot(rt: rt)
        XCTAssertEqual(snap.nodes.count, rt.gcObjects.count)
        var inDegree = [Int32](repeating: 0, count: snap.nodes.count)
        for idx in snap.children where Int(idx) < inDegree.count { inDegree[Int(idx)] += 1 }

        var varRefNodes = 0
        var sharedSeen = false
        for (i, u) in rt.gcObjects.enumerated() {
            guard i < snap.nodes.count,
                  u.takeUnretainedValue().gcObjType == .varRef else { continue }
            varRefNodes += 1
            XCTAssertEqual(snap.nodes[i].refCount, inDegree[i],
                           "var-ref node \(i) seeded with \(snap.nodes[i].refCount), in-degree \(inDegree[i])")
            if inDegree[i] >= 2 { sharedSeen = true }
        }
        // Without these the assertions above could pass vacuously.
        XCTAssertGreaterThan(varRefNodes, 0, "no detached var-refs on the GC list")
        XCTAssertTrue(sharedSeen, "no var-ref with two or more holders")
    }

    /// A var-ref whose holders are all live must survive a collection: seeded
    /// at in-degree N, phase 1 takes it to 0 and the rescue pass puts back one
    /// count per surviving holder. This is the invariant the GPU path shares
    /// with the CPU one, checked here through the CPU collector.
    func testSharedVarRefSurvivesCollection() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let setup = """
            var holders = (function () {
                var n = { tag: "NS" };
                return [function () { return n.tag; }, function () { return n.tag; }];
            })();
            // transient closures over the same slot, dropped immediately: the
            // var-ref's in-degree outlives some of its holders
            (function () {
                var n2 = { tag: "T" };
                var tmp = [function () { return n2.tag; }, function () { return n2.tag; }];
                return tmp[0]();
            })();
            var keep = []; for (var i = 0; i < 8000; i++) keep.push({ i: i });
            holders[0]()
            """
        let first = ctx.eval(input: setup, filename: "<metalgc-cpu>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(first.isException, "setup threw")
        first.freeValue()

        runGC(rt)
        runGC(rt)

        let after = ctx.eval(input: "holders[0]() + \"/\" + holders[1]()",
                             filename: "<metalgc-cpu>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(after.isException, "post-GC read threw")
        XCTAssertEqual(ctx.toSwiftString(after), "NS/NS")
        after.freeValue()
    }
}
#endif
