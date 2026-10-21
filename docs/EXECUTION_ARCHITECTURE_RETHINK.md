# Rethinking JeffJS execution: scripts as classes, closure trees, and what would actually be faster

2026-10-20. Design exploration, no engine code changed. Read against `jbachand/JeffJS` `perf/round5-beat-quickjs` (b6c14de),
the perf docket of 2026-10-19 (`README.md` in the project files), issue #1 and the native-compiler write-up
(`jeffjs-compiler/README.md`). Measurements marked *measured* were taken today on Jeff's M1 Max under load average 12,
so absolute milliseconds are rough; ratios between variants of one run are solid. The microbenchmark source is
`bench/arch/dispatch_bench.swift` on the local branch `design/execution-rethink` of `~/www/jeffjs` (not pushed).

## 1. The question

Jeff's idea: instead of a bytecode VM, make a script "just a class with dynamic method mapping that maps directly to a
Swift method, and the script can add its own methods, so adding variables and running functions instantly becomes
native."

Taken apart, that is three separable mechanisms, each with a known name in the interpreter literature:

| piece of the idea | what it means mechanically | known as |
|---|---|---|
| "maps directly to a Swift method" | every JS function (and every expression inside it) becomes a Swift closure or object that executes it, instead of bytes read by a dispatch loop | closure compilation (Feeley & Lapalme 1987), AST interpreters with self-specialising nodes (Truffle) |
| "class with a dynamic method map … script adds its own methods" | the global scope / each object is a Swift table from name to callable; defining `function f` inserts a Swift callable; a call looks it up and invokes it | shape-based objects with direct slots, inline caches, "property cells" for globals |
| "instantly and automatically becomes native" | the function defined by the script runs as native Swift | only true with code generation (a JIT or AOT compiler). Without it, the Swift closure that implements `f` still walks `f`'s body node by node; what became native is the glue between nodes, not the body |

So the honest version of the idea is: **replace the bytecode interpreter with a closure-tree interpreter, and replace
scope/object lookup with Swift tables.** The question is whether that is faster than what JeffJS has, and whether JS
semantics let it be.

## 2. Where JeffJS's time goes today (measured)

`sample` of the Oct 7 release CLI running `bench/realworld.js` (38 browser-shaped kernels, 13.6 s CPU; 9 039 main-thread
samples bucketed by the symbol at the top of the stack):

| bucket | share | what is in it |
|---|---:|---|
| Swift retain/release (incl. `dupValueHeap`/`freeValueHeap`, weak loads, uniqueness checks) | **32 %** | object/closure/array lifecycle, payload enum copies, `[JeffJSValue]` arrays |
| malloc/free, `swift_allocObject`, array storage deinit, memset | **16 %** | the same lifecycle, plus Swift arrays and strings |
| interpreter + call self (`callInternal`, the two fast traces, `callFunction`, native call entry) | **23 %** | opcode decode, the `switch`, stack traffic, call setup |
| property get/set/shape lookup self | 6 % | |
| `JeffJSObjectPayload` copies/destroys | 3 % | the enum-copy problem the plan already names |
| everything else (builtins, regex VM, strings, typed arrays, iterators, JSON) | 20 % | e.g. `typedArrayInfo(forClassID:)` alone is 1.8 % |

Two facts frame everything below. First, the micro kernels that are pure dispatch (int loops, float loops) already run at
1.0–1.3x C QuickJS (perf plan, round 5): **the switch loop is at parity with C**. Second, the 3.8x gap on realworld is in
the rows above the interpreter line: object lifecycle under Swift ARC and allocation (48 %), and builtins. Replacing the
dispatch mechanism can only touch the 23 % row, and even making that row free would be a 1.3x ceiling.

## 3. The dispatch mechanisms, head to head (measured)

One tiny language, the same NaN-boxed 8-byte values JeffJS uses, the same two programs (`fib(27)`: 832 039 calls, and a
20 M-iteration arithmetic loop), six executors written as well as I could in Swift at `-O -wmo`:

