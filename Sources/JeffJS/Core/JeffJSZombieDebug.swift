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
    if let cap = ProcessInfo.processInfo.environment["JEFFJS_ZOMBIE_REPORTS"].flatMap({ Int($0) }) {
        JeffJSZombieDebug.reportsRemaining = cap
    }
    JeffJSGCObjectHeader.trackRefcounts = JeffJSConfig.trackRefcounts
        || ProcessInfo.processInfo.environment["JEFFJS_TRACK_RC"] == "1"
    jeffJS_refDebugMode = JeffJSGCObjectHeader.trackRefcounts || jeffJSZombiesEnabled
    jeffJS_computeStoreOpcodeMask()
    jeffJS_bootstrapHeapCensus()
    if JeffJSGCObjectHeader.trackRefcounts && !jeffJS_rcReportRegistered {
        jeffJS_rcReportRegistered = true
        atexit { FileHandle.standardError.write(JeffJSGCObjectHeader.refcountReport().data(using: .utf8)!) }
    }
}

enum JeffJSZombieDebug {
    /// Most recently created context (zombie mode only): its live frame chain
    /// is printed with each report so the touch can be tied to JS source.
    nonisolated(unsafe) static weak var context: JeffJSContext?

    static func printJSStack() {
        guard let ctx = context, ctx.currentFrame != nil else { return }
        let trace = ctx.formatStackTrace(errorName: "JS stack", message: "",
                                         frames: ctx.captureStackFrames(maxDepth: 8))
        print(trace)
    }
    /// Contents of a freed string for the report (zombie strings keep their
    /// storage, so this is still readable): ` "<first 80 chars>" len=N`.
    static func describeString(_ sb: AnyObject?) -> String {
        var text: String? = nil
        var len = 0
        if let s = sb as? JeffJSString { text = s.toSwiftString(); len = s.len }
        else if let r = sb as? JeffJSStringRope { len = r.len; text = r.flat?.toSwiftString() ?? "<rope>" }
        else if let b = sb as? JeffJSStringBuffer { text = b.toSwiftString(); len = text?.utf16.count ?? 0 }
        guard let t = text else { return "" }
        let clipped = t.count > 80 ? String(t.prefix(80)) + "..." : t
        return " \"\(clipped)\" len=\(len)"
    }

    /// Cap report spam — first few stacks are the signal
    /// (JEFFJS_ZOMBIE_REPORTS=N raises it; every touch past the cap is still
    /// counted and the total is printed at exit).
    nonisolated(unsafe) static var reportsRemaining = 8
    nonisolated(unsafe) static var touches = 0
    nonisolated(unsafe) static var totalRegistered = false

    static func countTouch() -> Bool {
        touches += 1
        if !totalRegistered {
            totalRegistered = true
            atexit { print("[ZOMBIE] \(JeffJSZombieDebug.touches) touch(es) on freed values") }
        }
        guard reportsRemaining > 0 else { return false }
        reportsRemaining -= 1
        return true
    }

    /// Keeps freed strings/ropes/buffers allocated in zombie mode so stale
    /// NaN-boxed pointers stay detectable instead of scribbling reused memory.
    /// Single-threaded engine; debug-only.
    nonisolated(unsafe) static var stringKeepAlive: [AnyObject] = []

    static func reportTouch(_ kind: String, _ hdr: JeffJSGCObjectHeader) {
        guard countTouch() else { return }
        let classID = (hdr as? JeffJSObject)?.classID ?? -1
        print("[ZOMBIE-\(kind)] touch on freed object classID=\(classID) rc=\(hdr.refCount) type=\(hdr.gcObjType) ptr=\(Unmanaged.passUnretained(hdr).toOpaque())")
        for sym in Thread.callStackSymbols.prefix(14) {
            print("    \(sym)")
        }
        printJSStack()
    }

    static func reportString(_ kind: String, _ what: String, _ sb: AnyObject? = nil) {
        guard countTouch() else { return }
        print("[ZOMBIE-STR-\(kind)] touch on freed \(what)\(describeString(sb))")
        for sym in Thread.callStackSymbols.prefix(14) {
            print("    \(sym)")
        }
        printJSStack()
    }
}
