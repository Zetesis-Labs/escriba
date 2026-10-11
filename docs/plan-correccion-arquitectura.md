# Plan de corrección de arquitectura

Revisión del 2026-10-11 sobre `origin/main` (`5286bbf`) y
`origin/feat/filtros-biblioteca` (`150775b`). Este documento es el encargo para
la sesión que ejecute los arreglos. Leerlo entero antes de tocar nada; cada
fase dice qué se cambia, dónde, qué tests se escriben antes y cómo se cierra.

«De un tirón» significa una pila de ramas sobre `feat/filtros-biblioteca`, un
PR por bloque cerrado y rebase, no un commit único. Commits convencionales en
castellano, sin trailers de IA. Sin push ni merge salvo que Rubén lo pida.

## Decisiones que solo toma Rubén

Resueltas por Rubén el 2026-10-11: 1, retirar la pila de recetas Swift y los
jobs Linux/WASI; 2, conservar el CLI; 3, **mantener las palabras** en la
proyección (su coste venía de reproyectar de más, que corrigen A y G);
4, enum único; 5, conservar el SDK de SurrealDB con test de versiones.

1. **Pila de recetas en Swift.** `Sources/EscribaCore/{Recipe,RecipeBook,RecipeForm,RecipeProject,RecipeTemplate}.swift`,
   `Sources/EscribaEngine/{Recipe,RecipeSession,RecipeShelf,RecipeProject}.swift`,
   `Sources/EscribaSystemKit/RecipeProjectFolder.swift` (2.679 líneas), más
   `scripts/build-recetas.sh` y su paso de CI, y los jobs `linux` y `wasi` de
   `ci.yml`. Ningún binario publicado los ejecuta: el CLI construye `Pipeline`
   sin receta y `EscribaNativeHost` solo usa `Transcript`, `TranscriptSegment`,
   `DataValue`, `AnswerSchema`, `SpeakerVoice`/`SpeakerSpan`,
   `TranscriptionOptions`, los puertos `TranscriptionBackend`/`Summarizer`/`Asker`
   y `Log`. **Recomendado: retirar todo eso y los dos jobs de CI.**
2. **CLI `escriba`.** Producto aparte con ledger SQLite y biblioteca GRDB, sin
   datos compartidos con la app. **Recomendado: conservarlo tal cual en esta
   pasada**, sin añadirle nada; decidir su retirada en otro encargo.
3. **Granularidad de la proyección en `knowledge.surrealkv`.** Hoy se copian
   grabación, versión, transcripción, segmentos, hablantes y palabras con sus
   aristas (`knowledge/base.rs:179-340`). **Recomendado: segmentos siempre,
   palabras solo si una ontología instalada las declara como dependencia.**
4. **Mecanismo del contrato Rust ↔ TypeScript** (fase C): enum único etiquetado
   o comandos Tauri tipados. **Recomendado: enum único**, porque conserva el
   despacho actual y el cambio es incremental.
5. **SDK de SurrealDB dentro de las recetas** (ADR-0006). El motor RPC emulado
   declara al SDK 2.1.1 un servidor «3.3.2» (`runtime/knowledge.ts:36-108`).
   **Recomendado: conservarlo** con un test que fije la pareja de versiones; la
   alternativa es una API mínima `grafo.query(sql, bindings)`.

## Restricciones que no se negocian

- Las bibliotecas existentes siguen abriendo. Esquema `2` → `3` con migración
  en `Store::open`, datos conservados, nunca abrir vacía una base que no se ha
  podido leer. Identificadores y directorios de datos no se renombran.
- Prueba de aceptación de toda fase de persistencia: copia privada de la
  biblioteca real (hoy 242 grabaciones y 218 versiones) abre, convierte y
  devuelve los mismos datos por el modelo tipado. Es el procedimiento ya
  usado en `docs/pendiente-tauri.md`, apartado 8.
- `Field<T>` y `#[serde(flatten)] extra` existen para conservar campos
  ausentes, nulos y extensiones. Las escrituras por entidad los mantienen.
- SurrealDB, Tauri y Bun se quedan. No se reabre ninguna de las tres.
- Tests primero en cada fase: suite vertical con nombres de comportamiento en
  castellano, decisiones en funciones puras (`src/core/`, módulos Rust sin E/S).
