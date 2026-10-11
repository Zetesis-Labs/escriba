use people::{relabel_voices, strip_embeddings};
use recordings::{audio_copy_root, audio_copy_to_delete, references_audio};
use settings::defaults;
use settings::{canonical_folder, redacted_settings};
mod configuration;
mod drafts;
mod import;
mod knowledge;
mod model;
mod mutations;
mod people;
mod projection;
mod recordings;
mod settings;
mod versions;
mod views;
mod work;
use crate::persistence::{
    changes, AudioDeletion, Children, LibraryWrite, LogQuery, Persistence, Teaching, WriteScope,
};
use crate::voices::{recognize, KnownVoice, SpeakerVoice};
use chrono::Utc;
use fs2::FileExt;
pub use model::LibraryIndex;
pub use model::{Field, LibraryData, Recording, RecordingStatus, Settings, Version, WatchedFolder};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::SystemTime,
};
use uuid::Uuid;

pub fn now() -> String {
    Utc::now().to_rfc3339()
}
fn import_created_at(capture_date: Option<SystemTime>, imported_at: SystemTime) -> String {
    chrono::DateTime::<Utc>::from(capture_date.unwrap_or(imported_at)).to_rfc3339()
}
pub fn id() -> String {
    Uuid::new_v4().to_string()
}
pub fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str, String> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("Falta {key}"))
}
pub(crate) fn discarded_record(record: &Value) -> Result<Value, String> {
    Ok(json!({
        "id": text(record, "id")?,
        "source": record["source"],
        "sourceKey": record["sourceKey"],
        "legacyKey": record["legacyKey"],
        "status": "discarded",
    }))
}

