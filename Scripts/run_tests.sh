#!/bin/bash
# Runs the JeffJS test suite under BOTH cycle collectors.
#
# The app runs the Metal collector above `gc.metalThreshold` (5 000 objects);
# a SwiftPM consumer has no Metal default library, so the CLI and the test
# suite silently ran the CPU collector only — which is how a var-ref seeding
# bug that rendered a page blank survived a green suite for a day.
# `JEFFJS_GC_METAL=1` compiles the kernels out of the package resource bundle
# and drops the crossover to zero, so the second pass below collects every
# heap the first pass collected, on the GPU.
#
# Usage:
#   Scripts/run_tests.sh [release|debug] [--filter <pattern>] [extra swift test args...]
set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in
  release) shift; CFG=(-c release) ;;
  debug)   shift; CFG=(-c debug) ;;
  *)       CFG=(-c release) ;;
esac

# No separate --build-tests step: in release that builds JeffJS without
# -enable-testing and every `@testable import` then fails. `swift test` gets
# it right, and the second pass below is incremental.
status=0
for collector in cpu metal; do
  echo
  echo "======================================================================"
  echo "==> $collector collector ($CONFIG)"
  echo "======================================================================"
  if [ "$collector" = metal ]; then
    env JEFFJS_GC_METAL=1 swift test "${CFG[@]}" "$@"
  else
    swift test "${CFG[@]}" "$@"
  fi
  rc=$?
  [ $rc -eq 0 ] || { echo "!! $collector collector: swift test exited $rc"; status=1; }
done

# The GC stress scripts go through the CLI, which is where the app-shaped
# heaps (DOM wrappers, a React render loop) actually live.
echo
echo "==> GC stress scripts under both collectors"
swift build "${CFG[@]}" --product jeffjs-cli || exit 1
CLI=".build/$CONFIG/jeffjs-cli"
for script in Tests/gcstress/*.js; do
  [ -f "$script" ] || continue
  a=$("$CLI" "$script" 2>&1)
  b=$(JEFFJS_GC_METAL=1 "$CLI" "$script" 2>&1)
  if [ "$a" = "$b" ]; then
    echo "OK   $(basename "$script")"
  else
    echo "DIFF $(basename "$script")"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20
    status=1
  fi
done

exit $status
