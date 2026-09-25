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
    // --teardown exercises context/runtime free (the path the test suite runs
    // between groups); the CLI otherwise leaves it to process exit.
    if args.contains("--teardown") { env.teardown() }
    return status
}
exit(status)
