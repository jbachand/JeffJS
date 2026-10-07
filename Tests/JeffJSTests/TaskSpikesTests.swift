// TaskSpikesTests.swift
// JeffJS — per-task memory spikes (perf/task-spikes, 2026-10-07; React Natively
// PERF_PLAN.md "Watch status 2026-10-07"): homedepot pages died on the Apple Watch
// from bursts inside one task that the app's 250 ms footprint sampler saw too late.
//  * Interpreter value buffers: every non-inline activation took a pooled 8 192-slot
//    (64 KB) buffer, so a native↔JS recursion 2 900 levels deep (a stack-depth probe
//    through `f.call`) held 180 MB. They now come from one segmented stack per
//    runtime; deep claims are sized to the frame.
//  * Allocation trigger: big strings / stack segments / ArrayBuffers count toward
//    `gc.bytesSinceGCThreshold` (a collection at the next object allocation) and
//    `gc.bytesSinceHookThreshold` (the host's memory hook, called from the allocation).
//
//   swift test -c release --filter TaskSpikesTests

import XCTest
@testable import JeffJS

final class TaskSpikesTests: XCTestCase {

    private func withContext(_ body: (JeffJSRuntime, JeffJSContext) -> Void) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        body(rt, ctx)
        ctx.free(); rt.free()
    }

    private func evalBool(_ ctx: JeffJSContext, _ src: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let r = ctx.eval(input: src, filename: "<task-spikes>", evalFlags: 0)
        defer { r.freeValue() }
        if r.isException { ctx.getException().freeValue(); XCTFail("exception", file: file, line: line); return false }
        return r.isBool && r.toBool()
    }

    /// A native↔JS recursion to the engine's depth limit: the value stack in use at the
    /// deepest point stays near the frames' own size (was 64 KB per activation).
    func testDeepNativeRecursionUsesFrameSizedClaims() {
        guard JeffJSRuntime.segmentedStack else { return }
        withContext { rt, ctx in
            var deepest = 0, depthSeen = 0
            let global = ctx.getGlobalObject()
            ctx.setPropertyFunc(obj: global, name: "__probe", fn: { _, _, args in
                deepest = max(deepest, rt.interpStackUsedSlots)
                depthSeen += 1
                return .undefined
            }, length: 1)
            global.freeValue()
            XCTAssertTrue(evalBool(ctx, """
                var d = 0; function f(n) { d = n; __probe(n); return f.call(null, n + 1) }
                var ok = false; try { f(0) } catch (e) { ok = e instanceof RangeError }
                ok && d > 20
                """))
            XCTAssertGreaterThan(depthSeen, 20)
            let activations = depthSeen + 1
            let bytes = deepest * MemoryLayout<JeffJSValue>.stride
            // Old scheme: ≥ 64 KB per activation. New: ≤ 16 big claims, then 8 KB, then frame-sized.
            XCTAssertLessThan(bytes, 16 * 65536 + activations * 8192 + 65536,
                              "value stack at the deepest point: \(bytes / 1024) KB for \(activations) activations")
            XCTAssertLessThan(bytes, activations * 65536 / 2)
            // Everything given back afterwards.
            XCTAssertEqual(rt.interpStackUsedSlots, 0)
            // ... the segments beyond one current + the spares are freed, and the spares
            // go at memory pressure.
            let seg = rt.vsSegmentSlots * MemoryLayout<JeffJSValue>.stride
            XCTAssertLessThanOrEqual(rt.interpStackSegmentBytes, (1 + JeffJSRuntime.vsMaxSpares) * seg)
            rt.trimInterpStack()
            XCTAssertLessThanOrEqual(rt.interpStackSegmentBytes, seg)
        }
    }

    /// An interrupt raised deep inside an inline-call chain whose frames overflowed
    /// their caller's claim (own claims above the activation's): the activation's exit
    /// gives back every claim (the epilogue only releases the current frame's buffer).
    func testInterruptFromInlineChainReleasesTheStack() {
        guard JeffJSRuntime.segmentedStack else { return }
        withContext { rt, ctx in
            var calls = 0
            rt.setInterruptHandler { _ in calls += 1; return calls > 2 }
            let r = ctx.eval(input: """
                function r(n) { var a = n, b = n + 1, c = n + 2, d = n + 3;
                  if (n === 0) { var t = 0; for (;;) { t++ } }
                  return r(n - 1) + a + b + c + d }
                r(2500)
                """, filename: "<interrupt-deep>", evalFlags: 0)
            XCTAssertTrue(r.isException)
            r.freeValue(); ctx.getException().freeValue()
            XCTAssertEqual(rt.interpStackUsedSlots, 0, "claims left on the value stack after the interrupt")
            rt.setInterruptHandler(nil)
            XCTAssertTrue(evalBool(ctx, "function s(n){ return n === 0 ? 0 : n + s(n - 1) } s(2000) === 2001000"))
            XCTAssertEqual(rt.interpStackUsedSlots, 0)
        }
    }

    /// Cyclic garbage holding 1 MB strings: the object-count trigger never fires (a few
    /// hundred objects); the allocation trigger collects every few megabytes.
    func testAllocationTriggerCollectsStringsHeldByCycles() {
        withContext { rt, ctx in
            rt.allocGCThreshold = 8 << 20
            let runs0 = rt.gcRuns
            XCTAssertTrue(evalBool(ctx, """
                var big = 'x'.repeat(1 << 20), o;
                for (var i = 0; i < 120; i++) { o = {}; o.self = o; o.s = (big + i).slice(1) }
                o.s.length === (1 << 20) + 2
                """))
            XCTAssertGreaterThanOrEqual(rt.allocGCRuns, 6, "allocation-triggered collections")
            XCTAssertGreaterThanOrEqual(rt.gcRuns - runs0, 6)
            XCTAssertLessThan(rt.allocBytesSinceGC, 32 << 20)
        }
        // Off: no allocation-triggered collection.
        withContext { rt, ctx in
            rt.allocGCThreshold = 0
            XCTAssertTrue(evalBool(ctx, """
                var big = 'x'.repeat(1 << 20), o;
                for (var i = 0; i < 20; i++) { o = {}; o.self = o; o.s = (big + i).slice(1) }
                true
                """))
            XCTAssertEqual(rt.allocGCRuns, 0)
        }
    }

    /// The host hook is called from the allocation, every `allocHookThreshold` bytes —
    /// also inside a single native call — and a stop it asks for ends the script at the
    /// next interrupt check.
    func testMemoryHookCalledFromAllocationAndStops() {
        withContext { rt, ctx in
            rt.allocHookThreshold = 4 << 20
            var hookCalls = 0
            rt.memoryHook = { _ in hookCalls += 1; return false }
            // Inside one native call: a single 16 MB string (one call: the threshold is
            // crossed once per allocation, however far).
            XCTAssertTrue(evalBool(ctx, "var s = 'abcdefgh'.repeat(1 << 21); s.length === 1 << 24"))
            XCTAssertEqual(hookCalls, 1, "one hook call for one 16 MB allocation")
            // Sixteen 1 MB strings: every 4 MB.
            XCTAssertTrue(evalBool(ctx, "var a = []; for (var i = 0; i < 16; i++) a.push(s.slice(i, i + (1 << 20))); a.length === 16"))
            XCTAssertGreaterThanOrEqual(hookCalls, 1 + 4, "hook calls for 16 × 1 MB of string payload")

            // A stop request ends the running loop.
            var calls2 = 0
            rt.memoryHook = { _ in calls2 += 1; return calls2 >= 3 }
            let r = ctx.eval(input: """
                var keep = [], big = 'z'.repeat(1 << 20);
                for (var i = 0; i < 100000; i++) { keep.push((big + i).slice(1)) }
                """, filename: "<hook-stop>", evalFlags: 0)
            XCTAssertTrue(r.isException, "the memory hook's stop must end the script")
            r.freeValue(); ctx.getException().freeValue()
            XCTAssertGreaterThanOrEqual(calls2, 3)
            XCTAssertLessThan(calls2, 200, "stopped soon after the hook asked")
            // The next task runs.
            rt.memoryHook = nil
            XCTAssertTrue(evalBool(ctx, "keep.length > 0 && keep.length < 100000"))
        }
    }
}
