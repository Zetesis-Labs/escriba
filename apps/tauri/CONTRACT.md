# Escriba — contrato de integración

Una aplicación: **Escriba.app** (ADR-0005). El identificador técnico
`dev.zetesis.escriba.tauri` mantiene la ubicación de datos y los permisos.
`ESCRIBA_TAURI_DATA` selecciona una biblioteca aislada para pruebas.
No pruebas contra Notion ni tokens reales.

TypeScript: UI React, formularios Zod, recetas, conectores npm y orquestación en un proceso propio.
Rust: SurrealDB, cola duradera, biblioteca y versiones, configuración, cuentas/secretos 0600, transporte
autenticado, archivos autorizados, vigilancia, ejecución del proceso nativo.
Swift: WhisperKit/SpeakerKit, FoundationModels y captura/metadatos AVFoundation.

Rust implementa un único comando Tauri `app_command {method, params}` y lo
deserializa a un enum etiquetado (`src-tauri/src/command.rs`): un método
desconocido o un parámetro de más falla antes de ejecutar nada. Cada variante
declara si refresca la biblioteca y si las recetas pueden llamarla; añadir un
comando obliga a decidir ambas cosas y a documentarlo aquí, porque un test
comprueba que todos figuran en este contrato.

Los tipos de `src/generated/` se generan desde Rust con ts-rs:
`cargo test --lib los_tipos_generados` falla si están desfasados y
`ESCRIBA_WRITE_BINDINGS=1` los regenera. `knowledge(method, params)` de
`src/api.ts` está tipado de punta a punta para los comandos `knowledge_*`;
`call<T>(method, params)` comprueba el nombre del método y deja los
parámetros como JSON hasta que cada módulo tipa los suyos. `src/types.ts`
sigue siendo el modelo compartido de la biblioteca.
Errores rechazan la promesa con texto legible; nunca éxitos vacíos.

## Comandos Rust

