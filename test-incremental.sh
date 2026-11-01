#!/bin/sh
# Verifies that incremental rescans match full scans. Needs the Zig object (./build.sh first).
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/dcc-incremental-test"
mkdir -p "$OUT"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -import-objc-header include/dcc.h \
  macos/Sources/Model.swift macos/Sources/IncrementalCache.swift macos/Sources/GitCheck.swift macos/Tests/main.swift \
  zig-out/lib/dcc.o -o "$OUT/check"
DCC_CACHE_FILE="$OUT/size-cache.json" "$OUT/check" "$OUT/work"
