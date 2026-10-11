#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]

mod appearance;
mod capabilities;
mod catalog;
mod error;
mod folder_access;
mod jobs;
mod knowledge;
#[cfg(test)]
mod knowledge_base_integration_tests;
mod knowledge_commands;
#[cfg(test)]
mod knowledge_integration_tests;
mod library_view;
mod login;
mod menubar;
mod native;
mod notification_delivery;
mod notification_events;
mod notifications;
mod persistence;
mod project;
mod project_watch;
mod recorder;
mod recording;
mod remote;
mod scripts;
mod store;
mod symbols;
mod voice_registration;
mod voices;
mod watcher;

use notifications::Problem;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{atomic::AtomicBool, Arc, Mutex},
    time::{Duration, SystemTime},
};
use store::{text, Store};
use tauri::{Emitter, Manager};

struct Runtime {
    knowledge: tokio::sync::OnceCell<knowledge::Knowledge>,
    knowledge_path: PathBuf,
    store: Arc<Mutex<Store>>,
    jobs: Arc<jobs::Queue>,
    scripts: scripts::Scripts,
    materializer: native::Native,
    materializing: Mutex<watcher::Materializations>,
    scanner: Mutex<watcher::Scanner>,
    watch_health: Mutex<watcher::Health>,
    scan_lock: tokio::sync::Mutex<()>,
    folder_accesses: Mutex<HashMap<String, FolderAccess>>,
    watch_wake: tokio::sync::mpsc::Sender<()>,
    inference: native::Native,
    recorder: native::Native,
    recording: Mutex<Option<recording::Session>>,
    recording_problem: Mutex<Option<recording::Problem>>,
    recording_lock: tokio::sync::Mutex<()>,
    voice_registration: voice_registration::Registration,
    menubar: Mutex<menubar::Bar>,
    quitting: AtomicBool,
    vendor: PathBuf,
    project_runtime: PathBuf,
    project_lock: tokio::sync::Mutex<()>,
}

struct FolderAccess {
    bookmark: Vec<u8>,
    resolved: folder_access::ResolvedFolder,
}

impl Runtime {
    fn store(&self) -> Result<std::sync::MutexGuard<'_, Store>, String> {
        self.store
            .lock()
            .map_err(|_| "No se pudo acceder a la biblioteca".into())
    }

    fn library(&self) -> Result<Value, String> {
        let library = self.store()?.library();
        self.decorate(library)
    }

    fn snapshot(&self) -> Result<Value, String> {
        let snapshot = self.store()?.snapshot()?;
        self.decorate(snapshot)
    }

    fn decorate(&self, mut snapshot: Value) -> Result<Value, String> {
        snapshot["watchIssues"] = self
            .watch_health
            .lock()
            .map_err(|_| "No se pudo consultar el acceso a las carpetas")?
            .snapshot();
        Ok(snapshot)
    }
}

#[tauri::command]
async fn app_command(
    app: tauri::AppHandle,
    state: tauri::State<'_, Arc<Runtime>>,
    method: String,
    params: Value,
) -> Result<Value, String> {
    let runtime = state.inner().clone();
    let refresh = refreshes_library(&method, &params);
    let check_resolvers = notification_events::settings_changed(&method, &params);
    let result = dispatch(&app, &runtime, &method, params)
        .await
        .and_then(voices::public_reply);
    if result.is_ok() && refresh {
        let _ = app.emit("escriba://changed", ());
    }
    if refresh {
        state.jobs.wake.notify_one();
    }
    if result.is_ok() && check_resolvers {
        tauri::async_runtime::spawn(async move { warn_about_unusable(&app, &runtime).await });
    }
    result
}

fn resolver_draft(state: &Runtime, p: &Value) -> Result<(Value, Option<String>), String> {
    let typed = p["key"]
        .as_str()
        .map(str::trim)
        .filter(|key| !key.is_empty())
        .map(str::to_owned);
    let secret = match (typed, p["resolverId"].as_str()) {
        (Some(key), _) => Some(key),
        (None, Some(id)) => state
            .store()?
            .credential(id)?
            .map(|key| key.trim().to_owned()),
        (None, None) => None,
    };
    Ok((p["resolver"].clone(), secret))
}

