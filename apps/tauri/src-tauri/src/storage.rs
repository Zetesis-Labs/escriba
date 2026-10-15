use std::path::Path;
use std::time::Duration;
use surrealdb::engine::local::{Db, RocksDb};
use surrealdb::opt::{auth::Root, Config};
use surrealdb::Surreal;

#[cfg(all(test, any(target_os = "macos", target_os = "windows")))]
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}

pub(crate) async fn open(
    target: &Path,
    config: Config,
    root: Option<Root>,
) -> Result<Surreal<Db>, String> {
    let legacy = target.with_extension("surrealkv");
    if legacy.exists() {
        return Err(format!(
            "{} está en SurrealKV y esta versión ya no lo convierte",
            legacy.display()
        ));
    }
    protect(target)?;
    connect(target, config, root.as_ref()).await
}

fn protect(path: &Path) -> Result<(), String> {
    crate::file_security::protect_directory(path)
}

#[cfg(not(test))]
async fn engine(path: &Path, config: Config) -> surrealdb::Result<Surreal<Db>> {
    Surreal::new::<RocksDb>((path.to_path_buf(), config)).await
}

// Each #[tokio::test] drops its runtime on return, which cuts the datastore
// shutdown short and leaks its threads, open files and memtables.
#[cfg(test)]
async fn engine(path: &Path, config: Config) -> surrealdb::Result<Surreal<Db>> {
    static RUNTIME: std::sync::LazyLock<tokio::runtime::Runtime> = std::sync::LazyLock::new(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("runtime de bases de prueba")
    });
    let path = path.to_path_buf();
    RUNTIME
        .spawn(async move { Surreal::new::<RocksDb>((path, config)).await })
        .await
        .expect("la apertura de la base de prueba no terminó")
}

async fn connect(path: &Path, config: Config, root: Option<&Root>) -> Result<Surreal<Db>, String> {
    let mut attempts = 0;
    loop {
        match engine(path, config.clone()).await {
            Ok(db) => {
                if let Some(root) = root {
                    db.signin(root.clone())
                        .await
                        .map_err(|e| format!("No se pudo abrir {}: {e}", path.display()))?;
                }
                return Ok(db);
            }
            Err(e) if attempts < 200 && e.to_string().to_lowercase().contains("lock") => {
                attempts += 1;
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(e) => return Err(format!("No se pudo abrir {}: {e}", path.display())),
        }
    }
}

#[cfg(all(test, target_os = "windows"))]
pub(crate) async fn released(path: &Path) -> Result<(), String> {
    use fs2::FileExt;
    let lock = path.join("LOCK");
    for _ in 0..400 {
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&lock)
        {
            Ok(file) if file.try_lock_exclusive().is_ok() => {
                file.unlock().map_err(error)?;
                return Ok(());
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            _ => tokio::time::sleep(Duration::from_millis(25)).await,
        }
    }
    Err(format!("{} no liberó su bloqueo", path.display()))
}

// RocksDB locks with fcntl, which on Linux neither conflicts with flock nor
// with other locks of the same process; its open LOCK descriptor does tell.
#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
pub(crate) async fn released(path: &Path) -> Result<(), String> {
    let lock = path.join("LOCK");
    for _ in 0..400 {
        if !held_by_this_process(&lock) {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    Err(format!("{} no liberó su bloqueo", path.display()))
}

#[cfg(all(test, target_os = "macos"))]
fn held_by_this_process(lock: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(lock) = lock.canonicalize() else {
        return false;
    };
    std::fs::read_dir("/dev/fd")
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse::<i32>().ok())
        .any(|descriptor| {
            let mut buffer = [0u8; libc::PATH_MAX as usize];
            // SAFETY: F_GETPATH writes at most PATH_MAX bytes, NUL included, into the buffer.
            let found = unsafe { libc::fcntl(descriptor, libc::F_GETPATH, buffer.as_mut_ptr()) };
            found == 0
                && std::ffi::CStr::from_bytes_until_nul(&buffer).is_ok_and(|path| {
                    Path::new(std::ffi::OsStr::from_bytes(path.to_bytes())) == lock
                })
        })
}

#[cfg(all(test, target_os = "linux"))]
fn held_by_this_process(lock: &Path) -> bool {
    let Ok(lock) = lock.canonicalize() else {
        return false;
    };
    std::fs::read_dir("/proc/self/fd")
        .into_iter()
        .flatten()
        .filter_map(|entry| std::fs::read_link(entry.ok()?.path()).ok())
        .any(|target| target == lock)
}

#[cfg(test)]
mod tests;
