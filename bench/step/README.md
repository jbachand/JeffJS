# bench/step

Exact instruction profiles of `jeffjs-cli` without a debugger. `lldb`, `sample` and Instruments need Developer Tools
access on the Mac (a password dialog an agent cannot answer); these two libraries need nothing: they are injected with
`DYLD_INSERT_LIBRARIES` and inspect their own process.

`./build.sh` builds `libstep.dylib` and `libsample.dylib`. Measure a `swift build -c release` binary with a dSYM next to
it (`dsymutil .build/release/jeffjs-cli -o .build/release/jeffjs-cli.dSYM`); copy the binary, the dSYM and
`JeffJS_JeffJS.bundle` aside to keep a build for comparison.

## Instructions per iteration of a kernel (`mp.sh`)

`kernels/*.js` each define `f()`, warm it up twice, then run it once between two `Number.isSafeInteger(1)` calls. The
library puts a hardware breakpoint on that builtin and single-steps everything between the two hits, so the count is
exact and the same on every run (about 15 µs per instruction, a few seconds per kernel).

    bench/step/mp.sh .build/release/jeffjs-cli mytag            # every kernel: steps, steps per iteration
    bench/step/mp.sh .build/release/jeffjs-cli mytag calls fib  # some

Profiles land in `bench/step/out/<tag>.<kernel>.step`. Then:

- `stepmap.py <cli> <step-file> <JeffJSInterpreter.swift of that build> <iterations> [N]`: instructions per iteration
  by function, and inside the interpreter by the enclosing `case .op` label. `None` is compiler-generated code
  without a source line (spills, reloads, register moves); `invalid` is the switch dispatch itself.
- `hot.py <cli> <step-file> <iterations> [min per iteration]`: the executed instructions in address order with their
  count per iteration and source line.
- `seq.py <cli> <seq-file> [max lines]`: one loop iteration in execution order. Record it with `STEP_SEQ=<file>` and
  a small `STEP_MAX` (see the header of `step.c` for every variable).

To compare two builds, run `mp.sh` on both and diff the `stepmap.py` tables: a register that moved out of the dispatch
loop shows up as a few instructions on every opcode, with no difference in the source.

## Where the time goes on a long run (`libsample.dylib`)

    SAMPLE_OUT=/tmp/rw.smp DYLD_INSERT_LIBRARIES=bench/step/libsample.dylib .build/release/jeffjs-cli bench/realworld.js
    python3 bench/step/smp.py .build/release/jeffjs-cli /tmp/rw.smp 30
    python3 bench/step/smpfn.py .build/release/jeffjs-cli /tmp/rw.smp callInternalRaw Sources/JeffJS/Bytecode/JeffJSInterpreter.swift

A thread suspends the main thread every `SAMPLE_US` microseconds (default 500), reads its pc and resumes it.
`smp.py` prints self time by function, the library symbols behind the time spent outside the executable
(`swift_retain`, `_xzm_free`, ...) and time by the engine function on the stack; `smpfn.py` breaks one function down by
`case .op` label and source line. Wall-clock sampling: use it for shares, and `bench/arc/ir.sh` or `mp.sh` for
before/after numbers.

## Notes

- The single-step handler runs on its own thread through the task's breakpoint exception port. The kernel clears the
  single-step bit on every step, so the handler re-arms it; a few exceptions arrive without progress and are skipped
  (`stray` in the output).
- The CLI evaluates scripts on the main thread; `pthread_create` is interposed so other threads get the breakpoint too.
- A real `brk` (a Swift trap) ends the profile with `brk` as the reason instead of looping on it.
