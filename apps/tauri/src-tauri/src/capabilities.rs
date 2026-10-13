//! Narrow authority granted to connector programs by the Rust host.
use reqwest::Url;
use serde_json::{json, Map, Value};
use std::{
    collections::HashSet,
    ffi::CString,
    fs,
    io::{Read, Write},
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    path::{Path, PathBuf},
};

const FILE_LIMIT: usize = 64 * 1024 * 1024;
const FILE_COUNT_LIMIT: usize = 10_000;

pub fn validate_access(access: &Value) -> Result<(), String> {
    match required_str(access, "capability")? {
        "http" => {
            parse_origin(required_str(access, "origin")?)?;
            let allowed = access["allowedHeaders"]
                .as_array()
                .ok_or("Cabeceras autorizadas inválidas")?;
            for value in allowed {
                let header = value.as_str().ok_or("Cabecera autorizada inválida")?;
                safe_header_name(header)?;
            }
            if let Some(credential) = access.get("credential") {
                if !credential.is_null() {
                    required_str(credential, "label")?;
                    let header = required_str(credential, "header")?;
                    if !header.eq_ignore_ascii_case("authorization") {
                        safe_header_name(header)?;
                    }
                    if allowed.iter().any(|value| {
                        value
                            .as_str()
                            .is_some_and(|name| name.eq_ignore_ascii_case(header))
                    }) {
                        return Err(
                            "La cabecera de credencial no puede pasar desde la receta".into()
                        );
                    }
                    if let Some(prefix) = credential.get("prefix") {
                        let prefix = prefix.as_str().ok_or("Prefijo de credencial inválido")?;
                        if prefix.contains(['\r', '\n']) {
                            return Err("Prefijo de credencial inválido".into());
                        }
                    }
                    if credential
                        .get("help")
                        .is_some_and(|value| !value.is_string())
                    {
                        return Err("Ayuda de credencial inválida".into());
                    }
                }
            }
        }
        "folder" => {
            if access.get("origin").is_some_and(|value| !value.is_null())
                || access
                    .get("credential")
                    .is_some_and(|value| !value.is_null())
                || access["allowedHeaders"]
                    .as_array()
                    .is_none_or(|headers| !headers.is_empty())
            {
                return Err("Permiso de carpeta inválido".into());
            }
        }
        _ => return Err("Capacidad de proveedor inválida".into()),
    }
    Ok(())
}

pub fn validate_account_grant(grant: &Value) -> Result<(), String> {
    validate_access(grant)?;
    let fields = grant.as_object().ok_or("Autorización inválida")?;
    if fields.keys().any(|key| {
        !["capability", "origin", "allowedHeaders", "credential"].contains(&key.as_str())
    }) {
        return Err("La autorización contiene datos no permitidos".into());
    }
    if let Some(credential) = grant["credential"].as_object() {
        if credential
            .keys()
            .any(|key| !["label", "header", "prefix", "help"].contains(&key.as_str()))
        {
            return Err("La definición de credencial contiene datos no permitidos".into());
        }
    }
    Ok(())
}

pub fn access_equivalent(left: &Value, right: &Value) -> bool {
    if validate_access(left).is_err()
        || validate_access(right).is_err()
        || left["capability"] != right["capability"]
    {
        return false;
    }
    if !same_authority(left, right) {
        return false;
    }
    let headers = |value: &Value| -> Vec<String> {
        let mut names = value["allowedHeaders"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_ascii_lowercase)
            .collect::<Vec<_>>();
        names.sort();
        names.dedup();
        names
    };
    if headers(left) != headers(right) {
        return false;
    }
    true
}

pub fn same_authority(left: &Value, right: &Value) -> bool {
    if left["capability"] != right["capability"] {
        return false;
    }
    if left["capability"] == "http"
        && parse_origin(left["origin"].as_str().unwrap_or(""))
            .ok()
            .map(|url| url.origin())
            != parse_origin(right["origin"].as_str().unwrap_or(""))
                .ok()
                .map(|url| url.origin())
    {
        return false;
    }
    let credential = |value: &Value| -> Option<(String, String)> {
        value["credential"].as_object().map(|credential| {
            (
                credential
                    .get("header")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase(),
                credential
                    .get("prefix")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
            )
        })
    };
    credential(left) == credential(right)
}

fn safe_header_name(header: &str) -> Result<(), String> {
    let name = reqwest::header::HeaderName::from_bytes(header.as_bytes())
        .map_err(|_| "Cabecera HTTP inválida")?;
    let lower = name.as_str();
    if [
        "authorization",
        "proxy-authorization",
        "host",
        "cookie",
        "set-cookie",
        "connection",
        "transfer-encoding",
        "content-length",
        "forwarded",
    ]
    .contains(&lower)
        || lower.starts_with("proxy-")
        || lower.starts_with("sec-")
        || lower.starts_with("x-forwarded-")
    {
        return Err("Cabecera HTTP no permitida".into());
    }
    Ok(())
}

