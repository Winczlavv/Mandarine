#!/bin/bash
# 🍊 Mandarine
#   ./build.sh            → compile pour ce Mac, embarque ffmpeg et installe dans /Applications
#   ./build.sh --release  → compile Apple Silicon + Intel dans dist/ (utilisé par GitHub Actions)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-install}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0}"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "⚠️  Outils de développement Apple manquants. Une fenêtre d'installation va s'ouvrir."
  echo "    Relance ce script une fois l'installation terminée."
  xcode-select --install || true
  exit 1
fi

fetch_ffmpeg() {  # $1 = arm64 | x86_64
  local arch="$1" out="vendor/ffmpeg-$1" tmp url
  [ -x "$out" ] && return 0
  mkdir -p vendor
  tmp="$(mktemp -d)"
  if [ "$arch" = arm64 ]; then url="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
  else url="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip"; fi
  echo "⬇️  ffmpeg ($arch)…"
  if ! curl -fsSL "$url" -o "$tmp/f.zip"; then
    if [ "$arch" = x86_64 ] && curl -fsSL "https://evermeet.cx/ffmpeg/getrelease/zip" -o "$tmp/f.zip"; then :
    else echo "⚠️  ffmpeg ($arch) indisponible : formats MP3/WEBM… désactivés"; rm -rf "$tmp"; return 0; fi
  fi
  ditto -x -k "$tmp/f.zip" "$tmp/x"
  find "$tmp/x" -type f -name ffmpeg -exec cp {} "$out" \;
  chmod +x "$out" 2>/dev/null || true
  rm -rf "$tmp"
}

build_app() {  # $1 = arm64 | x86_64  → build/$1/Mandarine.app
  local arch="$1" app="build/$1/Mandarine.app"
  echo "🍊 Compilation ($arch, v$VERSION)…"
  rm -rf "build/$arch" && mkdir -p "build/$arch"
  if ! xcrun swiftc -O -swift-version 5 -suppress-warnings -target "$arch-apple-macos13.0" \
       -o "build/$arch/Mandarine" Sources/*.swift; then
    echo ""
    echo "❌ La compilation a échoué. Copie les lignes 'error:' ci-dessus et envoie-les à Claude."
    exit 1
  fi
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  mv "build/$arch/Mandarine" "$app/Contents/MacOS/Mandarine"
  cp Info.plist "$app/Contents/"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
  fetch_ffmpeg "$arch"
  if [ -x "vendor/ffmpeg-$arch" ]; then
    cp "vendor/ffmpeg-$arch" "$app/Contents/MacOS/ffmpeg"
    codesign --force --sign - "$app/Contents/MacOS/ffmpeg"
  fi
  [ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$app/Contents/Resources/"
  codesign --force --sign - "$app"
  xattr -cr "$app" 2>/dev/null || true
}

make_icon() {
  xcrun swift icon.swift build/icon.png >/dev/null 2>&1 || return 0
  mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || true
}

mkdir -p build
echo "🎨 Icône…"
make_icon

if [ "$MODE" = "--release" ]; then
  rm -rf dist && mkdir -p dist
  for arch in arm64 x86_64; do
    build_app "$arch"
    ditto -c -k --keepParent "build/$arch/Mandarine.app" "dist/Mandarine-$arch.zip"
  done
  echo "✅ Archives prêtes dans dist/"
  exit 0
fi

ARCH="$( [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] && echo arm64 || echo x86_64 )"
build_app "$ARCH"

echo "📦 Installation…"
pkill -x Mandarine 2>/dev/null || true
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Mandarine.app"
cp -R "build/$ARCH/Mandarine.app" "$DEST/"
/System/Library/CoreServices/pbs -update 2>/dev/null || true
open "$DEST/Mandarine.app"
echo ""
echo "✅ Mandarine $VERSION installée dans $DEST (🍊 dans la barre de menus)."
