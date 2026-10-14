//! Decisions that differ between macOS and Linux, without I/O.

use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
    process::Command,
};

#[cfg(target_os = "macos")]
pub fn is_models_root(root: &Path) -> bool {
    root.ends_with("Application Support/escriba/models")
}

#[cfg(target_os = "linux")]
pub fn is_models_root(root: &Path) -> bool {
    linux_models_root(
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
    .is_some_and(|expected| expected == root)
}

// XDG asks to ignore a relative XDG_DATA_HOME.
#[cfg(any(target_os = "linux", test))]
fn linux_models_root(data_home: Option<&OsStr>, home: Option<&OsStr>) -> Option<PathBuf> {
    let data = data_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join(".local/share"))
        })?;
    Some(data.join("escriba/models"))
}

#[cfg(target_os = "macos")]
pub fn open(target: &OsStr) -> Command {
    let mut command = Command::new("/usr/bin/open");
    command.arg(target);
    command
}

#[cfg(target_os = "linux")]
pub fn open(target: &OsStr) -> Command {
    let mut command = Command::new("xdg-open");
    command.arg(target);
    command
}

#[cfg(target_os = "macos")]
pub fn reveal(path: &Path) -> Command {
    let mut command = Command::new("/usr/bin/open");
    command.arg("-R").arg(path);
    command
}

// xdg-open cannot select a file, so it opens the folder that contains it.
#[cfg(target_os = "linux")]
pub fn reveal(path: &Path) -> Command {
    open(path.parent().unwrap_or(path).as_os_str())
}

#[cfg(target_os = "macos")]
pub const REVEAL_FAILED: &str = "Finder no pudo abrir la ubicación";
#[cfg(target_os = "linux")]
pub const REVEAL_FAILED: &str = "No se pudo abrir la carpeta";

#[cfg(target_os = "macos")]
pub fn open_vscode(path: &Path) -> Command {
    let mut command = Command::new("/usr/bin/open");
    command.args(["-b", "com.microsoft.VSCode"]).arg(path);
    command
}

#[cfg(target_os = "linux")]
pub fn open_vscode(path: &Path) -> Command {
    let mut command = Command::new("code");
    command.arg(path);
    command
}

#[cfg(target_os = "macos")]
pub fn privacy_settings(pane: Option<&str>) -> Result<Command, String> {
    let pane = match pane {
        Some("microphone") => {
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        Some("disk") => "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        _ => "x-apple.systempreferences:com.apple.preference.security",
    };
    Ok(open(OsStr::new(pane)))
}

#[cfg(target_os = "linux")]
pub fn privacy_settings(pane: Option<&str>) -> Result<Command, String> {
    Err(match pane {
        Some("microphone") => {
            "Escriba no puede usar el micrófono. Comprueba que hay un micrófono conectado y que la configuración de tu escritorio permite usarlo."
        }
        Some("disk") => {
            "Escriba no puede leer la carpeta. Comprueba que tu usuario tiene permiso de lectura sobre ella."
        }
        _ => "Escriba no tiene un permiso que necesita. Revisa la configuración de tu escritorio.",
    }
    .into())
}

/// Package and file of the SurrealDB binding the controller loads.
pub fn surreal_native() -> (String, String) {
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x64"
    };
    let name = if cfg!(target_os = "linux") {
        format!("linux-{arch}-gnu")
    } else {
        format!("darwin-{arch}")
    };
    (
        format!("node-native-{name}"),
        format!("surrealdb-node.{name}.node"),
    )
}

/// Whether recipes run under an OS sandbox. Without it they still run and
/// the interface shows a permanent warning.
pub fn recipes_isolated() -> bool {
    cfg!(target_os = "macos")
}

// The native host records AAC on macOS and Opus on Linux.
#[cfg(target_os = "macos")]
pub const RECORDING_EXTENSION: &str = "m4a";
#[cfg(target_os = "linux")]
pub const RECORDING_EXTENSION: &str = "ogg";

#[cfg(target_os = "macos")]
pub const SYSTEM: &str = "macos";
#[cfg(target_os = "linux")]
pub const SYSTEM: &str = "linux";

