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
# The release workflow passes VERSION (the tag without the "v"); local builds get 0.0.0.
VERSION="${VERSION:-0.0.0}"
case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) VERSION="0.0.0" ;; esac
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
[ -f macos/Resources/AppIcon.icns ] && cp macos/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
