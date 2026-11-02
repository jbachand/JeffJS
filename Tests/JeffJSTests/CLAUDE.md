# Engine tests — Claude neuron

> Area: `Tests/JeffJSTests/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The JeffJS engine's correctness gate: one SwiftPM test target (`JeffJSTests` in `Package.swift`) holding the
conformance runner (192 named groups of JS snippets run through `JeffJSRuntime`/`JeffJSContext`), XCTest classes for
the host-facing pieces (DOM, bridges, bytecode cache, GC parity, threading rules, unminifier, WebAssembly) and the perf
benchmarks. Nothing here is compiled into the React Natively app; the app's own copy of the runner lives in its
`renderengine/JS/JeffJSTests/` and is driven from its settings drawer. Every engine fix lands with a case here first.

## Key files
- `JeffJSTestRunner.swift` (13 477 lines) — `JeffJSTestRunner.allTests`: `[(name, { $0.testX() })]`, one shared context per
  group (`cleanupSharedContext` / `detachSharedContext`); `JeffJSQuickVerify.runQuickVerification()` smoke pass;
  `runAsync` (the app's drawer path, `renderengine.swift`); `runBenchmarks`. Most language groups are `mutating func testX` here.
- `EngineTests.swift` — the XCTest entry points: `testConformance` (every group, fresh context each, 32 MB thread,
  1800 s = 30 min wait), `testSuspectGroups` (`JEFFJS_GROUPS=A,B`), `testGroupsTail`, `testRealmsGroup`,
  `testWebAssemblyGroup`, `testPerfBenchmarks`, `testHeadToHead` (`JEFFJS_H2H=1`, vs JavaScriptCore), `testThrowTrace`
  (`JEFFJS_TRACE_SNIPPET`), `testRealmProbe` (`JEFFJS_REALM_PROBE`), teardown/leak regressions.
- `*Conformance.swift` (~75 files) — one conformance group each as an `extension JeffJSTestRunner` (`static let xCases`,
  `mutating func testX`), registered in `allTests`; some also wrap themselves in an XCTest class so one group runs alone
  (`InterfaceShadowICConformance.swift` → `InterfaceShadowICTests`). Named after the spec section or the site that found
  the bug (`AkamaiSensor`, `HomedepotAkamai`, `NflConstructor`, `BrowserFingerprint`, `WebAssembly`, `Realms`, `ShadowDOM`…).
- `NativeTwinsConformance.swift` — groups `NativeTwins`/`NativeTwins2`/`NativeTwins3`/`NativeTwinsReact`: differential runs of
  Home Depot's deepmerge / Babel / Apollo / React copies with `rt.nativeTwins` true and false (outputs must be equal, the
  twin must have served calls); first asserts `JeffJSTwinTableData.entries` == `JeffJSNativeTwins.buildTable(ctx)`.
- `EngineThreadingRuleTests.swift` — `testTopLevelDeclarationsAreNonisolated` (every engine top-level declaration
  `nonisolated`: the app compiles the engine under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`),
  `testEngineClassesAreNonisolated` (classes in `heapDirectories` Core/Builtins/Bytecode/Parser/RegExp/StdLib/Utils/Config/Unicode),
  `testSecondThreadHeapMutationIsReported`, `testCachedAtomIsReleasedOnlyInItsRuntime`, `testVerifierAcceptsHealthyHeap`.
- `BytecodeCache{Budget,Key,Closure,Lazy}Tests.swift`, `BytecodePagingTests.swift`, `PrecompilerTests.swift` — disk/memory
  tiers and budgets, key fields, serialize→deserialize parity, lazy bodies, mapped code, off-thread precompile;
  `BytecodeCacheBudgetTests.testEngineSourceHashIsCurrent` checks `Scripts/update_bytecode_identity.sh`'s hash.
- `MetalGCParityTests.swift`, `MetalGCVarRefTests.swift` — the GPU collector frees exactly what the CPU one frees.
- `RefcountLeakTests`, `ObjectSizeRefLeakTests`, `RuntimeTeardownReleaseTests`, `TaskSpikesTests`, `LazyPayloadTests`,
  `LargeObjectShapeTests` — memory comes back to baseline. `DOMThreadSafetyTests`, `HostActorTests`, `ThreadRuntimeTests`,
  `InterruptTerminationTests`, `DynamicImportCheckpointTests` — DOM one-writer contract, host actor, per-thread runtimes, interrupts.
- Host surface, one XCTest class each: `HTMLParserTests`, `SelectorTests` (+ `Selector*Bench*`, `SelectorMatcherDifferentialTests`),
  `DOMAPITests`, `DOMGeometryTests`, `DOM*Bench*`, `IntlTests`, `UnminifierTests`, `FetchBridgeTests`, `WebSocketBridgeTests`,
  `CookieJarTests`, `RequestHeadersTests`, `StorageBridgeTests`, `QuantumTests`.
