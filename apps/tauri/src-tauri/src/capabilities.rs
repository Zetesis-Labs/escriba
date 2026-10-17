//! Narrow authority granted to connector programs by the Rust host.
#[cfg(all(test, unix))]
use serde_json::json;
use serde_json::{Map, Value};
#[cfg(unix)]
use std::io::Write;
use std::{
    collections::HashSet,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

#[cfg(unix)]
use std::{
    ffi::CString,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
};
#[cfg(windows)]
struct OwnedFd {
    path: PathBuf,
    _locks: Vec<fs::File>,
}

const FILE_LIMIT: usize = 64 * 1024 * 1024;
const FILE_COUNT_LIMIT: usize = 10_000;

fn required_str<'a>(object: &'a Value, name: &str) -> Result<&'a str, String> {
    object
        .get(name)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("Falta {name}"))
}

fn ensure_enabled(account: &Value) -> Result<(), String> {
    if account.get("enabled").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err("Cuenta desactivada".into())
    }
}

/// Reads or applies Markdown files inside one account's authorized real folder.
pub fn files(account: &Value, request: &Value) -> Result<Value, String> {
    ensure_enabled(account)?;
    let raw = Path::new(required_str(account, "folder")?);
    if !raw.is_absolute() {
        return Err("La carpeta autorizada debe ser absoluta".into());
    }
    let root = fs::canonicalize(raw).map_err(|_| "Carpeta autorizada no disponible")?;
    if !root.is_dir() {
        return Err("Carpeta autorizada no disponible".into());
    }
    let root_fd = open_root(&root)?;
    match required_str(request, "operation")? {
        "snapshot" => snapshot(&root, &root_fd),
        "apply" => apply(&root_fd, request),
        _ => Err("Operación de archivos desconocida".into()),
    }
}

pub fn authorized_okf_file(account: &Value, path: &Path) -> Result<PathBuf, String> {
    if account["provider"] != "okf" {
        return Err("La cuenta no es OKF".into());
    }
    let folder = Path::new(required_str(account, "folder")?);
    if !folder.is_absolute() {
        return Err("La carpeta autorizada debe ser absoluta".into());
    }
    let root = folder
        .canonicalize()
        .map_err(|_| "Carpeta autorizada no disponible")?;
    if !root.is_dir() {
        return Err("Carpeta autorizada no disponible".into());
    }
    let requested = if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    };
    let real = requested
        .canonicalize()
        .map_err(|_| "Archivo OKF no disponible")?;
    if !real.starts_with(&root)
        || !real.is_file()
        || real.extension().and_then(|value| value.to_str()) != Some("md")
    {
        return Err("El archivo no es un documento OKF de la carpeta autorizada".into());
    }
    Ok(real)
}

fn snapshot(root: &Path, root_fd: &OwnedFd) -> Result<Value, String> {
    let mut output = Map::new();
    let mut stack = vec![(root.to_path_buf(), String::new())];
    let mut total = 0usize;
    while let Some((directory, prefix)) = stack.pop() {
        for entry in
            fs::read_dir(&directory).map_err(|_| "No se puede leer la carpeta autorizada")?
        {
            let entry = entry.map_err(|_| "No se puede leer la carpeta autorizada")?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| "Hay un nombre de archivo no UTF-8")?;
            let relative = if prefix.is_empty() {
                name
            } else {
                format!("{prefix}/{name}")
            };
            let kind = fs::symlink_metadata(entry.path())
                .map_err(|_| "No se puede inspeccionar la carpeta")?;
            if kind.file_type().is_symlink() {
                return Err("La carpeta contiene un enlace simbólico".into());
            }
            if kind.is_dir() {
                stack.push((entry.path(), relative));
            } else if kind.is_file() && relative.ends_with(".md") {
                let components = relative_path(&relative)?;
                let text = read_current(root_fd, &components)?
                    .ok_or("El archivo cambió durante la lectura")?;
                total = total
                    .checked_add(text.len())
                    .ok_or("Snapshot supera 64 MiB")?;
                if total > FILE_LIMIT {
                    return Err("Snapshot supera 64 MiB".into());
                }
                if output.len() >= FILE_COUNT_LIMIT {
                    return Err("Snapshot supera 10000 archivos".into());
                }
                output.insert(relative, Value::String(text));
            }
        }
    }
    Ok(Value::Object(output))
}

struct FileChange {
    components: Vec<String>,
    contents: Option<String>,
}

