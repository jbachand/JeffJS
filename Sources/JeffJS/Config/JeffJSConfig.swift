// JeffJSConfig.swift
// Loads JeffJSConfig.plist and exposes all engine flags as static properties.
// Single source of truth — edit the plist, not the code.

import Foundation

enum JeffJSConfig {

    // MARK: - Plist backing store (loaded once at process start)

    private static let dict: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "JeffJSConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return [:]
        }
        return plist
    }()

    private static func bool(_ key: String, default d: Bool) -> Bool {
        dict[key] as? Bool ?? d
    }
    private static func int(_ key: String, default d: Int) -> Int {
        dict[key] as? Int ?? d
    }
    private static func string(_ key: String, default d: String) -> String {
        dict[key] as? String ?? d
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
    static let bytecodeMaxSize     = int("cache.bytecodeMaxSize",      default: 1_000_000)

    // MARK: - Trace Blocks

    static let traceHitThreshold   = int("trace.hitThreshold",         default: 16)

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
    static let gcMetalThreadGroupSize = int("gc.metalThreadGroupSize", default: 256)
    static let gcMetalMaxRescue    = int("gc.metalMaxRescueIterations", default: 100)

    // MARK: - Atoms

    static let atomsInitialHashSize = int("atoms.initialHashSize",     default: 1024)

    // MARK: - Shapes

    static let shapesHashBits      = int("shapes.hashBits",           default: 4)

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
