#!/bin/bash
# Runs scripts/linux/smoke.sh in a clean container of each supported
# distribution (decision 6 of docs/plan-linux.md) with the built packages.
# Uso: scripts/linux/matrix.sh [--sin-red] [imagen...]
set -uo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="$PROJECT/apps/tauri/src-tauri/target/release/bundle"
ARGS=()
[[ "${1:-}" == "--sin-red" ]] && { ARGS=(--sin-red); shift; }
IMAGES=("$@")
[[ ${#IMAGES[@]} -eq 0 ]] && IMAGES=(ubuntu:24.04 ubuntu:26.04 debian:13 fedora:44 fedora:43)
RESULT=0
for image in "${IMAGES[@]}"; do
  case "$image" in
    fedora*) package=$(ls -t "$BUNDLE"/rpm/*.rpm | head -1) ;;
    *) package=$(ls -t "$BUNDLE"/deb/*.deb | head -1) ;;
  esac
  folder=$(mktemp -d)
  cp "$package" "$folder/"
  # Docker's default seccomp profile hides Landlock; the host kernel decides.
  docker run --rm --security-opt seccomp=unconfined \
    -v "$folder:/pkg:ro" \
    -v "$PROJECT/apps/tauri/native-host/tests/fixtures:/fixtures:ro" \
    -v "$PROJECT/scripts/linux/smoke.sh:/smoke.sh:ro" \
    "$image" bash /smoke.sh "${ARGS[@]}" || RESULT=1
  rm -rf "$folder"
done
exit $RESULT
