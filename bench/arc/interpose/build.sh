#!/bin/sh
# Builds libcnt.dylib, which counts swift_retain/release/bridgeObject* calls by call site (return address + 2 callers).
cd "$(dirname "$0")" && clang -dynamiclib -O2 -fno-omit-frame-pointer -o libcnt.dylib cnt.c -Wl,-undefined,dynamic_lookup
