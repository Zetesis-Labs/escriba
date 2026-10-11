use crate::voices::{KnownVoice, SpeakerVoice};
use chrono::Utc;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::Path,
    sync::mpsc,
    thread,
};
use surrealdb::{
    engine::local::{Db, SurrealKv},
    types::SurrealValue,
    Surreal,
};
use tokio::sync::mpsc as async_mpsc;
use uuid::Uuid;
mod index;
use index::{load_index, preview_for, recording};

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
}

#[derive(Clone, Deserialize, Serialize)]
struct PersonRecord {
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

enum Command {
    Load(mpsc::Sender<Result<Option<Value>, String>>),
    LoadIndex(mpsc::Sender<Result<Option<Value>, String>>),
    Recording(String, mpsc::Sender<Result<Option<Value>, String>>),
    #[cfg(test)]
    Save(Value, Value, mpsc::Sender<Result<(), String>>),
    SaveScoped(
        Value,
        Value,
        WriteScope,
        Vec<AudioDeletion>,
        mpsc::Sender<Result<(), String>>,
    ),
    SaveScopedVersion(
        Value,
        Value,
        WriteScope,
        String,
        Vec<SpeakerVoice>,
        Option<Teaching>,
        mpsc::Sender<Result<bool, String>>,
    ),
    SaveWithAudioDeletions(
        Value,
        Value,
        Vec<AudioDeletion>,
        mpsc::Sender<Result<(), String>>,
    ),
    PendingAudioDeletions(mpsc::Sender<Result<Vec<AudioDeletion>, String>>),
    CompleteAudioDeletion(String, mpsc::Sender<Result<(), String>>),
    Jobs(mpsc::Sender<Result<Vec<Value>, String>>),
    SaveJob(Value, mpsc::Sender<Result<(), String>>),
    #[cfg(test)]
    RemoveJob(String, mpsc::Sender<Result<(), String>>),
    Recall(String, mpsc::Sender<Result<Option<Value>, String>>),
    Keep(String, String, Value, mpsc::Sender<Result<(), String>>),
    TraceSave(Value, mpsc::Sender<Result<(), String>>),
    TraceList(Option<String>, mpsc::Sender<Result<Vec<Value>, String>>),
    People(mpsc::Sender<Result<Value, String>>),
    KnownVoices(mpsc::Sender<Result<Vec<KnownVoice>, String>>),
    AddPersonVoice(
        String,
        SpeakerVoice,
        String,
        mpsc::Sender<Result<(), String>>,
    ),
    RenamePerson(String, String, mpsc::Sender<Result<(), String>>),
    RemovePersonVoice(String, mpsc::Sender<Result<(), String>>),
    RemovePerson(String, mpsc::Sender<Result<(), String>>),
    VersionVoices(String, mpsc::Sender<Result<Vec<SpeakerVoice>, String>>),
    #[cfg(test)]
    Query(String, mpsc::Sender<Result<(), String>>),
    #[cfg(test)]
    Select(String, mpsc::Sender<Result<Vec<Value>, String>>),
    #[cfg(test)]
    Downgrade(mpsc::Sender<Result<(), String>>),
}

pub struct Persistence {
    sender: Option<async_mpsc::UnboundedSender<Command>>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Persistence {
    pub fn open(path: &Path) -> Result<Self, String> {
        let (sender, mut receiver) = async_mpsc::unbounded_channel();
        let (ready_sender, ready_receiver) = mpsc::channel();
        let path = path.to_owned();
        let worker = thread::spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(value) => value,
                Err(error) => {
                    let _ = ready_sender.send(Err(error.to_string()));
                    return;
                }
            };
            runtime.block_on(async move {
                let db = match connect(&path).await {
                    Ok(value) => value,
                    Err(error) => {
                        let _ = ready_sender.send(Err(error));
                        return;
                    }
                };
                let _ = ready_sender.send(Ok(()));
                while let Some(command) = receiver.recv().await {
                    match command {
                        Command::Load(reply) => {
                            let _ = reply.send(load(&db).await);
                        }
                        Command::LoadIndex(reply) => {
                            let _ = reply.send(load_index(&db).await);
                        }
                        Command::Recording(id, reply) => {
                            let _ = reply.send(recording(&db, &id).await);
                        }
                        #[cfg(test)]
                        Command::Save(before, after, reply) => {
                            let _ = reply.send(save(&db, &before, &after).await);
                        }
                        Command::SaveScoped(before, after, scope, deletions, reply) => {
                            let _ = reply.send(
                                save_scoped(
                                    &db,
                                    &before,
                                    &after,
                                    &scope,
                                    SaveExtras {
                                        audio_deletions: &deletions,
                                        ..SaveExtras::default()
                                    },
                                )
                                .await,
                            );
                        }
                        Command::SaveScopedVersion(
                            before,
                            after,
                            scope,
                            id,
                            voices,
                            teaching,
                            reply,
                        ) => {
                            let _ = reply.send(
                                save_scoped_version(
                                    &db,
                                    &before,
                                    &after,
                                    &scope,
                                    &id,
                                    &voices,
                                    teaching.as_ref(),
                                )
                                .await,
                            );
                        }
                        Command::SaveWithAudioDeletions(before, after, deletions, reply) => {
                            let _ = reply.send(
                                save_with_aux(
                                    &db,
                                    &before,
                                    &after,
                                    SaveExtras {
                                        audio_deletions: &deletions,
                                        ..SaveExtras::default()
                                    },
                                )
                                .await,
                            );
                        }
                        Command::PendingAudioDeletions(reply) => {
                            let _ = reply.send(pending_audio_deletions(&db).await);
                        }
                        Command::CompleteAudioDeletion(id, reply) => {
                            let _ = reply.send(complete_audio_deletion(&db, &id).await);
                        }
                        Command::Jobs(reply) => {
                            let _ = reply.send(jobs(&db).await);
                        }
                        Command::SaveJob(job, reply) => {
                            let _ = reply.send(save_job(&db, &job).await);
                        }
                        #[cfg(test)]
                        Command::RemoveJob(id, reply) => {
                            let _ = reply.send(remove_job(&db, &id).await);
                        }
                        Command::Recall(key, reply) => {
                            let _ = reply.send(recall(&db, &key).await);
                        }
                        Command::Keep(key, parent, value, reply) => {
                            let _ = reply.send(keep(&db, &key, &parent, &value).await);
                        }
                        Command::TraceSave(value, reply) => {
                            let _ = reply.send(trace_save(&db, &value).await);
                        }
                        Command::TraceList(parent, reply) => {
                            let _ = reply.send(trace_list(&db, parent.as_deref()).await);
                        }
                        Command::People(reply) => {
                            let _ = reply.send(people(&db).await);
                        }
                        Command::KnownVoices(reply) => {
                            let _ = reply.send(known_voices(&db).await);
                        }
                        Command::AddPersonVoice(name, voice, source, reply) => {
                            let _ = reply.send(add_person_voice(&db, &name, &voice, &source).await);
                        }
                        Command::RenamePerson(name, new_name, reply) => {
                            let _ = reply.send(rename_person(&db, &name, &new_name).await);
                        }
                        Command::RemovePersonVoice(id, reply) => {
                            let _ = reply.send(remove_person_voice(&db, &id).await);
                        }
                        Command::RemovePerson(name, reply) => {
                            let _ = reply.send(remove_person(&db, &name).await);
                        }
                        Command::VersionVoices(id, reply) => {
                            let _ = reply.send(version_voices(&db, &id).await);
                        }
                        #[cfg(test)]
                        Command::Query(query, reply) => {
                            let result = db.query(query).await.map_err(|e| e.to_string()).and_then(
                                |response| response.check().map(|_| ()).map_err(|e| e.to_string()),
                            );
                            let _ = reply.send(result);
                        }
                        #[cfg(test)]
                        Command::Select(query, reply) => {
                            let result = async {
                                let mut response = db
                                    .query(query)
                                    .await
                                    .map_err(|e| e.to_string())?
                                    .check()
                                    .map_err(|e| e.to_string())?;
                                response.take(0).map_err(|e| e.to_string())
                            }
                            .await;
                            let _ = reply.send(result);
                        }
                        #[cfg(test)]
                        Command::Downgrade(reply) => {
                            let _ = reply.send(downgrade_v1_test(&db).await);
                        }
                    }
                }
                drop(db);
                let lock = path.join("LOCK");
                for _ in 0..200 {
                    if let Ok(file) = std::fs::OpenOptions::new()
                        .read(true)
                        .write(true)
                        .open(&lock)
                    {
                        if file.try_lock_exclusive().is_ok() {
                            let _ = file.unlock();
                            break;
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                }
            });
        });
        ready_receiver
            .recv()
            .map_err(|_| "No se pudo iniciar SurrealDB".to_owned())??;
        Ok(Self {
            sender: Some(sender),
            worker: Some(worker),
        })
    }

