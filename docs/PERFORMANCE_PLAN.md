# JeffJS Performance Plan

Goal: bring the interpreter to JavaScriptCore-interpreter (LLInt) speed on every
Apple platform, then optionally beyond it on macOS. Started 2026-09-04.

## Baseline (2026-09-04, Apple Silicon, release build)

Times in milliseconds for `bench/kernels.js`. `jsc` is the system binary at
`/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc`.
The LLInt column (`--useJIT=false`) is also roughly what JavaScriptCore delivers
inside third-party iOS apps, which cannot JIT.

| kernel            | JeffJS | jsc LLInt | jsc baseline JIT | jsc full JIT |
|-------------------|-------:|----------:|-----------------:|-------------:|
| int-loop (20M)    |   1754 |       153 |               56 |            6 |
| float-loop (10M)  |    926 |       135 |              114 |           23 |
| calls (5M)        |   1294 |       129 |               29 |            3 |
| prop-get-set (5M) |    998 |       101 |               25 |            2 |
| method-call (3M)  |   1350 |       157 |               31 |            4 |
| alloc-objs (1M)   |    699 |        39 |               11 |            1 |
| array-push (2M)   |    823 |        74 |               34 |           16 |
| string-concat     |     65 |         4 |                2 |            1 |
| closure (3M)      |    740 |        82 |               19 |            5 |
| fib(25)           |     44 |         6 |              1.5 |            1 |

JeffJS is 7-19x behind LLInt and roughly 8x behind C QuickJS. Closing the gap
to LLInt is the target on iOS/watchOS/tvOS/visionOS, where writable+executable
memory is unavailable to third-party apps, so no JIT of any kind is possible.

## Root causes found by profiling the int loop (`sample`)

1. `for (let i ...)` emits `close_loc` on every iteration even when nothing
   captures the variable. It costs a full buf->frame sync plus
   `closeLexicalVar`, and it is not trace-eligible, so `executeFastTrace`
   never ran for the most common loop shape. C QuickJS only emits it when the
   variable is captured.
2. `put_loc_check` does `fb as? JeffJSFunctionBytecodeCompiled` per store to
   check const assignment. QuickJS resolves this at compile time.
3. `frame.varBuf` / `frame.argBuf` are Swift arrays: copy-on-write uniqueness
   and bounds checks on every touch, plus periodic `syncBufToFrame` copies.
4. The dispatch loop is one ~7,300-line function; hot opcodes are starved of
   registers.
5. `JeffJSEnvironment.onConsoleMessage` never fires from a plain CLI process.

## Phases

Each phase is measured with `bench/run.sh` and gated by `swift test`
(conformance suite).

| # | Phase | Expected effect | Status |
|---|-------|-----------------|--------|
| 1 | Benchmark harness: `jeffjs-cli` executable target, `bench/kernels.js`, `bench/run.sh` comparing against jsc. Fix console callback. | measurement | done |
| 2 | Compiler fixes: emit `close_loc` only for captured loop vars; const-assignment check at compile time (no dynamic cast); widen trace eligibility. | 3-5x on loops | done (2x measured) |
| 3 | Frame/stack rewrite: one contiguous unsafe value stack for args, locals, operands (QuickJS layout). No Swift arrays in frames, no sync copies, no overflow-reporting push in release. Toggle: `interp.uncheckedStack` in `JeffJSConfig.plist`. | 2-3x everywhere | partial: shared stack, lazy frame arrays; frame objects still pooled classes |
| 4 | Calls: inline fast path for `call_method` and constructors, args passed in place on the shared stack, no per-call frame object. | 2-3x calls | partial: call/call_method/zero-arg fused calls inline; constructors not yet |
| 5 | Objects: property values in one tail-allocated buffer; `put_field` IC; prototype-chain IC; precomputed shapes for literals/`new`; object free list; trim per-alloc GC bookkeeping. | 2-4x objects | partial: shared shapes, ARC-free IC hits; define_field IC and free list pending |
| 6 | Quickening: rewrite bytecode in place on first execution with fused instructions and embedded cache slots (LLInt style). Split cold opcodes out of the dispatch function. | 1.5-2x | not started |
| 7 | macOS-only JIT (optional, after 2-6): ARM64 emitter + `pthread_jit_write_protect_np`, needs `com.apple.security.cs.allow-jit`. Portable fallback: closure compilation. | large, Mac only | not started |

Expected end state after phases 2-6: loop and call kernels within 1-2x of jsc
LLInt, matching what C QuickJS achieves.

## Progress log

- 2026-09-04: baseline measured, plan written.
- 2026-09-04: Phase 1 done. `jeffjs-cli` target, `bench/kernels.js`, `bench/run.sh`, `JEFFJS_DUMP=1` bytecode dump. Console callback works; the earlier failure was the kernel script preferring a `print` global that JeffJS defines.
- 2026-09-04: Phase 2 part 1. close_loc stripped for non-captured loop vars (name-based conservative analysis over descendant functions); const assignment resolved to throw_error at compile time; put_loc_check trace-eligible; overlapping loop candidates merged into one trace region with per-target start pc. int-loop 1754 -> 932 ms, float-loop 926 -> 638 ms. Conformance unchanged (1705 pass / 1 pre-existing fail: allLoaded18).
- 2026-09-04: Phase 2 part 2. TDZ elimination for provably-initialised lexical locals (get_loc_check/put_loc_check -> get_loc/put_loc; switch-body scopes excluded); NOP compaction before the peephole pass, which made every multi-instruction peephole and fusion live for the first time. Three latent bugs surfaced and were fixed: `get_loc8_call` fused argc>0 calls (callee/arg confusion), `get_loc8_add` had operands reversed (string concat order), and push+drop deleted throwing `get_var` loads. `JeffJSBytecodeCache.rt` was `weak`, which put every runtime retain/release on the slow side-table path; now unowned(unsafe). int-loop 892, float 524, prop-get-set 633, alloc-objs 523, array-push 340, closure 602 ms.
- 2026-09-04: Phase 3 + 4 (first cut). Frame arrays (argBuf/varBuf) no longer filled per call; they are materialised on demand by syncBufToFrame() for the arguments object and generator save/restore. Inline call path uses fbFast/varRefsFast instead of pattern-matching the payload enum. InlineCallFrame holds fb/frame unowned(unsafe). Shared value stack: an inline callee's frame is carved out of the caller's buffer at the first argument slot (no allocation, no arg copy); `bufOwned` tracks the rare fallback to a pooled buffer; interp buffers are now 8192 slots. call_method got the same inline fast path through a shared enterInlineFrame() helper. calls 1023 -> 820, method-call 1072 -> 780, fib25 45 -> 37 ms. Conformance 1706/0.
- 2026-09-04: Phase 3/4 second cut. Inline call stack moved to a per-runtime unsafe stack of trivially-copyable frames (caller varRefs re-derived from funcObj on pop). `get_loc8_call` (fused zero-arg call) now takes the inline path; it used to force every closure call through callFunction. calls 767, closure 479, fib25 32 ms.
- 2026-09-04: Phase 5 first cut. Shared hidden-class shapes: objects start on a hashed root shape per prototype and follow hashed transitions on property add (`jeffJS_rootShape`, `jeffJS_objectAddShapeProperty`); delete / flag change / freeze / prototype change copy the shape first (`prepareShapeUpdate`); hashed shapes stay cached (cap `shapes.maxHashed`). Inline caches now hit across objects of the same shape. IC hit paths compare an unretained `shapeIdentity` and read a raw `icEntries` pointer (no ARC); `writable` cached in the entry. Object dup/free go through unretained refs (`_withUnsafeGuaranteedRef`). alloc-objs 510 -> 330, prop-get-set 631 -> 407, method-call 767 -> 625 ms. Conformance 1706/0.

- 2026-09-05: Round 2. Trace: `inc_loc`/`dec_loc`/`add_loc`, `push_const8`, float arithmetic + comparisons, property opcodes (IC hits only), arrays/globals now eligible, `perm3/4/5` and `get_loc_checkthis` implemented (they were eligible but missing, so any loop containing them deopted every iteration); no per-op range/stack checks; boolean branch fast path. Main loop: int fast paths for bitwise ops. Calls: frame pool is a free list of immortal frames (`rt.allFrames`) with unowned(unsafe) `prevFrame`/`currentFrame`; varRefs array only copied for functions with closure vars. Objects: `define_field` transition IC, cached root shape for `{}`, `propExtra` allocated lazily (one array per object instead of two). Tried and reverted: unowned(unsafe) locals for `fb`/`frame` inside callInternal (5-6% slower everywhere, presumably codegen). int-loop 869 -> 585, float 532 -> 356, calls 742 -> 478, prop-get-set 404 -> 339, method-call 618 -> 446, alloc 324 -> 198, closure 473 -> 337, fib25 32 -> 24 ms.

- 2026-09-05: Round 2, second half. Prototype-chain inline cache (depth 1: receiver shape + holder object + holder shape, all retained by the entry) in the four get_field forms and their trace counterparts: method-call 446 -> 385. `get_length` uses the IC with an atom-based fallback instead of re-interning "length" per execution: array-push 300 -> 230. Strings carry a `kind` tag on the shared base class so concat/flatten/free use `unsafeDowncast` instead of `as?` chains; trace `add` concatenates strings in place: string-concat 37 -> 23. Frame release resets only fields the next acquire does not overwrite; `JeffJSVarRef.parentFrame` unowned(unsafe).

- 2026-09-05: Round 3 (QuickJS parity push), part 1. Instruments (`xctrace record --template 'Time Profiler'`, exported with `xctrace export --xpath ... time-profile`, aggregated by `/tmp/jjbench/tp.py`) replaces `sample`. Note: Instruments shows inlined helpers as separate frames, so "push #1 ()" in a profile is not evidence of a call. Done: push/pop/peek rewritten to direct buffer ops in the dispatch loop (no measurable change; they were already inlined), compile-time const check for closure-variable stores (removed a dynamic cast per store: closure 338 -> 302), `hasLiveVarRefs`/`varRefsLoaded` flags instead of Array.isEmpty, direct slot pointers for closure variables (`JeffJSVarRef.slot`), unowned(unsafe) `frame` local (calls 465 -> 419, method 383 -> 345, fib 22.7 -> 19.6), debug flags as stored globals. Measured twice and rejected: unowned(unsafe) `fb` local (10-15% slower on calls).

- 2026-09-05: Round 3, part 2 — the big one. Every nested function inside callInternal that captured the hot locals (`pc`, `sp`, `buf`, `fb`, `frame`, ...) was removed: push/pop/peek/peekAt call sites rewritten to direct buffer ops and the helpers deleted, syncBufToFrame/syncFrameToBuf moved to file scope with parameters, and enterInlineFrame expanded textually at its three call sites. Captured `var`s cannot live in registers; with the captures gone the compiler keeps them in registers across the dispatch loop. calls 448 -> 375, method-call 371 -> 316, closure 285 -> 236, fib25 20.4 -> 18.4, alloc 209 -> 192, array-push 242 -> 225 ms. Rule for this file: no nested functions or closures may capture interpreter locals.

