#!/bin/sh
# Checks the git safety inspection against real repositories (needs git).
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/dcc-git-test"
mkdir -p "$OUT"
cp macos/Tests/git_main.swift "$OUT/main.swift"   # top-level code must live in a file named main.swift
swiftc -swift-version 5 -target arm64-apple-macos15.0 macos/Sources/GitCheck.swift macos/Sources/ProcessRunner.swift "$OUT/main.swift" -o "$OUT/check"
"$OUT/check" "$OUT/work"
