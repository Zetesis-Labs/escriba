# Pendiente en el Mac

Lo que la iniciativa de Linux deja por hacer en macOS, en orden. En Ubuntu no
se compila Swift ni el código de Rust que solo existe en macOS, así que nada de
esto está probado. Al cerrar un punto, se borra de aquí y se apunta en el
Registro de `docs/plan-linux.md`.

## 1. Varios modelos de Whisper local

Spec: `specs/escriba/modelos-whisper/functional-specs.md`. Rust, el controlador
y la interfaz ya lo tienen; en Linux está validado. En el Mac falta el host de
Swift, y por eso el «+» de STT no ofrece modelos locales.

- **`models`** en `Sources/EscribaNativeHost/NativeHost.swift`: devuelve
  `{default, models: [{model, label, bytes, installed}]}`, como en
  `docs/tauri-native-protocol.md`. `default` es
  `WhisperKitBackend.defaultVariant`.
  - Pista: un catálogo fijo de variantes de WhisperKit con su tamaño
    aproximado, como `MODELS` en `native-host/src/platform/linux/mod.rs`, sin
    red para listar.
  - `installed` sale de `WhisperKitBackend.installedModelFolder(variant:)`. Si
    está instalado, `bytes` es el tamaño real de esa carpeta.
- **`deleteModel`**: borra solo la carpeta que devuelve
  `installedModelFolder(variant:)`. Si no existe, responde `model_missing`. Si
  el motor tenía cargada esa variante, la descarga antes de borrar.
- Mientras Swift no los tenga, `whisper_model` en `src-tauri/src/lib.rs` usa el
  comportamiento anterior: mide la carpeta de modelos y solo borra el de serie,
  borrando la carpeta entera. Con `deleteModel` ese camino deja de usarse en el
  Mac. Comprobar que borrar el de serie no se lleva los demás modelos.
- Con el catálogo, el «−» también quita el Whisper de serie (hoy está
  desactivado en el Mac porque no podría volver con «+»). Comprobar que una
  receta sin STT pasa al primer Whisper local que quede.
- Comprobar en la app:
  - Añadir un modelo, descargarlo con progreso y transcribir con él.
  - Dos modelos distintos no reutilizan la misma transcripción.
  - «Quitar» no borra del disco y pasa sus recetas al de serie.
  - Detectar hablantes funciona con un modelo añadido.
- Comprobar `ESCRIBA_NATIVE_HOST=<EscribaNativeHost> cargo test --test contract`
  desde `apps/tauri/native-host`: `el_catalogo_de_modelos_tiene_el_de_serie_y_tamanos`
  debe pasar.

## 2. Protocolo: lo que Swift no cumple

- **`recordingStatus` no devuelve `paused`**, que el protocolo pide. Basta con
  `false` mientras el Mac no pause.
- **`recordingPause` y `recordingResume`** solo existen en Linux. Antes de
  hacerlos, Rubén tiene que decidir si hay botón de pausa en el panel: solo
  Linux, los dos sistemas o ninguno.
- Pasar la batería común contra el host de Swift y corregir lo que falle.

## 3. Grabar y leer archivos con el host de Rust (ADR-0010, decisión 3)

En el Mac pasan a Rust la grabación (AAC con AudioToolbox), `audioInfo`,
`fileStatus` y `materialize`, sin cambios visibles. Swift se queda con
WhisperKit, SpeakerKit y FoundationModels.

- Crear `native-host/src/platform/macos/` con los mismos nombres que
  `platform/linux/`:
  - `Encoder` y `ENCODER_RATES`: AAC mono en m4a a 48 kHz, como hoy en
    `AVAudioRecorder`.
  - `file_flags`: `st_flags`.
  - `dataless`: `SF_DATALESS`.
  - `materialize`: pedir la descarga de iCloud y leer un byte con tiempo
    límite, como `requestMaterialization` de Swift. Ojo: hoy el de Swift admite
    `folderBookmark` y el de Rust no lo lee.
  - `Inference`: en el Mac la inferencia sigue en Swift. Hay que decidir si
    `Inference` de macOS responde `backend_unavailable` o si el host de Rust ni
    lo enlaza.