- 2026-09-05: Round 3, part 3. Fast trace can now run calls and returns: a `HotState` struct hands the full interpreter state to the trace and back, so it can enter inline callees (call / call_method / get_loc8_call), return from them, and deopt from anywhere. Also added: push_this, closure-variable ops, the Array.prototype.push fast path, float operands for bitwise ops (the int-loop kernel overflows to double and used to deopt on `|0` every iteration), a progress-aware deopt guard that disables blocks that keep bailing out, and a raw-byte test instead of enum `==` per opcode (the bigger function stopped inlining the generic `==`: 15% of a loop). The call-capable variant is ~10% slower per opcode, so the compiler flags blocks that need it (`TraceBlockInfo.hasCalls`) and the lean variant (`executeFastTraceLean`) handles the rest. calls 357 -> 323, method-call 304 -> 271, closure 232 -> 222.

- 2026-09-05: Round 3, part 4. Rarely-used values demoted from trace locals to the handoff struct (stack spills 486 -> 361); `.invalid` handled as a switch case instead of a per-opcode compare; interrupt counter kept in a register inside both trace variants; `set_loc + drop -> put_loc` peephole.

- 2026-09-05: Round 4 ("close the last 2x"). Loop layout: `for`/`while` are now bottom-tested (condition and update parsed into side buffers and appended after the body): one conditional back-edge per iteration instead of three jumps; conditional backward branches are trace entry points. Superinstructions: the six `with_*` opcodes moved to the wide range (they run through the 0x00-prefix path) to free single-byte numbers for `cmp_loc_i8`, `cmp_loc_loc`, `arith_loc_loc`, `arith_loc_i8` (add/sub/mul/and/or/xor), `to_int32`, `arith_const8`, emitted by peepholes on `get_loc push_i8 <op>`, `get_loc get_loc <op>`, `push_0 or`, `push_const <op>`; plus `dup perm3 put_field drop -> put_field` and `dup put_loc drop -> put_loc`. The int loop went from 13 opcodes per iteration to 5. Fused compares branch directly when `if_true8/if_false8` follows (runtime lookahead, no compiler change). Trace: unowned bytecode reference inside the trace (a win there, unlike in the main loop), unmanaged var-ref mirror (`JeffJSObject.varRefsRaw`) so closure-variable access has no ARC, trace entry at function entry and at inline calls (fib went 17.5 -> 11.3 ms: it has no loop, so it never traced before), warm-up threshold 2, and per-function lean/fat variant selection (`fb.traceLean`). Fixed along the way: `super(...)` in derived constructors emitted one `drop` too many (stack one below base; hidden for years by a guarded pop), the main loop's pops are guarded again (`jeffJS_pop`, reports once and disables the trace for that function), and the trace's `drop`/`return` deopt on underflow.

## Round 5 plan: beating QuickJS (2026-09-05)

QuickJS is a C interpreter with computed-goto dispatch; on pure arithmetic loops both engines sit at the interpreter floor and JeffJS is already at parity. The rest of the gap is in places where QuickJS is architecturally weak and a Swift engine can do better, so the plan is to attack those rather than the dispatch:

| # | item | why it wins | kernels |
|---|---|---|---|
| 1 | Trace coverage: inner loops of an ineligible outer loop (region merge drops them), `object`/`define_field`/`array_from`/TDZ-slot opcodes in the trace, `push` on arrays without an IC | the alloc and array-push kernels currently never enter a trace at all (profiled: main loop 40%, guarded pops 7%) | alloc, array-push |
| 2 | ARC-free hot paths: unmanaged object access in the trace's property and call ops, unmanaged `fbFast` mirror, frame acquire without retain, raw IC pointer in the lean trace, store-opcode mask as a literal | retain/release pairs are 15-18% of the calls, closure, fib and property profiles | calls, closure, fib, prop, method |
| 3 | Raw property storage (`propValues` as an unsafe buffer): no bounds check, uniqueness check or end-mutation call per property read/write | QuickJS does a hash lookup per access; a two-load IC hit beats it | prop, method, alloc |
| 4 | Plain-object creation fast path (cached proto and root shape, initial slot capacity 4, no class-table lookup) and an object recycle pool | QuickJS mallocs every object; the profile shows malloc/free at 21% and array regrowth at 5% | alloc |
| 5 | Double fast paths in the fused arithmetic ops | float loop is 1.35x | float |
| 6 | Frame-less inline calls: no frame object acquire/release per call, smaller saved-state record | call bookkeeping is ~25% of the calls kernel | calls, fib, closure, method |

### Round 5 progress log

- Trace coverage: an outer loop with an unsupported opcode no longer removes its inner loops from tracing (the merged region falls back to the eligible inner candidates); `object`, `define_field` (transition-cache hit), `array_from` (empty literal), `set_loc_uninitialized` and `put_loc_check_init` run in both traces; `arr.push` on an array receiver pushes the cached `Array.prototype.push` without an inline cache so the trace's push fast path applies.
- Raw property storage: `JeffJSObject.propValues` is a (pointer, count, capacity) triple (`JeffJSPropStorage`), freed in `deinit`; `freeObject` moves it out before releasing the values. `propExtra.count` is mirrored in `propExtraCount`. Inline-cache hits run inside one guaranteed-reference scope (`jeffJS_icRead`/`jeffJS_icWrite`/`jeffJS_icDefine` in JeffJSPropStorage.swift): no retain/release per field access.
- Object recycle pool (JeffJSObjectPool.swift): plain objects with only data slots are reset and parked on `rt.objectPool` when their refcount reaches zero; `newObjectClass` pops from it. `JEFFJS_NO_POOL=1` disables it. Alloc kernel 182 -> 92 ms (QuickJS 91).
- Correctness bugs found by the pool (recycling turns a dangling reference into a live one, where before it hit dead-but-intact memory):
  1. `set_loc_uninitialized` (block re-entry in loops) overwrote the slot without releasing the previous binding: every `let`/`const` inside a loop body leaked one value per iteration (the alloc kernel peaked at 3.7 GB; now 18 MB).
  2. Closures created in a loop body all saw the last iteration's block-scoped binding (`for (...) { const o = ...; fns.push(() => o) }` gave 2,2,2 for 0,1,2): `createFunction` resolves the parent before compiling its children, so `isCaptured` is never set when the parent's `leave_scope` is expanded into `close_loc`. The expansion now uses the descendant-name over-approximation already used for close_loc stripping. `for-of`/`for-in` loop variables had no per-iteration `close_loc` at all; the continue label now sits before one.
  3. `Promise.all`/`allSettled`/`any` released their copy of the capability's resolve/reject functions when the combinator returned, while the element closures call them from later microtasks (use-after-free; `allSettled` results silently never arrived). `PromiseAllData` now owns those references and its collected values, released in `deinit`.
- `put_field` inline-cache hits (main loop and traces) now release the overwritten slot value and the receiver reference, as QuickJS does; the trace's array push fast path releases the callee and receiver references.
- Zombie mode (`JEFFJS_ZOMBIES=1`) additionally reports calls to freed function objects (`[ZOMBIE-CALL]`), which is what located bug 3.

- Call path without ARC: `fbFastU` (unmanaged mirror of `fbFast`), `acquireFrameU`/`releaseFrameU` with an unmanaged free list (`nextFree`) and a `bufArraysLive` flag instead of two array-count loads per return, the lean trace takes the raw IC pointer (`icEntries`) instead of the cache object (a retain/release pair per property op), the store-opcode mask is a bootstrap-filled stored global (no swift_once per `isStoreOpcode`), and `dupValueFast`/`freeValueFast` inline the plain-object refcount bump for the traces' hot release sites. Calls 220 -> 190 ms, prop 235 -> 181, method 185 -> 170, closure 127 -> 106, fib 11.5 -> 9.5.
- Ownership audit (memory leaks measured with a per-operation scan, `/tmp/jjbench/leaks`, peak RSS at 1M iterations; 17 MB is the floor). Fixed: inline returns now release the callee's variable slots and the caller's function/receiver/argument slots (`InlineCallFrame.spTop`; heap arguments leaked one reference per call: 728 MB -> 19 MB); detached var-refs are dropped from `frame.liveVarRefs` (closure creation in a loop was quadratic: 40k iterations took 6.3 s, now 0.05 s); string-plus-number leaked the number's string (`jsAdd`); the fused `get_loc8_add` leaked its operands; the generic (non-inline) call sites release the callee and receiver after the call and the arguments when the callee is bytecode; `iterator_close` releases the iterator state and `iteratorClose` its `return` function; `for_of_next` releases the `{value, done}` object; the activation epilogue releases the variable slots of non-generator frames; `put_field` misses (every `this.x = v` that adds a property in a constructor) release the receiver; `put_array_el` releases the receiver; the main loop's array literal releases the parser's sentinel object; dying arrays release their elements (both storages); `JeffJSVarRef.deinit` releases the detached value; array element overwrite releases the old element (both storages); `arr.length = n` and `pop`/`shift` truncate the fast storage and release the dropped elements; `Array.prototype.fill` and `Function.prototype.bind` take their own references (they stored borrowed arguments).
- Convention now documented and enforced by the zombie stress set (`/tmp/jjbench/zs`, one script per array-storing builtin): the interpreter owns every stack value; `callFunction` borrows func/this/args; builtins that store an argument must dup it. Arguments are released after C-function calls only once every storing builtin dups (today: `push`, `unshift`, `splice`, `concat`, `Object.assign`, `defineProperty`, `Map.set`, ... hand a borrowed argument to an ownership-taking setter, so those calls still leak their arguments; callbacks passed to `map`/`forEach`/`JSON` leak the same way).
- Still leaking (per-iteration): property reads on string primitives allocate a wrapper that is never released (`str_meth`, 140 B/iter); `JSON.parse`/`stringify` temporaries (650 B/iter); closures passed to C builtins (see above).

## Current standing (2026-09-05, end of round 5)

| kernel | round 4 | now | QuickJS | now vs QuickJS |
|---|---:|---:|---:|---:|
| int-loop | 317 | 314 | 314 | 1.00x |
| float-loop | 239 | 237 | 177 | 1.34x |
| calls | 225 | 206 | 146 | 1.41x |
| prop-get-set | 261 | 177 | 138 | 1.28x |
| method-call | 201 | 177 | 125 | 1.41x |
| alloc-objs | 180 | 86 | 90 | 0.96x |
| array-push | 182 | 149 | 108 | 1.38x |
| string-concat | 18 | 17.7 | 10.3 | 1.71x |
| closure | 128 | 112 | 69 | 1.62x |
| fib25 | 11.6 | 10.0 | 5.1 | 1.97x |

