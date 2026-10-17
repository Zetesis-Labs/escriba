use super::*;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
};

use crate::windows_files::parents;

pub(super) fn read_bytes(root: &Path, entry: &str, limit: usize) -> Result<Vec<u8>, String> {
    let parts = checked_entry(root, entry, false)?;
    let (path, _locks) = parents(root, &parts, false)?;
    let file = OpenOptions::new()
        .read(true)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| error.to_string())?;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file()
        || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
        || metadata.len() > limit as u64
    {
        return Err("Fuente inválida, enlace o demasiado grande".into());
    }
    let mut bytes = Vec::new();
    file.take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > limit {
        return Err("Fuente demasiado grande".into());
    }
    Ok(bytes)
}

pub(super) fn write_source(
    path: &Path,
    entry: &str,
    source: &str,
    expected: Option<&str>,
    create_new: bool,
) -> Result<(), String> {
    if create_new && expected.is_some() {
        return Err("La creación no admite una versión previa".into());
    }
    if source.len() > SOURCE_LIMIT {
        return Err("La fuente supera 8 MiB".into());
    }
    let root = project_root(path)?;
    let parts = checked_entry(&root, entry, true)?;
    let (target, _locks) = parents(&root, &parts, true)?;
    if let Some(expected) = expected {
        if read(&root, entry)?["source"].as_str() != Some(expected) {
            return Err("La fuente cambió desde que se abrió".into());
        }
    }
    let temporary = target.with_file_name(format!(".escriba-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file =
            crate::file_security::create_private(&temporary, false).map_err(|e| e.to_string())?;
        file.write_all(source.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        drop(file);
        if create_new {
            fs::hard_link(&temporary, &target)
                .map_err(|_| "El archivo ya existe o no se pudo crear".to_owned())
        } else {
            fs::rename(&temporary, &target).map_err(|e| e.to_string())
        }
    })();
    let _ = fs::remove_file(temporary);
    result
}

pub(super) fn launcher_source(
    runtime: &Path,
    vendor: &Path,
    checker: &Path,
) -> Result<String, String> {
    let quote = |path: &Path| path.display().to_string().replace('%', "%%");
    let sandbox = crate::native::binary("escriba-sandbox")?;
    let source = format!(
        r#"{LAUNCHER_MARKER}chcp 65001 >nul
setlocal DisableDelayedExpansion
set "RUNTIME={runtime}"
set "VENDOR={vendor}"
set "CHECKER={checker}"
set "SANDBOX={sandbox}"
set "ROOT=%~dp0"
pushd "%ROOT%" || exit /b 1
set "BUN_INSTALL_CACHE_DIR=%ROOT%.escriba\cache"
set "TEMP=%ROOT%.escriba\tmp"
set "TMP=%TEMP%"
set "BUN_BE_BUN="
if "%~1"=="install" goto install
if "%~1"=="check" goto check
if "%~1"=="test" goto test
if "%~1"=="build" goto build
echo Uso: escriba.cmd install^|check^|test^|build
exit /b 2
:install
set "BUN_BE_BUN=1"
"%SANDBOX%" install --project "%CD%" --vendor "%VENDOR%" --executable "%RUNTIME%" -- install --ignore-scripts
exit /b %ERRORLEVEL%
:check
"%SANDBOX%" tool --project "%CD%" --vendor "%VENDOR%" --executable "%CHECKER%" -- --noEmit --pretty false -p "%CD%"
exit /b %ERRORLEVEL%
:test
set "BUN_BE_BUN=1"
"%SANDBOX%" tool --project "%CD%" --vendor "%VENDOR%" --executable "%RUNTIME%" -- test
exit /b %ERRORLEVEL%
:build
"%SANDBOX%" tool --project "%CD%" --vendor "%VENDOR%" --executable "%RUNTIME%" -- --project-build "%CD%" "%VENDOR%"
exit /b %ERRORLEVEL%
"#,
        runtime = quote(runtime),
        vendor = quote(vendor),
        checker = quote(checker),
        sandbox = quote(&sandbox)
    );
    Ok(source.replace("\r\n", "\n").replace('\n', "\r\n"))
}