    fn request<T>(
        &self,
        command: impl FnOnce(mpsc::Sender<Result<T, String>>) -> Command,
    ) -> Result<T, String> {
        let (reply, receiver) = mpsc::channel();
        self.sender
            .as_ref()
            .ok_or("SurrealDB está cerrada")?
            .send(command(reply))
            .map_err(|_| "SurrealDB dejó de responder")?;
        receiver.recv().map_err(|_| "SurrealDB dejó de responder")?
    }
    pub fn load(&self) -> Result<Option<Value>, String> {
        self.request(Command::Load)
    }
    pub fn load_index(&self) -> Result<Option<Value>, String> {
        self.request(Command::LoadIndex)
    }
    pub fn recording(&self, id: &str) -> Result<Option<Value>, String> {
        self.request(|reply| Command::Recording(id.to_owned(), reply))
    }
    pub fn save_scoped(
        &self,
        before: Value,
        after: Value,
        scope: WriteScope,
    ) -> Result<(), String> {
        self.request(|reply| Command::SaveScoped(before, after, scope, Vec::new(), reply))
    }
    pub fn save_scoped_with_audio_deletions(
        &self,
        before: Value,
        after: Value,
        scope: WriteScope,
        deletions: &[AudioDeletion],
    ) -> Result<(), String> {
        self.request(|reply| Command::SaveScoped(before, after, scope, deletions.to_vec(), reply))
    }
    pub fn save_scoped_version(
        &self,
        before: Value,
        after: Value,
        scope: WriteScope,
        id: &str,
        voices: &[SpeakerVoice],
        teaching: Option<Teaching>,
    ) -> Result<bool, String> {
        self.request(|reply| {
            Command::SaveScopedVersion(
                before,
                after,
                scope,
                id.to_owned(),
                voices.to_vec(),
                teaching,
                reply,
            )
        })
    }
    #[cfg(test)]
    pub fn save(&self, before: Value, after: Value) -> Result<(), String> {
        self.request(|reply| Command::Save(before, after, reply))
    }
    pub fn save_with_audio_deletions(
        &self,
        before: Value,
        after: Value,
        deletions: &[AudioDeletion],
    ) -> Result<(), String> {
        self.request(|reply| {
            Command::SaveWithAudioDeletions(before, after, deletions.to_vec(), reply)
        })
    }
    pub fn pending_audio_deletions(&self) -> Result<Vec<AudioDeletion>, String> {
        self.request(Command::PendingAudioDeletions)
    }
    pub fn complete_audio_deletion(&self, id: &str) -> Result<(), String> {
        self.request(|reply| Command::CompleteAudioDeletion(id.to_owned(), reply))
    }
    pub fn jobs(&self) -> Result<Vec<Value>, String> {
        self.request(Command::Jobs)
    }
    pub fn save_job(&self, job: &Value) -> Result<(), String> {
        self.request(|reply| Command::SaveJob(job.clone(), reply))
    }
    #[cfg(test)]
    pub fn remove_job(&self, id: &str) -> Result<(), String> {
        self.request(|reply| Command::RemoveJob(id.to_owned(), reply))
    }
    pub fn recall(&self, key: &str) -> Result<Option<Value>, String> {
        self.request(|reply| Command::Recall(key.to_owned(), reply))
    }
    pub fn keep(&self, key: &str, parent: &str, value: &Value) -> Result<(), String> {
        self.request(|reply| Command::Keep(key.to_owned(), parent.to_owned(), value.clone(), reply))
    }
    pub fn trace_save(&self, value: &Value) -> Result<(), String> {
        self.request(|reply| Command::TraceSave(value.clone(), reply))
    }
    pub fn trace_list(&self, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
        self.request(|reply| Command::TraceList(recording_id.map(str::to_owned), reply))
    }
    pub fn people(&self) -> Result<Value, String> {
        self.request(Command::People)
    }
    pub fn known_voices(&self) -> Result<Vec<KnownVoice>, String> {
        self.request(Command::KnownVoices)
    }
    pub fn add_person_voice(
        &self,
        name: &str,
        voice: &SpeakerVoice,
        source: &str,
    ) -> Result<(), String> {
        self.request(|reply| {
            Command::AddPersonVoice(name.to_owned(), voice.clone(), source.to_owned(), reply)
        })
    }
    pub fn rename_person(&self, name: &str, new_name: &str) -> Result<(), String> {
        self.request(|reply| Command::RenamePerson(name.to_owned(), new_name.to_owned(), reply))
    }
    pub fn remove_person_voice(&self, id: &str) -> Result<(), String> {
        self.request(|reply| Command::RemovePersonVoice(id.to_owned(), reply))
    }
    pub fn remove_person(&self, name: &str) -> Result<(), String> {
        self.request(|reply| Command::RemovePerson(name.to_owned(), reply))
    }
    pub fn version_voices(&self, id: &str) -> Result<Vec<SpeakerVoice>, String> {
        self.request(|reply| Command::VersionVoices(id.to_owned(), reply))
    }
    #[cfg(test)]
    pub fn query_test(&self, query: &str) -> Result<(), String> {
        self.request(|reply| Command::Query(query.to_owned(), reply))
    }
    #[cfg(test)]
    pub fn select_test(&self, query: &str) -> Result<Vec<Value>, String> {
        self.request(|reply| Command::Select(query.to_owned(), reply))
    }
    #[cfg(test)]
    pub fn downgrade_v1_test(&self) -> Result<(), String> {
        self.request(Command::Downgrade)
    }
}

impl Drop for Persistence {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

async fn connect(path: &Path) -> Result<Surreal<Db>, String> {
    let path = path.to_str().ok_or("Ruta de SurrealDB no UTF-8")?;
    let db = Surreal::new::<SurrealKv>(path)
        .await
        .map_err(|e| format!("No se pudo abrir SurrealKV: {e}"))?;
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
    ] {
        db.query(format!(
            "DEFINE FIELD OVERWRITE payload ON TABLE {table} TYPE object"
        ))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    }
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
    let mut data = json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"providers":[],"logs":[],"settings":{}});
    type OrderedChildren = (Vec<(i64, Value)>, Vec<(i64, Value)>);
    let mut children: BTreeMap<String, OrderedChildren> = BTreeMap::new();
    for table in table_names() {
        let mut items = rows(db, table).await?;
        items.sort_by_key(|row| row.position);
        for row in items {
            let item = row.payload;
            match table {
                "version" => children
                    .entry(row.parent)
                    .or_default()
                    .0
                    .push((row.position, item)),
                "publication" => children
                    .entry(row.parent)
                    .or_default()
                    .1
                    .push((row.position, item)),
                "setting" => {
                    data["settings"][&row.key] = item;
                }
                "recording" => data["recordings"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                "account" => data["accounts"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                "resolver" => data["resolvers"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                "recipe" => data["recipes"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                "destination" => data["destinations"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                "provider" => data["providers"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                "log" => data["logs"]
                    .as_array_mut()
                    .ok_or("Estado inválido")?
                    .push(item),
                _ => unreachable!(),
            }
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

fn flatten_with_scope(
    data: &Value,
    scope: Option<&WriteScope>,
) -> Result<BTreeMap<(String, String), Row>, String> {
    let mut output = BTreeMap::new();
    for (table, field) in [
        ("recording", "recordings"),
        ("account", "accounts"),
        ("resolver", "resolvers"),
        ("recipe", "recipes"),
        ("destination", "destinations"),
        ("provider", "providers"),
        ("log", "logs"),
    ] {
        let empty = Vec::new();
        for (position, item) in data
            .get(field)
            .and_then(Value::as_array)
            .or_else(|| (field == "providers").then_some(&empty))
            .ok_or(format!("{field} inválido"))?
            .iter()
            .enumerate()
        {
            let key = item["id"].as_str().ok_or(format!("{field} sin ID"))?;
            let payload = if table == "recording" {
                Value::Object(
                    item.as_object()
                        .ok_or("Grabación inválida")?
                        .iter()
                        .filter(|(key, _)| !["versions", "publications"].contains(&key.as_str()))
                        .map(|(key, value)| (key.clone(), value.clone()))
                        .collect(),
                )
            } else {
                item.clone()
            };
            insert(
                &mut output,
                table,
                key.to_owned(),
                String::new(),
                position as i64,
                payload,
            )?;
            if table == "recording" {
                if scope.is_some_and(|scope| !scope.full_recordings.contains(key)) {
                    continue;
                }
                for (child_table, field, id_field) in [
                    ("version", "versions", "id"),
                    ("publication", "publications", "destinationId"),
                ] {
                    let children = match item[field].as_array() {
                        Some(children) => children.as_slice(),
                        None if item["status"] == "discarded" => &[],
                        None => return Err(format!("{field} inválido")),
                    };
                    for (child_position, child) in children.iter().enumerate() {
                        let id = child[id_field]
                            .as_str()
                            .ok_or(format!("{field} sin {id_field}"))?;
                        insert(
                            &mut output,
                            child_table,
                            json!([key, id]).to_string(),
                            key.to_owned(),
                            child_position as i64,
                            child.clone(),
                        )?;
                    }
                }
            }
        }
    }
    for (key, value) in data["settings"].as_object().ok_or("Ajustes inválidos")? {
        insert(
            &mut output,
            "setting",
            key.clone(),
            String::new(),
            0,
            value.clone(),
        )?;
    }
    Ok(output)
}

fn insert(
    rows: &mut BTreeMap<(String, String), Row>,
    table: &str,
    key: String,
    parent: String,
    position: i64,
    payload: Value,
) -> Result<(), String> {
    let row = Row {
        key: key.clone(),
        parent,
        position,
        payload,
    };
    if rows.insert((table.to_owned(), key), row).is_some() {
        return Err("Identificador duplicado en la biblioteca".into());
    }
    Ok(())
}

#[cfg(test)]
async fn save(db: &Surreal<Db>, before: &Value, after: &Value) -> Result<(), String> {
    save_with_aux(db, before, after, SaveExtras::default()).await
}

async fn save_scoped(
    db: &Surreal<Db>,
    before: &Value,
    after: &Value,
    scope: &WriteScope,
    extras: SaveExtras<'_>,
) -> Result<(), String> {
    save_with_aux_mode(db, before, after, extras, Some(scope)).await
}

#[derive(Default)]
struct SaveExtras<'a> {
    audio_deletions: &'a [AudioDeletion],
    version_voices: Option<(&'a str, &'a [SpeakerVoice])>,
    teaching: Option<&'a TeachingPlan>,
}

async fn save_scoped_version(
    db: &Surreal<Db>,
    before: &Value,
    after: &Value,
    scope: &WriteScope,
    id: &str,
    voices: &[SpeakerVoice],
    teaching: Option<&Teaching>,
) -> Result<bool, String> {
    save_version_mode(db, before, after, scope, id, voices, teaching).await
}

async fn save_version_mode(
    db: &Surreal<Db>,
    before: &Value,
    after: &Value,
    scope: &WriteScope,
    id: &str,
    voices: &[SpeakerVoice],
    teaching: Option<&Teaching>,
) -> Result<bool, String> {
    let plan = if let Some(teaching) = teaching.filter(|teaching| !teaching.voices.is_empty()) {
        if teaching.person.trim().is_empty() {
            return Err("Escribe un nombre".into());
        }
        let existing = person_records(db)
            .await?
            .into_iter()
            .find(|person| person.name == teaching.person);
        if teaching.existing_only && existing.is_none() {
            None
        } else {
            let fresh = existing.is_none();
            let person = existing.unwrap_or_else(|| PersonRecord {
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
            Some(TeachingPlan {
                person,
                fresh,
                voices: teaching.voices.clone(),
                source: teaching.source.clone(),
                start_position,
            })
        }
    } else {
        None
    };
    save_with_aux_mode(
        db,
        before,
        after,
        SaveExtras {
            version_voices: Some((id, voices)),
            teaching: plan.as_ref(),
            ..SaveExtras::default()
        },
        Some(scope),
    )
    .await?;
    Ok(plan.is_some())
}

async fn save_with_aux(
    db: &Surreal<Db>,
    before: &Value,
    after: &Value,
    extras: SaveExtras<'_>,
) -> Result<(), String> {
    save_with_aux_mode(db, before, after, extras, None).await
}

async fn save_with_aux_mode(
    db: &Surreal<Db>,
    before: &Value,
    after: &Value,
    extras: SaveExtras<'_>,
    scope: Option<&WriteScope>,
) -> Result<(), String> {
    let old = flatten_with_scope(before, scope)?;
    let new = flatten_with_scope(after, scope)?;
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    let result = async {
        for ((table, key), row) in &new {
            if old.get(&(table.clone(), key.clone())).is_some_and(|previous| previous.parent == row.parent && previous.position == row.position && previous.payload == row.payload) { continue; }
            let preview = if table == "version" || table == "publication" { preview_for(table, &row.payload)? } else { Value::Null };
            tx.query("UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload, title = $title, status = $status, createdAt = $createdAt, backend = $backend, state = $state, recordingId = $recordingId")
                .bind(("table", table.as_str())).bind(("key", key.as_str()))
                .bind(("parent", row.parent.as_str())).bind(("position", row.position))
                .bind(("payload", row.payload.clone()))
                .bind(("title", row.payload["title"].clone())).bind(("status", row.payload["status"].clone()))
                .bind(("createdAt", row.payload["createdAt"].clone())).bind(("backend", row.payload["backend"].clone()))
                .bind(("state", row.payload["state"].clone())).bind(("recordingId", row.payload["recordingId"].clone()))
                .await.map_err(|e| e.to_string())?
                .check().map_err(|e| e.to_string())?;
            if table == "version" || table == "publication" {
                let preview_table = format!("{table}_preview");
                tx.query("UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
                    .bind(("table", preview_table)).bind(("key", key.as_str()))
                    .bind(("parent", row.parent.as_str())).bind(("position", row.position))
                    .bind(("payload", preview)).await.map_err(|e| e.to_string())?
                    .check().map_err(|e| e.to_string())?;
            }
            if table == "recording" && row.payload["status"] == "discarded" {
                let record_parent = parent_literal(key)?;
                let mut versions = tx.query(format!("SELECT payload.id AS version_id FROM version_preview WHERE parent = {record_parent}"))
                    .await.map_err(|e| e.to_string())?
                    .check().map_err(|e| e.to_string())?;
                let ids: Vec<Value> = versions.take(0).map_err(|e| e.to_string())?;
                for version in ids {
                    let id = version["version_id"].as_str().ok_or("Versión guardada sin ID")?;
                    let voice_parent = parent_literal(id)?;
                    tx.query(format!("DELETE voice WHERE parent = {voice_parent}"))
                        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                }
                for child in ["version", "publication", "version_preview", "publication_preview"] {
                    tx.query(format!("DELETE type::table($table) WHERE parent = {record_parent}"))
                        .bind(("table", child))
                        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                }
                for child in ["memory", "trace", "job"] {
                    tx.query(format!("DELETE type::table($table) WHERE parent = {record_parent}"))
                        .bind(("table", child))
                        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                }
            }
        }
        for (table, key) in old.keys() {
            if new.contains_key(&(table.clone(), key.clone())) { continue; }
            tx.query("DELETE type::record($table, $key)")
                .bind(("table", table.as_str())).bind(("key", key.as_str()))
                .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            if table == "recording" {
                let record_parent = parent_literal(key)?;
                let mut versions = tx.query(format!("SELECT payload.id AS version_id FROM version_preview WHERE parent = {record_parent}"))
                    .await.map_err(|e| e.to_string())?
                    .check().map_err(|e| e.to_string())?;
                let ids: Vec<Value> = versions.take(0).map_err(|e| e.to_string())?;
                for version in ids {
                    let id = version["version_id"].as_str().ok_or("Versión guardada sin ID")?;
                    let voice_parent = parent_literal(id)?;
                    tx.query(format!("DELETE voice WHERE parent = {voice_parent}"))
                        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                }
                for child in ["version", "publication", "version_preview", "publication_preview"] {
                    tx.query(format!("DELETE type::table($table) WHERE parent = {record_parent}"))
                        .bind(("table", child))
                        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                }
                for child in ["memory", "trace", "job"] {
                    tx.query(format!("DELETE type::table($table) WHERE parent = {record_parent}"))
                        .bind(("table", child))
                        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                }
            }
            if table == "version" {
                let version_id = old.get(&(table.clone(), key.clone()))
                    .and_then(|row| row.payload["id"].as_str())
                    .ok_or("Versión sin ID")?;
                let voice_parent = parent_literal(version_id)?;
                tx.query(format!("DELETE type::table('voice') WHERE parent = {voice_parent}"))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
            if table == "version" || table == "publication" {
                let preview_table = format!("{table}_preview");
                tx.query("DELETE type::record($table, $key)")
                    .bind(("table", preview_table)).bind(("key", key.as_str()))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
        }
        if let Some(scope) = scope {
            if scope.recipe_aliases.iter().any(|(old, new)| old != new) {
                let mut response = tx
                    .query("SELECT key, payload.recipeId AS recipe_id FROM version_preview")
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                let rows: Vec<Value> = response.take(0).map_err(|e| e.to_string())?;
                let mut updates = Vec::new();
                for row in rows {
                    if let Some(old_recipe) = row["recipe_id"].as_str() {
                        if let Some(new_recipe) = scope.recipe_aliases.get(old_recipe) {
                            if new_recipe != old_recipe {
                                let key = row["key"].as_str().ok_or("Proyección de versión sin clave")?;
                                updates.push((key.to_owned(), new_recipe.as_str()));
                            }
                        }
                    }
                }
                for (key, new_recipe) in updates {
                    for table in ["version", "version_preview"] {
                        tx.query("UPDATE type::record($table, $key) SET payload.recipeId = $replacement")
                            .bind(("table", table)).bind(("key", key.as_str()))
                            .bind(("replacement", new_recipe))
                            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
                    }
                }
            }
        }
        if let Some((version_id, voices)) = extras.version_voices {
            for (position, voice) in voices.iter().enumerate() {
                let record = VersionVoiceRecord { id: format!("{version_id}:{position}"), version_id: version_id.to_owned(), speaker: voice.speaker.clone(), model: voice.model.clone(), embedding: voice.embedding.clone() };
                tx.query("CREATE type::record('voice', $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
                    .bind(("key", record.id.as_str())).bind(("parent", version_id))
                    .bind(("position", position as i64)).bind(("payload", serde_json::to_value(record).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
        }
        if let Some(teaching) = extras.teaching {
            if teaching.fresh {
                tx.query("CREATE type::record('person', $key) SET key = $key, parent = '', position = 0, payload = $payload")
                    .bind(("key", teaching.person.id.as_str())).bind(("payload", serde_json::to_value(&teaching.person).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
            for (index, voice) in teaching.voices.iter().enumerate() {
                let record = PersonVoiceRecord { id: Uuid::new_v4().to_string(), person_id: teaching.person.id.clone(), model: voice.model.clone(), embedding: voice.embedding.clone(), source: teaching.source.clone(), added_at: Utc::now().to_rfc3339() };
                tx.query("CREATE type::record('person_voice', $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
                    .bind(("key", record.id.as_str())).bind(("parent", teaching.person.id.as_str()))
                    .bind(("position", teaching.start_position + index as i64)).bind(("payload", serde_json::to_value(record).map_err(|e| e.to_string())?))
                    .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            }
        }
        for deletion in extras.audio_deletions {
            tx.query("UPSERT type::record('audio_deletion', $key) SET key = $key, parent = '', position = 0, payload = $payload")
                .bind(("key", deletion.id.as_str()))
                .bind(("payload", serde_json::to_value(deletion).map_err(|e| e.to_string())?))
                .await
                .map_err(|e| e.to_string())?
                .check()
                .map_err(|e| e.to_string())?;
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
            Ok(())
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
        (!own.is_empty()).then(|| json!({"name":person.name,"voices":own}))
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
