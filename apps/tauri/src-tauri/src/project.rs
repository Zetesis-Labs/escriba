//! TypeScript project creation, confined source access, and Bun artifacts.
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::{
    ffi::CString,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
};
use walkdir::WalkDir;
#[cfg(windows)]
#[path = "project_windows.rs"]
mod windows;

const TYPES: &str = include_str!("../../../../recetas/escriba-recetas.d.ts");
const PREVIOUS_TYPES_SHA256: &[&str] = &[
    "1ddebd218cbb5a0b4f3b6a40120dadec5c8c5912eeb93a6d1d3fdd824b7146d1",
    "976e7e95fa41cffb8273cc14a72ec4fa091e89c9d9d147824f542ff971e3cebe",
    "dd560d43ed138390fcbdaa222ae214a90c04084864c4ed9595596fb4f3a83b8b",
    "7bcbc0a206ebb579fefc562a5aeb8fcc84b963bab156540e968cd9375f42938a",
    "79937382df1625fde0940602a46c11b07e5b155f12df99f444ed527714cb2afa",
];
const EXAMPLE: &str = include_str!("../../../../recetas/por-defecto/receta.ts");
const PIECES: &str = include_str!("../../../../recetas/piezas.ts");
const SOURCE_LIMIT: usize = 8 * 1024 * 1024;
const BUNDLE_LIMIT: usize = 32 * 1024 * 1024;
const MANIFEST_LIMIT: usize = 1024 * 1024;
const CATALOG_LIMIT: usize = 30 * 1024 * 1024;
const TOOL_OUTPUT_LIMIT: usize = 64 * 1024;
const TOOL_TIMEOUT: Duration = Duration::from_secs(60);
#[cfg(unix)]
const LAUNCHER_MARKER: &str = "#!/bin/sh\nESCRIBA_LAUNCHER_VERSION=1\n";

#[cfg(windows)]
const LAUNCHER_MARKER: &str = "@echo off\r\nrem ESCRIBA_LAUNCHER_VERSION=1\r\n";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    recipes: Vec<ManifestRecipe>,
    connectors: Option<String>,
    ontologies: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestRecipe {
    id: String,
    name: String,
    entry: String,
    file: String,
}

