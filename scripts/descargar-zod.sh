#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

zod=4.6.5
mkdir -p .build/herramientas
curl -fsSL "https://registry.npmjs.org/zod/-/zod-$zod.tgz" -o ".build/herramientas/zod-$zod.tgz"
echo "a78c0c533de30dc1c4afc259ac43ac06e390cb0da8d2e32eae355301b50b36fc  .build/herramientas/zod-$zod.tgz" \
  | shasum -a 256 -c - >/dev/null
echo ".build/herramientas/zod-$zod.tgz"
