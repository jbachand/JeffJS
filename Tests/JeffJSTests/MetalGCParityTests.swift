// MetalGCParityTests.swift
// JeffJS — the GPU collector must free exactly what the CPU collector frees.
//
// The app runs the Metal cycle collector above `gc.metalThreshold` (5 000
// objects); the CLI and this suite ran only the CPU one, because a SwiftPM
// consumer has no Metal default library and `shouldUseMetalGC` quietly
// returned false. A whole class of divergence was therefore invisible — the
// var-ref seeding bug that rendered a page blank lived for a day behind a
// green suite.
//
// Every case below runs the *same* script twice in two fresh runtimes, one
// pinned to each collector, and compares what survives a forced collection
// plus what the surviving heap still says when JS reads it back. A collector
// that frees too much shows up in the read-back; one that frees too little
// shows up in the live count.
//
//   swift test -c release --filter MetalGC
//
// The whole suite can also be re-run on the GPU collector:
//   JEFFJS_GC_METAL=1 swift test -c release
// which drops the crossover to zero (see JeffJSMetalGC.effectiveThreshold).

#if canImport(Metal)
import XCTest
@testable import JeffJS

final class MetalGCParityTests: XCTestCase {

    /// What a collection leaves behind, from both sides: the collector's own
    /// counters and the heap as JS can still see it.
    private struct Outcome: Equatable {
        var live: Int
        var readback: String
    }

    /// Pin one collector for the duration of `body`. `Int.max` can never be
    /// exceeded by an object count, so it is "CPU only"; `0` is "GPU for every
    /// collection".
    private func pinned<T>(metal: Bool, _ body: () throws -> T) rethrows -> T {
        let saved = JeffJSMetalGC.thresholdOverride
        JeffJSMetalGC.thresholdOverride = metal ? 0 : Int.max
        defer { JeffJSMetalGC.thresholdOverride = saved }
        return try body()
    }

    /// The kernels are compiled out of the package resource bundle, which only
    /// happens while a collector choice is pinned (a host app links them into
    /// its own default library instead).
    private var metalReady: Bool { pinned(metal: true) { JeffJSMetalGC.shared.isAvailable } }

    /// Build the heap, force two collections (the second one catches anything
    /// the first freed into a new zero), then read the heap back.
    private func run(_ setup: String, _ readback: String, metal: Bool) -> Outcome {
        pinned(metal: metal) {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            defer { ctx.free(); rt.free() }
            let r = ctx.eval(input: setup, filename: "<gc-parity-setup>",
                             evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let e = ctx.getException()
                let msg = ctx.toSwiftString(e) ?? "?"
                e.freeValue()
                return Outcome(live: -1, readback: "setup threw: \(msg)")
            }
            r.freeValue()
            runGC(rt)
            runGC(rt)
            let live = rt.gcObjects.count
            let back = ctx.eval(input: readback, filename: "<gc-parity-read>",
                                evalFlags: JS_EVAL_TYPE_GLOBAL)
            var text: String
            if back.isException {
                let e = ctx.getException()
                text = "readback threw: " + (ctx.toSwiftString(e) ?? "?")
                e.freeValue()
            } else {
                text = ctx.toSwiftString(back) ?? "<unstringable>"
            }
            back.freeValue()
            return Outcome(live: live, readback: text)
        }
    }

    /// The parity assertion. `liveSlack` is there because the GPU run's own
    /// automatic collections fire at slightly different moments (the rescue
    /// wavefront can leave one generation of freshly-dead objects for the next
    /// pass), so what must match exactly is the *read-back* — over-freeing is
    /// never within slack — while the live count is allowed a small constant.
    private func assertParity(_ name: String, setup: String, readback: String,
                              liveSlack: Int = 8,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard metalReady else {
            // Better a loud failure than a green run that exercised the CPU
            // collector twice.
            XCTFail("\(name): Metal collector unavailable — parity unverified", file: file, line: line)
            return
        }
        let before = JeffJSMetalGC.shared.completedRuns
        let cpu = run(setup, readback, metal: false)
        let gpu = run(setup, readback, metal: true)
        let ran = JeffJSMetalGC.shared.completedRuns - before
        XCTAssertGreaterThan(ran, 0, "\(name): the GPU collector never ran (declined "
            + "\(JeffJSMetalGC.shared.declinedRuns) time(s))", file: file, line: line)
        XCTAssertEqual(gpu.readback, cpu.readback,
                       "\(name): the two collectors leave different heaps", file: file, line: line)
        XCTAssertFalse(cpu.readback.contains("threw"),
                       "\(name): CPU read-back failed: \(cpu.readback)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(gpu.live - cpu.live), liveSlack,
            "\(name): CPU left \(cpu.live) live objects, GPU left \(gpu.live)",
            file: file, line: line)
        print("[gc-parity] \(name): cpu live=\(cpu.live) gpu live=\(gpu.live) "
              + "readback=\(cpu.readback.prefix(60))")
    }

