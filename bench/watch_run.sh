#!/bin/sh
# Watch interpreter speed benches: instructions retired / cycles per file
# (load-independent; the Mac is shared) for a jeffjs-cli, plus wall times.
#   bench/watch_run.sh [path/to/jeffjs-cli] [KEY=VALUE ...]
cd "$(dirname "$0")/.."
CLI="${1:-.build/release/jeffjs-cli}"; [ $# -gt 0 ] && shift
for f in bench/watch_deepmerge.js bench/watch_iter.js bench/watch_callbacks.js bench/kernels.js bench/realworld.js; do
  env "$@" /usr/bin/time -l "$CLI" "$f" > /tmp/watch_run.out 2> /tmp/watch_run.err
  awk -v f="$f" '/instructions retired/{i=$1}/cycles elapsed/{c=$1}END{printf "%-28s %8.2f Ginstr %7.2f Gcyc\n", f, i/1e9, c/1e9}' /tmp/watch_run.err
done
