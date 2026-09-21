# escriba

Transcriptor automático de notas de voz, en Swift, camino de ser una app propia
con biblioteca de grabaciones. El `README.md` explica el dominio (iCloud,
asentamiento, ledger, backends); esto son las reglas para tocar el código.

**Alcance (cambiado por Rubén el 2026-09-20)**: Escriba es un **producto
OSS**. Cualquiera se lo baja de GitHub, pega el token de su integración
(Notion hoy; otros destinos mañana) y tiene su ingester apuntado a sus
páginas. Diseñar para un desconocido que se baja el binario: onboarding
claro, nada que exija leer el código, y verificar de punta a punta contra
el servicio real antes de decir «hecho». Sigue sin haber venta: el plan
comercial de `comercializacion.md` (2026-09-04) queda aparcado y solo sirve
para no repetir el análisis.

**El núcleo viaja**: el mismo motor debe poder correr en un Mac, en un pod
de Linux o en un runtime WebAssembly (WASI), cambiando solo el host que lo
conecta. `EscribaCore`, `EscribaEngine` y `EscribaNotion` compilan a
`wasm32-unknown-wasi` y a Linux, y el CI lo comprueba en cada PR. El
escritorio en Windows y Linux está descartado por ahora; el análisis queda en
`docs/requisito-multiplataforma.md`. El núcleo como componente WebAssembly en
Kubernetes es un spike aprobado: la prueba de `wasi:http` está en
`spikes/wasi-http` y los criterios de salida en
`docs/requisito-nucleo-wasm-kubernetes.md`.

## Comandos

```bash
export TOOLCHAINS=org.swift.640202609131a   # Swift 6.4 de swift.org; sin esto, el 6.2 de Xcode
swift build                 # CLI + app
swift test                  # swift-testing; --filter NO casa con nombres de @Suite
./scripts/build-app.sh      # .build/app/Escriba.app (elige el toolchain 6.4 solo si esta instalado)
./scripts/install-app.sh    # a /Applications

# Portabilidad (lo mismo que hace el CI)
docker run --rm -v "$PWD":/src -w /src swift:6.4-noble bash -c \
  "apt-get update -qq && apt-get install -y -qq libsqlite3-dev && swift build --target EscribaSystemKit"
swift build --swift-sdk swift-6.4.0-RELEASE_wasm --product escriba-wasm-probe   # toolchain swift.org 6.4
node scripts/run-wasi.mjs "$(swift build --swift-sdk swift-6.4.0-RELEASE_wasm --product escriba-wasm-probe --show-bin-path)/escriba-wasm-probe.wasm"

# Prueba en vivo del conector (crea y regenera una página real)
ESCRIBA_NOTION_TOKEN=ntn_… [ESCRIBA_NOTION_AUDIO=fichero.m4a] swift test --filter EnVivoTests
```

Desde Swift 6.4 SwiftPM construye con Swift Build y los productos salen en
`.build/out/Products/<config>-<plataforma>/`: nunca hardcodear la ruta, usar
`--show-bin-path`.

**El toolchain del proyecto es el 6.4 de swift.org**, también para la app y
los tests de macOS (el CI lo instala en el runner). Xcode 26.0 trae Swift
6.2 y sirve de respaldo, así que si se usa sintaxis de 6.4 hay que asumir
que con Xcode a secas no compila. Lo que NO se puede usar es API de 6.4 que
exija runtime nuevo (p. ej. `withTaskCancellationShield`, SE-0504): el
mínimo es macOS 26.0 y el stdlib es el del sistema. El SDK wasm exige el
toolchain swift.org de su misma versión.

La app se firma con la identidad del Llavero que contenga «Escriba»
(hoy `Zetesis - Escriba`, autofirmada, confiada vía `add-trusted-cert
-p codeSign`; caduca 2027-08-31 — renovar igual). Con identidad estable el
Acceso total al disco sobrevive a las reinstalaciones; sin ella cae a
ad-hoc y puede caducar.

## Arquitectura: núcleo funcional, cáscara imperativa

| Target | Qué | Corre en | Dependencias |
|---|---|---|---|
| `EscribaCore` | Modelo (`Transcript`, `Recording`), parseo, decisiones puras | macOS, Linux, WASI | ninguna |
| `EscribaEngine` | Puertos (`TranscriptionBackend`, `RecordingSource`, `Sink`, `LedgerPort`, `FolderWatcher`, `ReadinessProbe`), `Pipeline`, `Daemon`, `Log`. Orquestación que solo habla con puertos | macOS, Linux, WASI | ninguna |
| `EscribaNotion` | Conector Notion: esquema y mapeo, plantilla del cuerpo, cliente API sobre un transporte HTTP propio, publicación, sink | macOS, Linux, WASI | ninguna (URLSession solo fuera de WASI) |
| `EscribaSystemKit` | Host de sistema: FSEvents (macOS) o sondeo (Linux), stat/iCloud/materialización, flock, `offloaded`, ledger SQLite, migración legacy | macOS, Linux | SQLite del sistema (`CSQLite` en Linux) |
| `EscribaWhisper` | Backend WhisperKit + SpeakerKit | Apple | argmax-oss-swift |
| `EscribaStore` | Biblioteca SQLite + copia del audio + rastro de publicaciones | macOS, Linux | GRDB |
| `EscribaModel` | Modelos observables de la UI (biblioteca, conectores, ajustes), token en fichero 0600 | macOS | |
| `escriba` | CLI | macOS | |
| `EscribaMenuBar` | App: ventana única con Biblioteca / Conectores / Ajustes | macOS | aislamiento MainActor por defecto |
| `escriba-wasm-probe` | Sonda que ejercita Core+Engine+Notion; la ejecuta el CI en un runtime WASI | WASI | |

