// JeffJSPrecompiler.swift
// JeffJS — compile a script OFF the JS thread into the bytecode cache's disk
// tier, so the JS thread's eval maps the entry instead of parsing and
// compiling (perf/bytecode-paging).
//
// A host calls `JeffJSPrecompiler.precompileScript(text, filename:)` from a
// background thread as soon as it has a script's final text (React Natively:
// `JSScriptEngine.loadExecutableSourceOffMain`, where a fetched classic
// script is rewritten off-main before it is queued — there is no streaming:
// the fetch path delivers complete bodies, so the compile starts on arrival).
// The text and filename must be exactly what the JS thread will pass to
// `eval` (the cache key covers both); anything else is a harmless miss.
//
// Isolation. The compile runs in a private JeffJSRuntime + context made on
// the calling thread and freed at the end (≈1 ms), under one process-wide
// lock (one background compile at a time). It never runs code. The engine's
// one process-wide mutable pointer, `JeffJSGCObjectHeader.activeRuntime`
// (which runtime a new GC object belongs to), is never written here: while a
// precompile runs, `jeffJS_threadOwnersActive` is nonzero and objects created
// on this thread take their owner from a thread-local (its private runtime);
// every other thread keeps using `activeRuntime`. The runtime is marked
// `isBackgroundCompiler`, so its context init leaves `activeRuntime` alone.
//
// Ordering. While a precompile of a key is in flight, a JS-thread lookup of
// that key waits for it (it started earlier, so it finishes before a compile
// on the JS thread would), then maps the written entry.
//
// `compile.offThreadPrecompile` / `JEFFJS_COMPILE_OFFTHREADPRECOMPILE=0`
// turns the API into a no-op.

import Foundation

public enum JeffJSPrecompiler {

    public enum Outcome: Equatable, Sendable {
        /// Compiled and written (entry bytes).
        case compiled(bytes: Int)
        /// An entry already exists (or another precompile of it is running).
        case alreadyCached
        /// Not cacheable (cache off, module, excluded or pseudo filename, no disk tier).
        case skipped(String)
        /// Syntax error / compile failure / write refused: the JS thread will
        /// compile it (and report the error) as before.
        case failed(String)
    }

    private static let lock = NSLock()
    private static let statsLock = NSLock()
    nonisolated(unsafe) private static var _compiled = 0
    nonisolated(unsafe) private static var _compileMs = 0.0
    nonisolated(unsafe) private static var _sourceBytes = 0

    /// Scripts compiled, ms spent and source bytes, process-wide.
    public static var stats: (compiled: Int, ms: Double, sourceBytes: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (_compiled, _compileMs, _sourceBytes)
    }

    // MARK: - Worker thread

    /// Jobs for the worker, FIFO (document order as the host enqueues them).
    nonisolated(unsafe) private static var queue: [(source: String, filename: String, evalFlags: Int)] = []
    nonisolated(unsafe) private static var workerRunning = false
    private static let queueLock = NSLock()

    /// Queue `source` for a precompile on the engine's worker thread (16 MB
    /// stack: the parser recurses; Swift concurrency's pool threads have
    /// 512 KB). Returns at once; the worker exits when the queue is empty.
    /// Call it from wherever the host has the final text (any thread).
    public static func enqueue(_ source: String, filename: String, evalFlags: Int = 0) {
        guard JeffJSConfig.compileOffThreadPrecompile, JeffJSBytecodeDiskStore.shared != nil else { return }
        queueLock.lock()
        queue.append((source, filename, evalFlags))
        let start = !workerRunning
        if start { workerRunning = true }
        queueLock.unlock()
        guard start else { return }
        let th = Thread {
            while true {
                queueLock.lock()
                if queue.isEmpty { workerRunning = false; queueLock.unlock(); return }
                let job = queue.removeFirst()
                queueLock.unlock()
                _ = precompileScript(job.source, filename: job.filename, evalFlags: job.evalFlags)
            }
        }
        th.name = "jeffjs.precompile"
        th.stackSize = 16 << 20
        th.qualityOfService = .userInitiated   // the JS thread may wait on it
        th.start()
    }

