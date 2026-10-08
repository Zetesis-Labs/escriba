# Escriba Tauri — contrato de integración

Migración definitiva con dos instalaciones durante la transición. Tauri usa identificador
dev.zetesis.escriba.tauri y biblioteca propia. No importa credenciales ni datos
de la app estable al arrancar. No pruebas contra Notion ni tokens reales.

TypeScript: UI React, formularios Zod, recetas, conectores npm y orquestación en un proceso propio.
Rust: SurrealDB, cola duradera, biblioteca y versiones, configuración, cuentas/secretos 0600, transporte
autenticado, archivos autorizados, vigilancia, ejecución del proceso nativo.
Swift: WhisperKit/SpeakerKit, FoundationModels y captura/metadatos AVFoundation.

`src/types.ts` es el modelo compartido. Frontend usa `call<T>(method, params)`
desde `src/api.ts`; Rust implementa un único comando Tauri `app_command`.
Errores rechazan la promesa con texto legible; nunca éxitos vacíos.

## Comandos Rust

- snapshot -> Snapshot (todos los datos, jamás secretos).
- import_audio {paths:string[], recipeId?} -> Recording[] (copia audio).
- recording_update {id, title?, status?, error?, duration?, recipeId?} -> Recording.
- recording_discard {id} -> void; recording_restore {id} -> Recording.
- recording_remove_audio {id} -> void (solo copia propia).
- version_save {recordingId, transcript, digest?, data?, backend, recipeId?, inputs?} -> Version (siempre nueva).
- version_select {recordingId, versionId} -> void.
- version_update {recordingId, versionId, digest?, data?} -> void.
- config_save {collection:'resolvers'|'recipes'|'accounts'|'destinations', item} -> item (upsert por id).
- config_remove {collection,id} -> void (locales/base no se borran).
- settings_save {settings: Partial<Settings>} -> Settings.
- credential_save {id, value} -> void (vacío elimina; nunca lectura a JS).
- log {message,level?,recordingId?,recipeId?} -> void; log_clear -> void.
- native {method,params} -> resultado sidecar; native_cancel -> void (interrumpe proceso y se reinicia a demanda).
- transcribe {recordingId,resolverId,language?,diarize?,speakers?} -> Transcript (local Swift/remoto Rust).
- summarize {resolverId,instructions,prompt} -> Digest (una petición; troceo TS).
- ask {resolverId,instructions,prompt,schema?} -> JSON.
- recording_start -> {audioPath}; recording_pause/resume -> void; recording_stop {recipeId?} -> Recording.
- export_file {path,contents} -> void (archivo elegido por usuario en diálogo).
- reveal {path} -> void; open_url {url} -> void (http/https).
- project_init {path} -> void (solo crea ausentes; tipos y paquetes npm propios de serie).
- project_build -> {recipes:Recipe[],connectorProgram?:string} (esbuild nativo, bundles IIFE __recipe / __conectores, preserva último válido).
- project_read {entry} -> {source:string}; project_write {entry,source} -> void (confinado proyecto).
- connector_http {accountId,url,method?,headers?,body?,multipart?} -> {status,headers,body} (cuenta fija origen; secreto en Rust, no redirects; multipart [{name,value? ,audio?:{recordingId,start?,end?},filename?,type?}]).
- connector_files {accountId,operation:'snapshot'|'apply',changes?} -> mapa de textos / void (solo carpeta autorizada, sin symlinks ni escapes, CAS expectedContents).
- connector_audio {recordingId} -> {size,type,filename} | null (audio opaco, bytes nunca a receta).
- publication_save {recordingId,destinationId,accountId,name,provider,receipt,configuration,program?} -> void.
- publication_remove {recordingId,destinationId} -> void.
- watch_scan -> Recording[] (audio asentado, deduplicado; intervalos en host).

## Trabajos y estado de la interfaz

- runtime_run {operation,args} -> resultado del trabajo; la espera de la UI no es propietaria del trabajo.
- runtime_jobs -> JobState[] (pendientes, activos y en espera de reintento).
- runtime_history -> trabajos duraderos, resultado y error.
- runtime_cancel {recordingId} -> void; revoca capacidades y termina la receta.
- library_import {path,settingsPath?} -> informe de importación explícita de SwiftUI.
- recording_status -> {active,paused,audioPath,duration} del proceso de captura.
- recording_delete {id} -> void; borra biblioteca/copia propia, conserva fuente y servicios externos.
- notification_permission -> envía una notificación de comprobación desde una acción explícita.
- project_install {recipes,destinations} -> void; actualización transaccional de catálogo.
- memory_recall / memory_keep {recordingId,versionId,fingerprint,value?} -> JSON / void.
- trace_save {recordingId,...} -> void; trace_list {recordingId?} -> trazas.

`src/runtime/index.ts` solo es cliente IPC. Rust mantiene la cola y ejecuta el
controlador de `runtime-host` incluso sin ventana. Véase el protocolo del
[proceso TypeScript](runtime-host/README.md). La UI escucha `escriba://changed`
y `escriba://jobs`; el sondeo de respaldo es de 15 s, o 2 s durante captura.
