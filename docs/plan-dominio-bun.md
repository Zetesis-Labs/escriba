# Plan: el dominio en Bun y Rust como cáscara

Ejecuta el ADR-0011 (`docs/adr/0011-dominio-en-bun-rust-cascara.md`). Encargo
de Rubén del 2026-10-13: «implementación completa de la separación y
simplificación de Rust como cáscara para acceso al bajo nivel; Rust no tiene
que tener tanta responsabilidad salvo que esté debidamente justificada; de un
tirón». Rama `feat/dominio-bun` sobre `main` `cfffa83`.

## Antes de empezar

Leer `CLAUDE.md`, el ADR-0011, `apps/tauri/CONTRACT.md`,
`apps/tauri/runtime-host/README.md` y `docs/tauri-persistence.md`. El código
manda sobre los documentos.

Reglas de trabajo de Rubén:

- Cada vertical es una **vertical**: primero su batería de tests, después el
  código. Una vertical está **hecha** cuando Rubén la ve funcionar en la app
  instalada, no cuando pasan los tests. Al cerrar una que se vea en pantalla:
  instalar, avisar en una línea y seguir; nunca reinstalar mientras prueba sin
  avisar.
- Respuestas cortas. Sin preguntas entre verticales: solo por un hecho que
  únicamente Rubén conoce.
- Commits convencionales en castellano, uno por vertical, sin trailers de IA.
  Sin push, merge ni PR salvo petición.
- Nunca texto de notas reales en logs, salidas ni commits. La copia de la
  biblioteca real vive fuera del repo y solo se le piden recuentos e ids.
- Nunca publicar en Notion real; pruebas con servidor local falso y audio
  sintético.

## Hechos comprobados (2026-10-13, Bun 1.3.0 y 1.4.2, macOS arm64)

- `@surrealdb/node` 3.1.0 (motor 3.3.4) con el SDK `surrealdb` 2.1.1 abre
  RocksDB y SurrealKV desde Bun, también compilado con `bun build --compile`.
  Una **copia de la biblioteca real** (`library.rocksdb`, creada por Rust
  3.3.2) se abre y se lee: 248 grabaciones, 240 versiones, 34 trabajos, 7
  personas, 55 huellas; `meta:schema`, `meta:preview_v1` y `meta:initialized`
  presentes. `knowledge.rocksdb` también: 44.519 segmentos proyectados.
- **RocksDB admite un solo proceso abierto a la vez**, y dentro del mismo
  proceso una segunda `Surreal` falla. Rust y el controlador no pueden
  compartir un almacén: el traspaso de cada almacén es un corte, no un
  degradado.
- El motor de Node **no tiene opción de autenticación**: `ConnectionOptions`
  solo admite `capabilities`, `defaults` y tiempos límite. Con una sesión
  `RECORD` (`signin` con `access`) `$auth` y `$session` se rellenan, `INFO FOR
  DB` se deniega por IAM y un `DEFINE EVENT` con `$auth != NONE` dispara, pero
  **los `PERMISSIONS` de tabla no se aplican**: un `CREATE` sobre una tabla con
  `FOR create NONE` se ejecuta. En Rust sí se aplican porque `Config::user`
  activa la autenticación. `BEGIN … CANCEL` funciona.
- `bun build --compile` no embebe el `.node` (40 MB). El cargador de
  `@surrealdb/node-native` honra `NAPI_RS_NATIVE_LIBRARY_PATH`: la app lo
  lleva como recurso y Rust fija esa variable al arrancar el controlador. Hay
  bindings para darwin y linux, x64 y arm64.
- El binario compilado muere con `SIGKILL` (137) hasta firmarlo;
  `runtime-host/build.mjs` ya lo firma.
- Bun 1.4.2 (el de `runtime-host/bun-version` y el del runtime instalado) no
  estaba en el equipo. Descargado en `.build/bun/1.4.2/bun-darwin-aarch64/bun`,
  que `scripts/build-app.sh` ya busca y `.gitignore` ignora.
- El controlador ya es de larga vida: `scripts.rs` solo lo reemplaza si murió.

## Qué se queda en Rust y por qué

