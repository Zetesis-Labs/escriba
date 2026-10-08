#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$PROJECT/scripts/build-tauri.sh" "${1:-}"
CONFIGURATION=debug
if [[ "${1:-}" == "--release" ]]; then CONFIGURATION=release; fi
APP="$PROJECT/apps/tauri/src-tauri/target/$CONFIGURATION/bundle/macos/Escriba Tauri.app"
TARGET="/Applications/Escriba Tauri.app"
if [[ -e "$TARGET" ]]; then
  BACKUP="$PROJECT/.build/Escriba Tauri-$(date +%Y%m%d-%H%M%S).app"
  mkdir -p "$PROJECT/.build"
  mv "$TARGET" "$BACKUP"
  echo "Copia anterior: $BACKUP"
fi
ditto "$APP" "$TARGET"
codesign --verify --deep --strict "$TARGET"
echo "Instalada: $TARGET"
