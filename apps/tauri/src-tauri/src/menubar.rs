use crate::{recorder, Runtime};
use serde_json::Value;
use std::sync::{atomic::Ordering, Arc};
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem, Submenu},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager, Wry,
};

pub const STATUS_TRAY: &str = "status";

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    Starting,
    Watching,
    Working(usize),
    Problem(String),
}

impl Status {
    pub fn label(&self) -> String {
        match self {
            Status::Starting => "Arrancando".into(),
            Status::Watching => "Vigilando".into(),
            Status::Working(pending) => format!("Transcribiendo ({pending} en cola)"),
            Status::Problem(detail) => format!("Problema: {detail}"),
        }
    }

    pub fn symbol(&self) -> &'static str {
        match self {
            Status::Starting | Status::Watching => "waveform",
            Status::Working(_) => "waveform.badge.mic",
            Status::Problem(_) => "waveform.badge.exclamationmark",
        }
    }
}

pub fn status(
    startup_error: Option<&str>,
    importing: bool,
    jobs: &[Value],
    unreadable: bool,
) -> Status {
    if let Some(error) = startup_error {
        return Status::Problem(error.to_owned());
    }
    if importing {
        return Status::Starting;
    }
    let waiting = |marker: &str| {
        jobs.iter().any(|job| {
            job["state"] == "retry"
                && job["error"]
                    .as_str()
                    .is_some_and(|error| error.contains(marker))
        })
    };
    if waiting("BACKEND_UNAVAILABLE:") {
        return Status::Problem("el motor de transcripción no responde".into());
    }
    if waiting("RECIPE_UNAVAILABLE:") {
        return Status::Problem("la receta por defecto no está disponible".into());
    }
    if unreadable {
        return Status::Problem("no puedo leer la carpeta".into());
    }
    let pending = jobs
        .iter()
        .filter(|job| matches!(job["state"].as_str(), Some("queued" | "running")))
        .count();
    if pending > 0 {
        Status::Working(pending)
    } else {
        Status::Watching
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct View {
    pub status: Status,
    pub count: Option<usize>,
    pub recording: bool,
    pub problem: Option<String>,
}

impl View {
    pub fn symbol(&self) -> &'static str {
        if self.recording {
            "record.circle"
        } else {
            self.status.symbol()
        }
    }
}

#[derive(Default)]
pub struct Bar {
    view: Option<View>,
    stop: Option<MenuItem<Wry>>,
    new_recording: Option<MenuItem<Wry>>,
}

fn current(state: &Runtime, previous: Option<&View>) -> Option<View> {
    let (startup_error, importing) = state
        .startup
        .lock()
        .map(|startup| (startup.error.clone(), startup.snapshot.is_some()))
        .ok()?;
    let unreadable = state
        .watch_health
        .lock()
        .map(|health| {
            health
                .snapshot()
                .as_array()
                .is_some_and(|issues| !issues.is_empty())
        })
        .unwrap_or(false);
    let (jobs, count) = if importing {
        (Vec::new(), None)
    } else {
        match state.store.try_lock() {
            Ok(store) => (
                store.jobs().unwrap_or_default(),
                store.data["recordings"].as_array().map(Vec::len),
            ),
            Err(_) => return previous.cloned(),
        }
    };
    let problem = state
        .recording_problem
        .lock()
        .ok()
        .and_then(|problem| problem.as_ref().map(|p| p.message.clone()));
    Some(View {
        status: status(startup_error.as_deref(), importing, &jobs, unreadable),
        count,
        recording: recorder::is_recording(state),
        problem,
    })
}

pub fn refresh(app: &AppHandle, state: &Runtime) {
    let Ok(mut bar) = state.menubar.lock() else {
        return;
    };
    let Some(view) = current(state, bar.view.as_ref()) else {
        return;
    };
    if bar.view.as_ref() == Some(&view) {
        return;
    }
    if let Some(item) = &bar.new_recording {
        let _ = item.set_text(if view.recording {
            "Detener y transcribir"
        } else {
            "Nueva grabación"
        });
    }
    match tray_menu(app, &view, &clock(state)) {
        Ok((menu, stop)) => {
            if let Some(tray) = app.tray_by_id(STATUS_TRAY) {
                let _ = tray.set_menu(Some(menu));
                if bar.view.as_ref().map(View::symbol) != Some(view.symbol()) {
                    if let Some(icon) = crate::symbols::image(view.symbol()) {
                        let _ = tray.set_icon(Some(icon));
                        let _ = tray.set_icon_as_template(true);
                    }
                }
            }
            bar.stop = stop;
            bar.view = Some(view);
        }
        Err(error) => eprintln!("No se pudo actualizar el menú de la barra: {error}"),
    }
}

pub fn recording_clock(_app: &AppHandle, state: &Runtime, clock: &str) {
    if let Ok(bar) = state.menubar.lock() {
        if let Some(stop) = &bar.stop {
            let _ = stop.set_text(format!("Detener y transcribir ({clock})"));
        }
    }
}

fn clock(state: &Runtime) -> String {
    state
        .recording
        .lock()
        .ok()
        .and_then(|session| session.as_ref().map(|s| s.clock()))
        .unwrap_or_else(|| crate::recording::duration_clock(0.0))
}

fn disabled(app: &AppHandle, text: &str) -> tauri::Result<MenuItem<Wry>> {
    MenuItem::new(app, text, false, None::<&str>)
}

fn action(app: &AppHandle, id: &str, text: &str) -> tauri::Result<MenuItem<Wry>> {
    MenuItem::with_id(app, id, text, true, None::<&str>)
}

fn tray_menu(
    app: &AppHandle,
    view: &View,
    clock: &str,
) -> tauri::Result<(Menu<Wry>, Option<MenuItem<Wry>>)> {
    let menu = Menu::new(app)?;
    menu.append(&disabled(app, &view.status.label())?)?;
    if let Some(count) = view.count {
        menu.append(&disabled(app, &format!("{count} en la biblioteca"))?)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    let mut stop = None;
    if view.recording {
        let item = action(app, "bar-stop", &format!("Detener y transcribir ({clock})"))?;
        menu.append(&item)?;
        menu.append(&action(app, "bar-discard", "Descartar la grabación")?)?;
        stop = Some(item);
    } else {
        menu.append(&action(app, "bar-record", "Grabar nota")?)?;
    }
    if let Some(problem) = &view.problem {
        menu.append(&disabled(app, problem)?)?;
        menu.append(&action(app, "bar-dismiss", "Entendido")?)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&action(app, "bar-library", "Abrir biblioteca")?)?;
    menu.append(&action(app, "bar-scan", "Buscar grabaciones ahora")?)?;
    menu.append(&action(app, "bar-connectors", "Conectores…")?)?;
    menu.append(&action(app, "bar-settings", "Ajustes…")?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&action(app, "bar-log", "Ver registro")?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&action(app, "bar-quit", "Salir")?)?;
    Ok((menu, stop))
}

pub fn install(app: &AppHandle, state: &Runtime) -> tauri::Result<()> {
    let name = app.package_info().name.clone();
    let new_recording = MenuItem::with_id(
        app,
        "new-recording",
        "Nueva grabación",
        true,
        Some("CmdOrCtrl+N"),
    )?;
    let application = Submenu::with_items(
        app,
        &name,
        true,
        &[
            &PredefinedMenuItem::about(app, Some(&format!("Acerca de {name}")), None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::services(app, Some("Servicios"))?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, Some(&format!("Ocultar {name}")))?,
            &PredefinedMenuItem::hide_others(app, Some("Ocultar otros"))?,
            &PredefinedMenuItem::show_all(app, Some("Mostrar todo"))?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(
                app,
                "app-quit",
                format!("Salir de {name}"),
                true,
                Some("CmdOrCtrl+Q"),
            )?,
        ],
    )?;
    let file = Submenu::with_items(
        app,
        "Archivo",
        true,
        &[
            &new_recording,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::close_window(app, Some("Cerrar"))?,
        ],
    )?;
    let edit = Submenu::with_items(
        app,
        "Edición",
        true,
        &[
            &PredefinedMenuItem::undo(app, Some("Deshacer"))?,
            &PredefinedMenuItem::redo(app, Some("Rehacer"))?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::cut(app, Some("Cortar"))?,
            &PredefinedMenuItem::copy(app, Some("Copiar"))?,
            &PredefinedMenuItem::paste(app, Some("Pegar"))?,
            &PredefinedMenuItem::select_all(app, Some("Seleccionar todo"))?,
        ],
    )?;
    let view = Submenu::with_items(
        app,
        "Visualización",
        true,
        &[&PredefinedMenuItem::fullscreen(
            app,
            Some("Entrar en pantalla completa"),
        )?],
    )?;
    let window = Submenu::with_items(
        app,
        "Ventana",
        true,
        &[
            &PredefinedMenuItem::minimize(app, Some("Minimizar"))?,
            &PredefinedMenuItem::maximize(app, Some("Zoom"))?,
        ],
    )?;
    app.set_menu(Menu::with_items(
        app,
        &[&application, &file, &edit, &view, &window],
    )?)?;
    if let Ok(mut bar) = state.menubar.lock() {
        bar.new_recording = Some(new_recording);
    }
    let mut tray = TrayIconBuilder::with_id(STATUS_TRAY)
        .tooltip(&name)
        .show_menu_on_left_click(true)
        .menu(&Menu::new(app)?);
    if let Some(icon) = crate::symbols::image("waveform") {
        tray = tray.icon(icon).icon_as_template(true);
    }
    tray.build(app)?;
    refresh(app, state);
    Ok(())
}

pub fn watch(app: AppHandle, state: Arc<Runtime>) {
    tauri::async_runtime::spawn(async move {
        loop {
            refresh(&app, &state);
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    });
}

pub fn handle(app: &AppHandle, id: &str) {
    let app = app.clone();
    let id = id.to_owned();
    tauri::async_runtime::spawn(async move {
        let state = app.state::<Arc<Runtime>>().inner().clone();
        let result = match id.as_str() {
            "new-recording" if recorder::is_recording(&state) => {
                recorder::stop(&app, &state).await.map(|_| ())
            }
            "new-recording" | "bar-record" => recorder::start(&app, &state, None).await.map(|_| ()),
            "bar-stop" => recorder::stop(&app, &state).await.map(|_| ()),
            "bar-discard" => recorder::cancel(&app, &state).await.map(|_| ()),
            "bar-dismiss" => {
                recorder::dismiss(&app, &state);
                Ok(())
            }
            "bar-scan" => crate::scan(&app, &state).await.map(|_| ()),
            "bar-library" => show(&app, "library"),
            "bar-connectors" => show(&app, "connectors"),
            "bar-settings" => show(&app, "settings"),
            "bar-log" => show(&app, "log"),
            "bar-quit" | "app-quit" => {
                quit(&app, &state).await;
                Ok(())
            }
            _ => Ok(()),
        };
        if let Err(error) = result {
            crate::log_error(&state, &error);
        }
    });
}

pub fn show(app: &AppHandle, section: &str) -> Result<(), String> {
    let window = app
        .get_webview_window("main")
        .ok_or("La ventana principal no existe")?;
    let _ = window.unminimize();
    window.show().map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())?;
    window
        .emit("escriba://navigate", section)
        .map_err(|e| e.to_string())
}

pub async fn quit(app: &AppHandle, state: &Arc<Runtime>) {
    state.quitting.store(true, Ordering::SeqCst);
    if recorder::is_recording(state) {
        if let Err(error) = recorder::stop(app, state).await {
            crate::log_error(
                state,
                &format!("No se pudo guardar la grabación al salir: {error}"),
            );
        }
    }
    app.exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn el_estado_se_dice_como_en_swift() {
        assert_eq!(Status::Watching.label(), "Vigilando");
        assert_eq!(Status::Starting.label(), "Arrancando");
        assert_eq!(Status::Working(3).label(), "Transcribiendo (3 en cola)");
        assert_eq!(Status::Problem("x".into()).label(), "Problema: x");
        assert_eq!(Status::Working(1).symbol(), "waveform.badge.mic");
        assert_eq!(
            Status::Problem("x".into()).symbol(),
            "waveform.badge.exclamationmark"
        );
    }

    #[test]
    fn el_estado_sale_de_los_trabajos_y_las_carpetas() {
        let running = json!({"state":"running"});
        let queued = json!({"state":"queued"});
        let engine = json!({"state":"retry","error":"BACKEND_UNAVAILABLE: modelo ausente"});
        let recipe = json!({"state":"retry","error":"RECIPE_UNAVAILABLE: sin paquete"});
        let done = json!({"state":"succeeded"});
        assert_eq!(status(None, false, &[], false), Status::Watching);
        assert_eq!(status(None, false, &[done], false), Status::Watching);
        assert_eq!(
            status(None, false, &[running.clone(), queued], false),
            Status::Working(2)
        );
        assert_eq!(
            status(None, false, &[running.clone(), engine], false),
            Status::Problem("el motor de transcripción no responde".into())
        );
        assert_eq!(
            status(None, false, &[recipe], false),
            Status::Problem("la receta por defecto no está disponible".into())
        );
        assert_eq!(
            status(None, false, &[running], true),
            Status::Problem("no puedo leer la carpeta".into())
        );
        assert_eq!(status(None, true, &[], false), Status::Starting);
        assert_eq!(
            status(Some("sin base"), true, &[], false),
            Status::Problem("sin base".into())
        );
    }

    #[test]
    fn mientras_se_graba_el_icono_es_el_de_grabar() {
        let view = View {
            status: Status::Working(2),
            count: Some(4),
            recording: true,
            problem: None,
        };
        assert_eq!(view.symbol(), "record.circle");
        assert_eq!(
            View {
                recording: false,
                ..view
            }
            .symbol(),
            "waveform.badge.mic"
        );
    }
}
