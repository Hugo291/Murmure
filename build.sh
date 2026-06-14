#!/bin/bash
# Compile Murmure et assemble Murmure.app (bundle barre de menus, signé ad-hoc).
set -euo pipefail
cd "$(dirname "$0")"

APP="Murmure"
BUNDLE_ID="com.hugo.murmure"
DEST="${1:-$HOME/Applications}"   # par défaut ~/Applications

echo "▸ Compilation (release)…"
swift build -c release

BIN=".build/release/$APP"
APPDIR="$DEST/$APP.app"

echo "▸ Assemblage du bundle → $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$APP</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$APP</string>
    <key>CFBundleDisplayName</key>         <string>Murmure</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmure enregistre votre voix pour la transcrire localement.</string>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

SIGN_ID="Murmure Self Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "▸ Signature avec le certificat stable « $SIGN_ID »…"
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APPDIR"
else
  echo "▸ Certificat stable absent → signature ad-hoc (les autorisations seront perdues à chaque build)…"
  codesign --force --sign - "$APPDIR"
fi

echo "✅ Construit : $APPDIR"
echo "   Lance avec : open \"$APPDIR\""