Conformance 1706/0. The ownership fixes cost the call kernels about 7% against the interim best (calls 190, method 170, fib 9.5): every inline return now releases the callee's slots and the caller's function/receiver/argument slots, which is required for correctness (heap arguments leaked one reference per call before). Peak memory of the alloc kernel went from 3.7 GB to 18 MB over the round.

### What would beat QuickJS on the remaining kernels

1. Calls/fib/closure (1.4-2x): a frame-less inline call. The `JeffJSStackFrame` object is still acquired and released per call (13 stores plus the free-list link); QuickJS keeps its frame on the C stack. Materialise the frame object only when something observes it (closures, `arguments`, exceptions, generators), and keep the 14-field `InlineCallFrame` record as the only per-call state.
2. Constructors and `this.x = v`: `put_field` has no transition cache, so every property added in a constructor is an inline-cache miss through `setPropertyChecked` (the `new_class` scan spends most of its time there). Reuse the `define_field` transition cache for adds.
3. Property access (1.28x): the remaining cost is the cache entry load (56 bytes, 7 fields) and the `extra` check; a two-field entry (shape, slot) for own data properties plus a separate proto entry table would shorten the hit path to compare, load, load.
4. Strings (1.7x): string-plus-number goes through `toString` + `concatStrings` with two temporaries; a direct int-to-rope append, and the primitive wrapper allocation on `"str".method()` (also the last known per-iteration leak) need a String.prototype lookup that never boxes.
5. Float loop (1.34x): the fused arithmetic ops decode both operands through the generic numeric path; a double-only fast path in `arith_loc_loc`/`arith_const8` when both tags are float.
6. Arguments after C-function calls are still leaked (see the convention note above); making every storing builtin dup its stored arguments would let the call sites release arguments unconditionally.

## Round 6: real-world workloads (2026-09-05)

Jeff's ask: "real usage speed, not just random benchmarks". `bench/realworld.js`
runs 38 browser-style kernels (DOM-ish tree building, JSON, regex tokenising,
string formatting, Map/Set, classes, closures, promises, typed arrays, proxies,
generators ...) and prints each result so it can be checked against
`/opt/homebrew/bin/qjs`. The first run found three crashes/wrong results
(Map/Set iteration, multi-level class default constructors + `super.method()`,
regex exec on long inputs) and several quadratic paths.

### What was fixed

Speed (real-world blockers):
- regex exec: bytecode compiled once and reused, code units cached on the input
  string, one VM reused across start positions (regex-tokenize 15754 ms -> 80 ms);
- array building: fast-array storage migration, `Array.of`, `Object.fromEntries`,
  `arraySnapshot()` at every direct payload reader (map/filter/reduce 2906 -> 546 ms);
- string builtins: O(1) `charAt/charCodeAt/codePointAt/at`, direct UTF-16 string
  construction, `requireThisString` leak (charcode-encode 1172 -> 92 ms);
- native calls: C functions dispatched directly from the fat trace, ARC-free
  `dispatchCFunction` (native-calls 1129 -> 540 ms);
- dynamic keys: atoms cached on JS strings used as property keys, hashed from
  code units (object-dictionary 422 -> 311 ms);
- string buffer `flatCache` (the `+=` accumulator materialised a fresh 16 KB
  string per read: 1.3 GB peak on the tokenizer kernel);
- Map/Set iterator prototypes and `{value, done}` results; array `length`
  non-enumerable and for-in over arrays.

Correctness (found by the suite and by the probes written for it, all
verified against QuickJS):
- `try` inside `for-of`/`for-in`, nested `try`, and `break`/`continue`/`return`
  crossing a `try` or an inner `for-of`: the parser emitted `nip_catch` with the
  catch offset on top (deleting the value below it, e.g. the loop's iterator
  state or the outer handler) and `break`/`continue` ignored pending `finally`
  blocks and inner iterators. Now `emitUnwind` walks block envs (with
  `iteratorSlots`/`finallyDepth`) innermost-first and emits drop/nip_catch +
  gosub + iterator_close/perm4 in nesting order; nested functions get a fresh
  block-env chain; `nip_catch` at runtime pops the offset if it is on top, else
  keeps TOS and frees down to the offset (QuickJS semantics, needed because the
  eval completion-value pass treats `nip_catch` as transparent).
- `async function` *expressions* compiled as plain functions (returned raw
  values instead of promises): the primary parser consumed `async` before
  delegating, so `parseFunctionDef` never saw it.
- generators: `return()` now runs `finally` blocks (resume pushes
  `[value, is_return]`, parser emits `if_false; unwind; return_` after
  `yield`/`yield*`, QuickJS style); `yield*` forwards `next(v)` and `throw()` to
  the inner iterator and `return()` closes it; `for-of`/`for-in` inside a
  generator crashed on the second `next()` (the saved value stack was copied
  without ownership and freed by the frame epilogue: now moved into the saved
  state, released in `JeffJSGeneratorData.deinit` if abandoned); `yield` as a
  call argument / assignment RHS lost its operands for the same reason.

Leaks (per-operation leak scan in /tmp/jjbench/leaks, all files now at the
17 MB floor except the pre-existing arr_map 79 MB and json 66 MB):
- trace `put_loc*`/`put_loc_check` stores never released the previous slot
  value and `set_loc0-3` shared one reference between slot and stack (one object
  per iteration for any `var o = {...}` in a traced loop; the shared ref was the
  tokenizer crash);
- generator args/locals never released at completion or abandonment; each
  yielded/returned value leaked one reference (`createIterResult` copies);
  each `next()` on an array iterator leaked a reference to the array; `yield*`
  leaked the iterable, the first result object and the delegate; the resume
  prologue's early returns skipped `releaseFrame` (a frame per `yield*` step);
- `var x = ...` inside a top-level loop: the per-iteration `define_var`
  redefined the global with `undefined` without releasing the old value
  (`defineGlobalVar` now leaves an existing binding alone, per
  CreateGlobalVarBinding; one shared-context test expectation updated).

### Real-world standing (ms, lower is better; `start` = first run of the suite)

| kernel | start | now | QuickJS | now/qjs |
|---|---:|---:|---:|---:|
| generators-iterators | 238 | 241 | 17.7 | 13.6x |
| object-dictionary | 422 | 311 | 26.5 | 11.8x |
| string-sort-compare | 599 | 341 | 30.2 | 11.3x |
| regex-tokenize | 15754 | 80 | 7.2 | 11.2x |
| array-find-indexof | 233 | 236 | 23.8 | 9.9x |
| bind-call-apply | 404 | 358 | 36.6 | 9.8x |
| string-split-trim | 459 | 239 | 24.8 | 9.6x |
| for-in-entries | 824 | 705 | 84.2 | 8.4x |
| proxy-reactive | 312 | 266 | 31.9 | 8.3x |
| json-parse | 561 | 606 | 73.5 | 8.2x |
| date-number-format | 774 | 725 | 88.1 | 8.2x |
| charcode-encode | 1172 | 92 | 11.2 | 8.2x |
| rest-spread-destructure | 939 | 890 | 109 | 8.1x |
| typed-array-image | 1034 | 944 | 120 | 7.8x |
| object-assign-create | 715 | 522 | 71.3 | 7.3x |
| getter-setter | 123 | 126 | 17.2 | 7.3x |
| map-set | crash | 339 | 47.8 | 7.1x |
| array-map-filter-reduce | 2906 | 546 | 79.5 | 6.9x |
| template-html | 409 | 288 | 41.9 | 6.9x |
| arguments-object | 251 | 243 | 39.8 | 6.1x |
| template-literals | 299 | 200 | 33.6 | 6.0x |
| large-object-keys | 308 | 238 | 41.4 | 5.8x |
| array-from-fill | 194 | 99 | 18.3 | 5.4x |
| native-calls | 1129 | 540 | 101 | 5.4x |
| vdom-build-diff | 115 | 101 | 18.9 | 5.4x |
| event-emitter | 108 | 77 | 16.2 | 4.7x |
| class-hierarchy | crash | 335 | 70.6 | 4.7x |
| string-replace-regex | wrong | 222 | 52.2 | 4.2x |
| polymorphic-access | 125 | 118 | 31.2 | 3.8x |
| json-stringify | 450 | 343 | 91.3 | 3.8x |
| array-sort-comparator | 949 | 226 | 65.6 | 3.4x |
| physics-vectors | 94 | 69 | 21.9 | 3.1x |
| tree-walk | 43 | 43 | 15.3 | 2.8x |
| array-splice-concat | 45 | 33 | 13.9 | 2.3x |
| closure-creation | 56 | 42 | 20.6 | 2.0x |
| switch-interpreter | 133 | 143 | 72.8 | 2.0x |
| try-catch-throw | 49 | 46 | 42.6 | 1.1x |
| promise-chain-setup | 11.4 | 10.9 | 12.0 | 0.9x |

All 38 results match QuickJS; geometric mean 5.5x slower. Micro-kernels are
unchanged by this round (int 1.04x, alloc 1.05x, others 1.3-1.6x, fib 2.1x).
Conformance 1706/0.

### Known gaps left (documented, not fixed)

- A closure capturing a generator local sees a stale value after a `yield`
  (var refs are detached when the generator frame is released at the yield).
- `yield*` + `return()`: an inner `return()` that reports `done: false` is
  treated as done instead of re-yielding its value.
- eval completion value through `for-of` + `try` is `undefined` (QuickJS: the
  last statement value); the tail-position analysis does not look through
  loops.

### Next levers (from the table)

1. generators (13.6x): each `next()` re-enters `callInternal` with a fresh
   frame, copies the saved stack/vars both ways and allocates a `{value, done}`
   object; keep the generator frame alive across yields (also fixes the closure
   gap) and build the result object from a cached shape.
2. dynamic keys / for-in / Object.keys (8-12x): `findAtom(jsString:)` still
   hashes per access when the string has no cached atom (computed keys built
   per iteration); a small string->atom cache keyed by content, and a for-in
   enumerator that walks the shape directly.
3. string compare/sort/split/trim (9-11x): comparisons go through
   `stringValue` + Swift String; compare code units directly and give
   `split`/`trim` narrow-storage fast paths.
4. call/apply/bind (9.8x) and rest/spread/arguments (6-8x): args arrays are
   built and copied per call; hand the callee a slice of the caller's stack.
5. Date/number formatting, JSON.parse, typed arrays (8x): builtins written with
   Swift String/Array conveniences; rewrite the hot ones over raw buffers.

## Round 7: everyday speed without a JIT (2026-09-05, evening)

Jeff's direction: "wildly more performant for every day use", ideally running
on Metal "at raw memory speed like JIT". Measured on the M1 Max first
(`/tmp/jjbench/metal/probe.swift`):

