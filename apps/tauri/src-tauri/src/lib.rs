mod appearance;
mod capabilities;
mod catalog;
mod folder_access;
mod jobs;
mod library_view;
mod menubar;
mod migration;
mod native;
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
    compiler: PathBuf,
    startup: Mutex<Startup>,
}

struct FolderAccess {
    bookmark: Vec<u8>,
    resolved: folder_access::ResolvedFolder,
}

#[derive(Default)]
struct Startup {
    snapshot: Option<Value>,
    error: Option<String>,
}

impl Runtime {
    fn store(&self) -> Result<std::sync::MutexGuard<'_, Store>, String> {
        self.store
            .lock()
            .map_err(|_| "No se pudo acceder a la biblioteca".into())
    }

    fn startup_reply(&self, method: &str) -> Result<Option<Value>, String> {
        let startup = self
            .startup
            .lock()
            .map_err(|_| "No se pudo consultar el arranque")?;
        let Some(snapshot) = &startup.snapshot else {
            return Ok(None);
        };
        match method {
            "snapshot" => Ok(Some(snapshot.clone())),
            "library" => Ok(Some(library_view::light_library(snapshot))),
            "runtime_jobs" => Ok(Some(json!([]))),
            "recording_status" => Ok(Some(recording::view(None, None))),
            "system_appearance" => Ok(Some(json!({"accent": appearance::accent()}))),
            _ => Err("Espera a que termine de incorporarse la biblioteca anterior".into()),
        }
    }

    fn library(&self) -> Result<Value, String> {
        let library = self.store()?.library();
        self.decorate(library)
    }

    fn snapshot(&self) -> Result<Value, String> {
        let snapshot = self.store()?.snapshot();
        self.decorate(snapshot)
    }

    fn decorate(&self, mut snapshot: Value) -> Result<Value, String> {
        let startup = self
            .startup
            .lock()
            .map_err(|_| "No se pudo consultar el arranque")?;
        if let Some(error) = &startup.error {
            snapshot["settings"]["startupMigration"] = json!({"state":"error","message":error});
        }
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
    let result = dispatch(&app, &runtime, &method, params)
        .await
        .and_then(voices::public_reply);
    if result.is_ok() && refresh {
        let _ = app.emit("escriba://changed", ());
    }
    if refresh {
        state.jobs.wake.notify_one();
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
    let model = state.store()?.data["settings"]["whisperModel"].clone();
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
        | "library_import"
        | "recording_update"
        | "recording_discard"
        | "recording_delete"
        | "recording_restore"
        | "recording_remove_audio"
        | "recording_stop"
        | "version_save"
        | "version_select"
        | "version_update"
        | "settings_save"
        | "config_save"
        | "config_remove"
        | "connector_save"
        | "connector_remove"
        | "people_rename"
        | "people_remove"
        | "people_remove_voice"
        | "credential_save"
        | "publication_save"
        | "publication_remove"
        | "project_init"
        | "project_install"
        | "project_write"
        | "log"
        | "log_clear"
        | "trace_save"
        | "runtime_cancel"
        | "watch_scan"
        | "watch_folder_authorize" => true,
        _ => false,
    }
}

