# JeffJS Native twins — Claude neuron

> Area: `Sources/JeffJS/Builtins/Twins/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
Library-aware substitution (JeffJS issue #3): a known npm function shipped by a page (deepmerge, Babel's
`_objectSpread2`, Apollo's `cloneDeep`, `@wry/equality`, Home Depot's `_client` strip, React's / fbjs's `shallowEqual`)
is recognised by its **name-free bytecode** (`JeffJSBytecodeSerializer.nameFreeBytes`, `../../Bytecode/JeffJSBytecodeCache.swift`)
and runs as Swift instead of the interpreter. Input: a compiled `JeffJSFunctionBytecode` (hashed on compile); output: the
same value the bytecode would produce, or a *decline* that lets the bytecode run. The interpreter's `createClosure` /
`callInternal` payload path asks `JeffJSNativeTwins.allowsFastPath` so an entry body never gets `fbFast` and every call
reaches `JeffJSNativeTwins.call` first (`../../Bytecode/JeffJSInterpreter.swift` ~line 1560). Measured on Home Depot:
~85 % of landing-page script time was deepmerge; watch-sim longest task 20 s → 2.9–5.2 s.

## Key files
- `JeffJSNativeTwins.swift` — `Family` (name, `roles` (role 0 = entry), `values`, reference `source`, `alternates` =
  other builds of the same library, `foreign` = cells holding another family's member, `needs`, `accepts`, `run`,
  `runLeaf` for one-function families), the per-context `Table` (hash → member, ≤ 253 members: `twinTag` is one byte),
  `Resolved` / `LeafCells` (cells checked for one call), `JeffJSTwinDecline`, `JeffJSNativeTwinStats` (`rt.twinStats`:
  hits / declines / recognised / `servedByFamily`), `families` list, `tableSource` (what the CLI prints).
- `JeffJSTwinTableData.swift` — **generated** (`jeffjs-cli --twin-table` → `JeffJSEnvironment.nativeTwinTableSource()`):
  the reference texts' members as this compiler compiles them. Cell codes: role index, `1000 + value index`,
  `2000 + 100·family + role` (another family's member), `-1` other.
- `JeffJSTwinIntrinsics.swift` — `Needs` option set (`.deepmerge .spread .clone .equal .strip .shallow`, each listing the
  builtins that family reaches) and `check(ctx, needs)`: every (holder, key) remembered by shape + slot, one value compare
  on a later check; holders captured before any page script, held **strongly** until `JeffJSContext.free`.
- `JeffJSTwinReader.swift` — the only reads a twin may do: `tag` (Object.prototype.toString's answer), `plainObject`,
  `plainArray` (dense), `plainChain`, `chainData`, `setCreatesOwn`, `ownKeys`, `ownData(WithFlags)`, `define`; each throws
  `JeffJSTwinDecline` on a proxy, accessor, host object or lazily built object before anything changed.
- `JeffJSTwinDeepmerge.swift` — deepmerge 4.x as homedepot.com ships it (5 copies, one structure); default options only.
- `JeffJSTwinObjectSpread.swift` — Babel `_objectSpread2` (+ `ownKeys`/`_defineProperty`/`_toPropertyKey`/`_toPrimitive`),
  two Babel builds via `alternates`; ~1 400 module copies on homedepot.com, 20 % of its home page JS.
- `JeffJSTwinCloneDeep.swift` — Apollo `cloneDeep`; copies are fresh, so a decline leaves nothing behind.
- `JeffJSTwinEquality.swift` — `@wry/equality` `equal` for plain objects / dense arrays / primitives; Map, Set, Error,
  Date, RegExp, function or wrapper anywhere declines; `previousComparisons` is left empty.
- `JeffJSTwinClientStrip.swift` — Home Depot's data-model `_client` strip; its Babel-spread build names the spread helper
  as `foreign: ["Lt": ("objectSpread2", 0)]`; `typeof null == "object"` → the predicate throws → decline.
- `JeffJSTwinShallowEqual.swift` — React 16/17 (A), 18 / 19 cjs (B), Meta's www build (C) and fbjs's module
  (`fbjsFamily`: `is` a member, `hasOwnProperty` a bound `call`).

## Invariants
- **A twin may only do what the bytecode would do without running page code.** Any getter, setter, proxy, patched
  builtin or reassigned closure cell on the way = decline *before* the first observable write; the bytecode then runs.
  A declined call costs the work so far, never a different result.
- Per call: every closure cell the family reads must still hold the family's own functions (a page can reassign them),
  and the intrinsics its `Needs` lists must be the context's own (`JeffJSTwinIntrinsics.check`) — also *absence*
  checks (e.g. no own `Object.hasOwnProperty` shadowing the prototype's).
- **Never hold engine objects in `weak` Swift references** (here or anywhere): a weak ref gives the object a side table
  and every retain/release of `Object.prototype`, `Array.prototype`, … in the whole engine takes Swift's slow path
  (add28e8 did it; build 156). Holders are strong, released in `JeffJSContext.free`.
- The table is computed from the reference sources *by this compiler* on first use (lazy + eager, sloppy + strict), so a
  compiler change can never leave stale hashes behind — but the checked-in `JeffJSTwinTableData.swift` can go stale:
  `NativeTwinsConformance` fails until it is regenerated.
- Twin == bytecode is proven differentially: each conformance group runs the same body with `rt.nativeTwins` on and off
  and asserts equal output and `served > 50` (`Tests/JeffJSTests/NativeTwinsConformance.swift`: groups `NativeTwins`,
  `NativeTwins2`, `NativeTwins3`, `testNativeTwinsReact`), including patched `Object.keys`/`Map`/`Set`/`defineProperty`
  cases that must decline.
- Twins answer for ordinary objects with data properties and dense arrays only; keys listed from those only.

## Gotchas
- Minified names differ per build (`Lde`/`VY`, `Qt`/`lo`/…): a twin that stops matching after a site deploy usually
  needs a new `alternates` entry, not a new family.
- `deepmerge` with a third (options) argument runs the bytecode — only the default-options call sites are served.
- An entry body never takes the interpreter fast path (`allowsFastPath` false), so a *mis*-recognised hot function
  would be slower, not wrong: check `JEFFJS_NATIVETWINS_DEBUG=1` output for unexpected family names.
- `JeffJSTwinTableData.swift` is also stale after Parser/Bytecode changes that alter emitted bytecode (new opcodes,
  constant folding): regenerate it with the bytecode identity (`Scripts/update_bytecode_identity.sh`).
- The table holds < 253 members; past that a member is skipped with one `[jeffjs:twins] table full` stderr line (always printed).

## Patterns to follow
Adding a twin: (1) one file `JeffJSTwin<Name>.swift` with the library's reference text exactly as a site ships it and a
`static let family = JeffJSNativeTwins.Family(…)` (`accepts` = cheap argument test, `run`/`runLeaf` reading only through
`JeffJSTwinReader`, throwing `JeffJSTwinDecline(reason:)`); (2) a line in `JeffJSNativeTwins.families`; (3) a `Needs`
bit + its `expect`/`absent` checks in `JeffJSTwinIntrinsics.check`; (4) regenerate the table:
`swift run -c release jeffjs-cli --twin-table > Sources/JeffJS/Builtins/Twins/JeffJSTwinTableData.swift`; (5) an on/off
differential group in `NativeTwinsConformance.swift` with patched-builtin decline cases. Skip libraries that already
memoise (graphql-tag caches each query's parse — looked at and skipped). A member shared between libraries goes through
`Family.foreign`, not a copy of its text.

## Debug switches
- `JEFFJS_NATIVETWINS_ENABLED=0` — no lookup (`nativeTwins.enabled`, `../../Config/JeffJSConfig.swift`); per runtime `rt.nativeTwins` (tests).
- `JEFFJS_NATIVETWINS_DEBUG=1` — stderr: table size, recognised bodies, declined calls with the reason, served counts per family.
- `rt.twinStats` — hits / declines / recognised / `servedByFamily` for a probe.

## Cross-area links
- [Builtins](../CLAUDE.md) — the intrinsics the twins check against; a builtin shape change must keep twin == bytecode.
- [Bytecode](../../Bytecode/CLAUDE.md) — `nameFreeBytes`, `allowsFastPath` hook, `fbFast` closures, bytecode identity.
- [Core](../../Core/CLAUDE.md) — `JeffJSContext.free` (holder release), object/shape model the reader relies on.
- [Environment](../../Environment/CLAUDE.md) — `nativeTwinTableSource()` behind `jeffjs-cli --twin-table`.
- [React Natively app](../../../../../../CLAUDE.md) — "Native twins" history under "Working with the JeffJS submodule".

## Deep docs
- [`docs/EXECUTION_ARCHITECTURE_RETHINK.md` § 8.3 / § 5](../../../../docs/EXECUTION_ARCHITECTURE_RETHINK.md) — the case for library-aware substitution.
- [App `docs/NATIVE_REACT_SCOPING.md`](../../../../../../docs/NATIVE_REACT_SCOPING.md) — scoping of twins around React (row C: deepmerge, lodash, @wry/equality, graphql-tag, Apollo).

## Suspected dead code
- None found (searched: `grep -rn "static let family\|fbjsFamily" Twins` → all 7 families listed in `JeffJSNativeTwins.families`;
  every `JeffJSTwinReader` method and `Needs` bit is referenced from a family file).

## Suspected stale
- App root doc says `JEFFJS_NATIVETWINS_DEBUG=1` "logs recognitions/declines" and "Debug prints served counts per
  family" — verified (`JeffJSConfig.nativeTwinsDebug`, `servedByFamily`). Nothing else unverified.
