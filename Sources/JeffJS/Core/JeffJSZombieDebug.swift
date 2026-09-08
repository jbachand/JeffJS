// JeffJSZombieDebug.swift
// JeffJS — use-after-free tripwire ("zombie objects" mode).
//
// The engine layers manual refcounts (NaN-boxed raw pointers) on top of ARC:
// when a JS refcount over-release drops an object to zero early, the matching
// `Unmanaged.release()` lets ARC deallocate it while live `JeffJSValue`s still
// hold its raw pointer. The next dup/free then scribbles freed memory and the
// process dies later, far from the bug.
//
// With JEFFJS_ZOMBIES=1, freed JS objects are kept allocated (flagged via
// `freeMark`) instead of released, and any subsequent dupValue/freeValue on a
// dead object prints the touching stack — the exact over-release call site.

import Foundation

/// True when the JEFFJS_ZOMBIES env var is set. A stored literal global (no
/// swift_once on read — it is checked on every object dup/free); populated by
/// `jeffJS_bootstrapDebugFlags()` from JeffJSRuntime.init.
nonisolated(unsafe) var jeffJSZombiesEnabled: Bool = false
/// JEFFJS_NO_POOL=1: never recycle plain objects (JeffJSObjectPool.swift).
nonisolated(unsafe) var jeffJSObjectPoolDisabled: Bool = false
/// trackRefcounts || zombies: one load on the inline dup/free fast paths.
nonisolated(unsafe) var jeffJS_refDebugMode: Bool = false
/// JEFFJS_TRACE_DEBUG=1: log fast-trace entries/exits (first few per block).
nonisolated(unsafe) var jeffJSTraceDebug: Bool = false
/// JEFFJS_TRACK_RC=1: refcount tracking with a report at exit.
nonisolated(unsafe) var jeffJS_rcReportRegistered: Bool = false

/// Copy the config/env-derived debug flags into their plain stored globals.
/// Idempotent; called from JeffJSRuntime.init.
func jeffJS_bootstrapDebugFlags() {
    jeffJSZombiesEnabled = ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1"
    jeffJSTraceDebug = ProcessInfo.processInfo.environment["JEFFJS_TRACE_DEBUG"] == "1"
    jeffJSObjectPoolDisabled = ProcessInfo.processInfo.environment["JEFFJS_NO_POOL"] == "1"
    JeffJSGCObjectHeader.trackRefcounts = JeffJSConfig.trackRefcounts
        || ProcessInfo.processInfo.environment["JEFFJS_TRACK_RC"] == "1"
    jeffJS_refDebugMode = JeffJSGCObjectHeader.trackRefcounts || jeffJSZombiesEnabled
    jeffJS_computeStoreOpcodeMask()
    if JeffJSGCObjectHeader.trackRefcounts && !jeffJS_rcReportRegistered {
        jeffJS_rcReportRegistered = true
        atexit { FileHandle.standardError.write(JeffJSGCObjectHeader.refcountReport().data(using: .utf8)!) }
    }
}

enum JeffJSZombieDebug {
    /// Cap report spam — first few stacks are the signal.
    nonisolated(unsafe) static var reportsRemaining = 8

    /// Keeps freed strings/ropes/buffers allocated in zombie mode so stale
    /// NaN-boxed pointers stay detectable instead of scribbling reused memory.
    /// Single-threaded engine; debug-only.
    nonisolated(unsafe) static var stringKeepAlive: [AnyObject] = []

    static func reportTouch(_ kind: String, _ hdr: JeffJSGCObjectHeader) {
        guard reportsRemaining > 0 else { return }
        reportsRemaining -= 1
        let classID = (hdr as? JeffJSObject)?.classID ?? -1
        print("[ZOMBIE-\(kind)] touch on freed object classID=\(classID) rc=\(hdr.refCount) type=\(hdr.gcObjType) ptr=\(Unmanaged.passUnretained(hdr).toOpaque())")
        for sym in Thread.callStackSymbols.prefix(14) {
            print("    \(sym)")
        }
    }

    static func reportString(_ kind: String, _ what: String) {
        guard reportsRemaining > 0 else { return }
        reportsRemaining -= 1
        print("[ZOMBIE-STR-\(kind)] touch on freed \(what)")
        for sym in Thread.callStackSymbols.prefix(14) {
            print("    \(sym)")
        }
    }
}