    /// Compile `source` as a classic script (`evalFlags` as the eval will
    /// use, 0 = global) under `filename` into the disk tier, on the calling
    /// thread. Never call it on a thread that is running JS.
    @discardableResult
    public static func precompileScript(_ source: String, filename: String, evalFlags: Int = 0) -> Outcome {
        return precompileScript(source, filename: filename, evalFlags: evalFlags, store: JeffJSBytecodeDiskStore.shared)
    }

    static func precompileScript(_ source: String, filename: String, evalFlags: Int,
                                 store: JeffJSBytecodeDiskStore?) -> Outcome {
        guard JeffJSConfig.compileOffThreadPrecompile else { return .skipped("compile.offThreadPrecompile=false") }
        guard let store else { return .skipped("no disk tier") }
        let isModule = (evalFlags & JS_EVAL_TYPE_MASK) == JS_EVAL_TYPE_MODULE
        if let why = JeffJSContext.bytecodeCacheSkipReason(filename: filename, isModule: isModule) {
            return .skipped(why)
        }
        // Host pseudo-names are written on their second sighting only (the
        // cache's one-shot rule): a precompile would be wasted work.
        if filename.hasPrefix("<"), !filename.hasPrefix("<inline") { return .skipped("pseudo filename") }
        if Thread.isMainThread { return .skipped("main thread") }
        let key = JeffJSBytecodeCache.key(source: source, filename: filename, evalFlags: evalFlags)
        if FileManager.default.fileExists(atPath: store.url(for: key.hash).path) { return .alreadyCached }
        guard JeffJSBytecodeCache.beginPrecompile(key.hash) else { return .alreadyCached }
        defer { JeffJSBytecodeCache.endPrecompile(key.hash) }

        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: store.url(for: key.hash).path) { return .alreadyCached }
        let t0 = CFAbsoluteTimeGetCurrent()

        let rt = JeffJSRuntime()
        rt.isBackgroundCompiler = true
        rt.bytecodeCache.diskStore = nil
        pthread_setspecific(jeffJS_threadOwnerKey, Unmanaged.passUnretained(rt).toOpaque())
        jeffJS_threadOwnersActive += 1
        defer {
            jeffJS_threadOwnersActive -= 1
            pthread_setspecific(jeffJS_threadOwnerKey, nil)
        }

        let outcome: Outcome = {
            let ctx = rt.newContext()
            defer {
                ctx.free()
                rt.free()
            }
            switch ctx.compileProgram(input: source, filename: filename, evalFlags: evalFlags, cacheHash: key.hash) {
            case .compiled(let fb):
                let blob = JeffJSBytecodeSerializer.serialize(fb, rt: rt)
                ctx.releaseUnrunProgram(fb)
                let cap = JeffJSConfig.bytecodeMaxSize
                if cap > 0, blob.count > cap { return .failed("over cache.bytecodeMaxSize") }
                let entry = JeffJSBytecodeCache.makeEntry(key: key, blob: blob)
                guard store.write(key.hash, entry) else { return .failed("disk write refused") }
                return .compiled(bytes: entry.count)
            case .empty:
                return .failed("empty program")
            case .syntaxError:
                return .failed("syntax error")
            case .failed:
                return .failed("compile failed")
            }
        }()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if case .compiled = outcome {
            statsLock.lock()
            _compiled += 1; _compileMs += ms; _sourceBytes += source.utf8.count
            statsLock.unlock()
        }
        if JeffJSBytecodeCache.debugLogging {
            FileHandle.standardError.write(Data("[jeffjs:bccache] precompile \(outcome) file=\(filename) ms=\(Int(ms))\n".utf8))
        }
        return outcome
    }
}
