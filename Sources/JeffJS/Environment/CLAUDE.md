# Environment — Claude neuron

> Area: `Sources/JeffJS/Environment/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
`JeffJSEnvironment` is the engine's turnkey browser-shaped runtime: one runtime + context + empty document with every
bridge registered (DOM, events, storage, cookies, fetch, WebSocket, IndexedDB, video, dynamic import, Web APIs,
quantum), the engine's own polyfills evaluated and GCD timers installed. It is what `jeffjs-cli`, the JeffJSConsole
apps (phone/watch/widget) and most of `Tests/JeffJSTests` drive. **The React Natively page engine does not use it**
(`JSScriptEngine` builds its own context and polyfill layers); the app's only instance is HydraDOM's launch splash
(`renderengine/HydraDOM/HydraBootHost.swift`, `boot.js`, base URL `app://hydra-boot`).

## Key files
- `JeffJSEnvironment.swift` — `Configuration` (baseURL, userAgent, viewport, dpr, storageScope, videoProvider, dynamicImportDelegate, `additionalPolyfills`, `startupScripts`, cookieJar, webStorage, browsingContext); `init` = 21 numbered steps (runtime/context → document → `initScript` → `JeffJSStdLib.addIntrinsics` → console callback → `__nativeGetComputedStyleValue` → bridges 8–17 → `evaluatePolyfills` → `installGCDTimers` → startup scripts → built-in global capture); `eval`/`evalAsync`/`compileOnly`/`evalPrecompiledBundle`, `makeChildRealm`, GC + lazy-compile + bytecode-cache accessors, layout-rect store (`updateLayoutRects`), `registerNativeFunction`, `consoleCompletions`, user-globals snapshot, `teardown`. `DefaultDynamicImportDelegate` at the end.
- `JeffJSPolyfills.swift` — the **engine's** polyfill texts: `globalsPolyfill` (DOMException, Event/CustomEvent, Node constants, window stubs), `locationPolyfill(for:)`, `navigatorPolyfill(userAgent:)`, `historyPolyfill(for:)`, `viewportAndMediaPolyfill(...)`, `fetchAndXHRPolyfill`; `escapeJSString`. Evaluated as `<poly:globals>` … `<poly:fetch>`, then the host's `additionalPolyfills` as `<poly:custom-i>`.
- `JeffJSGlobalSnapshot.swift` — `snapshotUserGlobals` / `restoreUserGlobals` JS: user-added `globalThis` properties as a tagged JSON tree (cycles by id table; functions / DOM nodes / natives skipped and reported in `JeffJSSnapshotResult.skipped`). Used by the JeffJSConsole apps' persisted globals.
- `JeffJSEnvironment+HeapDebug.swift` — `heapHistogram`, `rootReport`, `functionBodyReport`, `stringDuplicateReport` for `jeffjs-cli --heap-report/--roots/--orphans`.
- `JeffJSEnvironment+LazyPayload.swift` — `lazyPayloadSummary` / `lazyPayloadStatsJSON` / `evictLazyPayloads` over the lazy JSON payload counters (`../Core` `JeffJSLazyPayload.swift`, `json.*` keys).

## Invariants
- `JeffJSEnvironment` is `@JeffJSHostActor`-isolated: create and use it on the host actor (the app's splash uses `JeffJSHostActor.assumeIsolated` on main because the page thread is off there). Its console callback hops to main when not already there.
- `installGCDTimers` **replaces** the StdLib polling timers on the global — a host that keeps `JeffJSEnvironment` must not also drive `JeffJSStdLib.pollTimers`.
- The quantum bridge is registered unconditionally (step 17); `window.jeffjs.quantum.enabled` mirrors `quantum.enabled` (see [Quantum](../Quantum/CLAUDE.md)).
- `Environment/` and `Quantum/` are **excluded from the app's polyfill precompile harness** (`Scripts/precompile_polyfills.sh` compiles the engine without `DOM/`, `Environment/`, `Quantum/`): nothing in `Core/ Builtins/ Bytecode/ Parser/ RegExp/ StdLib/ Utils/` may depend on a symbol defined here, or the `.jfbc` generator stops building. That is why the heap-debug walks live in this folder.
- Every class here that holds engine objects is on the host actor or `nonisolated` with explicit teardown (`teardown()` frees runtime/context); never let a runtime be released on a thread while another is inside it (engine threading rule).

## Gotchas
- These polyfills are a **separate, smaller surface** from the app's (`JSScriptEngine`'s `<poly:dynamic>`, the Safari surface pass, the precompiled `.jfbc`). A fix made here does not reach pages in React Natively and vice versa; the app only shares `JeffJSStdLib` and the bridges. `initScript` even stubs `requestAnimationFrame` as `setTimeout(cb, 16)` and `ResizeObserver`/`IntersectionObserver` as no-ops.
- `DefaultDynamicImportDelegate` resolves against `baseURL` with the configured UA; `security.blockRemoteImports` refuses http(s) `import()`.
- `onConsoleMessage` never fires from a plain CLI process unless set (`docs/PERFORMANCE_PLAN.md` item 5).

## Patterns to follow
- Host-specific JS goes in `Configuration.additionalPolyfills` / `startupScripts`, host natives through `registerNativeFunction` — do not grow `initScript`.
- A new bridge is registered in `init` as the next numbered step and released in `teardown()`.

## Debug switches
- `jeffjs-cli --heap-report`, `--roots`, `--orphans`, `--string-dups`, `--lazy-stats`, `--lazy-evict`, `--cache-stats`, `--teardown-report` — exercise the accessors above (`jeffjs-cli/main.swift`).
- `JEFFJS_JSON_LAZY=0`, `JEFFJS_JSON_LAZYEVICTONIDLE`, `JEFFJS_JSON_LAZYTHRESHOLDBYTES` — the lazy payload the `+LazyPayload` counters describe ([Config](../Config/CLAUDE.md)).

## Cross-area links
- [StdLib](../StdLib/CLAUDE.md) — `addIntrinsics`, console callback, the polling timers replaced here.
- [DOM](../DOM/CLAUDE.md) — the bridges registered in steps 8–16.
- [Config](../Config/CLAUDE.md) — `security.blockRemoteImports`, `quantum.*`, `json.*`.
- [Quantum](../Quantum/CLAUDE.md) — `JeffJSQuantumBridge` (step 17).
- [React Natively app](../../../../../CLAUDE.md) — "HydraDOM v2 … Launch splash" (the app's one `JeffJSEnvironment`); "Working with the JeffJS submodule" for the `.jfbc` regen rule.

## Deep docs
- [`README.md` § "The Quantum module" / "Configuration"](../../../README.md) — the environment-level JS API as users see it.
- [`docs/PERFORMANCE_PLAN.md`](../../../docs/PERFORMANCE_PLAN.md) — CLI harness notes (`runGC`, console caveat).

## Suspected dead code
- None found (searched: `grep -rl "JeffJSEnvironment(\|JeffJSPolyfills\|JeffJSGlobalSnapshot\|snapshotUserGlobals" Sources jeffjs-cli Tests JeffJSConsole "React Natively"` — every file has callers in the CLI, tests, console apps or the app's `HydraBootHost`).

## Suspected stale
None.
