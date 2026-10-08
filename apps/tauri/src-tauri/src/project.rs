//! TypeScript project creation, confined source access, and esbuild packaging.
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use walkdir::WalkDir;

const TYPES: &str = include_str!("../../../../recetas/escriba-recetas.d.ts");
const EXAMPLE: &str = include_str!("../../../../recetas/por-defecto/receta.ts");
const SOURCE_LIMIT: usize = 8 * 1024 * 1024;
const BUNDLE_LIMIT: usize = 32 * 1024 * 1024;
const ERROR_LIMIT: usize = 8 * 1024;
const BUILD_TIMEOUT: Duration = Duration::from_secs(30);

/// Creates only missing project files. Existing source and dependencies stay untouched.
pub fn initialize(path: &Path, accounts: &Value, vendor: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("La carpeta del proyecto debe ser absoluta".into());
    }
    fs::create_dir_all(path).map_err(|_| "No se pudo crear la carpeta del proyecto")?;
    let root = project_root(path)?;
    install_managed_connector(&root, vendor)?;
    write_new(
        &root.join("package.json"),
        r#"{
  "name": "escriba-project",
  "private": true,
  "type": "module",
  "dependencies": {
    "@escriba/conectores": "file:.escriba/deps/conectores",
    "zod": "4.6.5"
  }
}
"#,
    )?;
    write_new(
        &root.join("tsconfig.json"),
        r#"{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "baseUrl": ".",
    "paths": { "@escriba/conectores": [".escriba/deps/conectores/index.d.ts"] }
  },
  "include": ["**/*.ts", "escriba-recetas.d.ts"],
  "exclude": ["node_modules", ".git", ".escriba"]
}
"#,
    )?;
    write_new(&root.join("escriba-recetas.d.ts"), TYPES)?;
    let examples = root.join("ejemplos");
    match fs::create_dir(&examples) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err("No se pudo crear ejemplos".into()),
    }
    let kind = fs::symlink_metadata(&examples).map_err(|_| "No se pudo inspeccionar ejemplos")?;
    if !kind.is_dir() || kind.file_type().is_symlink() {
        return Err("ejemplos debe ser una carpeta real".into());
    }
    write_new(&root.join("ejemplos/receta.ts"), EXAMPLE)?;
    write_new(&root.join("conectores.ts"), &connector_source(accounts)?)?;
    Ok(())
}

/// Bundles recipes and connectors. Caller installs the returned catalog atomically after inspection.
pub fn build(path: &Path, compiler: &Path, vendor: &Path) -> Result<Value, String> {
    let root = project_root(path)?;
    if !compiler.is_file() {
        return Err("No está disponible el compilador esbuild".into());
    }
    let vendor_modules = if vendor.join("node_modules").is_dir() {
        vendor.join("node_modules")
    } else {
        vendor.to_path_buf()
    };
    let vendor_real = fs::canonicalize(&vendor_modules)
        .map_err(|_| "No están disponibles las dependencias incluidas")?;
    let mut entries = BTreeMap::<String, String>::new();
    let walker = WalkDir::new(&root)
        .follow_links(false)
        .into_iter()
        .filter_entry(|item| {
            item.depth() == 0
                || !item.file_type().is_dir()
                || !excluded(item.file_name().to_str().unwrap_or(""))
        });
    for item in walker {
        let item = item.map_err(|_| "No se pudo recorrer el proyecto")?;
        if item.file_type().is_symlink() {
            continue;
        }
        if !item.file_type().is_file()
            || !["receta.ts", "receta.js"].contains(&item.file_name().to_str().unwrap_or(""))
        {
            continue;
        }
        let relative = item
            .path()
            .strip_prefix(&root)
            .map_err(|_| "Receta fuera del proyecto")?;
        let entry = relative
            .to_str()
            .ok_or("Ruta de receta no UTF-8")?
            .replace('\\', "/");
        checked_entry(&root, &entry, false)?;
        let directory = Path::new(&entry)
            .parent()
            .and_then(Path::to_str)
            .unwrap_or("")
            .to_owned();
        if entry.ends_with(".ts") || !entries.contains_key(&directory) {
            entries.insert(directory, entry);
        }
    }
    if entries.len() > 10_000 {
        return Err("El proyecto supera 10000 recetas".into());
    }
    let mut recipes = Vec::with_capacity(entries.len());
    for (directory, entry) in entries {
        let bundle = compile(&root, compiler, &vendor_real, &entry, "__recipe")?;
        let id = match directory.strip_prefix("recetas/") {
            Some(key) if !key.is_empty() && !key.contains('/') => key.to_owned(),
            _ => format!("code:{}", directory.replace('/', ":")),
        };
        let name = Path::new(&directory)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("Receta");
        recipes.push(
            json!({"id":id,"name":name,"kind":"code","values":{},"entry":entry,"bundle":bundle}),
        );
    }
    let connector_program = if root.join("conectores.ts").exists() {
        checked_entry(&root, "conectores.ts", false)?;
        Some(compile(
            &root,
            compiler,
            &vendor_real,
            "conectores.ts",
            "__conectores",
        )?)
    } else {
        None
    };
    Ok(json!({"recipes":recipes,"destinations":[],"connectorProgram":connector_program}))
}

