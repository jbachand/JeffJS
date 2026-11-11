# Config — Claude neuron

> Area: `Sources/JeffJS/Config/` · Repo: engine · Last reviewed: 2026-11-11 (app 59ae5c0 / engine perf/manual-memory-varrefs)

## Purpose
`JeffJSConfig` is the single source of engine flags: one `static let` per key, read once at process start from
`JeffJSConfig.plist` in the resource bundle, with an environment override per key. Every subsystem (interpreter, GC,
cache, lazy compile, storage, wasm, quantum…) reads its switches from here. This doc also covers `../Resources/`
(the plist + Metal shaders) and, for lack of a better home, the `JEFFJS_*` naming rule.

## Key files
- `JeffJSConfig.swift` — `jeffJSResourceBundle` (`Bundle.module` under SwiftPM, else `Bundle.main`: the app compiles the sources into its own module), the plist dictionary, `envOverride` (`"JEFFJS_" + key.uppercased()` with `.` → `_`), typed readers `bool`/`int`/`string`, then the key groups: `build` (`precompilePolyfills`), `debug`, `optimize`, `cache.bytecode*`, `compile.lazy*` / `mappedSource` / `offThreadPrecompile`, `json.lazy*`, `wasm.enabled`, `storage.*` (quotas), `interp.*` (fast paths, IC tables, segmented stack), `trace.hitThreshold`, `stack.*`, `gc.*`, `atoms.*`, `shapes.*`, `strings.*`, `regex.metalThreadGroupSize`, `jobs.maxPerDrain`, `interrupt.counterInit`, `security.blockRemoteImports`, `quantum.*`.
- `../Resources/JeffJSConfig.plist` — the engine's shipped values (SwiftPM, CLI, tests, JeffJSConsole). `../Resources/JeffJSMetalGC.metal` (`gc_trial_decref`…, loaded by `Core/JeffJSMetalGC.swift`), `JeffJSMetalRegex.metal` (unused, see [RegExp](../RegExp/CLAUDE.md)), `QuantumSearch.metal` / `QuantumSimulator.metal` (`Quantum/QuantumGPU.swift`, `QuantumSimulatorGPU.swift`; `makeDefaultLibrary(bundle: jeffJSResourceBundle)` fallback).

## Invariants
- **Every key is overridable from the environment as `JEFFJS_<KEY_UPPER>`** (e.g. `cache.bytecodeEnabled` → `JEFFJS_CACHE_BYTECODEENABLED`, bools `1/0/true/false`); env wins over plist, plist over the code default. On the simulator prefix it `SIMCTL_CHILD_JEFFJS_…` (and boot the sim with them unset: `simctl boot` bakes `SIMCTL_CHILD_*` into launchd's env, see the app's "Watch memory").
- Values are read **once** (`static let`): set env vars before the first `JeffJSConfig` access — the watch model does `setenv("JEFFJS_…", …, 0)` in its init (`WatchRenderEngineModel.swift`: bytecode budgets, `GC_TEARDOWNFREESHEAP`, `STACK_MAXINLINEDEPTH`, `GC_BYTESSINCE*THRESHOLD`).
- **The app ships its own plist**: `React Natively/renderengine/JS/JeffJSConfig.plist` is in the app bundle and the engine's `Resources/JeffJSConfig.plist` is an Xcode exception for the "React Natively" target (pbxproj), so under `Bundle.main` the app's values are the only ones. A new key the app needs goes into both plists; the watch target excludes every `Resources/` file (no Metal, plist comes from the phone folder it includes).
- Edit the plist, not the code, for a value change; a new key = one `static let` here + plist entries + a doc line in `README.md` § "Configuration" when user-facing.
- Config keys are the only `JEFFJS_` env source. Direct `ProcessInfo` reads that bypass `JeffJSConfig` exist only as diagnostics (`JEFFJS_REGEX_WATCH`, `JEFFJS_GC_METAL`, `JEFFJS_TEST_UNMINIFY_EVAL`, `JEFFJS_GC_VERIFYROOTS`…); prefer a key with a documented A/B default.

- `JeffJSConfig.manualMemory` is not a plist key: it mirrors the compilation condition `JEFFJS_MANUAL_MEMORY` (the manual-memory core, issue #1), set by `JEFFJS_MANUAL_MEMORY=1` at `swift build` or in Xcode's active compilation conditions.
## Gotchas
- `build.precompilePolyfills` is **false in the shipped plists** (both); the app's `Scripts/precompile_polyfills.sh` reads the engine plist with PlistBuddy and skips when false — flip it to true for a `.jfbc` regen run and restore it (the app still loads the `.jfbc` either way).
- `cache.bytecodeMaxSize`: 0 = no cap from engine d563ff4 on, but the app plist uses 1 000 000 000 because older engines compared it against bytecode length (0 disabled caching).
- `stack.maxCallDepth` default 200 in code; the app plist sets 200 000 and `stack.maxInlineDepth` 60 000 (watch 10 000 via env) — the "Maximum call stack size exceeded" you see depends on which plist loaded.
- `quantum.enabled` defaults to `false` in code but `true` in both plists; the README table reports the plist value.
- Missing plist (bundle lookup fails) silently yields every code default — check `jeffJSResourceBundle` first when the CLI behaves unlike the app.

## Patterns to follow
- A/B switches: ship the new behaviour on and document the legacy value in the doc comment as `A/B: JEFFJS_<KEY>=0` (every `interp.*` key follows this).
- Per-call glue eval names must be listed in `cache.bytecodeExcludePrefixes` (app plist) so unique-per-call texts never hit the bytecode disk cache.

## Debug switches
- `JEFFJS_<KEY_UPPER>=…` — any key. Frequently used: `JEFFJS_CACHE_BYTECODEENABLED=0`, `JEFFJS_CACHE_BYTECODEDEBUG=1`, `JEFFJS_COMPILE_LAZYFUNCTIONS=0`, `JEFFJS_COMPILE_LAZYDROPDEBUG=1`, `JEFFJS_COMPILE_LAZYDROPSTRESS=1`, `JEFFJS_NATIVETWINS_ENABLED=0` / `_DEBUG=1`, `JEFFJS_WASM_ENABLED=0`, `JEFFJS_JSON_LAZY=0`, `JEFFJS_STORAGE_DEBUG=1`, `JEFFJS_GC_TEARDOWNFREESHEAP=0`, `JEFFJS_GC_VERIFYROOTS=1`, `JEFFJS_INTERP_SEGMENTEDSTACK=0`, `JEFFJS_SHAPES_MAXHASHEDPROPS=0`.

## Cross-area links
- [Bytecode](../Bytecode/CLAUDE.md) — what `cache.*` / `compile.*` / `trace.*` keys drive.
- [Core](../Core/CLAUDE.md) — `gc.*`, `shapes.*`, `strings.*`, `stack.*`, `interp.*` consumers; `JeffJSMetalGC` and its shader.
- [DOM](../DOM/CLAUDE.md) — `storage.*` quotas (`JeffJSWebStorage`).
- [Quantum](../Quantum/CLAUDE.md) — `quantum.*`.
- [React Natively app](../../../../../CLAUDE.md) — "Bytecode cache" row and "Working with the JeffJS submodule" (the app plist, `.jfbc` regen).

## Deep docs
- [`README.md` § "Configuration"](../../../README.md) — the user-facing key table.

## Suspected dead code
- `regexMetalThreadGroupSize` (`JeffJSConfig.swift`) — confidence: high — checked: `grep -rn regexMetalThreadGroupSize Sources jeffjs-cli Tests` → defined only.

## Suspected stale
None.
