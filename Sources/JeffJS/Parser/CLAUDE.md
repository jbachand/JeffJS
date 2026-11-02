# JeffJS Parser — Claude neuron

> Area: `Sources/JeffJS/Parser/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The tokenizer and the single-pass recursive-descent parser of JeffJS, a 1:1 Swift port of QuickJS's `next_token` /
`js_parse_*` (quickjs.c). **There is no AST**: the parser emits bytecode straight into a `JeffJSFunctionDefCompiler`
(`../Bytecode/JeffJSCompiler.swift`), which then runs the compiler passes (label resolution, peepholes, lazy stubs).
Input = script bytes (`JeffJSBytesSpan`, possibly a file mapping), output = per-function bytecode + constant pools +
scope/variable tables. Callers: `JeffJSContext` (eval / module / lazy body compiles), the compiler's lazy re-parse,
`JSON.parse` (the tokenizer's JSON mode), native twins and the unminifier (`../Utils/JeffJSUnminifier.swift`).

## Key files
- `JeffJSTokenizer.swift` — `JeffJSToken`, `JeffJSParseState` (buffer, `gotLF`, `lineNum`, `getLineCol` cache, syntax-error
  capture), `nextToken` / regexp-vs-division (`slashIsDivision`, `reParseAsRegexp`), string/template/number/regexp lexing,
  UTF-8 decoding, keyword table (QuickJS atom order), `jsonNextToken` (JSON mode, `extJSON`), `detectModule` (`JS_DetectModule`),
  ASI `expectSemicolon`, `peekToken` / `simpleNextToken` lookahead.
- `JeffJSParser.swift` — `JeffJSParser`: scopes/vars/block envs/finally scopes, `emit*` helpers, statements, functions +
  parameters (default/rest/destructuring replay), lazy seeds, import/export, the expression grammar (assignment rewriting,
  optional chains, arrows, templates, destructuring, yield/await), `tryLazyLiteral`.
- `JeffJSParserClass.swift` — `js_parse_class` / `js_parse_class_body`: fields → `<class_fields_init>`, static fields/blocks as
  synthetic functions run after the class is built, private names as per-class brands (`JeffJSClassFieldsCtx`).
- Types it depends on elsewhere: `JSTokenType` (`../Core/JeffJSConstants.swift`), `JeffJSLazySeed` (`../Core/JeffJSObject.swift`),
  `JeffJSOpcode` + `jeffJSGetOpcodeInfo` (`../Bytecode/JeffJSOpcodes.swift`), `jeffJS_lazyJSONValidate` and the lazy-literal
  switches (`../Builtins/JeffJSLazyPayload.swift`), `JeffJSConfig` (`../Config/JeffJSConfig.swift`).

## Invariants
- **QuickJS fidelity** (`CONTRIBUTING.md`): architectural changes to `Parser/` need an issue first; a commit touching it names the
  QuickJS function it ports (`quickjs.c:js_parse_…`); anything that touches the language gets a test (`Tests/JeffJSTests`).
- Every top-level declaration here is `nonisolated` (app compiles the engine with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`;
  `EngineThreadingRuleTests.testTopLevelDeclarationsAreNonisolated` enforces it).
- **After any Parser edit**: run `Scripts/update_bytecode_identity.sh` (rewrites `JeffJSBytecodeCache.engineSourceHash`, an FNV
  over `Parser/*.swift` + compiler/opcodes/cache sources; it names the disk-cache directory, so old blobs are never read;
  `BytecodeCacheBudgetTests.testEngineSourceHashIsCurrent` fails while stale, `--check` verifies). A change to what bytecode
  *means* also bumps `compilerVersion` (19 as of 2026-10-22, same file). Then regenerate the app's
  `precompiled_static_polyfills.jfbc` (`Scripts/precompile_polyfills.sh` in the app; it skips while `build.precompilePolyfills`
  is false — flip for the run, restore after). A stale `compilerVersion` header silently falls back to parsing source.
