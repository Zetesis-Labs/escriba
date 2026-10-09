//! Native macOS folder selection and persistent bookmark resolution.
//!
//! This app is not sandboxed. An ordinary bookmark remembers the selected
//! directory; the OS remains responsible for any privacy (TCC) decision.

use objc2::{rc::Retained, MainThreadMarker};
use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};
use objc2_foundation::{
    NSData, NSString, NSURLBookmarkCreationOptions, NSURLBookmarkResolutionOptions, NSURL,
};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub struct SelectedFolder {
    pub path: PathBuf,
    pub bookmark: Vec<u8>,
}

pub struct ResolvedFolder {
    pub path: PathBuf,
    pub refreshed_bookmark: Option<Vec<u8>>,
    _guard: AccessGuard,
}

/// Balances an acquired NSURL security scope, including an implicit scope.
pub struct AccessGuard {
    url: Retained<NSURL>,
    started: bool,
}

impl Drop for AccessGuard {
    fn drop(&mut self) {
        if self.started {
            // SAFETY: This URL was successfully started once by `access`.
            unsafe { self.url.stopAccessingSecurityScopedResource() };
        }
    }
}

fn path(url: &NSURL) -> Result<PathBuf, String> {
    url.path()
        .map(|path| PathBuf::from(path.to_string()))
        .ok_or_else(|| "La selección no es una carpeta local".into())
}

fn access(url: Retained<NSURL>) -> Result<(PathBuf, AccessGuard), String> {
    let selected = path(&url)?;
    // SAFETY: Calls the system method on a retained file URL. A successful
    // start is balanced in AccessGuard::drop.
    let started = unsafe { url.startAccessingSecurityScopedResource() };
    let guard = AccessGuard { url, started };
    let mut entries = fs::read_dir(&selected)
        .map_err(|error| format!("No se puede leer {}: {error}", selected.display()))?;
    entries
        .next()
        .transpose()
        .map_err(|error| format!("No se puede leer {}: {error}", selected.display()))?;
    Ok((selected, guard))
}

fn bookmark(url: &NSURL) -> Result<Vec<u8>, String> {
    url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
        NSURLBookmarkCreationOptions::empty(),
        None,
        None,
    )
    .map(|data| data.to_vec())
    .map_err(|error| format!("No se pudo guardar el acceso a la carpeta: {error}"))
}

fn select_url(url: Retained<NSURL>) -> Result<SelectedFolder, String> {
    let (path, _guard) = access(url.clone())?;
    let bookmark = bookmark(&url)?;
    Ok(SelectedFolder { path, bookmark })
}

/// Call on the main thread (for example, inside Tauri's run_on_main_thread).
/// Cancellation returns None; a panel failure returns an error.
pub fn select_folder(initial_path: Option<&Path>) -> Result<Option<SelectedFolder>, String> {
    let mtm = MainThreadMarker::new()
        .ok_or("El selector de carpetas debe abrirse en el hilo principal")?;
    let panel = NSOpenPanel::openPanel(mtm);
    panel.setCanChooseDirectories(true);
    panel.setCanChooseFiles(false);
    panel.setAllowsMultipleSelection(false);
    panel.setTitle(Some(&NSString::from_str("Autorizar carpeta")));
    panel.setMessage(Some(&NSString::from_str(
        "Selecciona solo la carpeta que Escriba debe vigilar",
    )));
    if let Some(initial_path) = initial_path {
        if let Some(path) = initial_path.to_str() {
            let url = NSURL::fileURLWithPath_isDirectory(&NSString::from_str(path), true);
            panel.setDirectoryURL(Some(&url));
        }
    }
    let response = panel.runModal();
    if response == NSModalResponseOK {
        let url = panel
            .URL()
            .ok_or("El selector no devolvió ninguna carpeta")?;
        select_url(url).map(Some)
    } else if response == 0 {
        Ok(None)
    } else {
        Err("No se pudo abrir el selector de carpetas".into())
    }
}

