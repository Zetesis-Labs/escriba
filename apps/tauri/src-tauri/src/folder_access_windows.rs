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

pub fn restore(path: &Path) -> Result<ResolvedFolder, String> {
    fs::read_dir(path)
        .map_err(|error| format!("No se puede leer {}: {error}", path.display()))?
        .next()
        .transpose()
        .map_err(|error| error.to_string())?;
    Ok(ResolvedFolder {
        path: path.to_owned(),
        refreshed_bookmark: None,
    })
}

pub fn restore_saved(path: &Path, _: &[u8]) -> Result<ResolvedFolder, String> {
    restore(path)
}

pub async fn choose(
    app: &tauri::AppHandle,
    initial_path: Option<&Path>,
) -> Result<Option<SelectedFolder>, String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    let mut dialog = app.dialog().file().set_title("Elegir carpeta");
    if let Some(path) = initial_path {
        dialog = dialog.set_directory(path);
    }
    dialog.pick_folder(move |folder| {
        let _ = send.send(folder);
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
    Ok(Some(SelectedFolder {
        path: restore(&path)?.path,
        bookmark: Vec::new(),
    }))
}