- Una fase cierra cuando Rubén la valida en la app instalada. Instalar y avisar
  al terminar; no reinstalar mientras prueba.

## Fase A. Persistencia: escrituras por entidad

**Problema.** `persistence.rs:862-1130` aplana el documento entero antes y
después de cada mutación y escribe la diferencia. `logs.insert(0, …)`
(`store/mutations.rs:68`) desplaza la `position` de hasta 3000 filas y las
reescribe en cada línea de registro. `store/import.rs:338` y
`store/recordings.rs:154` insertan la grabación nueva en la posición 0, así que
cada importación reescribe todas las filas `recording`. `library_view.rs:189`
envía los 3000 registros a la WebView en cada refresco.

**Cambio.**

- `Persistence` expone operaciones por entidad en lugar de `save(before, after)`:
  `upsert_recording`, `remove_recording`, `upsert_version`, `remove_version`,
  `upsert_publication`, `remove_publication`, `upsert_catalog_item(table, …)`,
  `set_setting`, `append_log`. Cada mutación de `store/mutations.rs` declara
  qué filas toca; `WriteScope` pasa a ser la lista explícita de operaciones.
  Las transacciones que hoy agrupan versión + huellas + borradores + lápida se
  conservan como una sola operación compuesta.
- `position` desaparece de `recording`, `version` y `publication`. La UI ya
  ordena por `createdAt` (`library/model.ts:95` y `:6`); el detalle ordena por
  `createdAt` y desempata por `id`. Se conserva `position` solo en los
  catálogos ordenados por el usuario (`resolver`, `recipe`, `destination`,
  `account`, `provider`) si la UI depende del orden; comprobarlo con `grep`
  antes de decidir.
- Los registros salen de `LibraryData`: tabla `log` append-only con `at`,
  `level`, `recordingId`, `recipeId`, `message`; comando nuevo
  `log_list {recordingId?, before?, limit}` paginado. `library` y `snapshot`
  dejan de incluir `logs`. La sección Registro de la UI pagina.
- Migración a esquema `3`: elimina `position` donde ya no se usa, mueve los
  `log` existentes a la tabla nueva y actualiza `meta:schema`. Una sola
  transacción; si falla, la apertura falla visible.
- `flatten_with_scope` y el diff se borran, no se dejan como ruta alternativa.

**Tests antes de implementar** (`store/tests.rs`, `persistence/tests.rs`,
`store/knowledge.rs` tests):

- «registrar una línea escribe exactamente una fila y no toca `recording`».
- «importar una nota escribe una fila `recording` y ninguna de las demás».
- «la grabación nueva aparece primera en la lista aunque no tenga `position`».
- «una biblioteca de esquema 2 con 3000 registros abre en esquema 3 con los
  mismos registros paginados y las mismas versiones».
- «`knowledge_changed` se dispara solo para la grabación modificada».
- Rendimiento orientativo, no bloqueante: 1000 líneas de `log` con 300
  grabaciones por debajo de 1 s en SurrealKV temporal.

**Cierre.** Suite Rust y TypeScript, Clippy y formato; copia privada intacta;
Registro paginado visible en la app instalada; Rubén valida.

**Desbloquea** B (menos tiempo bajo el cerrojo) y G (el journal deja de
dispararse por desplazamientos).

## Fase B. Cerrojos y colas

**Problema.** Un `std::sync::Mutex<Store>` serializa toda lectura y escritura
(`lib.rs:71`); los handlers async bloquean en él y luego en un canal síncrono
hacia el hilo de SurrealDB (`persistence.rs:371`). La cola admite un solo job
`Running` global (`jobs.rs:240`) y el controlador TypeScript encadena otra
promesa (`controller.ts:168-200`). En la rama, `Knowledge.root` se retiene
durante todo el filtro (`filters.rs:62`) y `synchronize_base` corre antes del
filtro sin límite (`knowledge_commands.rs:110-135`).

**Cambio.**

- `Persistence::request` pasa a `async` con `tokio::sync::oneshot`; el hilo con
  su runtime propio se conserva.
