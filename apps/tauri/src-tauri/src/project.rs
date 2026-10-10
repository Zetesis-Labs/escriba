//! TypeScript project creation, confined source access, and Bun artifacts.
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
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
const MANIFEST_LIMIT: usize = 1024 * 1024;
const CATALOG_LIMIT: usize = 30 * 1024 * 1024;
const TOOL_OUTPUT_LIMIT: usize = 64 * 1024;
const TOOL_TIMEOUT: Duration = Duration::from_secs(60);
const DEV_SANDBOX: &str = "(version 1)\n(deny default)\n(allow process-exec (literal (param \"EXECUTABLE\")))\n(allow file-read* (literal \"/\") (literal (param \"EXECUTABLE\")) (subpath (param \"PROJECT\")) (subpath (param \"VENDOR\")) (subpath \"/System/Library\") (subpath \"/usr/lib\") (subpath \"/usr/share/icu\"))\n(allow file-read-metadata (literal \"/var\") (literal \"/tmp\"))\n(allow file-write* (subpath (param \"PROJECT\")))\n(allow sysctl-read)\n";
const INSTALL_NETWORK: &str = "(allow network-outbound)\n";
const LAUNCHER_MARKER: &str = "#!/bin/sh\nESCRIBA_LAUNCHER_VERSION=1\n";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    recipes: Vec<ManifestRecipe>,
    connectors: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestRecipe {
    id: String,
    name: String,
    entry: String,
    file: String,
}

pub fn load(path: &Path) -> Result<Value, String> {
    let root = project_root(path)?;
    let dist = root.join("dist");
    let metadata = fs::symlink_metadata(&dist).map_err(|_| "No existe dist/escriba.json")?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("La carpeta dist no es una carpeta real".into());
    }
    let manifest: Manifest =
        serde_json::from_slice(&read_dist(&dist, "escriba.json", MANIFEST_LIMIT)?)
            .map_err(|_| "Manifiesto dist/escriba.json inválido")?;
    if manifest.version != 1 || manifest.recipes.len() > 10_000 {
        return Err("Versión o número de recetas del manifiesto inválido".into());
    }
    let mut ids = HashSet::new();
    let mut files = HashSet::new();
    let mut total = 0usize;
    let mut recipes = Vec::with_capacity(manifest.recipes.len());
    for recipe in manifest.recipes {
        if recipe.id.is_empty() || recipe.name.is_empty() || !ids.insert(recipe.id.clone()) {
            return Err("ID o nombre de receta duplicado o vacío".into());
        }
        if !files.insert(recipe.file.clone()) {
            return Err("Archivo repetido en el manifiesto".into());
        }
        checked_entry(&root, &recipe.entry, true)?;
        let bundle = load_bundle(&dist, &recipe.file, &mut total)?;
        recipes.push(json!({"id":recipe.id,"name":recipe.name,"kind":"code","values":{},"entry":recipe.entry,"bundle":bundle}));
    }
    let connector_program = manifest
        .connectors
        .map(|file| {
            if !files.insert(file.clone()) {
                return Err("Archivo repetido en el manifiesto".into());
            }
            load_bundle(&dist, &file, &mut total)
        })
        .transpose()?;
    let catalog = json!({"recipes":recipes,"destinations":[],"connectorProgram":connector_program});
    check_catalog_size(&catalog, CATALOG_LIMIT)?;
    Ok(catalog)
}

fn check_catalog_size(catalog: &Value, limit: usize) -> Result<(), String> {
    if serde_json::to_vec(catalog)
        .map_err(|_| "No se pudo serializar el catálogo")?
        .len()
        > limit
    {
        return Err("El catálogo dist supera el límite de transporte".into());
    }
    Ok(())
}

fn load_bundle(dist: &Path, entry: &str, total: &mut usize) -> Result<String, String> {
    if !entry.ends_with(".js") {
        return Err("El manifiesto debe referir un archivo JavaScript".into());
    }
    let bytes = read_dist(dist, entry, BUNDLE_LIMIT)?;
    *total = total.saturating_add(bytes.len());
    if *total > CATALOG_LIMIT {
        return Err("El catálogo supera 30 MiB".into());
    }
    let bundle = String::from_utf8(bytes).map_err(|_| "Paquete JavaScript no UTF-8")?;
    if bundle.is_empty() {
        return Err("Paquete JavaScript vacío".into());
    }
    Ok(bundle)
}

fn read_dist(dist: &Path, entry: &str, limit: usize) -> Result<Vec<u8>, String> {
    let parts = checked_entry(dist, entry, false)?;
    let root_fd = open_root(dist)?;
    let parent = open_parent(&root_fd, &parts, false)?.ok_or("Archivo dist no disponible")?;
    let name = c_name(parts.last().ok_or("Ruta dist inválida")?)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err("Archivo dist no disponible o enlace simbólico".into());
    }
    let mut file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let metadata = file.metadata().map_err(|_| "No se pudo leer dist")?;
    if !metadata.is_file() || metadata.len() > limit as u64 {
        return Err("Archivo dist inválido o demasiado grande".into());
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| "No se pudo leer dist")?;
    if bytes.len() > limit {
        return Err("Archivo dist demasiado grande".into());
    }
    Ok(bytes)
}

