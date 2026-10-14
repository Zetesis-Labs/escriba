# Plan de Escriba en Linux

Plan de implementación de `docs/adr/0010-linux-host-nativo-en-rust.md` y de
`specs/escriba/linux/functional-specs.md`, escrito el 2026-10-13 para un agente
que trabaja en Ubuntu sobre la rama `feat/linux`. El ADR dice qué se decidió y
por qué; la spec, qué ve la persona usuaria; este plan, en qué orden se
construye y cuándo cada fase está **hecha**.

## Antes de empezar

Lee el ADR-0010, la spec de Linux, `docs/tauri-native-protocol.md` y el
`CLAUDE.md` del repositorio. Del `CLAUDE.md` vale todo salvo el bloque
«Construir y comprobar», que es de macOS: en Ubuntu se construye como dice la
sección «Entorno Ubuntu» de este plan.

### Decisiones cerradas

Rubén las tomó el 2026-10-13. Se aplican tal cual; si una fase parece pedir
otra cosa, se le pregunta antes de tocarla.

1. Sin LLM incluido en Linux: resumir y preguntar usan resolutores (remotos o un
   Ollama/LM Studio del usuario). Sin LLM elegido, ese paso falla y ya.
2. Paquetes `.deb` y `.rpm`, para x86_64 y arm64. Nada más.
3. Si el equipo no permite aislar recetas, se ejecutan todas con un aviso
   permanente.
4. Se graba en Opus (`.ogg`); al importar o vigilar se aceptan m4a y el resto de
   formatos del Mac.
5. Whisper de serie en Linux: large-v3-turbo.
6. Soporte: Ubuntu LTS 24.04 y 26.04, Debian 13 y las dos últimas Fedora.
7. Linux empieza con biblioteca nueva; no se importa la del Mac.
8. Cada sistema usa su motor nativo; no hay motor común con el Mac.
9. Host nativo de Linux en Rust, en proceso aparte y con el protocolo v1. Linux
   no compila ni empaqueta Swift.

### Cómo se trabaja con Rubén

- Una fase está **hecha** cuando Rubén la ve funcionar en su Ubuntu. Motor más
  tests en verde no basta. Al terminar una fase, instala, avisa y espera.
- Cada fase es una **vertical**: primero su batería de tests, después el código.
- Respuestas cortas y una decisión por turno. Lo que no esté en la spec no se
  añade por iniciativa propia; se pregunta.
- Commits convencionales en castellano, uno por cosa, sin trailers de IA. Sin
  push, merge ni PR salvo que Rubén lo pida. Actualizar la rama con rebase de
  `main`, nunca con merge.
- Al acabar cada fase, apunta en el «Registro» del final el commit, y en
  `docs/pendiente-mac.md` lo que la sesión del Mac tiene que hacer o comprobar.

## Entorno Ubuntu

Sobre Ubuntu 24.04 con escritorio:

```bash
sudo apt install build-essential pkg-config clang cmake curl \
  libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
  librsvg2-dev libxdo-dev libasound2-dev espeak-ng
curl -sSf https://sh.rustup.rs | sh   # stable
```

Node 22.12 o posterior y el Bun de `apps/tauri/runtime-host/bun-version`. El
audio sintético de las pruebas se genera con `espeak-ng -w`; nunca se usan
grabaciones reales de Rubén.

`scripts/build-linux.sh` construye el host nativo de Rust, el runtime, las
dependencias incluidas y la app (`--release` deja el `.deb`); también prepara
lo que necesitan las pruebas de `cargo test` y `npm test`.

## Mapa del código que importa

- **Procesos nativos por papel.** `lib.rs:1689-1713` arranca tres procesos
  `Native` del mismo binario `EscribaNativeHost`: `materializer`, `inference` y
  `recorder`. `native::binary` (`native.rs:249`) lo busca junto al ejecutable o
  en `src-tauri/binaries/<nombre>-<triple>`. El host de Rust es un sustituto
  directo por papel: mismo nombre, mismo protocolo.
