#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

zod=.build/herramientas/zod-4.6.5.tgz
[ -f "$zod" ] || ./scripts/descargar-zod.sh >/dev/null
rm -rf recetas/.escriba/zod
mkdir -p recetas/.escriba/zod
tar -xzf "$zod" -C recetas/.escriba/zod --strip-components=1 package

npx --yes --package=typescript@5.9.3 -- tsc -p recetas

starter=$(sed 's/^export const receta = { nombre: "Por defecto" }$/export const receta = { nombre: "Mi receta" }/' recetas/por-defecto/receta.ts)
grep -q '^export const receta = { nombre: "Mi receta" }$' <<<"$starter" || { echo "la plantilla no sale de por-defecto" >&2; exit 1; }

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
  printf '    public static let starter = ##"""\n%s\n"""##\n' "$starter"
  echo '}'
} > Sources/EscribaCore/RecipeTemplate.swift
