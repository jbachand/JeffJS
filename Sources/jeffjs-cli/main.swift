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