/// Resolves the stored bookmark afresh and verifies that the directory can be
/// enumerated. Callers must retain `guard` while they use the directory.
pub fn restore(bytes: &[u8]) -> Result<ResolvedFolder, String> {
    if bytes.is_empty() {
        return Err("Falta el acceso guardado a la carpeta".into());
    }
    let data = NSData::with_bytes(bytes);
    let mut stale = objc2::runtime::Bool::NO;
    // SAFETY: `stale` is a valid writable pointer for the duration of this call.
    let url = unsafe {
        NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
            &data,
            NSURLBookmarkResolutionOptions::WithoutUI
                | NSURLBookmarkResolutionOptions::WithoutImplicitStartAccessing,
            None,
            &mut stale,
        )
    }
    .map_err(|error| format!("No se pudo recuperar el acceso a la carpeta: {error}"))?;
    let (path, guard) = access(url.clone())?;
    let refreshed_bookmark = if stale.as_bool() {
        Some(bookmark(&url)?)
    } else {
        None
    };
    Ok(ResolvedFolder {
        path,
        refreshed_bookmark,
        _guard: guard,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restaura_una_carpeta_sintetica_y_su_contenido() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(folder.path().join("prueba.txt"), "contenido").unwrap();
        let url = NSURL::fileURLWithPath_isDirectory(
            &NSString::from_str(folder.path().to_str().unwrap()),
            true,
        );
        let selected = select_url(url).unwrap();
        let resolved = restore(&selected.bookmark).unwrap();
        assert_eq!(
            fs::read_to_string(resolved.path.join("prueba.txt")).unwrap(),
            "contenido"
        );
        assert!(resolved.refreshed_bookmark.is_none());
    }

    #[test]
    fn datos_corruptos_no_autorizan_una_carpeta() {
        assert!(restore(b"esto no es un bookmark").is_err());
    }

    #[test]
    fn carpeta_trasladada_actualiza_su_bookmark() {
        let root = tempfile::tempdir().unwrap();
        let original = root.path().join("original");
        let moved = root.path().join("movida");
        fs::create_dir(&original).unwrap();
        let url = NSURL::fileURLWithPath_isDirectory(
            &NSString::from_str(original.to_str().unwrap()),
            true,
        );
        let selected = select_url(url).unwrap();
        fs::rename(&original, &moved).unwrap();
        let resolved = restore(&selected.bookmark).unwrap();
        assert_eq!(
            resolved.path.canonicalize().unwrap(),
            moved.canonicalize().unwrap()
        );
        let refreshed = resolved
            .refreshed_bookmark
            .expect("el traslado marca el bookmark obsoleto");
        assert_eq!(
            restore(&refreshed).unwrap().path.canonicalize().unwrap(),
            moved.canonicalize().unwrap()
        );
    }

    #[test]
    fn bookmark_persistido_se_lee_en_otro_proceso() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(folder.path().join("prueba.txt"), "persistido").unwrap();
        let url = NSURL::fileURLWithPath_isDirectory(
            &NSString::from_str(folder.path().to_str().unwrap()),
            true,
        );
        let selected = select_url(url).unwrap();
        let bookmark_file = folder
            .path()
            .parent()
            .unwrap()
            .join(format!("escriba-bookmark-{}.bin", std::process::id()));
        fs::write(&bookmark_file, selected.bookmark).unwrap();
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("folder_access::tests::restaura_bookmark_en_subproceso")
            .env("ESCRIBA_TEST_BOOKMARK_FILE", &bookmark_file)
            .output()
            .unwrap();
        fs::remove_file(bookmark_file).unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(String::from_utf8_lossy(&result.stdout).contains("1 passed"));
    }

    #[test]
    fn restaura_bookmark_en_subproceso() {
        let Ok(file) = std::env::var("ESCRIBA_TEST_BOOKMARK_FILE") else {
            return;
        };
        let resolved = restore(&fs::read(file).unwrap()).unwrap();
        assert_eq!(
            fs::read_to_string(resolved.path.join("prueba.txt")).unwrap(),
            "persistido"
        );
    }
}
