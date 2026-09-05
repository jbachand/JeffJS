#!/bin/sh
# Runs bench/kernels.js under JeffJS (release) and, if available, the system
# jsc with and without its JITs. Prints milliseconds per kernel side by side.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product jeffjs-cli 2>&1 | grep -E "error" || true
CLI=.build/release/jeffjs-cli
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
tmp=$(mktemp -d)
$CLI bench/kernels.js > "$tmp/jeffjs.txt"
if [ -x "$JSC" ]; then
  "$JSC" --useJIT=false bench/kernels.js > "$tmp/llint.txt"
  "$JSC" bench/kernels.js > "$tmp/jit.txt"
  printf "%-15s %10s %10s %10s %8s\n" kernel JeffJS jsc-LLInt jsc-JIT "vs LLInt"
  paste "$tmp/jeffjs.txt" "$tmp/llint.txt" "$tmp/jit.txt" | awk -F'\t' '{ printf "%-15s %10.1f %10.1f %10.1f %7.1fx\n", $1, $2, $4, $6, $2/$4 }'
else
  printf "%-15s %10s\n" kernel JeffJS
  awk -F'\t' '{ printf "%-15s %10.1f\n", $1, $2 }' "$tmp/jeffjs.txt"
fi
rm -rf "$tmp"