- library -> Snapshot ligero (metadatos, extractos y huellas de revisión; sin segmentos, resumen completo ni datos de receta). Es la lectura del arranque y los refrescos.
- recording_detail {id} -> Recording completa de la selección, leída de SurrealDB bajo demanda.
- snapshot -> Snapshot completo solo bajo solicitud explícita (jamás secretos).
- runtime_context {recordingId?} -> RuntimeContext (catálogos y ajustes de procesamiento; solo la grabación solicitada, sin registros, carpetas vigiladas ni rutas de audio). El controlador TypeScript usa esta consulta; La interfaz usa `library` y `recording_detail`; no necesita `snapshot` para mostrar la biblioteca.
- import_audio {paths:string[], recipeId?} -> Recording[] (copia audio).
- recording_update {id, title?, status?, error?, duration?, recipeId?} -> Recording.
- recording_discard {id} -> void.
- recording_remove_audio {id} -> void (solo copia propia).
- version_save {recordingId, transcript, digest?, data?, backend, recipeId?, inputs?} -> Version (siempre nueva).
- version_select {recordingId, versionId} -> void.
- version_update {recordingId, versionId, digest?, data?} -> void.
- people_list -> {name:string,color?:string,voices:VoiceMetadata[]}[] (sin vectores).
- people_set_color {name,color} -> void (persona existente; color hexadecimal #RRGGBB, exclusivo de la UI).
- people_rename {name,newName} -> void (si el nombre nuevo ya existe, une sus huellas); people_remove {name} -> void (borra sus huellas; las grabaciones conservan el nombre); people_remove_voice {id} -> void.
- voice_registration_status, voice_registration_start {name}, voice_registration_import {name,path}, voice_registration_stop, voice_registration_cancel y voice_registration_dismiss -> VoiceRegistration; emiten `escriba://voice-registration` con cada estado. Registrar exige 30 segundos de habla.
- note_draft_get {recordingId} -> NoteDraft | null (detalle privado de la UI).
- note_draft_begin {recordingId} -> NoteDraft (recupera el existente o toma la versión vigente).
- note_draft_save {recordingId,draftId,expectedRevision,content} -> NoteDraft (duradero; sin crear versión).
- note_draft_discard {recordingId,draftId,expectedRevision} -> void (no altera la versión base).
- note_draft_commit {recordingId,draftId,expectedRevision} -> {version:Version,created:boolean} (una versión por borrador, confirmación idempotente; no publica).
- config_save {collection:'resolvers'|'recipes'|'accounts'|'destinations', item} -> item (upsert por id).
- config_remove {collection,id} -> void (locales/base no se borran).
- settings_save {settings: Partial<Settings>} -> Settings.
- credential_save {id, value} -> void (vacío elimina; nunca lectura a JS).
- log {message,level?,recordingId?,recipeId?} -> void (`level` info, warn o error; emite `escriba://log`, no `escriba://changed`).
- log_list {recordingId?,before?,limit?} -> LogEntry[] (más recientes primero, hasta 3000; `before` pagina por `at`). `library` y `snapshot` no incluyen el registro.
- native {method,params} -> resultado sidecar; native_cancel -> void (interrumpe proceso y se reinicia a demanda).
- transcribe {recordingId,resolverId,language?,diarize?,speakers?} -> Transcript (local Swift/remoto Rust).
- summarize {resolverId,instructions,prompt} -> Digest (una petición; troceo TS).
- ask {resolverId,instructions,prompt,schema?} -> JSON.
- recording_start {recipeId?} -> estado del panel; recording_stop -> Recording | null.
- recording_dismiss -> estado del panel (descarta el aviso de problema); recording_cancel -> void (descarta la captura en curso y su archivo).
- export_file {path,contents} -> void (archivo elegido por usuario en diálogo).
- reveal {path} -> void; open_url {url} -> void (http/https).
- open_privacy_settings -> void (abre Ajustes del Sistema, destino fijo; no disponible para recetas).
- okf_file {accountId,path,action:'open'|'reveal'} -> void (solo documentos dentro de la carpeta autorizada de la cuenta OKF).
- system_appearance -> {accent:string|null} (color de acento del sistema).
- resolver_models {resolver,key?,resolverId?} -> string[] (modelos del servicio compatible con OpenAI); resolver_try {resolver,key?,resolverId?,role,instructions?,prompt?} -> Digest | {text} (prueba sin guardar; la clave escrita prevalece sobre la guardada).
- whisper_model {action:'info'|'delete'} -> {model,available,bytes} | void (solo la carpeta de modelos de Escriba).
- project_init {path} -> {hasDist:boolean} (crea ausentes; si ya existe el artefacto no añade fuentes).
- project_build -> {recipes:Recipe[],connectorProgram?:string,ontologyProgram?:string} (Bun aislado construye `dist/` y el cargador lo lee; conserva el artefacto anterior si falla la construcción).
- project_load -> el mismo resultado que project_build, leyendo solo `dist/escriba.json` y sus paquetes JavaScript.
- project_open_vscode -> void (abre la carpeta del proyecto en VS Code).
- project_list -> {files:string[]} (fuentes y JSON/Markdown; excluye dist, node_modules, .git, .escriba y enlaces).
- project_read {entry} -> {source:string}; project_write {entry,source,expectedSource?,createNew?} -> void (confinado al proyecto, escritura atómica; rechaza una versión externa distinta o un archivo existente al crear).
- project_tool {tool:'install'|'check'|'test'} -> {success:boolean,output:string} (Bun y TypeScript 7 incluidos, sandbox de desarrollo, salida y duración acotadas; solo install permite red, sin scripts de instalación).
- connector_save {account,destination} -> void (cuenta y destino gestionado con el mismo id; autorización explícita en account.grant, credencial por separado).
- connector_remove {id} -> void (retira configuración y credencial local; conserva las publicaciones).
- connector_http {accountId,expectedGrant,url,method?,headers?,body?,multipart?} -> {status,headers,body} (cuenta fija origen y cabeceras; secreto en Rust, no redirects; multipart [{name,value? ,audio?:{recordingId,start?,end?},filename?,type?}]).
- connector_files {accountId,expectedGrant,operation:'snapshot'|'apply',changes?} -> mapa de textos / void (solo carpeta autorizada, sin symlinks ni escapes, CAS expectedContents).
- connector_audio {recordingId} -> {size,type,filename} | null (audio opaco, bytes nunca a receta).
- publication_save {recordingId,destinationId,accountId,name,provider,receipt,configuration,program?,managed?} -> void.
- publication_remove {recordingId,destinationId} -> void.
- watch_scan -> Recording[] (audio asentado, deduplicado; intervalos en host).
- watch_folder_authorize {folderId?,name?,style?} -> WatchedFolder | null (panel nativo; cancelar no modifica configuración). Sin folderId incorpora la carpeta elegida; con folderId reautoriza esa fuente, conservando su identidad. Si la ruta anterior ya no existe, permite seleccionar su nueva ubicación. No disponible para recetas.

`NoteDraft` contiene `{id,recordingId,baseVersionId,baseFingerprint,revision,
createdAt,updatedAt,content}`. `content` es `{title:string,transcript:Transcript,
digest:Digest|null,data:JSONValue}`. La revisión comienza en cero y aumenta en
cada guardado. El título es canónico y se refleja en `digest.title` cuando hay
resumen. Guardar y confirmar rechazan una revisión obsoleta o una versión base
modificada; el borrador sigue disponible. Un commit sin cambios devuelve la
versión base con `created:false` y cierra el borrador. Estos comandos no están
habilitados para recetas ni trabajadores TypeScript, y sus datos no forman parte
de `library`, `snapshot` o `runtime_context`.

Tras un error al confirmar, `note_draft_get` permite comprobar si sigue abierto
el mismo borrador: en ese caso la UI puede conservarlo o descartarlo respetando
su revisión, y no debe quedar bloqueada en «confirmación pendiente». Si ya no
está, repetir `note_draft_commit` con el id y la revisión originales recupera el
recibo idempotente. Si tampoco se puede consultar, el estado sigue siendo
incierto y se ofrece reintentar, sin inferir el resultado del texto del error.

## Comandos del controlador

Los métodos de `CONTROLLER_METHODS` (`src-tauri/src/command.rs`) no son
variantes del enum: Rust los reenvía al controlador TypeScript como trama
`command {id,method,params,origin}` y devuelve su `result` o `error`. El
controlador arranca con la app, sin perfil de `sandbox-exec`, con `ESCRIBA_DATA`
y `NAPI_RS_NATIVE_LIBRARY_PATH` en su entorno; las recetas conservan el suyo.
Los eventos que emite (`changed`, `log`, `imported`, `project`,
`voice-registration`, `whisper-download`, `jobs`) llegan a la WebView como
`escriba://<evento>`.

- controller_status -> {protocolVersion, dataPath} (el controlador está vivo y sabe dónde están los datos).

## Trabajos y estado de la interfaz

- runtime_run {operation,args} -> resultado del trabajo; la espera de la UI no es propietaria del trabajo.
  La cola duradera tiene dos carriles: procesar y resumir comparten el de inferencia (uno a la vez, como el motor nativo); publicar y retirar van por el de red (hasta tres a la vez). Una nota nunca tiene dos trabajos activos ni corre dos a la vez. El controlador TypeScript no añade otra cola: solo rechaza procesar una nota que ya se está procesando.
- runtime_jobs -> Job[] (pendientes, activos y en espera de reintento). Cada trabajo de procesar guarda la receta con la que se encoló y la actualiza al empezar; `startedAt` es cuándo empezó a ejecutarse y `finishedAt` cuándo terminó, falló o se canceló.
- runtime_history {before?,state?,recipeId?,operation?,limit} -> HistoryPage {jobs,recipes,next}; solo trabajos terminados, fallidos o cancelados, del final más reciente al más antiguo. `next` es el cursor de la página siguiente o null; `recipes` son las recetas que aparecen en el historial.
- runtime_cancel {recordingId} -> void; revoca capacidades y termina la receta.
- runtime_job_steps {id} -> RecipeTrace[]; las ejecuciones de cada intento de un trabajo, la última primero. Rust apunta en cada `trace_save` el trabajo que la lanzó (`jobId`, tomado de la tarea, no de la receta); las guardadas antes se asocian por nota y hora al último trabajo de procesar que empezó antes que ellas.
- runtime_relaunch {id} -> {id}; encola un trabajo nuevo a partir de uno fallido o cancelado y conserva el original. Procesar reprocesa con la receta vigente de la nota (`force: true`); una prueba de receta y las acciones manuales repiten sus argumentos. Se rechaza si la nota ya tiene un trabajo activo o un efecto externo incierto pendiente.
- recording_status -> {active,clock,recipeName,levels,problem} del panel de captura.
- project_install {recipes,destinations,providers,ontologies?} -> void; actualización transaccional del catálogo y de las ontologías candidatas, sin instalar ontologías ni conceder acceso a cuentas.
- knowledge_candidates -> Ontologia[] propuestas por el proyecto vigente; knowledge_list -> Ontologia[] instaladas en la biblioteca.
- knowledge_install {definition} -> Ontologia; exige una candidata idéntica del proyecto vigente y aplica las migraciones pendientes de forma atómica.
- knowledge_open {recipeId,recordingId,ontologyId,dependency} -> {version:number}; contrasta la dependencia declarada por la receta instalada con el intervalo permitido.
- knowledge_query {recipeId,recordingId,ontologyId,dependency,expectedVersion,sql,bindings} -> string; `bindings` y el resultado son CBOR en base64, con tipos nativos de SurrealDB.
- knowledge_link {recipeId,recordingId,ontologyId,dependency,expectedVersion,versionId,recordId} -> void; vincula la versión de la nota al registro.
- knowledge_records {id,table,page?,recordingId?,versionId?} -> {records,page,hasMore}; página de 50 registros declarados.
- knowledge_graph_roots {ontologyId,table,page?} -> {nodes,edges,page,hasMore}; página de 40 registros declarados con etiquetas ligeras, sin propiedades completas.
- knowledge_graph_expand {ontologyId,recordId,page?} -> {nodes,edges,page,hasMore,root}; página de 40 conexiones incidentes declaradas, referencias entre extensiones y base y vínculos de procedencia. Las relaciones conservan identidad, dirección y extremos; los destinos ausentes se marcan `missing`. Los nodos usan la pareja ontología/RecordId canónico como clave.
- knowledge_graph_detail {ontologyId,recordId} -> {id,ontologyId,table,values,rev,truncatedFields}; vista de lectura de los campos declarados. `rev` vacío no habilita edición. Texto o JSON de más de 2000 caracteres se recorta como vista previa y su campo se incluye en `truncatedFields`; los valores breves conservan su tipo. Máximo 128 campos por detalle.
- knowledge_save {id,expectedVersion,table,recordId?,expectedRev?,values,recordingId?,versionId?} -> registro; formulario JSON con control de revisión y procedencia opcional.
- knowledge_delete {id,expectedVersion,table,recordId,expectedRev} -> void; knowledge_unlink {id,expectedVersion,recordId,recordingId} -> void.
- knowledge_attach {id,expectedVersion,recordId,recordingId,versionId} -> void; vínculo de una nota con un registro ya existente desde la UI.
- knowledge_filter_notes {filter} -> {recordingIds,incomplete?}; `incomplete` indica que la base aún se está sincronizando tras dos segundos y la UI repite el filtro. Aplica condiciones visuales sobre campos declarados o una consulta SurrealQL de lectura. Sincroniza la base y devuelve identidades de notas vigentes, sin descargar sus transcripciones a la interfaz.
- knowledge_filters_list -> SavedLibraryFilter[]; knowledge_filter_save {filter:{id?,name,filter:LibraryFilter}} -> SavedLibraryFilter; knowledge_filter_remove {id} -> void. `SavedLibraryFilter` contiene `id,name,filter`; conserva la definición visual (condiciones tipadas y todas/cualquiera) o SurrealQL. Los filtros permanecen en el registro privado de conocimiento al cambiar de proyecto. Las consultas del formato anterior se leen como SurrealQL conservando su ID. Estos comandos son exclusivos de la UI.

Los filtros se ejecutan con el principal de datos de la ontología, tras validar
que el AST completo sea de lectura, incluidas las extensiones. El último
resultado SurrealQL debe contener identidades nativas, registros con `id` o
referencias explícitas a la base. El host resuelve la procedencia y las
referencias declaradas contra la versión vigente; no hace recorridos
implícitos. Las condiciones visuales combinan notas con todas o cualquiera de
las coincidencias. Las consultas tienen un límite de 10 segundos, 10000
entidades/notas y 8 MiB de resultado aceptado; excederlo produce un error. Este
último límite se comprueba sin copiar el resultado y no constituye un presupuesto
total de RAM: el SDK embebido materializa primero los resultados de SurrealQL.
Los selectores
visuales usan páginas ligeras de `knowledge_graph_roots`. Contrato de los
criterios y comportamiento en `../../specs/escriba/filtros-biblioteca/functional-specs.md`.

Los comandos `knowledge_graph_*` sincronizan la proyección base mediante su
journal antes de consultar. No ejecutan recetas ni SQL aportado por la WebView.
La expansión admite hasta 128 extensiones instaladas y 512 fuentes de conexiones
declaradas; si se excede, devuelve un error visible. La interfaz acumula como
máximo 160 nodos y 240 conexiones por recorrido y permite centrar otro recorrido
en una entidad. Una relación con referencias o procedencia puede aparecer como
nodo de anclaje además de su arista dirigida. Tablas raw no declaradas y
referencias arbitrarias en JSON quedan fuera de este visor.
- account_effect_begin / account_effect_finish {recordingId} -> void; marcador duradero de escrituras arbitrarias de SDK. Solo se retira al iniciar otro reprocesado manual explícito.
- memory_recall / memory_keep {recordingId,versionId,fingerprint,value?} -> JSON / void.
- trace_save {recordingId,...} -> void; trace_list {recordingId?} -> trazas.

`src/runtime/index.ts` solo es cliente IPC. Rust mantiene la cola y ejecuta el
controlador de `runtime-host` incluso sin ventana. Véase el protocolo del
[proceso TypeScript](runtime-host/README.md). La UI escucha `escriba://changed`
y `escriba://jobs`; el sondeo de respaldo es de 15 s, o 2 s durante captura.
Las consultas de estado y de formularios no emiten `escriba://changed`, para que
un refresco no se realimente. Los trabajos y vigilantes empiezan después de abrir la biblioteca local.

Los trabajos conservan `error` como texto y `errorCode` como clasificación. El
código viaja entre Rust, controlador y receta; decide el reintento sin buscar
marcadores dentro del mensaje. La entrega de notificaciones usa el permiso
solicitado al arrancar. Los ajustes de usuario ya no aceptan `theme`, `language`
ni `autoProcess`; el idioma guardado anteriormente sigue siendo legible para
las recetas que lo usaban como valor de partida.

## Proveedores del proyecto

`@escriba/conectores` define `ProviderManifest`, `ProviderAccess` y `ConnectorView`.
El catálogo `providers` guarda los manifiestos y programas; la biblioteca ligera
entrega únicamente metadatos y `programFingerprint`. `runtime_context` incluye el
programa para ejecutar `connectorEditor {operation,request}` fuera de la WebView.
`describe` y `validate` carecen de capacidades; las acciones explícitas usan el
transporte de la cuenta. La respuesta del proveedor se valida antes de renderizarla.
Notion, OKF y los proveedores instalados comparten el mismo renderizador.

Cada llamada compara `expectedGrant` con la cuenta y el proveedor vigentes.
Cambiar el origen o la autenticación exige retirar la credencial anterior antes
de autorizar de nuevo. Retirar el proyecto marca el proveedor como no disponible;
las publicaciones previas conservan su programa, configuración y recibo para
actualizarse o retirarse con la autorización que siga vigente.

Las recetas reciben `cuentas` y `cuenta(id).fetch`, sin credenciales. Una operación
SDK arbitraria no genera un recibo de publicación. Antes de enviar una escritura,
el controlador confirma `accountEffectPending`; la cola bloquea su repetición
automática o recuperada hasta una ejecución manual explícita. Se conserva el
marcador al terminar para cubrir un cierre antes de confirmar el trabajo.

## Grafo de conocimiento

El proyecto puede declarar `src/ontologias.ts` y una receta puede exportar
`ontologias: {id,minVersion,maxVersion}[]`. Son contratos distintos: el primero
propone una definición, el segundo exige una versión instalada compatible. El
catálogo de candidatas se actualiza al construir/cargar un proyecto; las
ontologías instaladas pertenecen a la biblioteca y sobreviven al cambio de
proyecto. `knowledge_install` es una acción explícita de la UI. El esquema y los
datos del grafo residen en `knowledge.rocksdb`, separados de
`library.rocksdb`, con una base lógica por ID de ontología.
`knowledge_link` y `knowledge_attach` aceptan registros existentes solo de
tablas enumeradas en `collections`; las consultas raw pueden acceder a otras
tablas de esa base según sus permisos SurrealQL.

En el worker, `api.grafo(id)` abre de forma asíncrona una conexión del SDK oficial
SurrealDB 2.1.1 con transporte CBOR por `graph.open`/`graph.query`. Rust autentica
una sesión `RECORD` limitada a la base de esa ontología; no entrega conexión,
contraseña ni permisos de migración al worker. Se admiten operaciones de datos
y lotes SurrealQL transaccionales; no se admiten DDL, `USE`, operaciones de
autenticación, transacciones interactivas ni consultas `live`. `nota.vincular(id,
recordId)` pasa por `graph.link` y exige una versión activa de nota. Cada llamada
comprueba la dependencia guardada y la versión exacta abierta, por lo que una
actualización de ontología exige volver a abrir el grafo.

La dependencia de `escriba` v1 es implícita si la receta no la declara. Una
declaración explícita conserva su intervalo y falla si es incompatible. El mismo
`api.grafo("escriba")` abre la base interna de solo lectura tras sincronizarla
desde la biblioteca. Sus tablas públicas son `person`, `recording`, `version`,
`transcript`, `speaker`, `segment` y `word`; no expone rutas, credenciales,
huellas ni embeddings. `graph.link` rechaza `escriba`, cuyos vínculos ya derivan
de la biblioteca. Las referencias desde una ontología de usuario a la base son
objetos `{ontologyId:"escriba",table,id}`; no habilitan recorridos entre bases.

El `dryRun` deniega `graph.open`, `graph.query` y `graph.link`. El controlador
confirma `accountEffectPending` antes de toda consulta raw a una ontología de
usuario, pues un lote SurrealQL también puede escribir; esto bloquea el
reintento automático ante un resultado incierto. Los formularios de la UI usan
JSON y control de revisión; la protección de correcciones manuales impide que
una receta sobrescriba un registro editado allí. No hay cruces automáticos entre
bases de ontologías, red, scripting JavaScript, embeddings ni canvas.
La instalación excluye `EVENT`, vistas `TABLE AS SELECT` y acciones
`REFERENCE ON DELETE THEN` porque sus callbacks pueden ejecutarse con
privilegios del migrador en SurrealDB 3.3.2.

`watchIssues` contiene los errores del último escaneo de las carpetas habilitadas
(`folderId`, `path`, `message`, `permissionDenied`). La UI mantiene un aviso
visible y un estado de error hasta que un escaneo confirme la recuperación.
Cada cambio de errores emite `escriba://changed`; si hay errores, registra el
problema y solicita una notificación de escritorio. Un fallo repetido sin
cambios no vuelve a notificar ni a llenar el registro. La entrega del aviso del
sistema depende de los permisos de notificaciones; el aviso dentro de la app
siempre se muestra. Los escaneos automáticos y manuales se ejecutan en serie.

Cada carpeta puede tener `authorizationSaved` en el snapshot. Indica que se
conserva una selección, no que macOS permita leerla ahora: el resultado actual
se comunica mediante `watchIssues`. Los bytes del bookmark (`accessBookmark`)
se guardan en SurrealDB, sólo los manipula Rust y nunca se incluyen en snapshots
ni respuestas a TypeScript. Guardar ajustes conserva la selección cuando sigue
correspondiendo al mismo id y ruta; quitar la carpeta elimina esa referencia.

Rust restaura el bookmark antes del escaneo y de registrar FSEvents, renueva los
bookmarks obsoletos y mantiene vivo el acceso mientras la carpeta está habilitada.
La app actual usa bookmarks implícitos sin activar App Sandbox globalmente.
Para materializar un archivo de iCloud, Rust pasa el bookmark directamente al
adaptador Swift, que lo resuelve, comprueba que el archivo pertenece a la carpeta
y mantiene el acceso durante la operación. Fallos de materialización se añaden
a `watchIssues` y se reintentan con espera; un callback antiguo no puede sustituir
el estado de un intento más reciente.
