#!/bin/bash
# Spike: núcleo Swift como componente WebAssembly con red (wasi:http).
# Requiere: toolchain swift.org 6.4 + SDK wasm de la misma versión, wasm-tools,
# wit-bindgen, wasmtime (brew) y spin con el plugin trigger-command.
set -euo pipefail
cd "$(dirname "$0")"
export TOOLCHAINS="${TOOLCHAINS:-org.swift.640202609131a}"
SDK="${WASM_SDK:-swift-6.4.0-RELEASE_wasm}"
WASMTIME_TAG="v$(wasmtime --version | awk '{print $2}')"
ADAPTER=".build/wasi_snapshot_preview1.command.wasm"

mkdir -p .build
if [ ! -f "$ADAPTER" ]; then
  gh release download "$WASMTIME_TAG" -R bytecodealliance/wasmtime \
    -p wasi_snapshot_preview1.command.wasm --clobber -D .build
fi

swift build --swift-sdk "$SDK" -c release
MODULE="$(swift build --swift-sdk "$SDK" -c release --show-bin-path)/probe.wasm"
wasm-tools component embed --world probe wit "$MODULE" -o .build/embedded.wasm
wasm-tools component new .build/embedded.wasm \
  --adapt "wasi_snapshot_preview1=$ADAPTER" -o .build/component.wasm
ls -la .build/component.wasm

echo "== wasmtime"
wasmtime run -S http .build/component.wasm
echo "== spin (trigger command, el mismo runtime que el shim de Talos)"
spin up