fn directory_size(path: &std::path::Path) -> u64 {
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

fn models_root(status: &Value) -> Result<PathBuf, String> {
    let root = PathBuf::from(text(&status["whisper"], "modelsPath")?);
    if !root.ends_with("Application Support/escriba/models") {
        return Err("La carpeta de modelos no es la de Escriba".into());
    }
    Ok(root)
}

async fn whisper_model(state: &Arc<Runtime>, p: &Value) -> Result<Value, String> {
    let model = json!(state.store()?.data.settings.whisper_model.as_ref());
    let status = state
        .inference
        .call("status", json!({"model": model}))
        .await?;
    let root = models_root(&status)?;
    match text(p, "action")? {
        "info" => {
            let size = if status["whisper"]["available"] == true {
                let root = root.clone();
                tokio::task::spawn_blocking(move || directory_size(&root))
                    .await
                    .map_err(|e| e.to_string())?
            } else {
                0
            };
            Ok(
                json!({"model": status["whisper"]["model"], "available": status["whisper"]["available"], "bytes": size}),
            )
        }
        "delete" => {
            state.inference.unload_if_idle(Duration::ZERO);
            if root.exists() {
                tokio::fs::remove_dir_all(&root)
                    .await
                    .map_err(|e| format!("No se pudo borrar el modelo: {e}"))?;
            }
            Ok(Value::Null)
        }
        _ => Err("Acción desconocida".into()),
    }
}

fn refreshes_library(method: &str, params: &Value) -> bool {
    match method {
        "runtime_run" => params["operation"]
            .as_str()
            .is_some_and(|operation| jobs::durable(operation) || operation == "rebuildProject"),
        "import_audio"
        | "recording_update"
        | "recording_discard"
        | "recording_remove_audio"
        | "recording_stop"
        | "note_draft_commit"
        | "version_save"
        | "version_select"
        | "version_update"
        | "settings_save"
        | "config_save"
        | "config_remove"
        | "connector_save"
        | "connector_remove"
        | "people_set_color"
        | "people_rename"
        | "people_remove"
        | "people_remove_voice"
        | "credential_save"
        | "publication_save"
        | "publication_remove"
        | "project_init"
        | "project_install"
        | "knowledge_install"
        | "knowledge_save"
        | "knowledge_delete"
        | "knowledge_unlink"
        | "knowledge_attach"
        | "knowledge_filter_save"
        | "knowledge_filter_remove"
        | "project_write"
        | "log"
        | "trace_save"
        | "runtime_cancel"
        | "watch_scan"
        | "watch_folder_authorize" => true,
        _ => false,
    }
}

async fn dispatch_inference(
    state: &Arc<Runtime>,
    method: &str,
    p: Value,
) -> Result<Value, error::AppError> {
    match method {
        "transcribe" => {
            let (audio, resolver, secret, model) = {
                let store = state.store()?;
                let key = p["resolverId"].as_str().unwrap_or("local-stt");
                (
                    store.audio(text(&p, "recordingId")?)?,
                    store.item("resolvers", key)?,
                    store.credential(key)?,
                    json!(store.data.settings.whisper_model.as_ref()),
                )
            };
            if resolver["enabled"] == false {
                return Err("El resolutor está apagado".into());
            }
            let recording_id = text(&p, "recordingId")?.to_owned();
            let transcript = if resolver["local"] == true {
                state.inference.transcribe(&audio, model, p).await
            } else {
                remote::transcribe(&resolver, secret, &audio, &p).await
            }?;
            state
                .store()?
                .recognize_transcription(&recording_id, transcript)
                .map_err(Into::into)
        }
        "summarize" | "ask" => {
            let (resolver, secret) = {
                let store = state.store()?;
                let key = p["resolverId"].as_str().unwrap_or("local-llm");
                (store.item("resolvers", key)?, store.credential(key)?)
            };
            if resolver["enabled"] == false {
                return Err("El resolutor está apagado".into());
            }
            if resolver["local"] == true {
                state.inference.call(method, p).await
            } else {
                let mut params = p;
                if method == "summarize" {
                    params["schema"] = remote::digest_schema();
                }
                remote::ask(&resolver, secret, &params).await
            }
        }
        _ => Err("Capacidad de inferencia desconocida".into()),
    }
}

fn dispatch<'a>(
    app: &'a tauri::AppHandle,
    state: &'a Arc<Runtime>,
    method: &'a str,
    p: Value,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value, String>> + Send + 'a>> {
    Box::pin(async move {
        match method {
            "knowledge_candidates" => Ok(json!(state
                .store()?
                .data
                .settings
                .project_ontologies
                .as_ref()
                .cloned()
                .unwrap_or_default())),
            "knowledge_list"
            | "knowledge_install"
            | "knowledge_open"
            | "knowledge_query"
            | "knowledge_link"
            | "knowledge_records"
            | "knowledge_save"
            | "knowledge_delete"
            | "knowledge_graph_roots"
            | "knowledge_graph_expand"
            | "knowledge_graph_detail"
            | "knowledge_filter_notes"
            | "knowledge_filters_list"
            | "knowledge_filter_save"
            | "knowledge_filter_remove"
            | "knowledge_unlink"
            | "knowledge_attach" => {
                if matches!(method, "knowledge_list" | "knowledge_filters_list")
                    && state.knowledge.get().is_none()
                    && !state
                        .knowledge_path
                        .try_exists()
                        .map_err(|error| format!("No se pudo acceder al conocimiento: {error}"))?
                {
                    return Ok(if method == "knowledge_list" {
                        json!([knowledge::base_listing()])
                    } else {
                        json!([])
                    });
                }
                let knowledge = state
                    .knowledge
                    .get_or_try_init(|| knowledge::Knowledge::open(&state.knowledge_path))
                    .await?;
                knowledge_commands::dispatch(knowledge, &state.store, method, p).await
            }
            "snapshot" => state.snapshot(),
            "library" => state.library(),
            "recording_detail" => state.store()?.recording(text(&p, "id")?),
            "runtime_context" => state.store()?.runtime_context(
                p.get("recordingId")
                    .map(|_| text(&p, "recordingId"))
                    .transpose()?,
            ),
            "account_effect_begin" | "account_effect_finish" => state.store()?.mutate(method, &p),
            "runtime_run" => {
                let operation = text(&p, "operation")?;
                let args = p.get("args").cloned().unwrap_or(json!({}));
                if jobs::durable(operation) {
                    let id = state.jobs.enqueue(operation, args)?;
                    emit_jobs(app, state);
                    state.jobs.wait(&id).await
                } else {
                    script_call(app, state, &store::id(), operation, args)
                        .await
                        .map_err(|error| error.message)
                }
            }
            "runtime_jobs" => state.jobs.visible(),
            "runtime_history" => Ok(json!(state.jobs.jobs()?)),
            "memory_recall" => Ok(state
                .store()?
                .memory_recall(
                    text(&p, "recordingId")?,
                    text(&p, "versionId")?,
                    text(&p, "fingerprint")?,
                )?
                .unwrap_or(Value::Null)),
            "memory_keep" => {
                state.store()?.memory_keep(
                    text(&p, "recordingId")?,
                    text(&p, "versionId")?,
                    text(&p, "fingerprint")?,
                    &p["value"],
                )?;
                Ok(Value::Null)
            }
            "trace_save" => {
                state.store()?.trace_save(&p)?;
                Ok(Value::Null)
            }
            "trace_list" => Ok(json!(state
                .store()?
                .trace_list(p["recordingId"].as_str())?)),
            "runtime_cancel" => {
                let recording = text(&p, "recordingId")?;
                let running = state
                    .jobs
                    .jobs()?
                    .iter()
                    .any(|j| j["recordingId"] == recording && j["state"] == "running");
                let ids = state.jobs.cancel(recording)?;
                if running {
                    state.inference.cancel();
                }
                for id in ids {
                    state.scripts.cancel(&id).await;
                }
                emit_jobs(app, state);
                Ok(Value::Null)
            }
            "recording_discard" => {
                let recording = text(&p, "id")?;
                dispatch(
                    app,
                    state,
                    "runtime_cancel",
                    json!({"recordingId":recording}),
                )
                .await?;
                let result = state.store()?.mutate(method, &p)?;
                Ok(result)
            }
            "recording_remove_audio" => {
                let recording = text(&p, "id")?;
                if state.jobs.jobs()?.iter().any(|j| {
                    j["recordingId"] == recording
                        && ["running", "queued", "retry"]
                            .contains(&j["state"].as_str().unwrap_or(""))
                }) {
                    return Err("Cancela el trabajo antes de quitar su audio".into());
                }
                state.store()?.mutate(method, &p)
            }
            "recording_status" => Ok(recorder::view(state)),
            "recording_dismiss" => {
                recorder::dismiss(app, state);
                Ok(recorder::view(state))
            }
            "recording_cancel" => recorder::cancel(app, state).await,
            "people_list" => state.store()?.people(),
            "people_set_color" => {
                state
                    .store()?
                    .set_person_color(text(&p, "name")?, text(&p, "color")?)?;
                Ok(Value::Null)
            }
            "people_rename" => {
                state
                    .store()?
                    .rename_person(text(&p, "name")?, text(&p, "newName")?)?;
                Ok(Value::Null)
            }
            "people_remove" => {
                state.store()?.remove_person(text(&p, "name")?)?;
                Ok(Value::Null)
            }
            "people_remove_voice" => {
                state.store()?.remove_person_voice(text(&p, "id")?)?;
                Ok(Value::Null)
            }
            "voice_registration_status" => state.voice_registration.view(),
            "voice_registration_cancel" | "voice_registration_dismiss" => {
                let view = if method == "voice_registration_cancel" {
                    state.voice_registration.cancel()?
                } else {
                    state.voice_registration.dismiss()?
                };
                let _ = app.emit("escriba://voice-registration", &view);
                Ok(view)
            }
            "voice_registration_start" => {
                state
                    .voice_registration
                    .start(text(&p, "name")?, |view| {
                        let _ = app.emit("escriba://voice-registration", view);
                    })
                    .await
            }
            "voice_registration_import" => {
                let view = state
                    .voice_registration
                    .import_audio(
                        text(&p, "name")?,
                        Path::new(text(&p, "path")?),
                        &state.inference,
                        &state.store,
                        |view| {
                            let _ = app.emit("escriba://voice-registration", view);
                        },
                    )
                    .await?;
                if view["state"] == "idle" {
                    let _ = app.emit("escriba://changed", ());
                }
                Ok(view)
            }
            "voice_registration_stop" => {
                let view = state
                    .voice_registration
                    .stop(&state.inference, &state.store, |view| {
                        let _ = app.emit("escriba://voice-registration", view);
                    })
                    .await?;
                let _ = app.emit("escriba://changed", ());
                Ok(view)
            }
            "import_audio" => {
                let paths = p["paths"]
                    .as_array()
                    .ok_or("Faltan los audios")?
                    .iter()
                    .map(|v| {
                        v.as_str()
                            .map(PathBuf::from)
                            .ok_or_else(|| "Ruta no válida".to_owned())
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let recipe = p["recipeId"].as_str().map(str::to_owned);
                let state = state.clone();
                tokio::task::spawn_blocking(move || {
                    let mut store = state.store()?;
                    paths
                        .iter()
                        .map(|path| store.import(path, recipe.as_deref()))
                        .collect::<Result<Vec<_>, _>>()
                        .map(|v| json!(v))
                })
                .await
                .map_err(|e| e.to_string())?
            }
            "credential_save" => {
                state.store()?.save_credential(
                    text(&p, "id")?,
                    p["value"].as_str().ok_or("Falta la credencial")?,
                )?;
                Ok(Value::Null)
            }
            "connector_remove" => {
                state.store()?.remove_connector(text(&p, "id")?)?;
                Ok(Value::Null)
            }
            "connector_save" => {
                state
                    .store()?
                    .save_connector(&p["account"], &p["destination"])?;
                Ok(Value::Null)
            }
            "native" => {
                let method = text(&p, "method")?;
                if !["status", "downloadModel"].contains(&method) {
                    return Err("Esta capacidad se ejecuta a través de la biblioteca".into());
                }
                let params = p.get("params").cloned().unwrap_or(json!({}));
                if method == "downloadModel" {
                    let model = params["model"].clone();
                    return state
                        .inference
                        .call_with_progress(method, params, |fraction| {
                            if let Err(error) = app.emit(
                                "escriba://whisper-download",
                                json!({"model":model,"fraction":fraction}),
                            ) {
                                log_error(
                                    state,
                                    &format!("No se pudo mostrar el progreso de descarga: {error}"),
                                );
                            }
                        })
                        .await
                        .map_err(Into::into);
                }
                state
                    .inference
                    .call(method, params)
                    .await
                    .map_err(Into::into)
            }
            "native_cancel" => {
                state.inference.cancel();
                Ok(Value::Null)
            }
            "transcribe" | "summarize" | "ask" => dispatch_inference(state, method, p)
                .await
                .map_err(|e| e.message),
            "recording_start" => {
                recorder::start(app, state, p["recipeId"].as_str().map(str::to_owned)).await
            }
            "recording_stop" => recorder::stop(app, state).await,
            "connector_http" => {
                let (account, grant, secret, audio) = {
                    let store = state.store()?;
                    let key = text(&p, "accountId")?;
                    let record_id = p["multipart"].as_array().and_then(|a| {
                        a.iter()
                            .find_map(|part| part["audio"]["recordingId"].as_str())
                    });
                    let audio = record_id
                        .map(|id| {
                            store.audio(id).map(|path| capabilities::AudioFile {
                                path,
                                recording_id: id.to_owned(),
                            })
                        })
                        .transpose()?;
                    let account = store.item("accounts", key)?;
                    let provider = match account["provider"].as_str() {
                        Some("notion" | "okf") => None,
                        Some(id) => Some(store.item("providers", id)?),
                        None => return Err("Cuenta sin proveedor".into()),
                    };
                    let grant =
                        capabilities::authorized_access(&account, provider.as_ref(), &p, "http")?;
                    (account, grant, store.credential(key)?, audio)
                };
                capabilities::http_with_grant(&account, &grant, secret, &p, audio).await
            }
            "connector_files" => {
                let account = {
                    let store = state.store()?;
                    let account = store.item("accounts", text(&p, "accountId")?)?;
                    let provider = match account["provider"].as_str() {
                        Some("notion" | "okf") => None,
                        Some(id) => Some(store.item("providers", id)?),
                        None => return Err("Cuenta sin proveedor".into()),
                    };
                    capabilities::authorized_access(&account, provider.as_ref(), &p, "folder")?;
                    account
                };
                tokio::task::spawn_blocking(move || capabilities::files(&account, &p))
                    .await
                    .map_err(|e| e.to_string())?
            }
            "connector_audio" => {
                let store = state.store()?;
                let record = store.recording(text(&p, "recordingId")?)?;
                if record["audioPath"].is_null() {
                    return Ok(Value::Null);
                }
                let path = store.audio(text(&p, "recordingId")?)?;
                let size = fs::metadata(&path).map_err(|e| e.to_string())?.len();
                Ok(
                    json!({"size":size,"type":audio_type(&path),"filename":path.file_name().unwrap_or_default().to_string_lossy()}),
                )
            }
            "project_init" => {
                let _project_guard = state.project_lock.lock().await;
                let path = PathBuf::from(text(&p, "path")?);
                let accounts = {
                    let store = state.store()?;
                    project_accounts(&store.data.accounts, &store.data.destinations)?
                };
                let has_dist =
                    project::initialize(&path, &accounts, &state.vendor, &state.project_runtime)?;
                state
                    .store()?
                    .mutate("settings_save", &json!({"settings":{"projectPath":path}}))?;
                Ok(json!({"hasDist":has_dist}))
            }
            "project_build" => {
                let _project_guard = state.project_lock.lock().await;
                let path = project_path(state)?;
                let runtime = state.project_runtime.clone();
                let vendor = state.vendor.clone();
                tokio::task::spawn_blocking(move || project::build(&path, &runtime, &vendor))
                    .await
                    .map_err(|e| e.to_string())?
            }
            "project_load" => {
                let _project_guard = state.project_lock.lock().await;
                let path = project_path(state)?;
                let runtime = state.project_runtime.clone();
                let vendor = state.vendor.clone();
                tokio::task::spawn_blocking(move || {
                    project::load_with_tools(&path, &runtime, &vendor)
                })
                .await
                .map_err(|e| e.to_string())?
            }
            "project_list" => project::list(&project_path(state)?),
            "project_open_vscode" => {
                let path = project_path(state)?
                    .canonicalize()
                    .map_err(|_| "La carpeta del proyecto no existe o no se puede abrir")?;
                if !path.is_dir() {
                    return Err("La ruta del proyecto no es una carpeta".into());
                }
                let status = std::process::Command::new("/usr/bin/open")
                    .args(["-b", "com.microsoft.VSCode"])
                    .arg(path)
                    .status()
                    .map_err(|e| format!("No se pudo abrir VS Code: {e}"))?;
                if !status.success() {
                    return Err("No se pudo abrir VS Code. Comprueba que esté instalado".into());
                }
                Ok(Value::Null)
            }
            "project_tool" => {
                let _project_guard = state.project_lock.lock().await;
                let path = project_path(state)?;
                let runtime = state.project_runtime.clone();
                let vendor = state.vendor.clone();
                let tool = text(&p, "tool")?.to_owned();
                tokio::task::spawn_blocking(move || project::tool(&path, &runtime, &vendor, &tool))
                    .await
                    .map_err(|e| e.to_string())?
            }
            "project_read" => project::read(&project_path(state)?, text(&p, "entry")?),
            "project_write" => {
                let _project_guard = state.project_lock.lock().await;
                let expected = p
                    .get("expectedSource")
                    .map(|value| value.as_str().ok_or("expectedSource debe ser texto"))
                    .transpose()?;
                let create_new = p
                    .get("createNew")
                    .map(|value| value.as_bool().ok_or("createNew debe ser booleano"))
                    .transpose()?
                    .unwrap_or(false);
                project::write_checked(
                    &project_path(state)?,
                    text(&p, "entry")?,
                    p["source"].as_str().ok_or("Falta el código")?,
                    expected,
                    create_new,
                )?;
                Ok(Value::Null)
            }
            "project_install" => {
                let mut store = state.store()?;
                catalog::install(&mut store, &p)?;
                Ok(Value::Null)
            }
            "export_file" => {
                let path = PathBuf::from(text(&p, "path")?);
                store::atomic_write(&path, text(&p, "contents")?.as_bytes())?;
                Ok(Value::Null)
            }
            "reveal" => {
                let path = PathBuf::from(text(&p, "path")?);
                if !path.exists() {
                    return Err("El archivo no existe".into());
                }
                let status = std::process::Command::new("/usr/bin/open")
                    .args(["-R"])
                    .arg(path)
                    .status()
                    .map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err("Finder no pudo abrir la ubicación".into());
                }
                Ok(Value::Null)
            }
            "okf_file" => {
                let account = state.store()?.item("accounts", text(&p, "accountId")?)?;
                let path = capabilities::authorized_okf_file(
                    &account,
                    std::path::Path::new(text(&p, "path")?),
                )?;
                let mut command = std::process::Command::new("/usr/bin/open");
                match text(&p, "action")? {
                    "open" => {}
                    "reveal" => {
                        command.arg("-R");
                    }
                    _ => return Err("Acción de archivo OKF desconocida".into()),
                }
                let status = command.arg(path).status().map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err("No se pudo abrir el documento OKF".into());
                }
                Ok(Value::Null)
            }
            "open_url" => {
                let url = reqwest::Url::parse(text(&p, "url")?).map_err(|_| "Enlace inválido")?;
                if !["http", "https"].contains(&url.scheme()) {
                    return Err("Solo se pueden abrir enlaces web".into());
                }
                let status = std::process::Command::new("/usr/bin/open")
                    .arg(url.as_str())
                    .status()
                    .map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err("No se pudo abrir el enlace".into());
                }
                Ok(Value::Null)
            }
            "system_appearance" => Ok(json!({"accent": appearance::accent()})),
            "resolver_models" => {
                let (draft, secret) = resolver_draft(state, &p)?;
                Ok(json!(remote::models(&draft, secret).await?))
            }
            "resolver_try" => {
                let (draft, secret) = resolver_draft(state, &p)?;
                let llm = text(&p, "role")? == "llm";
                let request = json!({"instructions": p["instructions"], "prompt": p["prompt"]});
                match (draft["local"] == true, llm) {
                    (true, true) => state
                        .inference
                        .call("summarize", request)
                        .await
                        .map_err(Into::into),
                    (true, false) => Err("Whisper en este Mac no tiene prueba".into()),
                    (false, true) => {
                        let mut request = request;
                        request["schema"] = remote::digest_schema();
                        remote::ask(&draft, secret, &request)
                            .await
                            .map_err(Into::into)
                    }
                    (false, false) => {
                        Ok(json!({"text": remote::probe_transcription(&draft, secret).await?}))
                    }
                }
            }
            "whisper_model" => whisper_model(state, &p).await,
            "open_privacy_settings" => {
                let pane = match p["pane"].as_str() {
                    Some("microphone") => {
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    }
                    Some("disk") => {
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    }
                    _ => "x-apple.systempreferences:com.apple.preference.security",
                };
                let status = std::process::Command::new("/usr/bin/open")
                    .arg(pane)
                    .status()
                    .map_err(|e| format!("No se pudieron abrir los ajustes: {e}"))?;
                if !status.success() {
                    return Err("No se pudieron abrir los Ajustes del Sistema".into());
                }
                Ok(Value::Null)
            }
            "watch_scan" => scan(app, state).await,
            "watch_folder_authorize" => authorize_watched_folder(app, state, &p).await,
            "settings_save" => {
                if let Some(enabled) = p["settings"]["launchAtLogin"].as_bool() {
                    use tauri_plugin_autostart::ManagerExt;
                    let auto = app.autolaunch();
                    if enabled {
                        auto.enable()
                    } else {
                        auto.disable()
                    }
                    .map_err(|e| format!("No se pudo cambiar el inicio automático: {e}"))?;
                }
                let saved = state.store()?.mutate(method, &p)?;
                let _ = state.watch_wake.try_send(());
                state.jobs.wake.notify_one();
                Ok(saved)
            }
            _ => state.store()?.mutate(method, &p),
        }
    })
}
fn project_path(state: &Runtime) -> Result<PathBuf, String> {
    state
        .store()?
        .data
        .settings
        .project_path
        .as_ref()
        .map(String::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| "Elige la carpeta del proyecto en Recetas".into())
}

