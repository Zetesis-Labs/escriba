# escriba

Transcriptor automático de notas de voz, en Swift, camino de ser una app propia
con biblioteca de grabaciones. El `README.md` explica el dominio (iCloud,
asentamiento, ledger, backends); esto son las reglas para tocar el código.

**Alcance (cambiado por Rubén el 2026-09-20)**: Escriba es un **producto
OSS**. Cualquiera se lo baja de GitHub, pega el token de su integración
(Notion), o elige una carpeta para un bundle OKF, y tiene su ingester
apuntado a sus páginas. Diseñar para un desconocido que se baja el binario:
onboarding claro, nada que exija leer el código, y verificar de punta a
punta contra el servicio real antes de decir «hecho». Licencia MIT; no hay
venta.

**El núcleo viaja**: el mismo motor debe poder correr en un Mac, en un pod
de Linux o en un runtime WebAssembly (WASI), cambiando solo el host que lo
conecta. `EscribaCore`, `EscribaEngine` y `EscribaNotion` compilan a
`wasm32-unknown-wasi` y a Linux, y el CI lo comprueba en cada PR. El
escritorio en Windows y Linux está descartado por ahora; el análisis queda en
`docs/requisito-multiplataforma.md`. Si se retoma, la decisión ya está tomada:
SwiftUI en el Mac y **SwiftCrossUI** fuera, compartiendo `EscribaModel` (observa
`@Observable`, verificado el 2026-09-22). **Tauri con sidecar está descartado
por decisión de producto (la interfaz es Swift), no por CoreML**: el sidecar
sería Swift y usaría el Neural Engine igual. No reabrirlo sin que Rubén lo pida. El núcleo como componente WebAssembly en
Kubernetes **está descartado** (Rubén, 2026-10-06: no se va a hacer; no
reabrirlo sin que lo pida): el análisis queda en
`docs/requisito-nucleo-wasm-kubernetes.md` y la prueba de `wasi:http` en
`spikes/wasi-http`. **Recetas** (`docs/requisito-recetas.md`, en construcción desde el
2026-10-07): programas en TypeScript que orquestan todo el recorrido de una
grabación con `await`. Una lista de recetas de formulario (en la app) y de
código (las de la carpeta del proyecto); una es la por defecto y procesa todo,
y una puede pasar la grabación a otra con `procesar`. **No hay receta por
carpeta ni por grabación**, ni exportar o importar recetas sueltas, ni
convertir una de formulario en código (Rubén, 2026-10-07). Runtime:
**JavaScriptCore detrás de un puerto**, para cambiarlo por WebAssembly cuando
compense; el tiempo límite usa `JSContextGroupSetExecutionTimeLimit` (API
privada, cargada con `dlsym`, probada en macOS 26) y no cuenta las esperas. El
proyecto de recetas vive en una carpeta que elige el usuario (la edita con su
editor o un agente; git y GitHub son cosa suya) y la app la compila con
**esbuild en WebAssembly** a paquetes, que se descarga al elegir la carpeta: el
motor solo ejecuta paquetes y no lleva compilador. El editor Monaco dentro de
la app está aparcado (Rubén, 2026-10-07). Los
conectores como plugins wasm se exploraron y se archivaron el 2026-10-06
(viable, pero no merece la pena ahora): conclusiones y medidas en
`docs/exploracion-plugins-wasm.md`, código en el PR en borrador #3.

## Comandos