| Pieza | Ficheros | Justificación |
| --- | --- | --- |
| Ventana, menús, bandeja, diálogos, eventos a la WebView, notificaciones, inicio de sesión, apariencia | `menubar.rs`, `login.rs`, `symbols.rs`, `appearance.rs`, `notification*.rs` | APIs del sistema |
| Bookmarks y FSEvents de carpetas vigiladas, descubrimiento de ficheros, materialización de iCloud | `folder_access.rs`, `watcher.rs` (parte de ficheros) | APIs del sistema y TCC |
| Supervisión del host nativo (framing, cancelación, descarga por inactividad) | `native.rs` | proceso del sistema |
| Captura del micrófono y muestras de voz (sesión de grabación, niveles, ficheros temporales) | `recorder.rs`, `recording.rs`, `voice_registration.rs` (captura) | AVFoundation vía host |
| Arranque y supervisión de procesos: controlador, recetas, herramientas del proyecto; perfiles de `sandbox-exec`; vigilancia de memoria | `scripts.rs`, `project.rs` (herramientas) | aislamiento |
| **Conocimiento** (`knowledge.rocksdb`): instalación de ontologías, validación de SurrealQL de solo lectura, sesión `RECORD` de las recetas, grafo, filtros | `knowledge*.rs`, `knowledge/` | necesita el parser (`surrealdb-expr`) para validar el AST y filtrar migraciones, y la autenticación embebida para que `PERMISSIONS` protejan a las recetas; el motor de Node no ofrece ninguna de las dos |
| Comandos de la cáscara y reenvío al controlador | `command.rs`, `lib.rs` (reducidos) | la costura |

Lo de conocimiento es la excepción justificada del ADR-0011: su almacén es
otro directorio RocksDB, así que Rust lo abre y el controlador no. Lo que
conocimiento necesita de la biblioteca (unidades a proyectar, notas vigentes,
catálogo de recetas, candidatas del proyecto) lo pide al controlador.

## Qué se mueve a Bun

| Bloque | Ficheros Rust | Tests Rust que son la especificación |
| --- | --- | --- |
| Biblioteca: modelo, índice ligero, detalle, versiones, borradores, publicaciones, personas y huellas, catálogos, ajustes, importación, proyecciones, conversión de esquemas, log | `store.rs`, `store/*`, `persistence.rs`, `persistence/*`, `library.rs`, `library/*`, `library_view.rs`, `catalog.rs`, `voices.rs` | `store/tests.rs` 81, `persistence/tests.rs` 10, `persistence/changes.rs` 10, `library/tests.rs` 3, `catalog.rs` 9, `library_view.rs` 6, `voices.rs` 5, `store/model.rs` 2, `store/measurement.rs` 3, `store/knowledge.rs` 5 |
| Cola de trabajos: carriles, reclamación, reintentos, cancelación, historial, relanzar, recuperación, purga, efectos externos inciertos | `jobs.rs` | `jobs.rs` 35, `lifecycle_tests.rs` 1 |
| Credenciales (ficheros 0600), transporte HTTP con secreto, resolutores remotos, prueba de resolutores | `remote.rs`, `capabilities.rs` (http, grant, audio) | `remote.rs` 3, `capabilities.rs` 6 |
| Reconocimiento de hablantes (coseno, umbral 0,30, una persona por hablante) | `voices.rs`, parte de `library.rs` | en `store/tests.rs` |
| Política de capacidades de recetas (tabla de 26 métodos) y «cada comando figura en el contrato» | `command.rs` | `command.rs` 5 |

Los tests Rust se portan uno a uno a vitest con el mismo nombre en castellano;
un test que no aplica se anota en el Registro con el motivo.

## Topología final

```
WebView ──invoke app_command──► Rust (cáscara)
                                  │ métodos de la cáscara: los resuelve
                                  │ el resto: trama `command` ──► controlador Bun
                                  │                                 │ biblioteca (RocksDB)
                                  │                                 │ cola, credenciales, HTTP
                                  │ ◄── trama `call` shell.* ───────┤ recetas: worker_* (como hoy)
                                  │ ◄── trama `event` ──────────────┘
                                  │ conocimiento (RocksDB) ◄── pide unidades al controlador
```

- **Rust → controlador**: trama `{type:"command", id, method, params, origin}`
  con `origin` `ui` o `shell`. Las recetas no pasan por aquí: sus capacidades
  las atiende el controlador directamente (`workerClient`), aplicando la tabla
  de política en TypeScript.