- **Protocolo.** `docs/tauri-native-protocol.md` más lo que llama Rust de
  verdad: `recorder.rs:97` usa `recordingCancel`, que el documento no recoge.
  La batería de contrato se deriva de las llamadas de Rust, y el documento se
  corrige en la misma fase.
- **Recetas.** El binario `escriba-runtime` se construye con Bun
  (`runtime-host/build.mjs`) y corre bajo `sandbox-exec` en `scripts.rs:202`; las
  herramientas del proyecto, en `project.rs:279` y el lanzador de
  `project.rs:448`.
- **Valores de serie.** `store/settings.rs:305`: resolutores locales «Whisper ·
  en este Mac» con `openai_whisper-large-v3-v20240930` y «Apple Intelligence».

## Fases

Las fases van en orden. Cada una deja la app en un estado que Rubén puede ver.

### L0. Diagnóstico

Ejecuta `cargo check --all-targets` en `apps/tauri/src-tauri` y compáralo con el
«Inventario de compilación» del final.

**Hecho cuando** el inventario coincide con lo que ves o le has añadido lo nuevo.

### L1. El host Rust compila y pasa sus tests en Linux

Tests primero: los que fallen en Linux por depender de macOS se condicionan con
`cfg(target_os = "macos")` o reciben su versión de Linux; ninguno se borra.

- `folder_access.rs`: en Linux elegir carpeta devuelve la ruta y un bookmark
  vacío; `restore` acepta la ruta tal cual. La versión de macOS no cambia.
- `watcher.rs:4` y `watcher.rs:213` (`std::os::macos`, `st_flags`): en Linux
  `dataless` es siempre falso.
- `scripts.rs:224` (`resident_bytes`) y `scripts.rs:242` (`process_identity`)
  usan `proc_pidinfo` de macOS; en Linux salen de `/proc/<pid>/statm` y
  `/proc/<pid>/stat`.
- `lib.rs:1669`: `macos_launcher` del plugin de autostart solo existe en macOS.
- `native.rs:256`: el triple de desarrollo sale del objetivo de compilación
  (`*-unknown-linux-gnu` en Linux).
- `lib.rs:671-814`: abrir y mostrar usan `xdg-open`; los enlaces
  `x-apple.systempreferences` solo existen en macOS y en Linux el aviso explica
  qué permiso falta.
- `lib.rs:165`: la carpeta de modelos de Linux es la de datos del usuario
  (`$XDG_DATA_HOME/escriba/models`); la comprobación acepta la de cada sistema.
- `scripts.rs:202` y `project.rs:279/448`: en Linux, hasta L6, las recetas se
  ejecutan sin aislar (decisión 3). La detección vive en una función pura que
  hoy responde «no disponible» en Linux; el aviso llega en L2.
- Tests que llaman a `/usr/bin/say` (`scripts.rs:818`) generan el audio con
  `espeak-ng` en Linux.
- `tests/runtime/project.test.ts:25` crea sus carpetas en `/private/tmp`, que
  solo existe en macOS: diez tests caen por eso. Usar el temporal del sistema.

**Hecho cuando**, en Ubuntu, pasan `cargo check --all-targets`,
`cargo test --lib`, `cargo clippy --all-targets -- -D warnings` y
`cargo fmt --check`, y `npm test --prefix apps/tauri` pasa con los tests de
`sandbox-exec` (`tests/runtime/sidecar.test.ts:38`) limitados a macOS.
**Mac:** pasar la suite completa del `CLAUDE.md`.

### L2. La app arranca en Ubuntu y procesa con un STT remoto

Tests primero: decisiones puras de plataforma (textos, opciones visibles,
valores de serie) en Rust y en `tests/core/`.

