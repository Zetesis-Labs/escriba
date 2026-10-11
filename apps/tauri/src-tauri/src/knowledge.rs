use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{path::Path, time::Duration};
use surrealdb::types::{SurrealValue, Value as DbValue};
use surrealdb::{
    engine::local::{Db, SurrealKv},
    opt::{
        auth::{Database, Record, Root},
        Config,
    },
    Surreal,
};
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Ontology {
    pub id: String,
    pub name: String,
    pub version: u32,
    pub migrations: Vec<Migration>,
    pub collections: Vec<Collection>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Migration {
    pub version: u32,
    pub sql: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Collection {
    pub table: String,
    pub label: String,
    pub title_field: String,
    pub fields: Vec<Field>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relation: Option<Relation>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Relation {
    pub from: String,
    pub to: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Field {
    pub key: String,
    pub label: String,
    #[serde(rename = "type")]
    pub kind: FieldType,
    #[serde(default)]
    pub required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<ReferenceTarget>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReferenceTarget {
    pub ontology_id: String,
    pub table: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum FieldType {
    Text,
    Number,
    Boolean,
    Date,
    Json,
    Reference,
}

mod base;
mod base_query;
pub use base::{base_definition, base_listing};
mod graph;
#[cfg(test)]
mod graph_tests;
mod migrations;
mod records;
pub use records::{SaveRecord, Source};

pub struct Knowledge {
    root: Mutex<Surreal<Db>>,
    pub(crate) base_sync: Mutex<()>,
    #[cfg(test)]
    path: std::path::PathBuf,
}
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn database(id: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("ontology_{:x}", Sha256::digest(id.as_bytes()))
}

impl Knowledge {
    pub async fn open(path: &Path) -> Result<Self, String> {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        std::fs::create_dir_all(path).map_err(error)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).map_err(error)?;
        use std::io::Write;
        let key_path = path.with_extension("key");
        let password = match std::fs::read_to_string(&key_path) {
            Ok(key) => key,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let key = Uuid::new_v4().to_string();
                let mut file = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&key_path)
                    .map_err(error)?;
                file.write_all(key.as_bytes()).map_err(error)?;
                file.sync_all().map_err(error)?;
                key
            }
            Err(e) => return Err(error(e)),
        };
        let credentials = Root {
            username: "escriba".into(),
            password,
        };
        let capabilities = surrealdb::opt::capabilities::Capabilities::default()
            .with_scripting(false)
            .with_guest_access(false)
            .with_live_query_notifications(false)
            .with_all_net_targets_denied()
            .with_all_experimental_features_denied();
        let config = Config::new()
            .capabilities(capabilities)
            .user(credentials.clone())
            .query_timeout(Duration::from_secs(10))
            .transaction_timeout(Duration::from_secs(30));
        let root = Surreal::new::<SurrealKv>((path, config))
            .await
            .map_err(error)?;
        root.signin(credentials).await.map_err(error)?;
        root.use_ns("knowledge")
            .use_db("registry")
            .await
            .map_err(error)?;
        root.query("DEFINE TABLE IF NOT EXISTS ontology SCHEMALESS PERMISSIONS NONE")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let knowledge = Self {
            root: Mutex::new(root),
            base_sync: Mutex::new(()),
            #[cfg(test)]
            path: path.to_path_buf(),
        };
        knowledge.initialize_base().await?;
        Ok(knowledge)
    }
}

#[cfg(test)]
mod base_safety_tests;
#[cfg(test)]
mod base_tests;
#[cfg(test)]
mod tests;

pub fn validate_catalog(ontologies: &[Ontology]) -> Result<(), String> {
    if ontologies.len() > 64 {
        return Err("El proyecto declara más de 64 ontologías".into());
    }
    let mut ids = std::collections::HashSet::new();
    let mut size = 0usize;
    for ontology in ontologies {
        size = size.saturating_add(serde_json::to_vec(ontology).map_err(error)?.len());
        if size > 1_048_576 {
            return Err("Las definiciones de ontología superan 1 MiB".into());
        }
        validate(ontology)?;
        if !ids.insert(&ontology.id) {
            return Err("Identificador de ontología duplicado".into());
        }
    }
    Ok(())
}
fn validate(ontology: &Ontology) -> Result<(), String> {
    if ontology.id == "escriba" {
        return Err("La ontología base de Escriba la mantiene la aplicación".into());
    }
    if ontology.id.is_empty()
        || ontology.id.len() > 200
        || ontology.name.trim().is_empty()
        || ontology.version == 0
    {
        return Err("Ontología sin identidad, nombre o versión válida".into());
    }
    if ontology.migrations.len() != ontology.version as usize
        || ontology
            .migrations
            .iter()
            .enumerate()
            .any(|(i, m)| m.version != i as u32 + 1 || m.sql.trim().is_empty())
    {
        return Err("Las migraciones deben ser acumulativas y consecutivas desde 1".into());
    }
    for migration in &ontology.migrations {
        migrations::validate_sql(&migration.sql)?;
    }
    let mut tables = std::collections::HashSet::new();
    for collection in &ontology.collections {
        identifier(&collection.table)?;
        identifier(&collection.title_field)?;
        if !tables.insert(&collection.table) {
            return Err("Colección duplicada".into());
        }
        let mut field_keys = std::collections::HashSet::new();
        for field in &collection.fields {
            identifier(&field.key)?;
            if matches!(field.key.as_str(), "id" | "in" | "out") || !field_keys.insert(&field.key) {
                return Err("Campo de colección duplicado o reservado".into());
            }
            match (&field.kind, &field.reference) {
                (FieldType::Reference, Some(target))
                    if target.ontology_id == "escriba"
                        && base_definition().collections.iter().any(|collection| {
                            collection.table == target.table && collection.relation.is_none()
                        }) => {}
                (FieldType::Reference, _) | (_, Some(_)) => {
                    return Err(
                        "Referencia de campo inválida; elige una entidad de la base de Escriba"
                            .into(),
                    )
                }
                _ => {}
            }
        }
        if let Some(relation) = &collection.relation {
            identifier(&relation.from)?;
            identifier(&relation.to)?;
        }
    }
    Ok(())
}
fn identifier(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.starts_with('_')
        || !value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_')
        || value.as_bytes()[0].is_ascii_digit()
    {
        return Err(format!(
            "Identificador de colección o campo inválido: {value}"
        ));
    }
    Ok(())
}
async fn manifest(db: &Surreal<Db>) -> Result<Option<Ontology>, String> {
    let mut result = db
        .query("SELECT VALUE definition FROM _escriba_manifest:current")
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    let result: Vec<Value> = result.take(0).map_err(error)?;
    result
        .into_iter()
        .next()
        .map(serde_json::from_value)
        .transpose()
        .map_err(error)
}
async fn runtime(root: &Surreal<Db>, id: &str) -> Result<Surreal<Db>, String> {
    let session = root.clone();
    session
        .signin(Record {
            namespace: "knowledge".into(),
            database: database(id),
            access: "_escriba_recipe".into(),
            params: serde_json::json!({}),
        })
        .await
        .map_err(error)?;
    Ok(session)
}
async fn selected(root: &Surreal<Db>, id: &str) -> Result<Surreal<Db>, String> {
    let db = root.clone();
    db.use_ns("knowledge")
        .use_db(database(id))
        .await
        .map_err(error)?;
    Ok(db)
}
fn values(mut response: surrealdb::IndexedResults) -> Result<Vec<DbValue>, String> {
    response = response.check().map_err(error)?;
    (0..response.num_statements())
        .map(|index| response.take(index).map_err(error))
        .collect()
}
impl Knowledge {
    pub async fn list(&self) -> Result<Vec<Ontology>, String> {
        let root = self.root.lock().await;
        let mut rows = root
            .query("SELECT VALUE ontology_id FROM ontology")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let ids: Vec<String> = rows.take(0).map_err(error)?;
        let mut result = Vec::new();
        for id in ids {
            if let Some(value) = manifest(&selected(&root, &id).await?).await? {
                result.push(value);
            }
        }
        result.sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
        Ok(result)
    }
    pub async fn apply(&self, ontology: Ontology) -> Result<Ontology, String> {
        validate_catalog(std::slice::from_ref(&ontology))?;
        let root = self.root.lock().await;
        let db = selected(&root, &ontology.id).await?;
        db.query("DEFINE TABLE IF NOT EXISTS _escriba_manifest SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS _escriba_manual SCHEMALESS PERMISSIONS FOR select FULL FOR create, update, delete NONE; DEFINE TABLE IF NOT EXISTS _escriba_source SCHEMALESS PERMISSIONS FOR select FULL FOR create, update, delete NONE; DEFINE TABLE IF NOT EXISTS _escriba_principal SCHEMALESS PERMISSIONS NONE")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let existing = manifest(&db).await?;
        if let Some(current) = &existing {
            if current.version > ontology.version {
                return Err("No se puede bajar la versión de una ontología".into());
            }
            if current.version == ontology.version {
                return if current == &ontology {
                    Ok(current.clone())
                } else {
                    Err("La versión instalada es inmutable: su definición es distinta".into())
                };
            }
            if ontology.migrations[..current.migrations.len()] != current.migrations {
                return Err("Las migraciones ya aplicadas son inmutables".into());
            }
        }
        root.query("UPSERT type::record('ontology', $key) SET ontology_id = $id")
            .bind(("key", database(&ontology.id)))
            .bind(("id", ontology.id.clone()))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let password = Uuid::new_v4().to_string();
        db.query(format!(
            "DEFINE USER OVERWRITE _escriba_migrator ON DB PASSWORD '{password}' ROLES OWNER"
        ))
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
        let migrator = db.clone();
        migrator
            .signin(Database {
                namespace: "knowledge".into(),
                database: database(&ontology.id),
                username: "_escriba_migrator".into(),
                password,
            })
            .await
            .map_err(error)?;
        let tx = migrator.begin().await.map_err(error)?;
        let result: Result<(),String> = async {
            let before=migrations::host_state(&tx).await?;
            for migration in ontology.migrations.iter().skip(existing.as_ref().map_or(0,|o|o.version as usize)) {
                tx.query(&migration.sql).await.map_err(error)?.check().map_err(error)?;
                #[cfg(test)]
                tests::migration_checkpoint(migration.version).await?;
            }
            if migrations::host_state(&tx).await? != before {return Err("La migración intentó modificar el estado reservado del host".into())}
            tx.query("DEFINE TABLE OVERWRITE _escriba_manifest SCHEMALESS PERMISSIONS NONE; DEFINE TABLE OVERWRITE _escriba_manual SCHEMALESS PERMISSIONS FOR select FULL FOR create, update, delete NONE; DEFINE TABLE OVERWRITE _escriba_source SCHEMALESS PERMISSIONS FOR select FULL FOR create, update, delete NONE; DEFINE TABLE OVERWRITE _escriba_principal SCHEMALESS PERMISSIONS NONE; UPSERT _escriba_principal:runtime; DEFINE ACCESS OVERWRITE _escriba_recipe ON DB TYPE RECORD SIGNIN (RETURN _escriba_principal:runtime) DURATION FOR SESSION 1h; UPSERT _escriba_manifest:current SET definition = $definition;")
                .bind(("definition",serde_json::to_value(&ontology).map_err(error)?)).await.map_err(error)?.check().map_err(error)?;
            let mut info=tx.query("INFO FOR DB").await.map_err(error)?.check().map_err(error)?;
            let info:DbValue=info.take(0).map_err(error)?;
            let info=info.into_json_value();
            for collection in &ontology.collections {
                if info["tables"].get(&collection.table).is_none() {return Err(format!("La colección {} no tiene una tabla definida",collection.table))}
                tx.query(format!("DEFINE EVENT OVERWRITE _escriba_manual_guard ON TABLE `{}` WHEN $auth != NONE AND $event IN ['UPDATE','DELETE'] AND array::len((SELECT VALUE id FROM _escriba_manual WHERE record = $before.id)) > 0 THEN {{ THROW 'El registro tiene correcciones manuales; la receta no puede sobrescribirlo'; }}",collection.table)).await.map_err(error)?.check().map_err(error)?;
            }
            Ok(())
        }.await;
        match result {
            Ok(()) => {
                tx.commit().await.map_err(error)?;
                Ok(ontology)
            }
            Err(e) => {
                tx.cancel()
                    .await
                    .map_err(|cancel| format!("{e}; rollback: {cancel}"))?;
                Err(e)
            }
        }
    }
    #[cfg(test)]
    pub async fn query(
        &self,
        id: &str,
        expected_version: u32,
        sql: &str,
        bindings: Value,
    ) -> Result<Vec<Value>, String> {
        Ok(self
            .query_native(id, expected_version, sql, bindings.into_value())
            .await?
            .into_iter()
            .map(DbValue::into_json_value)
            .collect())
    }
    pub async fn query_cbor(
        &self,
        id: &str,
        expected_version: u32,
        sql: &str,
        bindings: &str,
    ) -> Result<String, String> {
        if bindings.len() > 1_400_000 {
            return Err("Los parámetros superan 1 MiB".into());
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(bindings)
            .map_err(error)?;
        let bindings = surrealdb_core::rpc::format::cbor::decode(&bytes, 64).map_err(error)?;
        let results = self
            .query_native(id, expected_version, sql, bindings)
            .await?;
        let encoded = surrealdb_core::rpc::format::cbor::encode(DbValue::Array(results.into()))
            .map_err(error)?;
        if encoded.len() > 8_388_608 {
            return Err("El resultado supera 8 MiB; pagina la consulta".into());
        }
        Ok(base64::engine::general_purpose::STANDARD.encode(encoded))
    }
    async fn query_native(
        &self,
        id: &str,
        expected_version: u32,
        sql: &str,
        bindings: DbValue,
    ) -> Result<Vec<DbValue>, String> {
        if sql.len() > 1_000_000 {
            return Err("Consulta demasiado grande".into());
        }
        if id == "escriba" {
            base_query::validate(sql)?;
        }
        if !matches!(bindings, DbValue::Object(_)) {
            return Err("Los parámetros deben ser un objeto".into());
        }
        let root = self.root.lock().await;
        let current = manifest(&selected(&root, id).await?)
            .await?
            .ok_or("Ontología no instalada")?;
        if expected_version == 0 || current.version != expected_version {
            return Err("La versión instalada no satisface la dependencia".into());
        }
        let db = runtime(&root, id).await?;
        values(db.query(sql).bind(bindings).await.map_err(error)?)
    }
}

impl Knowledge {
    #[cfg(test)]
    pub async fn close(self) -> Result<(), String> {
        use fs2::FileExt;
        let path = self.path.join("LOCK");
        drop(self.root);
        for _ in 0..200 {
            if let Ok(file) = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&path)
            {
                if file.try_lock_exclusive().is_ok() {
                    file.unlock().map_err(error)?;
                    return Ok(());
                }
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        Err("SurrealKV no liberó el bloqueo al cerrar".into())
    }
}
