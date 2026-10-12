use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;
use surrealdb::engine::local::{Db, RocksDb, SurrealKv};
use surrealdb::opt::{auth::Root, Config};
use surrealdb::types::Value as DbValue;
use surrealdb::Surreal;

fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[derive(Debug, PartialEq)]
enum Plan {
    Open,
    Convert,
}

fn plan(legacy_exists: bool) -> Plan {
    if legacy_exists {
        Plan::Convert
    } else {
        Plan::Open
    }
}

#[derive(Clone, Copy)]
enum Engine {
    RocksDb,
    SurrealKv,
}

fn retired(legacy: &Path) -> PathBuf {
    let base = legacy.with_extension("surrealkv.convertida");
    let mut candidate = base.clone();
    let mut attempt = 1;
    while candidate.exists() {
        attempt += 1;
        candidate = PathBuf::from(format!("{}-{attempt}", base.display()));
    }
    candidate
}

pub(crate) async fn open(
    target: &Path,
    config: Config,
    root: Option<Root>,
) -> Result<Surreal<Db>, String> {
    let extension = target.extension().and_then(|e| e.to_str());
    if extension == Some("surrealkv") {
        return Err(format!("{} no es una base RocksDB", target.display()));
    }
    let legacy = target.with_extension("surrealkv");
    match plan(extension == Some("rocksdb") && legacy.exists()) {
        Plan::Open => {
            protect(target)?;
            connect(Engine::RocksDb, target, config, root.as_ref()).await
        }
        Plan::Convert => {
            convert(&legacy, target, config.clone(), root.as_ref()).await?;
            connect(Engine::RocksDb, target, config, root.as_ref()).await
        }
    }
}

fn protect(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(path).map_err(error)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).map_err(error)
}

