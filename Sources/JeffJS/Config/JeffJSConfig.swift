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
