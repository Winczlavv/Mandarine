#!/bin/bash
# 🍊 Installation de Mandarine en une commande
set -e
echo ""
echo "🍊 Installation de Mandarine…"

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "❌ Il faut macOS 13 (Ventura) ou plus récent. Fais d'abord la mise à jour du Mac."
  exit 1
fi
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then ARCH=arm64; else ARCH=x86_64; fi

TMP=$(mktemp -d)
echo "⬇️  Téléchargement…"
curl -fL --progress-bar "https://github.com/Winczlavv/Mandarine/releases/latest/download/Mandarine-$ARCH.zip" -o "$TMP/m.zip"

pkill -x Mandarine 2>/dev/null || true
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
rm -rf "$DEST/Mandarine.app"
ditto -x -k "$TMP/m.zip" "$DEST"
xattr -cr "$DEST/Mandarine.app" 2>/dev/null || true
rm -rf "$TMP"
/System/Library/CoreServices/pbs -update 2>/dev/null || true
open "$DEST/Mandarine.app"

echo ""
echo "✅ C'est installé ! Cherche la 🍊 en haut à droite de ton écran."
echo "   Tu peux fermer cette fenêtre."