- **Los puertos son structs de funciones**, no protocolos ni herencia:
  `TranscriptionBackend`, `RecordingSource`, `Sink`, `LedgerPort`,
  `NotionClient`, `NotionTransport`. Una implementación nueva es una función
  `make(...)` que devuelve el struct.
- **Nada de Dispatch, CoreServices, `Process`, `URLSession` ni CoreFoundation
  en `EscribaCore`, `EscribaEngine` o `EscribaNotion`**: si lo necesitas, es
  un puerto y su implementación va a `EscribaSystemKit` (o al host que
  toque). Comprobación: `swift build --swift-sdk <sdk wasm> --target
  EscribaEngine`; el job `wasi` del CI falla si se rompe.
- **Toda decisión va en `EscribaCore` como función pura y con test.** La cáscara
  solo ejecuta. Si un bloque pide un comentario, extráelo a una función con
  nombre.
- **Cada dependencia externa vive en su propio target.** `EscribaCore`,
  `EscribaEngine` y `EscribaNotion` no importan nada.
- **Tests primero**, con swift-testing (`@Suite`/`@Test`/`#expect`), nunca
  XCTest. Los nombres de test describen el comportamiento en castellano.

## Decisiones cerradas (no reabrir)

- **Mínimo macOS 26 / tools 6.2, a propósito**: da `Observations`,
  FoundationModels, SpeechAnalyzer y el aislamiento por defecto. No bajarlo.
- **Nada de Combine.** Notificaciones a la UI con `AsyncSequence`
  (`ValueObservation.values(in:)`, `Observations`) sobre modelos
  `@MainActor @Observable`. `Observations` exige el modelo en `@MainActor`
  o pide `Sendable` y no compila.
- **GRDB, nunca SwiftData ni Core Data**: clavan los datos a Apple y bloquean
  `sqlite-vec`.
- **El pipeline no adivina cuántos hablan.** Guarda lo que sale; la corrección
  (`merging`, `renaming`, `--speakers-count N`) es de la app.
- **El ledger es la única fuente de verdad del pipeline; la biblioteca es el
  espejo de estados para la UI.** Toda grabación escaneada tiene fila en la
  biblioteca (`pending/processing/done/failed`, eventos `.scanned` /
  `.transcribing` / `.failed`); el pipeline decide qué transcribir solo con el
  ledger. No mover esa decisión al Store ni al revés.
- **La app se descarga sus modelos** a
  `~/Library/Application Support/escriba/models`; nunca reutiliza los
  de MacWhisper.
- **WhisperKit es el único backend** (por defecto desde 2026-08-31; el
  contraste MacWhisper/`mw` se borró el 2026-09-20). Nada del repo lanza
  procesos externos (`Shell`/`Process` se fueron con él): transcribir es un
  puerto que provee el host, y en un runtime WASI sería `wasi:nn`.
- **Conectores, en plural** (Rubén, 2026-09-20): lista de N conectores, cada
  uno con su token (fichero `~/Library/Application Support/escriba/secrets/<id>.token`
  con permisos 0600; **ya no en el Llavero**: pedía la contraseña en cada
  reinstalación aunque la firma fuera estable, y el fichero además vale en
  Linux; el token antiguo del Llavero se migra en la primera lectura y se
  retira de allí), su base, su mapeo
  columna-por-dato, su plantilla del cuerpo (`/comandos`) e interruptor. El
  rastro de publicación es por conector (tabla `publication`). Reprocesar o
  corregir **regenera** la página en cada conector donde estaba (mismo
  enlace). Un fallo del conector nunca tumba el pipeline: `notionSink`
  lo anota en el diario **y lo lanza**, y es `forgiving(_:)` (en la
  composición de sinks del pipeline, `AppRuntime.sink(for:)`) quien lo traga
  para que la pasada siga. «Publicar» a mano usa el sink sin envolver, así
  el error llega al usuario.
- **Token del usuario, no OAuth**: para un binario que cada uno se baja, OAuth
  obligaría a un backend con `client_secret`. Cada usuario crea su conexión
  «Token de acceso» en Notion y le comparte las bases.
- **La ventana de Ajustes no existe**: todo vive en la ventana principal
  (barra lateral Biblioteca / Conectores / Ajustes).
