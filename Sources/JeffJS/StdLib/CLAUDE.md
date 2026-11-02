# StdLib — Claude neuron

> Area: `Sources/JeffJS/StdLib/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The port of QuickJS `quickjs-libc.c`: the host-level globals a context gets from `JeffJSStdLib.addIntrinsics(ctx:)` —
console, timers, `performance`, `TextEncoder`/`TextDecoder`, `URL`/`URLSearchParams`, `structuredClone`,
`queueMicrotask`, `atob`/`btoa`, plus the `WebAssembly` namespace (`WasmJSAPI.install`, `../Wasm/`). Called once per
context by `JeffJSEnvironment`, the app's `JSScriptEngine` (main realm + workers, `renderengine/JS/WebWorkers.swift`)
and the tests. Console output is routed per context to a host callback.

## Key files
- `JeffJSStdLib.swift` — everything: per-context state (`JeffJSStdLibState`: timers, console counters/groups, `callerLocation`), `addIntrinsics` + one `add*` per module, the polling timer model (`JeffJSTimerEntry`, `pollTimers`, `getTimerDelay`), the QuickJS `std` / `os` modules (`addStdModule`, `addOsModule`) and `loop` (event loop), TypedArray helpers.

## Invariants
- `consoleCallbacks` / `contextStates` are process-wide tables keyed by context and guarded by `tablesLock`: contexts of different runtimes run on different threads (workers, `JeffJSThreadRuntime`) — never touch them without the lock.
- Call `removeConsoleCallback` / `removeState` when a context is freed, or the closure (and what it captures) outlives the page.
- The StdLib timers are a **polling** model (`pollTimers` must be driven). Browser hosts replace `setTimeout`/`setInterval` on the global with their own: `JeffJSEnvironment.installGCDTimers` and the app's `JSScriptEngine.installGCDTimers` (deadline-ordered, see the app's "Animation frames"). New host timer code goes there, not here.
- `setConsoleCallerLocation(ctx:enabled:)` is off by default; the app turns it on (`JSScriptEngine`, next to `setConsoleCallback`, gated by `ScriptUnminifyCache.enabled`). With it on, `console.warn`/`console.error` start with `[url:line:col] ` — the first Error argument's throw site (its stack's top frame, parsed by `JeffJSStackLocation.parse`; an `error` also appends the stack), else `ctx.currentScriptLocation()`. Keep that prefix format: the app's console parses it for the "unminified file.js:L:C" link.

## Gotchas
- `emitConsole` prints `[console.<level>] …` to stdout when no callback is set — a CLI process that "loses" console output has no callback registered (`docs/PERFORMANCE_PLAN.md` item 5).
- `console.log` arguments are formatted in Swift (`formatConsoleArgs`); group indentation (`groupPrefix`) is per context.
- `performance.now()` here is the StdLib's; the app replaces it with its navigation-timeline version (`NavigationTiming`), so a timing bug seen in the app may not be in this file.

## Patterns to follow
- A new web global that every realm needs goes into `addIntrinsics` as its own `add<Name>(ctx:)`; realm-specific or page-dependent surface belongs to the host polyfills ([Environment](../Environment/CLAUDE.md), the app's `<poly:dynamic>`).
- Native functions are registered with `ctx.setPropertyFunc`, and every JS value you create is freed (`definePropertyValue` dups its value — see the app's "Memory census" rule).

## Debug switches
- None read here directly. Console caller location is a host API (`setConsoleCallerLocation`), not an env var; the app's `RN_UNMINIFY_CONSOLE=0` turns the whole feature off on its side.

## Cross-area links
- [Environment](../Environment/CLAUDE.md) — who calls `addIntrinsics` in the engine and replaces the timers.
- [Utils](../Utils/CLAUDE.md) — `JeffJSUnminifier` / `JeffJSScriptSources`, the consumers of the caller-location prefix.
- [Core](../Core/CLAUDE.md) — `JeffJSStackLocation`, `currentScriptLocation`, error text (`JeffJSErrorText.swift`).
- [Wasm](../Wasm/CLAUDE.md) — `WasmJSAPI.install` runs from `addIntrinsics`.
- [React Natively app](../../../../../CLAUDE.md) — "JS unminifier" bullet under "JeffJS — pure Swift engine" (console prefix, tappable unminified excerpts).

## Deep docs
- [`docs/PERFORMANCE_PLAN.md`](../../../docs/PERFORMANCE_PLAN.md) — CLI measurement notes (console callback caveat).

## Suspected dead code
- `addStdModule`, `addOsModule`, `loop` (`JeffJSStdLib.swift` "QuickJS 'std' Module" / "'os' Module" / "Event Loop") — confidence: medium — checked: `grep -rn "JeffJSStdLib\.\(loop\|addStdModule\|addOsModule\|addPrint\)" Sources jeffjs-cli Tests JeffJSConsole "React Natively"` → 0 call sites outside the file (`addPrint` runs via `addIntrinsics`; `pollTimers` has one test caller, `CallbackRetentionConformance.swift`).

## Suspected stale
None.
