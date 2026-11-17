#!/bin/sh
# Builds libstep.dylib (single-step instruction profiler) and libsample.dylib (in-process pc sampler).
cd "$(dirname "$0")" && clang -O2 -dynamiclib -o libstep.dylib step.c && clang -O2 -dynamiclib -o libsample.dylib sample.c