pub fn load_with_tools(path: &Path, runtime: &Path, vendor: &Path) -> Result<Value, String> {
    let catalog = load(path)?;
    let root = project_root(path)?;
    ensure_safe_project_root(&root)?;
    refresh_existing_managed_dependencies(&root, vendor)?;
    refresh_generated_types(&root)?;
    refresh_launcher(&root, runtime, vendor, false)?;
    Ok(catalog)
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
    let ontology_program = manifest
        .ontologies
        .map(|file| {
            if !files.insert(file.clone()) {
                return Err("Archivo repetido en el manifiesto".into());
            }
            load_bundle(&dist, &file, &mut total)
        })
        .transpose()?;
    let catalog = json!({"recipes":recipes,"destinations":[],"connectorProgram":connector_program,"ontologyProgram":ontology_program});
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

#[cfg(unix)]
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
    let root = project_root(path)?;
    ensure_safe_project_root(&root)?;
    refresh_existing_managed_dependencies(&root, vendor)?;
    refresh_generated_types(&root)?;
    let (executable, arguments, network) = match name {
        "install" => (
            runtime.to_path_buf(),
            vec!["install", "--ignore-scripts"],
            true,
        ),
        "check" => (
            vendor.join(if cfg!(windows) {
                "node_modules/typescript/lib/tsc.exe"
            } else {
                "node_modules/typescript/lib/tsc"
            }),
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
    let wrapped = crate::confinement::wrap(
        &executable,
        crate::confinement::Profile::Tool {
            project: &root,
            vendor: &vendor,
            network,
        },
    );
    let mut command = Command::new(wrapped.program);
    command.args(wrapped.arguments);
    command
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
    #[cfg(windows)]
    {
        command.envs(crate::platform::process_environment());
        command
            .env("TEMP", managed.join("tmp"))
            .env("TMP", managed.join("tmp"));
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
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
    if root.parent().is_none() {
        return Err("La raíz del disco no puede ser un proyecto".into());
    }
    if let Some(home) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }) {
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
    let launcher = root.join(if cfg!(windows) {
        "escriba.cmd"
    } else {
        "escriba"
    });
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
    let checker = vendor.join(if cfg!(windows) {
        "node_modules/typescript/lib/tsc.exe"
    } else {
        "node_modules/typescript/lib/tsc"
    });
    if !runtime.is_file() || !checker.is_file() {
        return Err("Faltan las herramientas incluidas del proyecto".into());
    }
    let script = launcher_source(&runtime, &vendor, &checker)?;
    let temporary = root.join(format!(".escriba-launcher-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<(), String> {
        let mut file = crate::file_security::create_private(&temporary, true)
            .map_err(|_| "No se pudo crear el lanzador")?;
        file.write_all(script.as_bytes())
            .map_err(|_| "No se pudo escribir el lanzador")?;
        file.sync_all()
            .map_err(|_| "No se pudo sincronizar el lanzador")?;
        fs::rename(&temporary, &launcher).map_err(|_| "No se pudo instalar el lanzador")?;
        crate::file_security::sync_directory(root)
            .map_err(|_| "No se pudo sincronizar el proyecto")?;
        Ok(())
    })();
    let _ = fs::remove_file(&temporary);
    result
}

#[cfg(unix)]
fn launcher_source(runtime: &Path, vendor: &Path, checker: &Path) -> Result<String, String> {
    let runtime = shell_quote(runtime.to_str().ok_or("Ruta de Bun no UTF-8")?);
    let vendor = shell_quote(vendor.to_str().ok_or("Ruta vendor no UTF-8")?);
    let checker = shell_quote(checker.to_str().ok_or("Ruta TypeScript no UTF-8")?);
    let confinement = crate::confinement::launcher();
    let (profile, install_profile, run) = match &confinement {
        Some(launcher) => (
            shell_quote(&launcher.tool),
            shell_quote(&launcher.install),
            launcher.command.as_str(),
        ),
        None => ("''".to_owned(), "''".to_owned(), r#""$executable""#),
    };
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
    exec /usr/bin/env -i TMPDIR="$ROOT/.escriba/tmp" BUN_INSTALL_CACHE_DIR="$ROOT/.escriba/cache" BUN_BE_BUN=1 {run} "$@"
  fi
  exec /usr/bin/env -i TMPDIR="$ROOT/.escriba/tmp" BUN_INSTALL_CACHE_DIR="$ROOT/.escriba/cache" {run} "$@"
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

#[cfg(unix)]
pub(crate) fn shell_quote(value: &str) -> String {
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
            refresh_existing_managed_dependencies(&root, vendor)?;
            refresh_generated_types(&root)?;
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
        ("surrealdb", "surrealdb", true),
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
    "zod": "file:.escriba/deps/zod",
    "surrealdb": "file:.escriba/deps/surrealdb"
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
    ensure_sdk_dependency(&root)?;
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
        write_new(&root.join("src/recetas/piezas.ts"), PIECES)?;
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
    ensure_safe_project_root(&root)?;
    refresh_existing_managed_dependencies(&root, vendor)?;
    refresh_generated_types(&root)?;
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
#[cfg(unix)]
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
#[cfg(all(test, unix))]
pub fn write(path: &Path, entry: &str, source: &str) -> Result<(), String> {
    write_checked(path, entry, source, None, false)
}

#[cfg(unix)]
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

fn refresh_generated_types(root: &Path) -> Result<(), String> {
    let path = root.join("escriba-recetas.d.ts");
    let kind = match fs::symlink_metadata(&path) {
        Ok(kind) => kind,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err("No se pudieron inspeccionar los tipos del proyecto".into()),
    };
    if !kind.is_file() || kind.file_type().is_symlink() {
        return Err("Los tipos del proyecto no son un archivo real".into());
    }
    if kind.len() > SOURCE_LIMIT as u64 {
        return Err("Los tipos del proyecto superan el límite".into());
    }
    let existing = fs::read(&path).map_err(|_| "No se pudieron leer los tipos del proyecto")?;
    if existing == TYPES.as_bytes() {
        return Ok(());
    }
    let digest = Sha256::digest(&existing);
    if !PREVIOUS_TYPES_SHA256.contains(&format!("{digest:x}").as_str()) {
        return Ok(());
    }
    let temporary = root.join(format!(".escriba-recetas-types-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|_| "No se pudieron preparar los tipos del proyecto")?;
        file.write_all(TYPES.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|_| "No se pudieron escribir los tipos del proyecto")?;
        fs::rename(&temporary, &path)
            .map_err(|_| "No se pudieron actualizar los tipos del proyecto")?;
        crate::file_security::sync_directory(root)
            .map_err(|_| "No se pudo sincronizar el proyecto")?;
        Ok(())
    })();
    let _ = fs::remove_file(&temporary);
    result
}

fn refresh_existing_managed_dependencies(root: &Path, vendor: &Path) -> Result<(), String> {
    let deps = root.join(".escriba/deps");
    match fs::symlink_metadata(&deps) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err("No se pudo inspeccionar la carpeta administrada".into()),
        Ok(kind) if !kind.is_dir() || kind.file_type().is_symlink() => {
            return Err("Carpeta administrada inválida".into());
        }
        Ok(_) => {}
    }
    let managed = root.join(".escriba");
    let kind = fs::symlink_metadata(&managed).map_err(|_| "Carpeta administrada inválida")?;
    if !kind.is_dir() || kind.file_type().is_symlink() {
        return Err("Carpeta administrada inválida".into());
    }
    for (package, name, runtime) in [
        ("@escriba/conectores", "conectores", true),
        ("zod", "zod", true),
        ("@types/bun", "types-bun", false),
        ("bun-types", "bun-types", false),
        ("@types/node", "types-node", false),
        ("undici-types", "undici-types", false),
    ] {
        match fs::symlink_metadata(deps.join(name)) {
            Ok(_) => install_managed_dependency(root, vendor, package, name, runtime)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("No se pudo inspeccionar la dependencia administrada".into()),
        }
    }
    if vendor_modules(vendor).join("surrealdb").is_dir() {
        install_managed_dependency(root, vendor, "surrealdb", "surrealdb", true)?;
        ensure_sdk_dependency(root)?;
    }
    Ok(())
}

fn ensure_sdk_dependency(root: &Path) -> Result<(), String> {
    let path = root.join("package.json");
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err("No se pudo inspeccionar package.json".into()),
    };
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > SOURCE_LIMIT as u64
    {
        return Err("package.json inválido".into());
    }
    let content = fs::read(&path).map_err(|_| "No se pudo leer package.json")?;
    let mut manifest: Value =
        serde_json::from_slice(&content).map_err(|_| "package.json inválido")?;
    let object = manifest.as_object_mut().ok_or("package.json inválido")?;
    if [
        "dependencies",
        "devDependencies",
        "peerDependencies",
        "optionalDependencies",
    ]
    .iter()
    .any(|section| {
        object
            .get(*section)
            .and_then(Value::as_object)
            .is_some_and(|deps| deps.contains_key("surrealdb"))
    }) {
        return Ok(());
    }
    let dependencies = object
        .entry("dependencies")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("Las dependencias de package.json son inválidas")?;
    dependencies.insert("surrealdb".into(), json!("file:.escriba/deps/surrealdb"));
    let updated =
        serde_json::to_vec_pretty(&manifest).map_err(|_| "No se pudo preparar package.json")?;
    let temporary = root.join(format!(".escriba-package-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|_| "No se pudo preparar package.json")?;
        file.write_all(&updated)
            .and_then(|_| file.sync_all())
            .map_err(|_| "No se pudo escribir package.json")?;
        fs::set_permissions(&temporary, metadata.permissions())
            .map_err(|_| "No se pudo conservar los permisos de package.json")?;
        fs::rename(&temporary, &path).map_err(|_| "No se pudo actualizar package.json")?;
        crate::file_security::sync_directory(root)
            .map_err(|_| "No se pudo sincronizar el proyecto")?;
        Ok(())
    })();
    let _ = fs::remove_file(&temporary);
    result
}

fn same_dependency(source: &Path, destination: &Path) -> Result<bool, String> {
    let mut source_paths = HashSet::new();
    for item in WalkDir::new(source).follow_links(false) {
        let item = item.map_err(|_| "No se pudo leer la dependencia incluida")?;
        let relative = item
            .path()
            .strip_prefix(source)
            .map_err(|_| "Dependencia incluida inválida")?;
        if item.file_type().is_symlink() {
            return Err("La dependencia incluida contiene un enlace simbólico".into());
        }
        if relative.as_os_str().is_empty() {
            continue;
        }
        source_paths.insert(relative.to_path_buf());
        let target = destination.join(relative);
        let kind = match fs::symlink_metadata(&target) {
            Ok(kind) => kind,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(_) => return Err("Dependencia administrada inválida".into()),
        };
        if kind.file_type().is_symlink() {
            return Err("Dependencia administrada contiene un enlace simbólico".into());
        }
        if item.file_type().is_dir() {
            if !kind.is_dir() {
                return Ok(false);
            }
        } else if item.file_type().is_file() {
            let source_size = item
                .metadata()
                .map_err(|_| "Dependencia incluida inválida")?
                .len();
            if source_size > BUNDLE_LIMIT as u64 {
                return Err("Archivo de dependencia supera 32 MiB".into());
            }
            if !kind.is_file() || kind.len() != source_size {
                return Ok(false);
            }
            if fs::read(item.path()).map_err(|_| "No se pudo leer la dependencia incluida")?
                != fs::read(&target).map_err(|_| "No se pudo leer la dependencia administrada")?
            {
                return Ok(false);
            }
        } else {
            return Err("Tipo de archivo de dependencia inválido".into());
        }
    }
    for item in WalkDir::new(destination).follow_links(false) {
        let item = item.map_err(|_| "No se pudo leer la dependencia administrada")?;
        if item.file_type().is_symlink() {
            return Err("Dependencia administrada contiene un enlace simbólico".into());
        }
        let relative = item
            .path()
            .strip_prefix(destination)
            .map_err(|_| "Dependencia administrada inválida")?;
        if !relative.as_os_str().is_empty() && !source_paths.contains(relative) {
            return Ok(false);
        }
    }
    Ok(true)
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
    let existing = fs::symlink_metadata(&destination);
    if let Ok(kind) = existing.as_ref() {
        if !kind.is_dir()
            || kind.file_type().is_symlink()
            || !destination.join("package.json").is_file()
            || (runtime && !destination.join("index.js").is_file())
            || !destination.join("index.d.ts").is_file()
        {
            return Err("Dependencia administrada inválida".into());
        }
        if same_dependency(&source, &destination)? {
            return Ok(());
        }
    } else if !matches!(existing, Err(ref error) if error.kind() == std::io::ErrorKind::NotFound) {
        return Err("Dependencia administrada inválida".into());
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
        let backup = deps.join(format!(".{name}-backup-{}", uuid::Uuid::new_v4()));
        let replacing = destination.exists();
        if replacing {
            fs::rename(&destination, &backup)
                .map_err(|_| "No se pudo preparar la actualización de la dependencia")?;
        }
        if fs::rename(&temporary, &destination).is_err() {
            if replacing {
                fs::rename(&backup, &destination)
                    .map_err(|_| "No se pudo restaurar la dependencia anterior")?;
            }
            return Err("No se pudo instalar la dependencia");
        }
        crate::file_security::sync_directory(&deps)
            .map_err(|_| "No se pudo sincronizar la dependencia")?;
        if replacing {
            fs::remove_dir_all(&backup)
                .map_err(|_| "No se pudo retirar la dependencia anterior")?;
        }
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
    if entry.is_empty()
        || entry.starts_with('/')
        || entry.contains(['\\', '\0'])
        || (cfg!(windows) && entry.contains(':'))
    {
        return Err("Ruta de proyecto no permitida".into());
    }
    let parts: Vec<String> = entry.split('/').map(str::to_owned).collect();
    if parts.iter().any(|part| {
        part.is_empty()
            || (cfg!(windows) && crate::file_security::invalid_windows_name(part))
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

#[cfg(unix)]
fn c_name(name: &str) -> Result<CString, String> {
    CString::new(name).map_err(|_| "Ruta inválida".into())
}

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::{symlink, PermissionsExt},
        sync::Arc,
    };

    fn initialize_test(path: &Path, accounts: &Value, vendor: &Path) -> Result<bool, String> {
        let runtime = crate::native::binary("escriba-runtime")?;
        initialize(path, accounts, vendor, &runtime)
    }

    fn project_vendor() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor")
    }

    #[test]
    fn actualiza_dependencia_administrada_y_conserva_archivos_del_usuario() {
        let folder = tempfile::tempdir().unwrap();
        let vendor = tempfile::tempdir().unwrap();
        let source = vendor.path().join("conectores");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("package.json"), "{}").unwrap();
        fs::write(source.join("index.js"), "nuevo").unwrap();
        fs::write(source.join("index.d.ts"), "nuevo").unwrap();
        let managed = folder.path().join(".escriba/deps/conectores");
        fs::create_dir_all(&managed).unwrap();
        fs::write(managed.join("package.json"), "{}").unwrap();
        fs::write(managed.join("index.js"), "viejo").unwrap();
        fs::write(managed.join("index.d.ts"), "viejo").unwrap();
        fs::write(managed.join("sobrante.js"), "obsoleto").unwrap();
        let own = folder
            .path()
            .join("node_modules/@escriba/conectores/index.js");
        fs::create_dir_all(own.parent().unwrap()).unwrap();
        fs::write(&own, "usuario").unwrap();

        install_managed_dependency(
            folder.path(),
            vendor.path(),
            "conectores",
            "conectores",
            true,
        )
        .unwrap();
        assert_eq!(
            fs::read_to_string(managed.join("index.js")).unwrap(),
            "nuevo"
        );
        assert!(!managed.join("sobrante.js").exists());
        assert_eq!(fs::read_to_string(own).unwrap(), "usuario");
    }

    #[test]
    fn proyecto_con_dist_actualiza_copia_antigua_sin_crear_fuentes() {
        let folder = tempfile::tempdir().unwrap();
        let vendor = tempfile::tempdir().unwrap();
        let source = vendor.path().join("node_modules/@escriba/conectores");
        fs::create_dir_all(&source).unwrap();
        for (name, content) in [
            ("package.json", "{}"),
            ("index.js", "export const defineProvider = true"),
            ("index.d.ts", "export declare const defineProvider: boolean"),
        ] {
            fs::write(source.join(name), content).unwrap();
        }
        let managed = folder.path().join(".escriba/deps/conectores");
        fs::create_dir_all(&managed).unwrap();
        for name in ["package.json", "index.js", "index.d.ts"] {
            fs::write(managed.join(name), "viejo").unwrap();
        }
        fs::create_dir(folder.path().join("dist")).unwrap();
        fs::write(
            folder.path().join("dist/escriba.json"),
            r#"{"version":1,"recipes":[]}"#,
        )
        .unwrap();
        let has_dist = initialize(
            folder.path(),
            &json!([]),
            vendor.path(),
            Path::new("/bun/ausente"),
        )
        .unwrap();
        assert!(has_dist);
        assert!(fs::read_to_string(managed.join("index.js"))
            .unwrap()
            .contains("defineProvider"));
        assert!(!folder.path().join("src").exists());
        assert!(!folder.path().join("package.json").exists());
    }

    #[test]
    fn bun_reinstala_conector_file_tras_reemplazar_dependencia_administrada() {
        let folder = tempfile::tempdir().unwrap();
        let vendor = tempfile::tempdir().unwrap();
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let source = vendor.path().join("node_modules/@escriba/conectores");
        fs::create_dir_all(&source).unwrap();
        let package = r#"{"name":"@escriba/conectores","version":"1.0.0","main":"index.js"}"#;
        fs::write(source.join("package.json"), package).unwrap();
        fs::write(
            source.join("index.js"),
            "export const defineProvider = true",
        )
        .unwrap();
        fs::write(
            source.join("index.d.ts"),
            "export declare const defineProvider: boolean",
        )
        .unwrap();
        let managed = folder.path().join(".escriba/deps/conectores");
        fs::create_dir_all(&managed).unwrap();
        fs::write(managed.join("package.json"), package).unwrap();
        fs::write(managed.join("index.js"), "export const oldApi = true").unwrap();
        fs::write(
            managed.join("index.d.ts"),
            "export declare const oldApi: boolean",
        )
        .unwrap();
        fs::write(
            folder.path().join("package.json"),
            r#"{"name":"probe","dependencies":{"@escriba/conectores":"file:.escriba/deps/conectores"}}"#,
        )
        .unwrap();
        let old = run_development(
            folder.path(),
            &runtime,
            vendor.path(),
            &["install", "--ignore-scripts"],
            true,
            true,
            true,
        )
        .unwrap();
        assert!(old.success, "{}", old.output);
        let installed = folder
            .path()
            .join("node_modules/@escriba/conectores/index.js");
        assert!(fs::read_to_string(&installed).unwrap().contains("oldApi"));
        let result = tool(folder.path(), &runtime, vendor.path(), "install").unwrap();
        assert_eq!(result["success"], true, "{result}");
        assert!(fs::read_to_string(installed)
            .unwrap()
            .contains("defineProvider"));
    }

    #[test]
    fn refresca_tipos_generados_sin_pisar_tipos_editados() {
        let folder = tempfile::tempdir().unwrap();
        let types = folder.path().join("escriba-recetas.d.ts");
        let before_versions = TYPES
            .replace("interface InfoDeVersion {\n  readonly clave: string\n  readonly numero: number\n  readonly fecha: string\n  readonly origen: \"receta\" | \"correccion\"\n  readonly receta: string | null\n  readonly vigente: boolean\n  readonly abierta: boolean\n  readonly criterios: OpcionesDeTranscripcion | null\n  readonly tiene: { readonly hablantes: boolean; readonly resumen: boolean; readonly datos: boolean }\n}\n\ninterface OpcionesDeNota {\n  version?: string\n  editar?: boolean\n}\n\n", "")
            .replace("  readonly origen: number | null\n", "")
            .replace("  transcribir(opciones?: OpcionesDeTranscripcion): Promise<Nota>\n", "")
            .replace("  nota(audio: Audio, opciones?: OpcionesDeNota): Promise<Nota>\n  versiones(audio: Audio): Promise<readonly InfoDeVersion[]>\n", "  nota(audio: Audio): Promise<Nota | null>\n");
        assert_eq!(
            format!("{:x}", Sha256::digest(before_versions.as_bytes())),
            PREVIOUS_TYPES_SHA256[4]
        );
        fs::write(&types, &before_versions).unwrap();
        refresh_generated_types(folder.path()).unwrap();
        assert_eq!(fs::read_to_string(&types).unwrap(), TYPES);
        let before_note =
            before_versions.replace("  nota(audio: Audio): Promise<Nota | null>\n", "");
        assert_eq!(
            format!("{:x}", Sha256::digest(before_note.as_bytes())),
            PREVIOUS_TYPES_SHA256[3]
        );
        fs::write(&types, &before_note).unwrap();
        refresh_generated_types(folder.path()).unwrap();
        assert_eq!(fs::read_to_string(&types).unwrap(), TYPES);
        let before_reference = before_note
            .replace("interface ReferenciaDeConocimiento {\n  readonly ontologyId: \"escriba\"\n  readonly table: string\n  readonly id: string\n}\n\n", "")
            .replace("  readonly type: \"text\" | \"number\" | \"boolean\" | \"date\" | \"json\" | \"reference\"\n", "  readonly type: \"text\" | \"number\" | \"boolean\" | \"date\" | \"json\"\n")
            .replace("  readonly reference?: { readonly ontologyId: \"escriba\"; readonly table: ReferenciaDeConocimiento[\"table\"] }\n", "");
        assert_eq!(
            format!("{:x}", Sha256::digest(before_reference.as_bytes())),
            PREVIOUS_TYPES_SHA256[2]
        );
        fs::write(&types, &before_reference).unwrap();
        refresh_generated_types(folder.path()).unwrap();
        assert_eq!(fs::read_to_string(&types).unwrap(), TYPES);
        let before_graph = before_reference
            .replace("  vincular(ontologiaId: string, registroId: string): Promise<void>\n", "")
            .replace("  grafo(ontologiaId: string): Promise<import(\"surrealdb\").Surreal>\n", "")
            .replace("interface DependenciaDeOntologia {\n  readonly id: string\n  readonly minVersion: number\n  readonly maxVersion: number\n}\n\ninterface CampoDeConocimiento {\n  readonly key: string\n  readonly label: string\n  readonly type: \"text\" | \"number\" | \"boolean\" | \"date\" | \"json\"\n  readonly required?: boolean\n}\n\ninterface ColeccionDeConocimiento {\n  readonly table: string\n  readonly label: string\n  readonly titleField: string\n  readonly fields: readonly CampoDeConocimiento[]\n  readonly relation?: { readonly from: string; readonly to: string }\n}\n\ninterface Ontologia {\n  readonly id: string\n  readonly name: string\n  readonly version: number\n  readonly migrations: readonly { readonly version: number; readonly sql: string }[]\n  readonly collections: readonly ColeccionDeConocimiento[]\n}\n\n", "");
        assert_eq!(
            format!("{:x}", Sha256::digest(before_graph.as_bytes())),
            PREVIOUS_TYPES_SHA256[1]
        );
        fs::write(&types, &before_graph).unwrap();
        refresh_generated_types(folder.path()).unwrap();
        assert_eq!(fs::read_to_string(&types).unwrap(), TYPES);
        let previous = before_graph
            .replace("interface InfoDeCuenta {\n  readonly clave: string\n  readonly nombre: string\n  readonly tipo: string\n  readonly activo: boolean\n  readonly origen: string | null\n}\n\ninterface Cuenta {\n  readonly clave: string\n  readonly nombre: string\n  readonly fetch: typeof fetch\n}\n\n", "")
            .replace("  readonly cuentas?: readonly InfoDeCuenta[]\n", "")
            .replace("  cuenta(claveONombre: string): Cuenta\n", "");
        fs::write(&types, previous).unwrap();
        refresh_generated_types(folder.path()).unwrap();
        assert_eq!(fs::read_to_string(&types).unwrap(), TYPES);
        fs::write(&types, "// tipos propios").unwrap();
        refresh_generated_types(folder.path()).unwrap();
        assert_eq!(fs::read_to_string(&types).unwrap(), "// tipos propios");
    }

    #[test]
    fn dependency_del_sdk_conserva_la_version_propia_del_usuario() {
        let folder = tempfile::tempdir().unwrap();
        let package = folder.path().join("package.json");
        let own = br#"{"name":"custom","dependencies":{"surrealdb":"3.0.0","otra":"1.0.0"}}"#;
        fs::write(&package, own).unwrap();
        ensure_sdk_dependency(folder.path()).unwrap();
        assert_eq!(fs::read(&package).unwrap(), own);
        fs::write(
            &package,
            br#"{"name":"custom","dependencies":{"otra":"1.0.0"}}"#,
        )
        .unwrap();
        ensure_sdk_dependency(folder.path()).unwrap();
        let updated: Value = serde_json::from_slice(&fs::read(&package).unwrap()).unwrap();
        assert_eq!(updated["dependencies"]["otra"], "1.0.0");
        assert_eq!(
            updated["dependencies"]["surrealdb"],
            "file:.escriba/deps/surrealdb"
        );
    }

    #[test]
    fn carga_dist_autocontenido_sin_fuentes_ni_dependencias() {
        let folder = tempfile::tempdir().unwrap();
        let dist = folder.path().join("dist");
        fs::create_dir(&dist).unwrap();
        fs::write(dist.join("receta.js"), "var __recipe={flujo(){}}").unwrap();
        fs::write(dist.join("conectores.js"), "var __conectores={}").unwrap();
        fs::write(
            dist.join("ontologias.js"),
            "var __ontologias={ontologias:[]}",
        )
        .unwrap();
        fs::write(
            dist.join("escriba.json"),
            r#"{"version":1,"recipes":[{"id":"mi-receta","name":"Mi receta","entry":"recetas/mi-receta/receta.ts","file":"receta.js"}],"connectors":"conectores.js","ontologies":"ontologias.js"}"#,
        )
        .unwrap();
        let catalog = load(folder.path()).unwrap();
        assert_eq!(catalog["recipes"][0]["id"], "mi-receta");
        assert_eq!(catalog["recipes"][0]["bundle"], "var __recipe={flujo(){}}");
        assert_eq!(catalog["connectorProgram"], "var __conectores={}");
        assert_eq!(
            catalog["ontologyProgram"],
            "var __ontologias={ontologias:[]}"
        );
        fs::write(
            dist.join("escriba.json"),
            r#"{"version":1,"recipes":[],"ontologies":"../outside.js"}"#,
        )
        .unwrap();
        assert!(load(folder.path()).is_err());
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
        assert!(
            crate::confinement::available(),
            "falta escriba-sandbox o el equipo no aísla: ejecuta scripts/build-linux.sh"
        );
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
    fn cargar_proyecto_actualiza_lanzador_administrado_y_conserva_el_del_usuario() {
        let folder = tempfile::tempdir().unwrap();
        let tools = tempfile::tempdir().unwrap();
        let runtime = tools.path().join("bun");
        let vendor = tools.path().join("vendor");
        fs::create_dir_all(vendor.join("node_modules/typescript/lib")).unwrap();
        fs::write(&runtime, "runtime").unwrap();
        fs::write(
            vendor.join(if cfg!(windows) {
                "node_modules/typescript/lib/tsc.exe"
            } else {
                "node_modules/typescript/lib/tsc"
            }),
            "checker",
        )
        .unwrap();
        fs::create_dir(folder.path().join("dist")).unwrap();
        fs::write(
            folder.path().join("dist/escriba.json"),
            r#"{"version":1,"recipes":[]}"#,
        )
        .unwrap();
        let launcher = folder.path().join("escriba");
        fs::write(&launcher, format!("{LAUNCHER_MARKER}old bundle path")).unwrap();
        load_with_tools(folder.path(), &runtime, &vendor).unwrap();
        let updated = fs::read_to_string(&launcher).unwrap();
        assert!(!updated.contains("old bundle path"));
        assert!(updated.contains(runtime.to_str().unwrap()));
        fs::write(&launcher, "user launcher").unwrap();
        load_with_tools(folder.path(), &runtime, &vendor).unwrap();
        assert_eq!(fs::read_to_string(&launcher).unwrap(), "user launcher");
        fs::remove_file(&launcher).unwrap();
        load_with_tools(folder.path(), &runtime, &vendor).unwrap();
        assert!(!launcher.exists());
    }

    #[test]
    fn el_lanzador_aisla_las_herramientas_solo_donde_el_sistema_lo_permite() {
        let source = launcher_source(
            Path::new("/opt/escriba/runtime"),
            Path::new("/opt/escriba/vendor"),
            Path::new("/opt/escriba/tsgo"),
        )
        .unwrap();
        let runs = source
            .lines()
            .filter(|line| line.trim_start().starts_with("exec /usr/bin/env -i "))
            .collect::<Vec<_>>();
        assert_eq!(runs.len(), 2);
        let isolated = crate::confinement::launcher().map(|launcher| launcher.command);
        for run in runs {
            let expected = isolated.as_deref().unwrap_or(r#""$executable""#);
            assert!(run.ends_with(&format!("{expected} \"$@\"")), "{run}");
        }
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
        assert_eq!(
            fs::read_to_string(folder.path().join("src/recetas/ejemplo/receta.ts")).unwrap(),
            EXAMPLE
        );
        assert_eq!(
            fs::read_to_string(folder.path().join("src/recetas/piezas.ts")).unwrap(),
            PIECES
        );
        assert!(!folder.path().join("src/conectores.ts").exists());
        assert!(folder.path().join("escriba-recetas.d.ts").exists());
        let dependency = folder.path().join(".escriba/deps/conectores");
        assert!(dependency.join("index.js").is_file());
        assert!(folder.path().join(".escriba/deps/zod/index.js").is_file());
        assert!(folder
            .path()
            .join(".escriba/deps/surrealdb/index.js")
            .is_file());
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
        assert_eq!(
            serde_json::from_slice::<Value>(&fs::read(folder.path().join("package.json")).unwrap())
                .unwrap()["dependencies"]["surrealdb"],
            "file:.escriba/deps/surrealdb"
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
        let data = tempfile::tempdir().unwrap();
        let scripts = crate::scripts::Scripts::new(runtime)
            .with_env(crate::scripts::controller_env(data.path()));
        let capability: crate::scripts::Capability = Arc::new(|method, params| {
            Box::pin(async move {
                match method.as_str() {
                    "shell.native" => match params["method"].as_str() {
                        Some("status") => Ok(
                            json!({"protocolVersion":1,"whisper":{"available":true},"llm":{"available":true},"problems":[]}),
                        ),
                        Some("transcribe") => Ok(json!({"text":"Audio sintético","segments":[]})),
                        _ => Err("Método nativo inesperado".into()),
                    },
                    "shell.notify" | "shell.native_cancel" | "shell.autolaunch" => Ok(Value::Null),
                    _ => Err(format!("Capacidad inesperada: {method}").into()),
                }
            })
        });
        let events: crate::scripts::Events = Arc::new(|_| {});
        let schema = scripts
            .command(
                "config_save",
                json!({"collection":"recipes","item":recipes.as_array().unwrap().iter().find(|item| item["id"] == "mi-receta").unwrap()}),
                crate::scripts::Origin::Ui,
                capability.clone(),
                events.clone(),
            )
            .await
            .unwrap();
        assert_eq!(schema["id"], "mi-receta");
        scripts
            .command(
                "settings_save",
                json!({"settings":{"defaultRecipeId":"mi-receta"}}),
                crate::scripts::Origin::Ui,
                capability.clone(),
                events.clone(),
            )
            .await
            .unwrap();
        let schema = scripts
            .command(
                "runtime_run",
                json!({"operation":"getRecipeSchema","args":{"recipeId":"mi-receta"}}),
                crate::scripts::Origin::Ui,
                capability.clone(),
                events.clone(),
            )
            .await
            .unwrap();
        assert!(schema.is_null());
        let inbox = data.path().join("inbox");
        fs::create_dir_all(&inbox).unwrap();
        let audio = inbox.join("legacy.wav");
        fs::write(&audio, b"audio sintetico").unwrap();
        let imported = scripts
            .command(
                "import_inbox",
                json!({"files":[{"inbox":audio,"source":"/origen/legacy.wav"}]}),
                crate::scripts::Origin::Shell,
                capability.clone(),
                events.clone(),
            )
            .await
            .unwrap();
        let id = imported[0]["id"].as_str().unwrap();
        let saved = tokio::time::timeout(std::time::Duration::from_secs(20), async {
            loop {
                let saved = scripts
                    .command(
                        "recording_detail",
                        json!({"id":id}),
                        crate::scripts::Origin::Ui,
                        capability.clone(),
                        events.clone(),
                    )
                    .await
                    .unwrap();
                if saved["status"] == "done" || saved["status"] == "failed" {
                    break saved;
                }
                tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(saved["status"], "done");
        assert_eq!(saved["versions"].as_array().unwrap().len(), 1);
        scripts.shutdown().await;
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
        // Without the sandbox the compiler reads the file and Escriba's own check rejects it.
        let expected = if crate::platform::recipes_isolated() {
            "No se pudo compilar evil/receta.ts"
        } else {
            "El paquete evil/receta.ts importa una fuente fuera del proyecto"
        };
        assert!(error.contains(expected), "{error}");
        assert!(!project.join("dist/escriba.json").exists());
    }
}

#[cfg(windows)]
fn read_dist(root: &Path, entry: &str, limit: usize) -> Result<Vec<u8>, String> {
    windows::read_bytes(root, entry, limit)
}
#[cfg(windows)]
pub fn read(path: &Path, entry: &str) -> Result<Value, String> {
    let bytes = windows::read_bytes(&project_root(path)?, entry, SOURCE_LIMIT)?;
    Ok(json!({"source": String::from_utf8(bytes).map_err(|_| "La fuente no es UTF-8")?}))
}
#[cfg(windows)]
pub fn write_checked(
    path: &Path,
    entry: &str,
    source: &str,
    expected_source: Option<&str>,
    create_new: bool,
) -> Result<(), String> {
    windows::write_source(path, entry, source, expected_source, create_new)
}
#[cfg(windows)]
fn launcher_source(runtime: &Path, vendor: &Path, checker: &Path) -> Result<String, String> {
    windows::launcher_source(runtime, vendor, checker)
}
