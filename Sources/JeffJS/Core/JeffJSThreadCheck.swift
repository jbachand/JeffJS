// JeffJSThreadCheck.swift
//
// The runtime threading rule: **one thread runs JS on a runtime at a time.**
// A runtime may move between threads (the app evaluates its polyfills on a
// 16 MB background thread, then hands the runtime to the main thread), but
// while one thread is inside it no other thread may touch its heap — not by
// evaluating, not by collecting, and not by *releasing* an engine object
// whose deinit reaches the heap (a detached var-ref's deinit unlinks it from
// the GC list; a map or promise record's deinit drops JS values).
//
// That last case is how the rule was broken without anyone calling into the
// engine (idle-GC mark crash, 2026-09-30): the app compiles this package with
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and under default isolation a
// class *without* an explicit deinit gets an isolated deinit — released off
// the main thread, its destruction is enqueued on the main actor. The
// polyfill thread released JeffJSPropertyExtra / JeffJSMapState / …, the main
// thread ran their deinits concurrently, a var-ref's deinit swap-removed
// itself from `rt.gcObjects` while the polyfill thread appended to it, and
// the next collection's mark phase walked a freed header. Every engine class
// is therefore `nonisolated` (EngineThreadingRuleTests enforces it), so an
// engine object is destroyed on the thread that released it — the JS thread.
//
// Checks (on in Debug builds and under JEFFJS_GC_VERIFYROOTS=1):
//   * ownership: `eval`/`evalPrecompiled` enter the runtime (`enterJSThread`);
//     a GC-list mutation, a collection or a second entry from another thread
//     while one is inside traps (`jeffJS_threadViolationHandler` replaces the
//     trap in tests);
// and under JEFFJS_GC_VERIFYROOTS=1 only:
//   * every GC-list mutation notes its thread; a change of thread is logged
//     with the stack that made it (stderr, `[jeffjs:gc-thread]`);
//   * before each collection the whole list is checked: every entry must be a
//     live JeffJSObject / JeffJSShape / JeffJSVarRef / JeffJSBigInt (raw class
//     word compared, so a freed-and-reused block is caught before Swift touches
//     it), sit at its own `gcListIndex`, and belong to this runtime.

import Foundation

/// Stored literal globals (no swift_once on read: they are checked on every
/// GC-list add/remove); set by `jeffJS_bootstrapDebugFlags()` from
/// JeffJSRuntime.init.
nonisolated(unsafe) var jeffJS_gcVerifyRoots: Bool = false
#if DEBUG
nonisolated(unsafe) var jeffJS_threadCheck: Bool = true
#else
nonisolated(unsafe) var jeffJS_threadCheck: Bool = false
#endif

/// Tests set this to observe violations instead of trapping.
nonisolated(unsafe) var jeffJS_threadViolationHandler: ((String) -> Void)? = nil

@inline(__always)
nonisolated func jeffJS_currentThreadWord() -> UInt {
    #if canImport(Darwin)
    return UInt(bitPattern: pthread_self())
    #else
    return UInt(pthread_self())
    #endif
}

nonisolated private func jeffJS_threadLabel() -> String {
    let name = Thread.current.name ?? ""
    #if canImport(Darwin)
    let mach = pthread_mach_thread_np(pthread_self())
    return "\(mach)\(Thread.isMainThread ? " main" : "")\(name.isEmpty ? "" : " '\(name)'")"
    #else
    return "\(jeffJS_currentThreadWord())\(name.isEmpty ? "" : " '\(name)'")"
    #endif
}

nonisolated private func jeffJS_shortStack(drop: Int) -> [String] {
    Thread.callStackSymbols.dropFirst(drop).prefix(18).map { line -> String in
        // "3   React Natively   0x... symbol + 12" -> "symbol + 12"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        return parts.count > 3 ? parts[3...].joined(separator: " ") : line
    }
}

@inline(never)
nonisolated private func jeffJS_threadViolation(_ rt: JeffJSRuntime, _ what: String) {
    let msg = "[jeffjs:thread] \(what) on thread \(jeffJS_threadLabel()) while another thread runs JS on this runtime "
        + "(one JS thread per runtime; see JeffJSThreadCheck.swift)\n      "
        + jeffJS_shortStack(drop: 3).joined(separator: "\n      ")
    if let handler = jeffJS_threadViolationHandler { handler(msg); return }
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    fatalError(msg)
}