| probe | result |
|---|---:|
| compile 3 kernels from MSL source at runtime | 55 ms |
| empty compute dispatch round trip | 221 us median, 131 us min |
| serial LCG+switch loop, one GPU lane vs one CPU core | GPU 26.6x slower |
| element-wise map, 1K / 100K / 10M floats | GPU 290x slower / 15x slower / 4x faster |

The dispatch floor alone is worth ~200,000 interpreted opcodes and a lone GPU
lane is 25x behind a CPU core before dynamic typing enters, so Metal is not a
JIT substitute. It remains a throughput tier for element-wise numeric loops
over typed arrays with a million or more work items (integer/bitwise math
exact, float math not JS-exact: no f64). Chosen tracks instead: the "legal
JIT" (quickening + superinstructions: code generation as indices into a
build-time compiled handler table, allowed on iOS) and the page-load track
(parse speed, bytecode cache, lazy compilation, off-thread compile, GC).

### Parsing was quadratic

`bench`-style timing of parse+compile only (the script wrapped in a function
that is never called):

| script | before | after | QuickJS |
|---|---:|---:|---:|
| libvorbis.module.min.js (343 KB, one line) | 5448 ms | 123 ms | 34 ms |
| challenge.js (1 MB) | 7893 ms | 172 ms | 73 ms |
| synthetic 817 KB | 27876 ms | 394 ms | 50 ms |

`JeffJSParseState.getLineCol` rescanned the source from byte 0 for every
statement (the `line_num` emission), 76% of parse time and quadratic; it now
continues from the previous query. The remaining 2-4x is spread thin (Swift
array bounds checks, ARC, DynBuf appends, several compiler passes that each
decode every instruction). Also done: bitcast opcode decode in the compiler
passes, the switch fix-up pass gated on functions that contain a switch, the
JEFFJS_DUMP environment lookup read once, contextual-keyword checks cached.

### The bytecode cache was off because it was wrong

`JeffJSBytecodeCache` (in-memory, plus disk at
`~/Library/Caches/JeffJSBytecodeCache/v<n>/`, invalidated by a build stamp
and `compilerVersion`) existed but `cache.bytecodeEnabled` was false in the
plist. Deserialized code was wrong: the JFBC format dropped
`closureVarsList` (which parent slot each var_ref binds), `selfRefVarIdx`,
`isStrictMode` and the debug flags, and never restored trace regions. JFBC
v3 carries the descriptors and flags, recomputes trace regions with
`JeffJSCompiler.fuseBasicBlocks` on load, writes the disk file synchronously
(a queued write was lost when a short-lived host exited), and is enabled by
default. Checks: the real-world suite deserialized matches QuickJS on all 38
kernels at the same speed as freshly compiled code; every probe battery is
identical across compile and cache-hit evaluation; conformance 1706/0.

| script | parse+compile+store | disk hit |
|---|---:|---:|
| challenge.js (1 MB) | 183 ms | ~5 ms (30 ms process total, 24 ms is startup) |
| libvorbis (343 KB) | 132 ms | ~3 ms |

Scripts whose bytecode exceeds `cache.bytecodeMaxSize` used to throw
"Bytecode too large"; they later ran uncached. Since the byte-budget change
the cap compares the *serialized* entry (default 0 = none) and the disk tier
is bounded by `cache.bytecodeDiskBudgetBytes` with LRU eviction; a 3.7 MB
production bundle (homedepot) compiles in 974 ms and loads from disk in 32 ms
(8 MB entry). Any config key can be overridden
from the environment (`JEFFJS_CACHE_BYTECODEENABLED=1`).

### Superinstruction tooling

`swift build -c release --product jeffjs-cli --scratch-path <dir> -Xswiftc
-DJEFFJS_OPPROF` builds a CLI that counts executed opcodes and consecutive
pairs across the main loop and both traces and dumps the top entries at exit.
All 256 narrow opcode slots are in use (the compile-time-only scope_*/label_
ops already live in the wide range), so each new fused opcode must evict a
narrow opcode that the profile shows is essentially never executed.

### Superinstructions: what the opcode profile actually said

The profiled build (`-DJEFFJS_OPPROF`) over the real-world suite: 715 M
dispatches. `nop` was 5.1% of them (padding left by the late label-resolution
passes, mostly right after conditional jumps) and `nop -> nop` the top pair.
A final NOP-compaction pass with jump/label/line-table remapping removed
them: 3.6% faster overall, up to 10% on switch-heavy code. The NOP-prefixed
compound fusions (a NOP byte as an escape for a sub-opcode) were removed:
every pattern they matched was already captured by earlier fusions, and they
conflicted with padding compaction and with the traces. `a[i] = v;` compiled
as `dup perm4 put_array_el drop`; folded to one `put_array_el`.

Fused compare-and-branch (`cmp_if8`/`cmp_if`, a same-size post-compaction
rewrite of `lt/.../strict_neq` + `if_true(8)/if_false(8)`, taking the slots of
the never-emitted `swap2`/`dup1`) helped the micro-kernels (int loop at
QuickJS parity, fib25 -8%, method calls -4%) but a paired A/B on the
real-world suite was exactly neutral (1.000). Lesson: everyday code is not
dispatch-bound.

### Where everyday time really goes (CPU profile of the whole suite)

| bucket | share |
|---|---:|
| Swift retain/release (incl. slow paths and stubs) | ~26% |
| malloc/free/alloc (Swift arrays, strings, objects) | ~11% |
| callInternal self | 7.8% |
| traces self | 4% |
| shape transition lookup on property add (findHashedShape) | 2.4% |

Callers: payload enum copies (`if case ... = obj.payload` retains every
associated object even when the case does not match), `callInternal`,
prototype-chain walks in get/setPropertyInternal, `[JeffJSValue]` argument
arrays per native-to-JS call, and above all Swift `String` round trips:
`JeffJSString.toSwiftString()` built an array of `Character` per Latin-1
string and was the top allocation source (JSON, sort, assign, join, values,
parseFloat).

### String-conversion batch (2026-09-06)

`toSwiftString` decodes ASCII Latin-1 in one pass (non-ASCII transcoded
directly, UTF-16 without an Array copy); `indexOf`/`includes`/`sameValueZero`
compare code units instead of converting; `parseFloat` scans code units and
uses strtod (also correctly rounded now); `JSON.parse` takes bytes straight
from the JS string, builds result strings from UTF-16 units and object keys
through atoms; `JSON.stringify` quotes from code units (lone surrogates are
escaped instead of becoming U+FFFD). Correctness fixes found on the way:
`JSON.parse` errors are real `SyntaxError` objects (they were plain strings),
`sameValueZero` coerced every value to a number so `["cherry"].includes("Cherry")`
was true, Map/Set keys now canonicalize integral doubles (so `get(-0)` and
`get(0.5+0.5)` find an int key), and all three number-to-string paths follow
ES Number::toString layout (`0.000001` not `1e-06`, `1e-7` not `1e-07`,
`123456789012345680000` not the exact binary value).

| kernel | before | after | QuickJS | after/qjs |
|---|---:|---:|---:|---:|
| string-sort-compare | 329 | 111 | 30 | 3.7x |
| json-parse | 579 | 296 | 74 | 4.0x |
| date-number-format | 698 | 524 | 88 | 5.9x |
| object-assign-create | 511 | 421 | 71 | 5.9x |
| json-stringify | 344 | 297 | 91 | 3.3x |

Real-world geomean 4.9x QuickJS (from 5.3x); all 38 kernels match; conformance
1706/0. Known gaps left: `(0.1).toString(2)` last digits, `JSON.stringify(1n)`
must throw, a lone-surrogate escape in a source string literal becomes U+FFFD.

### Next levers (from the profile, in order)

1. Payload enum copies: guard every `if case ... = obj.payload` on a
   non-copying kind byte and read hot cases from dedicated fields.
2. Prototype-chain walks with unowned/Unmanaged references in
   get/setPropertyInternal; a per-shape transition cache for property adds.
3. Native-to-JS calls without a fresh `[JeffJSValue]` per call (sort
   comparators, map/filter/forEach callbacks, call/apply/bind).
4. Remaining Swift String users on hot paths: Object.assign/values/join keys,
   getProperty(obj:key:), string concatenation buffers.
5. Then generators (frame kept alive across yields), dynamic keys, for-in.

## Current standing (2026-09-05, end of round 4)

| kernel | baseline | round 3 | now | QuickJS | now vs QuickJS |
|---|---:|---:|---:|---:|---:|
| int-loop | 1754 | 602 | 317 | 318 | 1.00x |
| float-loop | 926 | 369 | 239 | 177 | 1.35x |
| calls | 1294 | 319 | 225 | 148 | 1.53x |
| prop-get-set | 998 | 341 | 261 | 141 | 1.85x |
| method-call | 1350 | 270 | 201 | 127 | 1.58x |
| alloc-objs | 699 | 197 | 180 | 91 | 1.98x |
| array-push | 823 | 254 | 182 | 110 | 1.65x |
| string-concat | 65 | 23 | 18 | 10.5 | 1.72x |
| closure | 740 | 220 | 128 | 70 | 1.84x |
| fib25 | 44 | 18.6 | 11.6 | 5.1 | 2.27x |

Known latent bugs surfaced by the guarded pop (reported once per run on stderr, harmless because the pop returns undefined and the function is kept out of the traces): a `return` at pc 32/149 and a `put_loc1` at pc 28 in three anonymous test functions pop from an empty stack — compiler stack-effect bugs in some try/finally or completion-value path; and `with` statements do not resolve identifiers against the object (reads throw ReferenceError; the conformance tests wrap them in try/catch). Both predate this work.

