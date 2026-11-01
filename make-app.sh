#!/bin/sh
# Builds the Zig core, then the SwiftUI menu bar app, into app/DevCacheClean.app
set -e
cd "$(dirname "$0")"
./build.sh
APP=app/DevCacheClean.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -import-objc-header include/dcc.h \
  macos/Sources/*.swift zig-out/lib/dcc.o \
  -o "$APP/Contents/MacOS/DevCacheClean"
cp macos/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
[ -f macos/Resources/AppIcon.icns ] && cp macos/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