- **Never identify an instruction by peeking at a fixed offset back from the end of the bytecode.** Every `obj[key]` / member read /
  call is preceded by a 10-byte tagged `line_num` expression span (`emitExprSpan`: line = `0x8000_0000 | start`, col = end,
  stripped into the span table by `resolveLabels`), so `buf[len - 5]` is span payload. `lastEmittedIsGetField` once did that and
  compiled `this["dR"]^=this["qR"]` as a field store (Akamai's homedepot sensor died). Walk instruction boundaries forward from
  the target's first byte (`peekOpcodeAt` + `jeffJSGetOpcodeInfo(op).size`, +1 for a wide opcode), as `findLastGetOpcode` does.
- Expression spans are emitted *before* the opcode they describe: the parser's rewinds (assignment targets, `++`/`--`, `delete`)
  look at the op itself and must keep that layout.
- **Optional chains keep their receiver**: `a?.b?.m?.(x)` / `o.m?.()` rewrite `get_field` → `get_field2` (`get_array_el2`) so the
  call runs with `this` = the object (`parseOptionalChainLink`; i18next's `?.addUsedNamespaces?.(ns)` ran with `this` undefined).
  Same rule for `(obj.m)()` (`promoteParenthesizedMemberCallee`, `lastMemberGet*`): a parenthesised plain reference is still a
  method call; `(0, obj.m)()` is not.
- A destructuring `let`/`const` for-in/of head gets **per-iteration bindings**: `emitCloseLoopScopeVars` emits `close_loc` for every
  lexical var of the head's scope (ES §14.7.5.7 step 5); every closure used to share the last iteration (chalk/washingtonpost).
- String literals are code units, not Swift Strings: `setCookedString` keeps a leading U+FEFF (Foundation's `String(bytes:encoding:)`
  drops it) and lone surrogates go to `strUnits` (`jsStringValue()` builds the value; `LoneSurrogateConformance`).
- Nesting depth is bounded by the **native stack** (`enterRecursion`: `stackLimitForCurrentThread` + `stackSafetyMargin` 128 KB →
  `SyntaxError: stack overflow`, QuickJS's text), never by a count; long binary/`?:` chains must not recurse per operand
  (`parseBinaryExpr` precedence climbing; `ParserNestingConformance`). `maxBytecodeSize` 50 MB is a hard cap.
- Shaping of errors: a SyntaxError's `message` is JavaScriptCore's bare wording (`unexpectedTokenError` / `jscTokenDescription`:
  "Unexpected token '}'", "Unexpected end of script", "Unexpected identifier 'b'"); the location goes to `line` / `column` / stack,
  never into the message (`SyntaxErrorTextConformance`). Runtime error text quotes the span table (`../Core/JeffJSErrorText.swift`).
  Never reintroduce V8 wording — pages fingerprint error text.
- Positions are **1-based lines, UTF-8 byte columns** (`getLineCol`: `offset - lineStart + 1`; `\n`, `\r`, `\r\n` end lines) — what
  `Error.stack` frames, the unminifier's position map and console `[url:line:col]` prefixes use.
- Call sites record JSC's column (`emitCallSitePos`: the position just past the callee, resolved by `callSitePos()` when the callee
  ends — querying `getLineCol` backwards rescans and made one-line bundles quadratic).
- `getLineCol` is incremental (monotonic queries continue from the last answer; a backward query builds `lineStartIndex` once).
  Do not add per-statement work that scans from byte 0.
- Lazy compilation is a parser contract: `recordLazySeed` / `recordArrowSeed` store how to re-parse `(params) { body }` from its
  `(` (only an arrow detected at the start of its AssignmentExpression, `markArrowStart`, can be re-parsed); `finishLazyCandidate`
  drops the parsed body (`JeffJSCompiler.lazyDropAtParseEnd`) and `parseLazyFunctionTail` re-parses it on the first call
  (`compileLazy`). A function at `pifeStart` (after `(` or unary `!`) is compiled eagerly (V8's PIFE heuristic). New function
  kinds must record a seed or they silently compile eagerly.
- Large pure-JSON object/array literals (≥ `compile.lazyLiteralMinBytes` 16 384, depth ≤ 256, no `__proto__` key, not an
  assignment pattern) become one `lazy_literal` op (`tryLazyLiteral`) whose text is a constant-pool string (bytecode-cache loads
  have no script text).

## Gotchas
- `s.lastPtr` is the byte just past the previous token: it is where a function's source text ends (`recordSource`) and where
  `callSitePos` reads. `s.token.ptr` is the current token's start.
- Restricted productions and ASI run on `s.gotLF` (`return`/`throw`/`break`/`continue`/postfix `++`, `async` before an
  arrow or method name); every speculative lookahead that rewinds (`markTokenizer`/`resetTokenizer`, arrow-parameter scans,
  `tokenAfterBalancedGroup`) must save and restore `gotLF`, `templateNestLevel` and `lineNum`, as `parseForStatement` does.
- Lookahead errors are not the script's errors: `speculationDepth > 0` suppresses recording; `lastReportedErrorOffset` makes a
  re-lex of the same spot a no-op. A tokenizer error inside a template substitution still fails the parse (`failed`).
- `/` vs regexp is decided from `lastTokenType` (`slashIsDivision`); `reParseAsRegexp` re-lexes when the parser knows better.
- HTML comments (`<!--`, `-->` after a line feed) and a hashbang line are honoured only in scripts (`allowHTMLComments = !isModule`).
- `tryLazyLiteral` resumes the tokenizer by hand (`s.bufPtr`, `s.lineNum += newlines`, synthetic closing token); any new tokenizer
  state must be updated there too.
- Direct eval is `lastEvalCalleeEnd` (a callee that ends exactly where the identifier `eval` was emitted); `noteDirectEvalCall`
  changes scope resolution for the whole function (`DirectEvalConformance`).
- `JeffJSFunctionDefCompiler` is a class; an `fd` switch (`withSyntheticFd`, child functions) must restore `fd`, block envs and
  finally scopes together, or `lastAnonClosure*` / `lastMemberGet*` offsets of two functions get compared.

## Patterns to follow
- Port, don't invent: find the QuickJS function, mirror its stack shape and opcode sequence, cite it in the comment.
- New per-op debug info = a `line_num`-shaped record (expression span or call-site), never a new opcode the peepholes must learn.
- Rewind-and-patch of already-emitted bytecode only through `peekOpcodeAt` / `findLastGetOpcode` walks from a recorded start.
- A new early error: JSC wording through `syntaxErrorAt` (`tokenErrorOffset`), a `SyntaxErrorTextConformance` case, and a
  `JeffJSTestRunner` case when the construct is new.
- Tests: `Scripts/run_tests.sh release --filter <Name>` (`swift test -c release`; Debug conformance exceeds its timeout). Parser
  gates: `JeffJSTestRunner` (functions, scoping, closures, classes, generators, async…), conformance groups (`runTrueCases` names) `ParserNesting`,
  `SyntaxErrorText`, `Redeclaration`, `AssignmentPatterns`, `LogicalAssignment`, `DirectEval`, `NamedEvaluation`,
  `ClassStaticElements`, `ParameterScope`, `ParameterPatterns`, `OfIdentifier`, `TaggedTemplateNesting`, `LoneSurrogate`,
  `SuperInArrow`, `VarBindings`, `ProgramCompletion`, `LazyPayload`, `AkamaiSensor`, `LazyCompileConformance`
  (`testLazyCompile` / `testLazyReclaim`), plus `PrecompilerTests`,
  `UnminifierTests` and `BytecodeCache*Tests` (a parse change must still round-trip through `.jfbc`).

## Debug switches
- `JEFFJS_COMPILE_LAZYFUNCTIONS=0` — compile every body eagerly (A/B for lazy seeds); `JEFFJS_COMPILE_LAZYLITERALS=0`,
  `JEFFJS_COMPILE_LAZYLITERALMINBYTES=<n>` — lazy literals; `JEFFJS_LAZYDEBUG=1` — `[lazy] compile literal …` lines.
  (Every `JeffJSConfig` plist key is overridable as `JEFFJS_<KEY_UPPER_WITH_UNDERSCORES>`.)
- `JEFFJS_DEBUG_SUPPRESSERRORPRINTING=1` — no stderr diagnostic line for syntax errors (`debug.suppressErrorPrinting`).
- `JEFFJS_TEST_UNMINIFY_EVAL=1` — every global/module script is unminified before compiling (tests the tokenizer round trip).
- `JEFFJS_CACHE_BYTECODEENABLED=0` — run conformance without the bytecode cache (a cache hit lost expression spans once).
- `jeffjs-cli --unminify <file> --at <line>:<col>`, `--bc-hash-code <files>` — tokenizer-based formatting / bytecode hash
  without positions (equal for sources differing only in whitespace/comments).

## Cross-area links
- [Bytecode](../Bytecode/CLAUDE.md) — `JeffJSFunctionDefCompiler`, label resolution, peepholes (`tail_call` fusion), lazy stubs,
  the `.jfbc` cache and `engineSourceHash` / `compilerVersion`.
- [Core](../Core/CLAUDE.md) — `JSTokenType`, `JeffJSLazySeed`, `JeffJSErrorText` (runtime error wording), strict tail-call frame
  elision in `JeffJSContext.isTailCall`.
- [Utils](../Utils/CLAUDE.md) — the unminifier drives `JeffJSParseState.nextToken` and must never add a newline where ASI /
  restricted productions change meaning.
- [Builtins](../Builtins/CLAUDE.md) — `JeffJSLazyPayload` (lazy literal validator/builder), `JeffJSBuiltinJSON` (JSON mode).
- [React Natively app](../../../../../CLAUDE.md) — polyfill `.jfbc` regeneration, `JS/` glue that evals per-call texts.

## Deep docs
- [`CONTRIBUTING.md`](../../../CONTRIBUTING.md) — fidelity rules, what needs an issue, commit message convention.
- [`README.md` § "Architecture"](../../../README.md) — pipeline overview (note: it still says "→ AST"; the parser header is right).
- [`docs/PERFORMANCE_PLAN.md`](../../../docs/PERFORMANCE_PLAN.md) — lazy JSON parse, `nip_catch` / async primary fixes.
- App [`CLAUDE.md` § "Working with the JeffJS submodule"](../../../../../CLAUDE.md) — dated parser fix history (2026-10-22 entries).

## Suspected dead code
- `jeffJS_canStartExpr`, `jeffJS_isKeyword` (JeffJSTokenizer.swift) — confidence: high — checked:
  `grep -rn 'jeffJS_canStartExpr\|jeffJS_isKeyword' Sources Tests` → definitions only.
- `JeffJSFunctionDef` placeholder class + `JeffJSParseState.curFunc` (JeffJSTokenizer.swift) — confidence: medium — checked:
  `grep -rn 'curFunc = \|JeffJSFunctionDef(' Sources/JeffJS/Parser Tests` → never assigned; the only read (`curFunc?.isStrict`)
  is always nil.

## Suspected stale
- "Strict tail-call elision + JSC call-site columns" (app CLAUDE.md, engine `fix/akamai-sensor`): the columns are here
  (`emitCallSitePos`), but tail-call elision is not parser code — the `call + return → tail_call` fusion lives in
  `../Bytecode/JeffJSCompiler.swift` and the frame elision in `JeffJSContext.isTailCall` (searched `tail` in `Parser/*.swift` → 0).
- README "Tokenizer + recursive-descent parser → AST": contradicted by `JeffJSParser.swift`'s header ("emits bytecode directly
  (no AST)") and by the code (every `parse*` calls `emitOp`).
