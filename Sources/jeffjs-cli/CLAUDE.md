# jeffjs-cli — Claude neuron

> Area: `Sources/jeffjs-cli/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The engine's command-line runner (`executableTarget` `jeffjs-cli` in `Package.swift`, built with
`swift build -c release --product jeffjs-cli` → `.build/release/jeffjs-cli`). It evaluates script files in one
`JeffJSEnvironment` (shared globals, like one conformance group in one context), and is the measurement and
debugging tool behind `bench/`, `Scripts/run_tests.sh` (gcstress), `Scripts/wasm_spectest.sh`, the native-twin table
and the memory-census work. No DOM host: `--page` stubs the network so a saved page's scripts run reproducibly.

## Key files
- `main.swift` — argument parsing and every mode below; registers test natives on the environment: `__gc`, `__gcStats`
  (runs/cyclesFreed/liveObjects/heapBytes/threshold JSON), `__mallocInUse`, `__lazyStats`, `__lazyEvict`; `cliRunPage`
  (`--page`), `cliBurstJS` (`--burst`), `cliMallocInUse`, `cliFootprintMB`.
- `Unminify.swift` — `cliUnminifyMain`: `--unminify` / `--unminify-stack` over `JeffJSUnminifier` (engine `Utils/`).
- `MallocCensus.swift` — the app's `renderengine/JS/MallocCensus.swift` minus its UIKit parts (keep them in step): malloc-zone
  census by class, `referrerReport` (`--refs=`), `orphanReport`, `liveInstances`, `bigBlockReport` (`--big`).


**Modes** (all in `main.swift` / `Unminify.swift`):
- `jeffjs-cli <script.js>... [--result] [--quiet] [--eager] [--lazy-stats]` — run in order; `--result` prints the completion
  value; exit 1 on an uncaught exception; `--eager` = lazy function compilation off.
- `--parse-only [--repeat=N]` (best of 5) · `--bc-hash` (FNV-1a of the serialized bytecode, compiler identity) ·
  `--bc-hash-code` (same hash without positions/text/file name, every body compiled, lazy literals off: equal for
  scripts differing only in whitespace/comments).
- `--boot-bench[=N] [--jfbc=<bundle>]` — best-of-N runtime / context / environment / precompiled-bundle boot ms.
- `--page=<rn_fixtures dir> [--bundles=<dir>] [--precompile]` — `index.html` + `manifest.json` + `r/<files>`: scripts run in
  document order, modules from `<file>.bundle.js` in `--bundles`, fetch/XHR never settle; `--precompile` = the app's
  off-thread `JeffJSPrecompiler`. `JEFFJS_PAGE_VERBOSE=1` (exceptions), `JEFFJS_PAGE_TIMES=1` (ms per script, stderr).
- `--settle=S [--sample=N]` — run the main run loop S s so timers and the idle tick (collections, lazy reclaim) fire,
  `[settle]` lines (footprint/heap/objects/compiled/dropped/IC bytes); then `--mem-census` (`MallocCensus.report`),
  `--refs=JeffJS.<Class>` (who points at live instances), `--reclaim-cycles=N [--aggressive]`, `--burst` (UI events at
  window/document/200 elements). `--glue-evals=N` — N distinct `<native-event>` glue evals, timed.
- `--heap-report [--lazy-evict] [--roots] [--big] [--string-dups] [--bodies] [--mem-census] [--orphans]` — 3 GCs then live
  objects, malloc delta, per-object bytes, histogram. `--cache-stats` — bytecode cache + precompiler counters.
  `--teardown` / `--teardown-report` — free context + runtime (the suite's path) and list engine instances / orphan strings left.
- `--twin-table` — prints `JeffJSTwinTableData.swift` (native twin hash table) for `Builtins/Twins/`.
- `--unminify <file.js> [--out <path>] [--map] [--at L:C [--context N]] [--check] [--indent N] [--width N] [--pos-comments N]`;
  `--unminify-stack <file.js> --stack "<Error.stack>" [--stack-url <url>]`; `--rename` accepted but **not implemented**.

## Invariants
- Every mode runs inside `JeffJSHostActor.assumeIsolated` (the CLI's host actor executor is main); a new mode must too.
- `--bc-hash-code` must set `JEFFJS_COMPILE_LAZYLITERALS=0` and `--eager` (lazy payloads keep source text, lazy bodies are
  never compiled): anything added to the identity hash must stay position- and text-free.
- `--twin-table` output is checked by the `NativeTwins` conformance group against `JeffJSTwinTableData.entries`;
  regenerate after any compiler change (`swift run -c release jeffjs-cli --twin-table > Sources/JeffJS/Builtins/Twins/JeffJSTwinTableData.swift`).
- `__lazyEvict` runs with JS on the stack: tests only (hosts evict at idle).
- `main.swift` globals initialise in statement order: helpers the top-level code calls must be `func`s (see `cliBurstJS`).
- The CLI has no Metal default library: the GPU collector runs only under `JEFFJS_GC_METAL=1` (`Scripts/run_tests.sh`).

## Gotchas
- `swift test -c release` rebuilds `jeffjs-cli` **with testability on** (call-heavy kernels 15–25 % slower): always
  `swift build -c release --product jeffjs-cli` before timing (`bench/run.sh` does; `docs/PERFORMANCE_PLAN.md` "Measurement trap").
- `--unminify-stack` matches frames by the file's last path component (query ignored) unless `--stack-url` is exact.
- `--page` skips module scripts without a `--bundles` dump (counted as `skipped`) and never settles fetch/XHR.
- Conformance/probe runs through the CLI want `JEFFJS_CACHE_BYTECODEENABLED=0` (warm-cache hits lose expression spans;
  see [tests](../../Tests/JeffJSTests/CLAUDE.md)).

## Patterns to follow
- Memory questions: `jeffjs-cli <script> --settle=5 --mem-census --refs=JeffJS.JeffJSObject` (or `--heap-report --orphans`),
  never `heap`/`leaks` (cannot attach to simulator processes; this census walks the zones in-process).
- Compiler-identity questions: `--bc-hash-code a.js b.js` (same hash = same bytecode modulo positions).
- Counting instructions instead of wall time: `bench/arc/ir.sh <cli> <bench.js>` / `bench/watch_run.sh` (see [bench](../../bench/CLAUDE.md)).

## Debug switches
- `JEFFJS_PAGE_VERBOSE=1`, `JEFFJS_PAGE_TIMES=1` — `--page` diagnostics (above).
- Engine switches the CLI is usually run with: `JEFFJS_GC_METAL=1`, `JEFFJS_ZOMBIES=1`, `JEFFJS_NO_POOL=1`, `JEFFJS_TRACK_RC=1`
  (`bench/arc/check.sh` modes), `JEFFJS_JSON_LAZY=0` + `JEFFJS_COMPILE_LAZYLITERALS=0` (`bench/lazy_json.js` eager run),
  `JEFFJS_DUMP=1` (bytecode dump), `JEFFJS_TEST_UNMINIFY_EVAL=1`, `JEFFJS_CACHE_BYTECODEENABLED=0`. Any config key:
  `JEFFJS_<KEY_UPPER>` (`Config/JeffJSConfig.swift`).

## Cross-area links
- [Engine tests](../../Tests/JeffJSTests/CLAUDE.md) — the gate; `NativeTwins` checks `--twin-table`; gcstress runs through this CLI.
- [bench + Scripts](../../bench/CLAUDE.md) — every bench script is a CLI invocation.
- [JeffJS engine root](../../CLAUDE.md); [Twins](../../Sources/JeffJS/Builtins/Twins/CLAUDE.md) (`--twin-table`),
  [Utils](../../Sources/JeffJS/Utils/CLAUDE.md) (`JeffJSUnminifier`), [Bytecode](../../Sources/JeffJS/Bytecode/CLAUDE.md)
  (cache, precompiler, lazy reclaim), [Config](../../Sources/JeffJS/Config/CLAUDE.md) (`JEFFJS_<KEY>` overrides).
- [React Natively app](../../../../CLAUDE.md) — "JS unminifier" (CLI flags from the app side), "Memory census",
  `Scripts/run_boot_harness.sh` / `Scripts/run_engine_bench.sh` (the simulator-side harnesses, not this CLI).

## Deep docs
- [`docs/PERFORMANCE_PLAN.md`](../../docs/PERFORMANCE_PLAN.md) — Phase 1 (the CLI's origin), "Measurement trap", Round 14 (`--page` with `JEFFJS_PAGE_TIMES`).
- [`bench/arc/README.md`](../../bench/arc/README.md) — exact dynamic ARC counts via `DYLD_INSERT_LIBRARIES` interpose on this binary.

## Suspected dead code
- None found (searched: every `--flag` string in `main.swift`/`Unminify.swift` is handled in the same file; `--rename` is a
  documented no-op, not dead).

## Suspected stale
- None. (`README.md` has no `jeffjs-cli` section: `grep -n 'jeffjs-cli' README.md` → 0 hits; the usage lives in the file headers.)