nonisolated extension JeffJSRuntime {
    /// The calling thread starts running JS on this runtime (nests). A second
    /// thread entering while the first is inside is a violation.
    @inline(__always)
    func enterJSThread() {
        guard jeffJS_threadCheck else { return }
        let me = jeffJS_currentThreadWord()
        if jsOwnerDepth > 0 && jsOwnerThread != me {
            jeffJS_threadViolation(self, "entered the runtime")
            return
        }
        jsOwnerThread = me
        jsOwnerDepth += 1
    }

    @inline(__always)
    func exitJSThread() {
        guard jeffJS_threadCheck else { return }
        if jsOwnerDepth > 0 && jsOwnerThread == jeffJS_currentThreadWord() {
            jsOwnerDepth -= 1
            if jsOwnerDepth == 0 { jsOwnerThread = 0 }
        }
    }
}

/// A heap mutation (`op`) on the calling thread: a violation when another
/// thread is inside the runtime.
@inline(__always)
nonisolated func jeffJS_checkJSThread(_ rt: JeffJSRuntime, _ op: StaticString) {
    if rt.jsOwnerDepth > 0 && rt.jsOwnerThread != jeffJS_currentThreadWord() {
        jeffJS_threadViolation(rt, "GC \(op)")
    }
}

/// Called on every GC-list mutation when the verifier is on.
@inline(never)
nonisolated func jeffJS_gcListNoteThread(_ rt: JeffJSRuntime, _ op: StaticString) {
    let me = jeffJS_currentThreadWord()
    if rt.gcListThread == me { return }
    let first = rt.gcListThread == 0
    rt.gcListThread = me
    if first { return }
    let entry = "gc list \(op) moved to thread \(jeffJS_threadLabel()):\n      "
        + jeffJS_shortStack(drop: 2).joined(separator: "\n      ")
    rt.gcListThreadLog.append(entry)
    if rt.gcListThreadLog.count > 8 { rt.gcListThreadLog.removeFirst() }
    FileHandle.standardError.write(("[jeffjs:gc-thread] " + entry + "\n").data(using: .utf8)!)
}

/// The class words a listed header may have.
nonisolated(unsafe) private let jeffJS_listedClassWords: [UnsafeRawPointer] = [
    unsafeBitCast(JeffJSObject.self as AnyClass, to: UnsafeRawPointer.self),
    unsafeBitCast(JeffJSShape.self as AnyClass, to: UnsafeRawPointer.self),
    unsafeBitCast(JeffJSVarRef.self as AnyClass, to: UnsafeRawPointer.self),
    unsafeBitCast(JeffJSBigInt.self as AnyClass, to: UnsafeRawPointer.self),
]

/// Walks the GC list before a collection; traps on the first bad entry.
@inline(never)
nonisolated func jeffJS_gcVerifyList(_ rt: JeffJSRuntime, _ phase: StaticString) {
    jeffJS_gcListNoteThread(rt, "verify")
    let classes = jeffJS_listedClassWords
    for i in 0..<rt.gcObjects.count {
        let raw = UnsafeRawPointer(rt.gcObjects[i].toOpaque())
        let isa = raw.load(as: UnsafeRawPointer.self)
        var problem: String? = nil
        if !classes.contains(isa) {
            problem = "class word \(isa) is not a GC header class (freed or reused block)"
        } else {
            let hdr = rt.gcObjects[i].takeUnretainedValue()
            if hdr.gcListIndex != i {
                problem = "gcListIndex \(hdr.gcListIndex) != list position (type \(hdr.gcObjType))"
            } else if hdr.ownerRuntime !== rt {
                problem = "owner runtime is not this runtime (type \(hdr.gcObjType))"
            } else if hdr.refCount < 0 || hdr.refCount > (1 << 40) {
                problem = "refCount \(hdr.refCount) (type \(hdr.gcObjType))"
            }
        }
        if let problem {
            let msg = "[jeffjs:gc-verify] \(phase): gcObjects[\(i)] of \(rt.gcObjects.count) at \(raw): \(problem); thread \(jeffJS_threadLabel())\n  recent GC-list thread changes:\n    "
                + rt.gcListThreadLog.joined(separator: "\n    ")
            FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
            fatalError(msg)
        }
    }
}

/// Runtime identities (`JeffJSRuntime.atomOwnerID`); runtimes may be created
/// on any thread.
nonisolated(unsafe) private let jeffJS_runtimeIDLock = NSLock()
nonisolated(unsafe) private var jeffJS_runtimeIDNext: UInt32 = 0
func jeffJS_nextRuntimeID() -> UInt32 {
    jeffJS_runtimeIDLock.lock(); defer { jeffJS_runtimeIDLock.unlock() }
    jeffJS_runtimeIDNext &+= 1
    if jeffJS_runtimeIDNext == 0 { jeffJS_runtimeIDNext = 1 }
    return jeffJS_runtimeIDNext
}
