#!/bin/bash
# Construit Murmure.app puis l'emballe dans un .dmg « glisser → Applications ».
# Le bundle est signé avec le certificat stable « Murmure Self Signed » (cf. build.sh) :
# il est donc téléchargeable et installable, MAIS non notarisé par Apple — au 1er lancement
# macOS demande « Ouvrir quand même » (Réglages › Confidentialité et sécurité). Voir le README.
#
#   ./package-dmg.sh [version]   # défaut : 1.0.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
DMG="Murmure-$VERSION.dmg"
BUILD_DIR="$(mktemp -d)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$STAGE"' EXIT

echo "▸ Construction du bundle (release, signé)…"
./build.sh "$BUILD_DIR" >/dev/null
APP="$BUILD_DIR/Murmure.app"
[ -d "$APP" ] || { echo "✗ build.sh n'a pas produit $APP" >&2; exit 1; }

echo "▸ Préparation du contenu du DMG (app + raccourci /Applications)…"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Création de $DMG…"
rm -f "$DMG"
hdiutil create -volname "Murmure" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✅ $DMG ($(du -h "$DMG" | cut -f1))"
echo "   Signature du bundle :"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" | sed 's/^/     /'
