//! Linux folder selection. A native install reads the folder through its path:
//! either the system lets Escriba read it or the folder is reported. Inside a
//! Flatpak the file chooser portal grants each folder, and the granted path
//! plays the part of the macOS bookmark: it is saved, restored and, if lost,
//! authorized again.

use std::{
    fs,
    path::{Path, PathBuf},
};
use tauri_plugin_dialog::DialogExt;

pub struct SelectedFolder {
    pub path: PathBuf,
    pub bookmark: Vec<u8>,
}

pub struct ResolvedFolder {
    pub path: PathBuf,
    pub refreshed_bookmark: Option<Vec<u8>>,
}

fn readable(path: &Path) -> Result<PathBuf, String> {
    let mut entries = fs::read_dir(path)
        .map_err(|error| format!("No se puede leer {}: {error}", path.display()))?;
    entries
        .next()
        .transpose()
        .map_err(|error| format!("No se puede leer {}: {error}", path.display()))?;
    Ok(path.to_path_buf())
}

fn selected(path: &Path, authorizes: bool) -> Result<SelectedFolder, String> {
    use std::os::unix::ffi::OsStrExt;
    let path = readable(path)?;
    let bookmark = if authorizes {
        path.as_os_str().as_bytes().to_vec()
    } else {
        Vec::new()
    };
    Ok(SelectedFolder { path, bookmark })
}

/// Cancellation returns None; an unreadable choice returns an error.
pub async fn choose(
    app: &tauri::AppHandle,
    initial_path: Option<&Path>,
) -> Result<Option<SelectedFolder>, String> {
    let (reply, receive) = tokio::sync::oneshot::channel();
    let mut dialog = app.dialog().file().set_title("Elegir carpeta");
    if let Some(initial_path) = initial_path {
        dialog = dialog.set_directory(initial_path);
    }
    dialog.pick_folder(move |folder| {
        let _ = reply.send(folder);
    });
    let Some(folder) = receive
        .await
        .map_err(|_| "El selector de carpetas se cerró inesperadamente")?
    else {
        return Ok(None);
    };
    let path = folder
        .into_path()
        .map_err(|_| "La selección no es una carpeta local")?;
    selected(&path, crate::platform::folder_authorization()).map(Some)
}

/// The portal's granted path, when there is one, is the folder's authorization.
pub fn restore_saved(path: &Path, bookmark: &[u8]) -> Result<ResolvedFolder, String> {
    use std::os::unix::ffi::OsStrExt;
    if bookmark.is_empty() {
        return restore(path);
    }
    restore(Path::new(std::ffi::OsStr::from_bytes(bookmark)))
}

pub fn restore(path: &Path) -> Result<ResolvedFolder, String> {
    Ok(ResolvedFolder {
        path: readable(path)?,
        refreshed_bookmark: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn elegir_una_carpeta_devuelve_la_ruta_y_un_bookmark_vacio() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(folder.path().join("prueba.ogg"), "audio").unwrap();
        let selected = selected(folder.path(), false).unwrap();
        assert_eq!(selected.path, folder.path());
        assert!(selected.bookmark.is_empty());
    }

    #[test]
    fn dentro_de_flatpak_la_carpeta_concedida_por_el_portal_es_su_autorizacion() {
        use std::os::unix::ffi::OsStrExt;
        let granted = tempfile::tempdir().unwrap();
        let chosen = selected(granted.path(), true).unwrap();
        assert_eq!(chosen.bookmark, granted.path().as_os_str().as_bytes());
        let elsewhere = tempfile::tempdir().unwrap();
        let resolved = restore_saved(elsewhere.path(), &chosen.bookmark).unwrap();
        assert_eq!(resolved.path, granted.path());
        assert!(resolved.refreshed_bookmark.is_none());
        let revoked = granted.path().join("revocada");
        let lost = restore_saved(granted.path(), revoked.as_os_str().as_bytes());
        assert!(lost.err().unwrap().contains("revocada"));
    }

    #[test]
    fn restaurar_acepta_la_ruta_tal_cual() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(folder.path().join("prueba.txt"), "contenido").unwrap();
        let resolved = restore(folder.path()).unwrap();
        assert_eq!(resolved.path, folder.path());
        assert_eq!(
            fs::read_to_string(resolved.path.join("prueba.txt")).unwrap(),
            "contenido"
        );
        assert!(resolved.refreshed_bookmark.is_none());
    }

    #[test]
    fn una_carpeta_ausente_no_se_restaura() {
        let root = tempfile::tempdir().unwrap();
        let error = restore(&root.path().join("movida")).err().unwrap();
        assert!(error.contains("movida"), "{error}");
    }

    #[test]
    fn una_carpeta_sin_permiso_de_lectura_no_se_elige_ni_se_restaura() {
        let root = tempfile::tempdir().unwrap();
        let locked = root.path().join("cerrada");
        fs::create_dir(&locked).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        let readable_anyway = fs::read_dir(&locked).is_ok();
        let chosen = selected(&locked, false).is_err();
        let restored = restore(&locked).is_err();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        if readable_anyway {
            return;
        }
        assert!(chosen);
        assert!(restored);
    }
}
