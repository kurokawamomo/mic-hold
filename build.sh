#!/bin/sh
# Builds /Applications/MicHold.app (or $APP) as a universal app: one binary for Apple silicon and Intel Macs.
# The ad-hoc signature changes on every build, so permissions must be granted again.
set -eu
cd "$(dirname "$0")"
APP="${APP:-/Applications/MicHold.app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp MicHold.icns "$APP/Contents/Resources/MicHold.icns"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12" main.swift -o "$TMP/MicHold-$arch"
done
lipo -create "$TMP/MicHold-arm64" "$TMP/MicHold-x86_64" -output "$APP/Contents/MacOS/MicHold"
codesign --force --sign - "$APP"
echo "$APP"
