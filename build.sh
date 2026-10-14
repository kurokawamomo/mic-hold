#!/bin/sh
# Builds /Applications/MicHold.app. The ad-hoc signature changes on every build, so permissions must be granted again.
set -eu
cd "$(dirname "$0")"
APP="/Applications/MicHold.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp MicHold.icns "$APP/Contents/Resources/MicHold.icns"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/MicHold"
codesign --force --sign - "$APP"
echo "$APP"
