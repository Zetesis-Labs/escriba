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

/// Whether recipes run under an OS sandbox. Without it they still run and
/// the interface shows a permanent warning.
pub fn recipes_isolated() -> bool {
    cfg!(target_os = "macos")
}

#[cfg(test)]
mod tests {
    use super::*;

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