pub fn list(path: &Path) -> Result<Value, String> {
    let root = project_root(path)?;
    let walker = WalkDir::new(&root)
        .follow_links(false)
        .into_iter()
        .filter_entry(|item| {
            item.depth() == 0
                || !item.file_type().is_dir()
                || !excluded(item.file_name().to_str().unwrap_or(""))
        });
    let mut files = Vec::new();
    for item in walker {
        let item = item.map_err(|_| "No se pudo recorrer el proyecto")?;
        if !item.file_type().is_file() || item.file_type().is_symlink() {
            continue;
        }
        let extension = item
            .path()
            .extension()
            .and_then(|extension| extension.to_str());
        if !extension.is_some_and(|extension| {
            matches!(
                extension,
                "ts" | "tsx" | "js" | "mjs" | "cjs" | "json" | "md"
            )
        }) {
            continue;
        }
        let entry = item
            .path()
            .strip_prefix(&root)
            .map_err(|_| "Archivo fuera del proyecto")?
            .to_str()
            .ok_or("Ruta de archivo no UTF-8")?
            .replace('\\', "/");
        checked_entry(&root, &entry, false)?;
        files.push(entry);
    }
    files.sort();
    Ok(json!({"files":files}))
}

pub fn tool(path: &Path, runtime: &Path, vendor: &Path, name: &str) -> Result<Value, String> {
    let (executable, arguments, network) = match name {
        "install" => (
            runtime.to_path_buf(),
            vec!["install", "--ignore-scripts"],
            true,
        ),
        "check" => (
            vendor.join("node_modules/typescript/lib/tsc"),
            vec!["--noEmit", "--pretty", "false", "-p", "."],
            false,
        ),
        "test" => (runtime.to_path_buf(), vec!["test"], false),
        _ => return Err("Herramienta de proyecto desconocida".into()),
    };
    let result = run_development(
        path,
        &executable,
        vendor,
        &arguments,
        network,
        true,
        name != "check",
    )?;
    Ok(json!({"success":result.success,"output":result.output}))
}

struct DevelopmentResult {
    success: bool,
    output: String,
}

fn run_development(
    path: &Path,
    binary: &Path,
    vendor: &Path,
    arguments: &[&str],
    network: bool,
    project_cwd: bool,
    bun_cli: bool,
) -> Result<DevelopmentResult, String> {
    let root = project_root(path)?;
    ensure_safe_project_root(&root)?;
    let executable = fs::canonicalize(binary).map_err(|_| "Falta la herramienta incluida")?;
    if !executable.is_file() {
        return Err("La herramienta incluida no es un archivo".into());
    }
    let vendor = fs::canonicalize(vendor).map_err(|_| "Faltan las dependencias incluidas")?;
    let managed = root.join(".escriba");
    real_directory(&managed)?;
    for directory in ["cache", "tmp"] {
        real_directory(&managed.join(directory))?;
    }
    let profile = if network {
        format!("{DEV_SANDBOX}{INSTALL_NETWORK}")
    } else {
        DEV_SANDBOX.to_owned()
    };
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .arg("-p")
        .arg(profile)
        .arg("-D")
        .arg(format!("EXECUTABLE={}", executable.display()))
        .arg("-D")
        .arg(format!("PROJECT={}", root.display()))
        .arg("-D")
        .arg(format!("VENDOR={}", vendor.display()))
        .arg(&executable)
        .args(arguments)
        .env_clear()
        .env("TMPDIR", managed.join("tmp"))
        .env("BUN_INSTALL_CACHE_DIR", managed.join("cache"))
        .current_dir(if project_cwd {
            root.as_path()
        } else {
            Path::new("/")
        })
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if bun_cli {
        command.env("BUN_BE_BUN", "1");
    }
    let mut child = command
        .spawn()
        .map_err(|_| "No se pudo iniciar la herramienta aislada")?;
    let stdout = child.stdout.take().ok_or("No se pudo leer la salida")?;
    let stderr = child.stderr.take().ok_or("No se pudo leer el error")?;
    let output_reader = thread::spawn(move || bounded_output(stdout, TOOL_OUTPUT_LIMIT));
    let error_reader = thread::spawn(move || bounded_output(stderr, TOOL_OUTPUT_LIMIT));
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|_| "No se pudo esperar la herramienta")?
        {
            break status;
        }
        if started.elapsed() >= TOOL_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err("La herramienta del proyecto superó 60 segundos".into());
        }
        thread::sleep(Duration::from_millis(20));
    };
    let output = output_reader
        .join()
        .map_err(|_| "Falló lectura de herramienta")??;
    let errors = error_reader
        .join()
        .map_err(|_| "Falló lectura de herramienta")??;
    let mut combined = output.bytes;
    if !combined.is_empty() && !errors.bytes.is_empty() {
        combined.push(b'\n');
    }
    let available = TOOL_OUTPUT_LIMIT.saturating_sub(combined.len());
    let error_copied = errors.bytes.len().min(available);
    combined.extend_from_slice(&errors.bytes[..error_copied]);
    let mut message = String::from_utf8_lossy(&combined).into_owned();
    if output.truncated || errors.truncated || error_copied < errors.bytes.len() {
        message.push_str("\n… salida truncada");
    }
    if message.trim().is_empty() && !status.success() {
        message = format!("Proceso terminado con {status}");
    }
    Ok(DevelopmentResult {
        success: status.success(),
        output: message,
    })
}

