#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]

mod appearance;
mod audio_ingress;
mod capabilities;
mod command;
mod error;
#[cfg(target_os = "macos")]
mod folder_access;
#[cfg(target_os = "linux")]
#[path = "folder_access_linux.rs"]
mod folder_access;
mod inbox;
mod knowledge;
#[cfg(test)]
mod knowledge_base_integration_tests;
mod knowledge_commands;
#[cfg(test)]
mod knowledge_integration_tests;
mod login;
mod menubar;
mod native;
mod notification_delivery;
mod notifications;
mod platform;
mod process_probe;
mod project;
mod project_watch;
mod recorder;
mod recording;
mod scripts;
mod storage;
mod symbols;
#[cfg(not(target_os = "macos"))]
mod tray_icons;
mod util;
mod voice_registration;
mod voices;
mod watcher;

use command::{AppCommand, Command, Request, Untyped};
use notifications::Problem;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{atomic::AtomicBool, Arc, Mutex},
    time::{Duration, SystemTime},
};
use tauri::{Emitter, Manager};
use util::text;

struct Runtime {
    knowledge: tokio::sync::OnceCell<knowledge::Knowledge>,
    knowledge_wake: tokio::sync::Notify,
    knowledge_path: PathBuf,
    app: tauri::AppHandle,
    facts: Mutex<Facts>,
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
    library_root: PathBuf,
    project_runtime: PathBuf,
    project_lock: tokio::sync::Mutex<()>,
}

struct FolderAccess {
    bookmark: Vec<u8>,
    resolved: folder_access::ResolvedFolder,
}

#[derive(Default, Deserialize)]
struct Facts {
    recordings: usize,
    jobs: Vec<Value>,
    settings: Value,
}

#[derive(Clone, Deserialize, PartialEq)]
struct WatchedFolder {
    id: String,
    path: PathBuf,
    enabled: Option<bool>,
    style: Option<String>,
}

#[derive(Deserialize)]
struct WatchFolders {
    folders: Vec<WatchedFolder>,
    bookmarks: Vec<(String, PathBuf, Vec<u8>)>,
}

impl Runtime {
    async fn controller(
        self: &Arc<Self>,
        method: &str,
        params: Value,
    ) -> Result<Value, error::AppError> {
        controller_command(&self.app, self, method, params, scripts::Origin::Shell).await
    }

    fn setting(&self, key: &str) -> Result<Value, String> {
        self.facts
            .lock()
            .map(|facts| facts.settings[key].clone())
            .map_err(|_| "No se pudo leer la configuración".into())
    }

