#!/bin/sh
# Builds /Applications/MicHold.app (or $APP) as a universal app: one binary for Apple silicon and Intel Macs.
# The app is put together and signed in a temporary folder, then copied, so a synced folder such as Desktop
# cannot add attributes that codesign refuses. The ad-hoc signature changes on every build, so permissions
# must be granted again.
set -eu
cd "$(dirname "$0")"
APP="${APP:-/Applications/MicHold.app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/MicHold.app"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp Info.plist "$OUT/Contents/Info.plist"
cp MicHold.icns "$OUT/Contents/Resources/MicHold.icns"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12" main.swift -o "$TMP/MicHold-$arch"
done
lipo -create "$TMP/MicHold-arm64" "$TMP/MicHold-x86_64" -output "$OUT/Contents/MacOS/MicHold"
codesign --force --sign - "$OUT"
rm -rf "$APP"
ditto --norsrc --noextattr "$OUT" "$APP"
echo "$APP"
