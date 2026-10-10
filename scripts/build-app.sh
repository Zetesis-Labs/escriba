#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI="$PROJECT/apps/tauri"
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--release" && "${1:-}" != "--dev" ) ]]; then
  echo "Uso: scripts/build-app.sh [--release|--dev]" >&2
  exit 2
fi
if ! node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || major === 22 && minor >= 12 ? 0 : 1)' >/dev/null 2>&1; then
  NODE_READY=false
  for NODE_BIN in "$HOME"/.nvm/versions/node/v2[246]*/bin /opt/homebrew/opt/node@22/bin /opt/homebrew/Cellar/node@22/*/bin /usr/local/opt/node@22/bin; do
    if [[ -x "$NODE_BIN/node" ]] && "$NODE_BIN/node" -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || major === 22 && minor >= 12 ? 0 : 1)' >/dev/null 2>&1; then
      export PATH="$NODE_BIN:$PATH"
      NODE_READY=true
      break
    fi
  done
  if [[ "$NODE_READY" != true ]]; then echo "Escriba necesita Node 22.12 o posterior." >&2; exit 1; fi
fi
BUN_VERSION=$(cat "$TAURI/runtime-host/bun-version")
BUN_READY=false
for BUN_BIN in "$PROJECT/.build/bun/$BUN_VERSION"/bun-darwin-*/bun $(type -ap bun) "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
  if [[ -x "$BUN_BIN" ]] && [[ "$("$BUN_BIN" --version)" == "$BUN_VERSION" ]]; then
    BUN_DIRECTORY="$(mktemp -d)"
    trap 'rm -rf "$BUN_DIRECTORY"' EXIT
    ln -s "$BUN_BIN" "$BUN_DIRECTORY/bun"
    export PATH="$BUN_DIRECTORY:$PATH"
    BUN_READY=true
    break
  fi
done
if [[ "$BUN_READY" != true ]]; then echo "Escriba necesita Bun $BUN_VERSION." >&2; exit 1; fi
CONFIGURATION=debug
TAURI_ARGS=(build --debug --bundles app)
if [[ "${1:-}" == "--release" ]]; then CONFIGURATION=release; TAURI_ARGS=(build --bundles app); fi
if [[ "${1:-}" == "--dev" ]]; then TAURI_ARGS=(dev); fi
if [[ -z "${TOOLCHAINS:-}" ]]; then
  SWIFT_ORG=$(ls -d "$HOME"/Library/Developer/Toolchains/swift-6.4*.xctoolchain /Library/Developer/Toolchains/swift-6.4*.xctoolchain 2>/dev/null | head -1 || true)
  if [[ -n "$SWIFT_ORG" ]]; then export TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw "$SWIFT_ORG/Info.plist"); fi
fi
SWIFT_ARGS=(--package-path "$PROJECT")
if [[ -n "${ESCRIBA_SWIFT_SCRATCH:-}" ]]; then SWIFT_ARGS+=(--scratch-path "$ESCRIBA_SWIFT_SCRATCH"); fi
swift build "${SWIFT_ARGS[@]}" -c "$CONFIGURATION" --product EscribaNativeHost
BIN=$(swift build "${SWIFT_ARGS[@]}" -c "$CONFIGURATION" --show-bin-path)
TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
mkdir -p "$TAURI/src-tauri/binaries"
cp "$BIN/EscribaNativeHost" "$TAURI/src-tauri/binaries/EscribaNativeHost-$TRIPLE"
npm ci --ignore-scripts --prefix "$PROJECT/packages/conectores"
npm run build --prefix "$PROJECT/packages/conectores"
npm ci --ignore-scripts --prefix "$TAURI"
npm ci --ignore-scripts --prefix "$TAURI/runtime-host/toolchain"
npm run typecheck:runtime --prefix "$TAURI"
node "$TAURI/scripts/prepare.mjs"
(cd "$TAURI" && npm exec tauri -- "${TAURI_ARGS[@]}")
if [[ "${1:-}" != "--dev" ]]; then
  APP="$TAURI/src-tauri/target/$CONFIGURATION/bundle/macos/Escriba.app"
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\([^"]*Escriba[^"]*\)".*/\1/p' | head -1 || true)
  codesign --force --deep --sign "${IDENTITY:--}" --entitlements "$TAURI/src-tauri/Entitlements.plist" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Construida: $APP"
fi