    fn decorate(&self, mut snapshot: Value) -> Result<Value, String> {
        snapshot["watchIssues"] = self
            .watch_health
            .lock()
            .map_err(|_| "No se pudo consultar el acceso a las carpetas")?
            .snapshot();
        snapshot["platform"] = platform::summary();
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
    if command::forwarded(&method) {
        let reply = controller_command(&app, &runtime, &method, params, scripts::Origin::Ui)
            .await
            .map_err(|error| error.message)?;
        let reply = if matches!(method.as_str(), "library" | "snapshot") {
            runtime.decorate(reply)?
        } else {
            reply
        };
        return voices::public_reply(reply);
    }
    let request = Request::parse_ui(&method, params)?;
    let refresh = request.refreshes();
    let result = dispatch(&app, &runtime, request)
        .await
        .and_then(voices::public_reply);
    if result.is_ok() && refresh {
        let _ = app.emit("escriba://changed", ());
        state.knowledge_wake.notify_one();
    }
    result
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
    if !platform::is_models_root(&root) {
        return Err("La carpeta de modelos no es la de Escriba".into());
    }
    Ok(root)
}

async fn whisper_model(state: &Arc<Runtime>, p: &Value) -> Result<Value, String> {
    let default = state.setting("whisperModel")?;
    let model = p
        .get("model")
        .filter(|model| model.is_string())
        .cloned()
        .unwrap_or(default.clone());
    let status = state
        .inference
        .call("status", json!({"model": model}))
        .await?;
    let name = status["whisper"]["model"].clone();
    match text(p, "action")? {
        "info" => {
            let bytes = match state.inference.call("models", json!({})).await {
                Ok(catalog) => catalog["models"]
                    .as_array()
                    .and_then(|models| models.iter().find(|entry| entry["model"] == name))
                    .filter(|entry| entry["installed"] == true)
                    .and_then(|entry| entry["bytes"].as_u64())
                    .unwrap_or(0),
                Err(error)
                    if native::unsupported(&error) && status["whisper"]["available"] == true =>
                {
                    let root = models_root(&status)?;
                    tokio::task::spawn_blocking(move || directory_size(&root))
                        .await
                        .map_err(|e| e.to_string())?
                }
                Err(error) if native::unsupported(&error) => 0,
                Err(error) => return Err(error.message),
            };
            Ok(json!({"model": name, "available": status["whisper"]["available"], "bytes": bytes}))
        }
        "delete" => {
            state.inference.unload_if_idle(Duration::ZERO);
            match state
                .inference
                .call("deleteModel", json!({"model": model}))
                .await
            {
                Ok(_) => Ok(Value::Null),
                Err(error) if native::unsupported(&error) && model == default => {
                    let root = models_root(&status)?;
                    if root.exists() {
                        tokio::fs::remove_dir_all(&root)
                            .await
                            .map_err(|e| format!("No se pudo borrar el modelo: {e}"))?;
                    }
                    Ok(Value::Null)
                }
                Err(error) => Err(error.message),
            }
        }
        _ => Err("Acción desconocida".into()),
    }
}

fn dispatch<'a>(
    app: &'a tauri::AppHandle,
    state: &'a Arc<Runtime>,
    request: Request,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value, String>> + Send + 'a>> {
    Box::pin(async move {
        let Request { method, command } = request;
        match command {
            Command::Knowledge(command) => knowledge_commands::run(
                &state.knowledge,
                &state.knowledge_path,
                &library_port(state),
                command,
            )
            .await?
            .into_value(&method),
            Command::App(command) => dispatch_app(app, state, &method, command).await,
        }
    })
}

