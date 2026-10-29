// JeffJSConfig.swift
// Loads JeffJSConfig.plist and exposes all engine flags as static properties.
// Single source of truth — edit the plist, not the code.

import Foundation

/// Bundle holding the engine's resources (config plist, Metal shaders).
///
/// `Bundle.module` is synthesized by SwiftPM only. These sources are also
/// compiled directly into a host app (React Natively builds the engine into
/// its own module), where the resources ship in the app bundle instead.
nonisolated(unsafe) let jeffJSResourceBundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle.main
    #endif
}()

nonisolated enum JeffJSConfig {

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
    /// Cache entries on disk are used in place: a hit maps the entry file
    /// read-only and deserializes out of the mapping (no heap copy of the
    /// blob), the in-memory tier keeps mappings (count-capped LRU,
    /// `cache.bytecodeMappedEntries`) instead of blob copies, and a fresh
    /// compile is not copied into the memory tier when its disk write is
    /// accepted (a lookup waits for the write and maps it). Only entries
    /// that never reach the disk (one-shot texts, no disk tier) still use
    /// the `bytecodeMemoryBudgetBytes` heap tier. perf/bytecode-paging.
    /// `JEFFJS_CACHE_BYTECODEMAPPED=0` = the in-heap copies.
    static let bytecodeMapped      = bool("cache.bytecodeMapped",      default: true)
    /// Mappings the memory tier keeps for reuse (LRU by count; a mapping
    /// costs address space and page tables, no heap; a mapping a live
    /// script still uses stays mapped whatever this says).
    static let bytecodeMappedEntries = int("cache.bytecodeMappedEntries", default: platformBudget(iOS: 64, watch: 16) / (1024 * 1024))

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
    /// Native twins (Builtins/Twins/JeffJSNativeTwins.swift): a recognised
    /// library function (same code as a known npm build, compared by its
    /// bytecode with every minified name left out) runs as Swift when its
    /// guards hold. `JEFFJS_NATIVETWINS_ENABLED=0` turns the lookup off.
    static let nativeTwins         = bool("nativeTwins.enabled",       default: true)
    /// `JEFFJS_NATIVETWINS_DEBUG=1`: one stderr line per recognised body and
    /// per declined call (the guard that failed), and a hit count.
    static let nativeTwinsDebug    = bool("nativeTwins.debug",         default: false)
    /// Script text kept for lazy compilation / `Function.prototype.toString`
    /// lives in the bytecode-cache entry's file mapping instead of the heap:
    /// on a cache hit the deserializer uses the entry's text in place, and
    /// after a fresh compile's entry lands on disk the heap text is swapped
    /// for the mapped one (`JeffJSSourceText.adoptMapping`). Lazy compiles
    /// parse straight out of the mapping. perf/bytecode-paging.
    /// `JEFFJS_COMPILE_MAPPEDSOURCE=0` = the heap copy.
    static let compileMappedSource = bool("compile.mappedSource",      default: true)
    /// `JeffJSPrecompiler.precompileScript` compiles a script on the calling
    /// (background) thread into the disk tier, so the JS thread maps it
    /// instead of compiling. `JEFFJS_COMPILE_OFFTHREADPRECOMPILE=0` = no-op.
    static let compileOffThreadPrecompile = bool("compile.offThreadPrecompile", default: true)
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
    /// A lazy candidate's parsed-then-dropped body gives back the string /
    /// BigInt literals of its constant pool (JeffJSCompiler.releaseDroppedConstants);
    /// false = the old leak, one reference per literal per parse (A/B:
    /// JEFFJS_COMPILE_LAZYDROPFREESCONSTANTS=0).
    static let lazyDropFreesConstants = bool("compile.lazyDropFreesConstants", default: true)
    /// A pure-data object/array literal (its source span is valid JSON, no
    /// `__proto__` key) of at least `compile.lazyLiteralMinBytes` compiles to
    /// a lazy payload (JeffJSLazyPayload.swift) instead of the object-building
    /// bytecode. `JEFFJS_COMPILE_LAZYLITERALS=0` = eager.
    static let compileLazyLiterals = bool("compile.lazyLiterals",      default: true)
    static let compileLazyLiteralMinBytes = int("compile.lazyLiteralMinBytes", default: 16384)

    // MARK: - JSON

    /// `JSON.parse` of an object/array text of at least
    /// `json.lazyThresholdBytes` returns a lazy payload (memory proportional
    /// to what is read; JeffJSLazyPayload.swift). `JEFFJS_JSON_LAZY=0` = eager.
    static let jsonLazy            = bool("json.lazy",                 default: true)
    static let jsonLazyThresholdBytes = int("json.lazyThresholdBytes", default: 16384)
    /// Also revert pristine materialized payload objects at the idle GC
    /// (default: only on memory pressure / `JeffJSRuntime.evictLazyPayloads`).
    static let jsonLazyEvictOnIdle = bool("json.lazyEvictOnIdle",      default: false)

    // MARK: - WebAssembly

    /// The `WebAssembly` namespace (Sources/JeffJS/Wasm/, issue #13): a decoder, validator and
    /// interpreter with the JS API. `JEFFJS_WASM_ENABLED=0` leaves it out (no global at all).
    static let wasmEnabled = bool("wasm.enabled", default: true)

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
    /// Inline-cache tables have one slot per IC site of the function (an
    /// ordinal from the bytecode walk, `JeffJSInlineCache`) instead of one per
    /// bytecode offset (~95 % empty). A/B: `JEFFJS_INTERP_ICORDINALTABLES=0`
    /// = the bytecode-offset tables sized to the bytecode.
    static let icOrdinalTables     = bool("interp.icOrdinalTables",    default: true)

    /// `await` inside an async function / async generator always suspends and
    /// resumes from a job (ES §27.7.5.3). false = the old synchronous
    /// unwrapping (A/B: `JEFFJS_INTERP_AWAITALWAYSSUSPENDS=0`).
    static let awaitAlwaysSuspends = bool("interp.awaitAlwaysSuspends", default: true)

    /// Array iterators share one `next` on %ArrayIteratorPrototype% and keep
    /// their state in three slots on a cached shape (they used to get two new
    /// native closures each and string-keyed slots); for-of / spread /
    /// array destructuring step over them inline (no `next` call, no
    /// `{value, done}` object), and `append` (spread) pushes in place.
    /// Watch interpreter speed fix (2026-10-05). A/B: `JEFFJS_INTERP_FASTITERATORS=0`.
    static let fastIterators       = bool("interp.fastIterators",      default: true)

    /// Array builtins skip work a plain array never needs: ArraySpeciesCreate
    /// on an array whose constructor is the intrinsic %Array% (and whose
    /// @@species getter is the original) makes the array directly instead of
    /// `new Array(n)` through the constructor; `concat` copies dense arrays
    /// slot to slot. A/B: `JEFFJS_INTERP_FASTARRAYBUILTINS=0`.
    static let fastArrayBuiltins   = bool("interp.fastArrayBuiltins",  default: true)

    /// Calls of native functions from the main interpreter loop pass their
    /// arguments straight from the VM stack (a reused argument array, as the
    /// fast trace does) instead of allocating an array and going through
    /// `callFunction`; `f.call(thisArg, …)` with a native `f` (e.g.
    /// `Object.prototype.toString.call(x)`) calls `f` directly.
    /// A/B: `JEFFJS_INTERP_FASTNATIVECALLS=0`.
    static let fastNativeCalls     = bool("interp.fastNativeCalls",    default: true)

    /// Cheaper entry into the interpreter from native code (array callbacks,
    /// promise jobs, timers): interpreter buffers pooled on a fixed unsafe
    /// stack, one stack-overflow check per native→JS call instead of two, and
    /// the array builtins' callbacks reuse one argument array per call
    /// instead of allocating one per element. A/B: `JEFFJS_INTERP_FASTCALLENTRY=0`.
    static let fastCallEntry       = bool("interp.fastCallEntry",      default: true)

    /// Object builtins without per-call allocation where the answer is fixed:
    /// `Object.prototype.toString` returns cached "[object Tag]" strings for
    /// the builtin tags, `Object.getOwnPropertySymbols` walks the shape once
    /// for symbol keys only. A/B: `JEFFJS_INTERP_FASTOBJECTBUILTINS=0`.
    static let fastObjectBuiltins  = bool("interp.fastObjectBuiltins", default: true)

    /// Freeing an object whose count reached zero reuses one scratch list per
    /// runtime for the batch it releases, instead of allocating a Swift array
    /// per freed object. A/B: `JEFFJS_INTERP_FASTFREECHAIN=0`.
    static let fastFreeChain       = bool("interp.fastFreeChain",      default: true)

    /// `arguments` objects and rest parameters are built straight from the
    /// frame's argument slots: no materialised `argBuf`/`varBuf` copies per
    /// creation (two array allocations), property storage sized once, and
    /// the rest array filled in one shot. A mapped/unmapped arguments object
    /// cost ~16k / ~11k instructions per call (QuickJS ~1.2k); Babel's
    /// `_objectSpread2` / `_extends` helpers create one per call.
    /// A/B: `JEFFJS_INTERP_FASTARGUMENTS=0`.
    static let fastArguments       = bool("interp.fastArguments",      default: true)

    /// Naming a fresh closure (`var f = function () {}`, `{ m: () => {} }`,
    /// set_name) and materialising a function's deferred `length` / `name`
    /// put both slots on the cached `[length, name]` transition shape in one
    /// step: set_name used to materialise both through two defineProperty
    /// transitions and then define `name` a third time (~30% of a
    /// closure-heavy loop). A/B: `JEFFJS_INTERP_FASTFUNCTIONNAME=0`.
    static let fastFunctionName    = bool("interp.fastFunctionName",   default: true)

    /// The fast trace runs `f.call(thisArg, …)` as a direct call of `f` (the
    /// stack rewritten to a method call; bytecode `f` inline, native `f`
    /// dispatched once) instead of a native call of Function.prototype.call
    /// that re-entered callFunction with a sliced argument array (deepmerge's
    /// `Object.hasOwnProperty.call` / `propertyIsEnumerable.call` /
    /// `Object.prototype.toString.call`: ~2.9k → ~1k instructions). Watch CPU
    /// fix (2026-10-07). A/B: `JEFFJS_INTERP_TRACECALLINTRINSIC=0`.
    static let traceCallIntrinsic  = bool("interp.traceCallIntrinsic", default: true)

    /// Native→JS calls of plain bytecode functions (array callbacks, promise
    /// jobs, timers, `Function.prototype.call/apply`) skip work the
    /// activation never needs: no materialised argument array on the frame
    /// (a retain, a release and a uniqueness check per call), and
    /// callFunction reaches callInternal without strong object / body
    /// references. Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_LEANCALLENTRY=0`.
    static let leanCallEntry       = bool("interp.leanCallEntry",      default: true)

    /// Native calls from the VM stack pass their arguments in one reused
    /// array per argument count, written in place (no append / removeAll /
    /// memmove per call), and a shared empty array for no arguments.
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_LEANNATIVEARGS=0`.
    static let leanNativeArgs      = bool("interp.leanNativeArgs",     default: true)

    /// `typeof` picks its cached result string by an index computed from the
    /// value (it built a Swift String and matched it against eight literals
    /// per evaluation). Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_FASTTYPEOF=0`.
    static let fastTypeof          = bool("interp.fastTypeof",         default: true)

    /// The runtime's cached JS string for a string atom (what Object.keys,
    /// for-in and getOwnPropertyNames hand out) carries that atom as its
    /// property key, and string keys are interned through the string
    /// (`findAtom(jsString:)`, cached) by `in` and hasOwnProperty, so a key
    /// read from Object.keys hits the keyed inline caches and the own-property
    /// fast paths instead of re-hashing a Swift String per use (deepmerge's
    /// `t in e`, `hasOwnProperty.call(e, t)`, `n[a] = …`).
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_ATOMKEYSTRINGS=0`.
    static let atomKeyStrings      = bool("interp.atomKeyStrings",     default: true)

    /// `Object.prototype.propertyIsEnumerable` on an ordinary object with a
    /// named key reads the enumerable bit off the shape instead of building
    /// a descriptor object (~11k → ~1k instructions).
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_FASTOWNPROPERTY=0`.
    static let fastOwnProperty     = bool("interp.fastOwnProperty",    default: true)

    /// Prototype-chain walks of [[Get]] and [[HasProperty]] read each
    /// prototype as an unretained pointer (the shapes own the references)
    /// instead of a retain/release pair per level.
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_UNRETAINEDPROTOWALK=0`.
    static let unretainedProtoWalk = bool("interp.unretainedProtoWalk", default: true)

    /// String `===` / `==` compares interned keys by atom and everything else
    /// with one memcmp (it copied both storage enums and compared the arrays
    /// element by element). Watch CPU fix (2026-10-07).
    /// A/B: `JEFFJS_INTERP_FASTSTRINGEQUALS=0`.
    static let fastStringEquals    = bool("interp.fastStringEquals",   default: true)

    /// Symbol values are counted like strings (one cast to the shared string
    /// base) instead of a dynamic `as?` chain per dup/free (`e.$$typeof ===
    /// REACT_ELEMENT_TYPE` paid two). Watch CPU fix (2026-10-07).
    /// A/B: `JEFFJS_INTERP_FASTSYMBOLREFCOUNT=0`.
    static let fastSymbolRefcount  = bool("interp.fastSymbolRefcount", default: true)

    /// Closure creation keeps the root shape of plain closures on the context
    /// (no hashed-shape lookup per closure) and finds a parent slot's live
    /// var-ref with a plain loop (no per-element retain).
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_FASTCLOSURE=0`.
    static let fastClosure         = bool("interp.fastClosure",        default: true)

    /// Plain arrays (own `length` only, prototype %Array.prototype%) skip the
    /// generic lookups ArraySpeciesCreate and IsConcatSpreadable make when the
    /// intrinsics are untouched (read off the shapes directly), and builtins
    /// that return a new array fill its pooled element store in place.
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_FASTSPECIES=0`.
    static let fastSpecies         = bool("interp.fastSpecies",        default: true)

    /// A frame's live var-refs that no closure holds any more when the frame
    /// returns (the closure was a callback that already died) are parked
    /// for the next closure instead of being detached into a copy nobody
    /// can read (dup + GC-list insert + later removal and free).
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_RECYCLEVARREFS=0`.
    static let recycleVarRefs      = bool("interp.recycleVarRefs",     default: true)

    /// An empty array literal (`object; array_from 0`: the object is a
    /// sentinel array_from drops) creates the array directly instead of a
    /// throwaway plain object plus the array. Watch CPU fix (2026-10-07).
    /// A/B: `JEFFJS_INTERP_FASTARRAYLITERAL=0`.
    static let fastArrayLiteral    = bool("interp.fastArrayLiteral",   default: true)

    /// A closure's var-refs live only in its varRefsFast array (and the raw
    /// mirror), not also in the payload enum, and a recycled closure keeps
    /// that array's storage for the next closure built on it.
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_LEANCLOSUREPAYLOAD=0`.
    static let leanClosurePayload  = bool("interp.leanClosurePayload", default: true)

    /// Adding an ordinary data property by assignment (`o[k] = v` on a key
    /// the object lacks) goes straight to the shape transition and appends
    /// the value (no property enum built and copied, no redundant own
    /// lookup), and a keyed write that added its property does not
    /// overwrite the site's inline-cache entry with the post-add shape.
    /// Watch CPU fix (2026-10-07). A/B: `JEFFJS_INTERP_FASTPROPERTYADD=0`.
    static let fastPropertyAdd     = bool("interp.fastPropertyAdd",    default: true)

    // MARK: - Trace Blocks

    static let traceHitThreshold   = int("trace.hitThreshold",         default: 2)

    // MARK: - Stack / Memory

    static let maxCallDepth        = int("stack.maxCallDepth",         default: 200)
    static let maxInlineDepth      = int("stack.maxInlineDepth",       default: 10000)
    static let maxLocalVars        = int("stack.maxLocalVars",         default: 65534)
    static let maxStackSize        = int("stack.maxStackSize",         default: 65534)
    static let defaultStackSize    = int("stack.defaultSize",          default: 1024 * 1024)
    static let bufPoolMax          = int("stack.bufPoolMax",           default: 32)

    /// Interpreter value buffers come from one segmented bump stack per
    /// runtime (perf/task-spikes) instead of a pooled 8 192-slot (64 KB)
    /// buffer per non-inline activation. Activations nest, so their buffers
    /// are claimed and given back in LIFO order: a claim is a pointer bump in
    /// the current segment, a release a pointer move back. While little of the
    /// stack is in use a claim keeps the old headroom (`bufBigSlots`) for the
    /// inline callees carved out of it; past `bufBigLimitSlots` used slots it
    /// shrinks to `bufMidSlots`, past `bufMidLimitSlots` to the frame itself.
    /// A native↔JS recursion 3 000 levels deep (a stack-depth probe through
    /// `f.call`) held 3 000 × 64 KB = 190 MB; it now holds ~2 MB + its frames.
    /// A/B: `JEFFJS_INTERP_SEGMENTEDSTACK=0` (the pooled 64 KB buffers).
    static let segmentedStack      = bool("interp.segmentedStack",     default: true)
    /// Slots per segment (8 bytes each); a claim larger than this gets a
    /// segment of its own.
    static let stackSegmentSlots   = int("interp.stackSegmentSlots",   default: 65536)
    static let bufBigSlots         = int("interp.bufBigSlots",         default: 8192)
    static let bufBigLimitSlots    = int("interp.bufBigLimitSlots",    default: 131072)
    static let bufMidSlots         = int("interp.bufMidSlots",         default: 1024)
    static let bufMidLimitSlots    = int("interp.bufMidLimitSlots",    default: 262144)

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
    /// With gcTeardownFreesHeap: the contexts' intrinsics (built before
    /// `initComplete`, never on the GC list) are freed with the rest of the heap
    /// (JeffJSRuntime.initObjects); false = they — and through their back-pointers
    /// the runtime and its contexts — outlive `free()` (A/B:
    /// JEFFJS_GC_TEARDOWNFREESINITOBJECTS=0).
    static let gcTeardownFreesInitObjects = bool("gc.teardownFreesInitObjects", default: true)
    /// The 2026-10-05 refcount-leak fixes (perf/watch-object-size): builtins
    /// and conversions that dropped an owned value un-freed — ToPrimitive /
    /// ToString of objects, `+` and comparisons on objects, Array join,
    /// propertyIsEnumerable, getOwnPropertyDescriptors, Object.fromEntries,
    /// early-closed Map/Set iterators, the async-function capability.
    /// true = the old leaking behaviour, for A/B (JEFFJS_GC_LEGACYREFLEAKS=1).
    static let gcLegacyRefLeaks    = bool("gc.legacyRefLeaks",         default: false)
    /// Allocation trigger (perf/task-spikes, JeffJSAllocationTrigger.swift):
    /// bytes allocated outside the object count — string payloads of 512+
    /// code units, interpreter stack segments, ArrayBuffer stores — since the
    /// last collection. Past this many (or half the live heap estimate, if
    /// larger) the next object allocation collects: the object-count trigger
    /// never fired on a task that held its memory in a few hundred big strings.
    /// 0 = off. The watch sets it lower (`JEFFJS_GC_BYTESSINCEGCTHRESHOLD`).
    static let gcBytesSinceGCThreshold = int("gc.bytesSinceGCThreshold", default: 64 * 1024 * 1024)
    /// Every this many such bytes the host's memory hook (the interrupt
    /// handler, `JeffJSRuntime.setInterruptHandler`, unless a dedicated
    /// `memoryHook` is set) is called synchronously from the allocation, so a
    /// burst inside one task — even inside one native call — is seen at the
    /// allocation instead of at the host's next sample. When it asks for
    /// termination, the next interrupt check comes at the next loop back-edge.
    /// 0 = off (`JEFFJS_GC_BYTESSINCEHOOKTHRESHOLD`).
    static let gcBytesSinceHookThreshold = int("gc.bytesSinceHookThreshold", default: 0)
    /// `Function.prototype.toString` of a function with 16 KB+ of source
    /// returns a shared string from a small per-runtime cache instead of a
    /// fresh copy per call (JeffJSFunctionSourceCache).
    /// A/B: `JEFFJS_STRINGS_FUNCTIONSOURCECACHE=0`.
    static let functionSourceCache = bool("strings.functionSourceCache", default: true)
    /// Recycle dying closures with their side box (jeffJS_recycleFunction);
    /// false = every closure is a fresh object + side box (A/B,
    /// JEFFJS_GC_FUNCTIONPOOL=0).
    static let gcFunctionPool      = bool("gc.functionPool",           default: true)
    /// Share short strings (JeffJSContext.sharedString: "", conversion
    /// constants, DOM tag names) and dedup short JSON.parse values; false =
    /// a fresh string every time (A/B, JEFFJS_GC_SHAREDSTRINGS=0).
    static let gcSharedStrings     = bool("gc.sharedStrings",          default: true)

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