- **Host nativo mínimo en Rust**: crate propio en `apps/tauri/native-host/` que
  produce `EscribaNativeHost`. Responde `status` (Whisper sin modelo; LLM no
  disponible), `audioInfo` (duración leyendo el audio), `fileStatus`,
  `materialize` (listo al momento, sin iCloud) y `backend_unavailable` en
  `summarize` y `ask`. Las piezas propias de cada sistema van en módulos aparte,
  para que la sesión del Mac añada las suyas sin reorganizar.
- **Construcción**: `prepare.mjs` usa el paquete `typescript-linux-<arch>` y el
  triple de Linux; `runtime-host/build.mjs` admite `bun-linux-x64` y
  `bun-linux-arm64` y no firma fuera de macOS; un `scripts/build-linux.sh`
  construye el host nativo, el runtime y la app.
- **Ventana**: `tauri.linux.conf.json` sin `titleBarStyle: Overlay`,
  `transparent` ni `windowEffects`, que son del Mac.
- **Plataforma en la interfaz**: Rust informa del sistema y la interfaz aplica
  la spec §6.2 y §8: «Whisper · en este equipo» (`src/core/resolvers.ts:6`),
  sin «Añadir Notas de Voz» (`SettingsPane.tsx:124`), sin «Autorizar…» ni
  «Acceso total al disco», «Mostrar en la carpeta» en lugar de «Finder»
  (`LibraryView.tsx:194`, `RecipesPane.tsx:388`), lista de LLMs vacía de serie
  y el aviso permanente de recetas sin aislar.
- **Bandeja y notificaciones**: `symbols.rs` no da iconos fuera de macOS y
  `notification_delivery.rs` devuelve error; Linux necesita iconos PNG propios y
  notificaciones del escritorio. Comprobar que el inicio con la sesión del
  plugin de autostart funciona en Linux.

**Hecho cuando** Rubén abre Escriba en su Ubuntu, ve la biblioteca vacía y los
Ajustes sin opciones del Mac, añade un resolutor STT remoto, deja un m4a en una
carpeta vigilada y la nota aparece transcrita.
**Mac:** que nada visible ha cambiado.

### L3. Grabar en Linux

Tests primero: batería de contrato del protocolo, que arranca el binario y
habla JSONL, para todos los métodos de grabación con una fuente de audio
inyectada; un test real con micrófono, marcado `#[ignore]`.

- `recordingStart`, `recordingPause`, `recordingResume`, `recordingStop`,
  `recordingCancel` y `recordingStatus`, grabando en Opus (`.ogg`).
- Sin micrófono o sin permiso, el panel lo dice y no crea grabación.
- Añadir `recordingCancel` a `docs/tauri-native-protocol.md`.

**Hecho cuando** Rubén graba desde el panel en Ubuntu, pausa y para, y la nota
aparece en `.ogg`, se reproduce y la procesa la receta elegida.

### L4. Whisper local

Tests primero: contrato de `status`, `downloadModel` (con líneas de progreso) y
`transcribe` (segmentos, palabras, idioma `es` y `auto`) con un modelo pequeño y
audio de `espeak-ng`, marcados `#[ignore]` porque descargan pesos.

- Motor whisper.cpp en el host de Rust; large-v3-turbo de serie y el resto
  descargables desde STT. Se transcribe solo con modelos instalados.
- Procesador por defecto; aceleración por gráfica solo si se demuestra estable.
- Valor de serie del modelo en Linux en `store/settings.rs`.

**Hecho cuando** Rubén descarga el modelo desde STT y una grabación se
transcribe en local sin resolutor remoto.

### L5. Hablantes y Personas

Tests primero: contrato de `transcribe` con `diarize` y `speakers`, y de
`diarizedVoices`, con audio de dos voces de `espeak-ng`.

- Diarización y huellas con un motor que funcione en Linux (sherpa-onnx es el
  candidato); modelos descargados explícitamente.
- El umbral 0,30 del `CLAUDE.md` es el de SpeakerKit. Para Linux se calibra con
  las pruebas y se apunta aquí el valor elegido: 0,50 (ver Registro, L5).
