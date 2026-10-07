#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version=0.28.2
destino=.build/herramientas/esbuild-wasm-$version
mkdir -p "$destino"

descargar() {
  curl -fsSL "https://cdn.jsdelivr.net/npm/esbuild-wasm@$version/$2" -o "$destino/$1"
  echo "$3  $destino/$1" | shasum -a 256 -c - >/dev/null
}

descargar esbuild.wasm esbuild.wasm b1831a5c0f6cf688034fb94d0419812f165ea316a3380d3fc00a151e562d2eaf
descargar browser.js lib/browser.js 91593b8f5d1021600a92443717a52e311bb1e1b772981f6aab76cd0ffba33169
echo "$destino"