Remaining gap, and what would close it: property access (1.85x) is the per-access inline-cache path (about 15 loads and several branches vs QuickJS's shape compare + slot load); allocation (2x) is `JeffJSObject` size (~26 fields) plus the value array; fib/calls (1.5-2.3x) are frame bookkeeping (frame object acquire/release, 13-field call record) and one retain/release pair on frame acquire/release. QuickJS keeps its frame on the C stack with ~8 stores; matching that needs a frame-less inline call design where the JeffJSStackFrame object is materialised only when something observes it (closures, arguments, exceptions).

## Current standing (2026-09-05, end of round 3)

| kernel | baseline | day 1 | round 2 | now | jsc LLInt |
|---|---:|---:|---:|---:|---:|
| int-loop | 1754 | 877 | 585 | 602 | 148 |
| float-loop | 926 | 528 | 362 | 369 | 128 |
| calls | 1294 | 757 | 470 | 319 | 127 |
| prop-get-set | 998 | 407 | 335 | 341 | 99 |
| method-call | 1350 | 626 | 386 | 270 | 154 |
| alloc-objs | 699 | 330 | 205 | 197 | 37 |
| array-push | 823 | 311 | 230 | 254 | 72 |
| string-concat | 65 | 32 | 23 | 23 | 3.5 |
| closure | 740 | 482 | 331 | 220 | 79 |
| fib25 | 44 | 33 | 24 | 18.6 | 6.3 |

### Versus C QuickJS (2026-09-05 end of round 3, qjs 2026-06-04 from Homebrew, same kernels)

| kernel | JeffJS | QuickJS | ratio |
|---|---:|---:|---:|
| int-loop | 602 | 320 | 1.9x |
| float-loop | 369 | 175 | 2.1x |
| calls | 319 | 147 | 2.2x |
| prop-get-set | 341 | 139 | 2.4x |
| method-call | 270 | 127 | 2.1x |
| alloc-objs | 197 | 92 | 2.2x |
| array-push | 254 | 110 | 2.3x |
| string-concat | 23 | 11 | 2.1x |
| closure | 220 | 70 | 3.2x |
| fib25 | 18.6 | 5.2 | 3.6x |

Round 3 took calls from 3.3x to 2.2x and method calls from 3.1x to 2.1x. Everything except closures and recursion now sits at 1.9-2.4x of C QuickJS. The remaining gap is per-opcode dispatch cost (the lean trace runs ~2.3 ns/op vs ~1.2 for QuickJS's computed-goto loop) plus, for closures and recursion, the retain/release on the bytecode object and the var-ref array per call.

### Next (to reach parity)

1. Superinstructions for loops: `get_loc + push_i8 + lt` -> `lt_loc_i8`, `get_loc8_get_loc8 + add` -> `add_loc_loc`, `push_0 + or` -> `to_int32`, `get_loc + call` with args. Each fusion needs a compiler peephole, the opcode table, and handlers in the main loop AND both trace variants. The narrow opcode space (0-255) is full: move compile-time-only opcodes (scope_*, label_, enter/leave_scope) to the wide range first to free slots; wide opcodes deopt the trace. Expected: 30-40% on tight loops.
2. Calls: the bytecode object reference is retained/released three times per call (`fbFast` binding, `fb = ...` on entry and on return). unowned(unsafe) locals were measured slower three times; the remaining option is Unmanaged fields in the frame record with explicit `_withUnsafeGuaranteedRef` reads (closures must not capture interpreter locals).
3. Closures: `varRefs[idx]` retains the var-ref per access and the array per call; an `Unmanaged` element array cached on the function object would remove both.
4. Objects: `JeffJSObject` has ~26 stored properties; allocation is 2.2x QuickJS mostly from object size and the two arrays.

Measurement trap: `swift test` rebuilds every product in the package with testing enabled, which leaves a slower `jeffjs-cli` binary in `.build/release` (call-heavy kernels 15-25% worse). Always run `swift build -c release --product jeffjs-cli` (which `bench/run.sh` does) before timing.

Known flaky conformance test: `allLoaded18` (Promise.all + executePendingJobs) fails intermittently in every build including the pre-change baseline; likely hash-seed-dependent job ordering, unrelated to this work.

Profiling note: `sample` stopped producing output on 2026-09-05 (hangs or exits silently even by pid); the round-2 targets were chosen by reading bytecode dumps (`JEFFJS_DUMP=1`) and reasoning about the paths instead.

Next up, in order of expected payoff: object allocation (JeffJSObject has ~26 stored properties incl. closures; move rare fields to a side object, or pool objects), trace-native fused arithmetic on locals (`get_loc8_get_loc8 + add` -> one op), constructor calls on the inline path, define_field transition IC for object literals, frame objects (immortal pooled frames with unowned links to remove per-call ARC), superinstructions / cold-opcode split in the dispatch loop (phase 6).

## Round 8 (2026-09-06/07) — React re-render

Target: the React re-render burst in React Natively (`window.__bump()` x100 on a
page rendered by React 18 UMD + ReactDOM), measured on macOS with the app's real
`JSScriptEngine`, best of 12 rounds.

| build | ms per 100 re-renders |
| --- | --- |
| before | 40.2 |
| after | 31.1 |
| JavaScriptCore | 17.2 |

23% faster; the gap to JSC on this workload narrowed from 2.34x to 1.81x.

What the Time Profiler pointed at, in the order it was fixed:

1. **for-in built Swift Strings to deduplicate** (16% inclusive). `createForInIterator`
   formatted every integer key into a `String`, hashed it into a `Set<String>`, and
   re-interned the iterator's two internal slot names on every loop. It now
   deduplicates on interned identity (array index by value, everything else by
   atom) and holds the slot atoms on the context. Shadowing semantics are
   unchanged: a non-enumerable own property still hides an enumerable one on the
   prototype.
2. **`typeof` allocated a JS string per evaluation.** The eight possible results
   are interned on the runtime, like `intKeyStrings`. React's reconciler runs
   `typeof x === 'function'` constantly; this was the single biggest win.
3. **`setFunctionName` interned "name" and allocated a string per closure.** It
   uses the predefined atom and the per-atom cached string.
4. **`atomIsArrayIndex` re-parsed the atom's string on every property visit.**
   The index value is computed once at atom creation (`arrayIndexValue`).
5. **for-in deduplication hashed every key.** `Set<UInt32>` (SipHash + resize) is
   now a linear scan over a small array that promotes to a set past 48 keys.
6. **`newArrayFrom` went through the generic indexed setter per element**, each
   one interning an index atom and walking the prototype chain. It installs the
   element storage in one shot.
7. **The arguments object re-derived `Array.prototype[Symbol.iterator]`** on every
   creation, interning "Array" and walking three properties (and leaking two
   references). It uses the context's cached `arrayProtoValues`.

Correctness fixed along the way (each has conformance coverage or a differential
check against `qjs`):

- **`o[1]` and `o["1"]` were two different properties.** Numeric keys reached the
  tagged-int atom only from the integer path; a numeric *string* interned as an
  ordinary string atom. `JSON.stringify` of such an object emitted the key twice.
  `findAtom` now maps a canonical decimal index to the tagged-int atom, matching
  QuickJS's `__JS_AtomFromUInt32`, and `atomToString` renders tagged atoms (they
  previously read back as nil, so the bytecode cache serialised them as ""). New
  conformance group `NumericPropertyKeys`. **JFBC `compilerVersion` bumped to 6**,
  so precompiled bundles must be regenerated.
- **`Array.prototype.values !== Array.prototype[Symbol.iterator]`.** They are one
  function object now, and it is what the context caches.
- **Every builtin carried a junk self-named property instead of `name`.**
  `newCFunction` interned the function's own name as the property key, so
  `Object.getOwnPropertyNames([].map)` was `["map","length"]` and `[].map.name`
  was undefined.

Still open, found while profiling and not fixed:

- **User-defined functions have no own `length` or `name`.** Defining them
  eagerly would add two property definitions per closure creation, which is the
  hot path this round was trying to shrink; it wants a lazy own-property handler.
- **Symbol keys collide with their description.** `Symbol('s')` interns as the
  plain string atom `"s"`, so `obj[Symbol('s')]` is readable as `obj.s`, two
  symbols with the same description are one property, and the key shows up in
  `Object.keys`. Well-known symbols are fine (they have real symbol atoms).
- **`delete arr[i]` does not punch a hole** in a fast array (`i in arr` stays
  true), and **for-in over a primitive string enumerates nothing**.
- **`Object.getOwnPropertyDescriptor(arr, '0')`** returns undefined for fast-array
  elements.
- **Array.prototype.map is 23% of the re-render profile**, almost all of it the
  per-element `[JeffJSValue]` argument array and the generic indexed get/has/set.
  A fast path over the element storage plus a borrowed argument buffer is the
  next big lever.

### Round 8b (2026-09-07) — array callbacks and a native for-in iterator

Re-render burst (same bench as Round 8): **31.1 -> 27.5 ms per 100**, 1.59x
JavaScriptCore's interpreter (JSC with its JIT does it in 10.0 ms; on iOS
third-party apps never get that JIT). Real-world geomean **4.9x -> 4.61x**
QuickJS, all 38 kernels still byte-identical.

- **Array callback builtins** (`map`/`filter`/`forEach`/`every`/`some`/`find`/
  `findIndex`/`reduce`/`indexOf`/`includes`/`sort`) read a plain fast array's
  element storage in place through one `ElementCursor` (re-fetched per step,
  since callbacks may mutate the array) instead of a generic `has` + `get`
  per element, reuse one argument array per loop instead of allocating one
  per callback, and install `map`/`filter` results in one shot. `sort`'s
  default order compares code units instead of building two Swift Strings per
  comparison. Elements are pinned around the callback and released after a
  bytecode callee, the interpreter's own rule; before, every element read was
  leaked. `array-find-indexof` 9.9x -> 6.5x, `array-map-filter-reduce`
  7.2x -> 4.7x, `array-sort-comparator` 2.7x.
- **`releaseFrameU` drops `argBuf`** instead of `removeAll(keepingCapacity:)`
  on a buffer shared with the caller, which copied it on every return.
- **for-in is a native iterator with a per-shape key cache.** The iterator
  object carries a `JeffJSForInIterator` payload over a `JeffJSForInKeyList`;
  the old one stored the keys in a JS array under two internal properties and
  did five property operations per iteration (and leaked the keys array once
  per step). Each shape caches its own enumerable key list
  (`enumKeyCache`, dropped by every in-place mutation: append, delete, flag
  change, compaction, `prepareShapeUpdate`, GC teardown), so a loop over a
  plain object whose prototypes contribute nothing shares the cached list
  without building a key. `Object.keys`/`entries`/`assign` take the same
  cache. `for-in-entries` 8.4x -> 4.8x.

Profile after this round: `executeFastTraceLean` 41% + `callInternal` 20%
self, retain/release ~11%; `setPropertyInternal` 8.7% inclusive (property
adds on fresh objects), the arguments object 3.8%, the DOM bridge accessors
6.2%, payload-enum copy/destroy ~5%, `String.indexOf` + `toUTF16Array` 3%.

Found, not fixed: class prototype methods/getters and `Function.prototype`
methods are enumerable (for-in over an instance or a function lists them);
`@@hasInstance` enumerates as a string key; a native call leaks any
temporary argument its C callee does not store (`a.map(x => ...)` leaks the
arrow per call: the interpreter releases arguments only after bytecode
callees because some builtins hand borrowed arguments to ownership-taking
setters). The fix is to make every storing builtin dup and release after C
callees too, verified with `JEFFJS_ZOMBIES=1`.

### Round 8c (2026-09-07) — the rest of the browser-shaped hot paths

Re-render burst **27.5 -> 25.5 ms per 100** (1.47x JavaScriptCore's
interpreter; 40.2 at the start of Round 8). Real-world geomean **4.61x ->
~4.1-4.2x** QuickJS (run-to-run noise on this machine is about 0.1x), all 38
kernels byte-identical. Each item below shipped with conformance 1712/0, a
zombie scan over the leak and stress sets, and no RSS change.

