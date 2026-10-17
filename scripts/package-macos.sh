#!/usr/bin/env bash
set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 3 ]] || die 'Uso: package-macos.sh APP_PATH TAG OUTPUT_DIR'
app=$1
tag=$2
output=$3
script_dir=$(cd "$(dirname "$0")" && pwd)
mode=${MACOS_NOTARIZE:-false}
case "$mode" in true|false) ;; *) die 'MACOS_NOTARIZE debe ser true o false' ;; esac
[[ -d "$app" && "$(basename "$app")" == Escriba.app && -f "$app/Contents/Info.plist" ]] || die 'APP_PATH debe apuntar a Escriba.app'
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'TAG debe tener forma vX.Y.Z'
version=${tag#v}
bundle_version=$(python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    print(plistlib.load(stream).get('CFBundleShortVersionString', ''))
PY
)
[[ "$bundle_version" == "$version" ]] || die "La versión de Info.plist ($bundle_version) no coincide con $tag"

if [[ "$mode" == true ]]; then
  for key in APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
    [[ -n "${!key:-}" ]] || die "Falta $key para MACOS_NOTARIZE=true"
  done
  [[ "$APPLE_SIGNING_IDENTITY" == 'Developer ID Application: '* ]] || die 'APPLE_SIGNING_IDENTITY debe ser Developer ID Application'
fi

suffix=_sin-notarizar
[[ "$mode" == true ]] && suffix=''
archive="Escriba_${version}_macos_arm64${suffix}.zip"
[[ ! -e "$output/$archive" && ! -e "$output/SHA256SUMS-macos-arm64" ]] || die 'El artefacto de salida ya existe'

work=$(mktemp -d "${TMPDIR:-/tmp}/escriba-package.XXXXXXXX")
keychain=''
cleanup() {
  status=$1
  trap - EXIT
  if [[ -n "$keychain" && -e "$keychain" ]]; then
    if ! security delete-keychain "$keychain" >/dev/null 2>&1; then
      printf 'Error: no se pudo eliminar el llavero temporal %s\n' "$keychain" >&2
      [[ $status -ne 0 ]] || status=1
    fi
  fi
  if ! rm -rf "$work"; then
    printf 'Error: no se pudo limpiar el directorio temporal %s\n' "$work" >&2
    [[ $status -ne 0 ]] || status=1
  fi
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
mkdir "$work/stage"
ditto "$app" "$work/stage/Escriba.app"
staged_app="$work/stage/Escriba.app"

identity='-'
sign_flags=()
if [[ "$mode" == true ]]; then
  keychain="$work/signing.keychain-db"
  password="$(uuidgen)$(uuidgen)"
  security create-keychain -p "$password" "$keychain" >/dev/null
  security unlock-keychain -p "$password" "$keychain" >/dev/null
  printf '%s' "$APPLE_CERTIFICATE" | base64 -D > "$work/certificate.p12" || die 'APPLE_CERTIFICATE no es base64 válido'
  security import "$work/certificate.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null || die 'No se pudo importar el certificado'
  security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null || die 'No se pudo autorizar codesign en el llavero'
  security find-identity -v -p codesigning "$keychain" | grep -F "$APPLE_SIGNING_IDENTITY" >/dev/null || die 'La identidad Developer ID no está disponible en el llavero temporal'
  identity=$APPLE_SIGNING_IDENTITY
  sign_flags=(--keychain "$keychain" --options runtime --timestamp)
fi

python3 "$script_dir/macos/list-code.py" "$staged_app" > "$work/code-list"
sign_one() {
  target=$1
  entitlements=()
  case "$(basename "$target")" in
    escriba-runtime) entitlements=(--entitlements "$script_dir/macos/bun-entitlements.plist") ;;
    EscribaNativeHost|EscribaSystemHost|escriba-tauri|Escriba.app) entitlements=(--entitlements "$script_dir/macos/audio-entitlements.plist") ;;
  esac
  # macOS ships bash 3.2, where set -u rejects "${array[@]}" of an empty array.
  codesign --force --sign "$identity" ${sign_flags[@]+"${sign_flags[@]}"} ${entitlements[@]+"${entitlements[@]}"} "$target"
}
while IFS= read -r -d '' target; do
  sign_one "$target"
