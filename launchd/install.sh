#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.ruben.escriba"
INSTALL_DIR="$HOME/.local/bin"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "compilando en release..."
(cd "$PROJECT" && swift build -c release)

mkdir -p "$INSTALL_DIR"
cp "$PROJECT/.build/release/escriba" "$INSTALL_DIR/escriba"
echo "binario instalado en $INSTALL_DIR/escriba"

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__INSTALL__|$INSTALL_DIR|g" -e "s|__HOME__|$HOME|g" \
    "$PROJECT/launchd/$LABEL.plist" > "$TARGET"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$TARGET"
launchctl enable "gui/$UID/$LABEL"

echo "servicio cargado: $TARGET"
echo
echo "IMPORTANTE: concede Acceso total al disco a $INSTALL_DIR/escriba"
echo "en Ajustes > Privacidad y seguridad > Acceso total al disco."
echo "Sin eso launchd no puede leer ~/Library/Mobile Documents."
echo
launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid)' || true
