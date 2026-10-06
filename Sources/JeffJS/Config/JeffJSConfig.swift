// JeffJSConfig.swift
// Loads JeffJSConfig.plist and exposes all engine flags as static properties.
// Single source of truth — edit the plist, not the code.

import Foundation

/// Bundle holding the engine's resources (config plist, Metal shaders).
///
/// `Bundle.module` is synthesized by SwiftPM only. These sources are also
/// compiled directly into a host app (React Natively builds the engine into
/// its own module), where the resources ship in the app bundle instead.
let jeffJSResourceBundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle.main
    #endif
}()

enum JeffJSConfig {

    // MARK: - Plist backing store (loaded once at process start)

    private static let dict: [String: Any] = {
        guard let url = jeffJSResourceBundle.url(forResource: "JeffJSConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return [:]
        }
        return plist
    }()

    /// Environment override for experiments: `cache.bytecodeEnabled` is read
    /// from `JEFFJS_CACHE_BYTECODEENABLED` when set (1/0, true/false), else
    /// from the plist, else the default.
    private static func envOverride(_ key: String) -> String? {
        let envKey = "JEFFJS_" + key.uppercased().replacingOccurrences(of: ".", with: "_")
        return ProcessInfo.processInfo.environment[envKey]
    }
    private static func bool(_ key: String, default d: Bool) -> Bool {
        if let e = envOverride(key) { return e == "1" || e.lowercased() == "true" }
        return dict[key] as? Bool ?? d
    }
    private static func int(_ key: String, default d: Int) -> Int {
        if let e = envOverride(key), let v = Int(e) { return v }
        return dict[key] as? Int ?? d
    }
    private static func string(_ key: String, default d: String) -> String {
        if let e = envOverride(key) { return e }
        return dict[key] as? String ?? d
    }

    // MARK: - Build

    static let precompilePolyfills = bool("build.precompilePolyfills", default: true)

    // MARK: - Debug

    static let traceOpcodes        = bool("debug.traceOpcodes",        default: false)
    static let trackRefcounts      = bool("debug.trackRefcounts",      default: false)
    static let suppressErrorPrinting = bool("debug.suppressErrorPrinting", default: false)

    // MARK: - Optimization

    static let optimizeEnabled     = bool("optimize.enabled",          default: true)
    static let shortOpcodes        = bool("optimize.shortOpcodes",     default: true)
    static let useInlineCalls      = bool("optimize.useInlineCalls",   default: false)

    // MARK: - Bytecode Cache

    static let bytecodeEnabled     = bool("cache.bytecodeEnabled",     default: true)
    /// Filename prefixes to EXCLUDE from caching. Small dynamic scripts
    /// like eval() and onclick handlers aren't worth caching.
    static let bytecodeExcludePrefixes: [String] = {
        string("cache.bytecodeExcludePrefixes", default: "<eval>,<onclick>,<diag>")
            .split(separator: ",").map(String.init)
    }()
    /// Legacy: if set, only cache filenames matching these prefixes (opt-in mode).
    /// Empty = cache everything not excluded (recommended).
    static let bytecodePrefixes: [String] = {
        string("cache.bytecodePrefixes", default: "")
            .split(separator: ",").map(String.init)
    }()
    /// Largest *serialized* entry the cache keeps, in bytes; 0 = no cap of
    /// its own (the budgets below decide). It used to be the top-level
    /// function's bytecode length with a 1 MB default, checked before
    /// compiling, which skipped exactly the multi-MB bundles that are the
    /// most expensive to recompile.
    static let bytecodeMaxSize     = int("cache.bytecodeMaxSize",      default: 0)
    /// Total bytes of the disk tier (`Caches/JeffJSBytecodeCache/<engine>`),
    /// kept by LRU eviction (`JeffJSBytecodeDiskStore`); 0 = no disk tier.
    /// Watch-sized by default on watchOS.
    static let bytecodeDiskBudgetBytes = int("cache.bytecodeDiskBudgetBytes", default: platformBudget(iOS: 200, watch: 16))
    /// Bytes of serialized blobs each runtime keeps in memory (LRU). A blob
    /// over a quarter of it is disk-only.
    static let bytecodeMemoryBudgetBytes = int("cache.bytecodeMemoryBudgetBytes", default: platformBudget(iOS: 16, watch: 2))

    /// A default in MB for the platform the engine runs on, in bytes.
    private static func platformBudget(iOS: Int, watch: Int) -> Int {
        #if os(watchOS)
        return watch * 1024 * 1024
        #else
        return iOS * 1024 * 1024
        #endif
    }
    /// One stderr line per bytecode-cache hit / miss / reject / store, with the
    /// full cache key and the reason a rejected entry was refused.
    /// `JEFFJS_CACHE_BYTECODEDEBUG=1` turns it on without touching the plist.
    static let bytecodeDebug       = bool("cache.bytecodeDebug",       default: false)

