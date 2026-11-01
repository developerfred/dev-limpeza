#!/bin/sh
# Builds the CLI and the C-ABI object. Needs Zig 0.17+ (set ZIG to override the binary).
set -e
cd "$(dirname "$0")"
ZIG="${ZIG:-zig}"
mkdir -p zig-out/bin zig-out/lib
FLAGS="-O ReleaseFast"
"$ZIG" build-exe src/main.zig $FLAGS -femit-bin=zig-out/bin/dev-cache-clean
# Linked as a plain object: Apple ld rejects Zig-built .a archives (members not 8-byte aligned).
"$ZIG" build-obj src/lib.zig $FLAGS -fcompiler-rt -femit-bin=zig-out/lib/dcc.o
