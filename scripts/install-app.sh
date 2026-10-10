#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--release" ) ]]; then
  echo "Uso: scripts/install-app.sh [--release]" >&2
  exit 2
fi
CONFIGURATION=debug
if [[ "${1:-}" == "--release" ]]; then CONFIGURATION=release; fi
SOURCE="$PROJECT/apps/tauri/src-tauri/target/$CONFIGURATION/bundle/macos/Escriba.app"
APPLICATIONS_DIR="${ESCRIBA_APPLICATIONS_DIR:-/Applications}"
TRASH_DIR="${ESCRIBA_TRASH_DIR:-$HOME/.Trash}"
TARGET="$APPLICATIONS_DIR/Escriba.app"
LEGACY="$APPLICATIONS_DIR/Escriba Tauri.app"
BUILD_DIR="$PROJECT/.build"
BACKUP="$BUILD_DIR/Escriba-anterior.app"
IDENTIFIER="dev.zetesis.escriba.tauri"
SWIFT_IDENTIFIER="dev.ruben.escriba"

check_bundle() {
  local bundle="$1" found
  [[ -e "$bundle" ]] || return 0
  if [[ ! -d "$bundle" || -L "$bundle" ]]; then
    echo "Instalación detenida: $bundle no es un bundle regular." >&2
    exit 1
  fi
  found=$(plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist")
  if [[ "$found" != "$IDENTIFIER" ]]; then
    echo "Instalación detenida: $bundle tiene identificador $found (se esperaba $IDENTIFIER)." >&2
    exit 1
  fi
}

TARGET_KIND=none
check_target() {
  local identifier executable
  [[ -e "$TARGET" ]] || return 0
  if [[ ! -d "$TARGET" || -L "$TARGET" ]]; then
    echo "Instalación detenida: $TARGET no es un bundle regular." >&2
    exit 1
  fi
  identifier=$(plutil -extract CFBundleIdentifier raw "$TARGET/Contents/Info.plist")
  executable=$(plutil -extract CFBundleExecutable raw "$TARGET/Contents/Info.plist")
  if [[ "$identifier" == "$IDENTIFIER" ]]; then
    TARGET_KIND=current
  elif [[ "$identifier" == "$SWIFT_IDENTIFIER" && "$executable" == EscribaMenuBar ]]; then
    TARGET_KIND=swift
  else
    echo "Instalación detenida: $TARGET no es una versión conocida de Escriba ($identifier, $executable)." >&2
    exit 1
  fi
}

check_closed() {
  local bundle="$1" executable
  [[ -d "$bundle" ]] || return 0
  executable=$(plutil -extract CFBundleExecutable raw "$bundle/Contents/Info.plist")
  if lsof -nP -t "$bundle/Contents/MacOS/$executable" >/dev/null 2>&1 || pgrep -f "$bundle/Contents/MacOS/" >/dev/null 2>&1; then
    echo "Cierra Escriba antes de instalar: $bundle sigue en uso." >&2
    exit 1
  fi
}

check_target
check_bundle "$LEGACY"
check_bundle "$BACKUP"
if [[ "$TARGET_KIND" == current && -e "$LEGACY" ]]; then
  echo "Instalación detenida: existen dos bundles actuales de Escriba." >&2
  exit 1
fi
check_closed "$TARGET"
check_closed "$LEGACY"
"$PROJECT/scripts/build-app.sh" "$@"
[[ -d "$SOURCE" ]] || { echo "No existe el bundle construido: $SOURCE" >&2; exit 1; }
check_bundle "$SOURCE"
codesign --verify --deep --strict "$SOURCE"
check_closed "$TARGET"
check_closed "$LEGACY"
mkdir -p "$BUILD_DIR"
if [[ "$(stat -f %d "$APPLICATIONS_DIR")" != "$(stat -f %d "$BUILD_DIR")" ]]; then
  echo "Instalación detenida: /Applications y .build deben estar en el mismo volumen para el rollback." >&2
  exit 1
fi

STAGING=$(mktemp -d "$BUILD_DIR/.Escriba-stage.XXXXXXXX")
ORIGINAL=""
if [[ "$TARGET_KIND" == current ]]; then ORIGINAL="$TARGET"; fi
if [[ -e "$LEGACY" ]]; then ORIGINAL="$LEGACY"; fi
OLD_BACKUP_IN_TRASH=""
OLD_SWIFT_IN_TRASH=""
NEW_INSTALLED=false
ORIGINAL_MOVED=false
SUCCESS=false
finish() {
  local status=$?
  if [[ "$SUCCESS" != true ]]; then
    if [[ "$NEW_INSTALLED" == true ]]; then rm -rf "$TARGET"; fi
    if [[ "$ORIGINAL_MOVED" == true ]]; then mv "$BACKUP" "$ORIGINAL"; fi
    if [[ -n "$OLD_SWIFT_IN_TRASH" ]]; then mv "$OLD_SWIFT_IN_TRASH/Escriba-SwiftUI.app" "$TARGET"; fi
    if [[ -n "$OLD_BACKUP_IN_TRASH" ]]; then mv "$OLD_BACKUP_IN_TRASH/Escriba-anterior.app" "$BACKUP"; fi
    echo "Instalación fallida; se restauraron los bundles anteriores." >&2
  fi
  rm -rf "$STAGING"
  if [[ -n "$OLD_SWIFT_IN_TRASH" && "$SUCCESS" != true ]]; then rmdir "$OLD_SWIFT_IN_TRASH"; fi
  if [[ -n "$OLD_BACKUP_IN_TRASH" && "$SUCCESS" != true ]]; then rmdir "$OLD_BACKUP_IN_TRASH"; fi
  exit "$status"
}
trap finish EXIT

ditto "$SOURCE" "$STAGING/Escriba.app"
codesign --verify --deep --strict "$STAGING/Escriba.app"
diff -rq "$SOURCE" "$STAGING/Escriba.app" >/dev/null
check_closed "$TARGET"
check_closed "$LEGACY"
if [[ -n "$ORIGINAL" && -e "$BACKUP" ]]; then
  mkdir -p "$TRASH_DIR"
  trash_slot=$(mktemp -d "$TRASH_DIR/.Escriba-backup.XXXXXXXX")
  mv "$BACKUP" "$trash_slot/Escriba-anterior.app"
  OLD_BACKUP_IN_TRASH="$trash_slot"
fi
if [[ "$TARGET_KIND" == swift ]]; then
  mkdir -p "$TRASH_DIR"
  swift_trash_slot=$(mktemp -d "$TRASH_DIR/.Escriba-SwiftUI.XXXXXXXX")
  mv "$TARGET" "$swift_trash_slot/Escriba-SwiftUI.app"
  OLD_SWIFT_IN_TRASH="$swift_trash_slot"
fi
if [[ -n "$ORIGINAL" ]]; then mv "$ORIGINAL" "$BACKUP"; ORIGINAL_MOVED=true; fi
mv "$STAGING/Escriba.app" "$TARGET"
NEW_INSTALLED=true
codesign --verify --deep --strict "$TARGET"
diff -rq "$SOURCE" "$TARGET" >/dev/null
SUCCESS=true
echo "Instalada: $TARGET"
if [[ -e "$BACKUP" ]]; then echo "Anterior recuperable: $BACKUP"; fi
if [[ -n "$OLD_SWIFT_IN_TRASH" ]]; then echo "SwiftUI archivada: $OLD_SWIFT_IN_TRASH/Escriba-SwiftUI.app"; fi