fn ensure_safe_project_root(root: &Path) -> Result<(), String> {
    if root == Path::new("/") {
        return Err("La raíz del disco no puede ser un proyecto".into());
    }
    if let Some(home) = std::env::var_os("HOME") {
        let home = fs::canonicalize(home).map_err(|_| "No se pudo validar la carpeta personal")?;
        if home.starts_with(root) {
            return Err("El proyecto no puede abarcar la carpeta personal".into());
        }
    }
    Ok(())
}

fn refresh_launcher(
    root: &Path,
    runtime: &Path,
    vendor: &Path,
    create: bool,
) -> Result<(), String> {
    let launcher = root.join("escriba");
    match fs::symlink_metadata(&launcher) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            let mut existing = File::open(&launcher).map_err(|_| "No se pudo leer el lanzador")?;
            let mut marker = vec![0; LAUNCHER_MARKER.len()];
            if existing.read_exact(&mut marker).is_err() || marker != LAUNCHER_MARKER.as_bytes() {
                return Ok(());
            }
        }
        Ok(_) => return Err("El lanzador escriba no es un archivo real".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && !create => return Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("No se pudo inspeccionar el lanzador".into()),
    }
    let runtime = fs::canonicalize(runtime).map_err(|_| "No está disponible Bun incluido")?;
    let vendor =
        fs::canonicalize(vendor).map_err(|_| "No están disponibles las dependencias incluidas")?;
    let checker = vendor.join("node_modules/typescript/lib/tsc");
    if !runtime.is_file() || !checker.is_file() {
        return Err("Faltan las herramientas incluidas del proyecto".into());
    }
    let script = launcher_source(&runtime, &vendor, &checker)?;
    let temporary = root.join(format!(".escriba-launcher-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(&temporary)
            .map_err(|_| "No se pudo crear el lanzador")?;
        file.write_all(script.as_bytes())
            .map_err(|_| "No se pudo escribir el lanzador")?;
        file.set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(|_| "No se pudo preparar el lanzador")?;
        file.sync_all()
            .map_err(|_| "No se pudo sincronizar el lanzador")?;
        fs::rename(&temporary, &launcher).map_err(|_| "No se pudo instalar el lanzador")?;
        File::open(root)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| "No se pudo sincronizar el proyecto")?;
        Ok(())
    })();
    let _ = fs::remove_file(&temporary);
    result
}

fn launcher_source(runtime: &Path, vendor: &Path, checker: &Path) -> Result<String, String> {
    let runtime = shell_quote(runtime.to_str().ok_or("Ruta de Bun no UTF-8")?);
    let vendor = shell_quote(vendor.to_str().ok_or("Ruta vendor no UTF-8")?);
    let checker = shell_quote(checker.to_str().ok_or("Ruta TypeScript no UTF-8")?);
    let profile = shell_quote(DEV_SANDBOX);
    let install_profile = shell_quote(&format!("{DEV_SANDBOX}{INSTALL_NETWORK}"));
    Ok(format!(
        r#"{LAUNCHER_MARKER}set -eu
ROOT=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
RUNTIME={runtime}
VENDOR={vendor}
CHECKER={checker}
PROFILE={profile}
INSTALL_PROFILE={install_profile}
if [ ! -x "$RUNTIME" ] || [ ! -x "$CHECKER" ] || [ ! -d "$VENDOR" ]; then
  printf '%s\n' 'Las herramientas de Escriba cambiaron de ubicación. Vuelve a elegir esta carpeta en Escriba.' >&2
  exit 1
fi
if [ -L "$ROOT/.escriba" ] || [ -L "$ROOT/.escriba/cache" ] || [ -L "$ROOT/.escriba/tmp" ]; then
  printf '%s\n' 'La carpeta administrada del proyecto contiene un enlace simbólico.' >&2
  exit 1
fi
/bin/mkdir -p "$ROOT/.escriba/cache" "$ROOT/.escriba/tmp"
cd "$ROOT"
run() {{
  profile=$1
  executable=$2
  bun=$3
  shift 3
  if [ "$bun" = yes ]; then
    exec /usr/bin/env -i TMPDIR="$ROOT/.escriba/tmp" BUN_INSTALL_CACHE_DIR="$ROOT/.escriba/cache" BUN_BE_BUN=1 /usr/bin/sandbox-exec -p "$profile" -D "EXECUTABLE=$executable" -D "PROJECT=$ROOT" -D "VENDOR=$VENDOR" "$executable" "$@"
  fi
  exec /usr/bin/env -i TMPDIR="$ROOT/.escriba/tmp" BUN_INSTALL_CACHE_DIR="$ROOT/.escriba/cache" /usr/bin/sandbox-exec -p "$profile" -D "EXECUTABLE=$executable" -D "PROJECT=$ROOT" -D "VENDOR=$VENDOR" "$executable" "$@"
}}
if [ "$#" -ne 1 ]; then
  printf '%s\n' 'Uso: ./escriba install|check|test|build' >&2
  exit 2
fi
case "${{1-}}" in
  install) run "$INSTALL_PROFILE" "$RUNTIME" yes install --ignore-scripts ;;
  check) run "$PROFILE" "$CHECKER" no --noEmit --pretty false -p "$ROOT" ;;
  test) run "$PROFILE" "$RUNTIME" yes test ;;
  build) run "$PROFILE" "$RUNTIME" no --project-build "$ROOT" "$VENDOR" ;;
  *) printf '%s\n' 'Uso: ./escriba install|check|test|build' >&2; exit 2 ;;