- Rust lanza los procesos por papel (`lib.rs`: `materializer`, `inference` y
  `recorder`). `recorder` y `materializer` pasan al binario de Rust y
  `inference` sigue con el de Swift. `status` se reparte entre los dos.
- La captura con cpal ya funciona en macOS; falta comprobar el diálogo de
  permiso de micrófono y que el permiso ya concedido se conserva al instalar
  con la firma estable.
- Mismas pruebas: la batería común y `tests/linux.rs`, con su equivalente para
  m4a, contra el host de Rust en el Mac.

## 4. Compilar lo movido y pasar la suite

Código del Mac que se movió tal cual desde Linux, sin compilarlo:

- `process_probe.rs`: `resident_bytes` y `process_identity` con
  `proc_pidinfo`.
- `folder_access::choose`: el selector sigue abriéndose en el hilo principal.
  También `folder_access::restore_saved`.
- `symbols/macos.rs` (SF Symbols) y `platform::file_flags` (`st_flags`).
- `platform::MACOS` y `platform::voice_memos_root`.
- `confinement.rs`: los perfiles de `sandbox-exec` (receta, herramienta e
  instalación) se movieron allí desde `scripts.rs` y `project.rs`, con los
  mismos textos; el lanzador `./escriba` debe generarse igual.
- `install_app_menu` y `open_panel` se llaman según `PLATFORM`. La URL del
  panel ya no lleva `&platform=` y el panel toma el macOS por defecto.
- El controlador recibe `ESCRIBA_PLATFORM` y toma de ahí el modelo de serie, si
  hay LLM incluido y si las carpetas necesitan autorización.
- La grabación se llama `.m4a` por `platform::RECORDING_EXTENSION`.
- De fases anteriores:
  - Con `runtime-host/targets.mjs`: `prepare.mjs`, `build.mjs` (`codesign` solo
    en macOS) y el binding de SurrealDB `darwin-<arch>`.
  - En `native.rs`, el triple `*-apple-darwin` sale de
    `TAURI_ENV_TARGET_TRIPLE`.
  - `sandbox-exec` va detrás de `platform::recipes_isolated()`, y el lanzador
    de `project.rs` debe generarse idéntico.
  - En pruebas, `storage::engine` abre la base en un runtime compartido.
  - `tests/runtime/project.test.ts` usa `realpath(tmpdir())`.
- El borrado pendiente de una copia de audio guarda también su fecha de
  creación (`birth`) y exige que coincida, porque ext4 reutiliza el inodo. Los
  descartes ya guardados sin ella se comprueban como antes. Descartar una nota
  en el Mac debe seguir borrando su copia.

Después, la suite completa del bloque «Construir y comprobar» del `CLAUDE.md`,
con `sidecar.test.ts` entero, incluidas sus pruebas de aislamiento.

## 5. Comprobar en pantalla que nada cambió

Con la app instalada:

- Menú de la app con ⌘N.
- Panel de grabación flotante con Liquid Glass.
- En Ajustes: Notas de Voz, «Autorizar…» y «Acceso total al disco».
- Apple Intelligence en LLMs.
- Textos con «Finder» y ⌘.
- «Descargar (unos 3 GB)».
- Iconos de la bandeja.
- Abrir una carpeta vigilada y autorizarla de nuevo.

## Deudas conocidas, sin encargo

- Hay dos nombres para el Whisper local del Mac: el resolutor se guarda como
  «Whisper · en este Mac» y la interfaz dice «Whisper en este Mac». Ya era así
  en `main`.
- El modelo de serie del Mac está en `WhisperKitBackend.defaultVariant` y en
  `platform::MACOS`.