fn apply(root_fd: &OwnedFd, request: &Value) -> Result<Value, String> {
    let changes = request
        .get("changes")
        .and_then(Value::as_array)
        .ok_or("Faltan changes")?;
    if changes.len() > FILE_COUNT_LIMIT {
        return Err("Apply supera 10000 archivos".into());
    }
    let mut prepared = Vec::with_capacity(changes.len());
    let mut seen = HashSet::new();
    let mut total = 0usize;
    // All validation and expected-content checks happen before the first mutation.
    for change in changes {
        let path = required_str(change, "path")?;
        let components = relative_path(path)?;
        if !seen.insert(path.to_owned()) {
            return Err("Ruta repetida en apply".into());
        }
        let contents = match change.get("contents") {
            Some(Value::String(s)) => Some(s.clone()),
            Some(Value::Null) => None,
            _ => return Err("contents debe ser texto o null".into()),
        };
        if let Some(text) = &contents {
            total = total.checked_add(text.len()).ok_or("Apply supera 64 MiB")?;
            if total > FILE_LIMIT {
                return Err("Apply supera 64 MiB".into());
            }
        }
        let current = read_current(root_fd, &components)?;
        if let Some(expected) = change.get("expectedContents") {
            let matches = match expected {
                Value::Null => current.is_none(),
                Value::String(text) => current.as_deref() == Some(text.as_str()),
                _ => return Err("expectedContents debe ser texto o null".into()),
            };
            if !matches {
                return Err("Los archivos cambiaron durante la publicación".into());
            }
        }
        prepared.push(FileChange {
            components,
            contents,
        });
    }
    for change in prepared {
        write_change(root_fd, &change)?;
    }
    Ok(Value::Null)
}

fn relative_path(path: &str) -> Result<Vec<String>, String> {
    if path.starts_with('/')
        || path.contains('\\')
        || path.contains('\0')
        || (cfg!(windows) && path.contains(':'))
        || !path.ends_with(".md")
    {
        return Err("Ruta Markdown no permitida".into());
    }
    let parts: Vec<String> = path.split('/').map(str::to_owned).collect();
    if parts.iter().any(|p| {
        p.is_empty()
            || p == "."
            || p == ".."
            || (cfg!(windows) && crate::file_security::invalid_windows_name(p))
    }) {
        return Err("Ruta relativa no permitida".into());
    }
    Ok(parts)
}

#[cfg(unix)]
fn open_root(path: &Path) -> Result<OwnedFd, String> {
    let path = CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| "Carpeta inválida")?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("Carpeta autorizada no disponible".into());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

#[cfg(unix)]
fn open_parent(
    root_fd: &OwnedFd,
    parts: &[String],
    create: bool,
) -> Result<Option<OwnedFd>, String> {
    let fd = unsafe { libc::fcntl(root_fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err("No se puede abrir la carpeta autorizada".into());
    }
    let mut parent = unsafe { OwnedFd::from_raw_fd(fd) };
    for part in &parts[..parts.len() - 1] {
        let name = CString::new(part.as_str()).map_err(|_| "Ruta inválida")?;
        let mut next = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if next < 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT)
            && create
        {
            let made = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
            if made < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST) {
                return Err("No se puede crear la carpeta de destino".into());
            }
            next = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if next >= 0 && unsafe { libc::fsync(parent.as_raw_fd()) } < 0 {
                unsafe { libc::close(next) };
                return Err("No se puede sincronizar la carpeta".into());
            }
        }
        if next < 0 {
            if !create && std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
                return Ok(None);
            }
            return Err("Ruta fuera de la carpeta autorizada o enlace simbólico".into());
        }
        parent = unsafe { OwnedFd::from_raw_fd(next) };
    }
    Ok(Some(parent))
}

