# bench/arc

ARC-removal harness. `ir.sh <cli> <bench.js>` prints instructions retired / cycles / RSS (stable to +-0.05%, unlike wall time).
`check.sh <cli>` runs leaks/*.js in default, NO_POOL, ZOMBIES modes and compares output; prints RSS and TRACK_RC live objects.
`arc*.py` attribute Swift runtime (retain/release/...) samples from an xctrace time-profile export to file:line (see arcdump.py, arccat2.py).
`closure_loop_leak_repro.js`: pre-existing leak, out of scope. `baseline_1d88693.txt`: check.sh at the start.

## Exact dynamic ARC counts (interpose/)
`interpose/build.sh` builds `libcnt.dylib`. Then:
`CNT_OUT=/tmp/x.cnt DYLD_INSERT_LIBRARIES=bench/arc/interpose/libcnt.dylib .build/release/jeffjs-cli bench/watch_callbacks.js`
`python3 bench/arc/interpose/rep.py .build/release/jeffjs-cli /tmp/x.cnt 60` lists the hottest sites (retain/release/bridgeRetain/bridgeRelease counts, file:line, 2 callers).
`diff.py`/`difflines.py <cli_a> <a.cnt> <cli_b> <b.cnt> N` compare two builds by function / source line (needs the debug info of both binaries, so keep each build's .o files or compare right after building).