fn project_accounts(accounts: &Value, destinations: &Value) -> Result<Value, String> {
    let destinations = destinations.as_array().ok_or("Destinos inválidos")?;
    let accounts = accounts.as_array().ok_or("Cuentas inválidas")?;
    Ok(json!(accounts
        .iter()
        .filter(|account| !destinations.iter().any(|destination| {
            destination["id"] == account["id"]
                && destination["account"] == account["id"]
                && destination["program"].is_null()
        }))
        .collect::<Vec<_>>()))
}
async fn authorize_watched_folder(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
    params: &Value,
) -> Result<Value, String> {
    let folder_id = params["folderId"].as_str();
    let voice_memos = folder_id.is_none() && params["style"] == "voiceMemos";
    let initial_path = {
        let store = state.store()?;
        match folder_id {
            None if voice_memos => Some(voice_memos_root(app)?),
            Some(id) => Some(PathBuf::from(
                store
                    .data
                    .settings
                    .watched_folders
                    .as_ref()
                    .and_then(|folders| folders.iter().find(|folder| folder.id == id))
                    .ok_or("La carpeta ya no está configurada")?
                    .path
                    .as_str(),
            )),
            None => None,
        }
    };
    let (reply, receive) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let _ = reply.send(folder_access::select_folder(initial_path.as_deref()));
    })
    .map_err(|error| format!("No se pudo abrir el selector de carpetas: {error}"))?;
    let Some(selected) = receive
        .await
        .map_err(|_| "El selector de carpetas se cerró inesperadamente")??
    else {
        return Ok(Value::Null);
    };
    let _scan = state.scan_lock.lock().await;
    let resolved = folder_access::restore(&selected.bookmark)?;
    if resolved.path != selected.path {
        return Err("La carpeta cambió mientras se autorizaba. Vuelve a seleccionarla".into());
    }
    let bookmark = resolved
        .refreshed_bookmark
        .clone()
        .unwrap_or(selected.bookmark);
    let saved = state.store()?.authorize_watched_folder(
        folder_id,
        &resolved.path,
        params["name"]
            .as_str()
            .or(voice_memos.then_some("Notas de Voz")),
        params["style"].as_str().unwrap_or("any"),
        &bookmark,
    )?;
    state
        .folder_accesses
        .lock()
        .map_err(|_| "No se pudo mantener el acceso a la carpeta")?
        .insert(
            text(&saved, "id")?.to_owned(),
            FolderAccess { bookmark, resolved },
        );
    let _ = state.watch_wake.try_send(());
    Ok(saved)
}