#[cfg(unix)]
fn read_current(root_fd: &OwnedFd, parts: &[String]) -> Result<Option<String>, String> {
    let Some(parent) = open_parent(root_fd, parts, false)? else {
        return Ok(None);
    };
    let name =
        CString::new(parts.last().ok_or("Ruta inválida")?.as_str()).map_err(|_| "Ruta inválida")?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        if std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
            return Ok(None);
        }
        return Err("Archivo fuera de la carpeta autorizada o enlace simbólico".into());
    }
    let mut file = fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let metadata = file.metadata().map_err(|_| "No se puede leer el archivo")?;
    if !metadata.is_file() {
        return Err("Solo se permiten archivos normales".into());
    }
    if metadata.len() > FILE_LIMIT as u64 {
        return Err("Archivo supera 64 MiB".into());
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take((FILE_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "No se puede leer el archivo")?;
    if bytes.len() > FILE_LIMIT {
        return Err("Archivo supera 64 MiB".into());
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| "Solo se permiten archivos UTF-8".into())
}

#[cfg(unix)]
fn write_change(root_fd: &OwnedFd, change: &FileChange) -> Result<(), String> {
    let Some(parent) = open_parent(root_fd, &change.components, change.contents.is_some())? else {
        return Ok(());
    };
    let name = CString::new(change.components.last().ok_or("Ruta inválida")?.as_str())
        .map_err(|_| "Ruta inválida")?;
    if let Some(contents) = &change.contents {
        let temp_name = CString::new(format!(".escriba-{}", uuid::Uuid::new_v4()))
            .map_err(|_| "Ruta temporal inválida")?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                temp_name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err("No se puede crear archivo temporal".into());
        }
        let mut file = fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
        let result = (|| {
            file.write_all(contents.as_bytes())
                .map_err(|_| "No se puede escribir archivo")?;
            file.sync_all()
                .map_err(|_| "No se puede sincronizar archivo")?;
            let renamed = unsafe {
                libc::renameat(
                    parent.as_raw_fd(),
                    temp_name.as_ptr(),
                    parent.as_raw_fd(),
                    name.as_ptr(),
                )
            };
            if renamed < 0 {
                return Err("No se puede sustituir archivo".into());
            }
            if unsafe { libc::fsync(parent.as_raw_fd()) } < 0 {
                return Err("No se puede sincronizar carpeta".into());
            }
            Ok(())
        })();
        unsafe { libc::unlinkat(parent.as_raw_fd(), temp_name.as_ptr(), 0) };
        result
    } else {
        let removed = unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) };
        if removed < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT) {
            return Err("No se puede borrar archivo".into());
        }
        if unsafe { libc::fsync(parent.as_raw_fd()) } < 0 {
            return Err("No se puede sincronizar carpeta".into());
        }
        Ok(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn archivo_okf_autorizado_acepta_md_real_y_rechaza_escape_por_enlace() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("bundle");
        fs::create_dir(&folder).unwrap();
        let inside = folder.join("nota.md");
        fs::write(&inside, b"synthetic").unwrap();
        let outside = temp.path().join("outside.md");
        fs::write(&outside, b"synthetic").unwrap();
        std::os::unix::fs::symlink(&outside, folder.join("escape.md")).unwrap();
        let account = json!({"provider":"okf","folder":folder});
        assert_eq!(
            authorized_okf_file(&account, &inside).unwrap(),
            inside.canonicalize().unwrap()
        );
        assert!(authorized_okf_file(&account, &folder.join("escape.md")).is_err());
        assert!(authorized_okf_file(&account, &outside).is_err());
    }
    #[cfg(unix)]
    use std::os::unix::fs::symlink;

    #[test]
    #[cfg(unix)]
    fn files_preflights_cas_and_blocks_escape_and_symlinks() {
        let folder = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::write(folder.path().join("note.md"), "old").unwrap();
        fs::write(folder.path().join("ignored.txt"), "not markdown").unwrap();
        fs::write(outside.path().join("secret.md"), "private").unwrap();
        let account = json!({"enabled":true,"folder":folder.path().to_str().unwrap()});
        let snapshot = files(&account, &json!({"operation":"snapshot"})).unwrap();
        assert_eq!(snapshot, json!({"note.md":"old"}));
        let failed = files(
            &account,
            &json!({"operation":"apply","changes":[
                {"path":"new.md","contents":"new","expectedContents":null},
                {"path":"note.md","contents":"changed","expectedContents":"stale"}
            ]}),
        );
        assert!(failed.is_err());
        assert!(!folder.path().join("new.md").exists());
        assert_eq!(
            fs::read_to_string(folder.path().join("note.md")).unwrap(),
            "old"
        );
        assert!(files(
            &account,
            &json!({"operation":"apply","changes":[
                {"path":"../secret.md","contents":"bad"}
            ]})
        )
        .is_err());
        symlink(outside.path(), folder.path().join("linked")).unwrap();
        assert!(files(&account, &json!({"operation":"snapshot"})).is_err());
        assert!(files(
            &account,
            &json!({"operation":"apply","changes":[
                {"path":"linked/secret.md","contents":"bad"}
            ]})
        )
        .is_err());
        assert_eq!(
            fs::read_to_string(outside.path().join("secret.md")).unwrap(),
            "private"
        );
        fs::remove_file(folder.path().join("linked")).unwrap();
        files(
            &account,
            &json!({"operation":"apply","changes":[
                {"path":"note.md","contents":"changed","expectedContents":"old"},
                {"path":"new.md","contents":"new","expectedContents":null}
            ]}),
        )
        .unwrap();
        assert_eq!(
            files(&account, &json!({"operation":"snapshot"})).unwrap(),
            json!({"note.md":"changed","new.md":"new"})
        );
    }
}

#[cfg(windows)]
fn open_root(path: &Path) -> Result<OwnedFd, String> {
    let (_, locks) = crate::windows_files::parents(path, &["probe".into()], false)?;
    Ok(OwnedFd {
        path: path.to_owned(),
        _locks: locks,
    })
}
#[cfg(windows)]
fn read_current(root: &OwnedFd, parts: &[String]) -> Result<Option<String>, String> {
    let path = parts
        .iter()
        .fold(root.path.clone(), |path, part| path.join(part));
    if !path.exists() {
        return Ok(None);
    }
    let (path, _locks) = crate::windows_files::parents(&root.path, parts, false)?;
    let mut file = crate::file_security::open_regular(&path).map_err(|error| error.to_string())?;
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take((FILE_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > FILE_LIMIT {
        return Err("Archivo supera 64 MiB".into());
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| "Solo se permiten archivos UTF-8".into())
}
#[cfg(windows)]
fn write_change(root: &OwnedFd, change: &FileChange) -> Result<(), String> {
    let path = change
        .components
        .iter()
        .fold(root.path.clone(), |path, part| path.join(part));
    if change.contents.is_none() && !path.exists() {
        return Ok(());
    }
    let (path, _locks) =
        crate::windows_files::parents(&root.path, &change.components, change.contents.is_some())?;
    if let Some(contents) = &change.contents {
        crate::util::atomic_write(&path, contents.as_bytes())
    } else {
        fs::remove_file(path).map_err(|error| error.to_string())
    }
}
