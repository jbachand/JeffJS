#!/bin/sh
# usage: check.sh <jeffjs-cli>   Runs leaks/*.js in default, NO_POOL, ZOMBIES, both modes; compares output, flags ZOMBIE lines, prints RSS and TRACK_RC live-object total.
CLI=${1:?cli}; D=$(dirname "$0")/leaks; fail=0
for f in $D/*.js; do
  n=$(basename $f .js)
  ref=$(JEFFJS_NO_POOL=1 $CLI $f 2>&1 | tail -1)
  for mode in "" "JEFFJS_NO_POOL=1" "JEFFJS_ZOMBIES=1" "JEFFJS_ZOMBIES=1 JEFFJS_NO_POOL=1"; do
    out=$(env $mode $CLI $f 2>&1)
    last=$(echo "$out" | grep -v ZOMBIE | tail -1)
    z=$(echo "$out" | grep -c ZOMBIE)
    [ "$last" = "$ref" ] && [ "$z" = 0 ] || { echo "FAIL $n [$mode] zombies=$z out=$last ref=$ref"; fail=1; }
  done
  rss=$(/usr/bin/time -l $CLI $f 2>&1 >/dev/null | awk '/maximum res/{printf "%d", $1/1e6}')
  live=$(JEFFJS_TRACK_RC=1 $CLI $f 2>&1 | grep -o '[0-9]* objects' | awk '{s+=$1} END{print s}')
  echo "$n: result=$ref rss=${rss}MB live_objects=$live"
done
exit $fail
