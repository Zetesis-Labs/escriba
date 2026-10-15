#!/bin/bash
# Builds the Flatpak from the .deb that scripts/build-linux.sh --release leaves,
# the same repackaging Flathub does from a release, and installs it for the user.
# Uso: scripts/build-linux-flatpak.sh [--bundle Escriba.flatpak]
#   --bundle writes a single-file bundle instead of installing (CI).
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLATPAK="$PROJECT/packaging/flatpak"
DEB=$(ls -t "$PROJECT"/apps/tauri/src-tauri/target/release/bundle/deb/*.deb 2>/dev/null | head -1)
if [[ -z "$DEB" ]]; then echo "Falta el .deb: ejecuta scripts/build-linux.sh --release" >&2; exit 1; fi
cp "$DEB" "$FLATPAK/Escriba.deb"
# FLATPAK_BUILDER picks another builder, such as "flatpak run org.flatpak.Builder".
read -ra BUILDER <<<"${FLATPAK_BUILDER:-flatpak-builder}"
BUILD=("${BUILDER[@]}" --user --force-clean --install-deps-from=flathub
  --state-dir "$FLATPAK/.flatpak-builder" "$FLATPAK/build" "$FLATPAK/es.zetesis.Escriba.yml")
if [[ "${1:-}" == "--bundle" ]]; then
  BUNDLE="${2:?Falta el archivo .flatpak}"
  "${BUILD[@]}" --repo "$FLATPAK/repo"
  # Installing the bundle fetches the GNOME runtime from Flathub.
  flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
    "$FLATPAK/repo" "$BUNDLE" es.zetesis.Escriba
  echo "Paquete: $BUNDLE"
else
  "${BUILD[@]}" --install
  echo "Instalado: flatpak run es.zetesis.Escriba"
fi
