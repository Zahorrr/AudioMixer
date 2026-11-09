#!/bin/bash
# scripts/build.sh          -> compile build/AudioMixer.app (architecture du Mac)
# scripts/build.sh install  -> compile + installe dans /Applications + lance
# scripts/build.sh pkg      -> compile en universel (Apple Silicon + Intel) + crée dist/AudioMixer.pkg
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP=build/AudioMixer.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$MODE" == "pkg" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
BINS=()
for arch in "${ARCHS[@]}"; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.2" \
    Sources/*.swift \
    -o "build/AudioMixer-$arch"
  BINS+=("build/AudioMixer-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/AudioMixer"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "✅ $APP ($(lipo -archs "$APP/Contents/MacOS/AudioMixer"))"

if [[ "$MODE" == "install" ]]; then
  pkill -x AudioMixer 2>/dev/null || true
  sleep 0.5
  DEST=/Applications/AudioMixer.app
  rm -rf "$HOME/Applications/AudioMixer.app" 2>/dev/null || true
  # Mise à jour EN PLACE : on ne supprime jamais le bundle (macOS le bloque)
  if ditto "$APP" "$DEST"; then
    touch "$DEST"
    open "$DEST"
    echo "✅ installé dans $DEST et lancé"
  else
    echo "⚠️  macOS bloque la mise à jour de $DEST."
    echo "    Réglages Système > Confidentialité et sécurité > Gestion des apps > active Terminal, puis relance."
    open "$APP"
  fi
fi

if [[ "$MODE" == "pkg" ]]; then
  ROOT=build/pkgroot
  rm -rf "$ROOT" && mkdir -p "$ROOT" dist
  ditto "$APP" "$ROOT/AudioMixer.app"
  # Empêche l'installeur de « suivre » une copie de l'app ailleurs sur le disque
  pkgbuild --analyze --root "$ROOT" build/component.plist >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO build/component.plist
  pkgbuild --root "$ROOT" \
    --component-plist build/component.plist \
    --identifier io.github.zahorrr.AudioMixer \
    --version "$VERSION" \
    --install-location /Applications \
    --scripts scripts/pkg \
    dist/AudioMixer.pkg
  echo "✅ dist/AudioMixer.pkg (v$VERSION)"
fi
