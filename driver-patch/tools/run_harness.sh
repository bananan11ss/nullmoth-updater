#!/bin/bash
# Loads a built NVMTLDriver into a test process (nothing is installed) and runs every harness test.
# usage: tools/run_harness.sh [path/to/NVMTLDriver]   (default: out/NVMTLDriver)
set -u
cd "$(dirname "$0")/.."
BIN=${1:-out/NVMTLDriver}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
D=$W/NVMTLDriver.bundle/Contents/MacOS; mkdir -p "$D"
cp "$BIN" "$D/NVMTLDriver"
# the translator and AIR runtime are found next to the plugin; take the installed ones
cp /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvmtl_translate.dylib "$D/"
ditto /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime "$D/air-runtime"
# named "java" so the plugin takes this machine's java:KEY=value lines from nvrm610.conf, as Minecraft does
xcrun clang -fobjc-arc -O1 tools/nvmtl_harness.m -o "$W/java" -framework Foundation -framework Metal -framework IOKit || exit 1
fail=0
for t in compute handler nocopy events stress texup texlate texmany bandwidth; do
  "$W/java" "$D/NVMTLDriver" $t > "$W/out.txt" 2>&1; rc=$?
  printf '%-10s rc=%-3s %s\n' "$t" "$rc" "$(grep RESULT "$W/out.txt" | head -1)"
  [ $rc = 0 ] || fail=1
done
exit $fail
