// EngineThreadingRuleTests.swift
// JeffJS — the runtime threading rule (JeffJSThreadCheck.swift): one thread
// runs JS on a runtime at a time, and nothing else touches its heap meanwhile.
//
// * `testEngineClassesAreNonisolated` — the regression test for the idle-GC
//   mark crash (2026-09-30). The React Natively app compiles these sources
//   with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; there a class without an
//   explicit deinit gets an *isolated* deinit, so an engine object released
//   on the app's polyfill thread was destroyed later on the main thread —
//   while the polyfill thread was still running JS. JeffJSPropertyExtra's
//   deinit released a detached var-ref whose deinit swap-removed it from
//   `rt.gcObjects` concurrently with the polyfill thread's appends, and the
//   next collection's mark phase dereferenced a freed header (SIGSEGV/SIGBUS
//   in `markChildren`, ~1 launch in 10 on reddit). SwiftPM builds use no
//   default isolation, so no test can observe the hop here; this checks the
//   rule that prevents it instead: every class of the engine's heap, compiler
//   and builtins is declared `nonisolated` (destroyed on the thread that
//   releases it). A class that must stay on the main actor says `@MainActor`.
// * `testSecondThreadHeapMutationIsReported` — the Debug ownership check: a
//   GC-list mutation from another thread while one thread is inside `eval`
//   is reported (it traps outside tests).
// * `testVerifierAcceptsHealthyHeap` — the JEFFJS_GC_VERIFYROOTS list walk has
//   no false positives on a heap that went through collections.

import Foundation
import XCTest
@testable import JeffJS

final class EngineThreadingRuleTests: XCTestCase {

    /// Directories whose classes are created and released on the JS thread.
    /// (DOM/, Environment/ and Quantum/ hold host bridges that are main-actor
    /// by design in the app: their `Task {}` bodies rely on inheriting it.)
    static let heapDirectories = ["Core", "Builtins", "Bytecode", "Parser", "RegExp",
                                  "StdLib", "Utils", "Config", "Unicode"]

