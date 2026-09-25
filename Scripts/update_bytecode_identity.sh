#!/bin/bash
# Recomputes JeffJSBytecodeCache.engineSourceHash: FNV-1a 64 over the engine's
# bytecode-relevant sources (Parser/*.swift, Bytecode/JeffJSCompiler.swift,
# Bytecode/JeffJSOpcodes.swift, Bytecode/JeffJSBytecodeCache.swift minus the
# line holding the constant), in that sorted path order, each as
# "<relative path>\0<contents>\0". The value names the disk cache directory,
# so a parser/compiler change never reads blobs written by the engine before
# it. BytecodeCacheBudgetTests.testEngineSourceHashIsCurrent checks it.
#   Scripts/update_bytecode_identity.sh [--check]
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import sys, glob, re
root = "Sources/JeffJS/"
files = sorted(glob.glob(root + "Parser/*.swift")) + [root + "Bytecode/JeffJSBytecodeCache.swift",
         root + "Bytecode/JeffJSCompiler.swift", root + "Bytecode/JeffJSOpcodes.swift"]
files = sorted(files)
marker = "// bytecode-identity"
h = 0xcbf29ce484222325
def mix(bs):
    global h
    for b in bs:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
for f in files:
    text = open(f, "rb").read().decode("utf-8")
    lines = [l for l in text.split("\n") if marker not in l]
    mix(f[len(root):].encode() + b"\0")
    mix("\n".join(lines).encode("utf-8") + b"\0")
value = "0x%016x" % h
cache = root + "Bytecode/JeffJSBytecodeCache.swift"
src = open(cache).read()
m = re.search(r"static let engineSourceHash: UInt64 = (0x[0-9a-fA-F]+) " + re.escape(marker), src)
if not m: sys.exit("engineSourceHash line not found in " + cache)
if "--check" in sys.argv:
    print(("current " if m.group(1).lower() == value else "STALE ") + m.group(1) + " computed " + value)
    sys.exit(0 if m.group(1).lower() == value else 1)
open(cache, "w").write(src.replace(m.group(0), "static let engineSourceHash: UInt64 = " + value + " " + marker))
print("engineSourceHash = " + value)
PY