```bash
export TOOLCHAINS=org.swift.640202609131a   # Swift 6.4 de swift.org; sin esto, el 6.2 de Xcode
swift build                 # CLI + app
swift test                  # swift-testing; --filter NO casa con nombres de @Suite
./scripts/build-recetas.sh  # comprueba tipos y recompila la receta por defecto (npx: typescript 5.9.3, esbuild 0.28.2)
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
| `EscribaEngine` | Puertos (`TranscriptionBackend`, `RecordingSource`, `Sink`, `LedgerPort`, `NoteMemory`, `FolderWatcher`, `ReadinessProbe`), capacidades, `Pipeline`, `Daemon`, `Log`. Orquestación que solo habla con puertos | macOS, Linux, WASI | ninguna |
| `EscribaNotion` | Conector Notion: valor de cada columna según su tipo, cuerpo de texto con datos convertido a bloques, cliente API sobre un transporte HTTP propio, publicación, sink | macOS, Linux, WASI | ninguna (URLSession solo fuera de WASI) |
| `EscribaOKF` | Conector a un bundle OKF v0.2 en una carpeta: N documentos por grabación (ruta, frontmatter y cuerpo con datos), `index.md` por carpeta y `log.md`. Decisiones puras (`okfPublication`, `okfRemoval`) y sink sobre el puerto `OKFFolder` | macOS, Linux, WASI | ninguna |
| `EscribaSystemKit` | Host de sistema: FSEvents (macOS) o sondeo (Linux), stat/iCloud/materialización, flock, `offloaded`, ledger SQLite, migración legacy | macOS, Linux | SQLite del sistema (`CSQLite` en Linux) |
| `EscribaWhisper` | Backend WhisperKit + SpeakerKit | Apple | argmax-oss-swift |
| `EscribaIntelligence` | Adaptador del puerto `Summarizer` con FoundationModels (titulo, resumen, etiquetas) | Apple | ninguna |
| `EscribaJSC` | Adaptador del puerto `RecipeRuntime` con JavaScriptCore: una máquina virtual por ejecución en su propia cola, tiempo límite por tramo, errores de Swift que cruzan JavaScript con su identidad, y la receta por defecto compilada (`DefaultRecipe.swift`, generado) | macOS | JavaScriptCore del sistema |
| `EscribaOpenAI` | Adaptadores de `Summarizer` (`/chat/completions` con `json_schema`) y `TranscriptionBackend` (`/audio/transcriptions`) sobre una API compatible con OpenAI; validación de URL y errores | macOS, Linux | ninguna (URLSession solo fuera de WASI) |
| `EscribaStore` | Biblioteca SQLite + copia del audio + rastro de publicaciones | macOS, Linux | GRDB |
| `EscribaModel` | Modelos observables de la UI (biblioteca, conectores, ajustes), token en fichero 0600 | macOS | |
| `escriba` | CLI | macOS | |
| `EscribaMenuBar` | App: ventana única con Biblioteca / Conectores / STT / LLMs / Ajustes | macOS | aislamiento MainActor por defecto |
| `escriba-wasm-probe` | Sonda que ejercita Core+Engine+Notion; la ejecuta el CI en un runtime WASI | WASI | |

- **Los puertos son structs de funciones**, no protocolos ni herencia:
  `TranscriptionBackend`, `RecordingSource`, `Sink`, `LedgerPort`, `NoteMemory`,
  `NotionClient`, `NotionTransport`, `Summarizer`, `OKFFolder`, `RecipeRuntime`. Una implementación nueva es
  una función `make(...)` que devuelve el struct.
- **Las plantillas son texto con datos, compartidas por los conectores**:
  `{{titulo}}`, `{{transcripcion}}`, `{{enlace:<id>}}`… (`TemplateToken`,
  `templatePieces`) y su valor (`NoteValues`) viven en `EscribaCore`; cada
  conector decide cómo pinta un dato (YAML en OKF, tipo de columna o bloques
  en Notion). El editor de la app es un `NSTextView` con los datos como
  pastillas y «/» en el cursor (`TokenEditor.swift`). `BodyTemplate` y el
  `mapping` antiguos solo existen para leer configuraciones guardadas antes.
- **Un destino recibe una `Note`** (`Recording` + `Transcript` + `Digest?`), no
  una transcripción suelta: así el resumen llega a la biblioteca y a Notion sin
  que el pipeline conozca a ninguno de los dos.
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
  ledger. No mover esa decisión al Store ni al revés. **La biblioteca es
  además la memoria de las capacidades** (Rubén, 2026-10-07, fase 1 de las
  recetas): el puerto `NoteMemory` recuerda la última versión con el mismo
  motor y los mismos criterios (`TranscriptionInputs`) y su resumen, así que
  si la app se cierra a mitad o la entrega falla, la nota se reintenta sin
  volver a transcribir ni resumir. La transcripción se guarda en cuanto llega,
  antes de resumir; publicar sigue siendo una sola vez, al final. La memoria no
  decide qué grabaciones están pendientes: eso sigue siendo del ledger.
- **La app se descarga sus modelos** a
  `~/Library/Application Support/escriba/models`; nunca reutiliza los
  de MacWhisper.
- **WhisperKit es el único backend local** (por defecto desde 2026-08-31; el
  contraste MacWhisper/`mw` se borró el 2026-09-20). Nada del repo lanza
  procesos externos (`Shell`/`Process` se fueron con él): transcribir es un
  puerto que provee el host, y en un runtime WASI sería `wasi:nn`. La
  dirección es **computación local** (Rubén, 2026-10-06); las alternativas
  investigadas (FluidAudio con Parakeet y Sortformer, modelos que transcriben
  y diarizan a la vez como VibeVoice-ASR) están en
  `docs/exploracion-transcripcion-diarizacion.md`. Cambiar de motor reabre esta
  decisión y solo con el banco de pruebas de `docs/requisito-hablantes.md`
  (memoria de hablantes, «Personas», aprobada y sin empezar).
- **STT y LLM son resolutores, en plural** (Rubén, 2026-10-06, a imagen de
  los proveedores de Biiak Next pero con N por papel): cada papel tiene una
  lista (`ResolverSet`) **sin favorito** (fuera el 2026-10-07: lo que una
  receta no elige va al local); los locales (Whisper, Apple Intelligence)
  vienen de serie y no se quitan, los remotos hablan la API de OpenAI. Quitar
  un remoto devuelve al local las recetas que lo usaban. **Quién procesa cada nota lo decide la receta por defecto** (Rubén,
  2026-10-07): la sección Recetas es una lista (`RecipeBook`) de recetas de
  formulario (en la app; eligen STT, idioma, hablantes, si resume, con qué LLM,
  **el prompt**, que ya no vive en el resolutor, y en qué conectores publican)
  y de código (las de la carpeta del proyecto), y una de cualquier tipo es la
  por defecto. El pipeline la resuelve **en cada nota** (`RecipeShelf`, que lee
  el libro y `installed.json` al ejecutar): editar recetas no reconstruye los
  pipelines. Si la por defecto no tiene paquete, las notas esperan
  (`recipeUnavailable`), nunca se procesan con otra. Ajustes solo tiene General y
  Carpetas vigiladas; las carpetas solo dicen qué se vigila. **Sin fallback**:
  un remoto caído no cae a local; los fallos que afectan a todas las notas (red,
  clave, 429, 5xx) son `backendUnavailable` y la nota espera, los de esa nota
  (413, 400) la marcan fallida. Un resolutor caído solo retiene sus notas: la
  pasada aparta las que van a él (`TranscriptionBackend.route`, el id del
  resolutor) y sigue con las demás. La clave se lee en cada llamada, así
  cambiarla no reconstruye nada. Diarizar solo existe en local. No hay copia en
  `.txt` (fuera el 2026-10-07; para ficheros, el conector OKF): lo que se
  guarda en el ledger es la copia de audio de la biblioteca.
- **Conectores, en plural** (Rubén, 2026-09-20): lista de N conectores, cada
  uno con su token (fichero `~/Library/Application Support/escriba/secrets/<id>.token`
  con permisos 0600; **ya no en el Llavero**: pedía la contraseña en cada
  reinstalación aunque la firma fuera estable, y el fichero además vale en
  Linux; el token antiguo del Llavero se migra en la primera lectura y se
  retira de allí), su base, el valor de cada columna y el cuerpo, e
  interruptor. El
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
  (barra lateral Biblioteca / Conectores / STT / LLMs / Ajustes).
- **Resumir es un puerto, no una dependencia** (Rubén, 2026-09-21): `Summarizer`
  vive en `EscribaEngine` y recibe una `DigestRequest` (instrucciones +
  petición, ambas decididas en `EscribaCore`) y devuelve un `Digest`. El
  troceado de transcripciones largas y la reducción de los parciales son del
  motor, no del adaptador: el adaptador solo declara su `capacity` y ejecuta
  una petición. La reducción es **en cascada** (los parciales se vuelven a
  trocear y reducir mientras no quepan en una sola petición, con tope de
  `maxReduceRounds`): unir todos los parciales de golpe se salía de la ventana
  justo en las grabaciones largas, que son las que motivan trocear.
  Un `Digest` vacío es un fallo (`SummaryError.empty`), no un resumen: si no,
  un modelo que no responde se guarda igual que uno que sí. Hay dos: `EscribaIntelligence` (FoundationModels en el
  propio Mac) y `EscribaOpenAI` (cualquier API compatible). El prompt es del
  resolutor (`Summarizer.prompt`); `DigestPrompt` le añade el idioma y el
  adaptador remoto el formato JSON.
  El resumen viene **apagado** por defecto.
- **El resumen es de la versión, no de la grabación**: se guarda en la fila de
  `transcript`, así elegir otra versión trae su resumen. Corregir hablantes lo
  arrastra; reprocesar genera uno nuevo. Resumir a mano ancla el resultado a la
  versión que se leyó (`setDigest(_:for:version:)`) y no republica si mientras
  tanto la vigente ha cambiado.
- **Quitar el resumen también republica**, y Notion recibe las columnas
  **vacías** (`rich_text: []`, `multi_select: []`), no ausentes: una propiedad
  que no se manda conserva el valor anterior, y biblioteca y destino quedarían
  discrepando en silencio.
- **La diarización se elige a mano** (decidido por Rubén 2026-09-04): el ajuste
  viene en `off` y el pipeline no diariza lo que entra. Se pide por grabación
  («Detectar hablantes») o por carpeta en Ajustes. No proponer activarla por
  defecto.
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
- `SystemLanguageModel.availability` puede decir `.modelNotReady` aunque Apple
  Intelligence esté activado: los pesos se bajan aparte y tardan. En el Mac de
  Rubén está así (2026-09-21), por eso el ajuste de resúmenes se puede activar
  igualmente y la interfaz explica por qué no resume todavía.
- La ventana del modelo de Apple es pequeña (8192 tokens contando instrucciones
  y salida): `AppleIntelligence.capacity` son 3500 caracteres por petición y lo
  que no cabe se trocea y se reduce.
- **Sin `maximumResponseTokens` el modelo se desboca**: con una entrada de 3300
  caracteres se pasó 4 minutos generando hasta reventar la ventana
  («Content contains 8193 tokens»). El tope está en
  `AppleIntelligence.responseTokens`. Ojo al calibrarlo: si corta antes de
  cerrar la estructura, falla con «GeneratedContent does not contain a property
  'tags'», así que el tope tiene que dar para el resumen **entero** (900 tokens
  con resúmenes de hasta 600 caracteres).
- **Reprocesar guarda la versión antes de resumir.** El resumen va en su propia
  tarea (`summarizing`), porque en una nota de 45 minutos tarda ~80 s y antes
  dejaba la transcripción sin guardar todo ese rato: parecía colgado.
- `Tests/EscribaIntelligenceTests/EnVivoTests.swift` resume de verdad con el
  modelo del sistema si le pasas `ESCRIBA_RESUMEN_TEXTO=<fichero>`; sin esa
  variable se salta, como el test en vivo de Notion.
- Un closure que se pasa a un puerto con `throws(SummaryError)` necesita la
  anotación explícita (`{ request throws(SummaryError) in`): sin ella el
  compilador infiere `any Error` y no compila.
- **JavaScriptCore**: un `JSValue` no puede entrar en el estado de un actor
  desde un callback de JS (el compilador lo para, con razón). Entre Swift y JS
  solo cruzan ids y textos: las promesas pendientes viven en el preludio, del
  lado de JS. El tiempo límite (`JSContextGroupSetExecutionTimeLimit`, por
  `dlsym`) necesita `JSC_usePollingTraps`: con las interrupciones por señal, un
  bucle compilado por el JIT no se corta dentro del proceso de tests.
- La receta por defecto se escribe en `recetas/por-defecto/receta.ts` y se
  compila con `./scripts/build-recetas.sh`; el CI falla si
  `DefaultRecipe.swift` no coincide con su fuente. No editar el generado.
