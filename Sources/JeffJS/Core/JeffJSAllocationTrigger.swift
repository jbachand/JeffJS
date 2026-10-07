// JeffJSAllocationTrigger.swift
// JeffJS — collections and host memory checks driven by bytes allocated
// (perf/task-spikes, 2026-10-07).
//
// The collector's own trigger counts objects (`gc.objectCost` per object
// against `mallocGCThreshold`), and the watch app's governor samples the
// process footprint every 250 ms. Neither sees a task that holds its memory
// in a few hundred large strings or in deep interpreter stacks: homedepot's
// PIP put 300+ MB on the heap inside one 620 ms task, past the watch's
// 300 MB kill line before the next sample.
//
// So the allocators of the big things — string payloads of 512+ code units
// (`JeffJSString.init`), interpreter stack segments, ArrayBuffer stores —
// report their bytes here:
//   * past `gc.bytesSinceGCThreshold` bytes since the last collection (or half
//     the live heap estimate, if that is larger, so collections stay
//     proportional to the heap), the next object allocation — the collector's
//     safe point — runs a collection (`mallocGCThreshold` is dropped to the
//     current heap size);
//   * every `gc.bytesSinceHookThreshold` bytes the host's memory hook is
//     called synchronously, from the allocation (`memoryHook`, else the
//     interrupt handler). It reads the footprint and may ask to stop; the
//     engine then makes the next interrupt check come at the next back-edge.
//
// `JEFFJS_BIGSTRING_LOG=<code units>`: log the JS stack of every string of at
// least that many code units when it is made (the first 40, then every 100th).

import Foundation

nonisolated(unsafe) let jeffJS_bigStringLog: Int = Int(ProcessInfo.processInfo.environment["JEFFJS_BIGSTRING_LOG"] ?? "") ?? 0
nonisolated(unsafe) var jeffJS_bigStringLogged = 0

/// Smallest string payload (code units) the trigger counts; smaller strings
/// are accounted with the objects that hold them.
let jeffJS_allocTriggerMinStringLen = 512

/// The runtime running JS on the calling thread, if any: `activeRuntime`
/// when the stack pointer is inside the stack its JS last entered on
/// (`updateStackLimitForCurrentThread`). Strings are also made off the JS
/// thread (background compiles, the bytecode cache); those must not touch a
/// runtime's counters or call its host hook.
@inline(__always)
func jeffJS_runtimeOnThisThread() -> JeffJSRuntime? {
    guard let rt = JeffJSGCObjectHeader.activeRuntime else { return nil }
    var probe: UInt8 = 0
    let sp = withUnsafeMutablePointer(to: &probe) { UInt(bitPattern: $0) }
    return sp < rt.stackTop && sp >= rt.stackFloor ? rt : nil
}

/// A string payload of `len` code units was just made (JeffJSString.init).
@inline(never)
func jeffJS_noteStringAllocation(len: Int, wide: Bool) {
    guard let rt = jeffJS_runtimeOnThisThread() else { return }
    rt.noteAllocation(wide ? len &<< 1 : len)
    if jeffJS_bigStringLog > 0, len >= jeffJS_bigStringLog { rt.logBigString(len: len, wide: wide) }
}

/// An ArrayBuffer store of `bytes` was just made.
@inline(never)
func jeffJS_noteBufferAllocation(_ bytes: Int) {
    jeffJS_runtimeOnThisThread()?.noteAllocation(bytes)
}

extension JeffJSRuntime {

    /// `bytes` were allocated outside the object count. `collectable`: a
    /// collection could give them back (strings, buffers — not stack segments,
    /// which only the host hook counts).
    @inline(__always)
    func noteAllocation(_ bytes: Int, collectable: Bool = true) {
        if collectable { allocBytesSinceGC &+= bytes }
        allocBytesSinceHook &+= bytes
        if (allocGCThreshold > 0 && allocBytesSinceGC >= allocGCThreshold)
            || (allocHookThreshold > 0 && allocBytesSinceHook >= allocHookThreshold) {
            allocationThresholdCrossed()
        }
    }

    @inline(never)
    func allocationThresholdCrossed() {
        if allocHookThreshold > 0, allocBytesSinceHook >= allocHookThreshold {
            allocBytesSinceHook = 0
            callMemoryHook()
        }
        // Proportional to the heap: half the live estimate since the last
        // collection, at least the configured amount.
        if allocGCThreshold > 0, !allocGCRequested,
           allocBytesSinceGC >= max(allocGCThreshold, gcLiveAfterLast >> 1) {
            allocGCRequested = true
            // The next object allocation collects (JeffJSObject.init: a safe
            // point; a collection here, inside whatever native code is making
            // a string, could free what that code holds without a reference).
            if mallocGCThreshold > mallocState.mallocSize { mallocGCThreshold = mallocState.mallocSize }
        }
    }