/// What the interface needs to know to show each system's options.
pub fn summary() -> serde_json::Value {
    serde_json::json!({"system": SYSTEM, "recipesIsolated": recipes_isolated()})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn el_binding_de_surrealdb_es_el_del_sistema() {
        let (package, file) = surreal_native();
        let system = if cfg!(target_os = "linux") {
            "linux"
        } else {
            "darwin"
        };
        assert!(
            package.starts_with(&format!("node-native-{system}-")),
            "{package}"
        );
        assert!(
            file.starts_with(&format!("surrealdb-node.{system}-")),
            "{file}"
        );
        assert_eq!(
            package.trim_start_matches("node-native-"),
            file.trim_start_matches("surrealdb-node.")
                .trim_end_matches(".node")
        );
    }

    #[test]
    fn la_interfaz_recibe_el_sistema_y_si_las_recetas_estan_aisladas() {
        let expected = if cfg!(target_os = "macos") {
            serde_json::json!({"system": "macos", "recipesIsolated": true})
        } else {
            serde_json::json!({"system": "linux", "recipesIsolated": false})
        };
        assert_eq!(summary(), expected);
    }

    #[test]
    fn la_grabacion_lleva_la_extension_del_formato_del_host() {
        let expected = if cfg!(target_os = "macos") {
            "m4a"
        } else {
            "ogg"
        };
        assert_eq!(RECORDING_EXTENSION, expected);
    }

    fn line(command: &Command) -> Vec<String> {
        std::iter::once(command.get_program())
            .chain(command.get_args())
            .map(|part| part.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn la_carpeta_de_modelos_de_linux_sigue_xdg() {
        assert_eq!(
            linux_models_root(Some(OsStr::new("/datos")), Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/datos/escriba/models"))
        );
        assert_eq!(
            linux_models_root(None, Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/home/ana/.local/share/escriba/models"))
        );
        assert_eq!(
            linux_models_root(Some(OsStr::new("relativa")), Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/home/ana/.local/share/escriba/models"))
        );
        assert_eq!(linux_models_root(None, None), None);
        assert_eq!(linux_models_root(None, Some(OsStr::new("relativa"))), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_solo_vale_la_carpeta_de_modelos_de_escriba() {
        let expected = linux_models_root(
            std::env::var_os("XDG_DATA_HOME").as_deref(),
            std::env::var_os("HOME").as_deref(),
        )
        .unwrap();
        assert!(is_models_root(&expected));
        assert!(!is_models_root(Path::new("/tmp/escriba/models")));
        assert!(!is_models_root(Path::new(
            "/Users/ana/Library/Application Support/escriba/models"
        )));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn en_macos_vale_application_support() {
        assert!(is_models_root(Path::new(
            "/Users/ana/Library/Application Support/escriba/models"
        )));
        assert!(!is_models_root(Path::new("/tmp/escriba/models")));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_abrir_y_mostrar_usan_xdg_open() {
        assert_eq!(
            line(&open(OsStr::new("https://example.com"))),
            ["xdg-open", "https://example.com"]
        );
        assert_eq!(
            line(&reveal(Path::new("/home/ana/audio/nota.ogg"))),
            ["xdg-open", "/home/ana/audio"]
        );
        assert_eq!(
            line(&open_vscode(Path::new("/home/ana/recetas"))),
            ["code", "/home/ana/recetas"]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn en_macos_abrir_y_mostrar_usan_open() {
        assert_eq!(
            line(&open(OsStr::new("https://example.com"))),
            ["/usr/bin/open", "https://example.com"]
        );
        assert_eq!(
            line(&reveal(Path::new("/Users/ana/nota.m4a"))),
            ["/usr/bin/open", "-R", "/Users/ana/nota.m4a"]
        );
        assert_eq!(
            line(&open_vscode(Path::new("/Users/ana/recetas"))),
            [
                "/usr/bin/open",
                "-b",
                "com.microsoft.VSCode",
                "/Users/ana/recetas"
            ]
        );
        assert_eq!(
            line(&privacy_settings(Some("microphone")).unwrap()),
            [
                "/usr/bin/open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ]
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_los_avisos_de_permisos_explican_que_falta_sin_enlaces_del_mac() {
        for pane in [Some("microphone"), Some("disk"), None] {
            let message = privacy_settings(pane).err().unwrap();
            assert!(!message.contains("x-apple"), "{message}");
            assert!(!message.contains("macOS"), "{message}");
        }
        assert!(privacy_settings(Some("microphone"))
            .err()
            .unwrap()
            .contains("micrófono"));
        assert!(privacy_settings(Some("disk"))
            .err()
            .unwrap()
            .contains("permiso de lectura"));
    }

    #[test]
    fn las_recetas_solo_se_aislan_en_macos_por_ahora() {
        assert_eq!(recipes_isolated(), cfg!(target_os = "macos"));
    }
}