- **Controlador → Rust**: tramas `call` con métodos `shell.*`: `emit`,
  `notify`, `native` (estado, descarga de modelos, transcribir local,
  resumir local, huellas), `nativeCancel`, `open`, `reveal`, `openUrl`,
  `privacySettings`, `appearance`, `autostart`, `whisperModel`, `project.*`
  (herramientas en sandbox), `folder.*` (autorizar, escanear, materializar).
- **Eventos**: el controlador emite `changed`, `jobs`, `log`, `imported`,
  `project`, `voice-registration`; Rust los reenvía como `escriba://*`.
- **Arranque**: Rust lanza el controlador al abrir la app con la raíz de datos
  en `ESCRIBA_DATA` y `NAPI_RS_NATIVE_LIBRARY_PATH`; sin perfil de
  `sandbox-exec` (lee credenciales, abre la base y sale a la red). Las recetas
  y las herramientas del proyecto conservan sus perfiles.
- **Inversión en la cáscara**: vigilancia, grabadora y registro de voz dejan
  de llamar a `state.library`; Rust descubre ficheros, captura audio y extrae
  huellas, y envía al controlador `incorporate`, `recorded`, `voiceSample`.
  El controlador decide: deduplicación, lápidas, identidad estable, persistir.

## Verticales

### V0. Preparación

Plan, corrección del ADR-0011 con los hechos de arriba, Bun 1.4.2 local.
`spikes/surreal-bun/` guarda las sondas (`access*.ts`, `inspect.ts`).

**Hecho cuando** el plan y el ADR están commiteados en `feat/dominio-bun`.

### V1. Fontanería

Tests primero: vitest del protocolo (trama `command` con `origin`, respuesta
`result`/`error`, `call` `shell.*`, reenvío de `event`) con un stdio falso; en
Rust, test de que `app_command` reenvía todo método que no sea de la cáscara.

- `runtime-host/main.ts`: atender `command`; `host.call` acepta `shell.*`.
- `scripts.rs`: arrancar el controlador en `setup`, sin sandbox cuando
  `worker=false`, con `ESCRIBA_DATA` y `NAPI_RS_NATIVE_LIBRARY_PATH`.
- `lib.rs`: lista de métodos de la cáscara; el resto se reenvía. Reenvío de
  eventos del controlador a la WebView.
- `tauri.conf.json` y `prepare.mjs`: el `.node` como recurso.
- `app_command` conserva `log` por el controlador como primer método movido.

**Hecho cuando** la app instalada arranca con el controlador vivo desde el
inicio, el Registro muestra una línea escrita a través del controlador y
`npm test`, `cargo test --lib`, clippy y fmt pasan.

### V2. Credenciales, HTTP y resolutores remotos

Tests primero: portar `remote.rs` (3) y `capabilities.rs` (6) a vitest con un
servidor HTTP local falso; política: la receta nunca recibe el secreto ni la
cabecera `Authorization` en la respuesta.

- `src/runtime/credentials.ts`: ficheros 0600 en `secrets/`, lectura y
  escritura atómica.
- `src/runtime/http.ts`: `http_with_grant` (origen, cabeceras, sin redirects,
  multipart con audio por rango, redacción del secreto en errores).
- `src/runtime/remote.ts`: `models`, `probe`, `transcribe`, `ask`, esquema del
  resumen.
- Se mueven `credential_save`, `connector_http`, `resolver_models`,
  `resolver_try`, `connector_audio` y la rama remota de `transcribe`,
  `summarize` y `ask`; la rama local sigue por `shell.native`.
- Rust pierde `remote.rs` y la parte HTTP de `capabilities.rs`.

**Hecho cuando** en la app instalada un resolutor remoto se prueba desde STT
o LLMs y una nota se procesa con él, y pasan los tests.

### V3. Biblioteca en Bun (sin traspaso)

Tests primero: portar `store/tests.rs`, `persistence/*`, `library/tests.rs`,
`catalog.rs`, `library_view.rs`, `voices.rs`, `store/model.rs`,
`store/measurement.rs`, `store/knowledge.rs` a `tests/runtime/library/`,
contra un RocksDB temporal real con `@surrealdb/node`.

