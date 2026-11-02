# JeffJS Builtins — Claude neuron

> Area: `Sources/JeffJS/Builtins/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The ECMAScript standard library of JeffJS: one file per QuickJS `js_*` builtin group (Object, Function, Array, String,
Number/Boolean, Symbol, Date, Math, JSON, RegExp, Map/Set/Weak*, Promise, Proxy/Reflect, TypedArray/ArrayBuffer/DataView,
Atomics, Iterator/Generator, WeakRef/FinalizationRegistry, Error), a Foundation-backed `Intl`, lazy JSON payloads and the
pending-promise trace. `JeffJSContext.init(addIntrinsics:)` (`../Core/JeffJSContext.swift`, ~line 735) creates the
prototypes in phase 1 (`addIntrinsicBaseObjects … addIntrinsicEval`), then phase 2 calls each file's `addIntrinsic(ctx:)`
in QuickJS's order (Object → Function → Array → Number → Boolean → String → Iterator → Map → JSON → Promise → Global …),
`js_addIntrinsicAtomics`, `js_initWeakRefAndFinalizationRegistry`, and last the three whole-surface passes
`addIntrinsicWellKnownMembers` → `addIntrinsicToStringTags` → `addIntrinsicNonEnumerableBuiltins`. Host builtins the web
needs (`URL`, `TextDecoder`, `structuredClone`, `performance`) are NOT here: see [StdLib](../StdLib/CLAUDE.md) /
[DOM](../DOM/CLAUDE.md). **Every builtin is shaped like JavaScriptCore's**: pages fingerprint names, order, attributes,
error texts and number formatting (Google's /search challenge, Akamai's sensor, core-js feature tests).

## Key files
- `JeffJSBuiltinObject.swift` — Object statics/prototype, `setPrototypeOf` (+ `JeffJSProxyReflection.swift`: a Proxy's
  [[GetOwnProperty]]/[[DefineOwnProperty]]/[[Set]]-with-receiver for `Object.getOwnPropertyDescriptor`, `defineProperty`,
  `Reflect.set(…, receiver)` — they used to read the proxy object's own empty shape).
- `JeffJSBuiltinFunction.swift` — Function.prototype (`call/apply/bind/toString`, `[Symbol.hasInstance]`, JSC's legacy
  `caller`/`arguments` accessors), `buildArgList` = CreateListFromArrayLike with ordinary [[Get]]s (typed arrays, accessor
  `length`, inherited elements count), `nativeCodeName`.
- `JeffJSBuiltinArray.swift` — Array; dense fast paths gated on `jeffJS_isFastArray` / `interp.fastArrayBuiltins`.
- `JeffJSBuiltinString.swift`, `JeffJSBuiltinNumber.swift` (Number + Boolean + the global parse functions;
  `numberToStringRadix` = JSC's `toStringWithRadixInternal` digits, exact binary arithmetic), `JeffJSBuiltinSymbol.swift`
  (global registry for `Symbol.for`), `JeffJSBuiltinGlobal.swift` (parseInt/URI functions, `undefined/NaN/Infinity/globalThis`).
- `JeffJSBuiltinDate.swift` — Date; `Date.prototype` is an ordinary object (no [[DateValue]]), methods in JSC's
  `DatePrototype.cpp` order incl. Annex B `getYear`/`setYear`, `toGMTString === toUTCString`; `toString` ends with the
  zone name (`timeZoneNameSuffix`).
- `JeffJSBuiltinMath.swift`, `JeffJSBuiltinJSON.swift` (+ `JeffJSBuiltinJSONFast.swift`: replacer-free `stringify` on
  the code-unit buffer, hands the call back (`nil`) for gap/indent, Proxy, typed arrays, host-lazy objects).
- `JeffJSBuiltinRegExp.swift` — RegExp object + Symbol methods + string iterator; the matcher is in `../RegExp/`.
  Input code units come from `rt.regexCaches.codeUnits(of:)` (see Gotchas).
- `JeffJSBuiltinMap.swift` — Map/Set/WeakMap/WeakSet over `JeffJSMapState` hash tables, `groupBy`.
- `JeffJSBuiltinPromise.swift` — Promise + reaction records; jobs go to `rt.jobQueue` / `executePendingJobs()`
  (`../Core/JeffJSRuntime.swift`). `JeffJSPromiseTrace.swift` — `JEFFJS_PROMISE_TRACE=1` pending-promise trace.
- `JeffJSBuiltinProxy.swift` — Proxy (13 traps, invariants, revocable) + Reflect.
- `JeffJSBuiltinTypedArray.swift` — ArrayBuffer/SharedArrayBuffer/%TypedArray%/12 views/DataView; `JeffJSBuiltinAtomics.swift`.
- `JeffJSBuiltinIterator.swift` — Iterator helpers (ES2025), Generator, AsyncGenerator prototypes.
- `JeffJSBuiltinWeakRef.swift` — WeakRef, FinalizationRegistry + its cleanup job.
- `JeffJSBuiltinError.swift` — QuickJS Error port; **not wired** (see Suspected dead code). Live error construction,
  `Error.captureStackTrace`, own `line`/`column`/`sourceURL`/`stack` and JSC-style frames (`name@url:line:col`,
  `name@[native code]`) are in `../Core/JeffJSContext.swift` (`addErrorConstructors`, ~line 4554 / 6087) and the
  message texts in `../Core/JeffJSErrorText.swift`.
- `JeffJSBuiltinIntrinsicMembers.swift` — spec members no routine installed (`get [Symbol.species]`, `Array.prototype
  [@@unscopables]`, `Symbol.prototype[@@toPrimitive]`, `length` of String/Array.prototype), each only if absent.
- `JeffJSBuiltinToStringTag.swift` — `@@toStringTag` on every prototype reachable through `ctx.classProto`, and
  `addIntrinsicNonEnumerableBuiltins` (every builtin method registered through `setPropertyStr` was enumerable:
  `Object.keys(Function.prototype)` listed call/apply/bind).
- `JeffJSIntlBridge.swift` — ECMA-402 on Foundation (NumberFormat, DateTimeFormat, Collator, PluralRules,
  RelativeTimeFormat, ListFormat, DisplayNames, Locale, Segmenter); Swift does the work, one eval'd JS shim does the
  constructor/prototype plumbing. Instantiated by `../DOM/JeffJSWebAPIsBridge.swift` (`JeffJSIntlBridge()`), not by
  context init. `@JeffJSHostActor` (allowed: it is a host bridge).
- `JeffJSLazyPayload.swift` — lazy `JSON.parse` results (≥ `json.lazyThresholdBytes`, 16 KB) and lazy pure-data
  literals (≥ `compile.lazyLiteralMinBytes`, 16 KB): validated once (`jeffJS_lazyJSONValidate`, no allocation, skip
  table for big containers), returned as a stub on the realm's lazy sentinel shape with `lazyPayloadBit`; any own-property
  operation materializes its top level (`jeffJS_lazyMaterialize`); `JeffJSRuntime.evictLazyPayloads` on memory pressure.

## Invariants
- **JSC shape, not V8 and not bare QuickJS.** String/Number/Boolean constructors inherit `Function.prototype` with
  `name`/`length` (a null proto broke every core-js bundle: `String(String)` threw); Function.prototype has
  `length/name/constructor/[Symbol.hasInstance]/arguments/caller`; `Date.prototype` members in JSC order; builtins are
  non-enumerable; `toString(radix)` prints JSC's digits; Intl dates use ASCII spaces (`webKitSpaces` folds ICU's U+202F /
  U+2009). Conformance groups guarding this: `BrowserFingerprint`, `AkamaiSensor`, `HomedepotAkamai`,
  `InterfaceShadowIC`, `ProxyReflection` (`../../../Tests/JeffJSTests/`). Never reintroduce V8 wording anywhere.
- Error texts: "undefined is not an object (evaluating '…')", "Can't find variable: x", `RangeError: Maximum call stack
  size exceeded.` (with the period — `JeffJSProxyReflection.swift`, `../Bytecode/JeffJSInterpreter.swift`), via
  `../Core/JeffJSErrorText.swift`. Don't hand-write a runtime error message; add it there.
- Natives, methods and arrows have no [[Construct]] and no `prototype`; `Symbol`/`BigInt` constructors set
  `isConstructor = false` (`../Core/JeffJSContext.swift`). A new native must keep that.
- Every top-level declaration here is `nonisolated` (`EngineThreadingRuleTests.testTopLevelDeclarationsAreNonisolated`,
  `testEngineClassesAreNonisolated`); `JeffJSIntlBridge` is the one explicit `@JeffJSHostActor` class (listed as a host
  bridge in that test). An unannotated declaration silently hops to main in the app build.
- `definePropertyValue` **dups** its value (not QuickJS's consume): free what you created
  (`JEFFJS_ERROR_KEEPMESSAGEREF=1` = the old error-message leak, see app root doc).
- A function object's payload holds no refcount on its bytecode: new code making a `.bytecodeFunc` payload must bump
  `liveClosures` (freeObject drops it) — app root doc "Memory census".
- A per-string identity cache must revalidate by length: `s += c` grows a string in place (`appendInPlace`), so
  `rt.regexCaches.codeUnits` (keyed by string identity) checks the length on every hit.
- Reads of Float32/Float64Array and DataView go through `JeffJSValue.newFloat64Purified` (JSC's purifyNaN): a NaN payload
  read raw became a tagged value and crashed. Any new float read path must too.
- Proxy: symbol keys reach the traps, `getPrototypeOf`/`instanceof`/`hasOwnProperty` honour the proxy, and (since
  `ProxyReflectionConformance`) for-in over a proxy also visits its prototype's enumerable keys (§14.7.5.9).
- Math methods take Numbers only: ToNumber(BigInt) is a TypeError checked at the call boundary (the per-argument
  conversion returns a Double and cannot report it).
- Promise: an async host callback that settles a promise must run a microtask checkpoint (`rt.executePendingJobs()` at
  `callDepth == 0`) — the dynamic-import bridge did not and `await import(x)` hung.
- Lazy payloads: malformed input, a `__proto__` key or a reviver take the eager parser so every error is unchanged; a
  stub must never be cached by an inline cache (sentinel shape).

## Gotchas
- Pages fingerprint `message + ":" + stack` (Google /search) and `Object.getOwnPropertyNames(Date.prototype)`;
  an extra own property, a different order or a V8 message = a 429 / sensor rejection. Diff JSC vs JeffJS vs WebKit
  before "fixing" a text.
- `Date.prototype.getTime.call({})` must throw (it returned NaN); every setter runs ToNumber on its arguments first.
- `Function.prototype.apply` ignored typed arrays and accessor lengths until `buildArgList` used ordinary [[Get]]s.
- A string literal's leading U+FEFF was dropped by the parser once (identity hash updated); `JSON.parse` of such text
  differs from `eval` — check the parser, not JSON, when they disagree.
- `JeffJSBuiltinJSONFast` must decline (`nil`) before writing a byte — a partial write then a generic retry would double
  `toJSON` side effects.
- `JeffJSBuiltinError.buildBacktrace`'s doc comment describes V8's `at fn (file:l:c)` frames; the shipped `stack` is the
  JSC-style one from `../Core/JeffJSContext.swift`. Don't copy that comment's format.
- Twin families (`Twins/`) run instead of library bytecode: a builtin change that alters what `Object.keys`,
  `Object.prototype.toString`, `.call`, `Map`/`Set` answer must keep `NativeTwinsConformance` (twin == bytecode) green.
- Symbol registry: `JeffJSBuiltinSymbol.swift` documents it as single-threaded; the runtime is one-thread-at-a-time
  (app root doc "JeffJS runtime threading rule") — never touch it from a second thread.

## Patterns to follow
- Add a member in the file that owns the builtin, registered inside its `addIntrinsic(ctx:)`; attributes per ES
  (`JeffJSBuiltinIntrinsicMembers.swift` shows the idiom: define only when absent, exact flags). The non-enumerable
  sweep runs last, so `setPropertyStr` registration is fine for methods; accessors and spec-fixed attributes are explicit.
- Port from QuickJS first (keep the `js_*` reference in the header), then shape to JSC where pages can see the
  difference (names, order, texts, number formatting) and add a conformance case in `Tests/JeffJSTests/JeffJSTestRunner.swift`
  (`("GroupName", { $0.testX() })` list ~line 220–400).
- A fast path (JSON fast, array fast paths, lazy payloads) is an *overlay* that hands back to the generic path on anything
  it does not model, never a second semantics.
- Error messages: `../Core/JeffJSErrorText.swift`; stacks: `../Core/JeffJSContext.swift` — do not grow `JeffJSBuiltinError.swift`.

## Debug switches
- `JEFFJS_PROMISE_TRACE=1` — `JeffJSPromiseTrace` records every pending promise something waits on (+ JS stack of the
  first wait, natives its executor called); `report(olderThan:)` lists them. The app's Settings "Debug: trace stuck
  promises" sets it; the page report's "--- pending promises" section prints it.
- `JEFFJS_NATIVETWINS_ENABLED=0` / `JEFFJS_NATIVETWINS_DEBUG=1` — see [Twins](Twins/CLAUDE.md).
- `JEFFJS_JSON_LAZY=0`, `JEFFJS_COMPILE_LAZYLITERALS=0` — eager JSON.parse / literals (`json.lazy`, `json.lazyThresholdBytes`,
  `json.lazyEvictOnIdle`, `compile.lazyLiteralMinBytes` in `../Config/JeffJSConfig.swift`; any key = `JEFFJS_<KEY_UPPER>`).
- `JEFFJS_ERROR_KEEPMESSAGEREF=1` — old error-message leak (A/B).
- `JEFFJS_CACHE_BYTECODEENABLED=0` — run conformance with the bytecode cache off (a cache hit used to lose the expression
  spans — "undefined is not an object" without "(evaluating …)" — fixed at `compilerVersion` 17; the switch stays as a guard).

## Cross-area links
- [Core](../Core/CLAUDE.md) — `JeffJSContext` intrinsic init order, error constructors/stack, `JeffJSErrorText`,
  `newFloat64Purified`, runtime job queue, GC/threading rule.
- [Bytecode](../Bytecode/CLAUDE.md) — interpreter fast paths (`fastArrayBuiltins`, twin hook `allowsFastPath`), stack-overflow texts.
- [RegExp](../RegExp/CLAUDE.md) — the matcher `JeffJSBuiltinRegExp` drives.
- [StdLib](../StdLib/CLAUDE.md) — `URL`/`searchParams` (re-serialised only after mutation), `performance.now` (whole ms),
  `structuredClone`/`TextDecoder` (gaps the app's `WebPlatformGlue` works around).
- [DOM](../DOM/CLAUDE.md) — `JeffJSWebAPIsBridge` (installs `JeffJSIntlBridge`), `__jeffjsMarkNative` (JeffJSDOMBridge).
- [Twins](Twins/CLAUDE.md) — native twins of npm functions.
- [React Natively app](../../../../../CLAUDE.md) — Safari surface pass, conformance switches, fingerprint history.

## Deep docs
- [`docs/EXECUTION_ARCHITECTURE_RETHINK.md` § 8.3](../../../docs/EXECUTION_ARCHITECTURE_RETHINK.md) — why twins, measured.
- [`README.md` § Architecture / § Configuration](../../../README.md) — module map, config keys.
- [App `CLAUDE.md` § "Working with the JeffJS submodule"](../../../../../CLAUDE.md) — per-fix history of builtin shaping
  (BrowserFingerprint d6c6743, AkamaiSensor f1557ec/07ba7fc, URL 5827299, NaN purification, apply fix).

## Suspected dead code
- `JeffJSBuiltinError` (`JeffJSBuiltinError.swift`, 727 lines) — confidence: high — checked:
  `grep -rn "JeffJSBuiltinError\." Sources Tests` → only the comment in `Core/JeffJSContext.swift:766` ("built a second,
  unreachable set … never called now"); `buildBacktrace(` has no caller outside the file. Phase-1 `addErrorConstructors` is live.
- None else found (searched: external callers of every `addIntrinsic`/`js_*` entry listed above — all called from `Core/JeffJSContext.swift`).

## Suspected stale
- App root doc: "open: for-in over a proxy skips its prototype's enumerable members" — `ProxyReflectionConformance.swift`
  line 47 tests "for-in over a proxy visits its prototype's enumerable keys" as passing; looks fixed.
- "`performance.now()` is whole ms", "`Error.captureStackTrace`", "errors have own line/column(/sourceURL)/stack" — true
  but implemented in `Core/`/`StdLib/`, not in this folder (`grep -rn captureStackTrace Sources` → `Core/JeffJSContext.swift:4554`).