- Las huellas no salen del proceso nativo y de Rust, como en el Mac.

**Hecho cuando** Rubén registra una voz de 30 segundos y una grabación nueva la
reconoce.

### L6. Aislamiento de recetas

Tests primero: los de `tests/runtime/sidecar.test.ts` que prueban que una
receta no lee ni escribe archivos y no abre conexiones, en su versión de Linux.

- Mismas garantías que `runtime-host/sandbox.sb`: solo lectura del ejecutable y
  sus bibliotecas, sin escritura, sin red, y capacidades solo por el canal de
  Escriba. Las herramientas del proyecto conservan su permiso de red al
  instalar.
- El mecanismo se elige comprobándolo en Ubuntu 24.04 y en Fedora, no por
  documentación. Ubuntu 24.04 restringe los espacios de nombres sin privilegios
  con AppArmor: bubblewrap necesitaría un perfil en el `.deb`; Landlock no.
- Si el equipo no lo permite, sigue la decisión 3.

**Hecho cuando** los tests pasan en Ubuntu 24.04 y Fedora y el aviso de recetas
sin aislar desaparece en un equipo que sí aísla.

### L7. Paquetes y CI

- `.deb` y `.rpm` con Tauri, con sus dependencias declaradas (WebKitGTK 4.1,
  AppIndicator, ALSA y los códecs de GStreamer).
- Comprobar que una instalación limpia reproduce m4a en la app (pendiente de la
  spec §10); si no, el paquete trae lo necesario.
- Jobs de CI en `ubuntu-24.04` y `ubuntu-24.04-arm`: construir, pasar los tests
  y dejar los paquetes como artefactos.
- Probar cada paquete en la matriz de la decisión 6 y rellenar la tabla del
  Registro.

**Hecho cuando** la matriz está completa y Rubén instala un paquete en su Ubuntu.

## Fuera de este plan: la sesión del Mac

La lista completa y ordenada está en `docs/pendiente-mac.md`.

El ADR-0010 también pasa al host de Rust, en el Mac, la grabación (AAC con
AudioToolbox), `audioInfo`, `fileStatus` y `materialize`. Se hace en macOS y no
aquí. Como los procesos van por papel, en el Mac bastará con que `recorder` y
`materializer` usen el host de Rust y `inference` siga en Swift; `status` se
reparte entre los dos. Por eso el host de L2 y L3 separa lo propio de cada
sistema en módulos.

## Inventario de compilación (2026-10-13)

Comprobado en contenedores Linux arm64 sobre `main` @ `2e8c438`.

**TypeScript** (`node:22-bookworm`, sin Bun): `packages/conectores` construye y
`tsc --noEmit` de la app pasa. `vitest run`: 315 pasan, 15 se saltan y 11
fallan:

- 10 de `tests/runtime/project.test.ts`, por `/private/tmp` (ver L1).
- `tests/runtime/knowledgeVendor.test.ts` y el fichero entero
  `tests/runtime/sidecar.test.ts`, por `spawnSync bun ENOENT` (faltaba Bun en el
  contenedor). Con Bun instalado, los de `sandbox-exec` seguirán fallando hasta
  limitarlos a macOS.

**Rust** (`ubuntu:24.04`, rustc 1.99, `cargo check --lib`): 16 errores, todos
cubiertos en L1. Al resolverlos pueden aparecer otros que estos tapaban; L0 los
añade aquí.

| Fichero | Errores | Causa |
|---|---|---|
| `folder_access.rs:6-8,118` | 5 | `objc2` sin condicionar a macOS |
| `scripts.rs:224-248` | 8 | `proc_pidinfo`, `proc_taskinfo`, `proc_bsdinfo` de macOS |
| `watcher.rs:4,213` | 2 | `std::os::macos` y `st_flags` |
| `lib.rs:1669` | 1 | `macos_launcher` del plugin de autostart |