/// Reads a project file selected by its relative entry path.
pub fn read(path: &Path, entry: &str) -> Result<Value, String> {
    let root = project_root(path)?;
    let components = checked_entry(&root, entry, false)?;
    let root_fd = open_root(&root)?;
    let parent = open_parent(&root_fd, &components, false)?.ok_or("La fuente no existe")?;
    let name = c_name(components.last().ok_or("Ruta inválida")?)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("La fuente no existe o es un enlace simbólico".into());
    }
    let mut file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let metadata = file.metadata().map_err(|_| "No se pudo leer la fuente")?;
    if !metadata.is_file() || metadata.len() > SOURCE_LIMIT as u64 {
        return Err("Fuente inválida o supera 8 MiB".into());
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take((SOURCE_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "No se pudo leer la fuente")?;
    if bytes.len() > SOURCE_LIMIT {
        return Err("La fuente supera 8 MiB".into());
    }
    let source = String::from_utf8(bytes).map_err(|_| "La fuente no es UTF-8")?;
    Ok(json!({"source":source}))
}

/// Atomically replaces one project source after checking the path under the chosen folder.
pub fn write(path: &Path, entry: &str, source: &str) -> Result<(), String> {
    if source.len() > SOURCE_LIMIT {
        return Err("La fuente supera 8 MiB".into());
    }
    let root = project_root(path)?;
    let components = checked_entry(&root, entry, true)?;
    let root_fd = open_root(&root)?;
    let parent = open_parent(&root_fd, &components, true)?.ok_or("Ruta inválida")?;
    let name = c_name(components.last().ok_or("Ruta inválida")?)?;
    let temporary = c_name(&format!(".escriba-{}", uuid::Uuid::new_v4()))?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            temporary.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err("No se pudo crear archivo temporal".into());
    }
    let mut file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let outcome = (|| {
        file.write_all(source.as_bytes())
            .map_err(|_| "No se pudo escribir la fuente")?;
        file.sync_all()
            .map_err(|_| "No se pudo sincronizar la fuente")?;
        if unsafe {
            libc::renameat(
                parent.as_raw_fd(),
                temporary.as_ptr(),
                parent.as_raw_fd(),
                name.as_ptr(),
            )
        } < 0
        {
            return Err("No se pudo reemplazar la fuente");
        }
        if unsafe { libc::fsync(parent.as_raw_fd()) } < 0 {
            return Err("No se pudo sincronizar la carpeta");
        }
        Ok(())
    })();
    unsafe { libc::unlinkat(parent.as_raw_fd(), temporary.as_ptr(), 0) };
    outcome.map_err(str::to_owned)
}