esac
"#
    ))
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Creates only missing project files. Existing source and dependencies stay untouched.
pub fn initialize(
    path: &Path,
    accounts: &Value,
    vendor: &Path,
    runtime: &Path,
) -> Result<bool, String> {
    if !path.is_absolute() {
        return Err("La carpeta del proyecto debe ser absoluta".into());
    }
    if path
        .components()
        .any(|part| matches!(part, std::path::Component::ParentDir))
    {
        return Err("La carpeta del proyecto contiene una ruta ambigua".into());
    }
    if path.exists() {
        ensure_safe_project_root(&project_root(path)?)?;
    }
    fs::create_dir_all(path).map_err(|_| "No se pudo crear la carpeta del proyecto")?;
    let root = project_root(path)?;
    ensure_safe_project_root(&root)?;
    match fs::symlink_metadata(root.join("dist")) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => return Err("dist debe ser una carpeta real".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("No se pudo inspeccionar dist".into()),
    }
    match fs::symlink_metadata(root.join("dist/escriba.json")) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            refresh_launcher(&root, runtime, vendor, false)?;
            return Ok(true);
        }
        Ok(_) => return Err("El manifiesto dist/escriba.json no es un archivo real".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("No se pudo inspeccionar dist/escriba.json".into()),
    }
    for (package, name, runtime) in [
        ("@escriba/conectores", "conectores", true),
        ("zod", "zod", true),
        ("@types/bun", "types-bun", false),
        ("bun-types", "bun-types", false),
        ("@types/node", "types-node", false),
        ("undici-types", "undici-types", false),
    ] {
        install_managed_dependency(&root, vendor, package, name, runtime)?;
    }
    write_new(
        &root.join("package.json"),
        r#"{
  "name": "escriba-project",
  "private": true,
  "type": "module",
  "dependencies": {
    "@escriba/conectores": "file:.escriba/deps/conectores",
    "zod": "file:.escriba/deps/zod"
  },
  "devDependencies": {
    "@types/bun": "file:.escriba/deps/types-bun",
    "bun-types": "file:.escriba/deps/bun-types",
    "@types/node": "file:.escriba/deps/types-node",
    "undici-types": "file:.escriba/deps/undici-types"
  },
  "overrides": {
    "bun-types": "file:.escriba/deps/bun-types",
    "@types/node": "file:.escriba/deps/types-node",
    "undici-types": "file:.escriba/deps/undici-types"
  }
}
"#,
    )?;
    write_new(
        &root.join("tsconfig.json"),
        r#"{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "rootDir": ".",
    "types": ["bun"]
  },
  "include": ["**/*.ts", "**/*.tsx"],
  "exclude": ["node_modules", ".git", ".escriba", "dist"]
}
"#,
    )?;
    write_new(&root.join("escriba-recetas.d.ts"), TYPES)?;
    for directory in ["src", "src/recetas", "src/recetas/ejemplo"] {
        real_directory(&root.join(directory))?;
    }
    if !has_recipe_source(&root)? {
        write_new(&root.join("src/recetas/ejemplo/receta.ts"), EXAMPLE)?;
    }
    if !root.join("conectores.ts").exists() {
        write_new(
            &root.join("src/conectores.ts"),
            &connector_source(accounts)?,
        )?;
    }
    refresh_launcher(&root, runtime, vendor, true)?;
    Ok(false)
}

