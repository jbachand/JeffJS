# JeffJS Core — Claude neuron

> Area: `Sources/JeffJS/Core/` · Repo: engine · Last reviewed: 2026-11-11 (app 59ae5c0 / engine perf/manual-memory-varrefs)

## Purpose
The engine heart of JeffJS, a 1:1 Swift port of QuickJS: runtime (atoms, shapes, GC lists, job queue), contexts/realms
(globals, intrinsics), the NaN-boxed value, objects + shapes + inline-cache entries, strings/ropes, BigInt, the
refcount + Bacon–Rajan cycle collector (CPU and Metal) and the thread/teardown rules every other engine folder relies
on. Input: values and bytecode from [Bytecode](../Bytecode/CLAUDE.md) / natives from [Builtins](../Builtins/CLAUDE.md);
output: object graph semantics the interpreter, the DOM bridges and the host (`JSScriptEngine` in the
[React Natively app](../../../../../CLAUDE.md)) build on. Every file carries a comment naming its quickjs.c counterpart.

## Key files
- `JeffJSRuntime.swift` — `JeffJSRuntime` (atom table, GC lists, shape hash, pools, job queue, `interruptHandler`/`memoryHook`, `newRealm`, `free()`, `executePendingJobs`); `atomOwnerID` identity; `JSMallocState`.
- `JeffJSContext.swift` — `JeffJSContext` (one realm: global, intrinsics, `realmIndex`); `defineProperty`/`definePropertyValue`, eval entry (`JEFFJS_BCDUMP_TMP`, `JEFFJS_TIME_PRECOMPILED`), error objects with JSC's own `line`/`column`/`sourceURL`/`stack`, `JeffJSWeakObjectBox`.
- `JeffJSValue.swift` — 8-byte NaN-boxed `JeffJSValue` (heap types = raw pointer, `Unmanaged.passRetained`); `dupValue`/`freeValue`; `newFloat64Purified` (JSC purifyNaN: NaN payloads from typed arrays/DataView must never become tagged values).
- `JeffJSObject.swift` — `JeffJSGCObjectHeader` (refCount, strong `ownerRuntime`, `gcListIndex`), `JeffJSObject` (80 B), inline-cache entries (`JeffJSICEntry`, `JeffJSPolySite`, `jeffJS_icFillDeep`), `JeffJSThreadRuntime` + `activeRuntime`, `JeffJSPropertyFlags`.
- `JeffJSShape.swift` — hidden classes / transition tree, runtime shape hash (`shapes.*` config), `icCached` + `prepareShapeUpdate` (a cached shape never grows in place).
- `JeffJSPropStorage.swift`, `JeffJSRawStack.swift` — raw malloc'd slot/pointer storage (no Swift Array COW/bounds/retain traffic on the hot path).
- `JeffJSFBRef.swift` — `JeffJSFBHandle`: the dispatch's handle on the running function's bytecode record (quickjs `JS_CallInternal`'s borrowed `b`). With `JEFFJS_MANUAL_MEMORY` it is `JeffJSFBRef`, an unmanaged pointer with forwarding accessors (no retain/release per call, return or trace entry); without it, the class itself. `fbFastH` (callee lookup), `icU`, `handle` / `object` / `with` / `identity` exist in both builds. A member the interpreter reads through `fb` needs a forwarding accessor here.
- `JeffJSVarRefHold.swift` — closure var-ref lifetime (quickjs `js_closure2`/`close_var_refs`/`free_var_ref`): `jeffJS_varRefHold/Drop`, `jeffJS_makeVarRef`, `JeffJSVarRefList` (a frame's unmanaged live list). Build with the compilation condition `JEFFJS_MANUAL_MEMORY` (issue #1, on by default) and the hold is a manual count with one manual retain; without it, a Swift retain/release on the same lists.
- `JeffJSGC.swift` — `runGC` (refcount + cycle collection, `JSGCPhaseEnum`), `freeObject`, weak refs (`JeffJSWeakRef`, `pruneWeakRefs`), idle GC (`jeffJS_idleGCTick`), `clearGCState`, `JEFFJS_GC_OFF/DEBUG`.
- `JeffJSMetalGC.swift` — GPU cycle detection (trial_decref → scan_rescue → collect_dead) above `gc.metalThreshold` objects; declines (returns false) and the CPU collector runs instead.
- `JeffJSObjectPool.swift` — recycle pools for plain objects, function objects and arrays (`jeffJS_recycleObject/Function/Array`); only `isPoolable` objects; off in debug modes.
- `JeffJSAllocationTrigger.swift` — byte-driven collections / host memory hook (`gc.bytesSinceGCThreshold`, `gc.bytesSinceHookThreshold`) for big strings, stack segments, ArrayBuffers.
- `JeffJSThreadCheck.swift` — the one-thread-per-runtime rule: Debug traps, `JEFFJS_GC_VERIFYROOTS`, `jeffJS_nextRuntimeID`.
- `JeffJSHostActor.swift` — `JeffJSHostActor` global actor for DOM/Environment bridges; executor = main unless `JeffJSHost.install` ran.
- `JeffJSAtom.swift`, `JeffJSString.swift` — per-runtime atom table (predefined atoms never freed); Latin-1/UTF-16 strings, ropes, `appendInPlace`, cached atom + `cachedAtomRuntime`.
- `JeffJSBigIntCore.swift` / `JeffJSBigIntValue.swift` — `JBigInt` value type (32-bit limbs) and the NaN-boxed layer (|v| < 2^47 inline, else heap `JeffJSBigInt`).
- `JeffJSErrorText.swift` — JavaScriptCore-shaped runtime error text (`throwNotAnObject/AFunction/AConstructor`, source appenders).
- `JeffJSDefineOwnProperty.swift` — `defineOrReplaceOwnProperty`: every native definition path, in-place replace, `JEFFJS_DEBUG_DEFINEREFUSED`.
- `JeffJSOwnPropertyOrder.swift` — hidden own properties (`JeffJSPropertyFlags.hidden`, `setOwnPropertyHidden`) and `reorderOwnProperties` for Safari-surface parity.
- `JeffJSArrayIntegrity.swift` — freeze/seal/preventExtensions and non-writable `length` for fast-array elements (per-element `attrs`, `checked` flag).
- `JeffJSMappedBytes.swift` — read-only `mmap`/heap byte owners + `JeffJSBytesSpan` pins (bytecode paging, lazy literals, source text).
- `JeffJSHeapCensus.swift`, `JeffJSZombieDebug.swift` — live-object census (`JEFFJS_HEAP_CENSUS_*`) and the use-after-free tripwire (`JEFFJS_ZOMBIES`).
- `JeffJSConstants.swift` — QuickJS limits/flags/enums; reads `Config/JeffJSConfig.swift` (`JEFFJS_OPTIMIZE`, `JS_DEFAULT_STACK_SIZE`, …).

## Invariants
- **QuickJS fidelity**: Core changes port the quickjs.c function by name (commit message + comment cite it, `CONTRIBUTING.md`); architectural changes to Core/GC need an issue first. No dependencies beyond Foundation (+ optional Metal, under `#if canImport(Metal)`).
- **Every top-level declaration is `nonisolated`** (the app compiles the engine under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; an undecorated type/func silently hops to main from host-actor code). Enforced by `EngineThreadingRuleTests.testTopLevelDeclarationsAreNonisolated` / `testEngineClassesAreNonisolated` over Core, Builtins, Bytecode, Parser, RegExp, StdLib, Utils, Config, Unicode. A class that really is main-thread says `@MainActor` explicitly.
- **One JS thread per runtime** (`JeffJSThreadCheck.swift`): a runtime may *move* between threads (polyfill thread → main), but while one thread is inside nothing else may eval, collect, or **release an engine object whose deinit reaches the heap**. Debug builds trap (`jeffJS_threadCheck`; `jeffJS_threadViolationHandler` for tests); `JEFFJS_GC_VERIFYROOTS=1` logs thread changes of GC-list mutations and checks every entry before each collection.
- A main-actor class **without an explicit `deinit`** gets an isolated deinit that runs on main later — the 2026-09-30 idle-GC mark crash. App/DOM classes holding `JeffJSValue`s that can die off-main must be `nonisolated` or have an explicit `deinit`.
- **Two runtimes concurrently** (workers): the second thread calls `JeffJSThreadRuntime.enter()` **before** `JeffJSRuntime()` (its own `activeRuntime` slot), `leave()` after `rt.free()`. Values never cross runtimes.
- **Never hold engine objects in `weak` Swift refs**: a weak ref gives the object a side table and every retain/release takes the slow path (`JeffJSGCObjectHeader.ownerRuntime` is strong for that reason; the runtime↔object cycle is broken by `clearGCState` in `free()`). The deliberate exceptions are JS-visible weak semantics (`JeffJSWeakRef`, `JeffJSWeakObjectBox` for `Proxy.revocable`).
- A string's cached atom is released only in the runtime that interned it (`cachedAtomRuntime == rt.atomOwnerID`), never `activeRuntime` blindly — the previous page's runtime is freed on a utility queue while the next runs (`testCachedAtomIsReleasedOnlyInItsRuntime`).
- `defineProperty`/`definePropertyValue` **dup** the value (QuickJS consumes): free what you created. `definePropertyValue` never refuses; host code wanting `Object.defineProperty`'s rejection uses `defineOrReplaceOwnProperty`.
- A function object's payload holds **no refcount on its bytecode**: new code making a `.bytecodeFunc` payload bumps `fb.liveClosures` (`JeffJSContext` ~3774; `freeObject` / the function pool drop it) or the body's constants are released under it.
- **Teardown frees everything**: `JeffJSRuntime.free()` frees the remaining heap as one dead group and the intrinsics (`gc.teardownFreesHeap`, `gc.teardownFreesInitObjects`); a page's runtime must not outlive its navigation (`RuntimeTeardownReleaseTests`).
- **Realms**: `rt.newRealm()` = a `JeffJSContext` with its own intrinsics; a function's realm is `JeffJSObject.realmIndex` and a call into another realm switches via `callInRealm` (`Bytecode/JeffJSInterpreter.swift`) — any new interpreter fast path that calls a function without `callFunction`/`callInternal` must check `realmIndex == ctxRealm`. Natives get the realm they were registered on as `ctx`.
- **Error text and builtin shape read like JavaScriptCore's** (`JeffJSErrorText.swift`; pages fingerprint `message + stack`): "undefined is not an object (evaluating 'w.C[b]')", "Can't find variable: x", `RangeError: Maximum call stack size exceeded.`, frames `name@url:line:col`, errors with own `line`/`column`/`sourceURL`/`stack`. Never reintroduce V8 wording. Groups `BrowserFingerprint`, `AkamaiSensor`, `SyntaxErrorText`.
- **Inline caches**: a shape an IC holds (`icCached`) is never grown in place; delete/flag changes go through `prepareShapeUpdate` (new identity). A deep-prototype fill (`jeffJS_icFillDeep`) must check every nearer level for the atom first (`InterfaceShadowIC`: `input.type` once read HTMLElement.prototype's reflector).
- Own-key order is observable (Google's challenge hashes `getOwnPropertyNames(window)` by index): host glue is hidden (`hidden` flag), never deleted; `reorderOwnProperties` is the only reordering primitive.
- Fast-array integrity: every unchecked element write path tests `checked`; a new element write/delete/length path must too.
- `JeffJSMappedBytes` mappings are PROT_READ; cache files are replaced by rename and sidecars append-only (a shrinking mapped file SIGBUSes). A reader keeps a `JeffJSBytesSpan` (pin), never a bare pointer.
- An async host callback that settles a promise runs a microtask checkpoint (`rt.executePendingJobs()` at `callDepth == 0`).
- No allocation inside census / zombie recorders; never `force_lock` malloc zones.

## Gotchas
- `activeRuntime` is process-wide except on `enter()`ed threads; a context's init sets it (`isBackgroundCompiler` runtimes do not). Strings made off the JS thread (background compiles, bytecode cache) must not touch the allocation trigger (`JeffJSAllocationTrigger` guards by stack range).
- Bytecode-cache hits lose expression spans: on a warm cache error messages stop at "undefined is not an object" — run conformance with `JEFFJS_CACHE_BYTECODEENABLED=0` (open since 2026-09-29).
- The collector's own trigger counts objects (`gc.objectCost`); a task holding memory in a few huge strings or stacks is only caught by the byte trigger (`gc.bytesSinceGCThreshold`, the watch sets it lower) and `memoryHook`/interrupt handler.
- `JEFFJS_GC_METAL=1` means "run the GPU collector" (threshold 0) unless `JEFFJS_GC_METALTHRESHOLD` is named; the GPU path abandons rather than frees on a half-finished scan (`MetalGCParityTests`, `MetalGCVarRefTests`).
- Idle GC (`jeffJS_idleGCTick`) runs only when the heap grew by 1/2^`gc.idleGrowthShift` since the last one and `gc.idleIntervalMs` passed; a collection that reclaimed little doubles the interval (up to 64x). The host must give idle ticks (the app's 2 Hz header timer does).
- Over-release = a crash far from the bug: `JEFFJS_ZOMBIES=1` keeps freed objects allocated and prints the touching stack; `JEFFJS_TRACK_RC=1` reports refcounts at exit (both bypass the pools).
- `JEFFJS_EVAL_KEEPTOPLEVELCONSTANTS=1` / `KEEPNESTEDBODIES=1` restore the pre-memory-census leak: after a top-level script runs, non-function constants and never-closed-over nested bodies are released.
- Error message strings used to leak a ref (`JEFFJS_ERROR_KEEPMESSAGEREF=1` = old).
- Stack overflow in Debug: ~47 KB native stack per JS call level (Release ~2 KB); `JEFFJS_STACK_DEBUG=1` prints the JS stack at the trip. Limits: `stack.maxCallDepth` (default 200, app 200 000), `stack.maxInlineDepth` (10 000, app 60 000).

## Patterns to follow
- Hot-path storage = raw pointers (`JeffJSPropStorage`, `JeffJSRawStack`, `Unmanaged` in IC entries), not Swift arrays/classes with ARC traffic; the engine decides who owns a reference (`retaining:`).
- New per-string identity caches (like the regex input cache) must revalidate by length: `appendInPlace` grows an unshared string in place.
- Equal-content sharing (`gc.sharedStrings`, function source cache) and pooling are config switches with A/B env overrides — add a `JeffJSConfig` key + `JEFFJS_<KEY>` override for a new behaviour, not a bare env read.
- Config keys: `Config/JeffJSConfig.swift`; every key is overridable as `JEFFJS_<KEY_UPPER_WITH_DOTS_AS_UNDERSCORES>` (`SIMCTL_CHILD_JEFFJS_…` on the simulator). Core-relevant: `gc.*`, `stack.*`, `shapes.*`, `atoms.initialHashSize`, `interp.icTableFixed/icOrdinalTables`, `strings.functionSourceCache`.
- After Parser/Bytecode edits (not Core alone): annotate `nonisolated` → `Scripts/update_bytecode_identity.sh` → regenerate the app's polyfill `.jfbc`.
- Tests: `swift test -c release` (Debug exceeds the timeout). Groups gating Core: `EngineThreadingRuleTests`, `ThreadRuntimeTests`, `HostActorTests`, `RuntimeTeardownReleaseTests`, `RefcountLeakTests`, `ObjectSizeRefLeakTests`, `FreedValueConformance`, `RefcountLeftoversConformance`, `MetalGCParityTests`, `MetalGCVarRefTests`, `LargeObjectShapeTests`, `InlineCacheSizingTests`, `InlineCacheOrdinalTests`, `InterfaceShadowICConformance`, `OwnPropertyOrderConformance`, `DefineOverExistingConformance`, `ArrayIntegrityConformance`, `BrowserFingerprintConformance`, `AkamaiSensorConformance`, `EngineTests` ("Realms" group, `JEFFJS_REALM_PROBE`).

## Debug switches
- Build-time: the manual-memory core (issue #1) is **on by default** (2026-11-12; `JeffJSConfig.manualMemory` reports it). `JEFFJS_MANUAL_MEMORY=0 swift build -c release --scratch-path .build-arc` (Package.swift) builds the ARC lifetime. A/B is two builds, not an env var. Run `swift test` and `bench/arc/check.sh` in both.
- `JEFFJS_GC_VERIFYROOTS=1` — thread-change logging of GC-list mutations (`[jeffjs:gc-thread]`) + list check before each collection (`[jeffjs:gc-verify]`, any build).
- `JEFFJS_GC_OFF=1` refcount only · `JEFFJS_GC_DEBUG=1` prints what a collection frees · `JEFFJS_GC_METAL=1`, `JEFFJS_GC_METALTHRESHOLD=<n>` GPU collector.
- `JEFFJS_GC_TEARDOWNFREESHEAP=0`, `JEFFJS_GC_TEARDOWNFREESINITOBJECTS=0`, `JEFFJS_GC_LEGACYREFLEAKS=1`, `JEFFJS_GC_SHAREDSTRINGS=0`, `JEFFJS_GC_FUNCTIONPOOL=0`, `JEFFJS_NO_POOL=1` — A/B (old leaking / unpooled behaviour).
- `JEFFJS_GC_BYTESSINCEGCTHRESHOLD`, `JEFFJS_GC_BYTESSINCEHOOKTHRESHOLD`, `JEFFJS_BIGSTRING_LOG=<units>` — byte trigger tuning / big-string stack log.
- `JEFFJS_ZOMBIES=1` (+ `JEFFJS_ZOMBIE_REPORTS=<n>`), `JEFFJS_TRACK_RC=1`, `JEFFJS_TRACE_DEBUG=1` — use-after-free / refcount / fast-trace tripwires.
- `JEFFJS_HEAP_CENSUS_S=<s>`, `JEFFJS_HEAP_CENSUS_GC=1`, `JEFFJS_HEAP_CENSUS_REFS=<substr|…>` — `[Heap]` census of live objects (who grows, who points at them).
- `JEFFJS_EVAL_KEEPTOPLEVELCONSTANTS=1`, `JEFFJS_EVAL_KEEPNESTEDBODIES=1`, `JEFFJS_ERROR_KEEPMESSAGEREF=1` — A/B leaks.
- `JEFFJS_STACK_DEBUG=1`, `JEFFJS_INTERP_SEGMENTEDSTACK=0`, `JEFFJS_INTERP_ICTABLEFIXED=1`, `JEFFJS_INTERP_ICORDINALTABLES=0`, `JEFFJS_SHAPES_MAXHASHEDPROPS=0`.
- `JEFFJS_DEBUG_DEFINEREFUSED=1`, `JEFFJS_BCDUMP_TMP=<path>`, `JEFFJS_TIME_PRECOMPILED=1`, `JEFFJS_TEST_UNMINIFY_EVAL=1`, `JEFFJS_STRINGS_FUNCTIONSOURCECACHE=0`, `JEFFJS_COMPILE_MAPPEDSOURCE=0`.

## Cross-area links
- [Bytecode](../Bytecode/CLAUDE.md) — interpreter, `callInRealm`, IC fill sites, bytecode cache / engine identity.
- [Builtins](../Builtins/CLAUDE.md) — JSC-shaped builtins, native twins, cold error texts.
- [DOM](../DOM/CLAUDE.md) — host-actor bridges (`JeffJSHostActor`), node wrappers per realm.
- [RegExp](../RegExp/CLAUDE.md) — regex input cache keyed by string identity (length revalidation).
- [React Natively app](../../../../../CLAUDE.md) — `JSScriptEngine`, `PageThread.swift` (`HostHop.configure` installs the host executor), engine config plist overrides, polyfill `.jfbc` regen.

## Deep docs
- [`README.md` § "Architecture"](../../../README.md) — folder map, Metal GC/regex table, config key table.
- [`CONTRIBUTING.md`](../../../CONTRIBUTING.md) — fidelity bar, commit-message QuickJS references, no-dependency rule.
- [`docs/PERFORMANCE_PLAN.md`](../../../docs/PERFORMANCE_PLAN.md) — interpreter vs LLInt baseline and root causes.
- [`docs/EXECUTION_ARCHITECTURE_RETHINK.md`](../../../docs/EXECUTION_ARCHITECTURE_RETHINK.md) — where time goes (ARC/lifecycle 48 %); closure-tree design rejected with measurements.
- [`PERF_PLAN.md`](../../../PERF_PLAN.md) (engine) and the app's [`PERF_PLAN.md` "memory census"](../../../../../PERF_PLAN.md) — teardown / constant-pool / message-ref leak history.

## Suspected dead code
- `JeffJSRuntimeProtocol` (`JeffJSString.swift:13`) — confidence: high — checked: `grep -rn JeffJSRuntimeProtocol Sources Tests` → 1 hit (the definition only).
- `JeffJSShapeProtocol` (`JeffJSObject.swift:11`) — confidence: medium — checked: `grep -rn JeffJSShapeProtocol Sources Tests` → definition + a NOTE saying its typealias was removed; no conformer or use found.
- `JSValueTag.bigFloat` (`JeffJSValue.swift`) — confidence: low — checked: `grep -rn bigFloat Sources` → 3 hits, tag enum cases only (QuickJS tag kept for parity).

## Suspected stale
- Root doc says conformance has "9 known failures (HTMLParser adoption/foster, Intl prototype `format`, SelectorTests `testIsSupported`)" — not verifiable without running `swift test`; not re-checked here.
- Root doc "engine `fix/idle-gc-mark` e04547b/20c1d67, tip 90fa574" and other branch tips are history; the current submodule tip is 1bcbde2 on `perf/round14-docket`.
