#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Escriba"
BUILD_DIR="$PROJECT/.build/app"
APP="$BUILD_DIR/$APP_NAME.app"

# Toolchain de swift.org (6.4) si esta instalado; si no, el de Xcode.
if [ -z "${TOOLCHAINS:-}" ]; then
  SWIFT_ORG=$(ls -d "$HOME"/Library/Developer/Toolchains/swift-6.4*.xctoolchain /Library/Developer/Toolchains/swift-6.4*.xctoolchain 2>/dev/null | head -1 || true)
  if [ -n "$SWIFT_ORG" ]; then
    export TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw "$SWIFT_ORG/Info.plist")
  fi
fi
echo "compilando en release con $(swift --version 2>&1 | head -1)..."
(cd "$PROJECT" && swift build -c release --product EscribaMenuBar)
BIN=$(cd "$PROJECT" && swift build -c release --product EscribaMenuBar --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/EscribaMenuBar" "$APP/Contents/MacOS/EscribaMenuBar"
cp "$PROJECT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"[^"]*Escriba[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "${IDENTITY:-}" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "firmada con: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "firmada ad-hoc; crea un certificado 'Escriba' en el Llavero para identidad estable"
fi

echo "construido: $APP"
