// ThreadRuntimeTests.swift
// JeffJS — runtimes running JS at the same time on different threads
// (`JeffJSThreadRuntime`, Web Workers). Each thread that owns a runtime of its
// own calls `enter()` first, so `JeffJSGCObjectHeader.activeRuntime` is its own
// and objects created there belong to its runtime.
//
//   swift test --filter ThreadRuntimeTests

import XCTest
@testable import JeffJS

final class ThreadRuntimeTests: XCTestCase {

    /// Allocation-heavy work touching objects, arrays, closures, strings, Map,
    /// promises (microtasks) and the GC; returns a checksum string.
    private let script = """
        (function () {
          var sum = 0, s = '', m = new Map(), out = [];
          for (var i = 0; i < 20000; i++) {
            var o = { i: i, a: [i, i + 1, { k: 'x' + i }], f: function (y) { return y + i; } };
            sum += o.f(o.a[1]) - o.a[0];
            if (i % 97 === 0) { s += o.a[2].k; m.set('k' + i, o); }
            if (i % 1000 === 0) m.clear();
          }
          Promise.resolve(sum).then(function (v) { out.push(v); return v * 2; }).then(function (v) { out.push(v); });
          globalThis.__out = out;
          return sum + ':' + s.length;
        })()
        """

    private func runOnce(_ ctx: JeffJSContext) -> String {
        let v = ctx.eval(input: script, filename: "<thread-runtime>", evalFlags: 0)
        defer { v.freeValue() }
        if v.isException { return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?") }
        _ = ctx.rt.executePendingJobs()
        let r = ctx.eval(input: "__out.join(',')", filename: "<thread-runtime-out>", evalFlags: 0)
        defer { r.freeValue() }
        return (ctx.toSwiftString(v) ?? "?") + "|" + (ctx.toSwiftString(r) ?? "?")
    }

    private var expected: String {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let r = runOnce(ctx)
        rt.free()
        return r
    }

    /// Two worker threads with their own runtimes and this thread's (shared
    /// `activeRuntime`) run the same allocation-heavy script concurrently,
    /// collecting garbage as they go; every result equals the serial one and
    /// every runtime frees cleanly on its own thread.
    func testConcurrentRuntimesOnOwnThreads() {
        let want = expected
        XCTAssertFalse(want.hasPrefix("!"), want)
        let workers = 3
        var results = [String](repeating: "", count: workers)
        let lock = NSLock()
        let done = DispatchGroup()
        for w in 0..<workers {
            done.enter()
            let th = Thread {
                JeffJSThreadRuntime.enter()
                XCTAssertTrue(JeffJSThreadRuntime.isOwnThread)
                let rt = JeffJSRuntime()
                let ctx = rt.newContext()
                XCTAssertTrue(JeffJSGCObjectHeader.activeRuntime === rt, "the thread's own active runtime")
                var last = ""
                for _ in 0..<4 { last = self.runOnce(ctx); rt.runGC() }
                let o = ctx.newPlainObject()
                let owned = o.isObject && (o.toObject()?.ownerRuntime === rt)
                o.freeValue()
                rt.free()
                XCTAssertNil(JeffJSGCObjectHeader.activeRuntime)
                JeffJSThreadRuntime.leave()
                lock.lock(); results[w] = owned ? last : "!owner"; lock.unlock()
                done.leave()
            }
            th.stackSize = 16 << 20
            th.start()
        }
        // Meanwhile, this thread keeps using the process-wide active runtime.
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        var mine = ""
        for _ in 0..<4 { mine = runOnce(ctx); rt.runGC() }
        XCTAssertFalse(JeffJSThreadRuntime.isOwnThread)
        XCTAssertTrue(JeffJSGCObjectHeader.activeRuntime === rt)
        done.wait()
        rt.free()
        XCTAssertEqual(mine, want)
        for r in results { XCTAssertEqual(r, want) }
        XCTAssertEqual(jeffJS_threadRuntimesActive.load(ordering: .relaxed), 0)
    }
}