/// Builds an artifact with the bundled runtime, then inspects only that artifact.
pub fn build(path: &Path, runtime: &Path, vendor: &Path) -> Result<Value, String> {
    let root = project_root(path)?;
    let vendor_real =
        fs::canonicalize(vendor).map_err(|_| "No están disponibles las dependencias incluidas")?;
    let root_text = root.to_str().ok_or("Ruta de proyecto no UTF-8")?;
    let vendor_text = vendor_real
        .to_str()
        .ok_or("Ruta de dependencias no UTF-8")?;
    let result = run_development(
        &root,
        runtime,
        &vendor_real,
        &["--project-build", root_text, vendor_text],
        false,
        false,
        false,
    )?;
    if !result.success {
        return Err(format!(
            "No se pudo construir el proyecto: {}",
            result.output.trim()
        ));
    }
    load(&root)
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
#[cfg(test)]
pub fn write(path: &Path, entry: &str, source: &str) -> Result<(), String> {
    write_checked(path, entry, source, None, false)
}

pub fn write_checked(
    path: &Path,
    entry: &str,
    source: &str,
    expected_source: Option<&str>,
    create_new: bool,
) -> Result<(), String> {
    if create_new && expected_source.is_some() {
        return Err("La creación no admite una versión previa".into());
    }
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
    let outcome = (|| -> Result<(), String> {
        file.write_all(source.as_bytes())
            .map_err(|_| "No se pudo escribir la fuente")?;
        file.sync_all()
            .map_err(|_| "No se pudo sincronizar la fuente")?;
        if create_new {
            if unsafe {
                libc::linkat(
                    parent.as_raw_fd(),
                    temporary.as_ptr(),
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    0,
                )
            } < 0
            {
                return Err("El archivo ya existe o no se pudo crear".into());
            }
        } else {
            if let Some(expected) = expected_source {
                let current = read(&root, entry)?;
                if current["source"].as_str() != Some(expected) {
                    return Err("La fuente cambió desde que se abrió".into());
                }
            }
            if unsafe {
                libc::renameat(
                    parent.as_raw_fd(),
                    temporary.as_ptr(),
                    parent.as_raw_fd(),
                    name.as_ptr(),
                )
            } < 0
            {
                return Err("No se pudo reemplazar la fuente".into());
            }
        }
        if unsafe { libc::fsync(parent.as_raw_fd()) } < 0 {
            return Err("No se pudo sincronizar la carpeta".into());
        }
        Ok(())
    })();
    unsafe { libc::unlinkat(parent.as_raw_fd(), temporary.as_ptr(), 0) };
    outcome
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

fn install_managed_dependency(
    root: &Path,
    vendor: &Path,
    package: &str,
    name: &str,
    runtime: bool,
) -> Result<(), String> {
    let source = vendor_modules(vendor).join(package);
    let source = fs::canonicalize(source).map_err(|_| "Falta una dependencia incluida")?;
    if !source.is_dir()
        || !source.join("package.json").is_file()
        || (runtime && !source.join("index.js").is_file())
        || !source.join("index.d.ts").is_file()
    {
        return Err("Una dependencia incluida está incompleta".into());
    }
    let managed = root.join(".escriba");
    real_directory(&managed)?;
    let deps = managed.join("deps");
    real_directory(&deps)?;
    let destination = deps.join(name);
    if destination.exists() {
        let kind =
            fs::symlink_metadata(&destination).map_err(|_| "Dependencia administrada inválida")?;
        if !kind.is_dir()
            || kind.file_type().is_symlink()
            || !destination.join("package.json").is_file()
            || (runtime && !destination.join("index.js").is_file())
            || !destination.join("index.d.ts").is_file()
        {
            return Err("Dependencia administrada inválida".into());
        }
        return Ok(());
    }
    let temporary = deps.join(format!(".{name}-{}", uuid::Uuid::new_v4()));
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
    matches!(name, ".git" | "node_modules" | ".escriba" | "dist")
}

fn has_recipe_source(root: &Path) -> Result<bool, String> {
    let walker = WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_entry(|item| {
            item.depth() == 0
                || !item.file_type().is_dir()
                || !excluded(item.file_name().to_str().unwrap_or(""))
        });
    for item in walker {
        let item = item.map_err(|_| "No se pudo recorrer el proyecto")?;
        if item.file_type().is_file()
            && matches!(item.file_name().to_str(), Some("receta.ts" | "receta.js"))
        {
            return Ok(true);
        }
    }
    Ok(false)
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
            .map_err(|_| "No se pudo leer la herramienta")?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::symlink,
        sync::{Arc, Mutex},
    };

    fn initialize_test(path: &Path, accounts: &Value, vendor: &Path) -> Result<bool, String> {
        let runtime = crate::native::binary("escriba-runtime")?;
        initialize(path, accounts, vendor, &runtime)
    }

    fn project_vendor() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor")
    }

    #[test]
    fn carga_dist_autocontenido_sin_fuentes_ni_dependencias() {
        let folder = tempfile::tempdir().unwrap();
        let dist = folder.path().join("dist");
        fs::create_dir(&dist).unwrap();
        fs::write(dist.join("receta.js"), "var __recipe={flujo(){}}").unwrap();
        fs::write(dist.join("conectores.js"), "var __conectores={}").unwrap();
        fs::write(
            dist.join("escriba.json"),
            r#"{"version":1,"recipes":[{"id":"mi-receta","name":"Mi receta","entry":"recetas/mi-receta/receta.ts","file":"receta.js"}],"connectors":"conectores.js"}"#,
        )
        .unwrap();
        let catalog = load(folder.path()).unwrap();
        assert_eq!(catalog["recipes"][0]["id"], "mi-receta");
        assert_eq!(catalog["recipes"][0]["bundle"], "var __recipe={flujo(){}}");
        assert_eq!(catalog["connectorProgram"], "var __conectores={}");
    }

    #[test]
    fn proyecto_con_dist_no_crea_fuentes_ni_exige_dependencias() {
        let folder = tempfile::tempdir().unwrap();
        let dist = folder.path().join("dist");
        fs::create_dir(&dist).unwrap();
        fs::write(dist.join("escriba.json"), r#"{"version":1,"recipes":[]}"#).unwrap();
        let has_dist =
            initialize_test(folder.path(), &json!([]), Path::new("/vendor/ausente")).unwrap();
        assert!(has_dist);
        assert!(!folder.path().join("package.json").exists());
        assert!(!folder.path().join("src").exists());
    }

    #[test]
    fn inicializacion_no_inyecta_ejemplo_si_hay_receta_del_usuario() {
        let folder = tempfile::tempdir().unwrap();
        let vendor = project_vendor();
        let recipe = folder.path().join("recetas/ejemplo/receta.ts");
        fs::create_dir_all(recipe.parent().unwrap()).unwrap();
        fs::write(&recipe, "export const receta={nombre:'Propia'}").unwrap();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
        assert_eq!(
            fs::read_to_string(&recipe).unwrap(),
            "export const receta={nombre:'Propia'}"
        );
        assert!(!folder.path().join("src/recetas/ejemplo/receta.ts").exists());
    }

    #[test]
    fn manifiesto_rechaza_duplicados_fugas_y_enlaces() {
        let folder = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let dist = folder.path().join("dist");
        fs::create_dir(&dist).unwrap();
        fs::write(dist.join("receta.js"), "var __recipe={}").unwrap();
        fs::write(outside.path().join("fuera.js"), "var __recipe={}").unwrap();
        let item = r#"{"id":"uno","name":"Uno","entry":"src/receta.ts","file":"receta.js"}"#;
        for manifest in [
            format!(r#"{{"version":2,"recipes":[{item}]}}"#),
            format!(r#"{{"version":1,"recipes":[{item},{item}]}}"#),
            r#"{"version":1,"recipes":[{"id":"uno","name":"Uno","entry":"../fuera.ts","file":"receta.js"}]}"#.to_owned(),
            r#"{"version":1,"recipes":[{"id":"uno","name":"Uno","entry":"src/receta.ts","file":"../fuera.js"}]}"#.to_owned(),
            r#"{"version":1,"recipes":[],"unexpected":true}"#.to_owned(),
        ] {
            fs::write(dist.join("escriba.json"), manifest).unwrap();
            assert!(load(folder.path()).is_err());
        }
        fs::remove_file(dist.join("receta.js")).unwrap();
        symlink(outside.path().join("fuera.js"), dist.join("receta.js")).unwrap();
        fs::write(
            dist.join("escriba.json"),
            format!(r#"{{"version":1,"recipes":[{item}]}}"#),
        )
        .unwrap();
        assert!(load(folder.path()).is_err());
    }

    #[test]
    fn limite_de_catalogo_cuenta_escapes_json() {
        let catalog = json!({"bundle":"\"\"\"\"\"\""});
        assert!(check_catalog_size(&catalog, 20).is_err());
        assert!(check_catalog_size(&catalog, 40).is_ok());
    }

    #[test]
    fn lista_solo_fuentes_editables_y_oculta_artefactos() {
        let folder = tempfile::tempdir().unwrap();
        for entry in [
            "src/recetas/a/receta.ts",
            "src/conectores.ts",
            "package.json",
            "dist/receta.js",
            "node_modules/dep/index.js",
            ".escriba/cache/data.json",
            ".git/config",
            "imagen.png",
        ] {
            let file = folder.path().join(entry);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, "dato").unwrap();
        }
        assert_eq!(
            list(folder.path()).unwrap(),
            json!({"files":["package.json","src/conectores.ts","src/recetas/a/receta.ts"]})
        );
    }

    #[test]
    fn herramienta_test_no_puede_leer_fuera_del_proyecto() {
        let folder = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let vendor = tempfile::tempdir().unwrap();
        let secret = outside.path().join("privado.txt");
        fs::write(&secret, "solo para prueba").unwrap();
        fs::write(
            folder.path().join("aislamiento.test.ts"),
            format!(
                "import {{ test, expect }} from 'bun:test'; import {{ readFileSync }} from 'node:fs'; test('aislado',()=>expect(()=>readFileSync({:?})).toThrow());",
                secret.to_str().unwrap()
            ),
        )
        .unwrap();
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let result = tool(folder.path(), &runtime, vendor.path(), "test").unwrap();
        assert_eq!(result["success"], true, "{result}");
    }

    #[test]
    fn herramienta_check_usa_typescript_nativo_y_devuelve_diagnostico() {
        let folder = tempfile::tempdir().unwrap();
        fs::write(
            folder.path().join("tsconfig.json"),
            r#"{"compilerOptions":{"noEmit":true,"strict":true},"files":["receta.ts"]}"#,
        )
        .unwrap();
        fs::write(
            folder.path().join("receta.ts"),
            "const valor: number = 'mal';",
        )
        .unwrap();
        let vendor = Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor");
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let result = tool(folder.path(), &runtime, &vendor, "check").unwrap();
        assert_eq!(result["success"], false);
        assert!(
            result["output"].as_str().unwrap().contains("TS2322"),
            "{result}"
        );
    }

    #[test]
    fn herramienta_install_resuelve_dependencia_local_sin_scripts() {
        let folder = tempfile::tempdir().unwrap();
        let dependency = folder.path().join("paquete-local");
        fs::create_dir(&dependency).unwrap();
        fs::write(
            dependency.join("package.json"),
            r#"{"name":"paquete-local","version":"1.0.0","main":"index.js","scripts":{"postinstall":"touch ../marcador-prohibido"}}"#,
        )
        .unwrap();
        fs::write(dependency.join("index.js"), "export const dato=1").unwrap();
        fs::write(
            folder.path().join("package.json"),
            r#"{"name":"fixture","private":true,"dependencies":{"paquete-local":"file:./paquete-local"}}"#,
        )
        .unwrap();
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let vendor = project_vendor();
        let result = tool(folder.path(), &runtime, &vendor, "install").unwrap();
        assert_eq!(result["success"], true, "{result}");
        assert!(folder
            .path()
            .join("node_modules/paquete-local/index.js")
            .exists());
        assert!(!folder.path().join("marcador-prohibido").exists());
    }

    #[test]
    fn editor_rechaza_creacion_duplicada_y_fuente_obsoleta() {
        let folder = tempfile::tempdir().unwrap();
        let entry = "src/receta.ts";
        fs::create_dir(folder.path().join("src")).unwrap();
        fs::write(folder.path().join(entry), "versión externa").unwrap();
        assert!(write_checked(folder.path(), entry, "nueva", None, true).is_err());
        assert_eq!(
            fs::read_to_string(folder.path().join(entry)).unwrap(),
            "versión externa"
        );
        assert!(write_checked(
            folder.path(),
            entry,
            "nueva",
            Some("versión antigua"),
            false
        )
        .is_err());
        assert_eq!(
            fs::read_to_string(folder.path().join(entry)).unwrap(),
            "versión externa"
        );
        write_checked(
            folder.path(),
            entry,
            "nueva",
            Some("versión externa"),
            false,
        )
        .unwrap();
        assert_eq!(
            fs::read_to_string(folder.path().join(entry)).unwrap(),
            "nueva"
        );
        write_checked(folder.path(), "src/otra.ts", "primera", None, true).unwrap();
        assert_eq!(
            fs::read_to_string(folder.path().join("src/otra.ts")).unwrap(),
            "primera"
        );
    }

    #[test]
    fn lanzador_del_proyecto_usa_bun_incluido_y_sandbox() {
        let folder = tempfile::tempdir().unwrap();
        let vendor = project_vendor();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
        fs::write(
            folder.path().join("lanzador.test.ts"),
            "import {test,expect} from 'bun:test'; import {join} from 'node:path'; const invalido: string = 4; test('incluido',()=>expect(join('a','b')).toBe('a/b'));",
        )
        .unwrap();
        let launcher = folder.path().join("escriba");
        assert_ne!(
            fs::metadata(&launcher).unwrap().permissions().mode() & 0o111,
            0
        );
        let installed = Command::new(&launcher)
            .arg("install")
            .current_dir("/")
            .env_clear()
            .output()
            .unwrap();
        assert!(
            installed.status.success(),
            "{}",
            String::from_utf8_lossy(&installed.stderr)
        );
        let invalid = Command::new(&launcher)
            .arg("check")
            .current_dir("/")
            .env_clear()
            .output()
            .unwrap();
        assert!(!invalid.status.success());
        assert!(String::from_utf8_lossy(&invalid.stdout).contains("TS2322"));
        fs::write(
            folder.path().join("lanzador.test.ts"),
            "import {test,expect} from 'bun:test'; import {join} from 'node:path'; test('incluido',()=>expect(join('a','b')).toBe('a/b'));",
        )
        .unwrap();
        for command in ["check", "test", "build"] {
            let result = Command::new(&launcher)
                .arg(command)
                .current_dir("/")
                .env_clear()
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{command}: {}",
                String::from_utf8_lossy(&result.stderr)
            );
        }
        assert!(folder.path().join("dist/escriba.json").is_file());
    }

    #[test]
    fn lanzador_escapa_rutas_con_comillas() {
        assert_eq!(shell_quote("una'comilla"), "'una'\\''comilla'");
    }

    #[test]
    fn initialization_preserves_existing_files_and_confines_source_access() {
        let folder = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let vendor = project_vendor();
        fs::write(folder.path().join("conectores.ts"), "// personalizado").unwrap();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
        assert_eq!(
            fs::read_to_string(folder.path().join("conectores.ts")).unwrap(),
            "// personalizado"
        );
        assert!(folder.path().join("src/recetas/ejemplo/receta.ts").exists());
        assert!(!folder.path().join("src/conectores.ts").exists());
        assert!(folder.path().join("escriba-recetas.d.ts").exists());
        let dependency = folder.path().join(".escriba/deps/conectores");
        assert!(dependency.join("index.js").is_file());
        assert!(folder.path().join(".escriba/deps/zod/index.js").is_file());
        assert!(!fs::symlink_metadata(&dependency)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(folder.path().join("package.json")).unwrap())
                .unwrap()["dependencies"]["@escriba/conectores"],
            "file:.escriba/deps/conectores"
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(folder.path().join("package.json")).unwrap())
                .unwrap()["dependencies"]["zod"],
            "file:.escriba/deps/zod"
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
    fn build_compiles_real_example_when_bun_is_available() {
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let vendor = project_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
        let result = build(folder.path(), &runtime, &vendor).unwrap();
        assert_eq!(result["recipes"][0]["id"], "ejemplo");
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
        let rebuilt = build(folder.path(), &runtime, &vendor).unwrap();
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
        let rebuilt = build(folder.path(), &runtime, &vendor);
        assert!(rebuilt.is_ok(), "{rebuilt:?}");
    }

    #[test]
    fn build_fallido_conserva_dist_anterior() {
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let vendor = project_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
        let previous = build(folder.path(), &runtime, &vendor).unwrap();
        write(
            folder.path(),
            "src/recetas/ejemplo/receta.ts",
            "import { falta } from 'paquete-inexistente'; export const receta={nombre:falta};",
        )
        .unwrap();
        assert!(build(folder.path(), &runtime, &vendor).is_err());
        assert_eq!(load(folder.path()).unwrap(), previous);
    }

    #[test]
    fn build_preserva_claves_legacy_js_y_prefiere_ts_del_mismo_directorio() {
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let vendor = project_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
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
        let result = build(folder.path(), &runtime, &vendor).unwrap();
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
        assert!(recipes.iter().any(|recipe| recipe["id"] == "ejemplo"));
    }

    #[tokio::test]
    async fn paquete_legacy_js_ejecuta_flujo_en_sidecar_compilado() {
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let vendor = project_vendor();
        let folder = tempfile::tempdir().unwrap();
        initialize_test(folder.path(), &json!([]), &vendor).unwrap();
        write(folder.path(), "recetas/mi-receta/receta.js", "export const receta={nombre:'Mi receta heredada'}; export async function flujo(audio,escriba){ const nota=await escriba.transcribir(audio); await nota.guardar(); }").unwrap();
        let recipes = build(folder.path(), &runtime, &vendor).unwrap()["recipes"].clone();
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
                        "runtime_context" => {
                            let mut context = snapshot.clone();
                            context["recordings"] = json!(snapshot["recordings"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .filter(|recording| params["recordingId"] == recording["id"])
                                .cloned()
                                .collect::<Vec<_>>());
                            Ok(context)
                        }
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
        assert!(schema.is_null());
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
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let vendor = project_vendor();
        let base = tempfile::tempdir().unwrap();
        let project = base.path().join("project");
        initialize_test(&project, &json!([]), &vendor).unwrap();
        fs::write(
            base.path().join("outside.ts"),
            "export const secret = 'outside';",
        )
        .unwrap();
        write(&project, "evil/receta.ts", "import { secret } from '../../outside.ts'; export const receta = { nombre: secret }; export async function flujo() { console.log(secret) }").unwrap();
        let error = build(&project, &runtime, &vendor).unwrap_err();
        assert!(
            error.contains("No se pudo compilar evil/receta.ts"),
            "{error}"
        );
        assert!(!project.join("dist/escriba.json").exists());
    }
}