**L0 en Ubuntu 25.10 x86_64** (2026-10-13, `feat/linux` @ `1198013`, rustc
1.99, Node 22.23.3, Bun 1.4.2). Rubén da por buena la 25.10 como equipo de
trabajo.

- `cargo check --all-targets` da los mismos 16 errores de la tabla.
- Antes, el `build.rs` de Tauri se para porque no existen los `externalBin`
  `binaries/EscribaNativeHost-x86_64-unknown-linux-gnu` y
  `binaries/escriba-runtime-x86_64-unknown-linux-gnu`. Hasta el script de L2 se
  crean marcadores en esa carpeta, que git ignora:
  `printf '#!/bin/sh\nexit 1\n' > <ruta> && chmod +x <ruta>`.
- `npm test`: 316 pasan, 15 se saltan y 10 fallan, los de `/private/tmp`.
  Con Bun instalado, `knowledgeVendor.test.ts` pasa y `sidecar.test.ts` cae
  entero en el `codesign` de `runtime-host/build.mjs:69`, antes de llegar a
  `sandbox-exec`.

## Registro

**L1 en Ubuntu 25.10** (2026-10-13). Pasan `cargo check --all-targets`,
`cargo test --lib` (355 pasan, 7 ignoradas), `cargo clippy --all-targets -- -D
warnings`, `cargo fmt --check`, `npm test --prefix apps/tauri` (326 pasan, los
15 de `sidecar.test.ts` se saltan), `tsc --noEmit` y `npm run typecheck:runtime`.

Encontrado al hacerlo:

- Las pruebas de Rust dejaban abierta a medias cada base RocksDB: el runtime de
  cada `#[tokio::test]` muere antes de que acabe el cierre. Con 12 hilos la
  suite pasaba de 10 GB y el OOM tumbaba el escritorio; en Ubuntu 25.10 `/tmp`
  es tmpfs y lo agrava. Ahora las bases de prueba se abren en un runtime
  compartido: la suite completa tarda 45 s con unos 6 GB de pico.
- En Linux `storage::released` no esperaba: RocksDB bloquea con `fcntl` y
  `flock` no lo ve. Se comprueba el descriptor del `LOCK`.
- En Linux el supervisor podía medir el worker entre `fork` y `exec`, ver la
  memoria del proceso padre y matarlo por pasar de 512 MiB. Afecta también a la
  app instalada; esa copia ya no se mide.

Pendiente para L2, no tocado en L1: el almacén rechaza el bookmark vacío
(`store/settings.rs:12`) y `watched_folder_bookmarks` filtra las carpetas sin
él, así que en Linux aún no se puede añadir una carpeta vigilada; las
notificaciones de Linux no envían nada todavía.

**L2 en Ubuntu 25.10** (2026-10-13). `scripts/build-linux.sh --release` deja
`Escriba_0.1.0_amd64.deb` y la app extraída arranca con su host nativo de Rust y
el runtime. Pasan `cargo test --lib` (364), las 12 pruebas del host nativo,
`clippy`, `fmt`, `npm test` (337) y los dos `typecheck`.

Para el «hecho» hay que elegir el STT remoto en la receta por defecto: sin
elección se usa el Whisper local, que en Linux llega en L4. El paso de resumen
falla avisando de que la receta no tiene LLM (decisión 1) y la transcripción se
conserva.

Visible y fuera de la spec, pendiente de que Rubén diga qué cambia: la barra de
menús de la app aparece dentro de la ventana (GTK); la franja de 52 px del
título del Mac sigue arriba; el aviso de recetas sin aislar solo está en
Recetas; descargar Whisper (L4) y grabar (L3) fallan con su aviso. Textos
redactados aquí, provisionales: «Elegir carpeta», los avisos de permisos, los
mensajes del host nativo, «La receta no tiene un LLM elegido…», «no puede
resumir», «se quedan sin LLM», el botón «Carpeta» y el aviso de recetas.