    // MARK: - The heap shapes

    func testSelfCycles() {
        assertParity("self-cycles", setup: """
            var keep = [];
            for (var i = 0; i < 6000; i++) { var o = {}; o.self = o; o.i = i; }
            for (var j = 0; j < 200; j++) { var k = {}; k.self = k; k.j = j; keep.push(k); }
            """, readback: "keep.length + \":\" + keep[199].self.j + \":\" + (keep[0].self === keep[0])")
    }

    func testReactStyleTree() {
        assertParity("react-tree", setup: """
            function node(depth, parent) {
                var n = { tag: "div", depth: depth, children: [], parent: parent || null };
                n.onClick = function () { return n.depth; };
                if (depth > 0) { n.children.push(node(depth - 1, n), node(depth - 1, n)); }
                return n;
            }
            var live = node(9, null);
            for (var p = 0; p < 4; p++) { var dead = node(9, null); dead = null; }
            """, readback: "live.children[0].parent === live ? live.onClick() + \":\" "
                         + "+ live.children[1].children[0].onClick() : \"detached\"")
    }

    func testSharedVarRefClosures() {
        // The bug of record: one var-ref captured by many closures.
        assertParity("shared-var-refs", setup: """
            function mkModule() {
                var ns = { tag: "NS", n: 0 };
                var fns = [];
                for (var i = 0; i < 30; i++) fns.push(function () { return ns.tag + ns.n; });
                var rec = function walk(d) { return d ? walk(d - 1) : ns.tag; };
                return { fns: fns, rec: rec };
            }
            var mods = [];
            for (var m = 0; m < 400; m++) { var mod = mkModule(); if (m % 100 === 0) mods.push(mod); }
            """, readback: "mods.length + \":\" + mods[0].fns[0]() + \":\" + mods[3].fns[29]() "
                         + "+ \":\" + mods[2].rec(12)")
    }

    func testWeakRefAndFinalizationRegistry() {
        assertParity("weakref", setup: """
            var reg = new FinalizationRegistry(function () {});
            var kept = {}; kept.self = kept;
            var keptRef = new WeakRef(kept);
            reg.register(kept, "kept");
            var deadRef = (function () { var d = {}; d.self = d; reg.register(d, "dead"); return new WeakRef(d); })();
            var filler = []; for (var i = 0; i < 6000; i++) { var t = {}; t.self = t; }
            """, readback: "(keptRef.deref() === kept) + \":\" + (deadRef.deref() === undefined)")
    }

    func testMapAndSetWithObjectKeys() {
        assertParity("map-set-object-keys", setup: """
            var live = new Map(); var liveSet = new Set();
            var k0 = { id: 0 }; live.set(k0, { v: "zero", back: k0 }); liveSet.add(k0);
            for (var i = 1; i < 3000; i++) {
                var k = { id: i }; var v = { v: i, back: k };
                var m = new Map(); m.set(k, v); var s = new Set(); s.add(v);
                if (i === 1) { live.set(k, v); liveSet.add(v); }
            }
            var wm = new WeakMap(); wm.set(k0, "w0");
            """, readback: "live.size + \":\" + live.get(k0).v + \":\" + live.get(k0).back.id "
                         + "+ \":\" + liveSet.has(k0) + \":\" + wm.get(k0)")
    }

    func testPromiseReactionCycles() {
        assertParity("promise-reactions", setup: """
            var resolvers = [];
            var keptP = new Promise(function (res) { resolvers.push(res); });
            keptP.self = keptP;
            var chain = keptP.then(function () { return keptP; });
            for (var i = 0; i < 3000; i++) {
                var p = new Promise(function (res) { resolvers.push(res); });
                p.self = p;
                p.then(function () { return p; }).catch(function () {});
                if (i % 500 === 0) resolvers[resolvers.length - 1](i);
            }
            """, readback: "(keptP.self === keptP) + \":\" + (typeof chain.then) + \":\" + resolvers.length")
    }

