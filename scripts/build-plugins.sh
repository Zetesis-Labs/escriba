#!/bin/bash
# Compila los conectores como plugins WebAssembly en .build/plugins/*.wasm.
set -euo pipefail

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ESCRIBA_WASM_SDK:-swift-6.4.0-RELEASE_wasm}"
OUT="$PROJECT/.build/plugins"
mkdir -p "$OUT"

cd "$PROJECT"
for plugin in okf notion; do
  swift build --swift-sdk "$SDK" -c release --product "escriba-plugin-$plugin"
  BIN="$(swift build --swift-sdk "$SDK" -c release --product "escriba-plugin-$plugin" --show-bin-path)"
  cp "$BIN/escriba-plugin-$plugin.wasm" "$OUT/$plugin.wasm"
  echo "$OUT/$plugin.wasm ($(du -h "$OUT/$plugin.wasm" | cut -f1))"
done