fn voice_memos_root(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .home_dir()
        .map_err(|e| e.to_string())?
        .join("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"))
}

fn restore_watched_folders(state: &Runtime) -> Result<Vec<watcher::FolderError>, String> {
    let bookmarks = state.store()?.watched_folder_bookmarks()?;
    let mut accesses = state
        .folder_accesses
        .lock()
        .map_err(|_| "No se pudo mantener el acceso a las carpetas")?;
    accesses.retain(|id, access| {
        bookmarks.iter().any(|(folder_id, path, bookmark)| {
            folder_id == id && bookmark == &access.bookmark && path == &access.resolved.path
        })
    });
    let mut issues = Vec::new();
    for (id, path, bookmark) in bookmarks {
        if accesses.contains_key(&id) {
            continue;
        }
        match folder_access::restore(&bookmark) {
            Ok(resolved) => {
                if state.store()?.refresh_watched_folder_bookmark(
                    &id,
                    &bookmark,
                    &resolved.path,
                    resolved.refreshed_bookmark.as_deref(),
                )? {
                    let bookmark = resolved.refreshed_bookmark.clone().unwrap_or(bookmark);
                    accesses.insert(id, FolderAccess { bookmark, resolved });
                }
            }
            Err(message) => issues.push(watcher::FolderError {
                folder_id: id,
                path,
                message: format!("Vuelve a autorizar la carpeta: {message}"),
                permission_denied: false,
            }),
        }
    }
    Ok(issues)
}