    func testClassHierarchies() {
        // `var`, not `class`: a lexical top-level declaration is not visible
        // from the separate eval the read-back runs in.
        assertParity("class-hierarchy", setup: """
            var Base = class { constructor() { this.b = 1; } who() { return "base"; } };
            var Mid = class extends Base { constructor() { super(); this.m = 2; } who() { return "mid" + super.who(); } };
            var liveInst = new Mid();
            for (var i = 0; i < 2500; i++) {
                class A { constructor() { this.x = i; } m() { return this.x; } }
                class B extends A { constructor() { super(); this.y = i; } m() { return super.m() + this.y; } }
                var tmp = new B(); tmp = null;
            }
            """, readback: "liveInst.who() + \":\" + liveInst.b + liveInst.m + \":\" "
                         + "+ (liveInst instanceof Base)")
    }

    func testGeneratorsAndSuspendedAsync() {
        assertParity("suspended-frames", setup: """
            function* counter(tag) { var box = { tag: tag }; var i = 0; while (true) { yield box.tag + (i++); } }
            var liveGen = counter("live"); liveGen.next();
            var pending = [];
            async function waiter(tag) { var box = { tag: tag }; await pending[pending.length - 1]; return box.tag; }
            var hold = new Promise(function () {});
            pending.push(hold);
            var liveAsync = waiter("async");
            for (var i = 0; i < 2000; i++) {
                var g = counter("g" + i); g.next(); g = null;
                var a = waiter("a" + i); a = null;
            }
            """, readback: "liveGen.next().value + \":\" + liveGen.next().value + \":\" + (typeof liveAsync.then)")
    }

    func testMappedArgumentsAndBoundFunctions() {
        assertParity("arguments-and-bound", setup: """
            function mk(x, y) { var a = arguments; return { args: a, get: function () { return x + y; } }; }
            var live = mk(20, 22);
            function target(a, b) { return this.base + a + b; }
            var liveBound = target.bind({ base: 100 }, 1);
            for (var i = 0; i < 3000; i++) {
                var t = mk(i, i); t.args = null; t = null;
                var b = target.bind({ base: i }, i); b = null;
            }
            """, readback: "live.get() + \":\" + live.args[0] + \":\" + live.args.length + \":\" + liveBound(2)")
    }

    func testProxies() {
        assertParity("proxies", setup: """
            var liveTarget = { v: 7 };
            var liveHandler = { get: function (t, k) { return k === "doubled" ? t.v * 2 : t[k]; } };
            var liveProxy = new Proxy(liveTarget, liveHandler);
            liveTarget.p = liveProxy;   // proxy <-> target cycle
            var revoked = [];
            for (var i = 0; i < 2500; i++) {
                var t = { v: i }; var h = { get: function (tt, k) { return tt[k]; } };
                var p = new Proxy(t, h); t.p = p;
                if (i % 500 === 0) { var r = Proxy.revocable({ v: i }, h); r.revoke(); revoked.push(r); }
                p = null; t = null;
            }
            """, readback: "liveProxy.doubled + \":\" + liveProxy.v + \":\" + (liveTarget.p === liveProxy) "
                         + "+ \":\" + revoked.length")
    }

    func testDetachedVarRefInArgumentsSlot() {
        // A mapped `arguments` slot and a closure share one var-ref; the GPU
        // snapshot reaches it through JeffJSPropertyExtra.varRef.
        assertParity("arguments-varref-sharing", setup: """
            function f(x) { var a = arguments; return [a, function () { return x; }, function () { x = x + 1; return x; }]; }
            var live = f(41);
            for (var i = 0; i < 4000; i++) { var t = f(i); t[0] = null; t = null; }
            """, readback: "live[1]() + \":\" + live[2]() + \":\" + live[1]()")
    }

    func testTypedArraysAndBuffers() {
        assertParity("typed-arrays", setup: """
            var liveBuf = new ArrayBuffer(64);
            var liveView = new Uint8Array(liveBuf); liveView[0] = 9; liveView.owner = liveBuf;
            for (var i = 0; i < 3000; i++) {
                var b = new ArrayBuffer(16); var v = new Float64Array(b); v.owner = b; b.view = v;
                v = null; b = null;
            }
            """, readback: "liveView[0] + \":\" + liveView.byteLength + \":\" + (liveView.owner === liveBuf)")
    }