**Rebase sobre `main` con el ADR-0011** (2026-10-14). La biblioteca, la
configuración y la cola pasan al controlador Bun, así que lo de L2 que vivía
en el almacén de Rust se rehízo en TypeScript: `src/runtime/platform.ts`
(valores de serie por sistema, «no tiene prueba», resumir sin LLM) y
`authorizeWatchedFolder` sin bookmark en Linux. El binding de SurrealDB del
controlador se elige por sistema (`targets.mjs`, `platform::surreal_native`).
Las pruebas destaparon que la receta por defecto fallaba sin LLMs; ahora «Resume
con» queda vacío y resumir falla avisando. `sidecar.test.ts` corre en Linux con
el worker sin aislar, salvo las tres pruebas de aislamiento. Se descartaron los
commits de `espeak-ng` y de clippy, porque `main` borró ese código. La prueba de
la biblioteca grande tiene 30 s de margen: en Ubuntu tarda 6,5 s también en
`main`.

**L3 en Ubuntu 25.10** (2026-10-14). El host de Rust graba con el micrófono por
defecto (cpal) en Opus/Ogg con libopus estática, con pausa, cancelación y nivel
como el medidor del Mac; batería de contrato con `ESCRIBA_AUDIO_SOURCE` y prueba
real de micrófono ignorada. Las grabaciones de Linux se llaman `.ogg`.
**Decidido por Rubén:** en Linux no hay panel flotante (Wayland no deja colocar
ni subir ventanas); el panel va dentro de la ventana principal, centrado arriba
sobre el contenido, y la ventana se muestra al empezar a grabar. Pendiente: si
la nota grabada se reproduce y se procesa en la app instalada, y si hay botón de
pausa (solo Linux, ambos o ninguno). `worker.test.ts` («tiempo de inferencia en
host…») falló una vez con el equipo cargado y pasó al repetir.

**L4 en Ubuntu 25.10** (2026-10-14). whisper.cpp (`whisper-rs`, en
procesador) en el host de Rust: modelos `ggml-<modelo>.bin`, large-v3-turbo de
serie, descarga explícita con progreso desde STT y transcripción solo con
modelos instalados. Las grabaciones Ogg Opus se decodifican con libopus. La
prueba real (`--ignored`, modelo tiny y voz de `espeak-ng`) transcribe en
español, detecta el idioma y lee una grabación Opus. Al pasar la batería, una
prueba antigua descargó de verdad large-v3-turbo (1,6 GB) en
`~/.local/share/escriba/models`; se conserva porque es el modelo de serie, y el
arnés usa ya siempre una carpeta de datos temporal. Detectar hablantes falla
avisando hasta L5. Sin gráfica: aceleración por GPU pendiente de demostrar que
es estable (plan L4). Fuera de la spec y por decidir: elegir otros modelos desde
STT (el Mac no tiene selector).

**Varios modelos de Whisper** (encargo de Rubén del 2026-10-14, opción A, spec
en `specs/escriba/modelos-whisper/functional-specs.md`). Cada modelo añadido en
STT es un resolutor local `local-stt-<modelo>` con su modelo; el de serie sigue
tomando el de los ajustes. El protocolo gana `models` y `deleteModel`, ya en el
host de Linux; `whisper_model` acepta `model` y vuelve al comportamiento
anterior si el host no los tiene.

**Lo propio de cada sistema detrás de puertos** (encargo de Rubén del
2026-10-14, antes de L5). Sin cambios visibles.

- Host nativo: lo de Linux vive en `native-host/src/platform/linux/`
  (whisper.cpp, Opus/Ogg, archivos sin iCloud) detrás de `Inference`,
  `Encoder`/`ENCODER_RATES`, `file_flags`, `dataless` y `materialize`; el Mac
  añadirá `platform/macos/` con los mismos nombres.
- La batería de contrato se parte: `tests/contract.rs` vale para cualquier host
  (`ESCRIBA_NATIVE_HOST=<binario>`) y `tests/linux.rs` es lo del host de Linux.
