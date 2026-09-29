// JeffJSLazyReclaim.swift
// Idle reclaim of lazily compiled function bodies: `compile.lazyDropAfterMs`
// (periodic) and `compile.lazyDropOnMemoryPressure` (memory warning / app
// backgrounded).
//
// A lazily compiled function (JeffJSCompiler.compileLazy) that has not run for
// a while gives its body back — bytecode, constant-pool view, inline-cache
// table (512 entries, ~28 KB, plus the shapes and holders it retains), trace
// blocks, pc→line tables — and compiles again on its next call (≈14 µs for a
// small function, less when the script's `-bodies.jfbc` sidecar has it).
//
// Use detection costs nothing on the call path. A function object reaches its
// body through `fbFast`; a reclaim cycle clears `fbFast` on every lazily
// compiled function object it scans, so the next call of that object takes
// callInternal's payload path, which sets `fbFast` again and stamps the body
// (`lazyInfo.touch = rt.lazyReclaimPhase`). createClosure stamps a compiled
// body too, since it sets `fbFast` directly.
//
// The clock: `rt.lazyReclaimPhase` is odd while a cycle runs (P) and even
// between cycles. At the end of cycle P a body is dropped when its last stamp
// is < P - 1: it was not used after the previous cycle's scan cleared it, so
// it has been idle for at least one interval (at most two). Safety — no
// function object may reach a dropped body through `fbFast`: every object of
// the body was scanned in this cycle (fbFast cleared; a stamp of P if it was
// set), and any later `fbFast` store stamps ≥ P. Nothing runs a body while it
// is dropped: slices run only at idle points (no JS on the stack) and a
// dropped body is pending again, so its next call recompiles it first.
//
// Bounded: a cycle is a scan of `rt.gcObjects` from the end to the start
// (robust to what happens to the list between slices: a swap-remove or the
// collector's stable compaction only moves already-scanned entries down, and
// new objects are appended behind the cursor — those were made by
// createClosure, which stamps), then a decide pass over the bodies it listed,
// which also walks their constant pools (nested bodies whose closures are all
// gone are only reachable there). Both run in slices of ≤ 1 ms (≤ 4 ms after
// 100 ms without a tick: nothing is running then), at most one slice per 8 ms
// of idle ticks, so a page with a large heap never parks the thread for a
// whole pass.
//
// Memory pressure: a memory warning, the app going to the background, or a
// kernel memory-pressure event bumps a process-wide generation; each runtime
// with `compile.lazyDropOnMemoryPressure` serves it at its next idle tick with
// one synchronous, aggressive cycle that drops every droppable body (hot ones
// recompile on their next call). The work happens on the JS thread at an idle
// point, never on the notification's thread.
//
// Kept: generators and async functions (suspended activations hold a pc into
// their bytecode) and bodies whose constant pool holds tagged-template objects
// (their identity is observable). A dropped body keeps its constant pool —
// the nested functions' bytecode objects — and compileLazy gives it back to the
// recompiled body (JeffJSCompiler.mergeRetainedCpool), so closures made before
// the drop and after the recompile share their nested functions and nothing
// is leaked or duplicated per cycle.

import Foundation
import Synchronization

/// Memory warnings / backgrounding bump this (any thread); runtimes with
/// `compile.lazyDropOnMemoryPressure` serve each new value once.
let jeffJS_lazyPressureGeneration = Atomic<Int>(0)

/// One reclaim cycle in progress (see the file header).
final class JeffJSLazyReclaimCycle {
    /// This cycle's (odd) reclaim phase.
    let phase: Int
    /// Drop every droppable body regardless of use. Only for a cycle that
    /// runs start to finish with no JS in between (memory pressure).
    let aggressive: Bool
    /// The scan's next index is `cursor - 1` (it walks down to 0).
    var cursor: Int
    /// Bodies listed by the scan / the constant-pool walk, and the decide
    /// pass's position in that list.
    var fbs: [JeffJSFunctionBytecodeCompiled] = []
    var decideIndex = 0
    var scanned = 0
    var dropped = 0
    var droppedBytes = 0
    var droppedICs = 0
    var slices = 0
    var ms: Double = 0
    var maxSliceMs: Double = 0

