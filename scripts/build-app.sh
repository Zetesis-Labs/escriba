#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Escriba"
BUILD_DIR="$PROJECT/.build/app"
APP="$BUILD_DIR/$APP_NAME.app"

echo "compilando en release..."
(cd "$PROJECT" && swift build -c release --product EscribaMenuBar)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PROJECT/.build/release/EscribaMenuBar" "$APP/Contents/MacOS/EscribaMenuBar"
cp "$PROJECT/Resources/Info.plist" "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Escriba[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "${IDENTITY:-}" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "firmada con: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "firmada ad-hoc; crea un certificado 'Escriba' en el Llavero para identidad estable"
fi

echo "construido: $APP"
