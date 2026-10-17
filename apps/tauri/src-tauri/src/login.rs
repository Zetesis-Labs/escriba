use std::{fs, path::Path};
use tauri_plugin_autostart::ManagerExt;

fn plugin(app: &tauri::AppHandle, enabled: bool) -> Result<(), String> {
    let auto = app.autolaunch();
    if enabled {
        auto.enable().map_err(|error| error.to_string())
    } else {
        auto.disable().map_err(|error| error.to_string())
    }
}

/// Inside a Flatpak only the Background portal may start the app with the session.
#[cfg(target_os = "linux")]
async fn portal(enabled: bool) -> Result<(), String> {
    ashpd::desktop::background::Background::request()
        .reason("Abrir Escriba al iniciar sesión")
        .auto_start(enabled)
        .command(["escriba-tauri"])
        .dbus_activatable(false)
        .send()
        .await
        .and_then(|request| request.response())
        .map(|_| ())
        .map_err(|error| format!("El escritorio no permitió el inicio automático: {error}"))
}

pub async fn set(app: &tauri::AppHandle, enabled: bool) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    if crate::platform::inside_flatpak() {
        return portal(enabled).await;
    }
    plugin(app, enabled)
}

/// At startup the plugin's entry follows the setting; the portal keeps its own.
pub fn synchronize(app: &tauri::AppHandle, enabled: bool) -> Result<(), String> {
    use tauri::Manager;
    #[cfg(target_os = "linux")]
    if crate::platform::inside_flatpak() {
        return Ok(());
    }
    plugin(app, enabled)?;
    retire_previous_agent(&app.path().home_dir().map_err(|error| error.to_string())?)
}

fn retire_previous_agent(home: &Path) -> Result<(), String> {
    let path = home.join("Library/LaunchAgents/Escriba Tauri.plist");
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.to_string()),
    };
    if !metadata.file_type().is_file() {
        return Err("El antiguo inicio automático no es un archivo regular".into());
    }
    let value = plist::Value::from_file(&path).map_err(|error| error.to_string())?;
    let owned = value.as_dictionary().is_some_and(|dictionary| {
        dictionary.get("Label").and_then(plist::Value::as_string) == Some("Escriba Tauri")
            && dictionary
                .get("ProgramArguments")
                .and_then(plist::Value::as_array)
                .is_some_and(|args| {
                    args.len() == 1
                        && args[0].as_string().is_some_and(|executable| {
                            Path::new(executable)
                                .ends_with("Escriba Tauri.app/Contents/MacOS/escriba-tauri")
                        })
                })
    });
    if !owned {
        return Err("El antiguo inicio automático fue modificado; no se ha eliminado".into());
    }
    fs::remove_file(path).map_err(|error| error.to_string())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn retira_solo_el_agente_anterior_conocido_y_conserva_archivos_ajenos() {
        let home = tempfile::tempdir().unwrap();
        let folder = home.path().join("Library/LaunchAgents");
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join("Escriba Tauri.plist");
        for (executable, owned) in [
            (
                "/Applications/Escriba Tauri.app/Contents/MacOS/escriba-tauri",
                true,
            ),
            ("/Applications/Otra.app/Contents/MacOS/otra", false),
        ] {
            let mut value = plist::Dictionary::new();
            value.insert("Label".into(), "Escriba Tauri".into());
            value.insert(
                "ProgramArguments".into(),
                plist::Value::Array(vec![executable.into()]),
            );
            plist::to_file_xml(&path, &value).unwrap();
            assert_eq!(retire_previous_agent(home.path()).is_ok(), owned);
            assert_eq!(path.exists(), !owned);
        }
        fs::remove_file(&path).unwrap();
        let external = home.path().join("external");
        fs::write(&external, "user file").unwrap();
        std::os::unix::fs::symlink(&external, &path).unwrap();
        assert!(retire_previous_agent(home.path()).is_err());
        assert_eq!(fs::read_to_string(&external).unwrap(), "user file");
    }
}