- Rust de la app: `platform::PLATFORM` dice qué ofrece cada sistema y su tipo
  de TypeScript se genera (`src/generated/Platform.ts`); la interfaz decide con
  eso. La medición de procesos va en `process_probe.rs` y la extensión de la
  grabación en `platform::RECORDING_EXTENSION`.
- Segunda pasada: `platform::MACOS` y `platform::LINUX` generan
  `src/generated/platforms.json`, con el modelo de Whisper de serie; Rust pasa
  la del sistema al controlador en `ESCRIBA_PLATFORM`, que deja de mirar
  `process.platform`. Elegir y restaurar carpeta viven en cada
  `folder_access` (`choose`, `restore_saved`); Notas de Voz y los flags de
  archivo, en `platform`; los iconos de bandeja en `symbols/{macos,linux}.rs`;
  el menú de la app y el panel flotante se deciden con `PLATFORM`.
- Quedan `cfg` sueltos solo donde la API de Tauri existe únicamente en macOS
  (`macos_launcher` del autostart y `RunEvent::Reopen`) y en pruebas propias de
  un sistema. El host nativo repite el modelo de serie de su sistema, como
  Swift con `WhisperKitBackend.defaultVariant`. El Mac sigue llamando
  «Whisper · en este Mac» al resolutor guardado y «Whisper en este Mac» en la
  interfaz, como en `main`.

**L2, L3, L4 y varios modelos validados por Rubén** en su Ubuntu el
2026-10-14.

**L5 en Ubuntu 25.10** (2026-10-14). Hablantes con sherpa-onnx en el host de
Rust: segmentación pyannote 3.0 (la misma familia que SpeakerKit) y huellas
NeMo TitaNet small, modelo `sherpa-onnx/nemo-titanet-small`. Una huella por
hablante: media de sus turnos de al menos 1 s, pesada por duración. Las palabras
de Whisper se reparten por quien habla en su tiempo y el segmento se parte
donde cambia la voz; el primero en hablar es «Speaker 1».

- **Descarga (decidido por Rubén):** los dos modelos (unos 46 MB) se bajan al
  descargar cualquier Whisper, sin interfaz nueva; lo ya descargado no se
  vuelve a bajar. Sin ellos, detectar hablantes espera como «no disponible».
- **Biblioteca compartida:** enlazado estático, el onnxruntime de sherpa-onnx y
  whisper.cpp se pisan las plantillas de `std::regex` y el host cae con
  `free(): invalid pointer`. Por eso sherpa-onnx va como `.so` en
  `/usr/lib/Escriba/native` y el host la busca con su rpath (`native-host/build.rs`).
- **Calibración:** con las voces reales públicas de `csukuangfj/sr-data`
  (cinco personas, 20 grabaciones, 190 pares; no se guardan en el repositorio)
  WeSpeaker ResNet34-LM confundía personas (16 errores), y TitaNet deja la
  misma persona en el mismo idioma por debajo de 0,415 y personas distintas por
  encima de 0,602. **Umbral de Linux: 0,50**, por modelo en
  `src/runtime/library/voices.ts` (SpeakerKit sigue en 0,30). La misma persona
  en otro idioma no se reconoce (más de 0,94). La agrupación usa el 0,5 de serie
  de sherpa-onnx. Con dos voces de `espeak-ng`, misma voz 0,015 y otra 0,707.
- Para validar en un equipo que ya tenía el Whisper de serie: añadir y
  descargar otro modelo (por ejemplo tiny) trae los de hablantes.
- **Validada por Rubén** el 2026-10-14: identifica bien a los hablantes.