fn connector_source(accounts: &Value) -> Result<String, String> {
    let mut definitions = Vec::new();
    for account in accounts.as_array().ok_or("Catálogo de cuentas inválido")? {
        if account.get("enabled").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        let id = account
            .get("id")
            .and_then(Value::as_str)
            .ok_or("Cuenta sin ID")?;
        let name = account
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("Destino");
        let provider = account
            .get("provider")
            .and_then(Value::as_str)
            .ok_or("Cuenta sin proveedor")?;
        let configuration = match provider {
            "okf" => match account
                .get("folder")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                Some(folder) => json!({"folder":folder}),
                None => continue,
            },
            "notion" => {
                if account
                    .get("origin")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .is_none()
                {
                    continue;
                }
                json!({"source":{"id":"","title":"","databaseTitle":"","properties":[]},"columns":{},"body":"{{transcripcion}}"})
            }
            _ => continue,
        };
        definitions.push(json!({"id":format!("{id}-destino"),"name":name,"provider":provider,"account":id,"configuration":configuration}));
    }
    let definitions = serde_json::to_string_pretty(&definitions)
        .map_err(|_| "No se pudo crear el catálogo de conectores")?;
    Ok(format!("import {{ createProgram }} from \"@escriba/conectores\";\n\nconst program = createProgram({definitions});\nexport const inspect = program.inspect;\nexport const run = program.run;\n"))
}

fn write_new(path: &Path, source: &str) -> Result<(), String> {
    match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(mut file) => {
            file.write_all(source.as_bytes())
                .map_err(|_| "No se pudo inicializar el proyecto")?;
            file.sync_all()
                .map_err(|_| "No se pudo sincronizar el proyecto".to_owned())
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(_) => Err("No se pudo inicializar el proyecto".into()),
    }
}

fn vendor_modules(vendor: &Path) -> PathBuf {
    if vendor.join("node_modules").is_dir() {
        vendor.join("node_modules")
    } else {
        vendor.to_path_buf()
    }
}

fn install_managed_connector(root: &Path, vendor: &Path) -> Result<(), String> {
    let source = vendor_modules(vendor).join("@escriba/conectores");
    let source = fs::canonicalize(source).map_err(|_| "Falta el paquete incluido de conectores")?;
    if !source.is_dir()
        || !source.join("index.js").is_file()
        || !source.join("index.d.ts").is_file()
    {
        return Err("El paquete incluido de conectores está incompleto".into());
    }
    let managed = root.join(".escriba");
    real_directory(&managed)?;
    let deps = managed.join("deps");
    real_directory(&deps)?;
    let destination = deps.join("conectores");
    if destination.exists() {
        let kind =
            fs::symlink_metadata(&destination).map_err(|_| "Dependencia administrada inválida")?;
        if !kind.is_dir()
            || kind.file_type().is_symlink()
            || !destination.join("index.js").is_file()
            || !destination.join("index.d.ts").is_file()
        {
            return Err("Dependencia administrada inválida".into());
        }
        return Ok(());
    }
    let temporary = deps.join(format!(".conectores-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&temporary).map_err(|_| "No se pudo preparar la dependencia")?;
    let result = (|| {
        for item in WalkDir::new(&source).follow_links(false) {
            let item = item.map_err(|_| "No se pudo leer la dependencia incluida")?;
            let relative = item
                .path()
                .strip_prefix(&source)
                .map_err(|_| "Dependencia incluida inválida")?;
            if relative.as_os_str().is_empty() {
                continue;
            }
            let target = temporary.join(relative);
            if item.file_type().is_symlink() {
                return Err("La dependencia incluida contiene un enlace simbólico");
            }
            if item.file_type().is_dir() {
                fs::create_dir(&target).map_err(|_| "No se pudo copiar la dependencia")?;
            } else if item.file_type().is_file() {
                let size = item
                    .metadata()
                    .map_err(|_| "No se pudo leer la dependencia")?
                    .len();
                if size > BUNDLE_LIMIT as u64 {
                    return Err("Archivo de dependencia supera 32 MiB");
                }
                fs::copy(item.path(), &target).map_err(|_| "No se pudo copiar la dependencia")?;
            } else {
                return Err("Tipo de archivo de dependencia inválido");
            }
        }
        fs::rename(&temporary, &destination).map_err(|_| "No se pudo instalar la dependencia")?;
        File::open(&deps)
            .and_then(|dir| dir.sync_all())
            .map_err(|_| "No se pudo sincronizar la dependencia")?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&temporary);
    }
    result.map_err(str::to_owned)
}

fn real_directory(path: &Path) -> Result<(), String> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err("No se pudo crear la carpeta administrada".into()),
    }
    let kind = fs::symlink_metadata(path).map_err(|_| "Carpeta administrada inválida")?;
    if !kind.is_dir() || kind.file_type().is_symlink() {
        return Err("Carpeta administrada inválida".into());
    }
    Ok(())
}