async fn connect(
    engine: Engine,
    path: &Path,
    config: Config,
    root: Option<&Root>,
) -> Result<Surreal<Db>, String> {
    let mut attempts = 0;
    loop {
        let opened = match engine {
            Engine::RocksDb => Surreal::new::<RocksDb>((path.to_path_buf(), config.clone())).await,
            Engine::SurrealKv => {
                Surreal::new::<SurrealKv>((path.to_path_buf(), config.clone())).await
            }
        };
        match opened {
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

async fn info(db: &Surreal<Db>, sql: &str) -> Result<Value, String> {
    let mut response = db.query(sql).await.map_err(error)?.check().map_err(error)?;
    let value: DbValue = response.take(0).map_err(error)?;
    Ok(value.into_json_value())
}

fn names(info: &Value, key: &str) -> Vec<String> {
    info[key]
        .as_object()
        .map(|entries| entries.keys().cloned().collect())
        .unwrap_or_default()
}

async fn inventory(db: &Surreal<Db>, root: Option<&Root>) -> Result<Vec<(String, String)>, String> {
    let system = info(db, "INFO FOR ROOT").await?;
    let users = names(&system, "users");
    if !names(&system, "accesses").is_empty()
        || users
            .iter()
            .any(|user| Some(user) != root.map(|root| &root.username))
    {
        return Err("La base tiene definiciones de sistema que la conversión no copia".into());
    }
    let mut databases = Vec::new();
    for namespace in names(&system, "namespaces") {
        db.use_ns(&namespace).await.map_err(error)?;
        let definition = info(db, "INFO FOR NS").await?;
        if !names(&definition, "users").is_empty() || !names(&definition, "accesses").is_empty() {
            return Err(
                "La base tiene definiciones de espacio de nombres que la conversión no copia"
                    .into(),
            );
        }
        for database in names(&definition, "databases") {
            databases.push((namespace.clone(), database));
        }
    }
    Ok(databases)
}

async fn rows(db: &Surreal<Db>, table: &str) -> Result<Vec<DbValue>, String> {
    let mut response = db
        .query("SELECT * FROM type::table($table) ORDER BY id")
        .bind(("table", table.to_owned()))
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    response.take(0).map_err(error)
}

async fn verify(
    source: &Surreal<Db>,
    target: &Surreal<Db>,
    databases: &[(String, String)],
) -> Result<(), String> {
    for (namespace, database) in databases {
        source
            .use_ns(namespace)
            .use_db(database)
            .await
            .map_err(error)?;
        target
            .use_ns(namespace)
            .use_db(database)
            .await
            .map_err(error)?;
        let definition = info(source, "INFO FOR DB").await?;
        if definition != info(target, "INFO FOR DB").await? {
            return Err(format!(
                "La conversión cambió la definición de {namespace}/{database}"
            ));
        }
        for table in names(&definition, "tables") {
            let sql = format!("INFO FOR TABLE `{table}`");
            if info(source, &sql).await? != info(target, &sql).await?
                || rows(source, &table).await? != rows(target, &table).await?
            {
                return Err(format!(
                    "La conversión cambió la tabla {table} de {namespace}/{database}"
                ));
            }
        }
    }
    Ok(())
}

async fn copy(
    source: &Surreal<Db>,
    target: &Surreal<Db>,
    databases: &[(String, String)],
    dumps: &Path,
) -> Result<(), String> {
    for (index, (namespace, database)) in databases.iter().enumerate() {
        let dump = dumps.join(format!("{index}.surql"));
        source
            .use_ns(namespace)
            .use_db(database)
            .await
            .map_err(error)?;
        source
            .export(&dump)
            .with_config()
            .accesses(false)
            .await
            .map_err(error)?;
        target
            .use_ns(namespace)
            .use_db(database)
            .await
            .map_err(error)?;
        target.import(&dump).await.map_err(error)?;
        for access in names(&info(source, "INFO FOR DB").await?, "accesses") {
            if access != "_escriba_recipe" {
                return Err(format!("Acceso desconocido en {namespace}/{database}"));
            }
            target
                .query(crate::knowledge::RECIPE_ACCESS)
                .await
                .map_err(error)?
                .check()
                .map_err(error)?;
        }
    }
    Ok(())
}

async fn convert(
    legacy: &Path,
    target: &Path,
    config: Config,
    root: Option<&Root>,
) -> Result<(), String> {
    if target.exists() {
        std::fs::remove_dir_all(target).map_err(error)?;
    }
    let dumps = target.with_extension("exportacion");
    if dumps.exists() {
        std::fs::remove_dir_all(&dumps).map_err(error)?;
    }
    protect(&dumps)?;
    let unbounded = config.query_timeout(None).transaction_timeout(None);
    let converted = transfer(legacy, target, unbounded, root, &dumps).await;
    std::fs::remove_dir_all(&dumps).map_err(error)?;
    drop(converted?);
    released(target).await?;
    std::fs::rename(legacy, retired(legacy)).map_err(error)
}

async fn transfer(
    legacy: &Path,
    target: &Path,
    config: Config,
    root: Option<&Root>,
    dumps: &Path,
) -> Result<Surreal<Db>, String> {
    let source = connect(Engine::SurrealKv, legacy, config.clone(), root).await?;
    let prepared = async {
        let databases = inventory(&source, root).await?;
        protect(target)?;
        let converted = connect(Engine::RocksDb, target, config, root).await?;
        let checked = async {
            copy(&source, &converted, &databases, dumps).await?;
            verify(&source, &converted, &databases).await?;
            converted
                .query("ALTER SYSTEM COMPACT")
                .await
                .map_err(error)?
                .check()
                .map_err(error)
        }
        .await;
        match checked {
            Ok(_) => Ok(converted),
            Err(e) => {
                drop(converted);
                released(target).await?;
                Err(e)
            }
        }
    }
    .await;
    drop(source);
    released(legacy).await?;
    prepared
}

#[cfg(test)]
mod tests;