- **Arguments objects share one transition shape per argument count** (sloppy
  and strict, counts 0...8). N + 3 transition lookups per creation became slot
  appends; length/callee/@@iterator are non-enumerable as the spec has them,
  so Object.keys / JSON / spread over `arguments` now see the indices only.
  `arguments-object` 5.8x -> 3.3x.
- **`bind` builds a real bound function** (JS_CLASS_BOUND_FUNCTION with the
  .boundFunction payload the call paths already unwrapped) instead of a Swift
  closure wrapped in a C function. `new` through a bound function works,
  instanceof unwraps to the target, length/name are right and non-enumerable,
  [[BoundThis]] is used as is.
- **Native calls stop copying the payload enum**: isCallable answers from the
  mirrored fbFast/cFuncFast fields, and callFunction checks cFuncFast before
  the bound-function payload match. **Arrays share the shape that holds
  length** (arrayShape was never populated, so every literal paid a
  root-shape lookup plus a transition). Re-render 27.0 -> 25.5 ms.
- **Shape transitions match by parent identity.** findHashedShape re-compared
  all N-1 earlier properties per add, so building an object with N keys was
  O(N^2); a hashed transition now records the shape it came from.
  `object-dictionary` 11.0x -> 3.3x.
- **String builtins read code units from the string's own storage** through a
  CodeUnits view (split, trim family, slice, substring, substr, indexOf,
  includes, startsWith, case mapping with an ASCII fast path). Every method
  used to widen Latin-1 into [UInt16] on entry and narrow on exit.
  `string-split-trim` 8.4x -> 6.0x.
- **Iterator protocol on atoms with a shared { value, done } shape**; the
  next method and result object leaked per step are released.
  `generators-iterators` 12.5x -> ~10.5x.
- **RegExp.exec caches group names** on the compiled pattern (it copied and
  re-parsed the bytecode per match) and shares the match-result shape.
  `regex-tokenize` 10.6x -> 9.5x.

Found, not fixed: `for..of` does not call the iterator's `return()` when the
loop body throws (only on `break`); `String.prototype.matchAll` results are
not iterable; the `groups` object of a match has Object.prototype instead of
a null prototype; `/./u` matches one code unit of a surrogate pair; a bound
function's `name` is "bound " because bytecode functions still have no own
`name`; sloppy-mode arguments do not alias parameters, `arguments.callee` does
not throw in strict mode, and `Object.prototype.toString` reports
`[object Object]` for arguments.

Next levers, from the profiles: `Function.prototype.call/apply` as
interpreter intrinsics (the kernel is per-call argument arrays, 7.4x);
the per-yield generator save/restore (`generatorResume` is 43% of that
kernel); the regex VM allocated per exec; proxies (8x); getters/setters
(7x, the accessor call path); and the structural items from Round 8:
`callInternal` self time, retain/release around it, and the payload-enum
copies still visible in every profile.

## Round 9 — argument ownership (leak fixes, perf-neutral)

Measured with `JEFFJS_TRACK_RC=1` (objects still alive at runtime teardown)
and `JEFFJS_ZOMBIES=1` (touches on freed objects, now printed with the
object pointer so free/dup traces can be matched). Real-world suite geomean
0.99x of Round 8c (noise), re-render 26.2 -> 26.4 ms, React page RSS
82 -> 71 MB. 1712/1712 conformance and the full suite pass under zombies.

- **One argument convention.** Every callee borrows its arguments and the
  caller releases them after the call — bytecode, C builtins, bound
  functions and proxies alike; generators and async functions are the one
  exception (they move the arguments into their saved state, see
  `jeffJS_calleeTakesArgs`). Before, only plain bytecode callees were
  released after, so every temporary passed to a native function leaked
  (`arr.map(x => ...)` kept 100k closures alive, `new Map()` leaked per
  call; `arr_map` 80 -> 18 MB). Builtins that keep an argument, return one,
  or return `this` now `dupValue()` it (Array ctor/of/push/unshift/concat/
  splice/toSpliced, Object.__defineGetter__/Setter__, iterator results,
  Reflect helpers, 18 `return this/arg` sites); `Promise.prototype.finally`
  retains its callback through `JeffJSRetainedValue`; generator objects own
  their `this` and function.
- **The trace interpreter's native fast paths never released arguments** —
  `call`/`call_method` freed the callee and `this` slots after
  `dispatchCFunction` and left the arg slots alone, so every argument to a
  builtin from a hot loop leaked under the old convention too
  (`JSON.stringify(o)`, `Reflect.get(o, k)`, `Object.is(o, o)` each pinned
  their arguments for the life of the runtime).
- **`ctx.toObject()` results are owned and were never released** in 62
  builtins (`Array.prototype.*`, `Object.keys/values/entries/assign/...`,
  `String.raw`): `[1,2,3].indexOf(2)`, `({}).hasOwnProperty()`,
  `Object.assign({}, src)` each leaked their receiver (`Object.assign` loop
  124 -> 18 MB). They now `defer { freeValue(obj) }` and dup on
  `return obj`; array iterators dup the target they store; `keysArr`/key
  strings in values/entries/assign/defineProperties are released.
- **Arrow functions.** Frames borrow the closure's captured `this` instead
  of dup'ing it on every call (the frame never released it, so each arrow
  call pinned `this`), the closure's own retain is released at teardown
  (pool recycle, freeObject, GC free), and the captured `this` is a real GC
  edge — the CPU mark and the Metal graph builder both see it (the Metal
  path now delegates to `markChildren` instead of a partial copy that had
  no payload edges at all).
- **Prototypes installed from borrowed arguments get a JS retain**
  (`Object.create`, `setPrototypeOf`, `newObjectProto`), and constructors
  release the pre-created `this` when a C or bytecode constructor returns
  its own object.


Found, not fixed:
- **Cycles are never collected during a run.** A self-referencing object
  held only through a `WeakRef` survives 200k further allocations on both
  GC paths, even with `JEFFJS_GC_MALLOCTHRESHOLD=1` (QuickJS reclaims it).
  Reference counting frees everything acyclic, but React-style trees
  (parent <-> child, instance <-> arrow handler) only go away with the
  runtime. This is pre-existing and the next memory item.
  *(Fixed in Round 10.)*
- `Reflect.construct(F, args, newTarget)` ignores `newTarget` (uses
  `callConstructor(_:args:)`, `callConstructor(_:newTarget:args:)` exists)
  and a script mixing it with `Object.create`/`setPrototypeOf` reports two
  zombies on the pre-session build as well.
- `EngineTests/testSuspectGroups` traps in `findHashedShapeProto` (shape
  table already torn down) when ErrorHandling runs after
  ES262CriticalSubset — identical on the pre-session commit; the test is
  the teardown investigation itself. *(Fixed in Round 10.)*
- `Object.assign` +6% and `bind-call-apply` +15% from the extra
  release work; `closure-creation` is unchanged once the zombie
  instrumentation is off.

## Round 10 — the cycle collector (memory)

`var o = {}; o.self = o` repeated 200 000 times, a React tree of
parent <-> child nodes, or an instance and the closure that captured it used
to survive every collection and only died with the runtime. They are
collected now.

- **Every JS object is on the GC list**, as quickjs's
  `JS_NewObjectFromShape` does with `add_gc_object`, and `js_trigger_gc` runs
  from `JeffJSObject.init` when the accounted heap crosses the threshold.
  `JS_RunGC` is the full four-phase algorithm: trial decrement, scan (rescue
  everything reachable from an externally referenced object, iteratively —
  a recursive rescue blows the stack on a long parent chain), **restore**
  (quickjs's `gc_scan_incref_child2`: give the unreachable set its counts back
  so the ordinary free path in phase 3 stays balanced — without it a live
  object referenced only by a dying one was left one count short and the next
  free took it), then free. Objects created while the intrinsics are being
  installed are deliberately *not* tracked: during init `freeValueSlow` lets
  refcounts fall to zero without freeing, so their counts do not describe
  reachability, and leaving them off the list makes every property of a
  prototype or of the global object an uncounted root edge — which is exactly
  what they are.
