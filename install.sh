#!/bin/sh
# Installs MicHold from a zip made by package.sh: the app into /Applications, whisper into ~/MicHold, and the config.
set -eu
cd "$(dirname "$0")"
mkdir -p "$HOME/MicHold" "$HOME/.config/michold"
cp -R whisper "$HOME/MicHold/"
chmod +x "$HOME/MicHold/whisper/whisper-server"
rm -rf /Applications/MicHold.app
cp -R MicHold.app /Applications/
xattr -dr com.apple.quarantine /Applications/MicHold.app "$HOME/MicHold" 2>/dev/null || true
vad=""; [ -f whisper/vad.bin ] && vad=",
  \"vadModel\": \"$HOME/MicHold/whisper/vad.bin\""
cat > "$HOME/.config/michold/config.json" <<JSON
{
  "serverBin": "$HOME/MicHold/whisper/whisper-server",
  "model": "$HOME/MicHold/whisper/model.bin"$vad,
  "language": "ja",
  "idleSeconds": 120
}
JSON
echo "Installed. Open /Applications/MicHold.app, then allow Microphone, Accessibility and Input Monitoring in System Settings."
echo "Log: ~/Library/Logs/MicHold.log"
