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

## La interfaz: Swift nativo también fuera de Apple

Investigado el 2026-09-20 (Rubén descartó la UI web en Tauri: la interfaz
tiene que ser Swift). Estado real de cada opción:

| Opción | Plataformas | Estado a 2026-09-20 | Veredicto |
|---|---|---|---|
| **SwiftCrossUI** (moreSwift) | Linux (GTK 4), Windows (WinUI 3), macOS (AppKit), iOS, Android | v0.9.0 del 2026-08-19, una release al mes, último push 2026-09-18, 1.752 estrellas, MIT. Catálogo de vistas: `NavigationSplitView`, `NavigationStack`, `List`, `Table`, `TextEditor`, `TextField`, `Menu`, `CommandMenu`, `Window`/`WindowGroup`, alertas, diálogos de abrir/guardar fichero, `WebView`. Backend AppKit «todas las funciones»; GTK y WinUI «la mayoría» | **La única vía viable** para Linux y Windows con un solo código |
| **Adwaita for Swift** (Aparoksha) | Linux GNOME (y macOS con GTK de Homebrew) | Activo (commit 2026-09-04), un solo tag 0.1.0, app Memorize en Flathub. El backend WinUI que anunció en 2024 **ya no existe** en la organización | Solo Linux; descartado por no cubrir Windows |
| **Swift/WinRT + WinUI 3** (The Browser Company, hoy Atlassian) | Windows | v0.1.396 (2026-03), push 2026-09-10; Dia para Windows en Swift sale en otoño de 2026. Es la base de las bindings `swift-winui` que usa SwiftCrossUI | Producción real, pero imperativo y solo Windows: una tercera UI |
| Tokamak, VertexGUI, Slint | varias | Tokamak busca mantenedores; VertexGUI (Skia) marginal; Slint no tiene bindings Swift (la PoC se abandonó) | Descartados |

**Lo que hay que saber de SwiftCrossUI antes de apostar:**

- El backend de Windows va clavado al **Windows App SDK 1.5 preview 1**
  (febrero de 2024); la subida a WinUI estable es la issue #204, abierta.
  El runtime se instala solo si se empaqueta con Swift Bundler
  (swift-windowsappsdk 0.1.1, PR #494). Hay 25 issues abiertas que
  mencionan WinUI; en el código quedan huecos (estilos de picker, gestos,
  factor de escala de la ventana).
- El backend GTK exige GTK 4 en el sistema. En Linux es lo normal; en
  AppImage hay que arrastrarlo, en Flatpak lo da la plataforma.
- `swift-tools-version` 5.10 con `StrictConcurrency` activado; compila con
  el toolchain 6.4. Hay que verificar que observa modelos `@Observable`
  (Observation existe en Linux) o si exige su propio sistema de estado.
- No trae reproductor de audio: los controles se montan con `Slider` y
  botones sobre un puerto de reproducción portable (AVFoundation, GStreamer,
  Media Foundation).
- Empaquetado con **Swift Bundler** (mismo autor): `.app`, AppImage, RPM,
  deb genérico, MSI vía WiX. Activo (commits 2026-09-17, arreglo para
  Swift 6.4) aunque sus tags de GitHub estén en 2022: se usa `main`.
- Swift 6.4 en Windows arm64 tiene un bug abierto en el instalador MSI
  (FoundationXML, swiftlang/swift#92379). x64 va bien.

**Recomendación registrada**: SwiftCrossUI. Dos formas de usarlo:

1. **Una sola interfaz** para los tres sistemas con el backend AppKit en el
   Mac. Máximo reuso, pero se pierde lo específico de SwiftUI que ya usa la
   app (`MenuBarExtra`, restauración de ventanas, Liquid Glass) y el Mac
   pasa a depender de un framework en 0.x.
2. **SwiftUI en el Mac, SwiftCrossUI fuera**, compartiendo `EscribaModel`.
   Dos interfaces, pero el Mac no arriesga nada y los modelos son uno.

Empezar por la 2 y decidir la 1 con una app real en la mano. Primer paso:
un spike con la pantalla de Conectores en SwiftCrossUI, en el Mac con
GTK de Homebrew y en una VM Linux, para medir cuánto de `EscribaModel`
se reutiliza tal cual y si la observación funciona.

## Orden propuesto cuando se aborde

1. Puerto de PCM + whisper.cpp + sherpa-onnx en Linux (desbloquea el pod y
   el escritorio Linux a la vez). Verificar en un Linux real, no solo en
   Docker.
2. Spike de SwiftCrossUI con Conectores (Mac con GTK 4 y VM Linux):
   reuso de `EscribaModel`, observación, aspecto.
3. Interfaz completa en SwiftCrossUI para Linux (GTK 4). Empaquetado con
   Swift Bundler: AppImage y Flatpak.
4. Windows: toolchain 6.4 x64, backend WinUI (runtime 1.5 preview vía
   Swift Bundler), Credential Manager, ffmpeg o Media Foundation, MSI con
   WiX y firma (sin firma SmartScreen bloquea al usuario).

## Verificar antes de empezar

- GRDB compila en Linux (comprobado); en Windows no está comprobado.
- Rendimiento real de whisper en CPU sin Neural Engine: cambia la
  experiencia respecto al Mac y condiciona qué modelo va por defecto.
- Tamaño del instalable con el runtime de Swift, GTK o el Windows App
  Runtime y ffmpeg dentro.
- SwiftCrossUI + `@Observable`: si no observa Observation, `EscribaModel`
  necesita una capa de adaptación.

## Relación con otras decisiones

- El backend remoto OpenAI-compatible (LiteLLM) quedó aparcado el
  2026-09-20 porque la diarización no está estandarizada por API; si se
  retoma, es otra implementación del mismo `TranscriptionBackend` y vale
  para los tres sistemas.
- WASI no aporta nada a este requisito ni a Kubernetes: el destino es un
  binario nativo. Su valor es obligar a que el núcleo siga limpio.
