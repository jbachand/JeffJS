# WebAssembly — Claude neuron

> Area: `Sources/JeffJS/Wasm/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
JeffJS's own WebAssembly (JeffJS issue #13, landed 2026-10-29): a Core 2.0 binary decoder + validator, a slot-addressed
interpreter and the W3C JS API (`WebAssembly.*`), no JIT. Input: module bytes from JS (`new WebAssembly.Module`,
`compile`, `instantiate`, `*Streaming` over a `Response`); output: `Instance` exports that call into the interpreter and
back out to JS imports. Installed into every new context by `JeffJSStdLib.addIntrinsics` (`WasmJSAPI.install(ctx:)`, its last
step), so page realms, iframe realms and worker runtimes all get it. Why it exists: hCaptcha's hsw
proof-of-work is a 1 MB wasm-bindgen module with no JS fallback (app `HCAPTCHA_PLAN.md`, D9).

## Key files
- `JeffJSWasmModule.swift` — module structure (`WasmModule`, types/imports/exports/segments/const exprs) + `WasmDecoder`
  (§5 binary format, limits `maxMemoryPages` 65536 / `maxTableSize` 10 000 000); `WasmError` (compile/link/trap/
  jsException/stackOverflow). Compile errors read like JSC's ("WebAssembly.Module doesn't parse at byte N: …").
- `JeffJSWasmCompiler.swift` — one-pass validation (operand-type stack + control stack, `WasmOperand.unknown` in
  unreachable code) that emits `WasmInstr` (`op`, slot `s`, immediates `a`/`b`) into `WasmCompiledFunction`; `prefixed()`
  = the 0xFC ops (saturating truncation, bulk memory/table); 0xFD/0xFE throw.
- `JeffJSWasmRuntime.swift` — `WasmMemory` (bytes are a `JeffJSArrayBuffer`'s `data`), `WasmTable`, `WasmGlobal`,
  `WasmFunction` (defined or host), `WasmRefs` (process-wide ref-id table), `WasmStore` (per realm), `WasmInstance`
  (`initialize` = §4.5.4 instantiation, `evalConst`), `WasmStack` (per-thread 4 MiB slot stack), `WasmInterpreter`.
- `JeffJSWasmJSAPI.swift` — natives `__jeffjsWasm` (compile/validate/instantiate/exports/imports/custom, value
  conversions `toJS`/`toWasm`, exported-function objects) + the JS `glue` text that builds the namespace per realm.
- Tests: `../../../Tests/JeffJSTests/WebAssemblyConformance.swift` (group "WebAssembly": prelude + 37 sync + 4 async
  cases, V8/node 22 answers, WAT in the header; `swift test -c release --filter EngineTests/testWebAssemblyGroup`);
  `../../../Scripts/wasm_spectest.sh` + `wasm_spectest_gen.js` (official 2.0 testsuite, needs `brew install wabt` + node).

## How the interpreter is structured
- Values are 64-bit slot bit patterns: i32/f32 zero-extended (reinterprets and `i64.extend_i32_u` are no-ops), refs are
  `WasmRefs` ids (0 = null). Validation knows the stack height at every instruction, so compiled code addresses slots
  directly: slots 0..<localCount = locals (params first), then operand positions; `drop`/`nop`/`block` emit nothing;
  branches carry target pc, height to restore and values to keep (copied only when not already in place).
- A call puts the callee's frame on the caller's argument slots, so results land where the caller expects them.
  Wasm→wasm calls run in one `run` loop with an explicit `Frame` array; a host (JS) import goes through `callHost`
  (ToJSValue args, `ctx.callFunction`, ToWebAssemblyValue results, multi-value = iterated). Entry from JS: `invoke`.
- Depth: `WasmInterpreter.maxFrames` 20 000 across re-entries → `RangeError: Maximum call stack size exceeded.`
- Memory: `memory.grow` (by 0 pages too) detaches the old `ArrayBuffer` and moves the bytes (JS API "refresh the memory
  buffer"); growth past 1 GiB is refused. The loop caches the memory base pointer and re-reads it (`memoryView`) after
  every call out to JS, every grow and every instance switch.

## Invariants
- Everything here is `nonisolated` (engine top-level rule); the interpreter runs on whichever thread entered the runtime.
  `WasmStack.current()` is per thread (`Thread.current.threadDictionary`); `WasmRefs.shared` and `WasmJSAPI.exported`
  are process-wide under `NSLock`s — ids / object keys are never reused while listed.
- **Ownership = the realm's `WasmStore`** (`JeffJSContext.wasmStore`, made on first use, released by `JeffJSContext.free`):
  it lists instances (added *before* `initialize`, so a trapping segment leaves earlier table writes, as linking.wast
  wants), host functions, ref ids, exported-function keys, wrapped Swift objects and the three error constructors. Swift
  objects hold JS values that hold them back — a cycle the collector cannot see — so wasm objects live until their realm
  goes. A function another realm still holds keeps a `dead` instance and traps ("call to a function whose realm was
  destroyed"). Any new Swift↔JS reference must be registered in the store (`wrapped` / `exportedKeys` / `refIDs`).
- `WasmFunction.instance` is `unowned(unsafe)` + `instanceRef` strong: keep both in sync; `WasmStore.release` is what
  breaks the instance ↔ function cycle.
- Identity: one JS object per memory/table/global/function (`handle(…)`, `exportedFunction`): exports and table reads
  return the same object; a re-exported host function gets its own Exported Function of the wasm type (type-checked on
  re-import). Exported functions are host functions named after their index, `length` = param count, not constructors.
- NaNs never cross into JS raw: `toJS` canonicalises (JeffJS values are NaN-boxed; a payload could read as a tag) and
  `JeffJSValue.newFloat64Purified` does the same for typed-array/DataView reads (found by the spec suite).
- Glue functions look native (`N.mark` → `markPlatformFunction`): hsw fingerprints
  `Function.prototype.toString.call(WebAssembly.compile).length`. Keep the glue JSC-shaped (names, lengths, messages).
- `CompileError`/`LinkError`/`RuntimeError` are real NativeErrors made by the glue (`makeError`) and registered via
  `N.errors` (`WasmStore.errorCtors`); natives report them as `"Kind:message"` strings the glue's `fail` rethrows.
  The app's Safari-surface stub rule for them (`SafariSurfaceOrder.interfaceStub`) only matters with wasm disabled.
- `__jeffjsWasm` is taken by the glue and deleted; never leave a `__`-less global behind.

## Gotchas
- Not implemented (all `CompileError`, so feature detection falls back): SIMD (0xFD, `v128`), threads/atomics (0xFE,
  shared memory → also a `TypeError` from `new Memory({shared:true})`), exception handling (tag section/imports), GC,
  memory64, multiple memories, tail calls. Extended constant expressions (i32/i64 add/sub/mul) *are* accepted.
- Export names and `customSections(name)` compare by code points, not Swift `String ==` (canonical equivalence merged
  "Å" and "A\u{30A}" in names.wast).
- A missing `Table.set`/`grow` value is DefaultValue (externref undefined, funcref null); a present `undefined` is
  converted (funcref → TypeError), as V8.
- Spec suite known diffs are node's (post-2.0 proposals, NaN payloads through JS); see the header of `wasm_spectest.sh`.
- hCaptcha's module validates + compiles in ~40 ms; the proof-of-work itself is interpreter-bound (see Deep docs).

## Patterns to follow
- A new instruction: decode + validate + `emit` in `FunctionCompiler` (slot convention in the `WasmOp` comment), one
  `case` in `run`; keep the "binary: s, s+1 → s" layout. A new unsupported proposal: throw `err("… not supported")`.
- A new JS API member: algorithm in the `glue` (spec wording, JSC messages, `method`/`getter`/`ctor` helpers so it is
  marked native), heavy lifting as a `def(...)` native; add a V8-checked case to `WebAssemblyConformance.swift`.
- Do not create JS objects in Swift without routing them through the store (`handle`, `exportedFunction`).

## Debug switches
- `JEFFJS_WASM_ENABLED=0` (config `wasm.enabled`) — no `WebAssembly` global at all. Simulator: `SIMCTL_CHILD_` prefix.
- `WASM_SPECTEST_DIR=<dir>` — work dir of `wasm_spectest.sh` (default `$TMPDIR/jeffjs-wasm-spectest`); run one file
  with `Scripts/wasm_spectest.sh memory_grow linking`.
- No runtime trace flag exists; traps surface as `WebAssembly.RuntimeError` with the messages listed in `run`.

## Cross-area links
- [JeffJS engine root](../../../CLAUDE.md) — threading / `nonisolated` rules, config keys, test runner.
- [Core](../Core/CLAUDE.md) — `JeffJSContext.free` (store release), `JeffJSArrayBuffer`, NaN-boxing (`newFloat64Purified`).
- [Builtins](../Builtins/CLAUDE.md) — typed arrays / BigInt the conversions rely on.
- [React Natively app](../../../../../CLAUDE.md) — app-side consumers; app `renderengine/JS` for the Safari surface
  (`SafariSurfaceOrder.swift`: WebAssembly's error types are NativeError stubs when the namespace is absent).

## Deep docs
- [`HCAPTCHA_PLAN.md` § "Status" / D9](../../../../../HCAPTCHA_PLAN.md) — why wasm exists here, the hsw module profile.
- [`docs/EXECUTION_ARCHITECTURE_RETHINK.md`](../../../docs/EXECUTION_ARCHITECTURE_RETHINK.md) — "WebAssembly as a
  target": the JIT ban and the interpreter-speed question.
- Engine git log `3234928`, `9f1c055`, `6e35f6f`, `7ca23c3`, `eb3516c` — the spec-suite and ownership fixes in detail.

## Suspected dead code
- `WasmError.link` (`JeffJSWasmModule.swift`) — confidence: medium — checked: `grep -rn 'WasmError\.link\|throw .*\.link('
  Sources` → 0 throw sites; only matched in `WasmJSAPI.throwWasm`'s switch. Link failures are returned as
  `"LinkError:…"` strings from `instantiate` instead.
- `WasmValType.v128` arms in `toJS`/`toWasm` (`JeffJSWasmJSAPI.swift`) — confidence: low — unreachable while the
  decoder rejects `v128` (`invalid value type`), kept for exhaustiveness.

## Suspected stale
- Root CLAUDE.md: "passes 27,406 assertions" — not re-run here; nothing in the tree records the number
  (`grep -rn '27,406\|27406' Vendor/JeffJS --include='*.md' --include='*.sh'` → 0). Treat as the 2026-10-29 result.
- Root CLAUDE.md: "42 checks" — the group has 37 sync + 4 async cases plus the prelude (41 asserted expressions).
