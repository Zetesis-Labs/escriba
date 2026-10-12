use crate::voices::{KnownVoice, SpeakerVoice};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::Path,
};
use surrealdb::{engine::local::Db, types::SurrealValue, Surreal};
use uuid::Uuid;
mod changes;
mod index;
mod knowledge;
mod logs;
pub use changes::{changes, Children, RowOp};
use changes::{RowWrite, Table};
use index::{load_index, preview_for, recording};
pub use knowledge::CoreChange;
pub use logs::LogQuery;
#[cfg(test)]
pub use logs::RETAINED as LOG_RETAINED;

#[derive(Clone, Debug, SurrealValue)]
struct Row {
    key: String,
    parent: String,
    position: i64,
    payload: Value,
}

#[derive(Default)]
pub struct WriteScope {
    pub full_recordings: HashSet<String>,
    pub recipe_aliases: HashMap<String, String>,
    pub draft_change: Option<(String, Option<Value>)>,
    pub draft_receipt: Option<(String, String, Value)>,
}

#[derive(Default)]
pub struct LibraryWrite {
    pub ops: Vec<RowOp>,
    pub recipe_aliases: HashMap<String, String>,
    pub draft_change: Option<(String, Option<Value>)>,
    pub draft_receipt: Option<(String, String, Value)>,
    pub audio_deletions: Vec<AudioDeletion>,
    pub version_voices: Option<(String, Vec<SpeakerVoice>)>,
    pub teaching: Option<Teaching>,
    pub logs: Vec<Value>,
}