- `JeffJSPerfTests.swift` — micro-benchmarks (`runAll`, `runHeadToHead`); `../gcstress/cycles.js` — CPU-vs-GPU collector
  stress run by `Scripts/run_tests.sh` (see [bench](../../bench/CLAUDE.md)).

## Invariants
- **The gate is `swift test -c release`** (Debug conformance exceeds `testConformance`'s 30 min timeout). `CONTRIBUTING.md`:
  `swift test` must stay green on every PR.
- **Every language change gets a case** in `JeffJSTestRunner.swift` or a focused `*Conformance.swift` group registered in
  `allTests`; a perf change comes with a `JeffJSPerfTests` delta (`CONTRIBUTING.md`).
- A new conformance group = `extension JeffJSTestRunner` with `static let <x>Cases` + `mutating func test<X>()`, one line in
  `allTests`, and (if it should run alone) a `final class <X>Tests: XCTestCase { testGroup() }` asserting `failCount == 0`
  and `passCount == cases.count`.
- Every engine class in the heap directories is `nonisolated` (or says `@MainActor` on purpose); every top-level declaration
  too — `EngineThreadingRuleTests` fails otherwise. Run `~/www/rnly-agents/ship/annotate_nonisolated.py Sources/JeffJS`
  (app repo rule) after bulk edits.
- After a Parser/Bytecode edit: `Scripts/update_bytecode_identity.sh` (else `testEngineSourceHashIsCurrent` fails), then
  regenerate the app's polyfill `.jfbc`.
- Adding a native twin: file in `Builtins/Twins/`, a line in `JeffJSNativeTwins.families`, `Needs` checks, regenerate the
  table (`swift run -c release jeffjs-cli --twin-table > Sources/JeffJS/Builtins/Twins/JeffJSTwinTableData.swift`), and an
  on/off differential group here; the `NativeTwins` group fails with "JeffJSTwinTableData.swift is stale" after compiler changes.
- Tests that read bytecode-cache entry files call `JeffJSBytecodeCache.flushPendingDiskWrites()` first (disk writes are queued).
- `gcstress/cycles.js` may never print a pointer, address or timing: its output is diffed byte for byte between collectors.

## Gotchas
- Conformance/probe runs need `JEFFJS_CACHE_BYTECODEENABLED=0` (env overrides of config keys are `JEFFJS_<KEY_UPPER>`,
  `Config/JeffJSConfig.swift`): a warm bytecode-cache hit used to lose the expression spans (error messages stopped at
  "undefined is not an object", `BuiltinGaps` message cases failed; fixed at `compilerVersion` 17 — `EXT_SPANS` is in the
  record again). The switch stays so a warm cache can never mask an error-text regression.
- `testConformance` **detaches** the shared context between groups instead of freeing it (a known teardown UAF, see
  `JeffJSZombieDebug`); leaking ~90 contexts per process is by design there.
- SwiftPM builds have no default actor isolation, so no test can observe the app's main-actor deinit hop; the threading
  rule tests check the declarations instead.
- The suite silently ran only the CPU collector until `Scripts/run_tests.sh` added the `JEFFJS_GC_METAL=1` second pass
  (a var-ref seeding bug survived a green suite for a day).
- `swift test -c release` rebuilds `jeffjs-cli` with testability on: rebuild it (`swift build -c release --product
  jeffjs-cli`) before timing anything (`docs/PERFORMANCE_PLAN.md` "Measurement trap").
- Debug per-JS-call native stack is ~47 KB (Release ~2 KB): deep legit recursion trips "Maximum call stack size
  exceeded" in Debug; `JEFFJS_STACK_DEBUG=1` prints the JS stack at the trip.
- `JEFFJS_TEST_UNMINIFY_EVAL=1` (`Core/JeffJSContext.swift`) formats every global/module script through
  `JeffJSUnminifier` before compiling: conformance then fails only `Function.prototype.toString` / line:col cases.

## Patterns to follow
- Group filter: `swift test -c release --filter <XCTestClass>[/<method>]`, e.g. `--filter InterfaceShadowICTests`,
  `--filter EngineTests/testConformance`, `--filter BytecodeCacheBudget`; several runner groups at once:
  `JEFFJS_GROUPS=Realms,WebAssembly swift test -c release --filter EngineTests/testSuspectGroups`.
- Both collectors + gcstress: `Scripts/run_tests.sh [release|debug] [--filter <pattern>]`.
- A site-found engine bug: name the group after the site/agent and the date in the file header, keep the minified
  reference text verbatim in a `static let` (as `NativeTwinsConformance` and `AkamaiSensorConformance` do).
- Differential groups compare printed shapes (`show()` helper: keys, order, attributes, prototypes, identities) between
  two modes of the same runtime; never compare timings in a test.
- Don't add XCTest cases to the app's copy of the runner (`renderengine/JS/JeffJSTests/`): it is the older app-side harness.

## Debug switches
- `JEFFJS_GROUPS=A,B` (+ `JEFFJS_TRACE_SUSPECT=1`) — `testSuspectGroups`; `JEFFJS_H2H=1` — enables `testHeadToHead`;
  `JEFFJS_PROFILE`, `JEFFJS_TRACE_SNIPPET`, `JEFFJS_TRACE_LAST`, `JEFFJS_REALM_PROBE` — the ad-hoc `EngineTests` probes.
- `JEFFJS_GC_METAL=1` — GPU collector from threshold 0 (`run_tests.sh` pass 2); `JEFFJS_GC_OFF`; `JEFFJS_GC_VERIFYROOTS=1`
  (logs GC-list thread changes, verifies entries before each collection); `JEFFJS_ZOMBIES=1`, `JEFFJS_TRACK_RC=1` (leak tests, `bench/arc/check.sh`).
- Config overrides the cache/IC/lazy tests toggle: `JEFFJS_CACHE_BYTECODEENABLED=0`, `JEFFJS_CACHE_BYTECODEMAPPED`, `JEFFJS_COMPILE_LAZYLITERALS`,
  `JEFFJS_COMPILE_LAZYDROPAFTERMS`, `JEFFJS_INTERP_ICTABLEFIXED`, `JEFFJS_INTERP_ICORDINALTABLES`, `JEFFJS_JSON_LAZY`.
- `JEFFJS_FETCH_MODE`, `JEFFJS_FETCH_LOOP` (`FetchBridgeTests`), `JEFFJS_BC_BENCH_FILE` (`BytecodeCacheBudgetTests`);
  `JEFFJS_TEST_UNMINIFY_EVAL=1`, `JEFFJS_STACK_DEBUG=1` — see Gotchas.

## Cross-area links
- [JeffJS engine root](../../CLAUDE.md) — branch rules, global threading/identity rules; [Bytecode](../../Sources/JeffJS/Bytecode/CLAUDE.md)
  (cache, precompiler), [Twins](../../Sources/JeffJS/Builtins/Twins/CLAUDE.md), [Utils](../../Sources/JeffJS/Utils/CLAUDE.md) (unminifier),
  [Config](../../Sources/JeffJS/Config/CLAUDE.md) (`JEFFJS_<KEY>` overrides).
- [jeffjs-cli](../../Sources/jeffjs-cli/CLAUDE.md) — `--twin-table`, `--bc-hash-code`, `--settle` + census: the tools the tests name.
- [bench + Scripts](../../bench/CLAUDE.md) — `run_tests.sh`, `update_bytecode_identity.sh`, `wasm_spectest.sh`, gcstress.
- [React Natively app](../../../../CLAUDE.md) — "Working with the JeffJS submodule" (gate, known failures, `.jfbc` regen);
  app harnesses that drive the engine: `Scripts/run_boot_harness.sh`, `Scripts/run_engine_bench.sh`, `renderengine/JS/JeffJSTests/`.

## Deep docs
- [`docs/PERFORMANCE_PLAN.md` § "Round 14"](../../docs/PERFORMANCE_PLAN.md) — per-branch measurements, "swift test -c release green" rule, probe scripts.
- [`CONTRIBUTING.md`](../../CONTRIBUTING.md) — tests for anything touching the language, perf deltas via `JeffJSPerfTests`.
- [`README.md` § "Testing"](../../README.md) — the public description of the runner.

## Suspected dead code
- None found (searched: `grep -rn 'runAsync(\|runBenchmarks()\|runQuickVerification()' "React Natively" Vendor/JeffJS` →
  `runAsync` called from the app's `renderengine.swift:12192`, `runQuickVerification` from `EngineTests`; `runBenchmarks`
  has no caller outside its definition but is the runner's documented benchmark entry — low confidence, left in).

## Suspected stale
- "9 known failures (HTMLParser adoption/foster, Intl prototype `format`, SelectorTests `testIsSupported`)" (root doc) vs
  "the 4 known failing cases only" (`docs/PERFORMANCE_PLAN.md` § Round 14): the tests exist (`HTMLParserTests`
  `testAdoptionAgencyReordersMisnestedFormatting` / `testFormattingIsSplitAcrossBlockBoundaries` /
  `testTemplateContentKeepsTableMarkup`, `IntlTests.testIntlIsNativeAndNotAStub`, `SelectorTests.testIsSupported`) and
  none is marked `XCTExpectFailure`; the count was not verified by running (no builds in this pass).
- `README.md` "run the same test runner inside the `JeffJSConsole` app target": `grep -rn 'TestRunner' JeffJSConsole` → 0 hits.
- `CONTRIBUTING.md` "CI runs `swift test` on every push": `.github/workflows/` holds only `testflight.yml` and
  `release.yml` (manual App Store workflows); `CODE_OF_CONDUCT.md` / `SECURITY.md` it links do not exist; its platform
  list (iOS 16+) predates `Package.swift` (iOS 18 / macOS 15).
