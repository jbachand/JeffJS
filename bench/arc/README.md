# bench/arc

ARC-removal harness. `ir.sh <cli> <bench.js>` prints instructions retired / cycles / RSS (stable to +-0.05%, unlike wall time).
`check.sh <cli>` runs leaks/*.js in default, NO_POOL, ZOMBIES modes and compares output; prints RSS and TRACK_RC live objects.
`arc*.py` attribute Swift runtime (retain/release/...) samples from an xctrace time-profile export to file:line (see arcdump.py, arccat2.py).
`closure_loop_leak_repro.js`: pre-existing leak, out of scope. `baseline_1d88693.txt`: check.sh at the start.
