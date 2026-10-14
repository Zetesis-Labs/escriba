#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI="$PROJECT/apps/tauri"
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--release" && "${1:-}" != "--dev" ) ]]; then
  echo "Uso: scripts/build-linux.sh [--release|--dev]" >&2
  exit 2
fi
node_ready() {
  "$1" -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major > 22 || major === 22 && minor >= 12 ? 0 : 1)' >/dev/null 2>&1
}
if ! command -v node >/dev/null || ! node_ready node; then
  NODE_READY=false
  for NODE_BIN in "$HOME"/.nvm/versions/node/v2[246]*/bin "$HOME/.local/opt/node/bin"; do
    if [[ -x "$NODE_BIN/node" ]] && node_ready "$NODE_BIN/node"; then
      export PATH="$NODE_BIN:$PATH"
      NODE_READY=true
      break
    fi
  done
  if [[ "$NODE_READY" != true ]]; then echo "Escriba necesita Node 22.12 o posterior." >&2; exit 1; fi
fi
BUN_VERSION=$(cat "$TAURI/runtime-host/bun-version")
BUN_READY=false
for BUN_BIN in $(type -ap bun) "$HOME/.bun/bin/bun" /usr/local/bin/bun; do
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
if ! command -v cargo >/dev/null && [[ -x "$HOME/.cargo/bin/cargo" ]]; then export PATH="$HOME/.cargo/bin:$PATH"; fi
CONFIGURATION=debug
CARGO_ARGS=()
TAURI_ARGS=(build --debug --no-bundle)
if [[ "${1:-}" == "--release" ]]; then CONFIGURATION=release; CARGO_ARGS=(--release); TAURI_ARGS=(build --bundles deb); fi
if [[ "${1:-}" == "--dev" ]]; then TAURI_ARGS=(dev); fi
cargo build --manifest-path "$TAURI/native-host/Cargo.toml" "${CARGO_ARGS[@]}"
TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
mkdir -p "$TAURI/src-tauri/binaries"
cp "$TAURI/native-host/target/$CONFIGURATION/EscribaNativeHost" "$TAURI/src-tauri/binaries/EscribaNativeHost-$TRIPLE"
# The host finds sherpa-onnx next to itself while developing and in /usr/lib/Escriba/native once installed.
rm -rf "$TAURI/src-tauri/native"
mkdir -p "$TAURI/src-tauri/native" "$TAURI/src-tauri/target/$CONFIGURATION"
for LIBRARY in "$TAURI/native-host/target/$CONFIGURATION"/lib{onnxruntime,sherpa-onnx-c-api}.so*; do
  cp -L "$LIBRARY" "$TAURI/src-tauri/native/"
  cp -L "$LIBRARY" "$TAURI/src-tauri/binaries/"
  cp -L "$LIBRARY" "$TAURI/src-tauri/target/$CONFIGURATION/"
done
npm ci --ignore-scripts --prefix "$PROJECT/packages/conectores"
npm run build --prefix "$PROJECT/packages/conectores"
npm ci --ignore-scripts --prefix "$TAURI"
npm ci --ignore-scripts --prefix "$TAURI/runtime-host/toolchain"
npm run typecheck:runtime --prefix "$TAURI"
node "$TAURI/scripts/prepare.mjs"
(cd "$TAURI" && npm exec tauri -- "${TAURI_ARGS[@]}")
if [[ "${1:-}" == "--release" ]]; then
  echo "Construido: $(ls -t "$TAURI"/src-tauri/target/release/bundle/deb/*.deb | head -1)"
elif [[ "${1:-}" != "--dev" ]]; then
  echo "Construido: $TAURI/src-tauri/target/debug/escriba-tauri"
fi