- **The mark set is exactly the counted edges.** Marking an edge that holds no
  refcount removes a reference nobody added, and the object dies while it is
  still in use. `obj.proto` and `shape.proto` are ARC strong references that
  `freeObject`/`freeShape` never release, so they are *not* GC edges (a dead
  class still collects through the constructor's `prototype` property). The
  set is: property data values, accessor getter/setter, an arrow's captured
  `this`, array elements, a typed array's buffer, a suspended generator's
  saved stack/locals/args/`this`/function, and captured var-refs. *Not*
  marking a counted edge is always safe — it leaks, it never over-frees.
- **Detached var-refs are graph nodes.** `var node = {}; node.cb =
  function () { return node; }` is what every render produces and it is only
  collectable if the closure -> var-ref -> object chain is an edge. Nothing
  maintains a var-ref's refcount (closures own them through ARC), so the
  collector seeds them to zero each run and lets phases 2 and 2b recompute the
  in-degree. Live var-refs read through their frame, which is a root, so only
  detached ones are listed (`close_var_refs` does the same).
- **Two bugs the collector exposed, both older than it.**
  `materializeFunctionPrototype` built its borrowed receiver with
  `mkPtr` (an *ARC* retain) and released it with `freeValue()` (a *refcount*
  decrement), so every function that materialised `F.prototype` lost one
  reference: `F` and its prototype became a self-contained garbage cycle while
  `F` was still a global, and `TextEncoder.prototype` went `undefined` the
  first time the collector ran. `JeffJSValue.borrowedObject` is the honest
  spelling and both materialisers use it. Separately, `gcFreeCycles` unlinked
  its victims by hand and so skipped the malloc accounting: `mallocSize`
  ratcheted up by one collection's worth of garbage per run, the trigger
  drifted with it, and peak RSS still grew linearly even though every cycle
  was being freed.
- **WeakRef and FinalizationRegistry observe a cycle free.** Their cells are
  registered with the runtime and cleared by `weakrefFree`; a `weak var` alone
  is not enough, because a collected object can still be allocated (another
  header holds an ARC reference, and `JEFFJS_ZOMBIES=1` keeps it alive on
  purpose).
- **Cost.** The GC lists are unretained (quickjs's intrusive `gc_obj_list`);
  `JeffJSGCObjectHeader.deinit` unlinks whatever reaches ARC deallocation
  while still listed. `markObject` skips the payload entirely for a plain
  object — both `_fastArrayValues` and `payload` are ARC-bearing reads. The
  threshold is quickjs's (256 KB floor, 1.5x the live heap), except that a run
  which reclaimed nothing doubles instead: `vdom-build-diff` grows to 700k
  live objects and finds no cycles at all. bench/realworld.js geomean 1.017x
  of the same-worktree base (worst kernel `vdom-build-diff` 1.34x, which is
  the collector walking a genuinely live 700k-object heap).
- **Results.** 200k self-cycles: peak RSS 91 -> 46 MB, live objects back to
  baseline (3577 -> 3578) after a forced collection. 10k-node parent <-> child
  tree with closures, dropped and rebuilt: 25/50/100 passes were
  481/942/1864 MB and are now 109/111/110 MB — flat. `JeffJSEnvironment.runGC()`
  and `gcStatistics` are public; the CLI exposes `__gc()` / `__gcStats()`.

### testSuspectGroups: a freed runtime handed to the next group

`EngineTests/testSuspectGroups` trapped in `findHashedShapeProto` when
ErrorHandling ran after ES262CriticalSubset. Four test groups end with
`ctx.rt.free()` on the *shared* runtime and leave `JeffJSTestRunner`'s cached
`_sharedRt`/`_sharedCtx` pointing at it, so the next group's `makeCtx()`
hands back a context whose runtime has been torn down. `runAllTests` hides it
by calling `cleanupSharedContext()` between groups; `testSuspectGroups` runs
them back to back and does not. They now tear down through
`cleanupSharedContext()`, which frees the context *before* the runtime and
drops the cache.

The engine side was two invariant repairs, so that an out-of-order teardown
degrades instead of trapping:
- `JeffJSRuntime.free()` leaves `shapeHashSize` behind when it empties
  `shapeHash`, and every shape lookup guards on `shapeHashSize > 0` and then
  indexes the array. That is an out-of-range trap, not a miss. The size is
  reset with the table.
- `clearGCState` now runs in dependency order — JS objects, then var-refs,
  then shapes — instead of interleaving the three in one pass, and holds a
  strong snapshot while it works: emptying one object drops ARC references
  that can deallocate another header in the same list.

Found, not fixed:
- **`arr.push(o)` leaks `o` when `o` holds a function.** 40 000 iterations of
  `arr.push({ type: "d", onClick: function () { return i; } })` followed by
  `arr = null` leave ~3 objects per iteration alive, and the collector agrees
  they are reachable, so it is a refcount leak and not a cycle. The same
  script without the array, or with a plain object in place of the closure,
  frees everything. Identical on the pre-round build (RSS 83 MB vs 93 MB), and
  it is what makes a `React.createElement` re-render microbenchmark regress
  ~30%: the collector rescans a heap the leak keeps large.
- **Rest parameters leak too** (`function f(a, ...rest)`: ~5 objects per call
  retained), same shape of bug.

## Round 11 — eight refcount leaks (memory)

Round 10 left two "found, not fixed" entries and guessed at their cause. Both
guesses were wrong, and looking for them turned up six more. Every one is the
same mistake in a different place: a reference was taken and never given back,
so the object stayed on the GC list forever and the cycle collector — which
sees an unaccounted count as an external root — dutifully reported it as
reachable. That is why the collector "agreed they were reachable": it was
right, and the extra reference was the bug.

The method used was a 20 000-iteration allocate-and-drop loop per shape with
`__gc()` and `__gcStats().liveObjects` on either side; a leak is a delta that
scales with the iteration count. `JEFFJS_TRACK_RC=1`'s per-class breakdown
then says *which* object, and its average refcount says how many counts too
many. `Tests/JeffJSTests/RefcountLeakTests.swift` is that loop as a test.

- **`if (obj)` was the expensive one, not `arr.push(obj)`.** Neither trace
  interpreter released the condition `if_false` / `if_true` / their 8-bit
  forms / `lnot` pop off the stack (the main dispatch loop always did). An
  `i < n` loop test is a bool and costs nothing; `if (node)`, `if (!a || !b)`
  and `!o` on an object each added a permanent reference to that object. A
  100-pass build-and-diff of a 5 000-node `createElement` tree ended with
  **2 478 690 live objects and 880 MB RSS — a whole tree leaked per pass, by
  the `if (!a || !b)` in `diff`** — and now ends with 28 098 (the one tree
  still referenced) and 41 MB.
- **The push fast path kept the array, not the element.** The main loop's
  `arr.push(x)` fast path popped three slots and released none; the element's
  reference legitimately moves into the array, but the callee and the receiver
  were the stack's. So the *array* became immortal and took everything in it
  with it. `arr.push(localVar)` was fine — that shape takes the fused
  get_field+push path, which does release the receiver — which is why Round 10
  read the leak as being about what was pushed.
- **`define_method` never released the function it stored.** `defineProperty`
  dups what it installs, so the popped function was the opcode's to release.
  Every object-literal method, getter and setter, and every class-body member,
  pinned its function; the function's `homeObject` back-reference then pinned
  the literal.
- **An accessor's getter and setter are counted edges.** `markObject` already
  marked them as such, but `freeObject` dropped only the property slot's ARC
  reference. Two hand-rolled prototype getters (TypedArray, Function) build
  their function with a bare `JeffJSObject()` and needed the ARC retain
  `makeObject` would have taken.
- **Redefining a property dropped the old value on the floor.**
  `setPropEntry` stores in place and releases nothing. `class C {}` hit it
  through the lazy `prototype`: installing `C.prototype` first materialises
  the constructor's own, and that orphaned object's `constructor` back-
  reference held the class forever — five objects per class evaluation.
- **`Object.defineProperty` never released the descriptor it read.** Every
  `getPropertyStr` in `definePropertyFromDescriptor` hands back a reference
  the function owns; none of `value` / `get` / `set` / `configurable` /
  `enumerable` / `writable` were released. `Object.defineProperties` dropped
  every (key, descriptor) pair it collected, and `__defineGetter__` /
  `__defineSetter__` leaked the key and the throwaway descriptor.
- **A dead Map/Set/WeakMap/WeakSet kept every key and value.**
  `mapStateInsert` dups both and `clear()`/`delete()` release them, but
  nothing did when the collection itself died.
- **Promise reactions were never released.** `.then(f)` builds a fulfill *and*
  a reject reaction; whichever one can no longer run was dropped without
  release, the reaction job released neither what it captured nor its dup of
  the settlement value, and a promise that died still pending took its queued
  reactions with it.

**Rest parameters do not leak** — `function f(a, ...rest)` in a 200k loop is
flat on the Round 10 tip. Round 10's reading of that measurement was the
`if (!x)` in the test harness, not the `rest` opcode.

**Cost.** bench/realworld.js geomean 1.025x of the same-worktree base, best
of five alternating runs; `vdom-build-diff` 1.010x. Exactly two kernels are
more than 4% slower, `closure-creation` (1.64x) and `tree-walk` (1.32x), and
without those two the geomean is 1.005x. Both are deallocation the leaks were
skipping, not new overhead:

- `closure-creation` is 1.64x when its 100 000 closures are dropped at the end
  of the kernel and **1.00x when the identical array is kept alive in a
  global** — same allocation, same calls, minus the teardown.
- `tree-walk` splits into build 27 -> 29 ms and walk 25 -> 24 ms; the whole
  56 -> 70 ms is freeing the previous pass's 65 538-object tree, which the tip
  leaked (and its RSS is 109 -> 53 MB).
- The condition release itself is ~1% on a 20M-iteration bool-condition loop
  and ~7% on an artificial 5M-iteration `if (obj)` loop that does nothing else.

What the leaks were costing, per kernel run: `vdom-build-diff` +118 772 live
objects (now +5), RSS 124 -> 49 MB; `tree-walk` +65 538 (now +5), RSS
109 -> 53 MB. The 100-pass re-render microbenchmark is 2308 -> 2434 ms for
2 478 690 -> 28 098 live objects and 880 -> 41 MB RSS. Per-object free is
~300 ns, which is now the thing worth optimising: with nothing leaking, the
suite spends real time in `freeObject`.

Found, not fixed:
- **`obj.proto` is dup'd but never released.** `newObjectProto`,
  `Object.create` and `setPrototypeOf` give the prototype a JS retain
  (Round 9), `freeObject` deliberately does not release `obj.proto` and
  `markObject` deliberately does not mark it (Round 10) — so every object
  created with an explicit prototype pins it forever. It is O(1) per
  prototype, not per instance, so a React app pays it once per class; it
  shows up as 2 objects per iteration only when the constructor itself is
  created in the loop. Fixing it means making `obj.proto` a fully counted
  edge, which is an audit of ~25 assignment sites where a missing dup is an
  over-free, so it is its own change. *(Fixed in Round 12: the reference
  belongs to the shape, one per shape.)*
- `Object.getOwnPropertyDescriptor(o, "g").get.name` is `"g"`; qjs says
  `"get g"`. Pre-existing.
- `({}).__defineGetter__` is not installed on `Object.prototype` (the builtin
  exists, the property does not), so the call throws. Pre-existing.

## Round 12 — one owner for the prototype (memory)

`obj.proto` was half of two models at once: `newObjectProto` / `Object.create`
/ `setPrototypeOf` took a JS reference *per object* that `freeObject` never
gave back, while `shape.proto` was an uncounted ARC alias that the collector
was told to ignore. So `Object.create(p)` run 100 000 times added 100 000
permanent counts to `p`, every instance pinned its class, and a dead class
hierarchy could only be collected by luck. The shape bug behind the
`RegExp.prototype` repair (829f9b2) was the same confusion from the other end.

**Shapes own the prototype, exactly one reference each** — quickjs's model
(`js_new_shape` dups, `js_free_shape` releases, `JS_SetPrototypeInternal`
re-shapes and swaps, `mark_children` reaches it through `js_shape_mark`).
`jeffJS_shapeSetProto` is the only writer; `createShape` and `cloneShapeRT`
take the reference, `freeShape` gives it back, `markChildren` marks it.
`obj.storedProto` stays as the uncounted mirror the prototype-chain walk
reads, and the object's claim on it is the owner count it already holds on
its shape. Because every `obj.proto = x` goes through the setter, which
re-shapes (`prepareShapeUpdate`) and then swaps the shape's reference, all
~35 assignment sites — `Reflect.setPrototypeOf` and the proxy fall-through,
which never dup'd, and `Object.create` / `newObjectProto` / `setPrototypeOf` /
`newObjectPrimitive` / the `matchAll` iterator, which dup'd per object — are
correct without touching any of them; the five stale dups were deleted.

- **`markObject` marks the shape** (quickjs: `mark_func(rt, &p->shape->
  header)`). Without it the prototype edge would hang off a node the
  collector treats as a permanent root: `shape.refCount` counts the objects
  on the shape, and those objects can all be garbage. `class B extends A {}`
  dropped in a loop leaked 4 objects per evaluation for exactly that reason.
  The collector still never *frees* a shape — hashed shapes stay cached at
  zero owners because the inline caches key on raw shape addresses — it only
  stops mistaking them for roots.
- **Three places dropped an owned prototype on the floor**, all invisible
  while `setPrototypeOf` dup'd for them: the `set_proto` opcode (which is how
  `class B extends A` sets both `B.prototype.__proto__` and `B.__proto__` —
  4 objects per class), `init_ctor`'s `getProperty(F, "prototype")`, and
  `defineClass`'s heritage and parent prototype.
- **A zero-owner hashed shape still holds its prototype's count**, so a
  prototype that is otherwise garbage is freed by the collector rather than by
  refcounting, and the cached shape is left pointing at a dead object that
  nothing can ever name again (it is inert: the shape table compares proto
  identity, and no live object can be on that shape). The tidy alternative —
  freeing hashed shapes at zero owners, as quickjs does — would recycle shape
  addresses that the inline caches compare by pointer.
- **Results** (`__gcStats().liveObjects` around 20k-iteration loops, and
  `JEFFJS_TRACK_RC=1` at exit). 100k `Object.create(p)` + 50k
  `setPrototypeOf` + 50k `class D extends Base`: 65 652 leaked objects and
  53 620 live at exit -> 3 149 and 3 628, which is the engine's own root set;
  the 100 000 instances' prototype now dies with them (`WeakRef.deref()` is
  `undefined` after `__gc()`, where it used to survive the runtime).
  Per iteration: `Object.create(shared)` 1 -> 0, `setPrototypeOf` 2 -> 0,
  `class A/class B extends A/new B()` 12 -> 0, `new F()` 2 -> 0.
  `Tests/JeffJSTests/RefcountLeakTests.swift` has eleven new cases plus the
  WeakRef one.