- `Store` pasa detrás de `tokio::sync::Mutex` y sus métodos a `async`. Hay 53
  puntos en `lib.rs` y 2 en `recorder.rs`; `jobs.rs` y `knowledge_commands.rs`
  también lo toman. Regla: ningún guard cruza una llamada a la red, al proceso
  nativo ni al runtime de recetas. `spawn_blocking` solo para CPU y disco
  puros (escaneo, hash de audio).
- La cola gana carriles: `inference` (serie, porque hay un solo proceso de
  inferencia) y `io` (publicar, resumir con proveedor remoto, previsualizar,
  descubrir; concurrencia 3). `JobOperation` declara su carril; `claim` toma
  el primer job de cada carril libre. La exclusividad por grabación se
  mantiene en Rust.
- Se borra la cadena `queue` del controlador; `runJob` conserva solo la
  exclusividad por `recordingId` y la cancelación nativa.
- `Knowledge.root` se suelta entre sentencias: cada consulta toma el cerrojo,
  ejecuta y lo libera; la correlación de resultados se hace fuera.
- `synchronize_base` deja de ejecutarse delante de filtros y grafo: pasa a un
  job del carril `io` encolado tras cada commit de biblioteca que marque
  filas sucias, con progreso en `runtime_jobs`. Filtros y grafo leen la
  proyección que haya y la UI indica «sincronizando N pendientes» si el
  journal no está vacío.

**Tests antes de implementar.**

- «refrescar la biblioteca no espera a que termine `version_save`».
- «una transcripción en curso no impide publicar otra nota».
- «dos trabajos sobre la misma grabación nunca corren a la vez».
- «el filtro responde con la proyección disponible y comunica pendientes».
- «la sincronización de la base avanza por lotes y sobrevive a un cierre».

**Cierre.** Igual que A, más medición de latencia de `library` durante un
`version_save` sintético (antes y después, en `rendimiento-escriba.md`).

## Fase C. Contrato Rust ↔ TypeScript generado

**Problema.** `app_command(method: String, params: Value) -> Result<Value, String>`
(`lib.rs:98`), `Store::mutate(method, &Value)` y `knowledge_commands.rs:136`
despachan por cadenas. Cinco definiciones a mano de Transcript/Version/Recording:
`store/model.rs`, `src/types.ts`, `packages/conectores/src/types.ts`,
`recetas/escriba-recetas.d.ts`, `EscribaCore/Transcript.swift`.
`src/knowledge/model.ts` repite además los validadores en tiempo de ejecución.

**Cambio (según decisión 4, recomendado enum).**

- Un `enum Command` con `#[serde(tag = "method", content = "params", rename_all = "snake_case")]`
  y una variante por comando con sus parámetros tipados; `dispatch` hace
  `match` exhaustivo. `app_command` deserializa a ese enum y devuelve un
  `enum Reply` o tipos concretos por variante.
- Los tipos de `src/types.ts` y `src/knowledge/model.ts` se generan desde Rust
  a `apps/tauri/src/generated/`. El implementador verifica, no asume, que el
  generador elegido (`ts-rs` o `specta`) soporta `#[serde(flatten)]` y el
  serializador propio de `Field<T>`; si no, se anota con el atributo de
  override del generador. Un test de CI falla si los ficheros generados no
  coinciden con el código.
- Los validadores manuales de `model.ts` (`isInstalledOntology`,
  `isCollection`, `isRecordPage`) se sustituyen por esquemas Zod generados
  o se eliminan si el tipo generado basta en la frontera IPC.
- `packages/conectores/src/types.ts` (`Note`) y `recetas/escriba-recetas.d.ts`
  se quedan como contratos externos independientes, pero con un test que
  compara su forma con los tipos generados (los dos son API pública de
  terceros y cambian con versión).
- Empezar la vertical por el módulo `knowledge`: sus structs ya son limpios y
  tiene 17 comandos.

**Tests antes de implementar.**

- «un método desconocido falla al deserializar, no en tiempo de ejecución».
- «cada variante del enum tiene un comando en `CONTRACT.md`» (test que lee el
  Markdown; luego el Markdown se genera o se recorta a prosa).
- «los tipos generados coinciden con el código» (CI).

