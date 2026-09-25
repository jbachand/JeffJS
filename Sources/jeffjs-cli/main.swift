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
    env.flushBytecodeCache()
    // --teardown exercises context/runtime free (the path the test suite runs
    // between groups); the CLI otherwise leaves it to process exit.
    if args.contains("--teardown") { env.teardown() }
    return status
}
exit(status)