pub fn authorized_access(
    account: &Value,
    provider: Option<&Value>,
    request: &Value,
    capability: &str,
) -> Result<Value, String> {
    ensure_enabled(account)?;
    let canonical_builtin = match account["provider"].as_str() {
        Some("notion") => Some(
            json!({"capability":"http","origin":"https://api.notion.com","allowedHeaders":["accept","content-type","notion-version"],"credential":{"label":"Token","header":"authorization","prefix":"Bearer "}}),
        ),
        Some("okf") => Some(json!({"capability":"folder","allowedHeaders":[]})),
        _ => None,
    };
    let granted = if let Some(grant) = account.get("grant") {
        validate_account_grant(grant)?;
        if canonical_builtin
            .as_ref()
            .is_some_and(|canonical| !access_equivalent(grant, canonical))
        {
            return Err("La autorización de la cuenta no coincide con el proveedor".into());
        }
        grant.clone()
    } else if let Some(canonical) = canonical_builtin {
        canonical
    } else {
        return Err("Cuenta sin autorización".into());
    };
    if granted["capability"] != capability {
        return Err("Capacidad no autorizada para esta cuenta".into());
    }
    if provider.is_some() && request.get("expectedGrant").is_none() {
        return Err("Falta la autorización esperada de la cuenta".into());
    }
    if let Some(expected) = request.get("expectedGrant") {
        if !access_equivalent(expected, &granted) {
            return Err("La autorización de la cuenta cambió".into());
        }
    }
    if let Some(provider) = provider {
        if !access_equivalent(provider, &granted) {
            return Err("La definición del proveedor cambió; reautoriza la cuenta".into());
        }
    }
    Ok(granted)
}

fn parse_origin(raw: &str) -> Result<Url, String> {
    let url = Url::parse(raw).map_err(|_| "Origen HTTP inválido")?;
    if has_userinfo(&url)
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
        || !safe_scheme(&url)
    {
        return Err("Origen HTTP no permitido".into());
    }
    Ok(url)
}

fn safe_scheme(url: &Url) -> bool {
    url.scheme() == "https"
        || (url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "::1" | "[::1]")))
}

fn has_userinfo(url: &Url) -> bool {
    url.as_str().split_once("://").is_some_and(|(_, rest)| {
        rest.split(['/', '?', '#'])
            .next()
            .is_some_and(|authority| authority.contains('@'))
    })
}

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
    if path.starts_with('/') || path.contains('\\') || path.contains('\0') || !path.ends_with(".md")
    {
        return Err("Ruta Markdown no permitida".into());
    }
    let parts: Vec<String> = path.split('/').map(str::to_owned).collect();
    if parts.iter().any(|p| p.is_empty() || p == "." || p == "..") {
        return Err("Ruta relativa no permitida".into());
    }
    Ok(parts)
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
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
    use std::os::unix::fs::symlink;

    #[test]
    fn una_autorizacion_propia_rechaza_proveedor_cambiado_o_cuenta_revocada() {
        let origin = "https://api.example";
        let grant = json!({"capability":"http","origin":origin,"allowedHeaders":["x-version"],"credential":{"label":"Token","header":"x-api-key","prefix":"Key "}});
        let provider = json!({"id":"example","capability":"http","origin":origin,"allowedHeaders":["x-version"],"credential":{"label":"Token","header":"x-api-key","prefix":"Key "}});
        let account = json!({"id":"a","provider":"example","enabled":true,"grant":grant});
        let request = json!({"url":format!("{origin}/items"),"headers":{"x-version":"2026"},"expectedGrant":grant});
        assert_eq!(
            authorized_access(&account, Some(&provider), &request, "http").unwrap(),
            grant
        );
        assert!(parse_origin("http://localhost:1234").is_err());
        let changed = json!({"id":"example","capability":"http","origin":"https://changed.example","allowedHeaders":["x-version"],"credential":{"label":"Token","header":"x-api-key","prefix":"Key "}});
        assert!(authorized_access(&account, Some(&changed), &request, "http").is_err());
        let revoked = json!({"id":"a","provider":"example","enabled":false,"grant":grant});
        assert!(authorized_access(&revoked, Some(&provider), &request, "http").is_err());
    }

    #[test]
    fn cuenta_notion_antigua_acepta_mismo_permiso_con_otra_etiqueta() {
        let account = json!({"id":"old","provider":"notion","origin":"https://api.notion.com","enabled":true});
        let expected = json!({"capability":"http","origin":"https://api.notion.com/","allowedHeaders":["notion-version","Content-Type","accept"],"credential":{"label":"Token de la integración","header":"Authorization","prefix":"Bearer "}});
        let request = json!({"expectedGrant":expected});
        assert!(authorized_access(&account, None, &request, "http").is_ok());
        let changed = json!({"expectedGrant":{"capability":"http","origin":"https://other.example","allowedHeaders":["accept","content-type","notion-version"],"credential":{"label":"Token","header":"authorization","prefix":"Bearer "}}});
        assert!(authorized_access(&account, None, &changed, "http").is_err());
        let disclosed = json!({"capability":"http","origin":"https://api.notion.com","allowedHeaders":[],"credential":{"label":"Token","header":"authorization","value":"synthetic-secret"}});
        assert!(validate_account_grant(&disclosed).is_err());
    }

    #[test]
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
