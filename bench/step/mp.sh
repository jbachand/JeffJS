#!/bin/bash
# mp.sh <cli> <tag> [kernels...]: instructions per iteration of each marker kernel (bench/step/kernels/*.js), counted between two
# Number.isSafeInteger(1) calls by single-stepping. Step files: step/out/<tag>.<kernel>.step
S="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$S/out"; CLI="$1"; TAG="$2"; shift 2
A=$(nm -n "$CLI" | awk 'index($3,"_$s6JeffJS0A15JSBuiltinNumberV13isSafeInteger")==1 {print $1; exit}')
[ -n "$A" ] || { echo "marker symbol not found" >&2; exit 1; }
iters() { case $1 in fib) echo 3193;; classnew|mapset|spread) echo 300;; *) echo 3000;; esac; }
for js in "$S"/kernels/*.js; do
  k=$(basename "$js" .js)
  if [ $# -gt 0 ]; then case " $* " in *" $k "*) ;; *) continue;; esac; fi
  o="$S/out/$TAG.$k.step"; rm -f "$o"
  STEP_OUT="$o" STEP_ADDR=$A STEP_BETWEEN=1 STEP_MAX=${STEP_MAX:-12000000} DYLD_INSERT_LIBRARIES=$S/libstep.dylib "$CLI" "$js" >/dev/null 2>"$o.err"
  steps=$(sed -n 2p "$o" 2>/dev/null | awk '{print $2}'); why=$(sed -n 2p "$o" 2>/dev/null | awk '{print $3}')
  if [ "${steps:-0}" -lt 2000 ]; then   # a rare false marker hit right after the first: run it again
    STEP_OUT="$o" STEP_ADDR=$A STEP_BETWEEN=1 STEP_MAX=${STEP_MAX:-12000000} DYLD_INSERT_LIBRARIES=$S/libstep.dylib "$CLI" "$js" >/dev/null 2>"$o.err"
    steps=$(sed -n 2p "$o" 2>/dev/null | awk '{print $2}'); why=$(sed -n 2p "$o" 2>/dev/null | awk '{print $3}')
  fi
  if [ -n "$steps" ]; then printf "%-11s %9d steps %8.1f/iter %s\n" $k $steps $(echo "$steps $(iters $k)" | awk '{print $1/$2}') "$([ "$why" = marker ] || echo "($why)")"; else echo "$k: failed: $(head -c 200 "$o.err")"; fi
done
