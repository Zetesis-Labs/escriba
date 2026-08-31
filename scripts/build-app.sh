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

codesign --force --deep --sign - "$APP"

echo "construido: $APP"