- `src/runtime/library/`: `schema.ts` (tablas, índices, `meta:schema` 2,
  conversión de esquema 1 y de `library.json`, marca `preview_v1`),
  `model.ts` (tipos serde → Zod), `index.ts` (índice ligero y vistas),
  `changes.ts` (diff puro por identidad), `writer.ts` (transacciones y
  efectos: proyecciones, cascadas, huellas, borradores, alias),
  `recordings.ts`, `versions.ts`, `drafts.ts`, `people.ts`, `voices.ts`
  (coseno, umbral 0,30), `configuration.ts`, `settings.ts` (`SETTABLE`),
  `import.ts` (copia y hash de audio, deduplicación, identidad estable de
  carpeta vigilada, lápidas, `audio_deletion`), `log.ts` (3000 líneas),
  `memory.ts`, `traces.ts`, `catalog.ts` (instalación transaccional del
  proyecto), `knowledgeFeed.ts` (`knowledge_dirty`, `knowledge_meta`,
  unidades públicas para Rust).
- Nada se conecta aún a la app: Rust sigue siendo el dueño en producción.

**Hecho cuando** todos los tests portados pasan en vitest contra RocksDB y
una copia de la biblioteca real se abre, se lista y se lee el detalle de una
grabación sin error (solo recuentos en la salida).

### V4. Cola en Bun (sin traspaso)

Tests primero: portar `jobs.rs` (35) y `lifecycle_tests.rs`.

- `src/runtime/queue.ts`: `Job`, carriles (inferencia 1, red 3), `claim`,
  `finish`, reintentos por `errorCode`, `cancel`, `relaunch`, `wait`,
  historial paginado, purga por días, recuperación al abrir, bloqueo por
  `accountEffectPending`, trabajos automáticos.
- `controller.ts` ejecuta las operaciones de sus propios trabajos; los
  `stages` dejan de viajar por Rust.

**Hecho cuando** los tests pasan y, en el test de ciclo de vida, matar el
proceso tras un commit no pierde ni duplica trabajos.

### V5. El traspaso

Tests primero: en Rust, `watcher`, `recorder` y `voice_registration` con un
controlador falso; en vitest, los comandos de la UI contra la biblioteca
(`library`, `recording_detail`, `runtime_context`, `snapshot`, personas,
borradores, ajustes, conectores).

- El controlador abre `library.rocksdb` al arrancar; Rust deja de abrirla
  (`open_library` desaparece, `close_library` también).
- `command.rs` queda con los métodos de la cáscara; el resto son tipos
  TypeScript en `src/runtime/commands.ts` con su política y el test de los 26.
- `watcher.rs` envía `incorporate`; `recorder.rs`, `recorded`;
  `voice_registration.rs`, `voiceSample`; `menubar.rs` pide el estado al
  controlador. `knowledge_commands.rs` pide al controlador lo que leía de
  `library`.
- Borrar `store/`, `persistence/`, `library.rs`, `library/`,
  `library_view.rs`, `catalog.rs`, `jobs.rs`, `voices.rs`, `remote.rs`, la
  parte HTTP de `capabilities.rs` y las dependencias de `Cargo.toml` que
  queden sin uso. `src/generated` solo con lo que Rust sigue respondiendo.
- Antes de instalar: abrir la copia de la biblioteca real desde la app con
  `ESCRIBA_TAURI_DATA` apuntando a ella y comprobar lista, detalle, Personas,
  Trabajos, Registro y un procesado.
- Comprobar TCC: el controlador lee un audio de `~/Documents` o `~/Downloads`
  sin un segundo permiso; si no, Rust conserva `shell.copyIntoLibrary`.

**Hecho cuando** la app instalada abre la biblioteca de Rubén con todo lo de
antes, procesa una nota, publica contra el servidor falso, registra una voz y
reconoce, y pasan `npm test`, `cargo test --lib`, clippy, fmt y
`typecheck:runtime`.

### V6. Limpieza

`CONTRACT.md`, `runtime-host/README.md`, `docs/tauri-persistence.md`,
`CLAUDE.md` (límites de módulos, «credenciales en Rust» → controlador,
huellas en el controlador), ADR-0011 con el resultado, `docs/plan-linux.md`
(L1 y L2 se simplifican: menos Rust que limpiar).

**Hecho cuando** los documentos describen el código y no queda ninguna
referencia a módulos borrados.

## Registro

| Fecha | Vertical | Estado | Notas |
| --- | --- | --- | --- |
| 2026-10-13 | V0 | hecha | plan, ADR corregido, Bun 1.4.2 local |
