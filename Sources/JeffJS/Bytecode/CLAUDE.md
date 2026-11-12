# JeffJS Bytecode — Claude neuron

> Area: `Sources/JeffJS/Bytecode/` · Repo: engine · Last reviewed: 2026-11-11 (app fafaacd / engine perf/manual-memory-frames)

## Purpose
The middle of the QuickJS pipeline as ported to Swift: the parser's raw bytecode (`../Parser/`) comes in, the
compiler passes (`resolveVariables`, `resolveLabels`, `fuseBasicBlocks`, lazy stubs) turn it into final
`JeffJSFunctionBytecode`, the interpreter runs it, and the cache serialises it to/from `.jfbc` so a page or the app's
static polyfills skip parse + compile. Callers: `JeffJSContext.eval` / `evalPrecompiled` (`../Core/JeffJSContext.swift`),
`callFunction`/`callInternal`, the host (React Natively's `JSScriptEngine`) for precompiles, interrupts and idle ticks.
QuickJS counterparts are named in each file header.

## Key files
- `JeffJSOpcodes.swift` — the opcode table (name, size, n_pop/n_push, format; port of `quickjs-opcode.h`) plus
  JeffJS-only fused/short opcodes. Part of the cache identity (below).
- `JeffJSCompiler.swift` — post-parse passes (`resolveVariables`, `resolveLabels`, `fuseBasicBlocks` trace regions),
  `lazyStubOrEager` / `compileLazy` (bodies compiled on first call), `JeffJSVarDef` scope model.
- `JeffJSInterpreter.swift` (~15 k lines) — `callFunction`/`callInternal`, the main dispatch loop, the "Fast Trace
  Mini-Interpreter" and "Lean fast trace" (loops without calls), inline call frames on the runtime's heap stack,
  interrupt check, type-conversion / operator helpers, `JEFFJS_REFERR_DEBUG` (end of file).
- `JeffJSBytecodeCache.swift` — JFBC serializer (atom remapping) + the two-tier cache (`JeffJSBytecodeCache` memory,
  `JeffJSBytecodeDiskStore` disk), cache keys, engine identity, the `<hash>-bodies.jfbc` lazy-body sidecar (JLZB).
- `JeffJSPrecompiler.swift` — `precompileScript(text, filename:)`: compile off the JS thread into the disk tier in a
  private runtime (never runs code; one at a time; a JS-thread lookup of an in-flight key waits for it).
- `JeffJSLazyReclaim.swift` — idle reclaim of lazily compiled bodies (bytecode, IC table, trace data, pc→line).
- `JeffJSColdErrors.swift` — `jeffJS_coldThrow` out-of-line error texts so LLVM does not hoist their string constants
  into `callInternal`'s prologue (they were stored to the stack on every call).
- `JeffJSJSProfiler.swift` — JS-level sampling profiler, compiled only under `-DJEFFJS_JSPROF` (`[jsprof] …` at exit).
- `JeffJSStackDiag.swift` — value-stack overflow reporter (`overflowCount`, `currentLabel` read by `EngineTests`).

## Invariants
- **`fb` in `callInternalRaw` / `executeFastTrace` is a `JeffJSFBHandle`** ([Core](../Core/CLAUDE.md) `JeffJSFBRef.swift`), not the class: pass it to a function that takes the class as `fb.object` (cold; a retain) or `fb.with { … }` (hot; borrowed), compare identities with `fb.identity`, look a callee up with `fbFastH`. Build both `swift build` and `JEFFJS_MANUAL_MEMORY=1 swift build --scratch-path .build-mm` after touching the dispatch.
- **Cache identity = engine identity, never the app binary.** Disk dir `Caches/JeffJSBytecodeCache/v<diskVersion 5>-cv<compilerVersion 19>-<engineIdentity>`;
  identity mixes `compilerVersion`, `JFBC_VERSION` (7), the entry header version, `engineSourceHash` (FNV-1a of
  `Parser/*.swift`, `JeffJSCompiler.swift`, `JeffJSOpcodes.swift`, `JeffJSBytecodeCache.swift`) and the opcode table.
  Other dirs under the root are deleted at open. **After any Parser/Compiler/Opcodes edit run
  `Scripts/update_bytecode_identity.sh`** (`--check` to verify); `BytecodeCacheBudgetTests.testEngineSourceHashIsCurrent`
  fails otherwise. Bump `compilerVersion` for a semantic change (its comment is the changelog), then regenerate the app's
  `.jfbc` (`Scripts/precompile_polyfills.sh` in the app: flip `build.precompilePolyfills` true for the run, restore it).
- Cache keys separate script vs module, strict vs sloppy, filename and flags (`BytecodeCacheKeyTests`); source text
  alone was the key once and the first compile won.
- Per-call-unique glue sources must be excluded from the cache: `cache.bytecodeExcludePrefixes` (engine default
  `<eval>,<onclick>,<diag>`; the app plist adds `<current-script>`, `<native-`, `<viewport>`, …). **A new host glue
  filename whose text differs per call goes on that list** — every distinct text is parsed, compiled and written to disk.
- Disk writes: a pseudo-named source (`<…>`, not `<inline…>`) is written only on its **second** sighting in the process,
  on a serial background queue, ≤ 256 entries / 48 MB per runtime; script URLs on the first sighting. Tests that read entry
  files call `JeffJSBytecodeCache.flushPendingDiskWrites()` first. `JEFFJS_CACHE_BYTECODEWRITESYNC=1` = old sync writes.
- `cache.bytecodeMaxSize` caps the **serialized** entry (0 = none). The app plist uses 1 000 000 000 because an older
  pinned engine compared it with top-level bytecode length where 0 disabled caching.
- Lazy bodies: a function compiled by `compileLazy` reaches its body via `fbFast`; a reclaim cycle clears `fbFast`, the
  next call's payload path re-sets it and stamps `lazyInfo.touch`. Slices run only at idle points (no JS on the stack);
  **never run a body while it may be dropped**. Bodies persist in the `-bodies.jfbc` sidecar (checksum per record).
- **Inline-cache deep fill (`jeffJS_icFillDeep`, `../Core/JeffJSObject.swift`): any new IC fill must check every nearer
  level for the atom first** (receiver shape, then depth-1) before caching a holder two or three prototypes up. Caching
  the deeper one skipped a shadowing property: `input.type` read HTMLElement.prototype's reflector and React's onChange
  never fired. Gate: conformance group `InterfaceShadowIC` (`InterfaceShadowICConformance.swift`).
- Realms: a function object's realm is `realmIndex`; `callFunction`/`callConstructor` switch via `callInRealm` when it
  differs. **Any new interpreter fast path that calls without `callFunction`/`callInternal` must check
  `realmIndex == ctxRealm`** (the trace loop does: `nObj.realmIndex == ctxRealm`).
- Call depth: `stack.maxCallDepth` (native frames; engine plist 200, app 200 000) and `stack.maxInlineDepth` (inline frames
  on the heap stack; engine 10 000, app 60 000 ≈ 30 MB, watch 10 000 via `setenv`) both throw
  `RangeError: Maximum call stack size exceeded.` — never reintroduce V8 wording (pages fingerprint error text).
- Bytecode lifetime: a function object's payload does **not** refcount its bytecode — `liveClosures` does. New code that
  makes a `.bytecodeFunc` payload must bump `liveClosures` (freeObject drops it); after a top-level eval the
  non-function constants and nested bodies with `liveClosures == 0` are released (`JEFFJS_EVAL_KEEPTOPLEVELCONSTANTS=1`,
  `JEFFJS_EVAL_KEEPNESTEDBODIES=1` = old). `definePropertyValue` dups its value (not QuickJS's consume).
- Microtasks: an async host callback that settles a promise must run a checkpoint — `rt.executePendingJobs()` at
  `callDepth == 0` (the dynamic-import bridge forgot; `await import(x)` hung). `DynamicImportCheckpointTests`.
- Interrupts: `rt.setInterruptHandler` returning true ends the script uncatchably (`checkInterrupt`, counter kept in a
  register in the trace loop); afterwards the context must be idle (depth 0, no inline frames) — the app's unload budget
  (`RN_UNLOAD_BUDGET_MS`), page abort and watch memory stop rely on it. `InterruptTerminationTests`.
- One JS thread per runtime: `eval`/`evalPrecompiled` enter the runtime (`../Core/JeffJSThreadCheck.swift`); Debug traps
  on a second thread. Every top-level declaration here is `nonisolated` (the app compiles the engine under
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; `EngineThreadingRuleTests.testTopLevelDeclarationsAreNonisolated`).
- Release builds compile with `-enforce-exclusivity=unchecked` (`Package.swift`): the dynamic checks were ~30 % of an
  arithmetic loop, 1.5–2.3x overall; the engine is single-threaded per runtime so static exclusivity suffices.
  Correctness is gated by the conformance suite. (It makes the package ineligible as a remote SwiftPM dependency.)

## Gotchas
- **The parser must never identify an instruction by peeking a fixed offset back from the end of emitted bytes**: every
  `obj[key]` read is preceded by a tagged `line_num` expression span, so a byte at `len - 5` is span payload
  (`lastEmittedIsGetField` compiled `this["dR"]^=this["qR"]` as a store; walk instruction boundaries forward).
- A stale `compilerVersion` header in the app's `precompiled_static_polyfills.jfbc` silently falls back to parsing
  source: slow startup after an engine pull = regenerate the `.jfbc`.
- Expression spans / `global code` frame name on a cache hit were lost once by a merge (fixed at compilerVersion 17,
  `EXT_SPANS`/`EXT_TOPLEVEL`); if JSC-style "(evaluating '…')" text vanishes on a warm cache, check those record bits.
- Debug builds use far more native stack per JS call level than Release (app root doc: ~47 KB vs ~2 KB), so legit deep
  recursion trips the simulator's 8 MB main thread; `JEFFJS_STACK_DEBUG=1` prints the JS stack at the trip. For heavy
  pages build Debug with `-O` and a larger `-stack_size`.
- IC tables are sized to the bytecode (next power of two ≥ length, 8–512 slots, `InlineCacheSizingTests`) and indexed by
  IC-site ordinal (`InlineCacheOrdinalTests`); the old fixed 512 × 56 B table is `JEFFJS_INTERP_ICTABLEFIXED=1`.
- `jeffJS_icFillDeep` declines megamorphic sites / shapes already listed (three.js spent ~15 % of a frame in the walk).
- The lazy reclaim's IC-table comment still says "512 entries, ~28 KB": tables are sized per function now (above).
- A `weak` Swift reference to an engine object gives it a side table and slows every retain/release (native twins,
  `../Builtins/Twins/`) — never hold engine objects weakly.
- Precompile text/filename must be byte-equal to what the JS thread evals (the key covers both) or it is a harmless miss.

## Patterns to follow
- Config keys (`compile.*`, `cache.*`, `stack.*`, `interp.*`, `trace.hitThreshold`) live in `../Config/JeffJSConfig.swift`
  and the plist `../Resources/JeffJSConfig.plist`; every key is overridable as `JEFFJS_<KEY_UPPER_WITH_UNDERSCORES>`
  (simulator: `SIMCTL_CHILD_JEFFJS_…`). Add a switch there with a doc comment naming its A/B env var, not an ad-hoc `getenv`.
- New per-opcode cost in `callInternal`'s prologue: put rare strings/paths in `JeffJSColdErrors.swift` (`@inline(never)`).
- Cold host integration: let the host call `JeffJSPrecompiler.precompileScript` off-thread with the final text (the app's
  `JSScriptEngine.loadExecutableSourceOffMain`) instead of compiling on the JS thread.
- Metal/host interaction is not here; the bytecode VM stays (`docs/EXECUTION_ARCHITECTURE_RETHINK.md` § 7: closure-tree
  engines rejected with measurements — spend effort on native method slots and the object model instead).
- Interpreter `interp.fast*` / `lean*` switches (the `interp.*` block of `JeffJSConfig.swift`) each carry a `JEFFJS_INTERP_<NAME>=0`
  A/B; keep that convention for a new fast path and measure on `realworld` (`Scripts/run_tests.sh`, CLI benches).

## Debug switches
- `JEFFJS_CACHE_BYTECODEENABLED=0|1`, `JEFFJS_CACHE_BYTECODEDEBUG=1` (hit/miss/store lines), `JEFFJS_CACHE_BYTECODEWRITESYNC=1`,
  `JEFFJS_CACHE_BYTECODEMAPPED=0` (in-heap copies instead of file mappings; `BytecodePagingTests`),
  `JEFFJS_CACHE_BYTECODEDISKBUDGETBYTES` / `…MEMORYBUDGETBYTES` (defaults 200 MB / 16 MB iOS, 16 MB / 2 MB watch).
- `JEFFJS_COMPILE_LAZYFUNCTIONS=0` (eager), `JEFFJS_COMPILE_LAZYDROPAFTERMS=0` (periodic reclaim off; app plist 30000),
  `JEFFJS_COMPILE_LAZYDROPONMEMORYPRESSURE=0`, `JEFFJS_COMPILE_LAZYDROPDEBUG=1` (`[jeffjs:reclaim] cycle …` per cycle),
  `JEFFJS_COMPILE_LAZYDROPSTRESS=1` (drop everything at every idle tick, tests), `JEFFJS_COMPILE_LAZYDROPFREESCONSTANTS=0`,
  `JEFFJS_COMPILE_LAZYLITERALS=0`, `JEFFJS_COMPILE_MAPPEDSOURCE=0`, `JEFFJS_COMPILE_OFFTHREADPRECOMPILE=0`.
- `JEFFJS_INTERP_ICTABLEFIXED=1`, `JEFFJS_INTERP_ICORDINALTABLES=0`, `JEFFJS_INTERP_AWAITALWAYSSUSPENDS=0`,
  `JEFFJS_INTERP_FAST{ITERATORS,ARRAYBUILTINS,NATIVECALLS,CALLENTRY,OBJECTBUILTINS,FREECHAIN,ARGUMENTS,FUNCTIONNAME,TYPEOF,OWNPROPERTY}=0`,
  `JEFFJS_INTERP_{TRACECALLINTRINSIC,LEANCALLENTRY,LEANNATIVEARGS,ATOMKEYSTRINGS,UNRETAINEDPROTOWALK}=0`.
- `JEFFJS_EVAL_KEEPTOPLEVELCONSTANTS=1`, `JEFFJS_EVAL_KEEPNESTEDBODIES=1` (old constant / body retention).
- `JEFFJS_STACK_DEBUG=1` (JS stack at a native-stack trip), `JEFFJS_REFERR_DEBUG=1` (unresolvable global reads),
  `JEFFJS_GC_VERIFYROOTS=1` (thread-ownership checks, `../Core/JeffJSThreadCheck.swift`), `debug.traceOpcodes` plist key.
- `-DJEFFJS_JSPROF` + `JEFFJS_JSPROF_US` (sampling period µs, default 1000) — the JS profiler.
- Tests: `swift test -c release` (Debug conformance exceeds its timeout); `--filter BytecodeCacheBudgetTests |
  BytecodeCacheClosureTests | BytecodeCacheKeyTests | BytecodeCacheLazyTests | BytecodePagingTests | PrecompilerTests |
  InlineCacheSizingTests | InlineCacheOrdinalTests | InterruptTerminationTests | DynamicImportCheckpointTests`;
  conformance groups via `JeffJSTestRunner`: `LazyCompile`, `InterfaceShadowIC`, `NativeTwins` (stale twin table
  after compiler changes), `AkamaiSensor`, `BrowserFingerprint`. Run with `JEFFJS_CACHE_BYTECODEENABLED=0` when a warm
  CLI cache could mask a serializer bug.

## Cross-area links
- [Core](../Core/CLAUDE.md) — `JeffJSContext.eval`/`evalPrecompiled`, `JeffJSObject` inline caches, GC/`liveClosures`,
  thread check, interrupt handler storage.
- [Parser](../Parser/CLAUDE.md) — emits the raw bytecode and the expression spans this area consumes; shares the identity hash.
- [Builtins](../Builtins/CLAUDE.md) — native twins recognised by name-free bytecode (`JeffJSBytecodeSerializer.nameFreeBytes`).
- [JeffJS engine root](../../../CLAUDE.md) — branch rules, submodule pinning.
- [React Natively app](../../../../../CLAUDE.md) and its [JS glue](../../../../../React%20Natively/renderengine/JS/CLAUDE.md) —
  the plist overrides, `precompile_polyfills.sh`, interrupt / idle-tick / precompile call sites.

## Deep docs
- [`README.md` § "Architecture" / "Bytecode cache"](../../../README.md) — pipeline overview, `.jfbc` purpose.
- [`docs/PERFORMANCE_PLAN.md` § "Round 7 … The bytecode cache was off because it was wrong"](../../../docs/PERFORMANCE_PLAN.md)
  — why JFBC v3 carried closure descriptors; cache timings; § "Round 14" for the docket.
- [`docs/EXECUTION_ARCHITECTURE_RETHINK.md` § 7 "Recommendation"](../../../docs/EXECUTION_ARCHITECTURE_RETHINK.md) —
  keep the bytecode VM; where the remaining 3.8x vs QuickJS lives.
- App `CLAUDE.md` "Bytecode cache" row and "Working with the JeffJS submodule" (lazy reclaim results, PERF_PLAN links).

## Suspected dead code
- `JeffJSStackDiag.reportOverflow` (`JeffJSStackDiag.swift`) — confidence: medium — checked:
  `grep -rn 'reportOverflow\|overflowCount' Sources/JeffJS` → 0 call sites outside its file (the header says `push()`
  reports here; only tests read `overflowCount`/`currentLabel`, which stay 0 / unused in Sources).

## Suspected stale
- App root CLAUDE.md says "JFBC v6" and a `v5-cv…/v4` disk dir purge: the blob is `JFBC_VERSION` 7, `diskVersion` 5,
  `compilerVersion` 19 (the "engine d563ff4 … submodule bump pending" note is overtaken: 1bcbde2 has it all).
- App root "a bytecode-cache hit loses the expression spans (open)": fixed at compilerVersion 17 (`EXT_SPANS`);
  not reproduced here — treat as closed unless a probe shows it.
- "~47 KB Debug / ~2 KB Release per JS call level" is an app-root measurement; nothing in the engine tree states it
  (`grep -rn '47 KB' docs README.md` → none). `callInternal`'s comment estimates ~2 KB per frame.