fn excluded(name: &str) -> bool {
    matches!(name, ".git" | "node_modules" | ".escriba")
}

fn project_root(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err("La carpeta del proyecto debe ser absoluta".into());
    }
    let root = fs::canonicalize(path).map_err(|_| "La carpeta del proyecto no existe")?;
    if !root.is_dir() {
        return Err("La ruta del proyecto no es una carpeta".into());
    }
    Ok(root)
}

fn checked_entry(root: &Path, entry: &str, allow_missing: bool) -> Result<Vec<String>, String> {
    checked_source(root, entry, allow_missing, false)
}

fn checked_source(
    root: &Path,
    entry: &str,
    allow_missing: bool,
    dependency: bool,
) -> Result<Vec<String>, String> {
    if entry.is_empty() || entry.starts_with('/') || entry.contains(['\\', '\0']) {
        return Err("Ruta de proyecto no permitida".into());
    }
    let parts: Vec<String> = entry.split('/').map(str::to_owned).collect();
    if parts.iter().any(|part| {
        part.is_empty()
            || part == "."
            || part == ".."
            || (excluded(part) && !(dependency && part == "node_modules"))
    }) {
        return Err("Ruta de proyecto no permitida".into());
    }
    let mut current = root.to_path_buf();
    for (index, part) in parts.iter().enumerate() {
        current.push(part);
        match fs::symlink_metadata(&current) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink()
                    || (index + 1 < parts.len() && !metadata.is_dir())
                    || (index + 1 == parts.len() && !metadata.is_file())
                {
                    return Err("La ruta contiene un enlace simbólico o tipo inválido".into());
                }
            }
            Err(error) if allow_missing && error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("La fuente no existe".into()),
        }
    }
    Ok(parts)
}

fn c_name(name: &str) -> Result<CString, String> {
    CString::new(name).map_err(|_| "Ruta inválida".into())
}

