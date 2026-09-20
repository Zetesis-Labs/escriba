# Requisito funcional: Escriba de escritorio en Windows y Linux

Estado: **requisito apuntado, sin fecha** (Rubén, 2026-09-20). No es un
compromiso de implementación; es la definición de qué significaría «hecho»
y de qué piezas faltan, para no volver a hacer el análisis.

## Qué tiene que poder hacer el usuario

Lo mismo que en el Mac, con el mismo modelo mental:

1. Bajarse un instalable de GitHub Releases para su sistema (AppImage o
   Flatpak en Linux; MSIX o instalador firmado en Windows) y abrirlo sin
   instalar nada más. Los modelos de transcripción se descargan desde la app.
2. Señalar una o varias carpetas de grabaciones. La sincronización con el
   móvil es cosa del usuario (Syncthing, Dropbox, la que tenga): fuera de
   Apple no hay Notas de Voz.
3. Ver la biblioteca: estado de cada grabación, transcripción, reproducir el
   audio, corregir hablantes, reprocesar.
4. Configurar N conectores (Notion hoy) igual que en el Mac: token, base,
   mapeo, plantilla con `/comandos`. La publicación y la regeneración se
   comportan exactamente igual.
5. Transcribir en local, sin cuenta en ningún sitio, con un modelo que corra
   en CPU (y en GPU si hay CUDA o Vulkan).
6. Detectar hablantes a petición, como en el Mac (nunca por defecto).

## Qué se conserva sin tocar

`EscribaCore`, `EscribaEngine`, `EscribaNotion`, `EscribaSystemKit` y
`EscribaStore` ya compilan en Linux y el CI lo comprueba. Swift en Windows
es un toolchain oficial de swift.org de la misma versión (6.4). Nada del
comportamiento del pipeline, del ledger, de la biblioteca ni de los
conectores cambia.

## Qué hay que sustituir (todo está ya detrás de un puerto)

| Pieza | Hoy (Apple) | Windows / Linux | Puerto |
|---|---|---|---|
| Transcripción | WhisperKit (CoreML) | whisper.cpp (CPU, CUDA, Vulkan) | `TranscriptionBackend` |
| Diarización | SpeakerKit (CoreML) | sherpa-onnx (segmentación + embeddings, API C) | dentro del backend |
| Decodificar audio | AVFoundation | ffmpeg/libavcodec, o el del sistema (Media Foundation, GStreamer); WAV/MP3/FLAC con librerías de cabecera | nuevo puerto de PCM |
| Fuente de grabaciones | Notas de Voz (iCloud) + carpetas | solo carpetas (`folderSource`, ya existe) | `RecordingSource` |
| Vigilar carpetas | FSEvents | sondeo cada 30 s (ya existe); mejora: inotify, `ReadDirectoryChangesW` | `FolderWatcher` |
| Secretos | Llavero | libsecret (Linux), Credential Manager (Windows) | `TokenStore` |
| Interfaz | SwiftUI | ver abajo | |

El backend whisper.cpp es el mismo que necesita el pod de Linux
(Kubernetes): se paga una vez y sirve a los dos.

## La interfaz: decisión abierta

SwiftUI no sale de Apple. Dos caminos:

1. **Swift de punta a punta** con SwiftCrossUI (declarativo, backends GTK
   y WinUI). Coherente con el repo, pero la librería está en alfa y el
   backend de Windows va por detrás. Riesgo: reescribir la UI dos veces.
2. **Núcleo como proceso local + UI web en Tauri.** El binario Swift de
   Linux/Windows (el mismo que iría a Kubernetes) va **dentro del bundle
   de Tauri como sidecar** (`externalBin`, mecanismo oficial): Tauri lo
   arranca, lo supervisa y lo cierra. La UI habla con él por HTTP o
   WebSocket en localhost (o JSON por stdio) con la misma API que usaría
   cualquier otro host. Un solo instalable, nada que el usuario tenga que
   lanzar aparte.

   Con el sidecar, técnicamente Tauri también podría envolver el Mac (el
   sidecar sería el núcleo con WhisperKit), pero eso reabriría la decisión
   cerrada «Swift nativo, no Tauri» del Mac. Hoy: SwiftUI en el Mac, Tauri
   fuera. Mantener dos interfaces tiene coste; se revisará cuando la web
   exista.

Recomendación registrada: la 2.

## Orden propuesto cuando se aborde

1. Puerto de PCM + whisper.cpp + sherpa-onnx en Linux (desbloquea el pod y
   el escritorio Linux a la vez). Verificar en un Linux real, no solo en
   Docker.
2. API local del núcleo (la que consumirá la UI web y, en el futuro, el
   móvil).
3. UI web + Tauri + sidecar en Linux. Empaquetado AppImage/Flatpak.
4. Windows: toolchain, libsecret → Credential Manager, ffmpeg o Media
   Foundation, MSIX y firma (sin firma SmartScreen bloquea al usuario).

## Verificar antes de empezar

- GRDB compila en Linux (comprobado); en Windows no está comprobado.
- Rendimiento real de whisper en CPU sin Neural Engine: cambia la
  experiencia respecto al Mac y condiciona qué modelo va por defecto.
- Tamaño del instalable con el runtime de Swift y ffmpeg dentro.

## Relación con otras decisiones

- El backend remoto OpenAI-compatible (LiteLLM) quedó aparcado el
  2026-09-20 porque la diarización no está estandarizada por API; si se
  retoma, es otra implementación del mismo `TranscriptionBackend` y vale
  para los tres sistemas.
- WASI no aporta nada a este requisito ni a Kubernetes: el destino es un
  binario nativo. Su valor es obligar a que el núcleo siga limpio.
