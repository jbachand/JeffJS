# Bench, Scripts, gcstress, Console — Claude neuron

> Area: `bench/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The engine's measurement scripts (`bench/`), its maintenance scripts (`Scripts/`), the collector stress input
(`Tests/gcstress/`) and the `JeffJSConsole` sample app. Everything here runs through `jeffjs-cli`
(`swift build -c release --product jeffjs-cli`); numbers feed `docs/PERFORMANCE_PLAN.md`, where every round's
before/after (QuickJS = `/opt/homebrew/bin/qjs`, jsc = the system binary) is recorded.

## Key files
- `kernels.js` — 10 micro kernels (int/float loops, calls, props, alloc, push, concat, closure, fib25); `run.sh` builds the
  CLI and prints ms per kernel vs the system `jsc` with and without JIT.
- `realworld.js` — 38 real-world kernels (json, vdom diff, array/string/regex, classes, closures, promises, proxies,
  generators, typed arrays…), one timed run after a warm-up, `name<TAB>ms<TAB>result` (results must agree across engines;
  runs under JeffJS, QuickJS and jsc). Round 14 docket result: suite 6488 → 4408 ms, 3.7x → 2.5x QuickJS.
- `watch_deepmerge.js` (Home Depot's deepmerge + `_objectSpread2`, verbatim), `watch_iter.js` (iterator protocol),
  `watch_callbacks.js` (native builtins calling JS callbacks), `watch_heap.js` (bytes per live object / string),
  `lazy_json.js` (3 MB ytInitialData-shaped payload, lazy vs eager) — the 2026-10-05 watch-interpreter set;
  `watch_run.sh [cli] [KEY=VALUE…]` prints instructions retired / cycles per file (`/usr/bin/time -l`, load-independent).
- `arc/` — ARC-removal harness (`README.md`): `ir.sh <cli> <bench.js>` (instr/cycles/RSS, ±0.05 %), `check.sh <cli>`
  (`leaks/*.js` under default / `JEFFJS_NO_POOL=1` / `JEFFJS_ZOMBIES=1`, outputs compared, RSS + `JEFFJS_TRACK_RC=1` live
  objects), `arc*.py` (xctrace retain/release attribution), `interpose/` (exact dynamic ARC counts via `DYLD_INSERT_LIBRARIES`).
- `arch/dispatch_bench.swift` — standalone dispatch microbenchmark behind `docs/EXECUTION_ARCHITECTURE_RETHINK.md` (`swiftc -O -wmo`).
- `../Scripts/run_tests.sh [release|debug] [--filter p]` — `swift test` under the CPU collector, again under `JEFFJS_GC_METAL=1`,
  then every `Tests/gcstress/*.js` under both, outputs diffed. `../Tests/gcstress/cycles.js` — the heap shapes.
- `../Scripts/update_bytecode_identity.sh [--check]` — recomputes `JeffJSBytecodeCache.engineSourceHash` (FNV-1a over
  `Parser/*.swift`, `JeffJSCompiler.swift`, `JeffJSOpcodes.swift`, `JeffJSBytecodeCache.swift`); names the disk-cache dir.
- `../Scripts/wasm_spectest.sh [name…]` + `wasm_spectest_gen.js` — WebAssembly 2.0 spec testsuite vs node (needs `brew install wabt`).
- `../JeffJSConsole/` — Xcode sample app (REPL `ConsoleView.swift`, `JeffJS Watch App`, `JeffJS Watch Widget`); `fastlane/`
  `beta`/`release` lanes driven by the manual `.github/workflows/testflight.yml` / `release.yml` (secrets in `.github/RELEASE.md`).

## Invariants
- Rebuild the CLI before timing: `swift test -c release` leaves a testability-enabled `jeffjs-cli` in `.build/release`
  (call-heavy kernels 15–25 % worse). `run.sh` rebuilds; `watch_run.sh` and `arc/*` take the binary you pass.
- A bench file prints its results through `console.log`, else `print` (jsc/qjs have no console): keep that prelude.
- `gcstress` scripts must be deterministic text (no pointers, addresses, timings) — byte-for-byte diff between collectors.
- A Parser/Bytecode change → `Scripts/update_bytecode_identity.sh` → regenerate the app's polyfill `.jfbc` (app rule).
- Report perf as best-of / geomean against a same-worktree base (what `docs/PERFORMANCE_PLAN.md` does); wall time on a
  shared Mac is noise (~0.1x) — prefer `ir.sh`/`watch_run.sh` instruction counts.

## Gotchas
- `JEFFJS_GC_METAL=1` drops the Metal crossover to zero and compiles kernels from the package resource bundle — without it
  the CLI and `swift test` never exercise the GPU collector (a var-ref seeding bug hid behind a green suite).
- `wasm_spectest.sh`: V8 implements post-2.0 proposals and keeps some NaN payloads, so a few files differ from node by design
  (listed in the script header). `lazy_json.js` eager comparison needs both `JEFFJS_JSON_LAZY=0` and `JEFFJS_COMPILE_LAZYLITERALS=0`.
- `arc/closure_loop_leak_repro.js` is a pre-existing leak kept as a repro, out of scope for the harness.

## Patterns to follow
- New kernel: add to `realworld.js` (or `kernels.js` for a pure interpreter path), keep the `bench(name, fn)` shape and a
  result value engines can be diffed on; cite the before/after row in `docs/PERFORMANCE_PLAN.md`.
- New collector stress shape: `Tests/gcstress/*.js` using the CLI's `__gc` / `__gcStats` natives.

## Debug switches
- `JEFFJS_GC_METAL=1` — GPU collector (run_tests.sh pass 2, gcstress). `JEFFJS_NO_POOL=1`, `JEFFJS_ZOMBIES=1`, `JEFFJS_TRACK_RC=1` — `arc/check.sh` modes.
- `JEFFJS_JSON_LAZY=0`, `JEFFJS_COMPILE_LAZYLITERALS=0` — eager `lazy_json.js`. `JEFFJS_DUMP=1` — bytecode dump (Phase 1).
- `WASM_SPECTEST_DIR` — spec-test work directory (default `$TMPDIR/jeffjs-wasm-spectest`).

## Cross-area links
- [jeffjs-cli](../Sources/jeffjs-cli/CLAUDE.md) — the binary every script drives; `--settle`/`--mem-census`/`--page`.
- [Engine tests](../Tests/JeffJSTests/CLAUDE.md) — the gate `run_tests.sh` wraps; `testEngineSourceHashIsCurrent`; WebAssembly group.
- [JeffJS engine root](../CLAUDE.md) — branches, config keys.
- [React Natively app](../../../CLAUDE.md) — app-side harnesses that drive the engine in a simulator: `Scripts/run_boot_harness.sh`,
  `Scripts/run_engine_bench.sh`; `Scripts/precompile_polyfills.sh` (.jfbc regen).

## Deep docs
- [`docs/PERFORMANCE_PLAN.md`](../docs/PERFORMANCE_PLAN.md) — baseline, rounds 5–14, "Measurement trap", every kernel's numbers.
- [`docs/EXECUTION_ARCHITECTURE_RETHINK.md`](../docs/EXECUTION_ARCHITECTURE_RETHINK.md) — why the bytecode VM stays (`arch/dispatch_bench.swift`).
- [`PERF_PLAN.md`](../PERF_PLAN.md) — one entry (engine 6cd832a, DOM one-writer contract + the CLI rebuild trap).
- [`.github/RELEASE.md`](../.github/RELEASE.md) — Console App Store pipeline.

## Suspected dead code
- None found (searched: `grep -rn 'create_project' Vendor/JeffJS --include='*.md' --include='*.sh'` → only itself, but it is
  a documented setup helper; `scratch/` (`b1_static.js`…`sym.js`, tracked) is referenced by no doc or script —
  `grep -rn 'scratch/' docs README.md PERF_PLAN.md` → 0 — low confidence, probe leftovers).

## Suspected stale
- `CONTRIBUTING.md` "CI runs `swift test` on every push" — no such workflow in `.github/workflows/` (only TestFlight/release).
- `README.md` "run the test runner inside `JeffJSConsole`" — `grep -rn 'TestRunner' JeffJSConsole` → 0 hits.
