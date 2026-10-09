use crate::recording::{self, Problem, Session};
use crate::{menubar, store::text, Runtime};
use serde_json::{json, Value};
use std::{fs, path::PathBuf, sync::Arc, time::Duration};
use tauri::{
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder,
};

const PANEL: &str = "recording";
const CLOCK_TRAY: &str = "recording-clock";
const PANEL_WIDTH: f64 = 452.0;
const PANEL_HEIGHT: f64 = 54.0;
const PANEL_TOP: f64 = 12.0;

pub fn view(state: &Runtime) -> Value {
    let session = state.recording.lock().ok();
    let problem = state.recording_problem.lock().ok();
    recording::view(
        session.as_ref().and_then(|s| s.as_ref()),
        problem.as_ref().and_then(|p| p.as_ref()),
    )
}

pub fn is_recording(state: &Runtime) -> bool {
    state.recording.lock().map(|s| s.is_some()).unwrap_or(false)
}

pub async fn start(
    app: &AppHandle,
    state: &Arc<Runtime>,
    recipe_id: Option<String>,
) -> Result<Value, String> {
    let _serial = state.recording_lock.lock().await;
    if is_recording(state) {
        return Ok(view(state));
    }
    set_problem(state, None);
    let (path, recipe_name) = {
        let store = state.store()?;
        let name = recipe_id.as_deref().and_then(|id| {
            store.data["recipes"]
                .as_array()?
                .iter()
                .find(|recipe| recipe["id"] == id)
                .and_then(|recipe| recipe["name"].as_str())
                .map(str::to_owned)
        });
        let path = store
            .root
            .join("captures")
            .join(recording::recording_name(chrono::Local::now()));
        (path, name)
    };
    match state
        .recorder
        .call("recordingStart", json!({"outputPath":path}))
        .await
    {
        Ok(_) => {
            *state.recording.lock().map_err(|_| "Grabadora ocupada")? =
                Some(Session::new(path, recipe_id, recipe_name));
            opened(app, state);
            tick(app.clone(), state.clone());
        }
        Err(error) => {
            set_problem(state, Some(Problem::starting(&error)));
            changed(app, state);
        }
    }
    Ok(view(state))
}

pub async fn stop(app: &AppHandle, state: &Arc<Runtime>) -> Result<Value, String> {
    let _serial = state.recording_lock.lock().await;
    let Some(session) = take(state)? else {
        return Ok(Value::Null);
    };
    closed(app, state);
    let saved = save(state, &session).await;
    if let Err(error) = &saved {
        set_problem(state, Some(Problem::saving(error)));
    }
    changed(app, state);
    let _ = app.emit("escriba://changed", ());
    state.jobs.wake.notify_one();
    saved
}

pub async fn cancel(app: &AppHandle, state: &Arc<Runtime>) -> Result<Value, String> {
    let _serial = state.recording_lock.lock().await;
    let Some(session) = take(state)? else {
        return Ok(Value::Null);
    };
    closed(app, state);
    let cancelled = state.recorder.call("recordingCancel", json!({})).await;
    if session.path.exists() {
        fs::remove_file(&session.path)
            .map_err(|e| format!("No se pudo borrar la grabación descartada: {e}"))?;
    }
    changed(app, state);
    cancelled.map(|_| Value::Null)
}

pub fn dismiss(app: &AppHandle, state: &Runtime) {
    set_problem(state, None);
    changed(app, state);
}

async fn save(state: &Runtime, session: &Session) -> Result<Value, String> {
    let reply = state.recorder.call("recordingStop", json!({})).await?;
    let path = PathBuf::from(text(&reply, "audioPath")?);
    let updated = {
        let mut store = state.store()?;
        let record = store.import(&path, session.recipe_id.as_deref())?;
        store.mutate(
            "recording_update",
            &json!({"id":record["id"],"duration":reply["duration"],"createdAt":session.started_at.to_rfc3339()}),
        )?
    };
    fs::remove_file(&path)
        .map_err(|e| format!("Audio guardado; no se pudo retirar la captura temporal: {e}"))?;
    Ok(updated)
}

fn take(state: &Runtime) -> Result<Option<Session>, String> {
    Ok(state
        .recording
        .lock()
        .map_err(|_| "Grabadora ocupada")?
        .take())
}