fn audio_type(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
        "ogg" | "oga" | "opus" => "audio/ogg",
        "aif" | "aiff" => "audio/aiff",
        "caf" => "audio/x-caf",
        "webm" => "audio/webm",
        _ => "audio/mp4",
    }
}
fn folders(state: &Runtime) -> Result<Vec<watcher::Folder>, String> {
    state
        .store()?
        .data
        .settings
        .watched_folders
        .as_ref()
        .ok_or("Carpetas inválidas")?
        .iter()
        .map(|folder| {
            Ok(watcher::Folder {
                id: folder.id.clone(),
                path: PathBuf::from(&folder.path),
                enabled: folder.enabled.as_ref() != Some(&false),
                style: watcher::Style::parse(folder.style.as_ref().map(String::as_str))?,
            })
        })
        .collect()
}
fn log_error(state: &Runtime, message: &str) {
    if let Ok(mut store) = state.store() {
        if let Err(error) = store.mutate("log", &json!({"level":"error","message":message})) {
            eprintln!("{message}; no se pudo guardar el error: {error}");
        }
    } else {
        eprintln!("{message}");
    }
}
async fn scan(app: &tauri::AppHandle, state: &Arc<Runtime>) -> Result<Value, String> {
    let _scan = state.scan_lock.lock().await;
    let mut issues = restore_watched_folders(state)?;
    let watched = folders(state)?;
    let watched_paths: Vec<_> = watched.iter().map(|folder| folder.path.clone()).collect();
    let runtime = state.clone();
    let batch = tokio::task::spawn_blocking(move || {
        runtime
            .scanner
            .lock()
            .map_err(|_| "Escaneo ocupado".to_owned())
            .map(|mut scanner| scanner.scan(&watched, SystemTime::now()))
    })
    .await
    .map_err(|e| e.to_string())??;
    issues.extend(batch.errors);
    let mut added = Vec::new();
    for candidate in batch
        .ready
        .into_iter()
        .chain(batch.zero)
        .chain(batch.abandoned)
    {
        let status = match watcher::file_status(&candidate.path) {
            Ok(status) => status,
            Err(error) => {
                issues.push(watcher::FolderError::from_io(
                    candidate.folder_id.clone(),
                    candidate.path.clone(),
                    error,
                ));
                continue;
            }
        };
        if status["dataless"] == true {
            let requested_at = SystemTime::now();
            let start = {
                let mut inflight = state
                    .materializing
                    .lock()
                    .map_err(|_| "Materialización ocupada")?;
                let should = inflight.request(&candidate.path, requested_at);
                if let Some(issue) = inflight.issue(&candidate) {
                    issues.push(issue);
                }
                should
            };
            if start {
                let folder_bookmark = state
                    .folder_accesses
                    .lock()
                    .map_err(|_| "No se pudo consultar el acceso a la carpeta")?
                    .get(&candidate.folder_id)
                    .map(|access| access.bookmark.clone());
                let runtime = state.clone();
                tokio::spawn(async move {
                    let result = runtime
                        .materializer
                        .call(
                            "materialize",
                            json!({"path":candidate.path,"timeoutSeconds":60,"folderBookmark":folder_bookmark}),
                        )
                        .await
                        .and_then(|result| {
                            if result["ready"] == true {
                                Ok(())
                            } else {
                                Err("El audio sigue pendiente de descarga desde iCloud".into())
                            }
                        }).map_err(String::from);
                    match runtime.materializing.lock() {
                        Ok(mut inflight) => {
                            inflight.complete(&candidate.path, requested_at, result);
                        }
                        Err(_) => {
                            log_error(&runtime, "No se pudo actualizar la descarga de iCloud")
                        }
                    }
                    let _ = runtime.watch_wake.try_send(());
                });
            }
            continue;
        }
        state
            .materializing
            .lock()
            .map_err(|_| "Materialización ocupada")?
            .forget(&candidate.path);
        if status["size"].as_u64().unwrap_or(0) == 0 {
            if candidate.stamp.modified.elapsed().unwrap_or_default() >= Duration::from_secs(3600) {
                let record = state.store()?.mutate("recording_abandoned", &json!({"path":candidate.path,"source":candidate.folder_id,"sourceKey":candidate.source_key,"title":candidate.title,"modifiedAt":chrono::DateTime::<chrono::Utc>::from(candidate.started_at).to_rfc3339()}))?;
                notify_problem(
                    state,
                    Problem::Failed {
                        key: text(&record, "id")?,
                        reason: "el fichero está vacío (0 bytes) desde hace más de una hora",
                    },
                );
                state
                    .scanner
                    .lock()
                    .map_err(|_| "Escaneo ocupado")?
                    .acknowledge(&candidate);
            }
            continue;
        }
        let result = state.store()?.import_with_metadata(
            &candidate.path,
            None,
            &candidate.title,
            candidate.started_at,
            &candidate.source_key,
        );
        match result {
            Ok(record) => {
                state
                    .scanner
                    .lock()
                    .map_err(|_| "Escaneo ocupado")?
                    .acknowledge(&candidate);
                added.push(record);
            }
            Err(error) => issues.push(watcher::FolderError {
                folder_id: candidate.folder_id,
                path: candidate.path,
                message: format!("No se pudo incorporar el audio: {error}"),
                permission_denied: false,
            }),
        }
    }
    let changed = state
        .watch_health
        .lock()
        .map_err(|_| "No se pudo actualizar el acceso a las carpetas")?
        .update(issues);
    if let Some(issues) = changed {
        for error in &issues {
            log_error(
                state,
                &format!(
                    "Carpeta {} ({}): {}",
                    error.folder_id,
                    error.path.display(),
                    error.message
                ),
            );
        }
        let _ = app.emit("escriba://changed", ());
        for issue in &issues {
            if watched_paths.contains(&issue.path) {
                notify_problem(
                    state,
                    Problem::FolderInaccessible(&issue.path.to_string_lossy()),
                );
            } else {
                notify_problem(state, Problem::ScanFailed(&issue.message));
            }
        }
    }
    recover_captures(state).await?;
    state.jobs.wake.notify_one();
    Ok(json!(added))
}
async fn recover_captures(state: &Arc<Runtime>) -> Result<(), String> {
    let root = state.store()?.root.join("captures");
    let captures = fs::read_dir(root)
        .map_err(|e| e.to_string())?
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "m4a"))
        .collect::<Vec<_>>();
    if captures.is_empty() {
        return Ok(());
    }
    let status = state.recorder.call("recordingStatus", json!({})).await?;
    if status["active"] == true {
        return Ok(());
    }
    for capture in captures {
        let path = capture.path();
        let metadata = capture.metadata().map_err(|e| e.to_string())?;
        if metadata.len() == 0 {
            continue;
        }
        let result = state.store()?.import_recovered_capture(&path);
        match result {
            Ok(record) => {
                state.store()?.mutate("log", &json!({"level":"warn","recordingId":record["id"],"message":"Recuperada una captura pendiente de guardar"}))?;
                fs::remove_file(&path).map_err(|e| {
                    format!("Captura recuperada; no se pudo retirar el temporal: {e}")
                })?;
            }
            Err(error) => log_error(
                state,
                &format!("No se pudo recuperar {}: {error}", path.display()),
            ),
        }
    }
    Ok(())
}
fn notify(state: &Runtime, notice: notifications::Notification) {
    if let Err(error) = notification_delivery::send(&notice) {
        log_error(state, &error);
    }
}
fn notify_problem(state: &Runtime, problem: Problem<'_>) {
    notify(state, notifications::notification(problem));
}
async fn warn_about_unusable(app: &tauri::AppHandle, state: &Arc<Runtime>) {
    let model = match state.store() {
        Ok(store) => json!(store.data.settings.whisper_model.as_ref()),
        Err(error) => {
            notify_problem(state, Problem::StartupFailed(&error));
            return;
        }
    };
    let status = match state
        .inference
        .call("status", json!({"model": model}))
        .await
    {
        Ok(status) => status,
        Err(error) => {
            log_error(state, &error.message);
            notify_problem(state, Problem::BackendUnavailable(&error.message));
            return;
        }
    };
    match script_call(
        app,
        state,
        &store::id(),
        "notificationProblems",
        json!({"status": {
            "protocolVersion": status["protocolVersion"],
            "whisper": {"available": status["whisper"]["available"]},
            "llm": {"available": status["llm"]["available"], "reason": status["llm"]["reason"]}
        }}),
    )
    .await
    {
        Ok(value) => {
            match serde_json::from_value::<Vec<notification_events::ResolverProblem>>(value) {
                Ok(problems) => {
                    for problem in problems {
                        log_error(state, &problem.reason);
                        notify(state, problem.notification());
                    }
                }
                Err(error) => log_error(
                    state,
                    &format!("No se pudieron leer los avisos de los resolutores: {error}"),
                ),
            }
        }
        Err(error) => {
            log_error(state, &error.message);
            notify_problem(state, Problem::RecipesUnavailable(&error.message));
        }
    }
}
fn job_notification(
    state: &Runtime,
    job: &Value,
    result: &Result<Value, error::AppError>,
) -> Result<Option<notifications::Notification>, String> {
    let store = state.store()?;
    let record = store.recording(text(job, "recordingId")?)?;
    Ok(notification_events::finished(
        job,
        &record,
        result.as_ref(),
        &store.settings_json(),
    ))
}
fn emit_jobs(app: &tauri::AppHandle, state: &Runtime) {
    match state.jobs.visible() {
        Ok(jobs) => {
            let _ = app.emit("escriba://jobs", jobs);
        }
        Err(error) => log_error(state, &error),
    }
    let _ = app.emit("escriba://changed", ());
}
async fn script_call(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
    id: &str,
    operation: &str,
    args: Value,
) -> Result<Value, error::AppError> {
    let weak = Arc::downgrade(state);
    let handle = app.clone();
    let capability: scripts::Capability = Arc::new(move |method, params, _task, lease| {
        let weak = weak.clone();
        let handle = handle.clone();
        Box::pin(async move {
            let state = weak.upgrade().ok_or("La aplicación se cerró")?;
            lease.ensure_active()?;
            let result = if matches!(method.as_str(), "transcribe" | "summarize" | "ask") {
                dispatch_inference(&state, &method, params).await
            } else {
                dispatch(&handle, &state, &method, params)
                    .await
                    .map_err(error::AppError::from)
            }
            .and_then(|value| voices::public_reply(value).map_err(Into::into));
            if result.is_ok() && !["runtime_context", "connector_audio"].contains(&method.as_str())
            {
                let _ = handle.emit("escriba://changed", ());
            }
            result
        })
    });
    let weak = Arc::downgrade(state);
    let handle = app.clone();
    let events: scripts::Events = Arc::new(move |event| {
        if let Some(state) = weak.upgrade() {
            if event["event"] == "jobs" {
                if let Err(error) = state.jobs.stages(&event["value"]) {
                    log_error(&state, &error);
                }
                emit_jobs(&handle, &state);
            }
        }
    });
    state
        .scripts
        .call(id, operation, args, capability, events)
        .await
}
fn start_jobs(app: tauri::AppHandle, state: Arc<Runtime>) {
    tauri::async_runtime::spawn(async move {
        loop {
            if let Err(error) = state.jobs.automatic() {
                log_error(&state, &error);
            }
            match state.jobs.claim() {
                Ok(Some(job)) => {
                    emit_jobs(&app, &state);
                    let id = job["id"].as_str().unwrap_or("");
                    let result = script_call(
                        &app,
                        &state,
                        id,
                        job["operation"].as_str().unwrap_or(""),
                        job["args"].clone(),
                    )
                    .await;
                    let notice = job_notification(&state, &job, &result);
                    match state.jobs.finish(id, result) {
                        Ok(true) => match notice {
                            Ok(Some(notice)) => notify(&state, notice),
                            Err(error) => log_error(&state, &error),
                            _ => {}
                        },
                        Ok(false) => {}
                        Err(error) => log_error(&state, &error),
                    }
                    emit_jobs(&app, &state);
                }
                Ok(None) => {
                    state.inference.unload_if_idle(Duration::from_secs(300));
                    tokio::select! { _ = state.jobs.wake.notified() => {}, _ = tokio::time::sleep(Duration::from_secs(5)) => {} }
                }
                Err(error) => {
                    log_error(&state, &error);
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        }
    });
}
fn start_project_watcher(app: tauri::AppHandle, state: Arc<Runtime>) {
    tauri::async_runtime::spawn(async move {
        let (sender, mut receiver) =
            tokio::sync::mpsc::unbounded_channel::<project_watch::Change>();
        let mut watching: Option<(String, notify::RecommendedWatcher)> = None;
        loop {
            let path = state
                .store()
                .ok()
                .and_then(|store| store.data.settings.project_path.as_ref().cloned());
            if watching.as_ref().map(|(current, _)| current) != path.as_ref() {
                watching = match path {
                    Some(path) => match project_watch::watch(&path, sender.clone()) {
                        Ok(watcher) => {
                            let action = if Path::new(&path).join("dist/escriba.json").is_file() {
                                project_watch::Change::Load
                            } else {
                                project_watch::Change::Build
                            };
                            let _ = sender.send(action);
                            Some((path, watcher))
                        }
                        Err(error) => {
                            log_error(
                                &state,
                                &format!("No se puede vigilar el proyecto de recetas: {error}"),
                            );
                            None
                        }
                    },
                    None => None,
                };
            }
            tokio::select! {
                Some(mut action) = receiver.recv() => {
                    tokio::time::sleep(Duration::from_millis(800)).await;
                    while let Ok(next) = receiver.try_recv() {
                        if next == project_watch::Change::Build {
                            action = next;
                        }
                    }
                    let _ = app.emit("escriba://project", json!({"phase": "building"}));
                    let result = script_call(&app, &state, &store::id(), "rebuildProject", json!({"loadOnly":action == project_watch::Change::Load})).await;
                    let phase = match &result {
                        Ok(_) => json!({"phase": "ready"}),
                        Err(error) => json!({"phase": "failed", "message": error}),
                    };
                    let _ = app.emit("escriba://project", phase);
                    let _ = app.emit("escriba://changed", ());
                }
                _ = tokio::time::sleep(Duration::from_secs(5)) => {}
            }
        }
    });
}

fn start_watcher(
    app: tauri::AppHandle,
    state: Arc<Runtime>,
    mut wake: tokio::sync::mpsc::Receiver<()>,
) {
    tauri::async_runtime::spawn(async move {
        let mut previous: Option<Vec<store::WatchedFolder>> = None;
        let mut watcher = None;
        loop {
            match scan(&app, &state).await {
                Ok(items) if items.as_array().is_some_and(|v| !v.is_empty()) => {
                    let _ = app.emit("escriba://imported", items);
                    let _ = app.emit("escriba://changed", ());
                }
                Err(error) => {
                    log_error(&state, &error);
                    notify_problem(&state, Problem::ScanFailed(&error));
                }
                _ => {}
            }
            let current = state
                .store()
                .map(|s| s.data.settings.watched_folders.as_ref().cloned());
            match current {
                Ok(current) if current != previous => {
                    match folders(&state).and_then(|f| watcher::watch(&f, state.watch_wake.clone()))
                    {
                        Ok(next) => {
                            for error in &next.errors {
                                log_error(&state, &error.message);
                                notify_problem(
                                    &state,
                                    Problem::FolderInaccessible(&error.path.to_string_lossy()),
                                );
                            }
                            watcher = Some(next);
                            previous = current;
                        }
                        Err(error) => {
                            log_error(&state, &error);
                            notify_problem(&state, Problem::ScanFailed(&error));
                        }
                    }
                }
                Err(error) => {
                    log_error(&state, &error);
                    notify_problem(&state, Problem::ScanFailed(&error));
                }
                _ => {}
            }
            tokio::select! { _ = wake.recv() => {}, _ = tokio::time::sleep(Duration::from_secs(15)) => {} }
            std::hint::black_box(&watcher);
        }
    });
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            let _ = menubar::show(app, "library");
            if let Err(error) = notification_delivery::send(&notifications::notification(
                Problem::AlreadyOpen("otra copia"),
            )) {
                eprintln!("{error}");
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .app_name("Escriba")
                .macos_launcher(tauri_plugin_autostart::MacosLauncher::LaunchAgent)
                .build(),
        )
        .setup(|app| {
            if let Err(error) = notification_delivery::request_authorization() {
                eprintln!("{error}");
            }
            let result: Result<(), Box<dyn std::error::Error>> = (|| {
                let isolated_root = std::env::var_os("ESCRIBA_TAURI_DATA").map(PathBuf::from);
                let root = isolated_root.clone().unwrap_or(app.path().app_data_dir()?);
                let store = Store::open(root.clone()).map_err(std::io::Error::other)?;
                app.asset_protocol_scope()
                    .allow_directory(root.join("audio"), true)?;
                let resource_vendor = app.path().resource_dir()?.join("vendor");
                let vendor = if resource_vendor.is_dir() {
                    resource_vendor
                } else {
                    Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor")
                };
                let engine = native::binary("EscribaNativeHost").map_err(std::io::Error::other)?;
                let store = Arc::new(Mutex::new(store));
                let jobs =
                    Arc::new(jobs::Queue::new(store.clone()).map_err(std::io::Error::other)?);
                let (watch_wake, wake) = tokio::sync::mpsc::channel(1);
                let state = Arc::new(Runtime {
                    knowledge: tokio::sync::OnceCell::new(),
                    knowledge_path: root.join("knowledge.surrealkv"),
                    store,
                    jobs,
                    scripts: scripts::Scripts::new(
                        native::binary("escriba-runtime").map_err(std::io::Error::other)?,
                    ),
                    materializer: native::Native::new(engine.clone()),
                    materializing: Mutex::new(watcher::Materializations::default()),
                    scanner: Mutex::new(watcher::Scanner::new()),
                    watch_health: Mutex::new(watcher::Health::default()),
                    scan_lock: tokio::sync::Mutex::new(()),
                    folder_accesses: Mutex::new(HashMap::new()),
                    watch_wake,
                    inference: native::Native::new(engine.clone()),
                    voice_registration: voice_registration::Registration::new(
                        root.join("voice-samples"),
                        engine.clone(),
                    )
                    .map_err(std::io::Error::other)?,
                    recorder: native::Native::new(engine),
                    recording: Mutex::new(None),
                    recording_problem: Mutex::new(None),
                    recording_lock: tokio::sync::Mutex::new(()),
                    menubar: Mutex::new(menubar::Bar::default()),
                    quitting: AtomicBool::new(false),
                    vendor,
                    project_runtime: native::binary("escriba-runtime")
                        .map_err(std::io::Error::other)?,
                    project_lock: tokio::sync::Mutex::new(()),
                });
                app.manage(state.clone());
                if isolated_root.is_none() {
                    let enabled = state
                        .store()
                        .map_err(std::io::Error::other)?
                        .data
                        .settings
                        .launch_at_login
                        .as_ref()
                        == Some(&true);
                    if let Err(error) = login::synchronize(app.handle(), enabled) {
                        log_error(
                            &state,
                            &format!("No se pudo actualizar el inicio automático: {error}"),
                        );
                    }
                }
                menubar::install(app.handle(), &state)?;
                app.on_menu_event(|app, event| menubar::handle(app, event.id().as_ref()));
                menubar::watch(app.handle().clone());
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    if let Ok(root) = voice_memos_root(&handle) {
                        let seeded = state
                            .store()
                            .and_then(|mut store| store.seed_voice_memos(&root));
                        match seeded {
                            Ok(true) => {
                                let _ = handle.emit("escriba://changed", ());
                            }
                            Ok(false) => {}
                            Err(error) => log_error(&state, &error),
                        }
                    }
                    warn_about_unusable(&handle, &state).await;
                    start_jobs(handle.clone(), state.clone());
                    start_project_watcher(handle.clone(), state.clone());
                    start_watcher(handle, state, wake);
                });
                Ok(())
            })();
            if let Err(error) = &result {
                if let Err(delivery) = notification_delivery::send(&notifications::notification(
                    Problem::StartupFailed(&error.to_string()),
                )) {
                    eprintln!("{delivery}");
                }
            }
            result
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![app_command])
        .build(tauri::generate_context!())
        .unwrap_or_else(|error| {
            eprintln!("No se pudo iniciar Escriba: {error}");
            std::process::exit(1);
        })
        .run(|app, event| match event {
            tauri::RunEvent::ExitRequested { api, .. } => {
                let state = app.state::<Arc<Runtime>>().inner().clone();
                if !state.quitting.load(std::sync::atomic::Ordering::SeqCst)
                    && recorder::is_recording(&state)
                {
                    api.prevent_exit();
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move { menubar::quit(&app, &state).await });
                }
            }
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Reopen { .. } => {
                let _ = menubar::show(app, "library");
            }
            _ => {}
        });
}

