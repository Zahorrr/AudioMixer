#!/bin/bash
# AudioMixer installer
# curl -fsSL https://raw.githubusercontent.com/Zahorrr/AudioMixer/main/install.sh | bash
set -euo pipefail

URL="https://github.com/Zahorrr/AudioMixer/releases/latest/download/AudioMixer.pkg"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "AudioMixer only runs on macOS." >&2; exit 1
fi

os=$(sw_vers -productVersion)
IFS=. read -r major minor _ <<< "$os.0"
if (( major < 14 || (major == 14 && minor < 2) )); then
  echo "AudioMixer needs macOS 14.2 or later (you have $os)." >&2; exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "→ Downloading AudioMixer…"
curl -fL --progress-bar "$URL" -o "$tmp/AudioMixer.pkg"

echo "→ Installing to /Applications (your password may be requested)…"
sudo installer -pkg "$tmp/AudioMixer.pkg" -target / >/dev/null

echo "✓ AudioMixer is installed and running — look for the sliders icon in your menu bar."