done < "$work/code-list"
sign_one "$staged_app"

verify_app() {
  local candidate=$1
  python3 "$script_dir/macos/list-code.py" "$candidate" > "$work/verify-list"
  while IFS= read -r -d '' target; do
    codesign --verify --strict --verbose=2 "$target"
  done < "$work/verify-list"
  codesign --verify --strict --verbose=2 "$candidate"
}
verify_app "$staged_app"

if [[ "$mode" == true ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$work/notary.zip"
  notary_exit=0
  xcrun notarytool submit "$work/notary.zip" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait --timeout 20m --output-format json > "$work/notary.json" || notary_exit=$?
  if ! notary_result=$(python3 - "$work/notary.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        result = json.load(stream)
    print('{}\t{}'.format(result.get('status', 'Unknown'), result.get('id', '')))
except (OSError, ValueError, TypeError):
    sys.exit(1)
PY
); then
    die "Falló el envío o la espera de la notarización (código $notary_exit; sin respuesta JSON válida)"
  fi
  IFS=$'\t' read -r notary_status notary_id <<< "$notary_result"
  if [[ "$notary_status" != Accepted ]]; then
    printf 'Error: notarización %s (id: %s, código: %s)\n' "$notary_status" "$notary_id" "$notary_exit" >&2
    if [[ -n "$notary_id" ]]; then
      xcrun notarytool log "$notary_id" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" >&2 || true
    fi
    exit 1
  fi
  [[ "$notary_exit" -eq 0 ]] || die "notarytool terminó con código $notary_exit pese a status Accepted"
  xcrun stapler staple "$staged_app"
  xcrun stapler validate "$staged_app"
  spctl --assess --type execute --verbose "$staged_app"
  verify_app "$staged_app"
fi

if [[ "$mode" == true ]]; then
  cat > "$work/stage/LEEME.txt" <<EOF
Escriba $version para macOS 26 o posterior en Apple Silicon (M1 o posterior).

Descomprime el ZIP y arrastra Escriba.app a la carpeta Aplicaciones.
Abre Escriba desde Aplicaciones. Esta versión está firmada con Developer ID y notarizada.
EOF
else
  cat > "$work/stage/LEEME.txt" <<EOF
Escriba $version para macOS 26 o posterior en Apple Silicon (M1 o posterior).

Descomprime el ZIP y arrastra Escriba.app a la carpeta Aplicaciones.
Esta versión tiene firma ad hoc y no está notarizada. Si macOS impide abrirla,
intenta abrir Escriba y luego ve a Ajustes del Sistema > Privacidad y seguridad >
Abrir igualmente. Sigue las indicaciones de macOS.

Ayuda de Apple: https://support.apple.com/es-es/102445
EOF
fi
ditto -c -k --sequesterRsrc "$work/stage" "$work/$archive"
mkdir "$work/extracted"
ditto -x -k "$work/$archive" "$work/extracted"
[[ -d "$work/extracted/Escriba.app" && -f "$work/extracted/LEEME.txt" ]] || die 'El ZIP no contiene Escriba.app y LEEME.txt'
verify_app "$work/extracted/Escriba.app"
if [[ "$mode" == true ]]; then
  xcrun stapler validate "$work/extracted/Escriba.app"
  spctl --assess --type execute --verbose "$work/extracted/Escriba.app"
fi

(cd "$work" && shasum -a 256 "$archive" > SHA256SUMS-macos-arm64)
mkdir -p "$output"
ditto "$work/$archive" "$output/$archive"
ditto "$work/SHA256SUMS-macos-arm64" "$output/SHA256SUMS-macos-arm64"
(cd "$output" && shasum -a 256 -c SHA256SUMS-macos-arm64)
printf 'Paquete preparado: %s/%s\n' "$output" "$archive"
