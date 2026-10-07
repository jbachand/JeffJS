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

// --page=<fixture dir>: a saved page (rn_fixtures layout: index.html, manifest.json,
// r/<files>): its HTML becomes the document and its scripts run in document
// order (classic: the fixture file or inline text; module: the app's dumped
// bundle `<file>.bundle.js` from --bundles=<dir>, else skipped). Network is
// stubbed (fetch/XHR never settle) so runs are reproducible.
let pageDir = args.first(where: { $0.hasPrefix("--page=") }).map { String($0.dropFirst(7)) }
let bundlesDir = args.first(where: { $0.hasPrefix("--bundles=") }).map { String($0.dropFirst(10)) }
guard !paths.isEmpty || pageDir != nil else {
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
    var pageURL: (url: URL, ua: String)? = nil
    if let dir = pageDir,
       let d = FileManager.default.contents(atPath: dir + "/manifest.json"),
       let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        pageURL = (URL(string: (m["final_url"] as? String) ?? (m["url"] as? String) ?? "about:blank")!,
                   (m["user_agent"] as? String) ?? "Mozilla/5.0")
    }
    let env = pageURL.map { JeffJSEnvironment(configuration: .init(baseURL: $0.url, userAgent: $0.ua)) } ?? JeffJSEnvironment()
    let quietConsole = args.contains("--quiet")
    env.onConsoleMessage = { _, msg in if !quietConsole { print(msg); fflush(stdout) } }
    let mallocAtStart = cliMallocInUse()
    // Test hooks: force a collection and read the collector's counters.
    env.registerNativeFunction("__gc") { _ in env.runGC(); return nil }
    env.registerNativeFunction("__gcStats") { _ in
        let s = env.gcStatistics
        return "{\"runs\":\(s.runs),\"cyclesFreed\":\(s.cyclesFreed),\"liveObjects\":\(s.liveObjects),\"heapBytes\":\(s.heapBytes),\"threshold\":\(s.threshold)}"
    }
    env.registerNativeFunction("__mallocInUse") { _ in String(cliMallocInUse()) }
    // Lazy JSON payloads (JeffJSLazyPayload.swift): counters, and eviction.
    // __lazyEvict runs with JS on the stack: tests only (hosts evict at idle).
    env.registerNativeFunction("__lazyStats") { _ in env.lazyPayloadStatsJSON }
    env.registerNativeFunction("__lazyEvict") { _ in String(env.evictLazyPayloads()) }
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
    if let dir = pageDir {
        let r = cliRunPage(env: env, dir: dir, bundlesDir: bundlesDir)
        let g = env.gcStatistics
        print("[page] scripts=\(r.ran) errors=\(r.errors) skipped=\(r.skipped) ms=\(Int(r.ms)) gcRuns=\(g.runs) cyclesFreed=\(g.cyclesFreed) live=\(g.liveObjects)")
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
    // --glue-evals=N: N distinct host-glue evals (filename <native-event>, the
    // app's per-event dispatch text), timed on this thread.
    if let g = args.first(where: { $0.hasPrefix("--glue-evals=") }).flatMap({ Int($0.dropFirst(13)) }) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let salt = Int(t0 * 1000) % 1_000_000   // distinct texts per run
        for i in 0..<g {
            _ = env.eval("if (typeof globalThis.__nativeDispatchAnimationEvent === 'function') { globalThis.__nativeDispatchAnimationEvent(null, 'animationiteration', 'pulse\(salt)', \(i).25); } var __nativeEventTarget = null;",
                         filename: "<native-event>")
        }
        print(String(format: "[glue] %d evals %.1f ms (%.3f ms each)", g, (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                     (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(max(g, 1))))
    }
    // --heap-report: collect (3 full GCs), then the live JS heap: GC-list
    // objects, malloc bytes in use since the environment was created, and
    // the per-object average (all engine bytes / live JS objects).
    if args.contains("--heap-report") {
        // --lazy-evict: what a memory-pressure pass gives back first (lazy
        // JSON payload objects still exactly what their spans say).
        if args.contains("--lazy-evict") { print("[lazy] evicted=\(env.evictLazyPayloads())") }
        // What the app's idle tick does within ~1 s: queued cache writes land
        // and the live scripts' text moves to the entry mappings.
        env.flushBytecodeCache()
        for _ in 0..<3 { env.runGC() }
        let g = env.gcStatistics
        let delta = cliMallocInUse() - mallocAtStart
        print(String(format: "[heap] liveObjects=%d mallocDelta=%.1fMB perObject=%.0fB footprint=%.1fMB",
                     g.liveObjects, Double(delta) / 1_048_576, Double(delta) / Double(max(g.liveObjects, 1)), cliFootprintMB()))
        print(env.heapHistogram())
        print("[lazy] " + env.lazyPayloadSummary)
        print("[heap] icUnmappedStores=\(JeffJSEnvironment.inlineCacheUnmappedStores)")
        if args.contains("--roots") { print(env.rootReport()) }
        if args.contains("--big") { print(bigBlockReport(minBytes: 256 * 1024)) }
        if args.contains("--string-dups") { print(JeffJSHeapDebug.stringDuplicateReport(liveInstances(className: "JeffJS.JeffJSString"))) }
        if args.contains("--bodies") {
            print(JeffJSHeapDebug.functionBodyReport(liveInstances(className: "JeffJS.JeffJSFunctionBytecodeCompiled")))
        }
        if args.contains("--mem-census") { print(MallocCensus.report(label: "heap", top: 40)) }
        if args.contains("--orphans") {
            print(orphanReport(className: "JeffJS.JeffJSString") { JeffJSHeapDebug.describeString(at: $0) })
            print(orphanReport(className: "JeffJS.JeffJSObject") { JeffJSHeapDebug.describeObject(at: $0) })
        }
    }
    if args.contains("--cache-stats") {
        print("[cache] " + env.bytecodeCacheDescription)
        let p = JeffJSPrecompiler.stats
        print(String(format: "[precompile] compiled=%d ms=%.0f srcKB=%d jsThreadWaitMs=%.0f",
                     p.compiled, p.ms, p.sourceBytes / 1024, JeffJSEnvironment.precompileWaitMs))
    }
    env.flushBytecodeCache()
    // --teardown exercises context/runtime free (the path the test suite runs
    // between groups); the CLI otherwise leaves it to process exit.
    if args.contains("--teardown") || args.contains("--teardown-report") {
        if args.contains("--teardown-report") {
            print(String(format: "[teardown] before: gcObjects=%d footprint=%.1fMB", env.gcStatistics.liveObjects, cliFootprintMB()))
        }
        env.teardown()
    }
    return status
}
// --teardown-report (with --page / scripts): after the environment's teardown and release, what
// the freed runtime left behind — engine instances still alive (nothing should be: the app frees a
// page's runtime at every navigation) and the strings among them that nothing points to.
if args.contains("--teardown-report") {
    MainActor.assumeIsolated {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        var counts: [String] = []
        for c in ["JeffJSString", "JeffJSObject", "JeffJSObjectAux", "JeffJSFunctionBytecodeCompiled",
                  "JeffJSFunctionBytecodeCold", "JeffJSShape", "JeffJSVarRef", "JeffJSAtomStruct",
                  "JeffJSContext", "JeffJSRuntime"] {
            counts.append("\(c)=\(liveInstances(className: "JeffJS." + c).count)")
        }
        print(String(format: "[teardown] after: footprint=%.1fMB mallocInUse=%.1fMB ", cliFootprintMB(),
                     Double(cliMallocInUse()) / 1_048_576) + counts.joined(separator: " "))
        print(orphanReport(className: "JeffJS.JeffJSString") { JeffJSHeapDebug.describeString(at: $0) })
        print(orphanReport(className: "JeffJS.JeffJSObject") { JeffJSHeapDebug.describeObject(at: $0) })
        if let rc = args.first(where: { $0.hasPrefix("--refs=") }) { print(referrerReport(className: String(rc.dropFirst(7)))) }
        var hist: [String: Int] = [:]
        for a in liveInstances(className: "JeffJS.JeffJSObject") {
            if let p = UnsafeRawPointer(bitPattern: a), let d = JeffJSHeapDebug.describeObject(at: p) {
                let key = d.replacingOccurrences(of: #" props=\d+"#, with: "", options: .regularExpression)
                hist[key, default: 0] += 1
            }
        }
        for (k, n) in hist.sorted(by: { $0.value > $1.value }).prefix(15) { print("[teardown]   object \(n) x \(k)") }
    }
}
exit(status)

/// Bytes in use in every malloc zone.
func cliMallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

/// --page: run a saved page's scripts in document order (see the flag).
@MainActor
func cliRunPage(env: JeffJSEnvironment, dir: String, bundlesDir: String?) -> (ran: Int, errors: Int, skipped: Int, ms: Double) {
    guard let html = try? String(contentsOfFile: dir + "/index.html", encoding: .utf8) else { return (0, 0, 0, 0) }
    // file -> original URL (error messages / filenames as the app sees them)
    var urlOf: [String: String] = [:]
    if let d = FileManager.default.contents(atPath: dir + "/manifest.json"),
       let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let res = m["resources"] as? [String: [String: Any]] {
        for (u, v) in res { if let f = v["file"] as? String { urlOf[f] = u } }
    }
    env.loadDocumentHTML(html)
    _ = env.eval("""
        (function(){
          var never = function(){ return new Promise(function(){}); };
          globalThis.fetch = never;
          if (globalThis.XMLHttpRequest) { XMLHttpRequest.prototype.send = function(){}; }
          if (globalThis.navigator) { try { navigator.sendBeacon = function(){ return true; }; } catch (e) {} }
        })();
        """, filename: "<page-prelude>")
    var scripts: [DOMNode] = []
    func walk(_ n: DOMNode) {
        if n.lowercasedTagName == "script" { scripts.append(n) }
        for c in n.children { walk(c) }
    }
    walk(env.document)
    var ran = 0, errors = 0, skipped = 0
    let t0 = CFAbsoluteTimeGetCurrent()
    let verbose = ProcessInfo.processInfo.environment["JEFFJS_PAGE_VERBOSE"] != nil
    // JEFFJS_PAGE_TIMES=1: wall time of every script's eval on stderr.
    let times = ProcessInfo.processInfo.environment["JEFFJS_PAGE_TIMES"] != nil
    // The scripts' final text and name, in document order (nil: skipped).
    var items: [(code: String, name: String)?] = []
    for s in scripts {
        let type = (s.attributeValue("type") ?? "").lowercased()
        let isModule = type == "module"
        if !(type.isEmpty || type.contains("javascript") || type.contains("ecmascript") || isModule) { items.append(nil); continue }
        var src: String? = nil
        var name = "<inline>"
        if let file = s.attributeValue("src") {
            name = urlOf[file] ?? file
            if isModule {
                let base = (file as NSString).lastPathComponent
                if let bd = bundlesDir { src = try? String(contentsOfFile: bd + "/" + base + ".bundle.js", encoding: .utf8) }
            } else {
                src = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8)
            }
        } else if !isModule {
            src = s.rawTextDescendants
        }
        guard let code = src, !code.isEmpty else { items.append(nil); continue }
        items.append((code, name))
    }
    // --precompile: the app's off-main compile on arrival (JeffJSPrecompiler):
    // a background thread compiles every script (the exact text and name the
    // eval below gets) into the disk tier in document order while this
    // thread runs them; a script whose precompile is in flight waits for it,
    // then maps it.
    if CommandLine.arguments.contains("--precompile") {
        let jobs = items.compactMap { $0 }
        let th = Thread {
            for job in jobs { _ = JeffJSPrecompiler.precompileScript(job.code, filename: job.name) }
        }
        th.stackSize = 16 << 20
        th.start()
    }
    for item in items {
        guard let (code, name) = item else { skipped += 1; continue }
        let ts = CFAbsoluteTimeGetCurrent()
        let r = env.eval(code, filename: name)
        if times {
            FileHandle.standardError.write(String(format: "[page-time] %8.1f ms  %7d chars  %@\n",
                (CFAbsoluteTimeGetCurrent() - ts) * 1000, code.utf16.count, String(name.suffix(90))).data(using: .utf8)!)
        }
        ran += 1
        if case .exception(let msg) = r {
            errors += 1
            if verbose { FileHandle.standardError.write("[page] \(name): \(msg.prefix(200))\n".data(using: .utf8)!) }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return (ran, errors, skipped, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
}

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