- **La diarización se elige a mano** (decidido por Rubén 2026-09-04): el ajuste
  viene en `off` y el pipeline no diariza lo que entra. Se pide por grabación
  («Detectar hablantes») o por carpeta en Ajustes. No proponer activarla por
  defecto.
- **El `.txt` sigue a la biblioteca**: reprocesar o corregir hablantes reescribe
  el fichero (`TranscriptWriter` inyectado en `LibraryModel`, misma
  `writeSidecarText` que el sink). Si el fichero y la biblioteca discrepan, es
  un bug.
- **El daemon es concurrencia estructurada** (decidido por Rubén 2026-08-31,
  tras proponerse conservar el hilo): Task cancelable + actor `WakeSignal`;
  la pasada bloqueante va en su cola GCD puenteada con una continuation —
  nunca bloquear el pool cooperativo.

## Swift moderno: qué se usa y dónde

Directriz (2026-08-31): usar lo último del lenguaje, cada cosa donde paga.

- **Concurrencia estricta Swift 6** en todo; aislamiento MainActor por defecto
  en los targets de UI; `@concurrent` para trabajo pesado fuera del main actor.
- **AsyncSequence como transporte único**: `values(in:)` de GRDB,
  `Observations`, `AsyncStream` para puentear callbacks (FSEvents, time
  observers de AVPlayer). Nada de Combine ni `NotificationCenter`.
- **Typed throws en los puertos**: `TranscriptionBackend` es
  `throws(TranscriptionError)`; el mapeo se hace en la frontera con
  `TranscriptionError.catching`.
- **`Mutex` (Synchronization) donde sobreviva un lock**; `NSLock` es legado.
- **Ownership donde es real, no adorno**: `~Copyable` para recursos de un solo
  dueño (`InstanceLock`/flock); `Span<Float>`/`borrowing` para mirar PCM sin
  copiarlo (una hora a 16 kHz float ≈ 230 MB). El resto no lo necesita.
- Sin caso aquí: Embedded Swift, interop C++, `InlineArray`.

## Trampas del stack

- `DecodingOptions.skipSpecialTokens` viene en `false`: sin activarlo el
  texto sale con `<|startoftranscript|><|0.00|>…`.
- `WhisperKit` y `WhisperKitConfig` **no son `Sendable`**: el kit vive dentro
  de un `actor` y solo cruzan la frontera tipos que sí lo son.
- `SpeakerSegment.text` sale de `speakerWords`, no de `transcription`: sin
  `wordTimestamps` las transcripciones diarizadas salen vacías **en silencio**.
- `SpeakerInfo` es enum no-frozen con `.noMatch` y `.multiple`: `@unknown default`.
- `SpeakerKit.diarize` pide PCM 16 kHz en memoria
  (`AudioProcessor.loadAudioAsFloatArray`), no una ruta.
- HubApi deja metadatos en `.cache` con el mismo nombre que la carpeta del
  modelo, y la carpeta existe desde el primer byte: un modelo está completo
  solo si tiene los tres `.mlmodelc` con `coremldata.bin`.
- Los métodos de WhisperKit son `open func`, no `public func` (grep engañoso).
- Grabaciones multicanal: los canales se suman a mono y la diarización se
  degrada. Pendiente diarizar por canal.
- Notion: `blocks/{id}/children` pagina de 100 en 100 — leer sin seguir
  `next_cursor` deja bloques viejos al regenerar. Reescribir una página larga
  cuesta ~1 petición por bloque; 429 se reintenta con `Retry-After`; un corte
  de red se reintenta solo en peticiones repetibles (crear página, nunca).
- El clasificador de Claude Code bloquea subir notas de voz reales a Notion
  desde una sesión: para probar `/audio` en vivo, audio sintético (`say` +
  `afconvert`).
- `JSONSerialization` devuelve booleanos como `NSNumber` en Darwin y como
  `Bool` en Linux/WASI: `jsonValue(from:)` lo trata con `#if
  canImport(ObjectiveC)`.
- `isolated deinit` con el aislamiento por defecto del target compila en
  debug pero **release exige el `@MainActor` explícito en la clase**.
- Un valor no `Sendable` (`OpaquePointer` de SQLite, `FSEventStreamRef`) puede
  vivir dentro de un `Mutex`, pero no puede quedar referenciado fuera del
  `withLock`: se crea, se arranca y se guarda dentro del mismo bloque, y solo
  sale el valor anterior para liberarlo. Así `Ledger`, `DirectoryWatcher` y
  `DaemonController` son `Sendable` sin `@unchecked`.
- `EscribaEngineTests` prueba `Pipeline` y `Daemon` contra puertos falsos
  (`Fakes.swift`: `MemoryLedger`, `source(_:)`, `FakeWatcher`); los tests de
  `EscribaSystemKitTests` son la integración con el host real. Un
  comportamiento nuevo del motor se prueba primero en Engine.
- El modelo se descarga solo tras 5 min sin trabajo (`IdleUnloader`); el RSS
  no vuelve del todo (malloc retiene páginas), pero los objetos se liberan.
