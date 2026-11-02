# RegExp — Claude neuron

> Area: `Sources/JeffJS/RegExp/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The regular-expression compiler and backtracking VM: a 1:1 port of QuickJS `libregexp.c` / `libregexp-opcode.h`
(pattern → regex bytecode → match + captures). Called only through the `RegExp` builtin
(`../Builtins/JeffJSBuiltinRegExp.swift`, `js_regexp_execInternal`), which owns the per-runtime caches around it.
Names mirror the C original (`lre_*`) so the two can be compared side by side.

## Key files
- `JeffJSRegExp.swift` — flags (`JeffJSRegExpFlags`), `CharRange` sets, case tables (`LRECaseTables`, `lreCanonicalizeChar`), the compiler (`lreCompile`), the VM (`REVirtualMachine`: `rebind`/`reset`/`exec`, `inUse` while a cached VM runs), `lreExec` / `lreExecGlobalMatch`, bytecode readers (`lreGetFlags`, `lreGetCaptureCount`, `lreGetGroupNames`).
- `JeffJSRegExpOpcodes.swift` — `JeffJSRegExpOpcode` (byte ids, payload widths, metadata) — must stay identical to QuickJS.
- `JeffJSMetalRegex.swift` — optional Metal NFA matcher (`JeffJSMetalRegex.shared`, `gpuMatchAll`, `shouldUseGPU` > 1 000 code units; `#if canImport(Metal)` with a nil-returning stub otherwise). Shader: `../Resources/JeffJSMetalRegex.metal` (`regex_match_all`). See "Suspected dead code".

## Invariants
- Every top-level declaration is `nonisolated` (engine rule, `EngineThreadingRuleTests`); the VM is used by one JS thread per runtime like the rest of the heap.
- A VM handed out by `JeffJSRegexCaches.vm(for:…)` is owned by the caller until it clears `inUse`; a busy cached VM means a fresh one, never a shared one.
- **Per-string identity caches revalidate by length**: `JeffJSRegexCaches.codeUnits(of:)` (in `JeffJSBuiltinRegExp.swift`) is keyed by `JeffJSString` identity, and `s += c` grows an unshared string in place (`appendInPlace`), so an entry is valid only while `count == s.len`. Any new cache keyed by string identity must do the same (apple.com's animation-expression tokenizer matched a stale one-character copy before this).
- Opcode ids / encodings in `JeffJSRegExpOpcodes.swift` and the `NFAInstruction` layout (8 bytes, mirrors `NFAInstr` in the `.metal`) are wire formats: change both sides together or not at all.
- Architectural changes to the regex engine need an issue first (`CONTRIBUTING.md` "What needs an issue first").

## Gotchas
- A page stalled in regex backtracking shows only `REVirtualMachine` frames in a sample: run with `JEFFJS_REGEX_WATCH=1`, which names every exec over 250 ms (pattern, flags, input length, start positions tried) and reports once after 2 s while still running.
- Capture offsets come straight from the VM over the cached `[UInt32]` code units; `lreIsInsideSurrogatePair` keeps non-unicode matches from splitting pairs.
- Group names are read from the bytecode (`lreGetGroupNames`) and cached per compiled pattern (`JeffJSRegexCaches.groupNames`, 8 entries).

## Patterns to follow
- Port, do not invent: a behaviour fix should be defensible against `libregexp.c`.
- Reuse across start positions: compile once, convert the input once, one VM per pattern (`docs/PERFORMANCE_PLAN.md`: regex-tokenize 15 754 → 80 ms). Do not allocate a VM or re-convert the input per `exec` in new code.
- Caches live on the runtime (`JeffJSRuntime.regexCaches`), never as fields on every string (the old `hashNext` link was dropped for that reason, `../Core/JeffJSString.swift`).

## Debug switches
- `JEFFJS_REGEX_WATCH=1` — stderr report for execs > 250 ms (read directly from the environment, not a config key).
- `JEFFJS_REGEX_METALTHREADGROUPSIZE=<n>` — overrides `regex.metalThreadGroupSize` (256); currently read by nothing (see below).

## Cross-area links
- [Builtins](../Builtins/CLAUDE.md) — `JeffJSBuiltinRegExp.swift`: `RegExp.prototype.*`, `JeffJSRegexCaches`, the watch diagnostic.
- [Core](../Core/CLAUDE.md) — `JeffJSString` storage (`str8`/`str16`, `appendInPlace`) the input cache reads.
- [Utils](../Utils/CLAUDE.md) — also covers `../Unicode/` (`JeffJSUnicode` / `JeffJSUnicodeTable`, the case-folding and property tables the compiler reads; no doc of its own).
- [Config](../Config/CLAUDE.md) — `regex.*` keys and the `JEFFJS_<KEY>` override rule.
- [React Natively app](../../../../../CLAUDE.md) — the regex input-cache rule in "Working with the JeffJS submodule" (2026-10-22, `fix/regex-input-cache`).

## Deep docs
- [`docs/PERFORMANCE_PLAN.md` "regex exec"](../../../docs/PERFORMANCE_PLAN.md) — the bytecode/VM/code-unit reuse that made regex-tokenize 11x faster.
- [`README.md` § "Metal GPU acceleration"](../../../README.md) — what the Metal matcher was meant to do.

## Suspected dead code
- `JeffJSMetalRegex` + `Resources/JeffJSMetalRegex.metal` + `JeffJSConfig.regexMetalThreadGroupSize` — confidence: high — checked: `grep -rln "gpuMatchAll\|JeffJSMetalRegex\|regexMetalThreadGroupSize\|regex_match_all" Sources jeffjs-cli Tests "React Natively" JeffJSConsole` → only its own file, the shader and the Config line; no call site. The README still advertises it.

## Suspected stale
None (the root CLAUDE.md's `JeffJSRegexCaches.codeUnits` / `appendInPlace` / `JEFFJS_REGEX_WATCH` claims all verified; note the cache class lives in `Builtins/`, not here).