- **Cost.** bench/realworld.js geomean 1.000x of a same-worktree base
  (`class-hierarchy` 1.009x, `polymorphic-access` 1.004x, `getter-setter`
  1.004x, `object-assign-create` 0.988x, worst kernel +2%); bench/kernels.js
  1.003x (`method-call` 1.006x, `prop-get-set` 1.010x). The dup and release
  are per *shape*, not per object, so the allocation path is untouched.

Found, not fixed:
- **An accessor setter never releases its value argument.** `o.s = {…}` on a
  property with a setter — any setter, including `__proto__` — leaves one
  reference on the assigned object. Identical before this round; a plain
  method call with the same argument is flat.
- **The hashed shape cache grows with distinct prototypes.** A loop that
  builds a fresh prototype (or a fresh class *and* instantiates it) parks one
  hashed root shape per prototype, up to `shapes.maxHashed` (16 384), and
  those shapes are never evicted. It is bounded and pre-existing, but it is
  what a per-iteration "leak" of ~0.74 objects in those loops actually is.

## Round 13 — two collectors, one answer (hardening)

### The GPU collector was never run outside the app

`shouldUseMetalGC` needs a Metal library, a SwiftPM consumer has no default
one, and nothing said so — the CLI and the whole test suite quietly took the
CPU path however the flags were set. That is how the var-ref seeding bug
(Round 12's postscript) survived a day of green runs: only the app ever
executed the kernels.

- `JEFFJS_GC_METAL=1` now means "use the GPU collector", not "use it on big
  heaps": the crossover drops to zero unless `JEFFJS_GC_METALTHRESHOLD` names
  one, and the kernels are compiled out of the package resource bundle
  whenever a collector is pinned. `Scripts/run_tests.sh` runs the suite twice,
  once per collector, and diffs `Tests/gcstress/cycles.js` through the CLI on
  both.
- `MetalGCParityTests` runs thirteen heap shapes in two runtimes, one pinned
  to each collector, and compares the surviving object count *and* what JS
  still reads back out of the heap: self-cycles, a React-style tree with
  handlers, thirty closures over one var-ref, WeakRef/FinalizationRegistry,
  Map/Set with object keys, promise reaction cycles, class hierarchies,
  suspended generators and async frames, mapped arguments, bound functions,
  proxy<->target cycles, typed arrays, and DOM wrappers through
  `JeffJSEnvironment`. It fails rather than skips when the kernels will not
  load. **No divergence was found** — the seeding fix holds on all thirteen.
- The GPU path declines instead of guessing: `runMetalGC` returns false, and
  `runGC` re-runs the CPU collector on the same heap, when Metal is missing, a
  buffer will not allocate, a command buffer reports anything but `.completed`,
  or the rescue wavefront does not converge inside the iteration cap. It also
  honours `JEFFJS_GC_OFF` and logs under `JEFFJS_GC_DEBUG`.
- **Cost.** bench/realworld.js under `JEFFJS_GC_METAL=1` is 0.94x of the same
  binary on the CPU collector — inside the noise floor (see below). The test
  suite is not: 26.0s -> 48.5s, which is what thousands of collections on
  small heaps cost in GPU dispatch. The app's 5 000-object threshold is the
  right shape.

### One shared leak the parity work found

`FinalizationRegistry.prototype.register` did `entry.target = target.dupValue()`
— a counted edge that `js_finrec_mark` deliberately does not mark, so the
count could never be given back. A registered object was immortal and its
cleanup callback could never fire. `[[WeakRefTarget]]` is a weak slot; the
entry borrows it now and the weakref cell stays the authority on liveness.

### The collector sweeps the shape table

Nothing ever emptied it: `removeHashedShape` was reachable only from
`freeShape`, and `freeObject` refused to free a hashed shape at zero owners.
Because a shape owns one counted reference to its prototype (Round 12), a loop
that builds a fresh prototype parked one hashed root shape per prototype and
kept that prototype alive for the life of the runtime — the ~0.74 objects per
iteration Round 12 recorded and could not account for. Past `shapes.maxHashed`
(16 384) it got *worse*: insertion is skipped, so every later object builds a
private shape and every property access on it is a permanent IC miss.

White hashed shapes with no owners now go into the collection's dead set,
alongside the objects. They have to go *with* them, not after: a white shape's
prototype is white too, so a first attempt that swept after `runGC` left the
shape's `proto` pointing at freed memory and `JEFFJS_ZOMBIES=1` caught the
release immediately. `gcFreeDeadObjects` is exactly the protocol for a
mutually-dead group — it breaks every edge before it hands any allocation back.

Sweeping is safe against the inline caches, which compare shapes by raw
address, for three reasons that all had to hold: `refCount == 0` means no live
receiver can match an entry naming the shape (all four context-level shape
caches take a count — `plainObjectRootShape` did not, and now does); every IC
entry retains the shapes it names, so the allocation outlives the sweep and its
address cannot be recycled under a stale entry; and `removeHashedShape` clears
`isHashed`, which `jeffJS_icDefine` already checks before moving an object onto
a transition target. That last one is the invalidation, and it was already
there.

**Results** (60 000-iteration loops, `__gcStats().liveObjects` either side):
`Object.create(fresh)` 0.718 -> 0.000 per iteration, a fresh `class` per
iteration 0.000, `new F()` with a fresh constructor a flat +271 total. The
engine's own post-GC root set drops 4063 -> 2170. A polymorphic-read stress
over 12 000 prototypes swept 36 439 shapes, left the table at 55, and every
read was correct.

### Per-object free

`sample` on a 200-pass build-and-drop of a 16 383-node tree, top of stack:
`swift_release` 261, `swift_retain` 186, **`JeffJSObjectPayload`
copy/destroy/outlined-destroy 288 combined**, `freeObject` 125, malloc/free
255. Almost all of the payload traffic was `freeObject` reading the enum into a
local and writing `.opaque(nil)` back — a retain and a release of whatever
class the case carries, plus the `didSet` re-matching it, on *every object
freed*. A plain object has no payload edges (`markObject` returns on the same
class-ID compare), so it is skipped; `propExtra` gets the same treatment, and
the all-data-slots case is one tight loop.

`weakrefFree` was a dictionary probe on every free: `freeObject` and the
recycle pool asked `!rt.gcWeakRefMap.isEmpty` and then hashed an
`ObjectIdentifier`, so one live `WeakMap` entry anywhere put that probe on the
whole heap's teardown path. `weakrefNew` now sets the `firstWeakRef` marker
`isPoolable` was already testing for, and both call sites test the field.

Teardown microbenchmark: free-tree 878 -> 544 ms, free-plain 602 -> 570,
free-with-weakref 729 -> 625, free-accessors 738 -> 591.

### A word on the measurements

This machine had an unrelated `swift-frontend` at ~99% CPU throughout, and the
honest noise floor is large: the *same binary* benchmarked against *itself*,
best of five alternating runs, came out at 1.104x. Nothing below ~10% per
kernel from this session should be believed. With that caveat:
bench/realworld.js geomean 0.9839x of a same-worktree base at dcb4eab (best of
nine, 38 kernels), and the three kernels Round 11 flagged, re-measured on their
own with best of fifteen: `vdom-build-diff` 1.032x, `closure-creation` 0.964x,
`tree-walk` 0.935x.

### A dead prototype outlived by its cached shape

`JEFFJS_ZOMBIES=1` on the threes fixture reported 13 touches on freed values,
all while Google's tag script ran and all the same path: `gcFreeCycles ->
freeShape -> jeffJS_shapeSetProto` released a prototype that an *earlier*
collection had already freed. The prototypes were Closure-style classes
(`B.prototype = Object.create(A.prototype)`), built inside a function and
dropped.

A shape owns one counted reference to its prototype (Round 12), and a hashed
shape stays cached at zero owners. When a collection frees a prototype, every
shape naming it is unreachable too, but only "sweepable" shapes (hashed, zero
owners, table past `shapes.evictThreshold`) joined the dead set. A shape was
left behind in two cases: an instance was still on it when the dead set was
chosen (prototype and instance in one cycle), or the table was below the
threshold. That shape kept pointing at the freed prototype, and the sweep in a
later collection released it again. Outside zombie mode the second release
does nothing, because the freed header's `refCount` is -1, but the shape's ARC
reference still keeps the dead prototype allocated until the shape goes, and
the zombie report hid the real touches in noise. quickjs never gets into this
state, because `js_free_shape` frees a shape when its last owner dies.

The fix: a dead shape whose prototype is in the dead set joins it
(`jeffJS_shapeLosesProto`, in both the CPU and Metal collectors), and
`gcFreeDeadObjects` frees shapes after every other member, so the dying
instances bring the shape to zero owners first. A dead shape whose prototype
survives is still left to the eviction threshold, so a live class whose
instances die in cycles keeps its cached shapes. `FreedValueTouches` has three
new cases, each with a collection after every step. Zombie touches: threes
13 -> 0, hn and wiki 0 -> 0, apple 0 after the fix. (The base-build apple run
failed twice to compile because another agent was editing app files.) bench/realworld.js geomean 0.995x
(best of seven, worst kernel `tree-walk` 1.022x, which is inside the noise
floor above).