async fn dispatch_app(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
    method: &str,
    command: AppCommand,
) -> Result<Value, String> {
    {
        match command {
            AppCommand::RecordingStatus(Untyped(_)) => Ok(recorder::view(state)),
            AppCommand::RecordingDismiss(Untyped(_)) => {
                recorder::dismiss(app, state);
                Ok(recorder::view(state))
            }
            AppCommand::RecordingCancel(Untyped(_)) => recorder::cancel(app, state).await,
            AppCommand::VoiceRegistrationStatus(Untyped(_)) => state.voice_registration.view(),
            AppCommand::VoiceRegistrationCancel(Untyped(_))
            | AppCommand::VoiceRegistrationDismiss(Untyped(_)) => {
                let view = if method == "voice_registration_cancel" {
                    state.voice_registration.cancel()?
                } else {
                    state.voice_registration.dismiss()?
                };
                let _ = app.emit("escriba://voice-registration", &view);
                Ok(view)
            }
            AppCommand::VoiceRegistrationStart(Untyped(p)) => {
                state
                    .voice_registration
                    .start(text(&p, "name")?, |view| {
                        let _ = app.emit("escriba://voice-registration", view);
                    })
                    .await
            }
            AppCommand::VoiceRegistrationImport(Untyped(p)) => {
                let view = state
                    .voice_registration
                    .import_audio(
                        text(&p, "name")?,
                        Path::new(text(&p, "path")?),
                        &state.inference,
                        &voice_sink(state),
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
            AppCommand::VoiceRegistrationStop(Untyped(_)) => {
                let view = state
                    .voice_registration
                    .stop(&state.inference, &voice_sink(state), |view| {
                        let _ = app.emit("escriba://voice-registration", view);
                    })
                    .await?;
                let _ = app.emit("escriba://changed", ());
                Ok(view)
            }
            AppCommand::ImportAudio(Untyped(p)) => {
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
                let mut imported = Vec::new();
                for path in paths {
                    let root = state.library_root.clone();
                    let source = path.clone();
                    let inbox = tokio::task::spawn_blocking(move || inbox::receive(&root, &source))
                        .await
                        .map_err(|e| e.to_string())??;
                    let result = state
                        .controller(
                            "import_inbox",
                            json!({
                                "files": [{"inbox": inbox, "source": path}], "recipeId": recipe
                            }),
                        )
                        .await;
                    if result.is_err() {
                        let _ = fs::remove_file(&inbox);
                    }
                    let records = result.map_err(|error| error.message)?;
                    imported.extend(
                        records
                            .as_array()
                            .ok_or("Importación inválida")?
                            .iter()
                            .cloned(),
                    );
                }
                Ok(json!(imported))
            }
            AppCommand::Native(Untyped(p)) => {
                let method = text(&p, "method")?;
                if !["status", "downloadModel", "models"].contains(&method) {
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
            AppCommand::RecordingStart(Untyped(p)) => {
                recorder::start(app, state, p["recipeId"].as_str().map(str::to_owned)).await
            }
            AppCommand::RecordingStop(Untyped(_)) => recorder::stop(app, state).await,
            AppCommand::ProjectInit(Untyped(p)) => {
                let _project_guard = state.project_lock.lock().await;
                let path = PathBuf::from(text(&p, "path")?);
                let context = state.controller("project_context", json!({})).await?;
                let has_dist = project::initialize(
                    &path,
                    &context["accounts"],
                    &state.vendor,
                    &state.project_runtime,
                )?;
                state
                    .controller("settings_save", json!({"settings":{"projectPath":path}}))
                    .await?;
                Ok(json!({"hasDist":has_dist}))
            }
            AppCommand::ProjectList(Untyped(_)) => project::list(&project_path(state)?),
            AppCommand::ProjectOpenVscode(Untyped(_)) => {
                let path = project_path(state)?
                    .canonicalize()
                    .map_err(|_| "La carpeta del proyecto no existe o no se puede abrir")?;
                if !path.is_dir() {
                    return Err("La ruta del proyecto no es una carpeta".into());
                }
                let status = platform::open_vscode(&path)
                    .status()
                    .map_err(|e| format!("No se pudo abrir VS Code: {e}"))?;
                if !status.success() {
                    return Err("No se pudo abrir VS Code. Comprueba que esté instalado".into());
                }
                Ok(Value::Null)
            }
            AppCommand::ProjectTool(Untyped(p)) => {
                let _project_guard = state.project_lock.lock().await;
                let path = project_path(state)?;
                let runtime = state.project_runtime.clone();
                let vendor = state.vendor.clone();
                let tool = text(&p, "tool")?.to_owned();
                tokio::task::spawn_blocking(move || project::tool(&path, &runtime, &vendor, &tool))
                    .await
                    .map_err(|e| e.to_string())?
            }
            AppCommand::ProjectRead(Untyped(p)) => {
                project::read(&project_path(state)?, text(&p, "entry")?)
            }
            AppCommand::ProjectWrite(Untyped(p)) => {
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
            AppCommand::ExportFile(Untyped(p)) => {
                let path = PathBuf::from(text(&p, "path")?);
                util::atomic_write(&path, text(&p, "contents")?.as_bytes())?;
                Ok(Value::Null)
            }
            AppCommand::Reveal(Untyped(p)) => {
                let path = PathBuf::from(text(&p, "path")?);
                if !path.exists() {
                    return Err("El archivo no existe".into());
                }
                let status = platform::reveal(&path)
                    .status()
                    .map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err(platform::REVEAL_FAILED.into());
                }
                Ok(Value::Null)
            }
            AppCommand::OpenUrl(Untyped(p)) => {
                let url = tauri::Url::parse(text(&p, "url")?).map_err(|_| "Enlace inválido")?;
                if !["http", "https"].contains(&url.scheme()) {
                    return Err("Solo se pueden abrir enlaces web".into());
                }
                let status = platform::open(std::ffi::OsStr::new(url.as_str()))
                    .status()
                    .map_err(|e| e.to_string())?;
                if !status.success() {
                    return Err("No se pudo abrir el enlace".into());
                }
                Ok(Value::Null)
            }
            AppCommand::SystemAppearance(Untyped(_)) => Ok(json!({"accent": appearance::accent()})),
            AppCommand::WhisperModel(Untyped(p)) => whisper_model(state, &p).await,
            AppCommand::OpenPrivacySettings(Untyped(p)) => {
                let status = platform::privacy_settings(p["pane"].as_str())?
                    .status()
                    .map_err(|e| format!("No se pudieron abrir los ajustes: {e}"))?;
                if !status.success() {
                    return Err("No se pudieron abrir los Ajustes del Sistema".into());
                }
                Ok(Value::Null)
            }
            AppCommand::WatchScan(Untyped(_)) => scan(app, state).await,
            AppCommand::WatchFolderAuthorize(Untyped(p)) => {
                authorize_watched_folder(app, state, &p).await
            }
        }
    }
}
fn project_path(state: &Runtime) -> Result<PathBuf, String> {
    state
        .setting("projectPath")?
        .as_str()
        .map(PathBuf::from)
        .ok_or_else(|| "Elige la carpeta del proyecto en Recetas".into())
}

fn library_port(state: &Arc<Runtime>) -> knowledge_commands::LibraryPort {
    let weak = Arc::downgrade(state);
    knowledge_commands::LibraryPort::new(Arc::new(move |method, params| {
        let weak = weak.clone();
        Box::pin(async move {
            let state = weak.upgrade().ok_or("La aplicación se cerró")?;
            state
                .controller(method, params)
                .await
                .map_err(|error| error.message)
        })
    }))
}

fn audio_port(state: &Arc<Runtime>) -> audio_ingress::ControllerPort {
    let weak = Arc::downgrade(state);
    Arc::new(move |method, params| {
        let weak = weak.clone();
        Box::pin(async move {
            let state = weak.upgrade().ok_or("La aplicación se cerró")?;
            state
                .controller(&method, params)
                .await
                .map_err(|error| error.message)
        })
    })
}

fn voice_sink(state: &Arc<Runtime>) -> voice_registration::VoiceSink {
    let weak = Arc::downgrade(state);
    Arc::new(move |name, voice, source| {
        let weak = weak.clone();
        Box::pin(async move {
            let state = weak.upgrade().ok_or("La aplicación se cerró")?;
            state
                .controller(
                    "people_add_voice",
                    json!({"name":name,"voice":voice,"source":source}),
                )
                .await
                .map(|_| ())
                .map_err(|error| error.message)
        })
    })
}

async fn watch_folders(state: &Arc<Runtime>) -> Result<WatchFolders, String> {
    serde_json::from_value(state.controller("watch_folders", json!({})).await?)
        .map_err(|error| format!("Carpetas inválidas: {error}"))
}

async fn authorize_watched_folder(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
    params: &Value,
) -> Result<Value, String> {
    let folder_id = params["folderId"].as_str();
    let voice_memos = folder_id.is_none() && params["style"] == "voiceMemos";
    let initial_path = match folder_id {
        None if voice_memos => Some(voice_memos_root(app)?),
        Some(id) => Some(
            watch_folders(state)
                .await?
                .folders
                .into_iter()
                .find(|folder| folder.id == id)
                .ok_or("La carpeta ya no está configurada")?
                .path,
        ),
        None => None,
    };
    #[cfg(target_os = "macos")]
    let selected = {
        let (reply, receive) = tokio::sync::oneshot::channel();
        app.run_on_main_thread(move || {
            let _ = reply.send(folder_access::select_folder(initial_path.as_deref()));
        })
        .map_err(|error| format!("No se pudo abrir el selector de carpetas: {error}"))?;
        receive
            .await
            .map_err(|_| "El selector de carpetas se cerró inesperadamente")??
    };
    #[cfg(target_os = "linux")]
    let selected = folder_access::select_folder(app, initial_path.as_deref()).await?;
    let Some(selected) = selected else {
        return Ok(Value::Null);
    };
    let _scan = state.scan_lock.lock().await;
    let resolved = restore_folder(&selected.path, &selected.bookmark)?;
    if resolved.path != selected.path {
        return Err("La carpeta cambió mientras se autorizaba. Vuelve a seleccionarla".into());
    }
    let bookmark = resolved
        .refreshed_bookmark
        .clone()
        .unwrap_or(selected.bookmark);
    let saved = state
        .controller(
            "watch_folder_save",
            json!({
                "folderId":folder_id,"path":resolved.path,
                "name":params["name"].as_str().or(voice_memos.then_some("Notas de Voz")),
                "style":params["style"].as_str().unwrap_or("any"),"bookmark":bookmark
            }),
        )
        .await?;
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

fn surreal_native(app: &tauri::AppHandle) -> Option<PathBuf> {
    let (_, file) = platform::surreal_native();
    let resource = app
        .path()
        .resource_dir()
        .ok()
        .map(|dir| dir.join("surreal").join(&file));
    let development = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("surreal")
        .join(&file);
    resource
        .into_iter()
        .chain(std::iter::once(development))
        .find(|path| path.is_file())
}

#[cfg(target_os = "macos")]
fn voice_memos_root(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .home_dir()
        .map_err(|e| e.to_string())?
        .join("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"))
}

// Voice Memos and its iCloud folder only exist on macOS.
#[cfg(not(target_os = "macos"))]
fn voice_memos_root(_: &tauri::AppHandle) -> Result<PathBuf, String> {
    Err("Notas de Voz solo existe en macOS".into())
}

#[cfg(target_os = "macos")]
fn restore_folder(_: &Path, bookmark: &[u8]) -> Result<folder_access::ResolvedFolder, String> {
    folder_access::restore(bookmark)
}

#[cfg(target_os = "linux")]
fn restore_folder(path: &Path, _: &[u8]) -> Result<folder_access::ResolvedFolder, String> {
    folder_access::restore(path)
}

async fn restore_watched_folders(
    state: &Arc<Runtime>,
) -> Result<Vec<watcher::FolderError>, String> {
    let bookmarks = watch_folders(state).await?.bookmarks;
    let known: Vec<String> = {
        let mut accesses = state
            .folder_accesses
            .lock()
            .map_err(|_| "No se pudo mantener el acceso a las carpetas")?;
        accesses.retain(|id, access| {
            bookmarks.iter().any(|(folder_id, path, bookmark)| {
                folder_id == id && bookmark == &access.bookmark && path == &access.resolved.path
            })
        });
        accesses.keys().cloned().collect()
    };
    let mut issues = Vec::new();
    for (id, path, bookmark) in bookmarks {
        if known.contains(&id) {
            continue;
        }
        match restore_folder(&path, &bookmark) {
            Ok(resolved) => {
                if state
                    .controller(
                        "watch_folder_refresh",
                        json!({
                            "folderId":id,"previous":bookmark,"resolved":resolved.path,
                            "replacement":resolved.refreshed_bookmark
                        }),
                    )
                    .await?
                    == true
                {
                    let bookmark = resolved.refreshed_bookmark.clone().unwrap_or(bookmark);
                    state
                        .folder_accesses
                        .lock()
                        .map_err(|_| "No se pudo mantener el acceso a las carpetas")?
                        .insert(id, FolderAccess { bookmark, resolved });
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

fn folders(configured: &[WatchedFolder]) -> Result<Vec<watcher::Folder>, String> {
    configured
        .iter()
        .map(|folder| {
            Ok(watcher::Folder {
                id: folder.id.clone(),
                path: folder.path.clone(),
                enabled: folder.enabled != Some(false),
                style: watcher::Style::parse(folder.style.as_deref())?,
            })
        })
        .collect()
}

fn log_error(state: &Arc<Runtime>, message: &str) {
    let state = state.clone();
    let message = message.to_owned();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = state
            .controller("log", json!({"level":"error","message":message}))
            .await
        {
            eprintln!("{message}; no se pudo guardar el error: {error}");
        }
    });
}

async fn scan(app: &tauri::AppHandle, state: &Arc<Runtime>) -> Result<Value, String> {
    let _scan = state.scan_lock.lock().await;
    let mut issues = restore_watched_folders(state).await?;
    let watched = folders(&watch_folders(state).await?.folders)?;
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
                let record = state.controller("recording_abandoned", json!({"path":candidate.path,"source":candidate.folder_id,"sourceKey":candidate.source_key,"title":candidate.title,"modifiedAt":chrono::DateTime::<chrono::Utc>::from(candidate.started_at).to_rfc3339()})).await?;
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
        match audio_ingress::watched(&state.library_root, &candidate, &audio_port(state)).await {
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
    Ok(json!(added))
}
async fn recover_captures(state: &Arc<Runtime>) -> Result<(), String> {
    let _recording = state.recording_lock.lock().await;
    if recorder::is_recording(state) {
        return Ok(());
    }
    let root = state.library_root.join("captures");
    let captures = fs::read_dir(root).map_err(|e| e.to_string())?;
    let mut pending = false;
    for capture in captures {
        let capture = capture.map_err(|e| e.to_string())?;
        if capture.path().extension().is_some_and(|ext| ext == "m4a") {
            pending = true;
            break;
        }
    }
    if !pending {
        return Ok(());
    }
    let status = state.recorder.call("recordingStatus", json!({})).await?;
    if status["active"] != true {
        state.controller("captures_recover", json!({})).await?;
    }
    Ok(())
}

fn notify(state: &Arc<Runtime>, notice: notifications::Notification) {
    if let Err(error) = notification_delivery::send(&notice) {
        log_error(state, &error);
    }
}
fn notify_problem(state: &Arc<Runtime>, problem: Problem<'_>) {
    notify(state, notifications::notification(problem));
}

const RELAYED_EVENTS: &[&str] = &[
    "changed",
    "log",
    "imported",
    "project",
    "voice-registration",
    "whisper-download",
    "jobs",
];

fn controller_hooks(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
) -> (scripts::Capability, scripts::Events) {
    let weak = Arc::downgrade(state);
    let handle = app.clone();
    let capability: scripts::Capability = Arc::new(move |method, params| {
        let weak = weak.clone();
        let handle = handle.clone();
        Box::pin(async move {
            let state = weak.upgrade().ok_or("La aplicación se cerró")?;
            if let Some(method) = method.strip_prefix("shell.") {
                return shell_capability(&handle, &state, method, params).await;
            }
            if matches!(
                method.as_str(),
                "knowledge_open" | "knowledge_query" | "knowledge_link"
            ) {
                let request = Request::parse(&method, params)?;
                let refresh = request.refreshes();
                let result = dispatch(&handle, &state, request).await;
                if result.is_ok() && refresh {
                    let _ = handle.emit("escriba://changed", ());
                }
                return result.map_err(Into::into);
            }
            Err(format!("Capacidad no autorizada: {method}").into())
        })
    });
    let weak = Arc::downgrade(state);
    let handle = app.clone();
    let events: scripts::Events = Arc::new(move |event| {
        let Some(state) = weak.upgrade() else {
            return;
        };
        let name = event["event"].as_str().unwrap_or("");
        if name == "status" {
            match serde_json::from_value::<Facts>(event["value"].clone()) {
                Ok(facts) => {
                    match state.facts.lock() {
                        Ok(mut current) => {
                            if current.settings["watchedFolders"]
                                != facts.settings["watchedFolders"]
                            {
                                let _ = state.watch_wake.try_send(());
                            }
                            *current = facts;
                        }
                        Err(_) => {
                            log_error(&state, "No se pudo actualizar el estado del controlador")
                        }
                    }
                    menubar::refresh(&handle);
                }
                Err(error) => {
                    log_error(&state, &format!("Estado del controlador inválido: {error}"))
                }
            }
        } else if RELAYED_EVENTS.contains(&name) {
            if name == "jobs" {
                if let (Ok(mut facts), Some(jobs)) = (state.facts.lock(), event["value"].as_array())
                {
                    facts.jobs = jobs.clone();
                }
                menubar::refresh(&handle);
            }
            let _ = handle.emit(&format!("escriba://{name}"), event["value"].clone());
            if name == "changed" {
                state.knowledge_wake.notify_one();
            }
        }
    });
    (capability, events)
}

async fn shell_capability(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
    method: &str,
    params: Value,
) -> Result<Value, error::AppError> {
    match method {
        "native" => {
            let native = text(&params, "method")?;
            let args = params.get("params").cloned().unwrap_or(json!({}));
            if native == "transcribe" {
                let audio = PathBuf::from(text(&args, "audioPath")?);
                return state
                    .inference
                    .transcribe(&audio, args["model"].clone(), args)
                    .await;
            }
            if !["status", "summarize", "ask"].contains(&native) {
                return Err(format!("Capacidad nativa no permitida: {native}").into());
            }
            state.inference.call(native, args).await
        }
        "native_cancel" => {
            state.inference.cancel();
            Ok(Value::Null)
        }
        "notify" => {
            notification_delivery::send(&notifications::Notification {
                title: text(&params, "title")?.to_owned(),
                body: text(&params, "body")?.to_owned(),
                sound: params["sound"].as_bool().ok_or("Sonido inválido")?,
            })?;
            Ok(Value::Null)
        }
        "autolaunch" => {
            use tauri_plugin_autostart::ManagerExt;
            let auto = app.autolaunch();
            if params["enabled"]
                .as_bool()
                .ok_or("Inicio automático inválido")?
            {
                auto.enable()
            } else {
                auto.disable()
            }
            .map_err(|e| format!("No se pudo cambiar el inicio automático: {e}"))?;
            Ok(Value::Null)
        }
        "files" => tokio::task::spawn_blocking(move || {
            capabilities::files(&params["account"], &params["request"])
        })
        .await
        .map_err(|e| e.to_string())?
        .map_err(Into::into),
        "okf_file" => {
            let path = capabilities::authorized_okf_file(
                &params["account"],
                Path::new(text(&params, "path")?),
            )?;
            let mut command = match text(&params, "action")? {
                "open" => platform::open(path.as_os_str()),
                "reveal" => platform::reveal(&path),
                _ => return Err("Acción de archivo OKF desconocida".into()),
            };
            if !command.status().map_err(|e| e.to_string())?.success() {
                return Err("No se pudo abrir el documento OKF".into());
            }
            Ok(Value::Null)
        }
        "validate_catalog" => {
            let ontologies: Vec<knowledge::Ontology> =
                serde_json::from_value(params["ontologies"].clone())
                    .map_err(|error| format!("Ontologías inválidas: {error}"))?;
            knowledge::validate_catalog(&ontologies)?;
            Ok(Value::Null)
        }
        "project_build" | "project_load" => {
            let _guard = state.project_lock.lock().await;
            let path = project_path(state)?;
            let runtime = state.project_runtime.clone();
            let vendor = state.vendor.clone();
            let build = method == "project_build";
            tokio::task::spawn_blocking(move || {
                if build {
                    project::build(&path, &runtime, &vendor)
                } else {
                    project::load_with_tools(&path, &runtime, &vendor)
                }
            })
            .await
            .map_err(|e| e.to_string())?
            .map_err(Into::into)
        }
        _ => Err(format!("Capacidad de la cáscara desconocida: {method}").into()),
    }
}

async fn controller_command(
    app: &tauri::AppHandle,
    state: &Arc<Runtime>,
    method: &str,
    params: Value,
    origin: scripts::Origin,
) -> Result<Value, error::AppError> {
    let (capability, events) = controller_hooks(app, state);
    state
        .scripts
        .command(method, params, origin, capability, events)
        .await
}

fn start_idle_unloader(state: Arc<Runtime>) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            state.inference.unload_if_idle(Duration::from_secs(300));
        }
    });
}

fn start_knowledge_sync(state: Arc<Runtime>) {
    tauri::async_runtime::spawn(async move {
        loop {
            let available = state.knowledge.get().is_some()
                || state.knowledge_path.try_exists().unwrap_or(false);
            let step = if available {
                match state
                    .knowledge
                    .get_or_try_init(|| knowledge::Knowledge::open(&state.knowledge_path))
                    .await
                {
                    Ok(knowledge) => {
                        knowledge_commands::sync_step(knowledge, &library_port(&state)).await
                    }
                    Err(error) => Err(error),
                }
            } else {
                Ok(true)
            };
            match step {
                Ok(false) => tokio::time::sleep(Duration::from_millis(50)).await,
                Ok(true) => {
                    tokio::select! { _ = state.knowledge_wake.notified() => {}, _ = tokio::time::sleep(Duration::from_secs(30)) => {} }
                }
                Err(error) => {
                    log_error(
                        &state,
                        &format!("No se pudo sincronizar la base de conocimiento: {error}"),
                    );
                    tokio::time::sleep(Duration::from_secs(30)).await;
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
            let path = match state.setting("projectPath") {
                Ok(value) => value.as_str().map(str::to_owned),
                Err(error) => {
                    log_error(&state, &error);
                    None
                }
            };
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
                    let result = controller_command(&app, &state, "runtime_run", json!({"operation":"rebuildProject","args":{"loadOnly":action == project_watch::Change::Load}}), scripts::Origin::Ui).await;
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
        let mut previous: Option<Vec<WatchedFolder>> = None;
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
            let current = match watch_folders(&state).await {
                Ok(configured) => Some(configured.folders),
                Err(error) => {
                    log_error(&state, &error);
                    None
                }
            };
            if current.is_some() && current != previous {
                match folders(current.as_deref().unwrap_or_default())
                    .and_then(|f| watcher::watch(&f, state.watch_wake.clone()))
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
        .plugin({
            let autostart = tauri_plugin_autostart::Builder::new().app_name("Escriba");
            #[cfg(target_os = "macos")]
            let autostart =
                autostart.macos_launcher(tauri_plugin_autostart::MacosLauncher::LaunchAgent);
            autostart.build()
        })
        .setup(|app| {
            if let Err(error) = notification_delivery::request_authorization() {
                eprintln!("{error}");
            }
            let result: Result<(), Box<dyn std::error::Error>> = (|| {
                let isolated_root = std::env::var_os("ESCRIBA_TAURI_DATA").map(PathBuf::from);
                let root = isolated_root.clone().unwrap_or(app.path().app_data_dir()?);

                app.asset_protocol_scope()
                    .allow_directory(root.join("audio"), true)?;
                let resource_vendor = app.path().resource_dir()?.join("vendor");
                let vendor = if resource_vendor.is_dir() {
                    resource_vendor
                } else {
                    Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor")
                };
                let engine = native::binary("EscribaNativeHost").map_err(std::io::Error::other)?;
                let mut controller_env = vec![
                    (
                        "ESCRIBA_DATA".to_owned(),
                        root.to_string_lossy().into_owned(),
                    ),
                    (
                        "ESCRIBA_PLATFORM".to_owned(),
                        platform::summary().to_string(),
                    ),
                ];
                if let Some(native) = surreal_native(app.handle()) {
                    controller_env.push((
                        "NAPI_RS_NATIVE_LIBRARY_PATH".to_owned(),
                        native.to_string_lossy().into_owned(),
                    ));
                }
                let (watch_wake, wake) = tokio::sync::mpsc::channel(1);
                let state = Arc::new(Runtime {
                    knowledge: tokio::sync::OnceCell::new(),
                    knowledge_wake: tokio::sync::Notify::new(),
                    knowledge_path: root.join("knowledge.rocksdb"),
                    app: app.handle().clone(),
                    facts: Mutex::new(Facts::default()),
                    scripts: scripts::Scripts::new(
                        native::binary("escriba-runtime").map_err(std::io::Error::other)?,
                    )
                    .with_env(controller_env),
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
                    library_root: root.clone(),
                    project_runtime: native::binary("escriba-runtime")
                        .map_err(std::io::Error::other)?,
                    project_lock: tokio::sync::Mutex::new(()),
                });
                app.manage(state.clone());
                let (capability, events) = controller_hooks(app.handle(), &state);
                tauri::async_runtime::block_on(state.scripts.start(capability, events))
                    .map_err(std::io::Error::other)?;
                inbox::cleanup(&root).map_err(std::io::Error::other)?;
                let settings =
                    tauri::async_runtime::block_on(state.controller("settings_read", json!({})))
                        .map_err(std::io::Error::other)?;
                state
                    .facts
                    .lock()
                    .map_err(|_| std::io::Error::other("Estado ocupado"))?
                    .settings = settings.clone();
                if isolated_root.is_none() {
                    if let Err(error) =
                        login::synchronize(app.handle(), settings["launchAtLogin"] == true)
                    {
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
                    if isolated_root.is_none() {
                        if let Ok(root) = voice_memos_root(&handle) {
                            let seeded = state
                                .controller("watch_seed_voice_memos", json!({"root":root}))
                                .await;
                            match seeded {
                                Ok(value) if value == true => {
                                    let _ = handle.emit("escriba://changed", ());
                                }
                                Ok(_) => {}
                                Err(error) => log_error(&state, &error.message),
                            }
                        }
                    }
                    start_idle_unloader(state.clone());
                    start_knowledge_sync(state.clone());
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
            tauri::RunEvent::Exit => {
                if let Some(state) = app.try_state::<Arc<Runtime>>() {
                    tauri::async_runtime::block_on(state.scripts.shutdown());
                }
            }
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Reopen { .. } => {
                let _ = menubar::show(app, "library");
            }
            _ => {}
        });
}