    /// DOM wrappers built by `JeffJSEnvironment`: a JS object with a native
    /// side, reachable through parent/child links the collector has to walk
    /// like any other property edge.
    @MainActor
    func testDOMWrappersThroughEnvironment() {
        guard metalReady else { XCTFail("Metal collector unavailable"); return }
        func build(metal: Bool) -> String {
            pinned(metal: metal) {
                let env = JeffJSEnvironment()
                defer { env.teardown() }
                let setup = """
                    var root = document.createElement("div"); root.id = "root";
                    document.body.appendChild(root);
                    root.onclick = function () { return root.id; };
                    for (var i = 0; i < 3000; i++) {
                        var d = document.createElement("span");
                        var c = document.createElement("b");
                        d.appendChild(c); c.owner = d; d.self = d;
                        d.handler = function () { return d; };
                        d = null; c = null;
                    }
                    var live = document.createElement("p"); live.textContent = "kept";
                    root.appendChild(live); live.back = root;
                    1
                    """
                if case .exception(let m) = env.eval(setup, filename: "<dom>") { return "setup threw: \(m)" }
                env.runGC(); env.runGC()
                switch env.eval("""
                    root.onclick() + ":" + document.getElementById("root").childNodes.length
                      + ":" + (live.back === root) + ":" + live.textContent
                    """, filename: "<dom-read>") {
                case .success(let v): return v ?? "undefined"
                case .exception(let m): return "readback threw: \(m)"
                }
            }
        }
        let cpu = build(metal: false)
        let gpu = build(metal: true)
        XCTAssertEqual(gpu, cpu, "dom-wrappers: the two collectors leave different heaps")
        XCTAssertFalse(cpu.contains("threw"), "dom-wrappers: \(cpu)")
        print("[gc-parity] dom-wrappers: \(cpu)")
    }

    // MARK: - The flags the CPU path honours

    /// `JEFFJS_GC_OFF` means "reference counting only". The GPU path has to
    /// refuse the same way the CPU path does, or the flag answers a different
    /// question depending on the heap size.
    func testMetalPathHonoursGCOff() {
        guard metalReady else { XCTFail("Metal collector unavailable"); return }
        let saved = jeffJS_gcDisable
        jeffJS_gcDisable = true
        defer { jeffJS_gcDisable = saved }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let r = ctx.eval(input: "for (var i = 0; i < 2000; i++) { var o = {}; o.self = o; } 1",
                         filename: "<gc-off>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        r.freeValue()
        let before = rt.gcObjects.count
        let freedBefore = rt.gcCyclesFreed
        pinned(metal: true) {
            XCTAssertFalse(JeffJSMetalGC.shared.runMetalGC(rt: rt),
                           "the GPU collector collected with JEFFJS_GC_OFF set")
            runGC(rt)
        }
        XCTAssertEqual(rt.gcCyclesFreed, freedBefore, "cycles were freed with the collector off")
        XCTAssertEqual(rt.gcObjects.count, before, "the GC list shrank with the collector off")
    }

    /// A collection the GPU abandons must free nothing at all and hand the heap
    /// back intact, so `runGC` can finish it on the CPU. Forced here by capping
    /// the rescue wavefront far below the graph's depth.
    func testAbandonedCollectionFreesNothing() {
        guard metalReady else { XCTFail("Metal collector unavailable"); return }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        // A long parent chain: the wavefront needs one iteration per link, so
        // the default 100-iteration cap cannot reach the end of it.
        let r = ctx.eval(input: """
            var head = null;
            for (var i = 0; i < 4000; i++) { head = { next: head, i: i }; }
            var probe = head.i;
            """, filename: "<deep-chain>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(r.isException)
        r.freeValue()
        let declinedBefore = JeffJSMetalGC.shared.declinedRuns
        let live = rt.gcObjects.count
        let freed = rt.gcCyclesFreed
        pinned(metal: true) {
            _ = JeffJSMetalGC.shared.runMetalGC(rt: rt)
        }
        // Either it converged (fine) or it declined — and if it declined, not
        // one object may have been freed.
        if JeffJSMetalGC.shared.declinedRuns > declinedBefore {
            XCTAssertEqual(rt.gcObjects.count, live, "an abandoned collection still freed objects")
            XCTAssertEqual(rt.gcCyclesFreed, freed, "an abandoned collection still counted cycles")
        }
        // And the chain is intact either way.
        let back = ctx.eval(input: "head.i + \":\" + head.next.next.i",
                            filename: "<deep-chain>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertEqual(ctx.toSwiftString(back), "3999:3997")
        back.freeValue()
    }
}
#endif
