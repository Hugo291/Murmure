#!/bin/bash
# Compile Murmure et assemble Murmure.app (bundle barre de menus, signé ad-hoc).
set -euo pipefail
cd "$(dirname "$0")"

APP="Murmure"
BUNDLE_ID="com.hugo.murmure"
DEST="${1:-$HOME/Applications}"   # par défaut ~/Applications

# SDK : depuis le SDK macOS 27, @State est une macro SwiftUI. Son plugin (libSwiftUIMacros.dylib)
# vient avec Xcode mais PAS avec les Command Line Tools 27 → « plugin for module 'SwiftUIMacros'
# not found ». Dans ce cas on compile avec le SDK 26.x livré à côté, où @State n'est pas une
# macro. Sans effet sur l'app : la cible reste macOS 14 (Package.swift). SDKROOT déjà défini → respecté.
if [ -z "${SDKROOT:-}" ]; then
  SDK="$(xcrun --show-sdk-path)"
  BIN_DIR="$(dirname "$(xcrun -f swift)")"
  HAS_SWIFTUI_MACROS=false
  # Dossiers de plugins du compilateur : toolchain, puis plateforme (Xcode).
  for d in "$BIN_DIR/../lib" "$BIN_DIR/../local/lib" \
           "$SDK/../../../Developer/usr/lib" "$SDK/../../../Developer/usr/local/lib"; do
    if [ -e "$d/swift/host/plugins/libSwiftUIMacros.dylib" ]; then HAS_SWIFTUI_MACROS=true; fi
  done
  if ! $HAS_SWIFTUI_MACROS && [ "$(xcrun --show-sdk-version | cut -d. -f1)" -ge 27 ]; then
    OLD_SDK="$(ls -d "$(dirname "$SDK")"/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [ -n "$OLD_SDK" ]; then
      export SDKROOT="$OLD_SDK"
      echo "▸ SDK $(basename "$OLD_SDK") (plugin SwiftUIMacros absent des Command Line Tools)"
    else
      echo "⚠︎  Plugin SwiftUIMacros absent et aucun SDK macOS 26.x : la compilation va échouer (installe Xcode)" >&2
    fi
  fi
fi

# SDK imposé (ci-dessus ou par l'appelant) : l'édition de liens passe par clang en --sysroot, dont
# il ne tire pas la version du SDK. Sans -isysroot, le binaire serait marqué « SDK 14.0 » et macOS
# lui appliquerait les comportements de compatibilité d'AppKit/SwiftUI au lieu de ceux de son SDK.
SWIFT_BUILD_FLAGS=()
if [ -n "${SDKROOT:-}" ]; then
  SWIFT_BUILD_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDKROOT")
fi

echo "▸ Compilation (release)…"
swift build -c release ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"}

BIN=".build/release/$APP"
APPDIR="$DEST/$APP.app"

echo "▸ Assemblage du bundle → $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"

# Icône de l'app (générée par ./make-icon.sh → icon/Murmure.icns)
if [ -f "icon/Murmure.icns" ]; then
  cp "icon/Murmure.icns" "$APPDIR/Contents/Resources/Murmure.icns"
else
  echo "⚠︎  icon/Murmure.icns absent — bundle sans icône (lance ./make-icon.sh)"
fi

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$APP</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$APP</string>
    <key>CFBundleDisplayName</key>         <string>Murmure</string>
    <key>CFBundleIconFile</key>            <string>Murmure</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmure enregistre votre voix pour la transcrire localement.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Murmure affiche un aperçu de votre dictée en temps réel, reconnu sur l'appareil (aucune donnée envoyée).</string>
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
