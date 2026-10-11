# Escriba — contrato de integración

Una aplicación: **Escriba.app** (ADR-0005). El identificador técnico
`dev.zetesis.escriba.tauri` mantiene la ubicación de datos y los permisos.
`ESCRIBA_TAURI_DATA` selecciona una biblioteca aislada para pruebas.
No pruebas contra Notion ni tokens reales.

TypeScript: UI React, formularios Zod, recetas, conectores npm y orquestación en un proceso propio.
Rust: SurrealDB, cola duradera, biblioteca y versiones, configuración, cuentas/secretos 0600, transporte
autenticado, archivos autorizados, vigilancia, ejecución del proceso nativo.
Swift: WhisperKit/SpeakerKit, FoundationModels y captura/metadatos AVFoundation.

`src/types.ts` es el modelo compartido. Frontend usa `call<T>(method, params)`
desde `src/api.ts`; Rust implementa un único comando Tauri `app_command`.
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
- config_save {collection:'resolvers'|'recipes'|'accounts'|'destinations', item} -> item (upsert por id).
- config_remove {collection,id} -> void (locales/base no se borran).
- settings_save {settings: Partial<Settings>} -> Settings.
- credential_save {id, value} -> void (vacío elimina; nunca lectura a JS).
- log {message,level?,recordingId?,recipeId?} -> void.
- native {method,params} -> resultado sidecar; native_cancel -> void (interrumpe proceso y se reinicia a demanda).
- transcribe {recordingId,resolverId,language?,diarize?,speakers?} -> Transcript (local Swift/remoto Rust).
- summarize {resolverId,instructions,prompt} -> Digest (una petición; troceo TS).
- ask {resolverId,instructions,prompt,schema?} -> JSON.
- recording_start {recipeId?} -> estado del panel; recording_stop -> Recording | null.
- export_file {path,contents} -> void (archivo elegido por usuario en diálogo).
- reveal {path} -> void; open_url {url} -> void (http/https).
- open_privacy_settings -> void (abre Ajustes del Sistema, destino fijo; no disponible para recetas).
- project_init {path} -> {hasDist:boolean} (crea ausentes; si ya existe el artefacto no añade fuentes).
- project_build -> {recipes:Recipe[],connectorProgram?:string} (Bun aislado construye `dist/` y el cargador lo lee; conserva el artefacto anterior si falla la construcción).
- project_load -> el mismo resultado que project_build, leyendo solo `dist/escriba.json` y sus paquetes JavaScript.
- project_list -> {files:string[]} (fuentes y JSON/Markdown; excluye dist, node_modules, .git, .escriba y enlaces).
- project_read {entry} -> {source:string}; project_write {entry,source,expectedSource?,createNew?} -> void (confinado al proyecto, escritura atómica; rechaza una versión externa distinta o un archivo existente al crear).
- project_tool {tool:'install'|'check'|'test'} -> {success:boolean,output:string} (Bun y TypeScript 7 incluidos, sandbox de desarrollo, salida y duración acotadas; solo install permite red, sin scripts de instalación).
- connector_http {accountId,url,method?,headers?,body?,multipart?} -> {status,headers,body} (cuenta fija origen; secreto en Rust, no redirects; multipart [{name,value? ,audio?:{recordingId,start?,end?},filename?,type?}]).
- connector_files {accountId,operation:'snapshot'|'apply',changes?} -> mapa de textos / void (solo carpeta autorizada, sin symlinks ni escapes, CAS expectedContents).
- connector_audio {recordingId} -> {size,type,filename} | null (audio opaco, bytes nunca a receta).
- publication_save {recordingId,destinationId,accountId,name,provider,receipt,configuration,program?} -> void.
- publication_remove {recordingId,destinationId} -> void.
- watch_scan -> Recording[] (audio asentado, deduplicado; intervalos en host).
- watch_folder_authorize {folderId?,name?,style?} -> WatchedFolder | null (panel nativo; cancelar no modifica configuración). Sin folderId incorpora la carpeta elegida; con folderId reautoriza esa fuente, conservando su identidad. Si la ruta anterior ya no existe, permite seleccionar su nueva ubicación. No disponible para recetas.

## Trabajos y estado de la interfaz

- runtime_run {operation,args} -> resultado del trabajo; la espera de la UI no es propietaria del trabajo.
- runtime_jobs -> JobState[] (pendientes, activos y en espera de reintento).
- runtime_history -> trabajos duraderos, resultado y error.
- runtime_cancel {recordingId} -> void; revoca capacidades y termina la receta.
- recording_status -> {active,clock,recipeName,levels,problem} del panel de captura.
- project_install {recipes,destinations} -> void; actualización transaccional de catálogo.
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
