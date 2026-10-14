#!/bin/bash
# Builds the Flatpak from the .deb that scripts/build-linux.sh --release leaves,
# the same repackaging Flathub does from a release, and installs it for the user.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLATPAK="$PROJECT/packaging/flatpak"
DEB=$(ls -t "$PROJECT"/apps/tauri/src-tauri/target/release/bundle/deb/*.deb 2>/dev/null | head -1)
if [[ -z "$DEB" ]]; then echo "Falta el .deb: ejecuta scripts/build-linux.sh --release" >&2; exit 1; fi
cp "$DEB" "$FLATPAK/Escriba.deb"
flatpak-builder --user --install --force-clean \
  --state-dir "$FLATPAK/.flatpak-builder" "$FLATPAK/build" "$FLATPAK/es.zetesis.Escriba.yml"
echo "Instalado: flatpak run es.zetesis.Escriba"
