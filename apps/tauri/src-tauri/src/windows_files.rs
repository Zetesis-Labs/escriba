use std::{
    fs::{self, File, OpenOptions},
    os::windows::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_SHARE_READ,
};
pub(crate) fn directory(path: &Path) -> Result<File, String> {
    let file = OpenOptions::new()
        .access_mode(0x80)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
        .map_err(|error| format!("No se pudo proteger la carpeta {}: {error}", path.display()))?;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err("La ruta contiene un enlace o una unión de directorios".into());
    }
    Ok(file)
}

// Holding every directory without delete sharing prevents a concurrent path swap.
pub(crate) fn parents(
    root: &Path,
    parts: &[String],
    create: bool,
) -> Result<(PathBuf, Vec<File>), String> {
    let mut path = PathBuf::new();
    let mut locks = Vec::new();
    for part in root.components() {
        path.push(part);
        if !matches!(part, std::path::Component::Prefix(_)) && path.has_root() {
            locks.push(directory(&path)?);
        }
    }
    for part in &parts[..parts.len() - 1] {
        path.push(part);
        if create && !path.exists() {
            fs::create_dir(&path).map_err(|error| error.to_string())?;
        }
        locks.push(directory(&path)?);
    }
    Ok((path.join(parts.last().ok_or("Ruta vacía")?), locks))
}