    init(phase: Int, aggressive: Bool, cursor: Int) {
        self.phase = phase
        self.aggressive = aggressive
        self.cursor = cursor
    }
}

/// Registers the memory-warning / background / memory-pressure observers
/// once per process. UIKit's notification names are used as strings so the
/// engine needs no UIKit; both are posted on the main thread.
enum JeffJSLazyPressureObserver {
    nonisolated(unsafe) private static var source: DispatchSourceMemoryPressure? = nil
    private static let installed: Bool = {
        for name in ["UIApplicationDidReceiveMemoryWarningNotification",
                     "UIApplicationDidEnterBackgroundNotification"] {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil,
                                                   queue: nil) { _ in
                jeffJS_lazyPressureGeneration.add(1, ordering: .relaxed)
            }
        }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { jeffJS_lazyPressureGeneration.add(1, ordering: .relaxed) }
        src.activate()
        source = src
        return true
    }()

    static func installOnce() { _ = installed }

    /// What a memory warning does, for hosts and tests: every runtime with
    /// `compile.lazyDropOnMemoryPressure` reclaims at its next idle tick.
    static func notePressure() { jeffJS_lazyPressureGeneration.add(1, ordering: .relaxed) }
}

extension JeffJSRuntime {
    /// Longest slice, and the least time between two slices, in seconds.
    /// After a quiet stretch (no idle tick for `lazyReclaimQuietGap`: the
    /// page is not running script) a slice may take `lazyReclaimQuietBudget`
    /// instead — a quiet page ticks rarely, and a cycle that only moves 1 ms
    /// per tick would take minutes to finish exactly when reclaiming matters.
    static let lazyReclaimSliceBudget: Double = 0.001
    static let lazyReclaimSliceGap: Double = 0.008
    static let lazyReclaimQuietGap: Double = 0.1
    static let lazyReclaimQuietBudget: Double = 0.004

    /// Idle tick (no JS on the stack): serve a memory-pressure request, start
    /// a cycle once per `lazyDropAfterMs`, and run one slice of it.
    func lazyReclaimTick() {
        guard inlineStackTop == 0 else { return }
        if lazyDropOnMemoryPressure {
            JeffJSLazyPressureObserver.installOnce()
            let gen = jeffJS_lazyPressureGeneration.load(ordering: .relaxed)
            if gen != lazyPressureServed || JeffJSConfig.lazyDropStress {
                lazyPressureServed = gen
                reclaimLazyBodiesNow(aggressive: true)
                return
            }
        }
        guard lazyDropAfterMs > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lazyReclaimCycle == nil {
            guard now - lazyLastReclaim >= Double(lazyDropAfterMs) / 1000 else { return }
            startLazyReclaimCycle(aggressive: false)
        }
        let sinceTick = now - lazyReclaimLastTick
        lazyReclaimLastTick = now
        guard now - lazyReclaimLastSlice >= Self.lazyReclaimSliceGap else { return }
        lazyReclaimLastSlice = now
        let budget = sinceTick >= Self.lazyReclaimQuietGap ? Self.lazyReclaimQuietBudget : Self.lazyReclaimSliceBudget
        runLazyReclaimSlice(deadline: now + budget)
    }

    /// One complete cycle now: finishes the cycle in progress, or runs a new
    /// one start to finish (tests, hosts, measurements). Call with no JS on
    /// the stack. Returns (bodies listed and kept, dropped, bytecode bytes).
    @discardableResult
    func reclaimIdleLazyBodies() -> (marked: Int, dropped: Int, bytes: Int) {
        guard inlineStackTop == 0 else { return (0, 0, 0) }
        if lazyReclaimCycle == nil { startLazyReclaimCycle(aggressive: false) }
        let c = lazyReclaimCycle!
        runLazyReclaimSlice(deadline: .infinity)
        return (c.fbs.count - c.dropped, c.dropped, c.droppedBytes)
    }