fn migrate_recipe_assignments(mut data: Value) -> Result<Value, String> {
    if data["settings"]["recipeSelectionMigrated"] == true {
        return Ok(data);
    }
    for record in data["recordings"]
        .as_array_mut()
        .ok_or("Biblioteca incompleta")?
    {
        if record["status"] != "discarded" {
            record["recipeId"] = Value::Null;
        }
    }
    data["settings"]["recipeSelectionMigrated"] = json!(true);
    Ok(data)
}
pub fn safe_id(s: &str) -> Result<&str, String> {
    if !s.is_empty()
        && s.len() < 200
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
        && s != "."
        && s != ".."
    {
        Ok(s)
    } else {
        Err("Identificador no válido".into())
    }
}
pub fn atomic_write(path: &Path, data: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Ruta sin carpeta")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let tmp = parent.join(format!(".escriba-{}", id()));
    let result = (|| {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        f.write_all(data)
            .and_then(|_| f.sync_all())
            .map_err(|e| e.to_string())?;
        fs::rename(&tmp, path).map_err(|e| e.to_string())?;
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}

type VersionCommit = (String, String, Vec<SpeakerVoice>, Option<Teaching>);

pub struct Store {
    pub root: PathBuf,
    pub data: LibraryIndex,
    database: Persistence,
    pending_voices: HashMap<String, Vec<SpeakerVoice>>,
    audio_cleanup_enabled: bool,
    _lock: File,
}

impl Store {
    pub fn open(root: PathBuf) -> Result<Self, String> {
        Self::open_with_audio_cleanup(root, true)
    }
    fn open_with_audio_cleanup(root: PathBuf, audio_cleanup_enabled: bool) -> Result<Self, String> {
        fs::create_dir_all(&root).map_err(|e| e.to_string())?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("No se pudo proteger la biblioteca: {e}"))?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(root.join("instance.lock"))
            .map_err(|e| e.to_string())?;
        lock.try_lock_exclusive()
            .map_err(|_| "Escriba ya está abierta con esta biblioteca")?;
        let database = Persistence::open(&root.join("library.surrealkv"))?;
        fs::set_permissions(
            root.join("library.surrealkv"),
            fs::Permissions::from_mode(0o700),
        )
        .map_err(|e| format!("No se pudo proteger SurrealDB: {e}"))?;
        let stored = database.load_index()?;
        let path = root.join("library.json");
        let mut data: Value = if let Some(saved) = stored.as_ref() {
            saved.clone()
        } else if path.exists() {
            serde_json::from_slice(&fs::read(&path).map_err(|e| e.to_string())?)
                .map_err(|e| format!("No se puede leer la biblioteca: {e}"))?
        } else {
            defaults()
        };
        if data["schemaVersion"] != 1 {
            return Err("Versión de biblioteca incompatible".into());
        }
        if data.get("providers").is_none() {
            data["providers"] = json!([]);
        }
        let imported_logs = match data
            .as_object_mut()
            .and_then(|fields| fields.remove("logs"))
        {
            Some(Value::Array(lines)) if stored.is_none() => importable_logs(lines),
            _ => Vec::new(),
        };
        data = migrate_recipe_assignments(data)?;
        let mut discarded_audio = Vec::new();
        for record in data["recordings"]
            .as_array_mut()
            .ok_or("Biblioteca incompleta")?
        {
            if record["status"] == "discarded" {
                if let Some(path) = record["audioPath"].as_str().filter(|path| !path.is_empty()) {
                    discarded_audio.push(PathBuf::from(path));
                }
                *record = discarded_record(record)?;
            } else if record["status"] == "processing" {
                record["status"] = json!("pending");
                record["error"] =
                    json!("El procesamiento se interrumpió al cerrar la app; se puede reanudar.");
            }
        }
        for dir in ["audio", "secrets", "captures", "packages"] {
            let path = root.join(dir);
            fs::create_dir_all(&path).map_err(|e| e.to_string())?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .map_err(|e| format!("No se pudo proteger {}: {e}", path.display()))?;
        }
        let typed = LibraryData::read(&data)?;
        let discarded_audio = discarded_audio
            .iter()
            .map(|path| audio_copy_to_delete(&root, &typed, path))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        let stored_is_new = stored.is_none();
        let before = match stored.as_ref() {
            Some(saved) => LibraryData::read(saved)?,
            None => LibraryData::read(&empty_library())?,
        };
        let no_children = std::collections::HashSet::new();
        let ops = changes(
            &before,
            &typed,
            if stored_is_new {
                Children::All
            } else {
                Children::Only(&no_children)
            },
        )?;
        database.write(LibraryWrite {
            ops,
            audio_deletions: discarded_audio,
            logs: imported_logs,
            ..LibraryWrite::default()
        })?;
        let data = if stored_is_new {
            LibraryIndex::new(typed)?
        } else {
            LibraryIndex::from_index(typed)
        };
        let store = Self {
            root,
            data,
            database,
            pending_voices: HashMap::new(),
            audio_cleanup_enabled,
            _lock: lock,
        };
        store.drain_audio_deletions()?;
        Ok(store)
    }
    fn drain_audio_deletions(&self) -> Result<(), String> {
        if !self.audio_cleanup_enabled {
            return Ok(());
        }
        let audio_root = audio_copy_root(&self.root)?;
        for deletion in self.database.pending_audio_deletions()? {
            let path = Path::new(&deletion.path);
            let metadata = match fs::symlink_metadata(path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.database.complete_audio_deletion(&deletion.id)?;
                    continue;
                }
                Err(error) => {
                    return Err(format!("No se puede comprobar el audio pendiente: {error}"))
                }
            };
            if !metadata.file_type().is_file() {
                return Err("La copia pendiente no es un archivo normal".into());
            }
            if metadata.dev() != deletion.device || metadata.ino() != deletion.inode {
                return Err("La copia de audio pendiente cambió desde el descarte".into());
            }
            let canonical = path
                .canonicalize()
                .map_err(|error| format!("No se puede comprobar el audio pendiente: {error}"))?;
            if canonical != path || !canonical.starts_with(&audio_root) {
                return Err("La copia pendiente está fuera de la biblioteca".into());
            }
            if references_audio(&self.data, &canonical)? {
                return Err("Otra grabación conserva la copia de audio pendiente".into());
            }
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(format!("No se pudo borrar el audio local: {error}")),
            }
            self.database.complete_audio_deletion(&deletion.id)?;
        }
        Ok(())
    }
    pub fn index_json(&self) -> Value {
        self.data.json()
    }
    #[cfg(test)]
    pub fn data_json(&self) -> Value {
        self.full_data_json()
            .expect("No se pudo leer la biblioteca de prueba")
    }
    fn full_data_json(&self) -> Result<Value, String> {
        self.database
            .load()?
            .ok_or_else(|| "Biblioteca sin inicializar".into())
    }
    pub fn settings_json(&self) -> Value {
        json!(&self.data.settings)
    }
    #[cfg(test)]
    pub fn replace(&mut self, data: Value) -> Result<(), String> {
        let typed = LibraryData::read(&data)?;
        if typed.schema_version != 1 {
            return Err("Versión de biblioteca incompatible".into());
        }
        let before = LibraryData::read(&self.full_data_json()?)?;
        let ops = changes(&before, &typed, Children::All)?;
        let index = LibraryIndex::new(typed)?;
        self.database.write(LibraryWrite {
            ops,
            ..LibraryWrite::default()
        })?;
        self.data = index;
        Ok(())
    }
    pub fn replace_catalog(
        &mut self,
        data: Value,
        aliases: HashMap<String, String>,
    ) -> Result<(), String> {
        let next = LibraryData::read(&data)?;
        let ops = changes(&self.data, &next, Children::Only(&Default::default()))?;
        self.database.write(LibraryWrite {
            ops,
            recipe_aliases: aliases,
            ..LibraryWrite::default()
        })?;
        self.data = LibraryIndex::from_index(next);
        Ok(())
    }
    fn commit(&mut self, data: LibraryData) -> Result<(), String> {
        if data.schema_version != 1 {
            return Err("Versión de biblioteca incompatible".into());
        }
        let ops = changes(&self.data, &data, Children::Only(&Default::default()))?;
        self.database.write(LibraryWrite {
            ops,
            ..LibraryWrite::default()
        })?;
        self.data = LibraryIndex::from_index(data);
        Ok(())
    }
    fn scoped_write(
        before: &LibraryData,
        after: &LibraryData,
        scope: WriteScope,
    ) -> Result<LibraryWrite, String> {
        let ops = changes(before, after, Children::Only(&scope.full_recordings))?;
        Ok(scope.into_write(ops))
    }
    pub fn append_log(&self, p: &Value) -> Result<(), String> {
        let level = p["level"].as_str().unwrap_or("info");
        if !["info", "warn", "error"].contains(&level) {
            return Err("Nivel de registro no válido".into());
        }
        self.database.append_log(&json!({
            "id": id(),
            "at": now(),
            "message": text(p, "message")?,
            "level": level,
            "recordingId": p["recordingId"],
            "recipeId": p["recipeId"],
        }))
    }
    pub fn log_list(&self, p: &Value) -> Result<Value, String> {
        let query: LogQuery =
            serde_json::from_value(p.clone()).map_err(|_| "Consulta del registro inválida")?;
        Ok(Value::Array(self.database.log_list(query)?))
    }
    fn recording_edit(&self, key: &str) -> Result<LibraryData, String> {
        let mut data = self.data.edit();
        *record_mut(&mut data, key)? = Recording::read(&self.recording(key)?)?;
        Ok(data)
    }
}
fn empty_library() -> Value {
    json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"providers":[],"settings":{}})
}
fn importable_logs(lines: Vec<Value>) -> Vec<Value> {
    lines
        .into_iter()
        .filter(|line| line["message"].is_string() && line["at"].is_string())
        .map(|mut line| {
            if line["id"].as_str().is_none_or(str::is_empty) {
                line["id"] = json!(id());
            }
            line
        })
        .collect()
}
fn collection(p: &Value) -> Result<&str, String> {
    let c = text(p, "collection")?;
    if ["accounts", "resolvers", "recipes", "destinations"].contains(&c) {
        Ok(c)
    } else {
        Err("Colección desconocida".into())
    }
}
fn record_mut<'a>(data: &'a mut LibraryData, key: &str) -> Result<&'a mut Recording, String> {
    data.recordings
        .iter_mut()
        .find(|record| record.id == key)
        .ok_or_else(|| "Grabación no encontrada".into())
}
fn prune(value: &mut Value, key: &str) {
    match value {
        Value::Object(map) => {
            map.retain(|_, v| v.as_str() != Some(key));
            for v in map.values_mut() {
                prune(v, key);
            }
        }
        Value::Array(a) => {
            a.retain(|v| v.as_str() != Some(key));
            for v in a {
                prune(v, key);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod measurement;
#[cfg(test)]
mod tests;