fn open_root(path: &Path) -> Result<OwnedFd, String> {
    use std::os::unix::ffi::OsStrExt;
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| "Ruta inválida")?;
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("No se pudo abrir el proyecto".into());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn open_parent(root: &OwnedFd, parts: &[String], create: bool) -> Result<Option<OwnedFd>, String> {
    let fd = unsafe { libc::fcntl(root.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if fd < 0 {
        return Err("No se pudo abrir el proyecto".into());
    }
    let mut parent = unsafe { OwnedFd::from_raw_fd(fd) };
    for part in &parts[..parts.len() - 1] {
        let name = c_name(part)?;
        let mut next = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if next < 0
            && create
            && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
        {
            if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
            {
                return Err("No se pudo crear la carpeta de fuente".into());
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
                return Err("No se pudo sincronizar la carpeta".into());
            }
        }
        if next < 0 {
            if !create && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
                return Ok(None);
            }
            return Err("Ruta de fuente fuera del proyecto o enlace simbólico".into());
        }
        parent = unsafe { OwnedFd::from_raw_fd(next) };
    }
    Ok(Some(parent))
}

fn compile(
    root: &Path,
    compiler: &Path,
    vendor: &Path,
    entry: &str,
    global: &str,
) -> Result<String, String> {
    let metadata = std::env::temp_dir().join(format!("escriba-{}.json", uuid::Uuid::new_v4()));
    let result = run_compiler(root, compiler, vendor, entry, global, &metadata);
    let _ = fs::remove_file(&metadata);
    result
}

fn run_compiler(
    root: &Path,
    compiler: &Path,
    vendor: &Path,
    entry: &str,
    global: &str,
    metadata: &Path,
) -> Result<String, String> {
    let mut child = Command::new(compiler)
        .current_dir(root)
        .env("NODE_PATH", vendor)
        .args([
            entry,
            "--bundle",
            "--format=iife",
            "--platform=browser",
            "--target=es2022",
            "--log-level=error",
            "--charset=utf8",
            "--outfile=/dev/stdout",
        ])
        .arg(format!("--global-name={global}"))
        .arg(format!("--metafile={}", metadata.display()))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .spawn()
        .map_err(|_| "No se pudo iniciar esbuild")?;
    let stdout = child.stdout.take().ok_or("Sin salida de esbuild")?;
    let stderr = child.stderr.take().ok_or("Sin errores de esbuild")?;
    let output_reader = thread::spawn(move || bounded_output(stdout, BUNDLE_LIMIT));
    let error_reader = thread::spawn(move || bounded_output(stderr, ERROR_LIMIT));
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|_| "No se pudo esperar a esbuild")?
        {
            break status;
        }
        if started.elapsed() >= BUILD_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err("esbuild superó 30 segundos".into());
        }
        thread::sleep(Duration::from_millis(20));
    };
    let output = output_reader
        .join()
        .map_err(|_| "Falló la lectura de esbuild")??;
    let errors = error_reader
        .join()
        .map_err(|_| "Falló la lectura de esbuild")??;
    if !status.success() {
        let detail = String::from_utf8_lossy(&errors.bytes);
        return Err(format!("esbuild: {}", detail.trim()));
    }
    if output.truncated {
        return Err("El paquete supera 32 MiB".into());
    }
    let bundle = String::from_utf8(output.bytes).map_err(|_| "El paquete no es UTF-8")?;
    if bundle.is_empty() {
        return Err("esbuild no devolvió un paquete".into());
    }
    validate_inputs(root, vendor, metadata)?;
    Ok(bundle)
}

struct LimitedOutput {
    bytes: Vec<u8>,
    truncated: bool,
}
fn bounded_output(mut stream: impl Read, limit: usize) -> Result<LimitedOutput, String> {
    let mut bytes = Vec::new();
    let mut truncated = false;
    let mut chunk = [0u8; 8192];
    loop {
        let count = stream
            .read(&mut chunk)
            .map_err(|_| "No se pudo leer esbuild")?;
        if count == 0 {
            break;
        }
        let allowed = limit.saturating_sub(bytes.len()).min(count);
        bytes.extend_from_slice(&chunk[..allowed]);
        if allowed < count {
            truncated = true;
        }
    }
    Ok(LimitedOutput { bytes, truncated })
}