**L6 en Ubuntu 25.10** (2026-10-14). `apps/tauri/sandbox` construye
`escriba-sandbox`, el `sandbox-exec` de Linux. Se encierra con `no_new_privs`,
Landlock (archivos y TCP, ABI 4 o posterior) y seccomp, y después se convierte
en el programa. Tiene los mismos tres perfiles que el Mac: receta (`worker`),
herramienta (`tool`) e instalación (`install`, que además conecta por TCP).
Rust lo usa desde `confinement.rs` (adaptador por sistema) para los workers de
`scripts.rs`, las herramientas de `project.rs` y el lanzador `./escriba`.

- **Detección:** `escriba-sandbox --check` una vez al arrancar. Con Landlock 4
  y seccomp, `recipes_isolated` es verdadero y el aviso desaparece. Si no,
  todo sigue sin aislar con aviso (decisión 3).
- **Medido con Bun, no por documentación:** Bun aborta sin leer su propio
  `/proc/<pid>` (`maps`, `statm`, `cgroup`, `mem`), `/proc/stat`,
  `/proc/sys/vm/{overcommit_memory,mmap_min_addr}`, `/sys/devices/system/cpu`,
  `/sys/kernel/mm/transparent_hugepage` y `/dev/urandom`. Es lo que en el Mac
  cubre `sysctl-read`. Solo su propio `/proc`; los límites del cgroup se le
  niegan y los tolera. `clone3` responde ENOSYS y glibc vuelve a `clone`,
  donde solo se permiten hilos.
- **Solo se ejecuta** el programa y el cargador dinámico que nombra su
  cabecera ELF; las bibliotecas se leen, no se ejecutan.
- **seccomp** niega crear procesos, `socket`/`socketpair` (en `install` solo se
  permiten Unix, IPv4, IPv6 y netlink), `ptrace`, `bpf`, `io_uring`, montar,
  espacios de nombres, módulos y claves. Leer la memoria de otro proceso ya lo
  impide Landlock.
- **Diferencias con el Mac:** con Landlock anterior a 6 (Linux 6.12, como el
  6.8 de Ubuntu 24.04) una receta puede mandar señales a otros procesos del
  usuario. Landlock no puede permitir leer solo `/` sin lo que cuelga de él,
  así que no se permite.
- **Pruebas:** las tres de aislamiento de `sidecar.test.ts` corren en Linux,
  junto con `herramienta_test_no_puede_leer_fuera_del_proyecto` y el
  lanzador de `project.rs`; los perfiles se prueban contra el kernel en
  `sandbox/tests/profiles.rs`.
- **Pendiente para dar L6 por hecha:** pasar las pruebas en Ubuntu 24.04 y en
  Fedora (necesita máquinas virtuales) y que Rubén vea desaparecer el aviso.

Lo que queda para el Mac está en `docs/pendiente-mac.md`.

| Fase | Estado | Commit | Validada por Rubén | Para la sesión del Mac |
|---|---|---|---|---|
| L0 | hecha | `5fdc89a` | | Nada: solo diagnóstico |
| L1 | hecha | `54436b9`…`c758503` | | `docs/pendiente-mac.md` |
| L2 | hecha | `e6fa7b8`…`6718249` | sí (2026-10-14) | `docs/pendiente-mac.md` |
| L3 | hecha | `9398936`…`51f61c0` | sí (2026-10-14) | `docs/pendiente-mac.md` |
| L4 | hecha | `7b27d68`…`7c2205b` | sí (2026-10-14) | `docs/pendiente-mac.md` |
| L5 | hecha | ver «L5 en Ubuntu 25.10» | sí (2026-10-14) | `docs/pendiente-mac.md` |
| L6 | construida; falta 24.04 y Fedora | ver «L6 en Ubuntu 25.10» | | `docs/pendiente-mac.md` |
| L7 | pendiente | | | |

Matriz de L7 (✓ instala y arranca, reproduce m4a, graba y transcribe):

| Sistema | x86_64 | arm64 |
|---|---|---|
| Ubuntu 24.04 | | |
| Ubuntu 26.04 | | |
| Debian 13 | | |
| Fedora (última) | | |
| Fedora (penúltima) | | |
