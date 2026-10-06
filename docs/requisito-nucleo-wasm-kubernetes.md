# Requisito funcional (spike): el núcleo como componente WebAssembly en Kubernetes

Estado: **descartado por Rubén el 2026-10-06**: no se va a hacer. Era un
spike aprobado el 2026-09-20 y ninguno de sus criterios de salida llegó a
ejecutarse. Se conserva por la prueba de `wasi:http` (`spikes/wasi-http`) y por
lo que se aprendió de Swift en WASI.

## Qué tiene que poder hacer

Escriba corre en el clúster **como `.wasm`, no como binario Linux**: el
mismo `EscribaCore` + `EscribaEngine` + `EscribaNotion` que la app del Mac,
compilado a `wasm32-unknown-wasip1`, convertido a componente y ejecutado por
el runtime WebAssembly que Talos ofrece (Spin, vía SpinKube). El usuario
sube grabaciones a un bucket, el componente las transcribe por un servidor
OpenAI-compatible (LiteLLM) y publica en Notion, sin Mac encendido.

## Lo que ya está demostrado (2026-09-20, `spikes/wasi-http`)

- Un módulo Swift 6.4 wasip1 se convierte en **componente** con
  `wasm-tools component embed/new` y el adaptador
  `wasi_snapshot_preview1.command` de wasmtime v48.0.2.
- Swift no tiene SDK wasip2: el pegamento son bindings C generados por
  `wit-bindgen c` para un mundo que importa `wasi:http/outgoing-handler`,
  consumidos por interop C desde Swift. Hace falta un stub de
  `__component_type_object_force_link_<mundo>` porque SwiftPM no enlaza el
  `.o` que genera wit-bindgen; el tipo del componente lo aporta
  `component embed`.
- El componente hace **HTTPS real** con el TLS en el host: `api.notion.com`
  devuelve 401 (sin token) y `swift.org` 200.
- Corre igual bajo `wasmtime run -S http` y bajo **Spin 4.1 con
  `trigger-command`**, que es lo que lleva el shim `spin` v0.25.1 de la
  extensión de Talos. Cortes (Talos 1.12.11) puede activarla como una
  `RuntimeClass` más.
- `Task.sleep` y `async let` funcionan en wasip1: el bucle del daemon no
  cambia.
- WasmEdge, la otra extensión de Talos, no tiene wasi-http (preview 2
  sigue en seguimiento): descartado.

Reproducir: `spikes/wasi-http/build.sh` (requiere toolchain swift.org 6.4
con su SDK wasm, `wasm-tools`, `wit-bindgen`, `wasmtime` y `spin` con el
plugin `trigger-command`).

## Criterios de salida del spike (lo que falta por demostrar)

1. **Subida de audio por streaming**: cuerpo multipart escrito en
   `outgoing-body` por trozos, a LiteLLM (`/v1/audio/transcriptions`) y a
   Notion (File Upload, partes de 10 MB). Sin esto no hay `/audio` ni
   transcripción.
2. **Ledger persistente**: `spin:sqlite` desde Swift vía WIT, o SQLite
   compilado dentro del `.wasm` sobre un PVC (la `SpinApp` admite
   `volumes`). Hay que elegir uno y probar que sobrevive a un reinicio del
   pod.
3. **Fuente de grabaciones**: listar y descargar de MinIO por la API S3 con
   SigV4 escrito en Swift (HMAC-SHA256, sin CryptoKit). Alternativa: bucket
   con política de lectura anónima solo durante el spike.
4. **Tamaño y arranque**: la sonda pesa 7 MB sin Foundation; el núcleo con
   Foundation va a ~45 MB por ICU. Medir el tiempo de precompilación de
   Spin y probar `swift-icudata-slim`. Criterio: arranque < 10 s.
5. **SpinKube en cortes**: extensión `spin` en Talos + runtime-class-manager
   + `SpinApp` con el componente. Criterio: una grabación real entra por el
   bucket y aparece en Notion.

## Cómo encaja con el resto

- El **backend de transcripción remoto OpenAI-compatible (LiteLLM)** deja
  de estar aparcado: es la pieza que hace posible el spike, porque en wasm
  no hay inferencia local. Se implementa sobre el mismo transporte HTTP de
  `EscribaNotion` (tipos propios), sin diarización (no está estandarizada
  por API; el parser tolera un `speaker` opcional si el proveedor lo
  devuelve).
- El pegamento C y las implementaciones de los puertos sobre WASI van a un
  target nuevo, **`EscribaWasiHost`**, hermano de `EscribaSystemKit`:
  transporte HTTP sobre `wasi:http`, ledger sobre `spin:sqlite`, fuente
  sobre S3, vigilante por sondeo. Nada de esto entra en Core, Engine ni
  Notion.
- El job `wasi` del CI pasa de «compila y ejecuta la sonda» a «compila,
  componentiza y ejecuta el spike bajo wasmtime con `-S http`».

## Relación con otras decisiones

- El escritorio en Windows y Linux está descartado por ahora
  (`docs/requisito-multiplataforma.md`, PR #6); este spike no lo necesita.
- Un binario Linux nativo con whisper.cpp sigue siendo la alternativa si el
  spike falla en 1, 2 o 4.
