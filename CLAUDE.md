# JeffJS — root map

JeffJS is a 1:1 port of [QuickJS](https://bellard.org/quickjs/) to Swift (~230 k lines under `Sources/JeffJS/`): tokenizer →
parser (emits bytecode directly, no AST) → compiler passes → interpreter, with JSC-shaped builtins, a refcount + cycle GC,
a bytecode cache, lazy compilation, native twins, WebAssembly, and — unusual for a JS engine — the **DOM node type, HTML
parser, selector engine, cookie jar and the host bridges** the React Natively app renders through. The app
(`jbachand/react-natively`, this repo is its submodule `Vendor/JeffJS`) compiles these sources into its own module.

> **Note to Claude.** Thin, always-loaded map. Area rules live in the neurons below (auto-loaded when you touch a folder).
> Last reviewed: 2026-11-02 (engine 1bcbde2 on `perf/round14-docket`; app 20c9d08). When used as the app's submodule the
> app's root map is [`../../CLAUDE.md`](../../CLAUDE.md) and the deep reports are in the app's `docs/claude/`.

## Area index (neurons)

| Area | Doc | What lives there |
|---|---|---|
| Core | [`Sources/JeffJS/Core/CLAUDE.md`](Sources/JeffJS/Core/CLAUDE.md) | runtime, context, values, objects/shapes/props, strings/atoms, GC, host actor, thread checks, error text, realms |
| Parser | [`Sources/JeffJS/Parser/CLAUDE.md`](Sources/JeffJS/Parser/CLAUDE.md) | tokenizer + parser emitting bytecode; expression spans; lazy function seeds |
| Bytecode | [`Sources/JeffJS/Bytecode/CLAUDE.md`](Sources/JeffJS/Bytecode/CLAUDE.md) | interpreter, compiler passes, opcodes, bytecode cache (JFBC), precompiler, lazy reclaim, inline caches |
| Builtins | [`Sources/JeffJS/Builtins/CLAUDE.md`](Sources/JeffJS/Builtins/CLAUDE.md), [`Twins/`](Sources/JeffJS/Builtins/Twins/CLAUDE.md) | ES builtins shaped like JavaScriptCore's; native twins of known library functions |
| DOM | [`Sources/JeffJS/DOM/CLAUDE.md`](Sources/JeffJS/DOM/CLAUDE.md) | `DOMNode`, HTML parser/tokenizer, CSS selectors, shadow DOM, DOM/event/fetch/storage/WebSocket/IndexedDB bridges, cookie jar, request headers |
| Wasm | [`Sources/JeffJS/Wasm/CLAUDE.md`](Sources/JeffJS/Wasm/CLAUDE.md) | WebAssembly decoder/validator, slot interpreter, JS API |
| RegExp | [`Sources/JeffJS/RegExp/CLAUDE.md`](Sources/JeffJS/RegExp/CLAUDE.md) | regex compiler/VM (+ optional Metal) |
| StdLib | [`Sources/JeffJS/StdLib/CLAUDE.md`](Sources/JeffJS/StdLib/CLAUDE.md) | console, timers, URL, performance, structuredClone, TextDecoder, intrinsics install |
| Utils | [`Sources/JeffJS/Utils/CLAUDE.md`](Sources/JeffJS/Utils/CLAUDE.md) | dtoa, lists, heap debug, script sources, the unminifier |
| Environment | [`Sources/JeffJS/Environment/CLAUDE.md`](Sources/JeffJS/Environment/CLAUDE.md) | `JeffJSEnvironment` (what a browser-like runtime gets), engine polyfills, global snapshot |
| Config | [`Sources/JeffJS/Config/CLAUDE.md`](Sources/JeffJS/Config/CLAUDE.md) | `JeffJSConfig` keys, plist + `JEFFJS_<KEY>` env overrides; Resources/, Unicode/ |
| Quantum | [`Sources/JeffJS/Quantum/CLAUDE.md`](Sources/JeffJS/Quantum/CLAUDE.md) | the quantum-computing module (papers/scripts excluded from the package) |
| Tests | [`Tests/JeffJSTests/CLAUDE.md`](Tests/JeffJSTests/CLAUDE.md) | `JeffJSTestRunner` conformance groups, focused test files, gcstress |
| CLI + bench | [`Sources/jeffjs-cli/CLAUDE.md`](Sources/jeffjs-cli/CLAUDE.md), [`bench/CLAUDE.md`](bench/CLAUDE.md) | `jeffjs-cli` (unminify, twin table, census), benchmarks |

Deep docs: [`README.md`](README.md) (overview, quickstart, configuration), [`CONTRIBUTING.md`](CONTRIBUTING.md),
[`docs/PERFORMANCE_PLAN.md`](docs/PERFORMANCE_PLAN.md), [`docs/EXECUTION_ARCHITECTURE_RETHINK.md`](docs/EXECUTION_ARCHITECTURE_RETHINK.md)
(a closure-tree redesign, rejected with measurements), [`PERF_PLAN.md`](PERF_PLAN.md); in the app: `docs/claude/ARCHITECTURE.md`,
`docs/NATIVE_REACT_SCOPING.md`, `docs/DOM_TURBO_PROFILE.md`.

## Global rules

- **Fidelity to QuickJS** in the engine core; builtins, error texts, `Error.stack` frames and every fingerprintable shape
  match **JavaScriptCore** (pages fingerprint them). Never reintroduce V8 wording.
- **No dependencies** beyond Foundation (and optional Metal). Platforms iOS 18 / macOS 15 / watchOS 11+ (`Package.swift`:
  the Synchronization module for `Atomic` / `Mutex`); `-enforce-exclusivity=unchecked` in release — one JS thread per runtime.
- **Branches.** One engine branch for the app: `perf/round14-docket` (contains `perf/round5-beat-quickjs`). Fix branches are
  cherry-picked onto it; the app then commits the new submodule pointer. Never leave a fix only as uncommitted edits in the
  app's `Vendor/JeffJS`. `~/www/jeffjs` is a second clone — fetch between them. PRs branch off `main`.
- **Every language change gets a test** in `Tests/JeffJSTests/JeffJSTestRunner.swift` (or a focused `*Conformance.swift` group);
  `swift test -c release` is the gate (Debug conformance exceeds its timeout; conformance runs set `JEFFJS_CACHE_BYTECODEENABLED=0`;
  the known failures — HTMLParser adoption/foster, Intl prototype `format`, SelectorTests `testIsSupported` — are listed in the Tests neuron). Commit messages name the ported QuickJS function (`quickjs.c:JS_NewObjectFromShape`).
  One concern per PR. Architecture changes to `Core/`, `Parser/`, `Bytecode/`, the GC or the regex engine need an issue first.
- **Threading.** One JS thread per runtime; a runtime may move between threads but nothing touches a heap while another
  thread is inside it (Debug traps in `Core/JeffJSThreadCheck.swift`). Every top-level declaration is `nonisolated`
  (`EngineThreadingRuleTests`; the app compiles the sources under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
  undecorated declaration silently hops to main). Never hold an engine object in a `weak` Swift reference. Host bridges that
  do I/O run their network leg off the host actor (`DOM/JeffJSFetchBridge.swift`'s prepare → run → finish pattern).
- **After a Parser / Bytecode / Compiler edit**: run `Scripts/update_bytecode_identity.sh` (the bytecode-cache identity:
  `compilerVersion` + `engineSourceHash`, checked by `BytecodeCacheBudgetTests`), then regenerate the app's precompiled
  polyfills (`Scripts/precompile_polyfills.sh` in the app). The native-twin table is regenerated with
  `swift run -c release jeffjs-cli --twin-table` (`NativeTwins` conformance fails when stale).
- **Config.** Every `JeffJSConfig` key is overridable as `JEFFJS_<KEY_UPPER>` in the environment (`SIMCTL_CHILD_` prefix on the
  simulator); the app ships its own `JeffJSConfig.plist`. Per-call glue evals must be excluded from the bytecode cache
  (`cache.bytecodeExcludePrefixes`).
- **Docs maintenance.** Update the area's `CLAUDE.md` in the same change (the `PostToolUse` hook in `.claude/settings.json`
  reminds you), bump its "Last reviewed", never invent: verify every claim against the tree; dead-code claims carry a
  confidence and the search. Area `CLAUDE.md` files are excluded from the SwiftPM target in `Package.swift` and from the app's
  Xcode targets in its pbxproj — a new neuron folder needs both entries.

## Quick reference

```sh
swift build                          # package (library + jeffjs-cli)
swift test -c release                # the gate (≈ 30 min; --filter <Group>Tests for one group)
swift run -c release jeffjs-cli             # no args = usage line; flags in Sources/jeffjs-cli/CLAUDE.md
Scripts/run_tests.sh release --filter <Group>
```
