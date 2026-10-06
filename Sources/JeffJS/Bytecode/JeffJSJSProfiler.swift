// JeffJSJSProfiler.swift
//
// JS-level sampling profiler for engine-speed work (build with
// `-Xswiftc -DJEFFJS_JSPROF`, or `OTHER_SWIFT_FLAGS='$(inherited) -DJEFFJS_JSPROF'`
// in an app build; nothing is compiled in otherwise). A background thread
// raises `jeffJS_profTick` every `JEFFJS_JSPROF_US` µs (default 1000); the
// interpreter's dispatchers check it per opcode and record the running
// function (+ its source line) and the JS call chain. Time spent in a native
// builtin is charged to the JS line that called it. Dumped to stdout when a
// runtime is freed and at exit (`[jsprof] …` lines).

import Foundation

#if JEFFJS_JSPROF
nonisolated(unsafe) var jeffJS_profTick: Bool = false
nonisolated(unsafe) private var jeffJS_profStarted = false
nonisolated(unsafe) private var jeffJS_profSelf: [String: Int] = [:]
nonisolated(unsafe) private var jeffJS_profLine: [String: Int] = [:]
nonisolated(unsafe) private var jeffJS_profIncl: [String: Int] = [:]
nonisolated(unsafe) private var jeffJS_profTotal = 0
nonisolated(unsafe) var jeffJS_icStats = [Int](repeating: 0, count: 8)
@inline(__always) func jeffJS_icCount(_ k: Int) { jeffJS_icStats[k] &+= 1 }
nonisolated(unsafe) private var jeffJS_profNames: [ObjectIdentifier: (JeffJSFunctionBytecode, String)] = [:]

private func jeffJS_profName(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode) -> String {
    let id = ObjectIdentifier(fb)
    if let e = jeffJS_profNames[id], e.0 === fb { return e.1 }
    var name = fb.nameAtom != 0 ? ctx.atomToSwiftString(fb.nameAtom) : ""
    if name.isEmpty { name = fb.inferredName ?? "<anon>" }
    var file = fb.fileName.map { $0.toSwiftString() } ?? "?"
    if file == "?", let c = fb as? JeffJSFunctionBytecodeCompiled {
        file = c.cachedDebugFilename ?? (c.debugFilenameAtom != 0 ? ctx.atomToSwiftString(c.debugFilenameAtom) : "?")
    }
    if let slash = file.lastIndex(of: "/") { file = String(file[file.index(after: slash)...]) }
    if file.count > 48 { file = String(file.prefix(48)) }
    let s = "\(name) \(file):\(fb.lineNum):\(fb.colNum)"
    jeffJS_profNames[id] = (fb, s)   // keeps fb alive: profiling builds only
    return s
}

private func jeffJS_profStart() {
    jeffJS_profStarted = true
    let us = UInt32(ProcessInfo.processInfo.environment["JEFFJS_JSPROF_US"].flatMap { UInt32($0) } ?? 1000)
    let t = Thread {
        while true { usleep(us); jeffJS_profTick = true }
    }
    t.qualityOfService = .userInteractive
    t.start()
    atexit { jeffJS_profDump(label: "exit") }
}

/// Called by a dispatcher when `jeffJS_profTick` is set.
@inline(never)
func jeffJS_profSample(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode, _ pc: Int) {
    jeffJS_profTick = false
    jeffJS_profTotal += 1
    let leaf = jeffJS_profName(ctx, fb)
    jeffJS_profSelf[leaf, default: 0] += 1
    var line = 0
    if let c = fb as? JeffJSFunctionBytecodeCompiled { line = c.lineForPC(pc) }
    jeffJS_profLine[leaf + " @\(line)", default: 0] += 1
    var seen = Set<String>([leaf])
    jeffJS_profIncl[leaf, default: 0] += 1
    var f = ctx.currentFrame
    var depth = 0
    while let fr = f, depth < 400 {
        if let o = fr.curFunc.obj, let cfb = o.fbFast {
            let n = jeffJS_profName(ctx, cfb)
            if seen.insert(n).inserted { jeffJS_profIncl[n, default: 0] += 1 }
        }
        f = fr.prevFrame
        depth += 1
    }
}

/// Lazily starts the ticker (first call from callInternal).
@inline(__always)
func jeffJS_profEnsureStarted() {
    if !jeffJS_profStarted { jeffJS_profStart() }
}

func jeffJS_profDump(label: String) {
    guard jeffJS_profTotal > 0 else { return }
    var out = "[jsprof] \(label) samples=\(jeffJS_profTotal)\n[jsprof] == self (function)\n"
    for (k, v) in jeffJS_profSelf.sorted(by: { $0.value > $1.value }).prefix(45) {
        out += String(format: "[jsprof] %6d %5.1f%% ", v, Double(v) * 100 / Double(jeffJS_profTotal)) + k + "\n"
    }
    out += "[jsprof] == self (line)\n"
    for (k, v) in jeffJS_profLine.sorted(by: { $0.value > $1.value }).prefix(45) {
        out += String(format: "[jsprof] %6d %5.1f%% ", v, Double(v) * 100 / Double(jeffJS_profTotal)) + k + "\n"
    }
    out += "[jsprof] == inclusive\n"
    for (k, v) in jeffJS_profIncl.sorted(by: { $0.value > $1.value }).prefix(60) {
        out += String(format: "[jsprof] %6d %5.1f%% ", v, Double(v) * 100 / Double(jeffJS_profTotal)) + k + "\n"
    }
    let ic = jeffJS_icStats
    out += "[jsprof] ic named: main hit=\(ic[0]) miss=\(ic[1]) trace hit=\(ic[2]); keyed miss get=\(ic[4]) put=\(ic[5])\n"
    jeffJS_icStats = [Int](repeating: 0, count: 8)
    print(out)
    fflush(stdout)
    jeffJS_profSelf = [:]; jeffJS_profLine = [:]; jeffJS_profIncl = [:]; jeffJS_profTotal = 0
}
#endif