impl WriteScope {
    pub fn into_write(self, ops: Vec<RowOp>) -> LibraryWrite {
        LibraryWrite {
            ops,
            recipe_aliases: self.recipe_aliases,
            draft_change: self.draft_change,
            draft_receipt: self.draft_receipt,
            ..LibraryWrite::default()
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
struct PersonRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    color: Option<String>,
    id: String,
    name: String,
    created_at: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct PersonVoiceRecord {
    id: String,
    person_id: String,
    model: String,
    embedding: Vec<f32>,
    source: String,
    added_at: String,
}

#[derive(Clone, Deserialize, Serialize)]
struct VersionVoiceRecord {
    id: String,
    version_id: String,
    speaker: String,
    model: String,
    embedding: Vec<f32>,
}

#[derive(Clone)]
pub struct Teaching {
    pub person: String,
    pub voices: Vec<SpeakerVoice>,
    pub source: String,
    pub existing_only: bool,
}

struct TeachingPlan {
    person: PersonRecord,
    fresh: bool,
    voices: Vec<SpeakerVoice>,
    source: String,
    start_position: i64,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct AudioDeletion {
    pub id: String,
    pub path: String,
    pub device: u64,
    pub inode: u64,
}

impl AudioDeletion {
    pub fn new(path: String, device: u64, inode: u64) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            path,
            device,
            inode,
        }
    }
}

#[derive(Clone)]
pub struct Persistence {
    db: Surreal<Db>,
}

impl Persistence {
    pub async fn open(path: &Path) -> Result<Self, String> {
        Ok(Self {
            db: connect(path).await?,
        })
    }
    pub async fn knowledge_prepare(&self, epoch: &str) -> Result<(), String> {
        knowledge::prepare(&self.db, epoch).await
    }
    pub async fn knowledge_change(&self) -> Result<Option<CoreChange>, String> {
        knowledge::change(&self.db).await
    }
    pub async fn knowledge_ack(&self, key: &str, revision: &str) -> Result<(), String> {
        knowledge::ack(&self.db, key, revision).await
    }
    pub async fn load(&self) -> Result<Option<Value>, String> {
        load(&self.db).await
    }
    pub async fn load_index(&self) -> Result<Option<Value>, String> {
        load_index(&self.db).await
    }
    pub async fn draft_read(&self, key: &str, receipt: bool) -> Result<Option<Value>, String> {
        let table = if receipt {
            "note_draft_receipt"
        } else {
            "note_draft"
        };
        let row: Option<Row> = self
            .db
            .select((table, key))
            .await
            .map_err(|e| e.to_string())?;
        Ok(row.map(|row| row.payload))
    }
    pub async fn recording(&self, id: &str) -> Result<Option<Value>, String> {
        recording(&self.db, id).await
    }
    pub async fn write(&self, write: LibraryWrite) -> Result<bool, String> {
        apply(&self.db, &write).await
    }
    pub async fn append_log(&self, entry: &Value) -> Result<(), String> {
        logs::append(&self.db, entry).await
    }
    pub async fn log_list(&self, query: LogQuery) -> Result<Vec<Value>, String> {
        logs::list(&self.db, &query).await
    }
    #[cfg(test)]
    pub async fn save(&self, before: Value, after: Value) -> Result<(), String> {
        let before = crate::store::LibraryData::read(&before)?;
        let after = crate::store::LibraryData::read(&after)?;
        self.write(LibraryWrite {
            ops: changes(&before, &after, Children::All)?,
            ..LibraryWrite::default()
        })
        .await
        .map(|_| ())
    }
    #[cfg(test)]
    pub async fn save_scoped(
        &self,
        before: Value,
        after: Value,
        scope: WriteScope,
    ) -> Result<(), String> {
        let before = crate::store::LibraryData::read(&before)?;
        let after = crate::store::LibraryData::read(&after)?;
        let ops = changes(&before, &after, Children::Only(&scope.full_recordings))?;
        self.write(scope.into_write(ops)).await.map(|_| ())
    }
    pub async fn pending_audio_deletions(&self) -> Result<Vec<AudioDeletion>, String> {
        pending_audio_deletions(&self.db).await
    }
    pub async fn complete_audio_deletion(&self, id: &str) -> Result<(), String> {
        complete_audio_deletion(&self.db, id).await
    }
    pub async fn jobs(&self) -> Result<Vec<Value>, String> {
        jobs(&self.db).await
    }
    pub async fn jobs_active(&self) -> Result<Vec<Value>, String> {
        jobs_active(&self.db).await
    }
    pub async fn jobs_for(&self, recording: &str) -> Result<Vec<Value>, String> {
        jobs_for(&self.db, recording).await
    }
    pub async fn job(&self, id: &str) -> Result<Option<Value>, String> {
        job(&self.db, id).await
    }
    pub async fn save_job(&self, job: &Value) -> Result<(), String> {
        save_job(&self.db, job).await
    }
    #[cfg(test)]
    pub async fn remove_job(&self, id: &str) -> Result<(), String> {
        remove_job(&self.db, id).await
    }
    pub async fn recall(&self, key: &str) -> Result<Option<Value>, String> {
        recall(&self.db, key).await
    }
    pub async fn keep(&self, key: &str, parent: &str, value: &Value) -> Result<(), String> {
        keep(&self.db, key, parent, value).await
    }
    pub async fn trace_save(&self, value: &Value) -> Result<(), String> {
        trace_save(&self.db, value).await
    }
    pub async fn trace_list(&self, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
        trace_list(&self.db, recording_id).await
    }
    pub async fn people(&self) -> Result<Value, String> {
        people(&self.db).await
    }
    pub async fn known_voices(&self) -> Result<Vec<KnownVoice>, String> {
        known_voices(&self.db).await
    }
    pub async fn add_person_voice(
        &self,
        name: &str,
        voice: &SpeakerVoice,
        source: &str,
    ) -> Result<(), String> {
        add_person_voice(&self.db, name, voice, source).await
    }
    pub async fn set_person_color(&self, name: &str, color: &str) -> Result<(), String> {
        set_person_color(&self.db, name, color).await
    }
    pub async fn rename_person(&self, name: &str, new_name: &str) -> Result<(), String> {
        rename_person(&self.db, name, new_name).await
    }
    pub async fn remove_person_voice(&self, id: &str) -> Result<(), String> {
        remove_person_voice(&self.db, id).await
    }
    pub async fn remove_person(&self, name: &str) -> Result<(), String> {
        remove_person(&self.db, name).await
    }
    pub async fn version_voices(&self, id: &str) -> Result<Vec<SpeakerVoice>, String> {
        version_voices(&self.db, id).await
    }
    #[cfg(test)]
    pub async fn query_test(&self, query: &str) -> Result<(), String> {
        self.db
            .query(query)
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    #[cfg(test)]
    pub async fn select_test(&self, query: &str) -> Result<Vec<Value>, String> {
        let mut response = self
            .db
            .query(query)
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        response.take(0).map_err(|e| e.to_string())
    }
    #[cfg(test)]
    pub async fn downgrade_v1_test(&self) -> Result<(), String> {
        downgrade_v1_test(&self.db).await
    }
}

async fn connect(path: &Path) -> Result<Surreal<Db>, String> {
    let db = crate::storage::open(path, surrealdb::opt::Config::new(), None).await?;
    db.use_ns("escriba")
        .use_db("library")
        .await
        .map_err(|e| e.to_string())?;
    for table in [
        "meta",
        "recording",
        "version",
        "publication",
        "version_preview",
        "publication_preview",
        "account",
        "resolver",
        "recipe",
        "destination",
        "provider",
        "log",
        "setting",
        "job",
        "memory",
        "trace",
        "person",
        "person_voice",
        "voice",
        "audio_deletion",
        "note_draft",
        "note_draft_receipt",
    ] {
        db.query(format!("DEFINE TABLE IF NOT EXISTS {table} SCHEMALESS"))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        db.query(format!(
            "DEFINE INDEX IF NOT EXISTS idx_{table}_key ON TABLE {table} FIELDS key UNIQUE"
        ))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
        if [
            "version",
            "publication",
            "version_preview",
            "publication_preview",
            "job",
            "memory",
            "trace",
            "person_voice",
            "voice",
            "note_draft",
            "note_draft_receipt",
        ]
        .contains(&table)
        {
            db.query(format!(
                "DEFINE INDEX IF NOT EXISTS idx_{table}_parent ON TABLE {table} FIELDS parent"
            ))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        }
    }
    db.query("DEFINE INDEX IF NOT EXISTS idx_job_state ON TABLE job FIELDS state")
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    migrate_v1(&db).await?;
    for table in [
        "recording",
        "version",
        "publication",
        "version_preview",
        "publication_preview",
        "account",
        "resolver",
        "recipe",
        "destination",
        "provider",
        "log",
        "job",
        "memory",
        "trace",
        "person",
        "person_voice",
        "voice",
        "audio_deletion",
        "note_draft",
        "note_draft_receipt",
    ] {
        db.query(format!(
            "DEFINE FIELD OVERWRITE payload ON TABLE {table} TYPE object"
        ))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    }
    knowledge::initialize(&db).await?;
    logs::trim(&db).await?;
    Ok(db)
}

async fn migrate_v1(db: &Surreal<Db>) -> Result<(), String> {
    let metadata = rows(db, "meta").await?;
    if !metadata
        .iter()
        .any(|row| row.key == "schema" && row.payload == json!("1"))
    {
        return Ok(());
    }
    let mut prior = Vec::new();
    for table in table_names().into_iter().chain(["job", "memory", "trace"]) {
        for row in rows(db, table).await? {
            prior.push((table, row));
        }
    }
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        for (table, row) in prior {
                let Value::String(raw) = row.payload else { return Err(format!("Esquema anterior {table}/{} inválido", row.key)); };
                let payload: Value = serde_json::from_str(&raw).map_err(|e| format!("Esquema anterior {table}/{} corrupto: {e}", row.key))?;
                tx.query("UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload, title = $title, status = $status, createdAt = $createdAt, backend = $backend, state = $state, recordingId = $recordingId")
                    .bind(("table", table)).bind(("key", row.key.as_str())).bind(("parent", row.parent.as_str())).bind(("position", row.position))
                    .bind(("payload", payload.clone())).bind(("title", payload["title"].clone())).bind(("status", payload["status"].clone()))
                    .bind(("createdAt", payload["createdAt"].clone())).bind(("backend", payload["backend"].clone()))
                    .bind(("state", payload["state"].clone())).bind(("recordingId", payload["recordingId"].clone()))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        }
        tx.query("UPSERT meta:schema SET key = 'schema', parent = '', position = 0, payload = '2'")
            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    }.await;
    match result {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string()),
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

#[cfg(test)]
async fn downgrade_v1_test(db: &Surreal<Db>) -> Result<(), String> {
    let mut prior = Vec::new();
    for table in table_names().into_iter().chain(["job", "memory", "trace"]) {
        for row in rows(db, table).await? {
            prior.push((table, row));
        }
        if table != "setting" {
            db.query(format!(
                "DEFINE FIELD OVERWRITE payload ON TABLE {table} TYPE any"
            ))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        }
    }
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        for (table, row) in prior {
            let raw = serde_json::to_string(&row.payload).map_err(|e| e.to_string())?;
            tx.query("UPDATE type::record($table, $key) SET payload = $payload")
                .bind(("table", table))
                .bind(("key", row.key))
                .bind(("payload", raw))
                .await
                .map_err(|e| e.to_string())?
                .check()
                .map_err(|e| e.to_string())?;
        }
        tx.query("UPDATE meta:schema SET payload = '1'")
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    }
    .await;
    match result {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string()),
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

fn table_names() -> [&'static str; 10] {
    [
        "recording",
        "version",
        "publication",
        "account",
        "resolver",
        "recipe",
        "destination",
        "provider",
        "log",
        "setting",
    ]
}

#[cfg(test)]
mod tests;

async fn rows(db: &Surreal<Db>, table: &str) -> Result<Vec<Row>, String> {
    let mut response = db
        .query("SELECT key, parent, position, payload FROM type::table($table)")
        .bind(("table", table))
        .await
        .map_err(|e| e.to_string())?;
    response = response.check().map_err(|e| e.to_string())?;
    response.take(0).map_err(|e| e.to_string())
}

async fn rows_for_parent(db: &Surreal<Db>, table: &str, parent: &str) -> Result<Vec<Row>, String> {
    let parent = parent_literal(parent)?;
    let mut response = db
        .query(format!(
            "SELECT key, parent, position, payload FROM type::table($table) WHERE parent = {parent}"
        ))
        .bind(("table", table))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    response.take(0).map_err(|e| e.to_string())
}

fn parent_literal(parent: &str) -> Result<String, String> {
    // SurrealDB 3.3 no usa idx_*_parent cuando el predicado compara con un parámetro.
    serde_json::to_string(parent).map_err(|e| e.to_string())
}

fn order_recordings(rows: &mut [Row]) {
    rows.sort_by(|left, right| {
        let created = |row: &Row| row.payload["createdAt"].as_str().map(str::to_owned);
        created(right)
            .cmp(&created(left))
            .then_with(|| left.key.cmp(&right.key))
    });
}

async fn load(db: &Surreal<Db>) -> Result<Option<Value>, String> {
    let metadata = rows(db, "meta").await?;
    if !metadata
        .iter()
        .any(|row| row.key == "initialized" && row.payload == json!("1"))
    {
        for table in table_names() {
            if !rows(db, table).await?.is_empty() {
                return Err("SurrealDB contiene datos sin marca de migración completa".into());
            }
        }
        return Ok(None);
    }
    if !metadata
        .iter()
        .any(|row| row.key == "schema" && row.payload == json!("2"))
    {
        return Err("Versión de esquema SurrealDB incompatible".into());
    }
    let mut data = json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"providers":[],"settings":{}});
    type OrderedChildren = (Vec<(i64, Value)>, Vec<(i64, Value)>);
    let mut children: BTreeMap<String, OrderedChildren> = BTreeMap::new();
    for table in table_names().into_iter().filter(|table| *table != "log") {
        let mut items = rows(db, table).await?;
        if table == "recording" {
            order_recordings(&mut items);
        } else {
            items.sort_by_key(|row| row.position);
        }
        for row in items {
            let item = row.payload;
            let field = match table {
                "version" => {
                    children
                        .entry(row.parent)
                        .or_default()
                        .0
                        .push((row.position, item));
                    continue;
                }
                "publication" => {
                    children
                        .entry(row.parent)
                        .or_default()
                        .1
                        .push((row.position, item));
                    continue;
                }
                "setting" => {
                    data["settings"][&row.key] = item;
                    continue;
                }
                "recording" => "recordings",
                "account" => "accounts",
                "resolver" => "resolvers",
                "recipe" => "recipes",
                "destination" => "destinations",
                "provider" => "providers",
                _ => return Err(format!("Tabla inesperada: {table}")),
            };
            data[field]
                .as_array_mut()
                .ok_or("Estado inválido")?
                .push(item);
        }
    }
    for recording in data["recordings"].as_array_mut().ok_or("Estado inválido")? {
        let id = recording["id"].as_str().ok_or("Grabación sin ID")?;
        let (versions, publications) = children.remove(id).unwrap_or_default();
        recording["versions"] = Value::Array(versions.into_iter().map(|(_, v)| v).collect());
        recording["publications"] =
            Value::Array(publications.into_iter().map(|(_, v)| v).collect());
    }
    if !children.is_empty() {
        return Err("SurrealDB contiene versiones o recibos huérfanos".into());
    }
    Ok(Some(data))
}

async fn teaching_plan(
    db: &Surreal<Db>,
    teaching: Option<&Teaching>,
) -> Result<Option<TeachingPlan>, String> {
    let Some(teaching) = teaching.filter(|teaching| !teaching.voices.is_empty()) else {
        return Ok(None);
    };
    if teaching.person.trim().is_empty() {
        return Err("Escribe un nombre".into());
    }
    let existing = person_records(db)
        .await?
        .into_iter()
        .find(|person| person.name == teaching.person);
    if teaching.existing_only && existing.is_none() {
        return Ok(None);
    }
    let fresh = existing.is_none();
    let person = existing.unwrap_or_else(|| PersonRecord {
        color: None,
        id: Uuid::new_v4().to_string(),
        name: teaching.person.clone(),
        created_at: Utc::now().to_rfc3339(),
    });
    let start_position = rows(db, "person_voice")
        .await?
        .iter()
        .map(|row| row.position)
        .max()
        .unwrap_or(-1)
        + 1;
    Ok(Some(TeachingPlan {
        person,
        fresh,
        voices: teaching.voices.clone(),
        source: teaching.source.clone(),
        start_position,
    }))
}

async fn run(tx: &surrealdb::method::Transaction<Db>, query: String) -> Result<(), String> {
    tx.query(query)
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

async fn delete_recording_children(
    tx: &surrealdb::method::Transaction<Db>,
    key: &str,
) -> Result<(), String> {
    let record_parent = parent_literal(key)?;
    let mut versions = tx
        .query(format!(
            "SELECT payload.id AS version_id FROM version_preview WHERE parent = {record_parent}"
        ))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let ids: Vec<Value> = versions.take(0).map_err(|e| e.to_string())?;
    for version in ids {
        let id = version["version_id"]
            .as_str()
            .ok_or("Versión guardada sin ID")?;
        run(
            tx,
            format!("DELETE voice WHERE parent = {}", parent_literal(id)?),
        )
        .await?;
    }
    for child in [
        "version",
        "publication",
        "version_preview",
        "publication_preview",
        "memory",
        "trace",
        "job",
        "note_draft",
        "note_draft_receipt",
    ] {
        run(tx, format!("DELETE {child} WHERE parent = {record_parent}")).await?;
    }
    Ok(())
}

async fn upsert_row(tx: &surrealdb::method::Transaction<Db>, row: &RowWrite) -> Result<(), String> {
    let table = row.table.name();
    tx.query("UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload, title = $title, status = $status, createdAt = $createdAt, backend = $backend, state = $state, recordingId = $recordingId")
        .bind(("table", table))
        .bind(("key", row.key.clone()))
        .bind(("parent", row.parent.clone()))
        .bind(("position", row.position))
        .bind(("payload", row.payload.clone()))
        .bind(("title", row.payload["title"].clone()))
        .bind(("status", row.payload["status"].clone()))
        .bind(("createdAt", row.payload["createdAt"].clone()))
        .bind(("backend", row.payload["backend"].clone()))
        .bind(("state", row.payload["state"].clone()))
        .bind(("recordingId", row.payload["recordingId"].clone()))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    if let Some(preview_table) = row.table.preview() {
        tx.query("UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
            .bind(("table", preview_table))
            .bind(("key", row.key.clone()))
            .bind(("parent", row.parent.clone()))
            .bind(("position", row.position))
            .bind(("payload", preview_for(table, &row.payload)?))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
    }
    if row.table == Table::Recording && row.payload["status"] == "discarded" {
        delete_recording_children(tx, &row.key).await?;
    }
    Ok(())
}

async fn delete_row(
    tx: &surrealdb::method::Transaction<Db>,
    table: Table,
    key: &str,
    id: &str,
) -> Result<(), String> {
    tx.query("DELETE type::record($table, $key)")
        .bind(("table", table.name()))
        .bind(("key", key.to_owned()))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    match table {
        Table::Recording => delete_recording_children(tx, key).await?,
        Table::Version => {
            run(
                tx,
                format!("DELETE voice WHERE parent = {}", parent_literal(id)?),
            )
            .await?
        }
        _ => {}
    }
    if let Some(preview_table) = table.preview() {
        tx.query("DELETE type::record($table, $key)")
            .bind(("table", preview_table))
            .bind(("key", key.to_owned()))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

async fn apply_aliases(
    tx: &surrealdb::method::Transaction<Db>,
    aliases: &HashMap<String, String>,
) -> Result<(), String> {
    if !aliases.iter().any(|(old, new)| old != new) {
        return Ok(());
    }
    let mut response = tx
        .query("SELECT key, payload.recipeId AS recipe_id FROM version_preview")
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let rows: Vec<Value> = response.take(0).map_err(|e| e.to_string())?;
    for row in rows {
        let Some(old_recipe) = row["recipe_id"].as_str() else {
            continue;
        };
        let Some(new_recipe) = aliases.get(old_recipe).filter(|new| *new != old_recipe) else {
            continue;
        };
        let key = row["key"]
            .as_str()
            .ok_or("Proyección de versión sin clave")?;
        for table in ["version", "version_preview"] {
            tx.query("UPDATE type::record($table, $key) SET payload.recipeId = $replacement")
                .bind(("table", table))
                .bind(("key", key.to_owned()))
                .bind(("replacement", new_recipe.clone()))
                .await
                .map_err(|e| e.to_string())?
                .check()
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

async fn apply(db: &Surreal<Db>, write: &LibraryWrite) -> Result<bool, String> {
    let plan = teaching_plan(db, write.teaching.as_ref()).await?;
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        for op in &write.ops {
            match op {
                RowOp::Upsert(row) => upsert_row(&tx, row).await?,
                RowOp::Delete { table, key, id } => delete_row(&tx, *table, key, id).await?,
            }
        }
        if let Some((key, value)) = &write.draft_change {
            if let Some(value) = value {
                tx.query("UPSERT type::record('note_draft', $key) SET key = $key, parent = $key, position = 0, payload = $payload")
                    .bind(("key", key.clone())).bind(("payload", value.clone()))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            } else {
                tx.query("DELETE type::record('note_draft', $key)").bind(("key", key.clone()))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
        }
        if let Some((key, parent, receipt)) = &write.draft_receipt {
            tx.query("CREATE type::record('note_draft_receipt', $key) SET key = $key, parent = $parent, position = 0, payload = $payload")
                .bind(("key", key.clone())).bind(("parent", parent.clone())).bind(("payload", receipt.clone()))
                .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        }
        apply_aliases(&tx, &write.recipe_aliases).await?;
        if let Some((version_id, voices)) = &write.version_voices {
            for (position, voice) in voices.iter().enumerate() {
                let record = VersionVoiceRecord { id: format!("{version_id}:{position}"), version_id: version_id.clone(), speaker: voice.speaker.clone(), model: voice.model.clone(), embedding: voice.embedding.clone() };
                tx.query("CREATE type::record('voice', $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
                    .bind(("key", record.id.clone())).bind(("parent", version_id.clone()))
                    .bind(("position", position as i64)).bind(("payload", serde_json::to_value(record).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
        }
        if let Some(teaching) = &plan {
            if teaching.fresh {
                tx.query("CREATE type::record('person', $key) SET key = $key, parent = '', position = 0, payload = $payload")
                    .bind(("key", teaching.person.id.clone())).bind(("payload", serde_json::to_value(&teaching.person).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
            for (index, voice) in teaching.voices.iter().enumerate() {
                let record = PersonVoiceRecord { id: Uuid::new_v4().to_string(), person_id: teaching.person.id.clone(), model: voice.model.clone(), embedding: voice.embedding.clone(), source: teaching.source.clone(), added_at: Utc::now().to_rfc3339() };
                tx.query("CREATE type::record('person_voice', $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
                    .bind(("key", record.id.clone())).bind(("parent", teaching.person.id.clone()))
                    .bind(("position", teaching.start_position + index as i64)).bind(("payload", serde_json::to_value(record).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
        }
        for deletion in &write.audio_deletions {
            tx.query("UPSERT type::record('audio_deletion', $key) SET key = $key, parent = '', position = 0, payload = $payload")
                .bind(("key", deletion.id.clone()))
                .bind(("payload", serde_json::to_value(deletion).map_err(|e| e.to_string())?))
                .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        }
        for entry in &write.logs {
            logs::insert(&tx, entry).await?;
        }
        tx.query("UPSERT meta:initialized SET key = 'initialized', parent = '', position = 0, payload = '1'")
            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        tx.query("UPSERT meta:schema SET key = 'schema', parent = '', position = 0, payload = '2'")
            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    }.await;
    match result {
        Ok(()) => {
            tx.commit().await.map_err(|e| e.to_string())?;
            Ok(plan.is_some())
        }
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

async fn pending_audio_deletions(db: &Surreal<Db>) -> Result<Vec<AudioDeletion>, String> {
    rows(db, "audio_deletion")
        .await?
        .into_iter()
        .map(|row| {
            let deletion: AudioDeletion =
                serde_json::from_value(row.payload).map_err(|e| e.to_string())?;
            if deletion.id != row.key {
                return Err("Cola de borrado de audio incoherente".into());
            }
            Ok(deletion)
        })
        .collect()
}

async fn complete_audio_deletion(db: &Surreal<Db>, id: &str) -> Result<(), String> {
    db.query("DELETE type::record('audio_deletion', $key)")
        .bind(("key", id))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

async fn jobs(db: &Surreal<Db>) -> Result<Vec<Value>, String> {
    Ok(rows(db, "job")
        .await?
        .into_iter()
        .map(|row| row.payload)
        .collect())
}

async fn jobs_active(db: &Surreal<Db>) -> Result<Vec<Value>, String> {
    let mut response = db
        .query("SELECT VALUE payload FROM job WHERE state = 'queued'; SELECT VALUE payload FROM job WHERE state = 'running'; SELECT VALUE payload FROM job WHERE state = 'retry'")
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let mut active = Vec::new();
    for statement in 0..3 {
        let rows: Vec<Value> = response.take(statement).map_err(|e| e.to_string())?;
        active.extend(rows);
    }
    Ok(active)
}

async fn jobs_for(db: &Surreal<Db>, recording: &str) -> Result<Vec<Value>, String> {
    Ok(rows_for_parent(db, "job", recording)
        .await?
        .into_iter()
        .map(|row| row.payload)
        .collect())
}

async fn job(db: &Surreal<Db>, id: &str) -> Result<Option<Value>, String> {
    let row: Option<Row> = db.select(("job", id)).await.map_err(|e| e.to_string())?;
    Ok(row.map(|row| row.payload))
}

async fn save_job(db: &Surreal<Db>, job: &Value) -> Result<(), String> {
    let key = job["id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("Job sin ID")?;
    let parent = job["recordingId"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("Job sin grabación")?;
    job["state"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("Job sin estado")?;
    db.query("UPSERT type::record('job', $key) SET key = $key, parent = $parent, position = 0, payload = $payload, recordingId = $parent, state = $state")
        .bind(("key", key)).bind(("parent", parent)).bind(("payload", job.clone())).bind(("state", job["state"].clone()))
        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
async fn remove_job(db: &Surreal<Db>, id: &str) -> Result<(), String> {
    db.query("DELETE type::record('job', $key)")
        .bind(("key", id))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

async fn recall(db: &Surreal<Db>, key: &str) -> Result<Option<Value>, String> {
    let mut response = db
        .query("SELECT key, parent, position, payload FROM type::record('memory', $key)")
        .bind(("key", key))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let rows: Vec<Row> = response.take(0).map_err(|e| e.to_string())?;
    Ok(rows.into_iter().next().map(|row| row.payload))
}

async fn keep(db: &Surreal<Db>, key: &str, parent: &str, value: &Value) -> Result<(), String> {
    let payload = value.clone();
    db.query("UPSERT type::record('memory', $key) SET key = $key, parent = $parent, position = 0, payload = $payload")
        .bind(("key", key)).bind(("parent", parent)).bind(("payload", payload))
        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    Ok(())
}

async fn trace_save(db: &Surreal<Db>, trace: &Value) -> Result<(), String> {
    let key = trace["id"].as_str().ok_or("Traza sin ID")?;
    let parent = trace["recordingId"].as_str().ok_or("Traza sin grabación")?;
    let payload = trace.clone();
    db.query("UPSERT type::record('trace', $key) SET key = $key, parent = $parent, position = 0, payload = $payload")
        .bind(("key", key)).bind(("parent", parent)).bind(("payload", payload))
        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    Ok(())
}

async fn trace_list(db: &Surreal<Db>, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
    let mut values: Vec<Value> = rows(db, "trace")
        .await?
        .into_iter()
        .filter(|row| recording_id.is_none_or(|id| row.parent == id))
        .map(|row| row.payload)
        .collect();
    values.sort_by(|a, b| b["startedAt"].as_str().cmp(&a["startedAt"].as_str()));
    Ok(values)
}

async fn person_records(db: &Surreal<Db>) -> Result<Vec<PersonRecord>, String> {
    rows(db, "person")
        .await?
        .into_iter()
        .map(|row| {
            serde_json::from_value(row.payload).map_err(|_| "Persona guardada inválida".into())
        })
        .collect()
}

async fn person_voice_records(db: &Surreal<Db>) -> Result<Vec<PersonVoiceRecord>, String> {
    let mut items = rows(db, "person_voice").await?;
    items.sort_by_key(|row| row.position);
    items
        .into_iter()
        .map(|row| {
            serde_json::from_value(row.payload).map_err(|_| "Huella guardada inválida".into())
        })
        .collect()
}

async fn people(db: &Surreal<Db>) -> Result<Value, String> {
    let mut people = person_records(db).await?;
    people.sort_by(|a, b| a.name.cmp(&b.name));
    let voices = person_voice_records(db).await?;
    Ok(Value::Array(people.into_iter().filter_map(|person| {
        let own: Vec<Value> = voices.iter().filter(|voice| voice.person_id == person.id)
            .map(|voice| json!({"id":voice.id,"model":voice.model,"source":voice.source,"addedAt":voice.added_at})).collect();
        (!own.is_empty()).then(|| {
            let mut value = json!({"id":person.id,"name":person.name,"voices":own});
            if let Some(color) = person.color { value["color"] = json!(color); }
            value
        })
    }).collect()))
}

async fn known_voices(db: &Surreal<Db>) -> Result<Vec<KnownVoice>, String> {
    let people = person_records(db).await?;
    let voices = person_voice_records(db).await?;
    Ok(voices
        .into_iter()
        .filter_map(|voice| {
            people
                .iter()
                .find(|person| person.id == voice.person_id)
                .map(|person| KnownVoice {
                    person: person.name.clone(),
                    person_id: person.id.clone(),
                    model: voice.model,
                    embedding: voice.embedding,
                })
        })
        .collect())
}

async fn add_person_voice(
    db: &Surreal<Db>,
    name: &str,
    voice: &SpeakerVoice,
    source: &str,
) -> Result<(), String> {
    if name.trim().is_empty()
        || voice.model.is_empty()
        || voice.embedding.is_empty()
        || voice.embedding.iter().any(|value| !value.is_finite())
    {
        return Err("Huella de voz inválida".into());
    }
    let person = person_records(db)
        .await?
        .into_iter()
        .find(|person| person.name == name)
        .unwrap_or_else(|| PersonRecord {
            color: None,
            id: Uuid::new_v4().to_string(),
            name: name.to_owned(),
            created_at: Utc::now().to_rfc3339(),
        });
    let fresh = !rows(db, "person")
        .await?
        .iter()
        .any(|row| row.key == person.id);
    let position = rows(db, "person_voice")
        .await?
        .iter()
        .map(|row| row.position)
        .max()
        .unwrap_or(-1)
        + 1;
    let voice = PersonVoiceRecord {
        id: Uuid::new_v4().to_string(),
        person_id: person.id.clone(),
        model: voice.model.clone(),
        embedding: voice.embedding.clone(),
        source: source.to_owned(),
        added_at: Utc::now().to_rfc3339(),
    };
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        if fresh {
            tx.query("CREATE type::record('person', $key) SET key = $key, parent = '', position = 0, payload = $payload")
                .bind(("key", person.id.as_str())).bind(("payload", serde_json::to_value(&person).map_err(|e| e.to_string())?))
                .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        }
        tx.query("CREATE type::record('person_voice', $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
            .bind(("key", voice.id.as_str())).bind(("parent", person.id.as_str()))
            .bind(("position", position))
            .bind(("payload", serde_json::to_value(&voice).map_err(|e| e.to_string())?))
            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    }.await;
    match result {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string()),
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

async fn set_person_color(db: &Surreal<Db>, name: &str, color: &str) -> Result<(), String> {
    if color.len() != 7
        || !color.starts_with('#')
        || !color.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
    {
        return Err("El color debe tener formato #RRGGBB".into());
    }
    let mut person = person_records(db)
        .await?
        .into_iter()
        .find(|person| person.name == name)
        .ok_or("Persona no encontrada")?;
    person.color = Some(color.into());
    db.query("UPDATE type::record('person', $key) SET payload = $payload")
        .bind(("key", person.id.clone()))
        .bind((
            "payload",
            serde_json::to_value(person).map_err(|e| e.to_string())?,
        ))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

async fn rename_person(db: &Surreal<Db>, name: &str, new_name: &str) -> Result<(), String> {
    if name == new_name {
        return Ok(());
    }
    if new_name.trim().is_empty() {
        return Err("Escribe un nombre".into());
    }
    let people = person_records(db).await?;
    let source = people
        .iter()
        .find(|person| person.name == name)
        .ok_or("Persona no encontrada")?;
    let target = people.iter().find(|person| person.name == new_name);
    let source_voices: Vec<Row> = rows(db, "person_voice")
        .await?
        .into_iter()
        .filter(|row| row.parent == source.id)
        .collect();
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        if let Some(target) = target {
            if target.color.is_none() && source.color.is_some() {
                let mut inherited = target.clone();
                inherited.color = source.color.clone();
                tx.query("UPDATE type::record('person', $key) SET payload = $payload")
                    .bind(("key", target.id.as_str())).bind(("payload", serde_json::to_value(inherited).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
            for mut row in source_voices {
                let mut voice: PersonVoiceRecord = serde_json::from_value(row.payload).map_err(|_| "Huella guardada inválida")?;
                voice.person_id = target.id.clone();
                row.parent = target.id.clone();
                tx.query("UPDATE type::record('person_voice', $key) SET parent = $parent, payload = $payload")
                    .bind(("key", row.key)).bind(("parent", row.parent))
                    .bind(("payload", serde_json::to_value(voice).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
            tx.query("DELETE type::record('person', $key)").bind(("key", source.id.as_str()))
                .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        } else {
            let mut renamed = source.clone();
            renamed.name = new_name.to_owned();
            tx.query("UPDATE type::record('person', $key) SET payload = $payload")
                .bind(("key", source.id.as_str())).bind(("payload", serde_json::to_value(renamed).map_err(|e| e.to_string())?))
                .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
        }
        Ok::<(), String>(())
    }.await;
    match result {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string()),
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

async fn remove_person_voice(db: &Surreal<Db>, id: &str) -> Result<(), String> {
    let voices = rows(db, "person_voice").await?;
    let voice = voices
        .iter()
        .find(|row| row.key == id)
        .ok_or("Huella no encontrada")?;
    let last = !voices
        .iter()
        .any(|row| row.parent == voice.parent && row.key != id);
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        tx.query("DELETE type::record('person_voice', $key)")
            .bind(("key", id))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        if last {
            tx.query("DELETE type::record('person', $key)")
                .bind(("key", voice.parent.as_str()))
                .await
                .map_err(|e| e.to_string())?
                .check()
                .map_err(|e| e.to_string())?;
        }
        Ok::<(), String>(())
    }
    .await;
    match result {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string()),
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

async fn remove_person(db: &Surreal<Db>, name: &str) -> Result<(), String> {
    let Some(person) = person_records(db)
        .await?
        .into_iter()
        .find(|person| person.name == name)
    else {
        return Ok(());
    };
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        tx.query("DELETE type::table('person_voice') WHERE parent = $parent")
            .bind(("parent", person.id.as_str()))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        tx.query("DELETE type::record('person', $key)")
            .bind(("key", person.id.as_str()))
            .await
            .map_err(|e| e.to_string())?
            .check()
            .map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    }
    .await;
    match result {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string()),
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            Err(error)
        }
    }
}

async fn version_voices(db: &Surreal<Db>, id: &str) -> Result<Vec<SpeakerVoice>, String> {
    let mut items = rows_for_parent(db, "voice", id).await?;
    items.sort_by_key(|row| row.position);
    items
        .into_iter()
        .map(|row| {
            let voice: VersionVoiceRecord =
                serde_json::from_value(row.payload).map_err(|_| "Huella guardada inválida")?;
            Ok(SpeakerVoice {
                speaker: voice.speaker,
                model: voice.model,
                embedding: voice.embedding,
            })
        })
        .collect()
}