    func testEngineClassesAreNonisolated() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JeffJS", isDirectory: true)
        let decl = try NSRegularExpression(pattern:
            #"^\s*((?:(?:public|private|fileprivate|internal|open|final|nonisolated)\s+)*)class\s+([A-Za-z_]\w*)"#)
        let notTypes: Set<String> = ["func", "var", "let", "subscript", "override", "static"]
        var offenders: [String] = []
        var checked = 0
        for dir in Self.heapDirectories {
            let root = sources.appendingPathComponent(dir, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    let ns = line as NSString
                    guard let m = decl.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                    let name = ns.substring(with: m.range(at: 2))
                    if notTypes.contains(name) { continue }
                    let mods = ns.substring(with: m.range(at: 1)).split(separator: " ").map(String.init)
                    let prev = i > 0 ? lines[i - 1] : ""
                    if line.contains("@MainActor") || prev.contains("@MainActor") || line.contains("@JeffJSHostActor") || prev.contains("@JeffJSHostActor") { continue }
                    checked += 1
                    if !mods.contains("nonisolated") {
                        offenders.append("\(dir)/\(url.lastPathComponent):\(i + 1): class \(name)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50, "found too few class declarations; is the source path right? \(sources.path)")
        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) engine class(es) without `nonisolated`. Under the app's default MainActor \
            isolation their deinit runs on the main thread when the JS thread releases them, concurrently \
            with JS (idle-GC mark crash, JeffJSThreadCheck.swift). Declare them `nonisolated` \
            (or `@MainActor` if they really are main-thread objects):
            \(offenders.joined(separator: "\n"))
            """)
    }

    func testSecondThreadHeapMutationIsReported() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        // On in Debug builds and under JEFFJS_GC_VERIFYROOTS=1; forced here so
        // release test runs exercise it too.
        let savedCheck = jeffJS_threadCheck
        jeffJS_threadCheck = true
        defer { jeffJS_threadCheck = savedCheck }

        let inside = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let global = ctx.getGlobalObject()
        ctx.setPropertyFunc(obj: global, name: "__parkInsideEval", fn: { _, _, _ in
            inside.signal()
            release.wait()
            return .undefined
        }, length: 0)
        global.freeValue()

        var reports: [String] = []
        let lock = NSLock()
        jeffJS_threadViolationHandler = { msg in lock.lock(); reports.append(msg); lock.unlock() }
        defer { jeffJS_threadViolationHandler = nil }

        let jsThread = Thread {
            let r = ctx.eval(input: "var o = {a: 1}; __parkInsideEval(); o.a", filename: "<owner>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            r.freeValue()
            release.signal()   // reuse as "done"
        }
        jsThread.stackSize = 8 << 20
        jsThread.start()
        XCTAssertEqual(inside.wait(timeout: .now() + 10), .success)

        // The JS thread is parked inside eval: this thread now allocates on the
        // runtime (a GC-list add), the way the main thread's deferred deinits
        // unlinked var-refs while the polyfill thread ran.
        let stray = ctx.newObject()
        release.signal()
        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        stray.freeValue()

        lock.lock(); let got = reports; lock.unlock()
        XCTAssertFalse(got.isEmpty, "a GC-list mutation from a second thread during eval was not reported")
        XCTAssertTrue(got.first?.contains("GC list add") ?? false, got.first ?? "")

        // Sequential hand-off (the polyfill thread finishing, then the main
        // thread) is allowed.
        reports.removeAll()
        let r2 = ctx.eval(input: "o.a + 1", filename: "<handoff>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        r2.freeValue()
        XCTAssertTrue(reports.isEmpty, reports.joined(separator: "\n"))
    }

    /// A string's cached atom belongs to the runtime that interned it. The
    /// deinit used to release it in `activeRuntime` — whichever runtime ran
    /// last — so a string of the previous page's runtime (torn down on a
    /// utility queue while the next page runs) decremented an unrelated live
    /// atom of the new runtime.
    func testCachedAtomIsReleasedOnlyInItsRuntime() {
        let rt1 = JeffJSRuntime()
        let ctx1 = rt1.newContext()
        let rt2 = JeffJSRuntime()
        let ctx2 = rt2.newContext()
        defer { ctx2.free(); rt2.free(); ctx1.free(); rt1.free() }
        XCTAssertNotEqual(rt1.atomOwnerID, rt2.atomOwnerID)

        var key: JeffJSString? = JeffJSString(swiftString: "zzThreadRuleKeyA")
        let a1 = rt1.findAtom(jsString: key!)      // caches one reference on the string
        rt1.freeAtom(a1)                            // drop the returned one
        let a2 = rt2.findAtom("zzThreadRuleKeyB")   // a live atom of rt2
        guard Int(a1) < rt2.atomCount, let entry = rt2.atomArray[Int(a1)] else {
            return XCTFail("rt2 has no atom at index \(a1) (runtimes interned differently: \(a1) vs \(a2))")
        }
        _ = rt2.dupAtom(a1)                         // keep it listed whatever happens
        let before = entry.refCount
        weak var dying = key
        JeffJSGCObjectHeader.activeRuntime = rt2    // the next page runs
        key = nil                                   // the old page's string dies
        XCTAssertNil(dying, "the string did not deallocate; the test proves nothing")
        XCTAssertTrue(rt2.atomArray[Int(a1)] === entry)
        XCTAssertEqual(entry.refCount, before, "releasing rt1's string released an atom of rt2")
        rt2.freeAtom(a1)
        rt2.freeAtom(a2)
    }

    func testVerifierAcceptsHealthyHeap() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let src = """
            var keep = [];
            for (var i = 0; i < 3000; i++) {
                var o = { i: i, self: null };
                o.self = o;                                  // cycles for the collector
                (function (k) { keep.push(function () { return k; }); })(o);
                if (i % 3 === 0) keep.pop();
                var m = new Map([[o, i]]);
                Object.defineProperty(o, 'g', { get: function () { return i; }, configurable: true });
                delete o.g;
            }
            keep.length
            """
        let r = ctx.eval(input: src, filename: "<verify>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(r.isException)
        r.freeValue()
        runGC(rt)
        jeffJS_gcVerifyList(rt, "test")   // traps on a bad entry
        XCTAssertGreaterThan(rt.gcObjects.count, 0)
    }
}