    // MARK: - Compilation

    /// Compile function bodies on their first call (JavaScriptCore / V8
    /// style). The whole script is still parsed up front, so early errors are
    /// reported at load; a function that never runs keeps only a small stub
    /// (its closure variables and source span) instead of its bytecode.
    /// `JEFFJS_COMPILE_LAZYFUNCTIONS=0` compiles everything eagerly.
    static let lazyFunctions       = bool("compile.lazyFunctions",     default: true)
    /// Functions whose source is shorter than this are compiled eagerly (a
    /// tiny body costs about as much as its stub).
    static let lazyMinSourceBytes  = int("compile.lazyMinSourceBytes", default: 0)
    /// Reclaim the compiled body (bytecode, inline caches, trace data) of a
    /// lazily compiled function that has not run for between one and two of
    /// these intervals (it compiles again on its next call); 0 = never. The
    /// scan runs in ≤ 1 ms slices at idle points; generators and async
    /// functions are kept.
    static let lazyDropAfterMs     = int("compile.lazyDropAfterMs",    default: 0)
    /// On a memory warning or when the app goes to the background, drop
    /// every lazily compiled body at the next idle point (they compile
    /// again on their next call). Independent of `lazyDropAfterMs`.
    static let lazyDropOnMemoryPressure = bool("compile.lazyDropOnMemoryPressure", default: false)
    /// One stderr line per completed reclaim cycle (`[jeffjs:reclaim] …`).
    static let lazyDropDebug       = bool("compile.lazyDropDebug",     default: false)
    /// Engine testing: every idle tick runs a memory-pressure reclaim, so
    /// every lazily compiled body is dropped and recompiled between tasks
    /// (`JEFFJS_COMPILE_LAZYDROPSTRESS=1 swift test …`).
    static let lazyDropStress      = bool("compile.lazyDropStress",    default: false)

    // MARK: - Web Storage

    /// Bytes one origin's `localStorage` may hold (keys + values, WebKit's
    /// `StorageMap` counting: a string of Latin-1 code units costs one byte
    /// per unit, any other two). Safari: 5 MB; watch-sized on watchOS. A
    /// `setItem` past it throws `QuotaExceededError`.
    static let storageLocalQuotaBytes = int("storage.localQuotaBytes", default: platformBudget(iOS: 5, watch: 1))
    /// The same for one origin's `sessionStorage` (in memory).
    static let storageSessionQuotaBytes = int("storage.sessionQuotaBytes", default: platformBudget(iOS: 5, watch: 1))
    /// Bytes every origin's persisted `localStorage` may hold together; a host
    /// store evicts whole origins, least recently used first, past it.
    static let storageTotalBudgetBytes = int("storage.totalBudgetBytes", default: platformBudget(iOS: 50, watch: 8))
    /// One `[WebStorage] …` line per write (`JEFFJS_STORAGE_DEBUG=1`); quota
    /// rejections are always printed.
    static let storageDebug = bool("storage.debug", default: false)

    // MARK: - Interpreter

    /// Inline-cache tables have a fixed 512 slots (28 KB) instead of the next
    /// power of two ≥ the function's bytecode length (`JeffJSInlineCache`,
    /// IC table size fix 2026-09-29). A/B: `JEFFJS_INTERP_ICTABLEFIXED=1`.
    static let icTableFixed        = bool("interp.icTableFixed",       default: false)

    /// `await` inside an async function / async generator always suspends and
    /// resumes from a job (ES §27.7.5.3). false = the old synchronous
    /// unwrapping (A/B: `JEFFJS_INTERP_AWAITALWAYSSUSPENDS=0`).
    static let awaitAlwaysSuspends = bool("interp.awaitAlwaysSuspends", default: true)

    // MARK: - Trace Blocks

    static let traceHitThreshold   = int("trace.hitThreshold",         default: 2)

    // MARK: - Stack / Memory

    static let maxCallDepth        = int("stack.maxCallDepth",         default: 200)
    static let maxLocalVars        = int("stack.maxLocalVars",         default: 65534)
    static let maxStackSize        = int("stack.maxStackSize",         default: 65534)
    static let defaultStackSize    = int("stack.defaultSize",          default: 1024 * 1024)
    static let bufPoolMax          = int("stack.bufPoolMax",           default: 32)

    // MARK: - GC

