#!/bin/sh
# Regenerates macos/Resources/AppIcon.icns from docs/img/app-icon.svg (the .icns is committed).
set -e
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
swift tools/render-icon.swift docs/img/app-icon.svg "$TMP/AppIcon.iconset"
mkdir -p macos/Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o macos/Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote macos/Resources/AppIcon.icns"