#[cfg(test)]
mod command_events_tests {
    use super::*;

    #[test]
    fn iniciar_proyecto_no_genera_destinos_para_cuentas_con_conector_en_la_app() {
        let accounts = json!([
            {"id":"app","name":"App","provider":"notion","enabled":true},
            {"id":"code","name":"Code","provider":"okf","enabled":true}
        ]);
        let destinations = json!([
            {"id":"app","account":"app","provider":"notion","configuration":{}},
            {"id":"coded","account":"code","provider":"okf","program":"compiled"}
        ]);
        assert_eq!(
            project_accounts(&accounts, &destinations).unwrap(),
            json!([accounts[1]])
        );
    }

    #[test]
    fn polling_the_library_and_recorder_does_not_request_another_refresh() {
        let refresh_cycle = [
            "snapshot",
            "recording_status",
            "runtime_jobs",
            "knowledge_filter_notes",
            "knowledge_filters_list",
            "knowledge_list",
        ];
        assert!(!refresh_cycle
            .iter()
            .any(|method| refreshes_library(method, &json!({}))));
    }

    #[test]
    fn loading_a_recipe_form_does_not_invalidate_its_input_snapshot() {
        assert!(!refreshes_library(
            "runtime_run",
            &json!({"operation":"getRecipeSchema"})
        ));
    }

    #[test]
    fn changes_to_recordings_and_recipe_catalogues_still_refresh_the_window() {
        assert!(refreshes_library("recording_stop", &json!({})));
        assert!(refreshes_library(
            "runtime_run",
            &json!({"operation":"rebuildProject"})
        ));
        assert!(refreshes_library("knowledge_filter_save", &json!({})));
        assert!(refreshes_library("knowledge_filter_remove", &json!({})));
    }
}
