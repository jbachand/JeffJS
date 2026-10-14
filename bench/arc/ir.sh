#!/bin/sh
# usage: ir.sh cli bench  -> instructions retired (millions), cycles (millions)
/usr/bin/time -l "$1" "$2" 2>&1 >/dev/null | awk '/instructions retired/{i=$1} /cycles elapsed/{c=$1} /maximum resident/{r=$1} END{printf "%8.0fM instr %8.0fM cyc  rss %dMB\n", i/1e6, c/1e6, r/1e6}'
