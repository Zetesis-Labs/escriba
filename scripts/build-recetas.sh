#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

npx --yes --package=typescript@5.9.3 -- tsc -p recetas

js=$(npx --yes esbuild@0.28.2 recetas/por-defecto/receta.ts \
  --bundle --format=iife --global-name=__receta --target=es2022 --charset=utf8 --log-level=warning)
fingerprint=$(printf '%s' "$js" | shasum -a 256 | cut -c1-16)

cat > Sources/EscribaJSC/DefaultRecipe.swift <<SWIFT
import EscribaEngine

extension RecipePackage {
    public static let defaultRecipe = RecipePackage(
        key: "por-defecto",
        source: ##"""
$js
"""##,
        fingerprint: "$fingerprint")
}
SWIFT
