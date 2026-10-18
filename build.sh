#!/bin/bash
# 🍊 Mandarine — compile et installe l'app dans /Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="Mandarine.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "⚠️  Outils de développement Apple manquants. Une fenêtre d'installation va s'ouvrir."
  echo "    Relance ce script une fois l'installation terminée."
  xcode-select --install || true
  exit 1
fi

echo "🍊 Compilation…"
rm -rf build && mkdir -p build
if ! xcrun swiftc -O -swift-version 5 -suppress-warnings -target "$(uname -m)-apple-macos13.0" \
  -o build/Mandarine Sources/*.swift; then
  echo ""
  echo "❌ La compilation a échoué. Copie les lignes 'error:' ci-dessus et envoie-les à Claude."
  exit 1
fi
mkdir -p "build/$APP/Contents/MacOS" "build/$APP/Contents/Resources"
mv build/Mandarine "build/$APP/Contents/MacOS/Mandarine"
cp Info.plist "build/$APP/Contents/"

echo "🎨 Icône…"
if xcrun swift icon.swift build/icon.png >/dev/null 2>&1; then
  mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o "build/$APP/Contents/Resources/AppIcon.icns" || true
fi

codesign --force --deep --sign - "build/$APP"
xattr -cr "build/$APP" 2>/dev/null || true

echo "📦 Installation…"
pkill -x Mandarine 2>/dev/null || true
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "build/$APP" "$DEST/"
open "$DEST/$APP"

echo ""
echo "✅ Mandarine installée dans $DEST (🍊 dans la barre de menus)."
command -v ffmpeg >/dev/null || [ -x /opt/homebrew/bin/ffmpeg ] || \
  echo "💡 Optionnel : 'brew install ffmpeg' pour MP3, FLAC, OGG, WEBM, MKV, AVI (puis relance l'app)."