fn set_problem(state: &Runtime, problem: Option<Problem>) {
    if let Ok(mut slot) = state.recording_problem.lock() {
        *slot = problem;
    }
}

fn tick(app: AppHandle, state: Arc<Runtime>) {
    tauri::async_runtime::spawn(async move {
        let mut shown = String::new();
        loop {
            tokio::time::sleep(Duration::from_millis(100)).await;
            if !is_recording(&state) {
                break;
            }
            let Ok(reply) = state.recorder.call("recordingStatus", json!({})).await else {
                continue;
            };
            let clock = {
                let Ok(mut slot) = state.recording.lock() else {
                    break;
                };
                let Some(session) = slot.as_mut() else { break };
                if reply["active"] != true {
                    drop(slot);
                    lost(&app, &state);
                    break;
                }
                session.sample(
                    reply["duration"].as_f64().unwrap_or(0.0),
                    reply["level"].as_f64().unwrap_or(0.0),
                );
                session.clock()
            };
            let _ = app.emit("escriba://recording", view(&state));
            if clock != shown {
                if let Some(tray) = app.tray_by_id(CLOCK_TRAY) {
                    let _ = tray.set_title(Some(format!(" {clock}")));
                }
                menubar::recording_clock(&app, &state, &clock);
                shown = clock;
            }
        }
    });
}

fn lost(app: &AppHandle, state: &Runtime) {
    if let Ok(mut slot) = state.recording.lock() {
        *slot = None;
    }
    set_problem(state, Some(Problem::saving("el micrófono dejó de grabar")));
    closed(app, state);
    changed(app, state);
}

fn changed(app: &AppHandle, state: &Runtime) {
    let _ = app.emit("escriba://recording", view(state));
    menubar::refresh(app, state);
}

fn opened(app: &AppHandle, state: &Runtime) {
    changed(app, state);
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        open_panel(&handle);
        open_clock(&handle);
    });
}

fn closed(app: &AppHandle, state: &Runtime) {
    changed(app, state);
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(panel) = handle.get_webview_window(PANEL) {
            let _ = panel.destroy();
        }
        let _ = handle.remove_tray_by_id(CLOCK_TRAY);
    });
}

fn open_panel(app: &AppHandle) {
    if app.get_webview_window(PANEL).is_some() {
        return;
    }
    let effects = tauri::utils::config::WindowEffectsConfig {
        effects: vec![tauri::window::Effect::LiquidGlassRegular],
        state: None,
        radius: Some(PANEL_HEIGHT / 2.0),
        color: None,
        interactive: false,
    };
    let built = WebviewWindowBuilder::new(
        app,
        PANEL,
        WebviewUrl::App("index.html?panel=recording".into()),
    )
    .title("Grabación")
    .inner_size(PANEL_WIDTH, PANEL_HEIGHT)
    .resizable(false)
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .visible_on_all_workspaces(true)
    .skip_taskbar(true)
    .focused(false)
    .focusable(false)
    .accept_first_mouse(true)
    .effects(effects)
    .visible(false)
    .build();
    let panel = match built {
        Ok(panel) => panel,
        Err(error) => {
            eprintln!("No se pudo abrir el panel de grabación: {error}");
            return;
        }
    };
    let monitor = app
        .cursor_position()
        .ok()
        .and_then(|point| app.monitor_from_point(point.x, point.y).ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let x = area.position.x as f64 + (area.size.width as f64 - PANEL_WIDTH * scale) / 2.0;
        let y = area.position.y as f64 + PANEL_TOP * scale;
        let _ = panel.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
    }
    let _ = panel.show();
}

fn open_clock(app: &AppHandle) {
    if app.tray_by_id(CLOCK_TRAY).is_some() {
        return;
    }
    let mut builder = TrayIconBuilder::with_id(CLOCK_TRAY)
        .title(" 00:00")
        .tooltip("Detener la grabación y transcribirla")
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle().clone();
                tauri::async_runtime::spawn(async move {
                    let state = app.state::<Arc<Runtime>>().inner().clone();
                    if let Err(error) = stop(&app, &state).await {
                        crate::log_error(&state, &error);
                    }
                });
            }
        });
    if let Some(icon) = crate::symbols::image("stop.circle.fill") {
        builder = builder.icon(icon).icon_as_template(true);
    }
    if let Err(error) = builder.build(app) {
        eprintln!("No se pudo mostrar el reloj de la grabación: {error}");
    }
}
