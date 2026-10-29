#!/bin/zsh
# The official WebAssembly 2.0 spec testsuite (WebAssembly/spec tag wg-2.0, test/core/*.wast,
# SIMD excluded) against jeffjs-cli, with node as the reference (issue #13).
#   Scripts/wasm_spectest.sh [name ...]      e.g. Scripts/wasm_spectest.sh memory_grow linking
# Needs wabt (brew install wabt: wast2json) and node. Work files go to $WASM_SPECTEST_DIR
# (default $TMPDIR/jeffjs-wasm-spectest). Each .wast becomes a JS script (Scripts/wasm_spectest_gen.js)
# that prints "<name> PASS n FAIL m SKIP k"; a line is printed when JeffJS and node differ.
# Known differences, all node's: V8 implements post-2.0 proposals (multi-memory, extended constant
# expressions), so a few assert_invalid cases fail in node only; conversions.wast has 8 cases that
# pass a NaN payload through JS (implementation-defined: JeffJS canonicalises NaNs read from typed
# arrays as JSC does, V8 keeps some payloads and fails 4 of them); data, elem and global
# each have 2 "unknown global" assert_invalid cases both engines accept (extended constants).
set -eu
ROOT=${0:a:h:h}
W=${WASM_SPECTEST_DIR:-${TMPDIR:-/tmp}/jeffjs-wasm-spectest}
mkdir -p $W
[ -d $W/spec ] || git clone -q --depth 1 --branch wg-2.0 https://github.com/WebAssembly/spec.git $W/spec
if [ ! -d $W/json ]; then
  for f in $W/spec/test/core/*.wast; do n=$(basename $f .wast); mkdir -p $W/json/$n; wast2json $f -o $W/json/$n/$n.json; done
fi
[ -d $W/js ] || node $ROOT/Scripts/wasm_spectest_gen.js $W/json $W/js
(cd $ROOT && swift build -c release --product jeffjs-cli >/dev/null 2>&1)
CLI=$ROOT/.build/release/jeffjs-cli
mkdir -p $W/out
names=("$@"); [ ${#names} -eq 0 ] && names=($(ls $W/js | sed 's/\.js$//'))
pass=0; fail=0; diffs=0
for n in $names; do
  timeout 60 node $W/js/$n.js > $W/out/$n.node 2>&1 || true
  timeout 120 $CLI $W/js/$n.js > $W/out/$n.jj 2>&1 || true
  j=$(grep -m1 " PASS " $W/out/$n.jj || echo "$n CRASH"); o=$(head -1 $W/out/$n.node)
  set -- ${=j}; [ "$2" = PASS ] && { pass=$((pass + $3)); fail=$((fail + $5)); }
  [ "$j" != "$o" ] && { echo "$j   (node: $o)"; diffs=$((diffs + 1)); }
done
echo "jeffjs: $pass passed, $fail failed; $diffs of ${#names} files differ from node (details in $W/out)"
