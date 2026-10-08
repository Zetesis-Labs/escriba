#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

zod=.build/herramientas/zod-4.6.5.tgz
[ -f "$zod" ] || ./scripts/descargar-esbuild.sh >/dev/null
rm -rf recetas/.escriba/zod
mkdir -p recetas/.escriba/zod
tar -xzf "$zod" -C recetas/.escriba/zod --strip-components=1 package

npx --yes --package=typescript@5.9.3 -- tsc -p recetas

js=$(npx --yes esbuild@0.28.2 recetas/por-defecto/receta.ts \
  --bundle --format=iife --global-name=__receta --target=es2022 --charset=utf8 --log-level=warning \
  --alias:zod=./recetas/.escriba/zod)
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

swift_text() {
  printf '    public static let %s = ##"""\n%s\n"""##\n' "$1" "$(cat "$2")"
}

{
  echo 'public enum RecipeTemplate {'
  swift_text contract recetas/escriba-recetas.d.ts
  echo
  swift_text tsconfig recetas/tsconfig.json
  echo
  swift_text agents recetas/plantilla/AGENTS.md
  echo
  swift_text starter recetas/plantilla/mi-receta.ts
  echo '}'
} > Sources/EscribaCore/RecipeTemplate.swift
