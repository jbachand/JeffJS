// jeffjs-cli — minimal command-line runner for benchmarking and debugging.
//
//   swift run -c release jeffjs-cli path/to/script.js [--result]
//
// Console output goes to stdout. With --result the completion value of the
// script is printed as well. Exit status 1 on an uncaught exception.

import Foundation
import JeffJS

let args = CommandLine.arguments.dropFirst()
let paths = args.filter { !$0.hasPrefix("--") }

// --boot-bench[=N] [--jfbc=path]: engine boot cost, best of N (default 10):
// bare JeffJSRuntime() / newContext(), a full JeffJSEnvironment (context,
// stdlib, bridges, built-in polyfills), and the app's precompiled polyfill
// bundle run in that environment. Times in ms on stdout.
if let bb = args.first(where: { $0.hasPrefix("--boot-bench") }) {
    let n = Int(bb.split(separator: "=").last.flatMap { Int($0) }.map(String.init) ?? "") ?? 10
    let jfbc = args.first(where: { $0.hasPrefix("--jfbc=") }).map { String($0.dropFirst(7)) }
    let bundle: [UInt8]? = jfbc.flatMap { FileManager.default.contents(atPath: $0) }.map { [UInt8]($0) }
    if jfbc != nil && bundle == nil { FileHandle.standardError.write("cannot read bundle\n".data(using: .utf8)!); exit(2) }
    let code: Int32 = MainActor.assumeIsolated {
        var bestRt = Double.infinity, bestCtx = Double.infinity, bestEnv = Double.infinity, bestPoly = Double.infinity
        for _ in 0..<max(1, n) {
            let (r, c) = JeffJSEnvironment.measureRuntimeAndContextInit()
            bestRt = min(bestRt, r); bestCtx = min(bestCtx, c)
            let t0 = CFAbsoluteTimeGetCurrent()
            let env = JeffJSEnvironment()
            let t1 = CFAbsoluteTimeGetCurrent()
            bestEnv = min(bestEnv, (t1 - t0) * 1000)
            if let b = bundle {
                if let err = env.evalPrecompiledBundle(b) {
                    FileHandle.standardError.write("bundle failed: \(err)\n".data(using: .utf8)!)
                    return 1
                }
                bestPoly = min(bestPoly, (CFAbsoluteTimeGetCurrent() - t1) * 1000)
            }
        }
        print(String(format: "runtime %.2f ms\tcontext %.2f ms\tenvironment %.2f ms", bestRt, bestCtx, bestEnv)
              + (bundle != nil ? String(format: "\tbundle %.2f ms", bestPoly) : ""))
        return 0
    }
    exit(code)
}

guard !paths.isEmpty else {
    FileHandle.standardError.write("usage: jeffjs-cli <script.js>... [--result]\n".data(using: .utf8)!)
    exit(2)
}
let showResult = args.contains("--result")
// --parse-only: parse + compile each file without running it (no bytecode
// cache), best of --repeat=N (default 5), times on stdout. --bc-hash also
// prints an FNV-1a hash of the serialized bytecode (compiler identity check).
let parseOnly = args.contains("--parse-only") || args.contains("--bc-hash")
let bcHash = args.contains("--bc-hash")
let repeatCount = args.first(where: { $0.hasPrefix("--repeat=") }).flatMap { Int($0.dropFirst(9)) } ?? (bcHash ? 1 : 5)

