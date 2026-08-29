#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="JPR Transcribe"
SOURCE="$PROJECT/.build/app/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"

"$PROJECT/scripts/build-app.sh"

osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

echo "instalada en $TARGET"
echo
echo "SIGUIENTE PASO — concede Acceso total al disco a \"$APP_NAME\""
echo "en Ajustes > Privacidad y seguridad > Acceso total al disco,"
echo "o no podra leer ~/Library/Mobile Documents."
echo
echo "para que arranque sola al iniciar sesion:"
echo "  Ajustes > General > Elementos de inicio > +"