| executor | ns per fib call | ns per loop iteration |
|---|---:|---:|
| A. bytecode + `switch` loop (what JeffJS does) | 21–23 | 29.0–29.5 |
| B. closure tree, call through a dynamic name→closure map (Jeff's idea, literal) | 46–54 | – |
| B2. closure tree, call target resolved once (cached slot) | 12.7–14.1 | 28.6–30.2 |
| B3. closure tree with JS control flow: `throws` for exceptions, a `Flow` enum for `return`/`break` | 52 | 39.8 |
| C. class-node AST (virtual `exec`), with a Truffle-style specialised int-add node | 12.7–13.3 | 28.2–29.3 |
| D. threaded code (array of handler closures, no switch) | 56–58 | 87–91 |
| E. plain Swift (the floor) | 1.7–1.8 | 8.3–8.8 |

What this says:

- **On straight-line code a closure tree is exactly as fast as the switch loop** (29 ns/iter both). The closure call per
  node costs what the decode + switch costs. No gain to be had from the mechanism itself.
- **The closure tree's win on fib (1.6x) is only because its frames are trivial** (one pointer bump, no frame object). That is
  a statement about call *setup*, not about dispatch, and the bytecode VM gets the same by making its call setup trivial
  (issue #1 step 2, lazy frames). JeffJS's real call is ~460 instructions against this toy's ~60 because of frame
  objects, argument arrays, closure var-refs and realm checks, none of which a closure tree removes.
- **The literal "dynamic method map" is 4x slower than a resolved slot** (B vs B2): a string-keyed dictionary lookup per
  call. JeffJS's atoms + shapes + inline caches already *are* the resolved-slot version; a Swift `[String: …]` would be a
  regression. "Adding a variable" today is a shape transition into a slot (perf/watch-cpu `fastPropertyAdd`), i.e. already
  the fast form of this idea.
- **Real JS control flow costs the closure tree 2–2.5x** (B3 vs B2, and B3 is 1.4–2.2x *slower than the bytecode VM*). A
  bytecode VM pays one `isException` test per op and `return`/`break` are jumps. A closure tree has to thread completions
  through every node: Swift `throws` on every closure and an enum result for statements. That is the semantic tax before
  generators, `finally`, labelled breaks or `with` are considered.
- **Threaded code loses in Swift** (D): no computed goto and no guaranteed tail calls, so a handler table is a loop around
  an indirect call with an `inout` state struct, 2–3x slower than the switch. The compiler write-up's "C dispatch loop"
  option was right that this needs C.
- Node specialisation (C's `NAddInt`) gave nothing here because the switch VM's `add` already has the int fast path first.
  In JeffJS the equivalent is quickening and the fast traces, which exist.

## 4. Where JS semantics fight a closure-tree / method-map engine

These are not implementation details; each one is a place where the design has to give back more than it gained.

1. **Generators and async functions.** A closure tree keeps the execution state on the Swift stack. `yield` has to unwind it
   and later rebuild it: either a CPS transform of every function that might yield (a second compiler), a thread per
   generator (memory; the watch), or a bytecode fallback for them (two engines to keep in agreement). Generators are the
   docket's worst row (9.9x) *because* today's engine copies the frame out and back per yield; the fix in a bytecode VM is
   to keep the frame alive, a contained change. In a closure tree it is an architecture.
2. **Exceptions and completions**: measured above (B3). Every expression node becomes `throws`, every statement returns a
   completion record. Bytecode checks one tag bit.
3. **Scope semantics.** Sloppy globals, `var` hoisting, TDZ for `let`/`const`, `with`, direct `eval`, `arguments` aliasing,
   `delete` on globals and the global object being `window` with a prototype chain (WindowProperties, `EventTarget`)
   that Safari-surface parity requires. A "class with a method map" is a model of one flat scope; JS needs the scope chain
   plus the global object's own property machinery, which is why engines end up with exactly what JeffJS has: atoms,
   shapes, var-refs, ICs. Any Swift-dictionary shortcut is both slower (B) and wrong for the fingerprinted surface
   (`Object.getOwnPropertyNames(window)` order, descriptors, `[[Set]]` through accessors).
4. **Memory, the watch constraint.** *Measured*: a closure node costs ~54 B of resident memory (3 closures for one `a + b`),
   against ~2–3 B per bytecode op. Home Depot's 3 MB landing module is a 5.7 MB `.jfbc` plus 1.3 MB of bodies in the
   cache today; as a closure tree it would be on the order of 100 MB of Swift heap objects, with the AST (or source) kept
   around to rebuild lazily-dropped functions. The watch stops JS at ~210 MB. The bytecode VM's lazy compile, idle reclaim
   and memory-pressure drop (`JeffJSLazyReclaim`) exist because even bytecode was too much there.
5. **Startup and the bytecode cache.** A closure tree cannot be serialised. Today a warm page maps `.jfbc` from disk and
   never parses the big bundles; the precompiler compiles the 3 MB module off the JS thread. A closure-tree engine would
   re-parse and rebuild every function on every load, on every launch, paying the parse cost the cache was built to hide
   (the plan's "parsing was quadratic" round and the `v5` cache design are both about this).
6. **Swift ARC, multiplied.** The engine's largest cost is Swift reference counting on the few hundred thousand engine
   objects a page creates. A closure tree is a Swift heap object per AST node: tens of millions of refcounted objects per
   page, each closure context holding its children. The microbenchmark avoided ARC traffic only because its trees are
   immutable `let` captures; the moment nodes rewrite themselves (self-specialisation) or are stored in arrays, Swift
   inserts retains on the hot path, the same fight the perf plan has been having for ten rounds.
7. **Error text and stacks.** `name@url:line:col`, the exact TypeError wording, `Error.captureStackTrace` and JSC-style
   call-site columns are fingerprinted by Google's challenge and Akamai. Doable in any design, but every node needs a
   position and every call a frame record: the "no frames" speed of B2 is not available to a browser engine anyway.

## 5. The part of the idea that is right, and where it already pays

"Dynamic method map that maps directly to a Swift method" is the right model for the **host boundary**, and that is where
JeffJS is weakest: a native call costs ~750 instructions against QuickJS's 310, native→JS callbacks 1.3 k vs 0.4 k, and
every DOM operation (Instagram's per-frame work, Meta's Bloks, React's commit) is a native call through `[JeffJSValue]`
arrays, wrappers and the generic `cFunc` payload switch. A Swift method reached through a shape slot that holds a thin
function pointer with an `argv` pointer ABI is issue #1 step 3 ("one native-call ABI over the VM stack") plus a
*native-method inline cache* so `el.getAttribute(...)` dispatches like `get_field` does: the slot's function pointer is
called with `(ctx, this, argv, argc)` and no array. That is Jeff's idea, applied to the 4.8x row rather than to the row
that is at parity.

The second right part is **direct slots for variables**: global `let`/`const`/`function` bindings as cells the bytecode
addresses by index after the first lookup (V8's property cells, QuickJS's global var refs). JeffJS has the global IC;
checking that script-level `function` declarations and module bindings resolve to a cell rather than a hash probe is a
small audit, not an architecture.

## 6. Other radical alternatives, ranked

| | alternative | attacks | plausible gain on browser code | size | verdict |
|---|---|---|---|---|---|
| A | **Manual-memory core in Swift**: `JeffJSObject`, closures, frames and strings as arena records behind `UnsafeMutablePointer`, JS refcount as the only count, no Swift class on a hot path ("C discipline in Swift"; issue #1 generalised) | the 48 % lifecycle share | 1.5–2x (3.8x → ~2x) | the largest change the engine has had; both collectors, zombie tooling | **the real lever**, do it in bounded steps with a kill gate |
| B | **C core**: embed C QuickJS (or write the VM core in C with computed goto) under the Swift bridges | everything | parity by definition (the 3.8x) | weeks; breaks the pure-Swift identity and the "match QuickJS" port discipline becomes "is QuickJS" | technically the surest path; a product decision, not an engineering one |
| C | **Register bytecode + more fused ops** (Lua 5 / V8 Ignition style) | the 23 % dispatch row | ≤ 10 % overall | compiler rewrite, cache format change | not now |
| D | **Closure tree / method map** (this document) | the 23 % row | ~0, negative with real control flow; memory ×15–40 | a new engine | **no** |
| E | **Builtin-level fixes from the docket table**: generator frames kept alive (9.9x), regex compile-to-matcher for the common patterns (9x), typed-array class lookup (`typedArrayInfo` 1.8 % of all time; 7x), Proxy trap fast path, accessor ICs, template objects | the 20 % "other" row, which is where most of the per-kernel gap sits | each 1.5–5x on its kernel; together maybe 1.3x on realworld | small each | **do alongside A** |
| F | **PGO / LTO / `-Ounchecked` on the engine** | code layout, inlining | 5–15 % for interpreters, unproven in Swift | days | cheap experiment, worth one build |
| G | **AOT to Swift closures/code for shipped JS** (polyfills, app bundles) | polyfill time | small today | medium | later, only for code we ship |
| H | **Run less JS**: bfcache (done), page thread (done), site-level memoisation (the THD experiment), speculative skip of dead init work | the whole wall clock | can beat any engine win on specific sites | per site | keep as a tool, not an architecture |

## 7. Recommendation

**Do not replace the bytecode VM with a closure-tree / dynamic-method-map engine.** The evidence: the dispatch mechanism is
the one part of JeffJS already at C speed; a closure tree equals it on straight-line code, loses 1.4–2.2x once JS
control flow is in, costs 15–40x the memory per function on a watch that stops JS at 210 MB, and gives up the bytecode
cache that makes warm loads fast. Its only measured win (trivial frames) is available to the bytecode VM as lazy frames.

**Do take the idea to the host boundary and the object model**, which is where the 3.8x lives:

1. **Native method slots (issue #1 step 3, done as Jeff's "method map")**: builtins and DOM bridge methods as thin
   function pointers in shape slots with an `argv`-pointer ABI, a native-method IC on `call_method` sites, and
   native→JS callbacks that write into the callee frame. Measure on Instagram's per-frame work and `native-calls` (4.8x).
2. **The manual-memory core (alternative A)** in gated steps: closure/function objects and mapped `arguments` first (the
   docket's leftover 1, where the measured ARC is), then plain objects. Each step behind a `JEFFJS_INTERP_<NAME>=0`
   switch, measured on `realworld` + `watch_deepmerge` + a recorded page, with a stop rule.
3. **Alternative E now**, independently: generator frames, the typed-array lookup, regex. Small, contained, and they fix the
   worst rows of the table.
4. Before 1 and 2, the docket's **one-day Reels profile on JB**, so the split between interpreter, bridge and layout is
   known and the first step is the one that moves the frame.

**What the first step costs.** The native-method-slot work is about one week for the ABI, the adapter for existing
`[JeffJSValue]` builtins and the IC, plus a few days migrating the DOM bridge's hot methods; go/no-go after a week on the
`native-calls`, `bind-call-apply` kernels and an Instagram feed script. The manual-memory core's first step (closure
objects + mapped `arguments` off ARC) is the 1–2 weeks the docket estimated, with a gate of ≥ 10 % on `watch_deepmerge`
before committing to plain objects. If Jeff would rather have the sure thing, the C-core decision (B) is the one to make
explicitly, because every Swift-side step above is work QuickJS has already done in C.

## Appendix: reproducing the measurements

```bash
# profile
cd ~/www/jeffjs && .build/release/jeffjs-cli bench/realworld.js & sample $! 15 -file /tmp/realworld_sample.txt
# dispatch microbenchmark (branch design/execution-rethink)
swiftc -O -wmo bench/arch/dispatch_bench.swift -o /tmp/dispatch_bench && /tmp/dispatch_bench
```