    /// Memory pressure: abandon the cycle in progress and drop every
    /// droppable body (`aggressive`) — or only the idle ones — in one
    /// synchronous cycle. Call with no JS on the stack.
    @discardableResult
    func reclaimLazyBodiesNow(aggressive: Bool) -> (marked: Int, dropped: Int, bytes: Int) {
        guard inlineStackTop == 0 else { return (0, 0, 0) }
        if lazyReclaimCycle != nil {
            // Its stamps stay valid; only the phase parity must be restored.
            lazyReclaimCycle = nil
            lazyReclaimPhase += 1
        }
        startLazyReclaimCycle(aggressive: aggressive)
        let c = lazyReclaimCycle!
        runLazyReclaimSlice(deadline: .infinity)
        return (c.fbs.count - c.dropped, c.dropped, c.droppedBytes)
    }

    private func startLazyReclaimCycle(aggressive: Bool) {
        lazyReclaimPhase += 1                       // odd: a cycle runs
        lazyReclaimCycle = JeffJSLazyReclaimCycle(phase: lazyReclaimPhase, aggressive: aggressive,
                                                  cursor: gcObjects.count)
    }

    /// Scan, then decide, until `deadline`; finishes the cycle when both are
    /// done.
    private func runLazyReclaimSlice(deadline: CFAbsoluteTime) {
        guard let c = lazyReclaimCycle else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        c.slices += 1
        var done = false
        work: do {
            while c.cursor > 0 {
                var n = 0
                while c.cursor > 0 && n < 512 {
                    c.cursor -= 1
                    if c.cursor >= gcObjects.count { c.cursor = gcObjects.count; continue }
                    lazyReclaimScan(gcObjects[c.cursor].takeUnretainedValue(), c)
                    n += 1
                }
                c.scanned += n
                if CFAbsoluteTimeGetCurrent() >= deadline { break work }
            }
            while c.decideIndex < c.fbs.count {
                var n = 0
                while c.decideIndex < c.fbs.count && n < 16 {
                    lazyReclaimDecide(c.fbs[c.decideIndex], c)
                    c.decideIndex += 1
                    n += 1
                }
                if CFAbsoluteTimeGetCurrent() >= deadline { break work }
            }
            done = true
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        c.ms += ms
        c.maxSliceMs = max(c.maxSliceMs, ms)
        lazyStats.reclaimMs += ms
        lazyStats.reclaimMaxSliceMs = max(lazyStats.reclaimMaxSliceMs, ms)
        if done { finishLazyReclaimCycle(c) }
    }

    /// A function object: clear `fbFast` (stamping its body if it was set)
    /// and list its body once.
    @inline(__always)
    private func lazyReclaimScan(_ hdr: JeffJSGCObjectHeader, _ c: JeffJSLazyReclaimCycle) {
        guard hdr.gcObjType == .jsObject, hdr.refCount > 0 else { return }
        let obj = unsafeBitCast(hdr, to: JeffJSObject.self)
        guard obj.classID == JeffJSClassID.bytecodeFunction.rawValue else { return }
        let fbAny: JeffJSFunctionBytecode
        if let f = obj.fbFast {
            fbAny = f
        } else if case .bytecodeFunc(let f?, _, _) = obj.payload {
            fbAny = f
        } else {
            return
        }
        guard let li = fbAny.lazyInfo, let fb = fbAny as? JeffJSFunctionBytecodeCompiled else { return }
        if obj.fbFast != nil && !fb.isGenerator && !fb.isAsyncFunc {
            li.touch = c.phase
            obj.fbFast = nil
        }
        if li.seenCycle != c.phase {
            li.seenCycle = c.phase
            c.fbs.append(fb)
        }
    }

    /// A listed body: list its nested lazily compiled functions, then drop it
    /// if it was idle for the whole interval (or unconditionally in an
    /// aggressive cycle).
    private func lazyReclaimDecide(_ fb: JeffJSFunctionBytecodeCompiled, _ c: JeffJSLazyReclaimCycle) {
        for v in fb.cpool {
            guard let child = v.toFunctionBytecode() as? JeffJSFunctionBytecodeCompiled,
                  let cli = child.lazyInfo, cli.seenCycle != c.phase else { continue }
            cli.seenCycle = c.phase
            c.fbs.append(child)
        }
        guard let li = fb.lazyInfo, !li.isPending, !fb.isGenerator, !fb.isAsyncFunc else { return }
        guard c.aggressive || li.touch < c.phase - 1 else { return }
        // Tagged-template objects in the constant pool: their identity is
        // observable, so the body stays.
        if fb.cpool.contains(where: { $0.isObject }) { return }
        if fb.ic != nil { c.droppedICs += 1 }
        c.droppedBytes += fb.dropLazyBody()
        c.dropped += 1
    }

    private func finishLazyReclaimCycle(_ c: JeffJSLazyReclaimCycle) {
        lazyReclaimPhase += 1                       // even: between cycles
        lazyReclaimCycle = nil
        lazyLastReclaim = CFAbsoluteTimeGetCurrent()
        lazyStats.reclaimCycles += 1
        lazyStats.dropped += c.dropped
        lazyStats.droppedBytecodeBytes += c.droppedBytes
        lazyStats.droppedICTables += c.droppedICs
        if JeffJSConfig.lazyDropDebug {
            // Bodies compiled since the previous cycle ended: first calls
            // plus recompiles of dropped bodies (the reclaim's cost).
            let mark = lazyReclaimCompiledMark
            FileHandle.standardError.write(Data(String(
                format: "[jeffjs:reclaim] cycle %d%@: objects=%d bodies=%d dropped=%d (%dKB bytecode, %d IC tables) slices=%d %.1fms (max slice %.2fms) | compiled since last cycle %d in %.1fms, dropped total %d\n",
                lazyStats.reclaimCycles, c.aggressive ? " (memory pressure)" : "", c.scanned, c.fbs.count,
                c.dropped, c.droppedBytes / 1024, c.droppedICs, c.slices, c.ms, c.maxSliceMs,
                lazyStats.compiled - mark.count, lazyStats.compileMs - mark.ms, lazyStats.dropped).utf8))
        }
        lazyReclaimCompiledMark = (lazyStats.compiled, lazyStats.compileMs)
    }
}

extension JeffJSCompiler {
    /// The constant pool for a body recompiled after an idle reclaim: the
    /// fresh compile's `new` pool, except that each nested function whose
    /// old bytecode object (from `old`, the pool the dropped body kept) is
    /// the same function — same source span, same closure variables — is
    /// that old object again (closures made before the drop keep sharing it
    /// with closures made from now on); the fresh duplicate is freed. The old
    /// pool's other constants (strings, BigInts) are freed; an old nested
    /// function that found no match (never expected: the compile is
    /// deterministic) is left alone rather than freed under a live closure.
    static func mergeRetainedCpool(_ old: [JeffJSValue], into new: [JeffJSValue]) -> [JeffJSValue] {
        var merged = new
        var reused = [Bool](repeating: false, count: old.count)
        for i in 0 ..< min(old.count, new.count) {
            guard let n = new[i].toFunctionBytecode() as? JeffJSFunctionBytecodeCompiled,
                  let o = old[i].toFunctionBytecode() as? JeffJSFunctionBytecodeCompiled,
                  n.sourceStart == o.sourceStart, n.sourceLen == o.sourceLen,
                  n.isArrow == o.isArrow, n.isGenerator == o.isGenerator, n.isAsyncFunc == o.isAsyncFunc,
                  sameClosureVars(n.closureVarsList, o.closureVarsList)
            else { continue }
            merged[i] = old[i]
            reused[i] = true
            new[i].freeValue()
        }
        for i in 0 ..< old.count where !reused[i] && !old[i].isFunctionBytecode {
            old[i].freeValue()
        }
        return merged
    }
}