    static let gcMallocThreshold   = int("gc.mallocThreshold",        default: 256 * 1024)
    static let gcObjectCost        = int("gc.objectCost",              default: 256)
    static let gcMetalThreshold    = int("gc.metalThreshold",          default: 5000)
    /// Idle collection (`jeffJS_idleGCTick`): collect between tasks once the
    /// live heap grew by 1/2^shift since the last collection (0 = off) ...
    static let gcIdleGrowthShift   = int("gc.idleGrowthShift",         default: 6)
    /// ... and at least this long after it ended.
    static let gcIdleIntervalMs    = int("gc.idleIntervalMs",          default: 1000)
    /// True when the crossover was named in the environment. `JEFFJS_GC_METAL=1`
    /// otherwise drops it to zero so "use the GPU collector" means every
    /// collection, not only the ones on a 5 000-object heap.
    static let gcMetalThresholdIsExplicit = envOverride("gc.metalThreshold").flatMap(Int.init) != nil
    static let gcMetalThreadGroupSize = int("gc.metalThreadGroupSize", default: 256)
    static let gcMetalMaxRescue    = int("gc.metalMaxRescueIterations", default: 100)
    /// `JEFFJS_GC_VERIFYROOTS=1`: before every collection, check that each entry
    /// of the runtime's GC list is a live header of this runtime (class, list
    /// index, owner), and log every change of the thread that mutates the list
    /// (JeffJSThreadCheck.swift). Debug instrument; off by default.
    static let gcVerifyRoots       = bool("gc.verifyRoots",            default: false)
    /// `JeffJSRuntime.free()` frees the heap that is still alive (objects, the
    /// strings and bytecode they hold) as one dead group before it empties the
    /// lists; false = the old behaviour, which only dropped the references and
    /// leaked every live object's allocation (A/B: JEFFJS_GC_TEARDOWNFREESHEAP=0).
    static let gcTeardownFreesHeap = bool("gc.teardownFreesHeap",      default: true)

    // MARK: - Atoms

    static let atomsInitialHashSize = int("atoms.initialHashSize",     default: 1024)

    // MARK: - Shapes

    static let shapesHashBits      = int("shapes.hashBits",           default: 4)
    /// Shape-table size above which a collection also sweeps zero-owner
    /// hashed shapes out of the transition table (see
    /// `jeffJS_evictHashedShapes`). Below it the sweep is not worth the walk:
    /// a small program's shapes are all live.
    static let shapesEvictThreshold = int("shapes.evictThreshold",     default: 512)
    /// Max shared (hashed) shapes kept alive in the transition table.
    static let shapesMaxHashed     = int("shapes.maxHashed",          default: 16384)
    /// A transition that would make a hashed shape with more than this many properties
    /// gives the object a private shape instead (a dictionary-mode object that then grows in
    /// place). Every hashed transition shape keeps a full copy of its property table, so an
    /// object built key by key to N properties left N cached shapes and N²/2 slots behind
    /// (threes.day: +146 MB in 250 ms on the Apple Watch, JSON maps keyed by player id).
    /// 0 = no limit (the old behaviour, A/B: JEFFJS_SHAPES_MAXHASHEDPROPS=0).
    static let shapesMaxHashedProps = int("shapes.maxHashedProps",    default: 64)

    // MARK: - Strings / Ropes

    static let ropeShortLen        = int("strings.ropeShortLen",       default: 512)
    static let ropeShort2Len       = int("strings.ropeShort2Len",     default: 8192)
    static let ropeMaxDepth        = int("strings.ropeMaxDepth",      default: 60)

    // MARK: - Regex

    static let regexMetalThreadGroupSize = int("regex.metalThreadGroupSize", default: 256)

    // MARK: - Jobs

    static let maxJobsPerDrain     = int("jobs.maxPerDrain",           default: 1000)

    // MARK: - Interrupt

    static let interruptCounterInit = int("interrupt.counterInit",     default: 10000)

    // MARK: - Security

    /// When true, dynamic import() of http:// and https:// URLs is blocked.
    /// Local/relative imports still work. Default: false (allow remote imports).
    static let blockRemoteImports  = bool("security.blockRemoteImports", default: false)

    // MARK: - Quantum Cache & Transport

    /// Master switch for the quantum storage subsystem.
    static let quantumEnabled          = bool("quantum.enabled",           default: false)
    /// Prefer Metal GPU search when available. Falls back to CPU if false or unavailable.
    static let quantumPreferGPU        = bool("quantum.preferGPU",         default: true)
    /// Bits encoded per chain step (2 = 4 slices, 3 = 8, 4 = 16).
    static let quantumDataBits         = int("quantum.dataBits",           default: 2)
    /// Max data values per chain before splitting into multiple keys.
    static let quantumMaxChainValues   = int("quantum.maxChainValues",     default: 8)
    /// Maximum seed-offset attempts when encoding.
    static let quantumMaxEncodeAttempts = int("quantum.maxEncodeAttempts", default: 100)
}