    /// Called by runGC at the end of every collection.
    @inline(__always)
    func allocationTriggerCollected() {
        if allocGCRequested { allocGCRuns &+= 1; allocGCRequested = false }
        allocBytesSinceGC = 0
    }

    @inline(never)
    func callMemoryHook() {
        guard let hook = memoryHook ?? interruptHandler else { return }
        allocHookCalls &+= 1
        if hook(self) {
            // Stop requested: every context's next back-edge in the main
            // loop checks (a running trace block keeps its own countdown).
            memoryStopRequested = true
            for i in 0..<realmTable.count {
                if let c = realmTable[i]?.takeUnretainedValue() { c.interruptCounter = 1 }
            }
        }
    }

    @inline(never)
    func logBigString(len: Int, wide: Bool) {
        jeffJS_bigStringLogged &+= 1
        let n = jeffJS_bigStringLogged
        guard n <= 40 || n % 100 == 0 else { return }
        var ctx: JeffJSContext? = nil
        for i in 0..<realmTable.count {
            if let c = realmTable[i]?.takeUnretainedValue(), c.currentFrame != nil { ctx = c; break }
        }
        var stack = "(no JS frame)"
        if let ctx {
            var natives: [(before: Int, name: String)] = []
            let frames = ctx.captureStackFrames(maxDepth: 12, natives: &natives, skipInnermostNative: false)
            stack = ctx.formatStackTrace(errorName: "", message: "", frames: frames, natives: natives)
        }
        jeffJS_stderrLine("[bigstring] #\(n) len=\(len) wide=\(wide) sinceGC=\(allocBytesSinceGC >> 20)MB\n\(stack)")
    }
}

// MARK: - Function source strings

/// `Function.prototype.toString` of a big function returns one shared string
/// (JS strings are immutable) instead of a fresh copy per call. Bot-defence
/// and analytics scripts call it on functions whose source is a whole script
/// or module bundle — Akamai's sensor on homedepot asks for its own 536 KB
/// source a dozen times; the PIP's bundle wrapper is 1.18 M UTF-16 units
/// (2.4 MB a copy). A few entries (`maxEntries`, `maxBytes`), most recent
/// first; dropped at memory pressure and teardown.
/// A/B: `JEFFJS_STRINGS_FUNCTIONSOURCECACHE=0`.
nonisolated final class JeffJSFunctionSourceCache {
    struct Entry {
        let text: JeffJSSourceText   // held: keeps its identity unique while cached
        let start: Int
        let len: Int
        let string: JeffJSString     // holds one count (dropCachedString)
        let bytes: Int
    }
    var entries: [Entry] = []
    var bytes = 0
    static let enabled = JeffJSConfig.functionSourceCache
    /// Spans shorter than this are rebuilt per call (cheap, and many).
    static let minLen = 16 * 1024
    static let maxEntries = 4
    static let maxBytes = 16 * 1024 * 1024
}

extension JeffJSRuntime {
    /// `Function.prototype.toString` text of the span: an owned JS value, or
    /// nil when the span is not in the text.
    func functionSourceString(_ text: JeffJSSourceText, start: Int, len: Int) -> JeffJSValue? {
        let cache = functionSourceCache
        guard JeffJSFunctionSourceCache.enabled, len >= JeffJSFunctionSourceCache.minLen else {
            return text.sliceJSString(start: start, len: len).map { JeffJSValue.makeString($0) }
        }
        if let i = cache.entries.firstIndex(where: { $0.text === text && $0.start == start && $0.len == len }) {
            let e = cache.entries[i]
            if i != 0 { cache.entries.remove(at: i); cache.entries.insert(e, at: 0) }
            return JeffJSContext.sharedStringRef(e.string)
        }
        guard let js = text.sliceJSString(start: start, len: len) else { return nil }
        let bytes = js.isWideChar ? js.len * 2 : js.len
        if bytes > JeffJSFunctionSourceCache.maxBytes { return JeffJSValue.makeString(js) }
        cache.entries.insert(.init(text: text, start: start, len: len, string: js, bytes: bytes), at: 0)
        cache.bytes += bytes
        while cache.entries.count > JeffJSFunctionSourceCache.maxEntries || cache.bytes > JeffJSFunctionSourceCache.maxBytes,
              let last = cache.entries.popLast() {
            cache.bytes -= last.bytes
            dropCachedString(last.string)
        }
        return JeffJSContext.sharedStringRef(js)
    }

    /// Memory pressure / teardown: give back the cached function sources.
    func dropFunctionSourceCache() {
        let cache = functionSourceCache
        for e in cache.entries { dropCachedString(e.string) }
        cache.entries.removeAll()
        cache.bytes = 0
    }
}