## Fase D. Una sola receta por defecto

**Problema.** `recetas/por-defecto/receta.ts` lo incrusta Rust
(`project.rs:24`), lo importa la app por ruta relativa
(`runtime/defaultRecipe.ts:2`) y lo convierte un script en
`EscribaCore/RecipeTemplate.swift`. `worker.ts:230-262` reimplementa el mismo
flujo inline cuando no hay programa.

**Cambio.**

- El worker ejecuta siempre un programa compilado; la receta por defecto se
  compila en `runtime-host/build.mjs` a `__DEFAULT_RECIPE__` igual que
  `__BUILTIN_PROGRAM__`. Se borra la rama inline de `worker.ts`.
- `runtime/defaultRecipe.ts` deja de importar fuera de `apps/tauri`: el
  formulario por defecto se obtiene ejecutando `buildRecipeForm` del programa
  compilado en el worker (`recipe-schema` ya existe).
- `recetas/` tiene un único consumidor en build: `project.rs` con
  `include_str!` para inicializar proyectos. Un test compara que la receta
  incrustada y la compilada en el runtime salen del mismo fichero.
- `RecipeTemplate.swift` y `build-recetas.sh` desaparecen con la decisión 1.

**Tests.** «sin programa de proyecto, el worker ejecuta la receta por defecto
compilada y produce la misma versión que antes» (fixture con host falso de
`tests/runtime/sidecar.test.ts`).

## Fase E. Swift (según decisiones 1 y 2)

- Borrar la pila de recetas y sus tests (`Tests/EscribaCoreTests/{FormularioDeReceta,LibroDeRecetas,ProyectoRecetas,RecetaContrato,RecetaPorDefecto,TrazaDeReceta}Tests.swift`,
  `Tests/EscribaEngineTests/{Receta*,Parametros*,PasarGrabacion,Preguntar*,Probar*,Proyecto*,Recetas*,Memoria*,Depurar*,VersionPorEjecucion}Tests.swift`
  y los de SystemKit que dependan de `RecipeProjectFolder`). Confirmar cada
  borrado con `swift build --product EscribaNativeHost` y `swift build --product escriba`.
- `Package.swift`: quitar los jobs y condiciones de Linux/WASI si la decisión 1
  lo confirma (`CSQLite`, `escriba-wasm-probe` ya no existe); `ci.yml` se
  queda con el job `macos`.
- `Pipeline` pierde el parámetro `recipe` opcional si nada lo pasa.
- No tocar `EscribaStore` ni `Ledger` mientras el CLI se conserve.

## Fase F. Topología de procesos

- `workerClient.ts:19`: eliminar el `new Worker(...)` de navegador por defecto;
  `WorkerPort` tiene una sola implementación, la de proceso. Eliminar el modo
  demo (`src/app/demo.ts`, `src/knowledge/demo.ts`, `demoDraftHost.ts`,
  `?demo=1` en `useAppData.ts`) y la ejecución de conectores en la WebView
  (`runtime/index.ts`, rama `!desktop`); los tests de UI que lo usaban pasan a
  fixtures.
- Si la decisión 5 conserva el SDK: test que fija `surrealdb` 2.1.1 ↔ versión
  emulada «3.3.2» ↔ `surrealdb` Rust `=3.3.2`, y falla si una cambia sin las
  otras.
- `sandbox-exec` va al registro de riesgos (abajo), no a esta pasada: no hay
  sustituto público sin adoptar App Sandbox.

## Fase G. Conocimiento

Depende de A (sin desplazamientos de `position` el journal deja de dispararse
por todo) y de B (sincronización en segundo plano).

- `persistence/knowledge.rs:28`: el `EVENT` compara `payload`, no la fila
  entera.
- Journal por versión, no por grabación: clave `version:<recording>:<id>` con
  hash del contenido guardado en `knowledge_meta`; una versión cuyo hash no
  cambia no se reproyecta. Los cambios de metadatos de la grabación proyectan
  solo la fila `recording`.
- Granularidad según decisión 3; si palabras es opt-in, el manifiesto de la
  ontología declara `requires: ["word"]` y la proyección las omite si ninguna
  instalada lo pide.