fn dispatch<'a>(
    app: &'a tauri::AppHandle,
    state: &'a Arc<Runtime>,
    method: &'a str,
    p: Value,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value, String>> + Send + 'a>> {
    Box::pin(async move {
        if let Some(reply) = state.startup_reply(method)? {
            return Ok(reply);
        }
        match method {
            "snapshot" => state.snapshot(),
            "library" => state.library(),
            "recording_detail" => state.store()?.recording(text(&p, "id")?),
            "runtime_context" => state.store()?.runtime_context(
                p.get("recordingId")
                    .map(|_| text(&p, "recordingId"))
                    .transpose()?,
            ),
            "runtime_run" => {
                let operation = text(&p, "operation")?;
                let args = p.get("args").cloned().unwrap_or(json!({}));
                if jobs::durable(operation) {
                    let id = state.jobs.enqueue(operation, args)?;
                    emit_jobs(app, state);
                    state.jobs.wait(&id).await
                } else {
                    script_call(app, state, &store::id(), operation, args).await
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
            "library_import" => {
                let home = app.path().home_dir().map_err(|e| e.to_string())?;
                let path = match p["path"].as_str() {
                    Some(path) => PathBuf::from(path),
                    None => home.join("Library/Application Support/escriba/library"),
                };
                let settings = match p["settingsPath"].as_str() {
                    Some(path) => Some(PathBuf::from(path)),
                    None if p["path"].is_null() => {
                        Some(home.join("Library/Preferences/dev.ruben.escriba.plist"))
                            .filter(|path| path.is_file())
                    }
                    None => None,
                };
                let state = state.clone();
                tokio::task::spawn_blocking(move || match settings {
                    Some(settings) => state
                        .store()?
                        .import_legacy_with_settings(&path, Some(&settings)),
                    None => state.store()?.import_legacy(&path),
                })
                .await
                .map_err(|e| e.to_string())?
            }
            "recording_discard" | "recording_delete" => {
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
            "notification_permission" => {
                notify(app, state, "Escriba", "Las notificaciones de Escriba están disponibles. Puedes ajustarlas en Ajustes del Sistema.")?;
                Ok(json!("sent"))
            }
            "recording_restore" => {
                let record = state.store()?.mutate(method, &p)?;
                let automatic = state.store()?.data["settings"]["autoProcess"] == true;
                if automatic && record["audioPath"].is_string() {
                    state.jobs.enqueue(
                        "processRecording",
                        json!({"recordingId":record["id"],"options":{"force":false}}),
                    )?;
                }
                Ok(record)
            }
            "recording_status" => Ok(recorder::view(state)),
            "recording_dismiss" => {
                recorder::dismiss(app, state);
                Ok(recorder::view(state))
            }
            "recording_cancel" => recorder::cancel(app, state).await,
            "people_list" => state.store()?.people(),
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
                state
                    .inference
                    .call(method, p.get("params").cloned().unwrap_or(json!({})))
                    .await
            }
            "native_cancel" => {
                state.inference.cancel();
                Ok(Value::Null)
            }
            "transcribe" => {
                let (audio, resolver, secret, model) = {
                    let store = state.store()?;
                    let key = p["resolverId"].as_str().unwrap_or("local-stt");
                    (
                        store.audio(text(&p, "recordingId")?)?,
                        store.item("resolvers", key)?,
                        store.credential(key)?,
                        store.data["settings"]["whisperModel"].clone(),
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
            "recording_start" => {
                recorder::start(app, state, p["recipeId"].as_str().map(str::to_owned)).await
            }
            "recording_stop" => recorder::stop(app, state).await,
            "connector_http" => {
                let (account, secret, audio) = {
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
                    (store.item("accounts", key)?, store.credential(key)?, audio)
                };
                capabilities::http(&account, secret, &p, audio).await
            }
            "connector_files" => {
                let account = state.store()?.item("accounts", text(&p, "accountId")?)?;
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
                let path = PathBuf::from(text(&p, "path")?);
                let accounts = {
                    let store = state.store()?;
                    project_accounts(&store.data["accounts"], &store.data["destinations"])?
                };
                project::initialize(&path, &accounts, &state.vendor)?;
                state
                    .store()?
                    .mutate("settings_save", &json!({"settings":{"projectPath":path}}))?;
                Ok(Value::Null)
            }
            "project_build" => {
                let path = project_path(state)?;
                let compiler = state.compiler.clone();
                let vendor = state.vendor.clone();
                tokio::task::spawn_blocking(move || project::build(&path, &compiler, &vendor))
                    .await
                    .map_err(|e| e.to_string())?
            }
            "project_read" => project::read(&project_path(state)?, text(&p, "entry")?),
            "project_write" => {
                project::write(
                    &project_path(state)?,
                    text(&p, "entry")?,
                    p["source"].as_str().ok_or("Falta el código")?,
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
                    (true, true) => state.inference.call("summarize", request).await,
                    (true, false) => Err("Whisper en este Mac no tiene prueba".into()),
                    (false, true) => {
                        let mut request = request;
                        request["schema"] = remote::digest_schema();
                        remote::ask(&draft, secret, &request).await
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
    state.store()?.data["settings"]["projectPath"]
        .as_str()
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
            Some(id) => Some(PathBuf::from(text(
                store.data["settings"]["watchedFolders"]
                    .as_array()
                    .and_then(|folders| folders.iter().find(|folder| folder["id"] == id))
                    .ok_or("La carpeta ya no está configurada")?,
                "path",
            )?)),
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
    state.store()?.data["settings"]["watchedFolders"]
        .as_array()
        .ok_or("Carpetas inválidas")?
        .iter()
        .map(|folder| {
            Ok(watcher::Folder {
                id: text(folder, "id")?.to_owned(),
                path: PathBuf::from(text(folder, "path")?),
                enabled: folder["enabled"] != false,
                style: watcher::Style::parse(folder["style"].as_str())?,
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
                        });
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
                let mut store = state.store()?;
                store.mutate("recording_abandoned", &json!({"path":candidate.path,"source":candidate.folder_id,"sourceKey":candidate.source_key,"title":candidate.title,"modifiedAt":chrono::DateTime::<chrono::Utc>::from(candidate.started_at).to_rfc3339()}))?;
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
        if !issues.is_empty() {
            let message = if issues.iter().any(|issue| issue.permission_denied) {
                "macOS ha denegado el acceso a una carpeta vigilada. Abre Escriba Tauri para revisar los permisos."
            } else {
                "No se puede leer una carpeta vigilada. Abre Escriba Tauri para revisar el problema."
            };
            let _ = notify(app, state, "No se pueden incorporar nuevos audios", message);
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
        let result = state.store()?.import(&path, None);
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
fn notify(
    app: &tauri::AppHandle,
    state: &Runtime,
    title: &str,
    message: &str,
) -> Result<(), String> {
    use tauri_plugin_notification::NotificationExt;
    app.notification()
        .builder()
        .title(title)
        .body(message.chars().take(240).collect::<String>())
        .show()
        .map_err(|e| {
            let message = format!("No se pudo mostrar la notificación: {e}");
            log_error(state, &message);
            message
        })
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
) -> Result<Value, String> {
    let weak = Arc::downgrade(state);
    let handle = app.clone();
    let capability: scripts::Capability = Arc::new(move |method, params, _task, lease| {
        let weak = weak.clone();
        let handle = handle.clone();
        Box::pin(async move {
            let state = weak.upgrade().ok_or("La aplicación se cerró")?;
            lease.ensure_active()?;
            let result = dispatch(&handle, &state, &method, params)
                .await
                .and_then(voices::public_reply);
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
                    if job["args"]["options"]["dryRun"] != true {
                        match &result {
                            Ok(_) if job["operation"] == "processRecording" => {
                                let setting = state
                                    .store()
                                    .map(|s| s.data["settings"]["notifyEveryNote"] != false)
                                    .unwrap_or(false);
                                if setting {
                                    let _ = notify(
                                        &app,
                                        &state,
                                        "Nota transcrita",
                                        "La grabación está lista en la biblioteca.",
                                    );
                                }
                            }
                            Err(error) if job["attempt"] == 1 && error != "Proceso cancelado" => {
                                let _ = notify(&app, &state, "Escriba necesita atención", error);
                            }
                            _ => {}
                        }
                    }
                    if let Err(error) = state.jobs.finish(id, result) {
                        log_error(&state, &error);
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
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel::<()>();
        let mut watching: Option<(String, notify::RecommendedWatcher)> = None;
        loop {
            let path = state.store().ok().and_then(|store| {
                store.data["settings"]["projectPath"]
                    .as_str()
                    .map(str::to_owned)
            });
            if watching.as_ref().map(|(current, _)| current) != path.as_ref() {
                watching = match path {
                    Some(path) => match project_watch::watch(&path, sender.clone()) {
                        Ok(watcher) => Some((path, watcher)),
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
                Some(()) = receiver.recv() => {
                    tokio::time::sleep(Duration::from_millis(800)).await;
                    while receiver.try_recv().is_ok() {}
                    let _ = app.emit("escriba://project", json!({"phase": "building"}));
                    let result = script_call(&app, &state, &store::id(), "rebuildProject", json!({})).await;
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
        let mut previous = Value::Null;
        let mut watcher = None;
        loop {
            match scan(&app, &state).await {
                Ok(items) if items.as_array().is_some_and(|v| !v.is_empty()) => {
                    let _ = app.emit("escriba://imported", items);
                    let _ = app.emit("escriba://changed", ());
                }
                Err(error) => log_error(&state, &error),
                _ => {}
            }
            let current = state
                .store()
                .map(|s| s.data["settings"]["watchedFolders"].clone());
            match current {
                Ok(current) if current != previous => {
                    match folders(&state).and_then(|f| watcher::watch(&f, state.watch_wake.clone()))
                    {
                        Ok(next) => {
                            for error in &next.errors {
                                log_error(&state, &error.message);
                            }
                            watcher = Some(next);
                            previous = current;
                        }
                        Err(error) => log_error(&state, &error),
                    }
                }
                Err(error) => log_error(&state, &error),
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
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .macos_launcher(tauri_plugin_autostart::MacosLauncher::LaunchAgent)
                .build(),
        )
        .setup(|app| {
            let isolated_root = std::env::var_os("ESCRIBA_TAURI_DATA").map(PathBuf::from);
            let root = isolated_root.clone().unwrap_or(app.path().app_data_dir()?);
            let store = Store::open(root.clone()).map_err(std::io::Error::other)?;
            let legacy = if isolated_root.is_none()
                && store.data["settings"]["legacyImported"] != true
                && store.data["recordings"]
                    .as_array()
                    .is_some_and(Vec::is_empty)
            {
                Some(
                    app.path()
                        .home_dir()?
                        .join("Library/Application Support/escriba/library"),
                )
            } else {
                None
            };
            let opening = legacy.as_ref().map(|_| {
                let mut snapshot = store.snapshot();
                snapshot["settings"]["startupMigration"] = json!({"state":"importing"});
                snapshot
            });
            let legacy_preferences = if isolated_root.is_none() {
                Some(
                    app.path()
                        .home_dir()?
                        .join("Library/Preferences/dev.ruben.escriba.plist"),
                )
            } else {
                None
            };
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
            let jobs = Arc::new(jobs::Queue::new(store.clone()).map_err(std::io::Error::other)?);
            let (watch_wake, wake) = tokio::sync::mpsc::channel(1);
            let state = Arc::new(Runtime {
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
                compiler: native::binary("escriba-esbuild").map_err(std::io::Error::other)?,
                startup: Mutex::new(Startup {
                    snapshot: opening,
                    error: None,
                }),
            });
            app.manage(state.clone());
            menubar::install(app.handle(), &state)?;
            app.on_menu_event(|app, event| menubar::handle(app, event.id().as_ref()));
            menubar::watch(app.handle().clone());
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                if legacy.is_some() || legacy_preferences.is_some() {
                    let importing = state.clone();
                    let result = tokio::task::spawn_blocking(move || {
                        let mut store = importing.store()?;
                        if let Some(source) = legacy {
                            store.import_startup_legacy(&source)?;
                        }
                        if let Some(preferences) = legacy_preferences {
                            store.adopt_legacy_watched_folders(&preferences)?;
                        }
                        Ok::<(), String>(())
                    })
                    .await
                    .map_err(|error| error.to_string())
                    .and_then(|result| result);
                    match state.startup.lock() {
                        Ok(mut startup) => {
                            startup.snapshot = None;
                            startup.error = result.err();
                        }
                        Err(error) => {
                            eprintln!("No se pudo finalizar la apertura de la biblioteca: {error}")
                        }
                    }
                    let _ = handle.emit("escriba://changed", ());
                }
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
                start_jobs(handle.clone(), state.clone());
                start_project_watcher(handle.clone(), state.clone());
                start_watcher(handle, state, wake);
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![app_command])
        .build(tauri::generate_context!())
        .expect("No se pudo iniciar Escriba Tauri")
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
        let refresh_cycle = ["snapshot", "recording_status", "runtime_jobs"];
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
        assert!(refreshes_library("library_import", &json!({})));
        assert!(refreshes_library(
            "runtime_run",
            &json!({"operation":"rebuildProject"})
        ));
    }
}