// Several files are evaluated in order in ONE environment (shared globals),
// which mirrors how the conformance runner feeds a group of snippets to a
// single context.
let status: Int32 = MainActor.assumeIsolated {
    let env = JeffJSEnvironment()
    env.onConsoleMessage = { _, msg in print(msg); fflush(stdout) }
    // Test hooks: force a collection and read the collector's counters.
    env.registerNativeFunction("__gc") { _ in env.runGC(); return nil }
    env.registerNativeFunction("__gcStats") { _ in
        let s = env.gcStatistics
        return "{\"runs\":\(s.runs),\"cyclesFreed\":\(s.cyclesFreed),\"liveObjects\":\(s.liveObjects),\"heapBytes\":\(s.heapBytes),\"threshold\":\(s.threshold)}"
    }
    var status: Int32 = 0
    // --eager: compile every function body up front (lazy compilation off).
    if args.contains("--eager") { env.lazyFunctions = false }
    let lazyStats = args.contains("--lazy-stats")
    defer { if lazyStats { FileHandle.standardError.write((env.lazyCompileSummary + "\n").data(using: .utf8)!) } }
    if parseOnly {
        for path in paths {
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
                return 2
            }
            var bestParse = Double.infinity, bestCompile = Double.infinity, bestTotal = Double.infinity
            var hash: UInt64? = nil
            for _ in 0..<max(1, repeatCount) {
                let r = env.compileOnly(src, filename: path, hashBytecode: bcHash)
                if let e = r.error {
                    print("\(path)\tERROR\t\(e)")
                    status = 1
                    break
                }
                bestParse = min(bestParse, r.parseMs)
                bestCompile = min(bestCompile, r.compileMs)
                bestTotal = min(bestTotal, r.parseMs + r.compileMs)
                hash = r.bytecodeHash
            }
            if bcHash {
                print("\(path)\t\(hash.map { String($0, radix: 16) } ?? "-")")
            } else if bestTotal.isFinite {
                print(String(format: "%@\tparse %.1f ms\tcompile %.1f ms\ttotal %.1f ms",
                             (path as NSString).lastPathComponent, bestParse, bestCompile, bestTotal))
            }
        }
        return status
    }
    for path in paths {
        guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            return 2
        }
        if paths.count > 1 { FileHandle.standardError.write("[eval] \(path)\n".data(using: .utf8)!) }
        switch env.eval(src, filename: path) {
        case .success(let value):
            if showResult, let value, value != "undefined" { print(value) }
        case .exception(let message):
            FileHandle.standardError.write("Uncaught \(message)\n".data(using: .utf8)!)
            status = 1
        }
    }
    // --settle=S: run the main run loop for S seconds after the scripts, so
    // their timers fire and with them the engine's idle tick (collections,
    // compile.lazyDropAfterMs reclaim); a sample line every --sample=N s.
    // --reclaim-cycles=N: then N explicit reclaim cycles, timed (with
    // --aggressive: memory-pressure cycles, which drop every body).
    // --burst: then dispatch a burst of UI events at the page (scroll, touch,
    // click ... on window/document/200 elements) and report what it compiled.
    if let settle = args.first(where: { $0.hasPrefix("--settle=") }).flatMap({ Double($0.dropFirst(9)) }) {
        let sample = args.first(where: { $0.hasPrefix("--sample=") }).flatMap { Double($0.dropFirst(9)) } ?? 5
        let t0 = CFAbsoluteTimeGetCurrent()
        @MainActor func line(_ tag: String) {
            let g = env.gcStatistics, l = env.lazyCounters
            let ic = JeffJSEnvironment.inlineCacheStats
            print(String(format: "[settle] %@ t=%.0fs footprint=%.1fMB heap=%dKB objects=%d compiled=%d compileMs=%.0f dropped=%d reclaimMs=%.1f icTables=%d icKB=%d",
                         tag, CFAbsoluteTimeGetCurrent() - t0, cliFootprintMB(), g.heapBytes / 1024, g.liveObjects,
                         l.compiled, l.compileMs, l.dropped, l.reclaimMs, ic.tables, ic.bytes / 1024))
            fflush(stdout)
        }
        line("start")
        var next = sample
        while CFAbsoluteTimeGetCurrent() - t0 < settle {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            if CFAbsoluteTimeGetCurrent() - t0 >= next { line("sample"); next += sample }
        }
        line("settled")
        // --mem-census: malloc census by class (MallocCensus.swift, the app's copy).
        if args.contains("--mem-census") { print(MallocCensus.report(label: "settled", top: 30)) }
        if let rc = args.first(where: { $0.hasPrefix("--refs=") }) { print(referrerReport(className: String(rc.dropFirst(7)))) }
        let cycles = args.first(where: { $0.hasPrefix("--reclaim-cycles=") }).flatMap { Int($0.dropFirst(17)) } ?? 0
        for i in 0..<cycles {
            let c0 = CFAbsoluteTimeGetCurrent()
            let r = args.contains("--aggressive") ? env.reclaimLazyBodiesNow() : env.reclaimIdleLazyBodies()
            print(String(format: "[reclaim] cycle %d: %.2f ms marked=%d dropped=%d (%dKB bytecode)",
                         i, (CFAbsoluteTimeGetCurrent() - c0) * 1000, r.marked, r.dropped, r.bytes / 1024))
        }
        if cycles > 0 { line("reclaimed") }
        if args.contains("--burst") {
            let before = env.lazyCounters
            let b0 = CFAbsoluteTimeGetCurrent()
            let r = env.eval(cliBurstJS(), filename: "<burst>")
            let wall = (CFAbsoluteTimeGetCurrent() - b0) * 1000
            let after = env.lazyCounters
            if case .success(let n) = r { print("[burst] events=\(n ?? "?")") } else { print("[burst] \(r)") }
            print(String(format: "[burst] wall=%.1fms compiled+=%d compileMs+=%.1f", wall,
                         after.compiled - before.compiled, after.compileMs - before.compileMs))
            line("burst")
        }
    }
    env.flushBytecodeCache()
    // --teardown exercises context/runtime free (the path the test suite runs
    // between groups); the CLI otherwise leaves it to process exit.
    if args.contains("--teardown") { env.teardown() }
    return status
}
exit(status)

/// Process footprint (what jetsam counts), in MB.
func cliFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// --burst: UI events a user's first scroll / tap would send, at window,
/// document, body and up to 200 elements. Returns how many were dispatched.
/// (A function: main.swift globals initialise in statement order.)
func cliBurstJS() -> String { """
(function(){
  var types = ['scroll','resize','touchstart','touchmove','touchend','pointerdown','pointerup','mousedown','mouseup','click','mouseover','mousemove','focus','blur','keydown','keyup','visibilitychange','wheel'];
  var els = [window, document, document.documentElement, document.body];
  try { els = els.concat(Array.prototype.slice.call(document.querySelectorAll('a,button,input,div,span,li,img')).slice(0, 200)); } catch (e) {}
  var n = 0;
  for (var i = 0; i < els.length; i++) {
    if (!els[i] || !els[i].dispatchEvent) continue;
    for (var j = 0; j < types.length; j++) {
      try { els[i].dispatchEvent(new Event(types[j], { bubbles: true, cancelable: true })); n++; } catch (e) {}
    }
  }
  return n;
})()
""" }
