# Utils — Claude neuron

> Area: `Sources/JeffJS/Utils/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
Leaf helpers with no engine state of their own: QuickJS `cutils`/`list`/`dtoa` ports, the tooling hooks for the CLI's
heap reports, the weak per-URL script-text registry, and the JS unminifier (pretty-printer) the app's console and
`jeffjs-cli --unminify` use. `Unicode/` (next door, no own doc) is the `libunicode.c` port: `JeffJSUnicode`
(classification, case conversion, `isSpace`…) over `JeffJSUnicodeTable` (ID_Start/ID_Continue, categories, composition).

## Key files
- `JeffJSCUtils.swift` — `DynBuf` (growable byte buffer for bytecode serialisation / string building), radix integer→string (`i64toa`, `u64toa`), UTF-8/UTF-16 helpers (`unicodeFromUTF8`, surrogate predicates), LEB128, safe arithmetic.
- `JeffJSList.swift` — `ListHead` intrusive doubly-linked list (`listAdd`, `listDel`, `listForEach*`, `ListSequence`). See "Suspected dead code".
- `JeffJSDtoa.swift` — `jsDtoa`/`jsDtoa2`/`jsFcvt`/`jsAtof`, `DtoaFormat` (port of `dtoa.c`). See "Suspected dead code".
- `JeffJSHeapDebug.swift` — `describeString(at:)` etc.: describe an engine object found by a malloc-zone walk without the tool knowing engine internals (`jeffjs-cli --orphans`, `--heap-report`; environment-level walks are in `../Environment/JeffJSEnvironment+HeapDebug.swift`).
- `JeffJSScriptSources.swift` — `register(filename:text:)` (called where a script's text is attached to its code: fresh compile in `../Core/JeffJSObject.swift`, bytecode-cache hit in `../Bytecode/JeffJSBytecodeCache.swift`) and `sourceBytes(forURL:)` / `liveURLs`: a **weak** table of `JeffJSSourceText` by stack-frame URL (query/fragment stripped by `JeffJSContext.stackFrameURL`; `<inline>`-style names never registered; later script with the same URL wins).
- `JeffJSUnminifier.swift` — `JeffJSUnminifier.format(_:)` / `format(span:)` → `JeffJSUnminified`: formatted text + position map both ways (`formattedPosition(line:column:)`, `originalPosition`, `formattedOffset`), `excerpt(originalLine:column:context:)`, `enclosingFunction(...)`, `rewriteStack(...)`; `JeffJSUnminifyOptions` (indent, width, position comments).

## Invariants
- The unminifier is a **token-stream printer on the engine tokenizer** (`JeffJSParseState.nextToken`; the parser has no AST): token bytes are copied verbatim, only inter-token whitespace changes, and a newline is never added where ASI / restricted productions would change meaning. Keep it that way — the test suite (`Tests/JeffJSTests/UnminifierTests.swift`) checks the output re-tokenizes to the same sequence (`jeffjs-cli --unminify … --check`).
- Positions use the engine convention everywhere: 1-based lines split at `\n`/`\r`/`\r\n`, 1-based **UTF-8 byte** columns — what `Error.stack` frames print.
- `JeffJSScriptSources` must never keep a text alive (weak entries, table pruned every 64 inserts). Call `sourceBytes` from the runtime's JS thread (the text may be re-homed into a file mapping there); the returned span is immutable and may go to any thread.
- Everything here is `nonisolated` (engine rule); `JeffJSHeapDebug`/`JeffJSScriptSources`/the unminifier are `public` because `jeffjs-cli` and the app call them.

## Gotchas
- Script text registered here is the **evaluated** text (after the app's rewrite passes / module bundling), so positions match stack frames; the app's HTTP-cache fallback is only approximate. Inline scripts have no URL (`fn@`) and cannot be resolved.
- `--rename` is accepted by the CLI but not implemented (needs scope analysis); output is unrenamed.
- `JEFFJS_TEST_UNMINIFY_EVAL=1` (read in `../Core/JeffJSContext.swift`) formats every global/module script before compiling — conformance then fails only `toString` / line:col tests, by design.

## Patterns to follow
- New byte-level helpers go into `JeffJSCUtils.swift` next to their QuickJS counterpart; do not add callers to `JeffJSDtoa.swift` without checking what the Number builtin already uses (nothing references that file today, see below).
- A host that wants a script's exact text asks `JeffJSScriptSources.sourceBytes(forURL:)` instead of re-fetching (the app: `renderengine/JS/ScriptUnminifyCache.swift`, LRU-formats off the main thread).

## Debug switches
- `jeffjs-cli --unminify <file.js> [--out <path>] [--map] [--at <line>:<col> [--context N]] [--check] [--indent N] [--width N] [--pos-comments N]` — format / excerpt / self-check.
- `jeffjs-cli --unminify-stack <file.js> --stack "<Error.stack>" [--stack-url <url>]` — rewrites frames to unminified positions.
- `jeffjs-cli --bc-hash-code <files>` — bytecode hash without positions (equal for scripts differing only in whitespace/comments).
- `jeffjs-cli --heap-report | --roots | --orphans | --string-dups`, `--mem-census`, `--refs=JeffJS.<Class>` — heap tooling built on `JeffJSHeapDebug` (`jeffjs-cli/main.swift`).
- `JEFFJS_TEST_UNMINIFY_EVAL=1` — see Gotchas.

## Cross-area links
- [StdLib](../StdLib/CLAUDE.md) — the `[url:line:col] ` console prefix the app's unminified-excerpt view starts from.
- [Core](../Core/CLAUDE.md) — `JeffJSSourceText`, `stackFrameURL`, the tokenizer entry the unminifier drives.
- [Bytecode](../Bytecode/CLAUDE.md) — cache hits re-register script texts; `nameFreeBytes` is what `--bc-hash-code` prints.
- [React Natively app](../../../../../CLAUDE.md) — "JS unminifier" bullet (console links, `RN_UNMINIFY_CONSOLE=0`, `RN_UNMINIFY_TIMING=1`, `RN_UNMINIFY_AUTO_EXPAND=<n>`).

## Deep docs
- [`README.md` § "Project layout"](../../../README.md) — the one-line folder map (still says "dtoa, list utilities").

## Suspected dead code
- `JeffJSDtoa.swift` (whole file) — confidence: high — checked: `grep -rn "Dtoa\|jsAtof\|ATODFlags\|JsAtofResult\|jsIsNaN\|jsIsFinite\|jsSignBit" --include='*.swift' Sources jeffjs-cli Tests` → 0 references outside the file.
- `JeffJSList.swift` list operations (`listAdd`, `listDel`, `listForEach*`, `ListSequence`, `listEntry`) — confidence: medium — checked: same grep over `Sources` → 0 call sites; only the `ListHead` type survives as `JeffJSRuntime.contextList` / `gcObjList` fields (8 references in `Core/`), `ListNode` is defined in `Core/JeffJSObject.swift`.

## Suspected stale
None.