fn validate_inputs(root: &Path, vendor: &Path, metadata: &Path) -> Result<(), String> {
    let bundled_connector = fs::canonicalize(vendor.join("@escriba/conectores")).ok();
    let bundled_zod = fs::canonicalize(vendor.join("zod")).ok();
    let managed_connector = fs::canonicalize(root.join(".escriba/deps/conectores")).ok();
    let info = fs::metadata(metadata).map_err(|_| "esbuild no informó sus fuentes")?;
    if info.len() > BUNDLE_LIMIT as u64 {
        return Err("Metadatos de esbuild superan 32 MiB".into());
    }
    let report: Value = serde_json::from_slice(
        &fs::read(metadata).map_err(|_| "No se pudo leer el mapa de fuentes")?,
    )
    .map_err(|_| "Mapa de fuentes inválido")?;
    let inputs = report
        .get("inputs")
        .and_then(Value::as_object)
        .ok_or("Sin mapa de fuentes")?;
    for input in inputs.keys() {
        let candidate =
            fs::canonicalize(root.join(input)).map_err(|_| "Fuente del paquete no disponible")?;
        if !candidate.starts_with(root)
            && !candidate.starts_with(vendor)
            && !bundled_connector
                .as_ref()
                .is_some_and(|path| candidate.starts_with(path))
            && !bundled_zod
                .as_ref()
                .is_some_and(|path| candidate.starts_with(path))
        {
            return Err("El paquete importa una fuente fuera del proyecto o vendor".into());
        }
        // Project source files may not be symlinks; vendor is app-managed.
        if candidate.starts_with(root) {
            let lexical = root.join(input);
            let relative = lexical.strip_prefix(root).map_err(|_| "Fuente inválida")?;
            let relative = relative
                .to_str()
                .ok_or("Fuente no UTF-8")?
                .replace('\\', "/");
            let installed_managed = (relative.starts_with("node_modules/@escriba/conectores/")
                || relative.starts_with(".escriba/deps/conectores/"))
                && managed_connector
                    .as_ref()
                    .is_some_and(|path| candidate.starts_with(path));
            if !installed_managed {
                checked_source(
                    root,
                    &relative,
                    false,
                    relative.starts_with("node_modules/"),
                )?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::symlink,
        sync::{Arc, Mutex},
    };

    fn bundled_source() -> PathBuf {
        std::env::var_os("ESCRIBA_PROJECT_TEST_CONNECTOR_SOURCE")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../../Sources/EscribaJSC/Resources/conectores")
            })
    }

    fn installed_nodes() -> PathBuf {
        std::env::var_os("ESCRIBA_PROJECT_TEST_VENDOR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .parent()
                    .unwrap()
                    .join("node_modules")
            })
    }

    fn test_vendor() -> tempfile::TempDir {
        let folder = tempfile::tempdir().unwrap();
        let nodes = folder.path().join("node_modules");
        fs::create_dir_all(nodes.join("@escriba")).unwrap();
        symlink(bundled_source(), nodes.join("@escriba/conectores")).unwrap();
        symlink(installed_nodes().join("zod"), nodes.join("zod")).unwrap();
        folder
    }

    #[test]
    fn initialization_preserves_existing_files_and_confines_source_access() {
        let folder = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let vendor = test_vendor();
        fs::write(folder.path().join("conectores.ts"), "// personalizado").unwrap();
        initialize(folder.path(), &json!([]), vendor.path()).unwrap();
        assert_eq!(
            fs::read_to_string(folder.path().join("conectores.ts")).unwrap(),
            "// personalizado"
        );
        assert!(folder.path().join("ejemplos/receta.ts").exists());
        assert!(folder.path().join("escriba-recetas.d.ts").exists());
        let dependency = folder.path().join(".escriba/deps/conectores");
        assert!(dependency.join("index.js").is_file());
        assert!(!fs::symlink_metadata(&dependency)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(folder.path().join("package.json")).unwrap())
                .unwrap()["dependencies"]["@escriba/conectores"],
            "file:.escriba/deps/conectores"
        );
        assert!(read(folder.path(), "../fuera.ts").is_err());
        assert!(write(folder.path(), "../fuera.ts", "mal").is_err());
        fs::write(outside.path().join("secret.ts"), "privado").unwrap();
        symlink(outside.path(), folder.path().join("enlace")).unwrap();
        assert!(read(folder.path(), "enlace/secret.ts").is_err());
        assert!(write(folder.path(), "enlace/secret.ts", "mal").is_err());
        assert_eq!(
            fs::read_to_string(outside.path().join("secret.ts")).unwrap(),
            "privado"
        );
        write(
            folder.path(),
            "nueva/receta.ts",
            "export const receta = { nombre: 'Nueva' }",
        )
        .unwrap();
        assert_eq!(
            read(folder.path(), "nueva/receta.ts").unwrap()["source"],
            "export const receta = { nombre: 'Nueva' }"
        );
    }

    #[test]
    fn build_compiles_real_example_when_esbuild_is_installed() {
        let compiler = installed_nodes().join("@esbuild/darwin-arm64/bin/esbuild");
        if !compiler.is_file() {
            return;
        }
        let vendor = test_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize(folder.path(), &json!([]), vendor.path()).unwrap();
        let result = build(folder.path(), &compiler, vendor.path()).unwrap();
        assert_eq!(result["recipes"][0]["id"], "code:ejemplos");
        assert!(result["recipes"][0]["bundle"]
            .as_str()
            .unwrap()
            .contains("__recipe"));
        assert!(result["connectorProgram"]
            .as_str()
            .unwrap()
            .contains("__conectores"));
        let own_dependency = folder.path().join("node_modules/demo-package");
        fs::create_dir_all(&own_dependency).unwrap();
        fs::write(
            own_dependency.join("package.json"),
            r#"{"name":"demo-package","version":"1.0.0","main":"index.js"}"#,
        )
        .unwrap();
        fs::write(
            own_dependency.join("index.js"),
            "export const marker = 'paquete-del-usuario';",
        )
        .unwrap();
        write(folder.path(), "personal/receta.ts", "import { marker } from 'demo-package'; export const receta = { nombre: marker }; export async function flujo() { console.log(marker) }").unwrap();
        let rebuilt = build(folder.path(), &compiler, vendor.path()).unwrap();
        assert_eq!(rebuilt["recipes"].as_array().unwrap().len(), 2);
        assert!(rebuilt["recipes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|recipe| recipe["bundle"]
                .as_str()
                .unwrap()
                .contains("paquete-del-usuario")));
        fs::create_dir_all(folder.path().join("node_modules/@escriba")).unwrap();
        symlink(
            folder.path().join(".escriba/deps/conectores"),
            folder.path().join("node_modules/@escriba/conectores"),
        )
        .unwrap();
        assert!(build(folder.path(), &compiler, vendor.path()).is_ok());
    }

    #[test]
    fn build_preserva_claves_legacy_js_y_prefiere_ts_del_mismo_directorio() {
        let compiler = installed_nodes().join("@esbuild/darwin-arm64/bin/esbuild");
        if !compiler.is_file() {
            return;
        }
        let vendor = test_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize(folder.path(), &json!([]), vendor.path()).unwrap();
        write(
            folder.path(),
            "recetas/mi-receta/receta.js",
            "export const receta={nombre:'Legacy JS'}; export async function flujo() {} ",
        )
        .unwrap();
        write(
            folder.path(),
            "recetas/doble/receta.js",
            "export const receta={nombre:'IGNORAR JS'}; export async function flujo() {} ",
        )
        .unwrap();
        write(
            folder.path(),
            "recetas/doble/receta.ts",
            "export const receta={nombre:'Preferida TS'}; export async function flujo() {} ",
        )
        .unwrap();
        write(
            folder.path(),
            "personal/receta.js",
            "export const receta={nombre:'Personal'}; export async function flujo() {} ",
        )
        .unwrap();
        let result = build(folder.path(), &compiler, vendor.path()).unwrap();
        let recipes = result["recipes"].as_array().unwrap();
        assert_eq!(recipes.len(), 4);
        assert!(recipes.iter().any(|recipe| recipe["id"] == "mi-receta"
            && recipe["entry"] == "recetas/mi-receta/receta.js"
            && recipe["bundle"].as_str().unwrap().contains("__recipe")));
        assert!(recipes.iter().any(|recipe| recipe["id"] == "doble"
            && recipe["entry"] == "recetas/doble/receta.ts"
            && recipe["bundle"].as_str().unwrap().contains("Preferida TS")
            && !recipe["bundle"].as_str().unwrap().contains("IGNORAR JS")));
        assert!(recipes.iter().any(
            |recipe| recipe["id"] == "code:personal" && recipe["entry"] == "personal/receta.js"
        ));
        assert!(recipes.iter().any(|recipe| recipe["id"] == "code:ejemplos"));
    }

    #[tokio::test]
    async fn paquete_legacy_js_ejecuta_flujo_en_sidecar_compilado() {
        let compiler = installed_nodes().join("@esbuild/darwin-arm64/bin/esbuild");
        if !compiler.is_file() {
            return;
        }
        let vendor = test_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize(folder.path(), &json!([]), vendor.path()).unwrap();
        write(folder.path(), "recetas/mi-receta/receta.js", "export const receta={nombre:'Mi receta heredada'}; export async function flujo(audio,escriba){ const nota=await escriba.transcribir(audio); await nota.guardar(); }").unwrap();
        let recipes = build(folder.path(), &compiler, vendor.path()).unwrap()["recipes"].clone();
        let state = Arc::new(Mutex::new(json!({
            "recordings":[{"id":"r","title":"Nota","createdAt":"2026-10-09T10:00:00Z","source":"sintético","audioPath":"/opaque","duration":0,"status":"pending","versions":[],"publications":[]}],
            "resolvers":[{"id":"local-stt","name":"Whisper","role":"stt","local":true,"enabled":true},{"id":"local-llm","name":"Apple","role":"llm","local":true,"enabled":true}],
            "recipes":recipes,"accounts":[],"destinations":[],
            "settings":{"defaultRecipeId":"mi-receta","projectPath":null,"watchedFolders":[],"language":"es","whisperModel":"large","autoProcess":false,"launchAtLogin":false,"theme":"system"},
            "logs":[],"dataPath":"/synthetic"
        })));
        let capability: crate::scripts::Capability = {
            let state = state.clone();
            Arc::new(move |method, params, _, lease| {
                let state = state.clone();
                Box::pin(async move {
                    lease.ensure_active()?;
                    let mut snapshot = state.lock().unwrap();
                    let record = &mut snapshot["recordings"][0];
                    match method.as_str() {
                        "snapshot" => Ok(snapshot.clone()),
                        "transcribe" => Ok(json!({"text":"Audio sintético","segments":[]})),
                        "version_save" => {
                            let mut version = params.clone();
                            version["id"] = json!("v1");
                            version["createdAt"] = json!("now");
                            record["versions"]
                                .as_array_mut()
                                .unwrap()
                                .push(version.clone());
                            record["currentVersionId"] = json!("v1");
                            Ok(version)
                        }
                        "version_update" => Ok(Value::Null),
                        "version_select" => {
                            record["currentVersionId"] = params["versionId"].clone();
                            Ok(Value::Null)
                        }
                        "recording_update" => {
                            for key in ["status", "error", "recipeId"] {
                                if let Some(value) = params.get(key) {
                                    record[key] = value.clone();
                                }
                            }
                            Ok(record.clone())
                        }
                        "log" | "memory_recall" | "memory_keep" | "trace_save" => Ok(Value::Null),
                        _ => Err(format!("Capacidad inesperada: {method}")),
                    }
                })
            })
        };
        let scripts =
            crate::scripts::Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        let events: crate::scripts::Events = Arc::new(|_| {});
        let schema = scripts
            .call(
                "legacy-schema",
                "getRecipeSchema",
                json!({"recipeId":"mi-receta"}),
                capability.clone(),
                events.clone(),
            )
            .await
            .unwrap();
        assert_eq!(schema["type"], "object");
        scripts
            .call(
                "legacy-run",
                "processRecording",
                json!({"recordingId":"r","options":{"force":false}}),
                capability,
                events,
            )
            .await
            .unwrap();
        let saved = state.lock().unwrap();
        assert_eq!(saved["recordings"][0]["status"], "done");
        assert_eq!(
            saved["recordings"][0]["versions"].as_array().unwrap().len(),
            1
        );
    }

    #[test]
    fn build_rejects_imports_outside_project() {
        let compiler = installed_nodes().join("@esbuild/darwin-arm64/bin/esbuild");
        if !compiler.is_file() {
            return;
        }
        let vendor = test_vendor();
        let base = tempfile::tempdir().unwrap();
        let project = base.path().join("project");
        initialize(&project, &json!([]), vendor.path()).unwrap();
        fs::write(
            base.path().join("outside.ts"),
            "export const secret = 'outside';",
        )
        .unwrap();
        write(&project, "evil/receta.ts", "import { secret } from '../../outside.ts'; export const receta = { nombre: secret }; export async function flujo() { console.log(secret) }").unwrap();
        assert!(build(&project, &compiler, vendor.path())
            .unwrap_err()
            .contains("fuera del proyecto"));
    }
}
