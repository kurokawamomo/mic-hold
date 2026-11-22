#!/bin/sh
# Makes a zip to install MicHold on another Mac, Intel by default: the universal app, whisper-server built for
# that CPU, the models from your config, and install.sh. Run it on a Mac where MicHold already works.
#   WHISPER_SRC=/path/to/whisper.cpp ./package.sh            -> dist/MicHold-x86_64.zip
#   ARCH=arm64 WHISPER_SRC=/path/to/whisper.cpp ./package.sh  -> dist/MicHold-arm64.zip
set -eu
cd "$(dirname "$0")"
ARCH="${ARCH:-x86_64}"
: "${WHISPER_SRC:?set WHISPER_SRC to a whisper.cpp checkout}"
CONFIG="${CONFIG:-$HOME/.config/michold/config.json}"
[ -f "$CONFIG" ] || CONFIG="$HOME/.config/qd/voice.json" # the same fallback as the app
model=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$CONFIG")
vad=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("vadModel", ""))' "$CONFIG")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PKG="$TMP/MicHold"
mkdir -p "$PKG/whisper" dist

APP="$PKG/MicHold.app" ./build.sh >/dev/null

# whisper-server for the target CPU, linked statically (no GPU on Intel)
cpu="-DGGML_METAL=ON"
[ "$ARCH" = x86_64 ] && cpu="-DGGML_METAL=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON" # Intel Macs from 2013 on
# shellcheck disable=SC2086
cmake -S "$WHISPER_SRC" -B "$TMP/whisper-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF $cpu -DWHISPER_BUILD_TESTS=OFF >/dev/null
cmake --build "$TMP/whisper-build" --target whisper-server -j 8 >/dev/null
cp "$TMP/whisper-build/bin/whisper-server" "$PKG/whisper/"

cp "$model" "$PKG/whisper/model.bin"
[ -n "$vad" ] && cp "$vad" "$PKG/whisper/vad.bin"
cp install.sh "$PKG/"
ditto -c -k --keepParent "$PKG" "dist/MicHold-$ARCH.zip"
echo "dist/MicHold-$ARCH.zip"
