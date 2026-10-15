#!/bin/bash
# Installs Escriba's package on a clean distribution and checks the matrix columns
# of docs/plan-linux.md. Runs as root inside a container:
#   /pkg       the .deb or .rpm to install
#   /fixtures  apps/tauri/native-host/tests/fixtures
# --sin-red skips the transcription, which downloads the tiny model.
# The sandbox check measures the kernel of the machine running the container.
set -uo pipefail
NETWORK=true
[[ "${1:-}" == "--sin-red" ]] && NETWORK=false
FAILED=0
ok() { echo "OK    $1"; }
fail() { echo "FALLO $1${2:+: $2}"; FAILED=1; }
. /etc/os-release
echo "== $PRETTY_NAME ($(uname -m)), kernel del anfitrión $(uname -r)"

if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update >/dev/null
  apt-get -qq install -y /pkg/*.deb >/tmp/install.log 2>&1 && ok "instala el .deb" || { fail "instala el .deb" "$(tail -3 /tmp/install.log)"; exit 1; }
  apt-get -qq install -y gstreamer1.0-tools xvfb xauth espeak-ng procps >/dev/null 2>&1
else
  dnf -q install -y /pkg/*.rpm >/tmp/install.log 2>&1 && ok "instala el .rpm" || { fail "instala el .rpm" "$(tail -3 /tmp/install.log)"; exit 1; }
  dnf -q install -y gstreamer1-plugins-base-tools xorg-x11-server-Xvfb xauth espeak-ng procps-ng >/dev/null 2>&1
fi

missing=""
for binary in /usr/bin/escriba-tauri /usr/bin/EscribaNativeHost /usr/bin/escriba-sandbox /usr/bin/escriba-runtime /usr/lib/Escriba/native/*.so*; do
  gone=$(ldd "$binary" 2>/dev/null | grep "not found")
  [[ -n "$gone" ]] && missing+="$(basename "$binary"): $gone "
done
[[ -z "$missing" ]] && ok "no falta ninguna biblioteca" || fail "bibliotecas" "$missing"

for audio in tono.m4a tono.ogg tono.mp3; do
  if gst-launch-1.0 -q filesrc location="/fixtures/$audio" ! decodebin ! fakesink >/tmp/gst.log 2>&1; then
    ok "GStreamer reproduce $audio"
  else
    fail "GStreamer reproduce $audio" "$(tail -1 /tmp/gst.log)"
  fi
done

export XDG_DATA_HOME
XDG_DATA_HOME=$(mktemp -d)
host() { ESCRIBA_AUDIO_SOURCE=/fixtures/tono.wav EscribaNativeHost 2>/dev/null; }
recording=$(mktemp -d)/grabada.ogg
reply=$( { echo '{"id":"a","method":"recordingStart","params":{"outputPath":"'"$recording"'"}}'
  sleep 1.5
  echo '{"id":"b","method":"recordingStop","params":{}}'
  echo '{"id":"c","method":"audioInfo","params":{"audioPath":"'"$recording"'"}}'; } | host)
duration=$(sed -n 's/.*"id":"c","result":{"duration":\([0-9.]*\)}.*/\1/p' <<<"$reply")
if [[ -n "$duration" ]] && awk "BEGIN { exit !($duration > 0.5) }"; then
  ok "graba Opus con el host (${duration} s)"
else
  fail "graba con el host" "$reply"
fi

if $NETWORK; then
  voice=$(mktemp -d)/voz.wav
  espeak-ng -v es -w "$voice" "Esta es una prueba de transcripción de Escriba." >/dev/null 2>&1
  # The model is downloaded first: a transcription requested meanwhile finds no model.
  echo '{"id":"d","method":"downloadModel","params":{"model":"tiny"}}' | EscribaNativeHost >/dev/null 2>&1
  reply=$(echo '{"id":"t","method":"transcribe","params":{"audioPath":"'"$voice"'","model":"tiny","language":"es"}}' | EscribaNativeHost 2>/dev/null)
  if grep -q '"id":"t","result".*[Pp]rueba' <<<"$reply"; then ok "transcribe en local (tiny)"; else fail "transcribe en local" "$(tail -c 300 <<<"$reply")"; fi
else
  echo "--    transcribir (sin red)"
fi

if abi=$(escriba-sandbox --check 2>&1); then
  if escriba-sandbox worker --executable /usr/bin/cat -- /etc/passwd >/dev/null 2>&1; then
    fail "aislamiento" "una receta leyó /etc/passwd"
  elif escriba-sandbox worker --executable /usr/bin/true -- >/dev/null 2>&1; then
    ok "aísla recetas ($abi)"
  else
    fail "aislamiento" "el perfil de receta no deja ejecutar ni /usr/bin/true"
  fi
else
  echo "--    sin aislamiento en este anfitrión: $abi"
fi

data=$(mktemp -d)
ESCRIBA_TAURI_DATA="$data" xvfb-run -a /usr/bin/escriba-tauri >/tmp/app.log 2>&1 &
sleep 15
alive=""
for process in escriba-tauri escriba-runtime EscribaNativeHost; do
  pgrep -f "/usr/bin/$process" >/dev/null || alive+="$process "
done
pkill -f /usr/bin/escriba-tauri
[[ -z "$alive" ]] && ok "la app arranca" || fail "la app arranca" "faltan $alive; $(grep -v appindicator /tmp/app.log | tail -3)"

exit $FAILED