- La garantía de solo lectura del SurrealQL del usuario pasa a ser de la base:
  el principal `RECORD` de cada ontología solo tiene `PERMISSIONS FOR select`
  y `NONE` para create/update/delete; el guard del AST
  (`knowledge/base_query.rs`) queda como defensa en profundidad. Con eso,
  `surrealdb-core` y `surrealdb-expr` dejan de ser la única barrera y la
  fijación `=3.3.2` puede relajarse al crate público cuando convenga.
- Tests: «dos ediciones del título de una grabación con 3 versiones no
  reproyectan ninguna versión»; «un UPDATE lanzado por el principal de la
  ontología falla por permisos aunque el guard del AST se desactive».

## Fase H. Decisiones registradas

- ADR-0003: nota de corrección Deno → Bun con fecha.
- ADR-0007: este plan, con las decisiones 1-5 resueltas y la fecha.
- `CLAUDE.md`: retirar «el núcleo viaja» y los comandos de Linux/WASI si la
  decisión 1 lo confirma; una sección por app (ya pedido en
  `pendiente-tauri.md`, apartado 9).
- `CONTRACT.md` se recorta a prosa sobre límites; la lista de comandos sale
  del enum (fase C).

## Fase I. Fuera de alcance de esta pasada

- Notarización y release descargable: encargo propio.
- Retirada del CLI (decisión 2).
- Sustituto de `sandbox-exec`.
- Madurez de SurrealDB 3.3: no evaluada.

## Qué no tocar

- El patrón tipado del módulo `knowledge` (structs, `RecordId` nativos,
  SurrealQL directo) es la referencia para la fase A.
- El journal `knowledge_dirty` → UPSERT → acuse por revisión es idempotente y
  sobrevive a un cierre; se conserva y solo cambia su granularidad.
- El guard del AST de `base_query.rs` se conserva.
- Los nombres de tabla y campo de los filtros visuales pasan por el manifiesto
  antes de interpolarse; no hay inyección que corregir.
- Los límites verificados del runtime (32 MiB por trama, 512 MiB por worker,
  10 s de CPU, 8 workers) y sus tests.

## Registro de riesgos

| Riesgo | Mitigación en este plan |
|---|---|
| Migración a esquema 3 corrompe una biblioteca | Copia privada como prueba de aceptación; apertura falla visible; `library.surrealkv` se copia a `.bak` antes de migrar |
| `sandbox-exec` obsoleto en Apple | Sin arreglo; repetir las pruebas de aislamiento en cada macOS/Bun nuevo |
| Fijación `=3.3.2` de crates internos | Permisos de base como barrera principal (G) |
| Generador de tipos no soporta `Field<T>` | Verificar antes de elegir; override por atributo; en último caso `Field<T>` se serializa a `Option<T>` en la frontera generada |
| Rama de 11.000 líneas sin validar en pantalla | Cada fase cierra con Rubén en la app instalada |

## Orden de la pila de PRs

1. A (persistencia) → 2. B (cerrojos y colas) → 3. G (conocimiento) →
4. C (contrato, empezando por `knowledge`) → 5. D (receta única) →
6. F (topología) → 7. E (Swift) → 8. H (decisiones).

A, B y G son los que cambian el comportamiento observable; C, D, F y E son
borrado y tipado y pueden ir en paralelo con ramas separadas una vez cerrada B.

## Ejecución

- **Fase A** (2026-10-12). Las mutaciones siguen editando una copia tipada
  del índice; `persistence/changes.rs` calcula por identidad las filas
  cambiadas y el escritor ejecuta solo esas. Se descartaron las operaciones
  escritas a mano en cada mutación: `config_remove` y las migraciones del
  arranque tocan referencias repartidas por varios catálogos, y una
  operación olvidada sería pérdida silenciosa. Las grabaciones se ordenan por
  `createdAt`; versiones, recibos y catálogos conservan `position`. El
  registro vive en su tabla con `log_list` y el evento `escriba://log`. No se
  sube el esquema a 3: no hay incompatibilidad y la versión anterior sigue
  abriendo la biblioteca. Medido de paso: cada commit de SurrealKV cuesta del
  orden de 30 ms por la sincronización del WAL.
