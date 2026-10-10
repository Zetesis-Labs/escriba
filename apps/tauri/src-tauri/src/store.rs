use crate::persistence::{AudioDeletion, Persistence, Teaching};
use crate::voices::{recognize, KnownVoice, SpeakerVoice};
use chrono::Utc;
use fs2::FileExt;
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

fn audio_copy_root(root: &Path) -> Result<PathBuf, String> {
    let path = root.join("audio");
    if !fs::symlink_metadata(&path)
        .map_err(|e| e.to_string())?
        .file_type()
        .is_dir()
    {
        return Err("Carpeta de copias de audio inválida".into());
    }
    path.canonicalize().map_err(|e| e.to_string())
}

fn references_audio(data: &Value, copy: &Path) -> Result<bool, String> {
    for record in data["recordings"]
        .as_array()
        .ok_or("Biblioteca incompleta")?
    {
        let paths = [
            record["source"].as_str(),
            (record["status"] != "discarded")
                .then(|| record["audioPath"].as_str())
                .flatten(),
        ];
        for path in paths.into_iter().flatten().filter(|path| !path.is_empty()) {
            if Path::new(path) == copy {
                return Ok(true);
            }
            match Path::new(path).canonicalize() {
                Ok(real) if real == copy => return Ok(true),
                Ok(_) => {}
                Err(error)
                    if copy
                        .parent()
                        .is_some_and(|root| Path::new(path).starts_with(root)) =>
                {
                    return Err(format!(
                        "No se puede comprobar una referencia de audio: {error}"
                    ));
                }
                Err(_) => {}
            }
        }
    }
    Ok(false)
}

fn audio_copy_to_delete(
    root: &Path,
    data: &Value,
    path: &Path,
) -> Result<Option<AudioDeletion>, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("No se puede comprobar el audio: {error}")),
    };
    if !metadata.file_type().is_file() {
        return Err("La copia de audio no es un archivo normal".into());
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("No se puede comprobar el audio: {error}"))?;
    if !canonical.starts_with(audio_copy_root(root)?) {
        return Err("Audio fuera de la biblioteca".into());
    }
    if references_audio(data, &canonical)? {
        return Ok(None);
    }
    Ok(Some(AudioDeletion::new(
        canonical
            .to_str()
            .ok_or("Ruta de audio no UTF-8")?
            .to_owned(),
        metadata.dev(),
        metadata.ino(),
    )))
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
fn strip_embeddings(value: &mut Value) {
    match value {
        Value::Object(fields) => {
            fields.retain(|key, _| {
                let lower = key.to_ascii_lowercase();
                lower != "voices" && !lower.contains("embedding")
            });
            for nested in fields.values_mut() {
                strip_embeddings(nested);
            }
        }
        Value::Array(items) => {
            for item in items {
                strip_embeddings(item);
            }
        }
        _ => {}
    }
}
fn relabel_voices(
    source: &Value,
    corrected: &Value,
    voices: &mut [SpeakerVoice],
) -> Result<(), String> {
    let old = source["segments"]
        .as_array()
        .ok_or("Segmentos de origen inválidos")?;
    let new = corrected["segments"]
        .as_array()
        .ok_or("Segmentos corregidos inválidos")?;
    if old.len() != new.len() {
        return Err("La corrección cambió los segmentos".into());
    }
    let mut labels = HashMap::new();
    for (before, after) in old.iter().zip(new) {
        if let (Some(before), Some(after)) = (before["speaker"].as_str(), after["speaker"].as_str())
        {
            if labels
                .insert(before, after)
                .is_some_and(|previous| previous != after)
            {
                return Err("Un hablante tiene nombres distintos en la corrección".into());
            }
        }
    }
    for voice in voices {
        if let Some(label) = labels.get(voice.speaker.as_str()) {
            voice.speaker = (*label).to_owned();
        }
    }
    Ok(())
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

pub struct Store {
    pub root: PathBuf,
    pub data: Value,
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
        let stored = database.load()?;
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
        let discarded_audio = discarded_audio
            .iter()
            .map(|path| audio_copy_to_delete(&root, &data, path))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        let previous = stored.unwrap_or_else(|| json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}));
        database.save_with_audio_deletions(&previous, &data, &discarded_audio)?;
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
    fn persist(&self, data: &Value) -> Result<(), String> {
        self.database.save(&self.data, data)
    }
    pub fn replace(&mut self, data: Value) -> Result<(), String> {
        if data["schemaVersion"] != 1 {
            return Err("Versión de biblioteca incompatible".into());
        }
        self.persist(&data)?;
        self.data = data;
        Ok(())
    }
    pub fn jobs(&self) -> Result<Vec<Value>, String> {
        self.database.jobs()
    }
    pub fn job_save(&mut self, job: &Value) -> Result<(), String> {
        self.recording_for_write(text(job, "recordingId")?)?;
        self.database.save_job(job)
    }
    #[cfg(test)]
    pub fn job_remove(&mut self, id: &str) -> Result<(), String> {
        self.database.remove_job(id)
    }
    fn memory_key(
        &self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
    ) -> Result<String, String> {
        if fingerprint.is_empty() {
            return Err("Falta la huella de memoria".into());
        }
        let record = self.recording_for_write(recording_id)?;
        if !record["versions"]
            .as_array()
            .is_some_and(|versions| versions.iter().any(|version| version["id"] == version_id))
        {
            return Err("La versión no pertenece a la grabación".into());
        }
        Ok(json!([recording_id, version_id, fingerprint]).to_string())
    }
    pub fn memory_recall(
        &self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
    ) -> Result<Option<Value>, String> {
        self.database
            .recall(&self.memory_key(recording_id, version_id, fingerprint)?)
    }
    pub fn memory_keep(
        &mut self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
        value: &Value,
    ) -> Result<(), String> {
        self.database.keep(
            &self.memory_key(recording_id, version_id, fingerprint)?,
            recording_id,
            value,
        )
    }
    pub fn trace_save(&mut self, trace: &Value) -> Result<(), String> {
        self.recording_for_write(text(trace, "recordingId")?)?;
        let mut trace = trace.clone();
        if trace["id"].as_str().is_none_or(str::is_empty) {
            trace["id"] = json!(id());
        }
        self.database.trace_save(&trace)
    }
    pub fn trace_list(&self, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
        self.database.trace_list(recording_id)
    }
    pub fn people(&self) -> Result<Value, String> {
        self.database.people()
    }
    pub fn known_voices(&self) -> Result<Vec<KnownVoice>, String> {
        self.database.known_voices()
    }
    pub fn add_person_voice(
        &self,
        name: &str,
        voice: &SpeakerVoice,
        source: &str,
    ) -> Result<(), String> {
        self.database.add_person_voice(name, voice, source)
    }
    pub fn rename_person(&self, name: &str, new_name: &str) -> Result<(), String> {
        self.database.rename_person(name, new_name)
    }
    pub fn remove_person_voice(&self, id: &str) -> Result<(), String> {
        self.database.remove_person_voice(id)
    }
    pub fn remove_person(&self, name: &str) -> Result<(), String> {
        self.database.remove_person(name)
    }
    #[cfg(test)]
    pub fn version_voices(&self, id: &str) -> Result<Vec<SpeakerVoice>, String> {
        self.database.version_voices(id)
    }
    pub fn recognize_transcription(
        &mut self,
        recording_id: &str,
        mut transcript: Value,
    ) -> Result<Value, String> {
        self.recording_for_write(recording_id)?;
        self.pending_voices.remove(recording_id);
        let raw_voices = transcript
            .as_object_mut()
            .ok_or("Transcripción inválida")?
            .remove("voices")
            .unwrap_or(json!([]));
        let mut voices: Vec<SpeakerVoice> =
            serde_json::from_value(raw_voices).map_err(|_| "Huellas de voz inválidas")?;
        if voices.iter().any(|voice| {
            voice.speaker.is_empty()
                || voice.model.is_empty()
                || voice.embedding.is_empty()
                || voice.embedding.iter().any(|value| !value.is_finite())
        }) {
            return Err("Huellas de voz inválidas".into());
        }
        strip_embeddings(&mut transcript);
        let mut recognized = Vec::new();
        if !voices.is_empty()
            && transcript["segments"]
                .as_array()
                .is_some_and(|segments| !segments.is_empty())
        {
            let known = self.known_voices()?;
            for recognition in recognize(&voices, &known) {
                let occupied = transcript["segments"].as_array().is_some_and(|segments| {
                    segments
                        .iter()
                        .any(|segment| segment["speaker"] == recognition.person)
                });
                if occupied {
                    continue;
                }
                for segment in transcript["segments"]
                    .as_array_mut()
                    .ok_or("Segmentos inválidos")?
                {
                    if segment["speaker"] == recognition.speaker {
                        segment["speaker"] = json!(recognition.person);
                    }
                }
                for voice in &mut voices {
                    if voice.speaker == recognition.speaker {
                        voice.speaker = recognition.person.clone();
                    }
                }
                recognized.push(json!({"speaker":recognition.speaker,"person":recognition.person,"distance":recognition.distance}));
            }
        }
        transcript["recognitions"] = Value::Array(recognized);
        if voices.is_empty() {
            self.pending_voices.remove(recording_id);
        } else {
            self.pending_voices.insert(recording_id.to_owned(), voices);
        }
        Ok(transcript)
    }
    pub fn library(&self) -> Value {
        let mut value = crate::library_view::light_library(&self.data);
        value["settings"] = redacted_settings(&value["settings"]);
        value["dataPath"] = json!(self.root);
        self.mark_credentials(&mut value);
        value
    }

    pub fn snapshot(&self) -> Value {
        let mut value = self.data.clone();
        value["settings"] = redacted_settings(&value["settings"]);
        value["dataPath"] = json!(self.root);
        self.mark_credentials(&mut value);
        value
    }

    pub fn runtime_context(&self, recording_id: Option<&str>) -> Result<Value, String> {
        let recordings = match recording_id {
            Some(id) => {
                let original = self.recording(id)?;
                let audio_path = original["audioPath"]
                    .as_str()
                    .filter(|path| !path.is_empty())
                    .map(|_| "available");
                let recording = json!({
                    "id": original["id"],
                    "title": original["title"],
                    "createdAt": original["createdAt"],
                    "source": format!("urn:escriba:recording:{id}"),
                    "audioPath": audio_path,
                    "audioHash": original["audioHash"],
                    "duration": original["duration"],
                    "status": original["status"],
                    "error": original["error"],
                    "recipeId": original["recipeId"],
                    "currentVersionId": original["currentVersionId"],
                    "versions": original["versions"],
                    "publications": original["publications"],
                });
                vec![recording]
            }
            None => Vec::new(),
        };
        let mut accounts = self.data["accounts"].clone();
        if let Some(items) = accounts.as_array_mut() {
            for account in items {
                if let Some(folder) = account["folder"].as_str() {
                    account["folder"] = json!(format!(
                        "urn:escriba:folder:{:x}",
                        Sha256::digest(folder.as_bytes())
                    ));
                }
            }
        }
        let settings = &self.data["settings"];
        let mut value = json!({
            "recordings": recordings,
            "settings": {
                "defaultRecipeId": settings["defaultRecipeId"],
                "language": settings["language"],
                "whisperModel": settings["whisperModel"],
            },
            "resolvers": self.data["resolvers"],
            "recipes": self.data["recipes"],
            "accounts": accounts,
            "destinations": self.data["destinations"],
        });
        self.mark_credentials(&mut value);
        Ok(value)
    }

    fn mark_credentials(&self, value: &mut Value) {
        for key in ["accounts", "resolvers"] {
            if let Some(items) = value[key].as_array_mut() {
                for item in items {
                    item["hasCredential"] = json!(self
                        .credential_path(item["id"].as_str().unwrap_or(""))
                        .is_ok_and(|p| p.is_file()));
                }
            }
        }
    }

    pub fn authorize_watched_folder(
        &mut self,
        folder_id: Option<&str>,
        path: &Path,
        name: Option<&str>,
        style: &str,
        bookmark: &[u8],
    ) -> Result<Value, String> {
        if bookmark.is_empty() {
            return Err("La autorización de carpeta está vacía".into());
        }
        if !["any", "voiceMemos", "justPressRecord"].contains(&style) {
            return Err("Estilo de carpeta desconocido".into());
        }
        let canonical = canonical_folder(path)?;
        let mut next = self.data.clone();
        let folders = next["settings"]["watchedFolders"]
            .as_array_mut()
            .ok_or("Carpetas inválidas")?;
        let found = if let Some(folder_id) = folder_id {
            Some(
                folders
                    .iter()
                    .position(|folder| folder["id"] == folder_id)
                    .ok_or("La carpeta vigilada ya no existe")?,
            )
        } else {
            folders.iter().position(|folder| {
                folder["path"]
                    .as_str()
                    .is_some_and(|existing| same_folder(Path::new(existing), &canonical))
            })
        };
        let saved = if let Some(index) = found {
            let relocation = {
                let existing = Path::new(text(&folders[index], "path")?);
                if same_folder(existing, &canonical) {
                    false
                } else {
                    match fs::metadata(existing) {
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                        _ => {
                            return Err(
                                "La carpeta elegida no corresponde a la que se reautoriza".into()
                            );
                        }
                    }
                }
            };
            if relocation
                && folders.iter().enumerate().any(|(other_index, folder)| {
                    other_index != index
                        && folder["path"]
                            .as_str()
                            .is_some_and(|path| same_folder(Path::new(path), &canonical))
                })
            {
                return Err("La nueva ubicación ya pertenece a otra carpeta vigilada".into());
            }
            let folder = &mut folders[index];
            if relocation {
                folder["path"] = json!(canonical);
            }
            folder["accessBookmark"] = json!(bookmark);
            folder
                .as_object_mut()
                .ok_or("Carpeta inválida")?
                .remove("authorizationSaved");
            folder.clone()
        } else {
            let default_name = canonical
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("Carpeta");
            let folder = json!({
                "id":id(),
                "path":canonical,
                "name":name.filter(|value| !value.trim().is_empty()).unwrap_or(default_name),
                "style":style,
                "enabled":true,
                "accessBookmark":bookmark,
            });
            folders.push(folder.clone());
            folder
        };
        self.replace(next)?;
        Ok(redacted_folder(&saved))
    }

    pub fn seed_voice_memos(&mut self, path: &Path) -> Result<bool, String> {
        let settings = &self.data["settings"];
        if settings["voiceMemosSeeded"] == true {
            return Ok(false);
        }
        let adopted = settings["legacyWatchAdopted"] == true;
        let present = settings["watchedFolders"]
            .as_array()
            .ok_or("Carpetas inválidas")?
            .iter()
            .any(|folder| {
                folder["style"] == "voiceMemos"
                    || folder["path"]
                        .as_str()
                        .is_some_and(|existing| same_folder(Path::new(existing), path))
            });
        let seeds = !adopted && !present;
        let mut next = self.data.clone();
        if seeds {
            next["settings"]["watchedFolders"]
                .as_array_mut()
                .ok_or("Carpetas inválidas")?
                .push(json!({"id":id(),"path":path,"name":"Notas de Voz","style":"voiceMemos","enabled":true}));
        }
        next["settings"]["voiceMemosSeeded"] = json!(true);
        self.replace(next)?;
        Ok(seeds)
    }

    pub fn watched_folder_bookmarks(&self) -> Result<Vec<(String, PathBuf, Vec<u8>)>, String> {
        let folders = self.data["settings"]["watchedFolders"]
            .as_array()
            .ok_or("Carpetas inválidas")?;
        folders
            .iter()
            .filter(|folder| folder["enabled"] != false && !folder["accessBookmark"].is_null())
            .map(|folder| {
                Ok((
                    text(folder, "id")?.to_owned(),
                    PathBuf::from(text(folder, "path")?),
                    bookmark_bytes(&folder["accessBookmark"])?,
                ))
            })
            .collect()
    }

    pub fn refresh_watched_folder_bookmark(
        &mut self,
        folder_id: &str,
        previous: &[u8],
        resolved_path: &Path,
        replacement: Option<&[u8]>,
    ) -> Result<bool, String> {
        if replacement.is_some_and(|bytes| bytes.is_empty()) {
            return Err("La autorización renovada está vacía".into());
        }
        let mut next = self.data.clone();
        let folders = next["settings"]["watchedFolders"]
            .as_array_mut()
            .ok_or("Carpetas inválidas")?;
        let Some(folder) = folders.iter_mut().find(|folder| folder["id"] == folder_id) else {
            return Ok(false);
        };
        if folder["accessBookmark"].is_null()
            || bookmark_bytes(&folder["accessBookmark"])? != previous
        {
            return Ok(false);
        }
        folder["path"] = json!(canonical_folder(resolved_path)?);
        if let Some(replacement) = replacement {
            folder["accessBookmark"] = json!(replacement);
        }
        self.replace(next)?;
        Ok(true)
    }
    pub fn recording(&self, record_id: &str) -> Result<Value, String> {
        self.data["recordings"]
            .as_array()
            .and_then(|items| items.iter().find(|r| r["id"] == record_id))
            .cloned()
            .ok_or_else(|| "Grabación no encontrada".into())
    }
    fn recording_for_write(&self, record_id: &str) -> Result<Value, String> {
        let record = self.recording(record_id)?;
        if record["status"] == "discarded" {
            Err("La grabación está descartada".into())
        } else {
            Ok(record)
        }
    }
    pub fn item(&self, collection: &str, item_id: &str) -> Result<Value, String> {
        self.data[collection]
            .as_array()
            .and_then(|items| items.iter().find(|r| r["id"] == item_id))
            .cloned()
            .ok_or_else(|| format!("No existe {item_id} en {collection}"))
    }
    pub fn audio(&self, record_id: &str) -> Result<PathBuf, String> {
        let record = self.recording(record_id)?;
        let path = PathBuf::from(text(&record, "audioPath")?);
        let canonical = path
            .canonicalize()
            .map_err(|e| format!("Audio no disponible: {e}"))?;
        if !canonical.starts_with(
            self.root
                .join("audio")
                .canonicalize()
                .map_err(|e| e.to_string())?,
        ) {
            return Err("Audio fuera de la biblioteca".into());
        }
        Ok(canonical)
    }
    fn credential_path(&self, key: &str) -> Result<PathBuf, String> {
        Ok(self
            .root
            .join("secrets")
            .join(format!("{}.token", safe_id(key)?)))
    }
    pub fn credential(&self, key: &str) -> Result<Option<String>, String> {
        match fs::read_to_string(self.credential_path(key)?) {
            Ok(s) => Ok(Some(s)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("No se puede leer la credencial: {e}")),
        }
    }
    pub fn save_credential(&self, key: &str, value: &str) -> Result<(), String> {
        if self.item("accounts", key).is_err() && self.item("resolvers", key).is_err() {
            return Err("La cuenta no existe".into());
        }
        let path = self.credential_path(key)?;
        if value.trim().is_empty() {
            if path.exists() {
                fs::remove_file(path).map_err(|e| e.to_string())?;
            }
            Ok(())
        } else {
            atomic_write(&path, value.trim().as_bytes())
        }
    }
    pub fn save_connector(&mut self, account: &Value, destination: &Value) -> Result<(), String> {
        let key = text(account, "id")?;
        safe_id(key)?;
        let provider = text(account, "provider")?;
        if !["notion", "okf"].contains(&provider)
            || destination["id"] != key
            || destination["account"] != key
            || destination["provider"] != provider
            || destination.get("program").is_some()
            || destination["enabled"].as_bool().is_none()
        {
            return Err("Cuenta y destino del conector no coinciden".into());
        }
        if !account.is_object() || !destination["configuration"].is_object() {
            return Err("Configuración del conector inválida".into());
        }
        if self
            .item("accounts", key)
            .is_ok_and(|old| old["provider"] != provider)
            || self
                .item("destinations", key)
                .is_ok_and(|old| !old["program"].is_null())
        {
            return Err("El identificador pertenece a otro conector".into());
        }
        let mut account = account.clone();
        let mut destination = destination.clone();
        account["enabled"] = json!(true);
        if provider == "notion" {
            account["origin"] = json!("https://api.notion.com");
        } else {
            let folder = destination["configuration"]["folder"]
                .as_str()
                .ok_or("Carpeta OKF inválida")?;
            let folder = if folder.is_empty() {
                String::new()
            } else {
                canonical_folder(Path::new(folder))?
                    .to_string_lossy()
                    .into_owned()
            };
            account["folder"] = json!(folder);
            destination["configuration"]["folder"] = json!(folder);
        }
        for field in ["token", "secret", "credential", "hasCredential"] {
            account
                .as_object_mut()
                .ok_or("Cuenta inválida")?
                .remove(field);
        }
        let mut next = self.data.clone();
        for (collection, item) in [("accounts", account), ("destinations", destination)] {
            let items = next[collection]
                .as_array_mut()
                .ok_or("Colección inválida")?;
            if let Some(old) = items.iter_mut().find(|old| old["id"] == key) {
                *old = item;
            } else {
                items.push(item);
            }
        }
        self.replace(next)
    }
    pub fn remove_connector(&mut self, key: &str) -> Result<(), String> {
        let account = self.item("accounts", key)?;
        let destination = self.item("destinations", key)?;
        if !["notion", "okf"].contains(&account["provider"].as_str().unwrap_or(""))
            || destination["account"] != key
            || !destination["program"].is_null()
        {
            return Err("El conector de la app no coincide con su cuenta y destino".into());
        }
        let mut next = self.data.clone();
        for collection in ["accounts", "destinations"] {
            next[collection]
                .as_array_mut()
                .ok_or("Colección inválida")?
                .retain(|item| item["id"] != key);
        }
        for recipe in next["recipes"].as_array_mut().ok_or("Recetas inválidas")? {
            if recipe["kind"] == "form" {
                prune(&mut recipe["values"], key);
            }
        }
        let credential = self.credential_path(key)?;
        self.replace(next)?;
        match fs::remove_file(credential) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "El conector se quitó, pero no se pudo borrar su token: {error}"
            )),
        }
    }
    pub fn import(&mut self, source: &Path, recipe_id: Option<&str>) -> Result<Value, String> {
        self.import_internal(source, recipe_id, None, false)
    }
    pub fn import_recovered_capture(&mut self, source: &Path) -> Result<Value, String> {
        self.import_internal(source, None, None, true)
    }
    pub fn import_with_metadata(
        &mut self,
        source: &Path,
        recipe_id: Option<&str>,
        title: &str,
        started_at: SystemTime,
        source_key: &str,
    ) -> Result<Value, String> {
        if source_key.is_empty() || source_key.len() > 4096 {
            return Err("Identidad de origen inválida".into());
        }
        self.import_internal(
            source,
            recipe_id,
            Some((title, started_at, source_key)),
            false,
        )
    }
    fn import_internal(
        &mut self,
        source: &Path,
        recipe_id: Option<&str>,
        metadata_from_watcher: Option<(&str, SystemTime, &str)>,
        recovered_capture: bool,
    ) -> Result<Value, String> {
        let metadata = source
            .metadata()
            .map_err(|e| format!("No se puede leer {}: {e}", source.display()))?;
        if !metadata.is_file() || metadata.len() == 0 {
            return Err("El audio está vacío o no es un archivo".into());
        }
        let capture_date =
            if recovered_capture {
                Some(metadata.modified().map_err(|e| {
                    format!("No se puede leer la fecha de {}: {e}", source.display())
                })?)
            } else {
                None
            };
        let ext = source
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        if ![
            "m4a", "mp3", "wav", "aac", "flac", "ogg", "oga", "opus", "mp4", "aiff", "aif", "caf",
            "webm", "mov",
        ]
        .contains(&ext.as_str())
        {
            return Err("Formato de audio no admitido".into());
        }
        let mut input = File::open(source).map_err(|e| e.to_string())?;
        let temp = self.root.join("audio").join(format!(".{}.import", id()));
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 65536];
        let copy_result = (|| -> Result<(), String> {
            loop {
                let n = input.read(&mut buffer).map_err(|e| e.to_string())?;
                if n == 0 {
                    break;
                }
                output.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
                hash.update(&buffer[..n]);
            }
            let after = input.metadata().map_err(|e| e.to_string())?;
            if after.len() != metadata.len()
                || after.modified().map_err(|e| e.to_string())?
                    != metadata.modified().map_err(|e| e.to_string())?
            {
                return Err(
                    "El audio cambió durante la copia; espera a que termine de grabarse".into(),
                );
            }
            output.sync_all().map_err(|e| e.to_string())?;
            Ok(())
        })();
        drop(output);
        if let Err(error) = copy_result {
            let _ = fs::remove_file(&temp);
            return Err(error);
        }
        let content_digest = hash.finalize();
        let content_hash = format!("{content_digest:x}");
        let source_text = source.to_string_lossy();
        if metadata_from_watcher.is_none() {
            if let Some(existing) = self.data["recordings"].as_array().and_then(|records| {
                records.iter().find(|record| {
                    record["audioHash"] == content_hash && record["status"] != "failed"
                })
            }) {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                return Ok(existing.clone());
            }
        }
        let prior = if let Some((_, _, source_key)) = metadata_from_watcher {
            self.data["recordings"].as_array().and_then(|records| {
                records
                    .iter()
                    .find(|record| record["sourceKey"] == source_key)
                    .or_else(|| {
                        let inode = source_key.strip_prefix("voiceMemos:")?.rsplit('/').next()?;
                        records.iter().find(|record| {
                            let same_folder = record["source"]
                                .as_str()
                                .and_then(|path| Path::new(path).parent())
                                == source.parent();
                            let legacy_inode = record["legacyKey"].as_str().is_some_and(|key| {
                                key == inode || key == format!("Notas de Voz/{inode}")
                            });
                            record["sourceKey"]
                                .as_str()
                                .is_some_and(|key| key.starts_with("swift:"))
                                && same_folder
                                && legacy_inode
                        })
                    })
                    .or_else(|| {
                        records.iter().find(|record| {
                            record["sourceKey"]
                                .as_str()
                                .is_some_and(|key| key.starts_with("swift:"))
                                && record["legacyKey"].is_string()
                                && record["source"] == source_text.as_ref()
                        })
                    })
                    .or_else(|| {
                        records.iter().find(|record| {
                            record["status"] == "discarded"
                                && record["source"] == source_text.as_ref()
                        })
                    })
                    .cloned()
            })
        } else {
            None
        };
        if let Some(discarded) = prior
            .as_ref()
            .filter(|record| record["status"] == "discarded")
        {
            fs::remove_file(&temp).map_err(|e| e.to_string())?;
            return Ok(discarded.clone());
        }
        let abandoned = self.data["recordings"].as_array().and_then(|records| {
            records
                .iter()
                .find(|record| {
                    record["source"] == source_text.as_ref()
                        && record["status"] == "failed"
                        && record["audioPath"].is_null()
                        && record["id"]
                            .as_str()
                            .is_some_and(|id| id.starts_with("empty-"))
                })
                .cloned()
        });
        let key = if let Some(record) = prior.as_ref().or(abandoned.as_ref()) {
            text(record, "id")?.to_owned()
        } else if let Some((_, _, source_key)) = metadata_from_watcher {
            format!("watch-{:x}", Sha256::digest(source_key.as_bytes()))
        } else {
            content_hash.clone()
        };
        if let Some(prior) = &prior {
            let changed = if let Some(previous) = prior["audioHash"].as_str() {
                previous != content_hash
            } else {
                match self.audio(&key) {
                    Ok(path) => file_hash(&path)?.as_slice() != content_digest.as_slice(),
                    Err(_) => true,
                }
            };
            if let Some((title, started_at, source_key)) =
                metadata_from_watcher.filter(|_| !changed || prior["status"] == "discarded")
            {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                let mut next = self.data.clone();
                let existing = record_mut(&mut next, &key)?;
                existing["source"] = json!(source_text);
                existing["sourceKey"] = json!(source_key);
                if !changed {
                    existing["audioHash"] = json!(content_hash);
                }
                if prior["legacyKey"].is_null() {
                    existing["title"] = json!(title);
                    existing["createdAt"] =
                        json!(chrono::DateTime::<Utc>::from(started_at).to_rfc3339());
                }
                let record = existing.clone();
                self.replace(next)?;
                return Ok(record);
            }
            if changed
                && self.jobs()?.iter().any(|job| {
                    job["recordingId"] == key
                        && matches!(job["state"].as_str(), Some("queued" | "running" | "retry"))
                })
            {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                return Err(
                    "El audio cambió mientras hay un trabajo activo; se reintentará cuando termine"
                        .into(),
                );
            }
        }
        if metadata_from_watcher.is_none() && abandoned.is_none() {
            if let Ok(existing) = self.recording(&key) {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                return Ok(existing);
            }
        }
        let filename = if metadata_from_watcher.is_some() {
            format!("{key}-{content_hash}.{ext}")
        } else {
            format!("{key}.{ext}")
        };
        let target = self.root.join("audio").join(filename);
        let created_copy = match fs::hard_link(&temp, &target) {
            Ok(()) => {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                if let Err(error) =
                    File::open(self.root.join("audio")).and_then(|dir| dir.sync_all())
                {
                    fs::remove_file(&target).map_err(|cleanup| {
                        format!("{error}; no se pudo limpiar la copia: {cleanup}")
                    })?;
                    return Err(format!("No se pudo confirmar la copia de audio: {error}"));
                }
                true
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let matches = file_hash(&temp)? == file_hash(&target)?;
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                if !matches {
                    return Err("La copia de audio existente no coincide con el origen".into());
                }
                false
            }
            Err(error) => {
                fs::remove_file(&temp).map_err(|cleanup| {
                    format!("{error}; no se pudo limpiar el temporal: {cleanup}")
                })?;
                return Err(format!("No se pudo guardar el audio: {error}"));
            }
        };
        let mut next = self.data.clone();
        let records = next["recordings"]
            .as_array_mut()
            .ok_or("Biblioteca inválida")?;
        let old_audio = prior
            .as_ref()
            .and_then(|record| record["audioPath"].as_str())
            .map(PathBuf::from);
        let record = if let Some(existing) = records.iter_mut().find(|record| record["id"] == key) {
            let changed_audio = existing["audioPath"] != json!(target);
            existing["audioPath"] = json!(target);
            existing["audioHash"] = json!(content_hash);
            existing["source"] = json!(source_text);
            if changed_audio || existing["status"] == "failed" {
                existing["status"] = json!("pending");
                existing["error"] = Value::Null;
            }
            if let Some(recipe) = recipe_id {
                existing["recipeId"] = json!(recipe);
            }
            if let Some((title, started_at, source_key)) = metadata_from_watcher {
                existing["title"] = json!(title);
                existing["createdAt"] =
                    json!(chrono::DateTime::<Utc>::from(started_at).to_rfc3339());
                existing["sourceKey"] = json!(source_key);
            }
            existing.clone()
        } else {
            let (title, started_at, source_key) = metadata_from_watcher
                .map(|(title, started_at, source_key)| {
                    (
                        title.to_owned(),
                        chrono::DateTime::<Utc>::from(started_at).to_rfc3339(),
                        Some(source_key),
                    )
                })
                .unwrap_or_else(|| {
                    (
                        source
                            .file_stem()
                            .and_then(|s| s.to_str())
                            .unwrap_or("Grabación")
                            .to_owned(),
                        import_created_at(capture_date, SystemTime::now()),
                        None,
                    )
                });
            let record = json!({"id":key,"title":title,"createdAt":started_at,"sourceKey":source_key,"source":source_text,"audioPath":target,"audioHash":content_hash,"duration":0,"status":"pending","recipeId":recipe_id,"versions":[],"publications":[]});
            records.insert(0, record.clone());
            record
        };
        if let Err(error) = self.replace(next) {
            if created_copy {
                let _ = fs::remove_file(&target);
            }
            return Err(error);
        }
        if let Some(old_audio) = old_audio.filter(|path| path != &target) {
            if old_audio.starts_with(self.root.join("audio")) && old_audio.exists() {
                fs::remove_file(old_audio).map_err(|e| format!("La importación está guardada, pero no se pudo retirar el audio anterior: {e}"))?;
            }
        }
        Ok(record)
    }
    pub fn mutate(&mut self, method: &str, p: &Value) -> Result<Value, String> {
        let guarded = match method {
            "recording_update" | "recording_remove_audio" => Some(text(p, "id")?),
            "version_save" | "version_select" | "version_update" | "publication_save"
            | "publication_remove" => Some(text(p, "recordingId")?),
            _ => None,
        };
        if let Some(recording_id) = guarded {
            self.recording_for_write(recording_id)?;
        }
        let mut next = self.data.clone();
        let mut delete_after_commit: Option<PathBuf> = None;
        let mut audio_to_delete = Vec::new();
        let mut voice_save: Option<(String, String, Vec<SpeakerVoice>, Option<Teaching>)> = None;
        let mut result = match method {
            "recording_update" => {
                let r = record_mut(&mut next, text(p, "id")?)?;
                for key in [
                    "title",
                    "status",
                    "error",
                    "duration",
                    "recipeId",
                    "createdAt",
                ] {
                    if let Some(v) = p.get(key) {
                        r[key] = v.clone();
                    }
                }
                if !["pending", "processing", "done", "failed", "discarded"]
                    .contains(&r["status"].as_str().unwrap_or(""))
                {
                    return Err("Estado no válido".into());
                }
                r.clone()
            }
            "recording_abandoned" => {
                let path = text(p, "path")?;
                let source_key = p["sourceKey"].as_str();
                let key = format!(
                    "empty-{:x}",
                    Sha256::digest(source_key.unwrap_or(path).as_bytes())
                );
                let created_at = p["modifiedAt"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(now);
                let records = next["recordings"]
                    .as_array_mut()
                    .ok_or("Biblioteca inválida")?;
                if let Some(record) = records.iter().find(|r| r["id"] == key) {
                    record.clone()
                } else {
                    let record = json!({"id":key,"title":p["title"].as_str().unwrap_or_else(||Path::new(path).file_stem().and_then(|s|s.to_str()).unwrap_or("Grabación vacía")),"createdAt":created_at,"source":path,"sourceKey":source_key,"audioPath":null,"duration":0,"status":"failed","error":"La grabación permanece vacía tras una hora; vuelve a intentarlo cuando contenga audio.","recipeId":null,"versions":[],"publications":[]});
                    records.insert(0, record.clone());
                    record
                }
            }
            "recording_discard" => {
                let key = text(p, "id")?;
                let prior = self.recording(key)?;
                let r = record_mut(&mut next, key)?;
                *r = discarded_record(r)?;
                let result = r.clone();
                if let Some(path) = prior["audioPath"].as_str().filter(|path| !path.is_empty()) {
                    if let Some(copy) = audio_copy_to_delete(&self.root, &next, Path::new(path))? {
                        audio_to_delete.push(copy);
                    }
                }
                result
            }
            "recording_restore" => {
                let r = record_mut(&mut next, text(p, "id")?)?;
                if r["status"] == "discarded" {
                    return Err("La grabación descartada ya no tiene audio".into());
                }
                r["status"] = json!(if r["versions"].as_array().is_some_and(|a| !a.is_empty()) {
                    "done"
                } else {
                    "pending"
                });
                r.clone()
            }
            "recording_remove_audio" => {
                let key = text(p, "id")?;
                let path = self.audio(key)?;
                delete_after_commit = Some(path);
                let r = record_mut(&mut next, key)?;
                r["audioPath"] = Value::Null;
                Value::Null
            }
            "recording_delete" => {
                let key = text(p, "id")?;
                let record = self.recording(key)?;
                if let Some(path) = record["audioPath"].as_str() {
                    if Path::new(path).try_exists().map_err(|e| e.to_string())? {
                        delete_after_commit = Some(self.audio(key)?);
                    }
                }
                next["recordings"]
                    .as_array_mut()
                    .ok_or("Biblioteca inválida")?
                    .retain(|record| record["id"] != key);
                Value::Null
            }
            "version_save" => {
                let recording_id = text(p, "recordingId")?;
                let r = record_mut(&mut next, recording_id)?;
                if !p["transcript"].is_object()
                    || !p["transcript"]["text"].is_string()
                    || !p["transcript"]["segments"].is_array()
                {
                    return Err("Transcripción inválida".into());
                }
                let mut teaching = None;
                let voices = if let Some(source) = p["sourceVersionId"].as_str() {
                    let source_version = r["versions"]
                        .as_array()
                        .and_then(|versions| {
                            versions.iter().find(|version| version["id"] == source)
                        })
                        .ok_or("La versión de origen no pertenece a la grabación")?;
                    let mut voices = self.database.version_voices(source)?;
                    if p["teaching"].is_object() {
                        let speaker = text(&p["teaching"], "speaker")?;
                        let person = text(&p["teaching"], "person")?;
                        teaching = Some(Teaching {
                            person: person.to_owned(),
                            voices: voices
                                .iter()
                                .filter(|voice| voice.speaker == speaker)
                                .cloned()
                                .collect(),
                            source: recording_id.to_owned(),
                            existing_only: p["teaching"]["existingOnly"] == true,
                        });
                    }
                    relabel_voices(&source_version["transcript"], &p["transcript"], &mut voices)?;
                    voices
                } else {
                    if !p["teaching"].is_null() {
                        return Err("La corrección no indica su versión de origen".into());
                    }
                    self.pending_voices
                        .get(recording_id)
                        .cloned()
                        .unwrap_or_default()
                };
                let mut transcript = p["transcript"].clone();
                strip_embeddings(&mut transcript);
                let mut v = json!({"id":id(),"createdAt":now(),"backend":p["backend"].as_str().unwrap_or("local"),"transcript":transcript,"hasVoices":!voices.is_empty()});
                for key in ["recipeId", "digest", "data", "inputs"] {
                    if let Some(value) = p.get(key) {
                        v[key] = value.clone();
                    }
                }
                r["currentVersionId"] = v["id"].clone();
                r["duration"] = p["transcript"]["duration"]
                    .as_f64()
                    .map_or(r["duration"].clone(), |v| json!(v));
                r["versions"]
                    .as_array_mut()
                    .ok_or("Versiones inválidas")?
                    .push(v.clone());
                voice_save = Some((
                    recording_id.to_owned(),
                    v["id"].as_str().ok_or("Versión sin ID")?.to_owned(),
                    voices,
                    teaching,
                ));
                v
            }
            "version_select" => {
                let r = record_mut(&mut next, text(p, "recordingId")?)?;
                let v = text(p, "versionId")?;
                if !r["versions"]
                    .as_array()
                    .is_some_and(|a| a.iter().any(|x| x["id"] == v))
                {
                    return Err("Versión no encontrada".into());
                }
                r["currentVersionId"] = json!(v);
                Value::Null
            }
            "version_update" => {
                let r = record_mut(&mut next, text(p, "recordingId")?)?;
                let key = text(p, "versionId")?;
                let v = r["versions"]
                    .as_array_mut()
                    .and_then(|a| a.iter_mut().find(|v| v["id"] == key))
                    .ok_or("Versión no encontrada")?;
                for key in ["digest", "data"] {
                    if let Some(value) = p.get(key) {
                        v[key] = value.clone();
                    }
                }
                v.clone()
            }
            "config_save" => {
                let collection = collection(p)?;
                let mut item = p["item"].clone();
                let key = text(&item, "id")?.to_owned();
                if collection == "accounts" || collection == "resolvers" {
                    safe_id(&key)?;
                }
                if !item.is_object() || item["name"].as_str().is_none_or(|s| s.trim().is_empty()) {
                    return Err("Escribe un nombre".into());
                }
                if collection == "resolvers" {
                    if !["stt", "llm"].contains(&item["role"].as_str().unwrap_or("")) {
                        return Err("Papel de resolutor inválido".into());
                    }
                    if !["local-stt", "local-llm"].contains(&key.as_str()) {
                        item["local"] = json!(false);
                    } else {
                        item["local"] = json!(true);
                        item["enabled"] = json!(true);
                    }
                }
                if collection == "accounts" {
                    if !["notion", "okf"].contains(&item["provider"].as_str().unwrap_or("")) {
                        return Err("Proveedor no válido".into());
                    }
                    if item["provider"] == "notion" {
                        item["origin"] = json!("https://api.notion.com");
                    }
                    if let Some(folder) = item["folder"].as_str().filter(|f| !f.is_empty()) {
                        let path = Path::new(folder)
                            .canonicalize()
                            .map_err(|e| format!("Carpeta inaccesible: {e}"))?;
                        if !path.is_dir() {
                            return Err("Elige una carpeta".into());
                        }
                        item["folder"] = json!(path);
                    }
                }
                for secret in ["token", "secret", "credential", "hasCredential"] {
                    item.as_object_mut()
                        .ok_or("Configuración inválida")?
                        .remove(secret);
                }
                for derived in ["bundleFingerprint", "programFingerprint"] {
                    item.as_object_mut()
                        .ok_or("Configuración inválida")?
                        .remove(derived);
                }
                let items = next[collection]
                    .as_array_mut()
                    .ok_or("Colección inválida")?;
                if let Some(old) = items.iter_mut().find(|i| i["id"] == key) {
                    for program in ["bundle", "program"] {
                        if item.get(program).is_none() {
                            if let Some(kept) = old.get(program).cloned() {
                                item[program] = kept;
                            }
                        }
                    }
                    *old = item.clone();
                } else {
                    if collection == "accounts" || collection == "resolvers" {
                        let orphan = self.credential_path(&key)?;
                        if orphan.exists() {
                            fs::remove_file(orphan).map_err(|e| {
                                format!(
                                    "No se pudo retirar la credencial de una cuenta anterior: {e}"
                                )
                            })?;
                        }
                    }
                    items.push(item.clone());
                }
                item
            }
            "config_remove" => {
                let collection = collection(p)?;
                let key = text(p, "id")?;
                if ["local-stt", "local-llm", "default"].contains(&key) {
                    return Err("Esta opción viene de serie y no se puede quitar".into());
                }
                if collection == "accounts"
                    && next["recordings"].as_array().is_some_and(|rs| {
                        rs.iter().any(|r| {
                            r["publications"]
                                .as_array()
                                .is_some_and(|ps| ps.iter().any(|p| p["accountId"] == key))
                        })
                    })
                {
                    return Err(
                        "Retira las publicaciones de esta cuenta antes de eliminarla".into(),
                    );
                }
                next[collection]
                    .as_array_mut()
                    .ok_or("Colección inválida")?
                    .retain(|i| i["id"] != key);
                if collection == "resolvers" || collection == "destinations" {
                    for recipe in next["recipes"].as_array_mut().ok_or("Recetas inválidas")? {
                        if recipe["kind"] == "form" {
                            prune(&mut recipe["values"], key);
                        }
                    }
                }
                if next["settings"]["defaultRecipeId"] == key {
                    next["settings"]["defaultRecipeId"] = json!("default");
                }
                if collection == "accounts" || collection == "resolvers" {
                    delete_after_commit = Some(self.credential_path(key)?);
                }
                Value::Null
            }
            "settings_save" => {
                let s = p["settings"].as_object().ok_or("Ajustes inválidos")?;
                let watched = s
                    .get("watchedFolders")
                    .map(|incoming| {
                        sanitize_watched_folders(incoming, &self.data["settings"]["watchedFolders"])
                    })
                    .transpose()?;
                let target = next["settings"]
                    .as_object_mut()
                    .ok_or("Ajustes inválidos")?;
                for (key, value) in s {
                    if target.contains_key(key) || SETTABLE.contains(&key.as_str()) {
                        target.insert(
                            key.clone(),
                            if key == "watchedFolders" {
                                watched.clone().ok_or("Carpetas inválidas")?
                            } else {
                                value.clone()
                            },
                        );
                    }
                }
                redacted_settings(&Value::Object(target.clone()))
            }
            "log" => {
                let entry = json!({"id":id(),"at":now(),"message":text(p,"message")?,"level":p["level"].as_str().unwrap_or("info"),"recordingId":p["recordingId"],"recipeId":p["recipeId"]});
                let logs = next["logs"].as_array_mut().ok_or("Registro inválido")?;
                logs.insert(0, entry);
                logs.truncate(3000);
                Value::Null
            }
            "log_clear" => {
                next["logs"] = json!([]);
                Value::Null
            }
            "publication_save" => {
                let r = record_mut(&mut next, text(p, "recordingId")?)?;
                let key = text(p, "destinationId")?;
                let mut publication = p.clone();
                publication
                    .as_object_mut()
                    .ok_or("Recibo inválido")?
                    .remove("recordingId");
                publication["updatedAt"] = json!(now());
                let pubs = r["publications"]
                    .as_array_mut()
                    .ok_or("Publicaciones inválidas")?;
                if let Some(old) = pubs.iter_mut().find(|v| v["destinationId"] == key) {
                    *old = publication;
                } else {
                    pubs.push(publication);
                }
                Value::Null
            }
            "publication_remove" => {
                let r = record_mut(&mut next, text(p, "recordingId")?)?;
                let key = text(p, "destinationId")?;
                r["publications"]
                    .as_array_mut()
                    .ok_or("Publicaciones inválidas")?
                    .retain(|v| v["destinationId"] != key);
                Value::Null
            }
            _ => return Err(format!("Operación desconocida: {method}")),
        };
        if let Some((recording_id, version_id, voices, teaching)) = voice_save {
            let report_learning = teaching.is_some();
            let learned =
                self.database
                    .save_version(&self.data, &next, &version_id, &voices, teaching)?;
            self.data = next;
            self.pending_voices.remove(&recording_id);
            if report_learning {
                result["learnedVoice"] = json!(learned);
            }
        } else if method == "recording_discard" {
            self.database
                .save_with_audio_deletions(&self.data, &next, &audio_to_delete)?;
            self.data = next;
        } else {
            self.replace(next)?;
        }
        if method == "recording_discard" {
            self.pending_voices.remove(text(p, "id")?);
            self.drain_audio_deletions()?;
        }
        if let Some(path) = delete_after_commit {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    return Err(format!(
                        "El cambio está guardado, pero no se pudo eliminar el archivo local: {e}"
                    ))
                }
            }
        }
        Ok(result)
    }
}
fn file_hash(path: &Path) -> Result<Vec<u8>, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let count = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hash.finalize().to_vec())
}
fn canonical_folder(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|error| format!("No se puede acceder a la carpeta: {error}"))?;
    if !path.is_dir() {
        return Err("La ruta elegida no es una carpeta".into());
    }
    Ok(path)
}
fn same_folder(left: &Path, right: &Path) -> bool {
    left == right
        || left
            .canonicalize()
            .ok()
            .zip(right.canonicalize().ok())
            .is_some_and(|(left, right)| left == right)
}
fn bookmark_bytes(value: &Value) -> Result<Vec<u8>, String> {
    let bytes = serde_json::from_value::<Vec<u8>>(value.clone())
        .map_err(|_| "La autorización guardada está dañada")?;
    if bytes.is_empty() {
        return Err("La autorización guardada está vacía".into());
    }
    Ok(bytes)
}
fn redacted_folder(folder: &Value) -> Value {
    let mut redacted = folder.clone();
    let authorized = bookmark_bytes(&redacted["accessBookmark"]).is_ok();
    if let Some(object) = redacted.as_object_mut() {
        object.remove("accessBookmark");
        object.insert("authorizationSaved".into(), json!(authorized));
    }
    redacted
}
fn redacted_settings(settings: &Value) -> Value {
    let mut redacted = settings.clone();
    if let Some(folders) = redacted["watchedFolders"].as_array_mut() {
        for folder in folders {
            *folder = redacted_folder(folder);
        }
    }
    redacted
}
fn sanitize_watched_folders(incoming: &Value, existing: &Value) -> Result<Value, String> {
    let incoming = incoming.as_array().ok_or("Carpetas inválidas")?;
    let existing = existing.as_array().ok_or("Carpetas inválidas")?;
    let mut seen = std::collections::HashSet::new();
    let mut result = Vec::with_capacity(incoming.len());
    for folder in incoming {
        let folder_id = text(folder, "id")?;
        if !seen.insert(folder_id) {
            return Err("Hay carpetas con el mismo identificador".into());
        }
        let path = text(folder, "path")?;
        let name = text(folder, "name")?;
        let style = folder["style"].as_str().unwrap_or("any");
        if !["any", "voiceMemos", "justPressRecord"].contains(&style) {
            return Err("Estilo de carpeta desconocido".into());
        }
        let mut entry = json!({
            "id":folder_id,
            "path":path,
            "name":name,
            "style":style,
            "enabled":folder["enabled"] != false,
        });
        if let Some(prior) = existing.iter().find(|prior| prior["id"] == folder_id) {
            if same_folder(Path::new(path), Path::new(text(prior, "path")?))
                && !prior["accessBookmark"].is_null()
            {
                entry["accessBookmark"] = prior["accessBookmark"].clone();
            }
        }
        result.push(entry);
    }
    Ok(json!(result))
}
fn collection(p: &Value) -> Result<&str, String> {
    let c = text(p, "collection")?;
    if ["accounts", "resolvers", "recipes", "destinations"].contains(&c) {
        Ok(c)
    } else {
        Err("Colección desconocida".into())
    }
}
fn record_mut<'a>(data: &'a mut Value, key: &str) -> Result<&'a mut Value, String> {
    data["recordings"]
        .as_array_mut()
        .and_then(|a| a.iter_mut().find(|r| r["id"] == key))
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
const SETTABLE: [&str; 9] = [
    "defaultRecipeId",
    "projectPath",
    "watchedFolders",
    "language",
    "whisperModel",
    "autoProcess",
    "launchAtLogin",
    "theme",
    "notifyEveryNote",
];

fn defaults() -> Value {
    json!({"schemaVersion":1,"recordings":[],"accounts":[],"destinations":[],"logs":[],"resolvers":[{"id":"local-stt","name":"Whisper · en este Mac","role":"stt","local":true,"enabled":true,"model":"openai_whisper-large-v3-v20240930"},{"id":"local-llm","name":"Apple Intelligence","role":"llm","local":true,"enabled":true}],"recipes":[{"id":"default","name":"Por defecto","kind":"form","values":{}}],"settings":{"defaultRecipeId":"default","projectPath":null,"watchedFolders":[],"language":"es","whisperModel":"openai_whisper-large-v3-v20240930","autoProcess":true,"launchAtLogin":false,"theme":"system"}})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voices::SpeakerVoice;

    #[test]
    fn fecha_de_incorporacion_usa_la_del_fichero_solo_para_captura_recuperada() {
        let imported_at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_750_000_000);
        let captured_at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);

        assert_eq!(
            import_created_at(Some(captured_at), imported_at),
            "2023-11-14T22:13:20+00:00"
        );
        assert_eq!(
            import_created_at(None, imported_at),
            "2025-06-15T15:06:40+00:00"
        );
    }

    #[test]
    fn captura_recuperada_conserva_la_fecha_del_fichero_tras_reabrir_la_biblioteca() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let capture = dir.path().join("captura.m4a");
        fs::write(&capture, b"audio sintetico").unwrap();
        File::open(&capture)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000))
            .unwrap();

        let mut store = Store::open(root.clone()).unwrap();
        let record = store.import_recovered_capture(&capture).unwrap();
        assert_eq!(record["createdAt"], "2023-11-14T22:13:20+00:00");
        drop(store);

        let reopened = Store::open(root).unwrap();
        assert_eq!(
            reopened.recording(record["id"].as_str().unwrap()).unwrap()["createdAt"],
            "2023-11-14T22:13:20+00:00"
        );
    }

    #[test]
    fn las_personas_guardan_varias_huellas_privadas_y_solo_exponen_metadatos() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let store = Store::open(root.clone()).unwrap();
        let first = SpeakerVoice {
            speaker: "Speaker 1".into(),
            model: "m".into(),
            embedding: vec![0.123456, -0.654321],
        };
        let second = SpeakerVoice {
            speaker: "Speaker 2".into(),
            model: "m".into(),
            embedding: vec![0.5, 0.5],
        };
        store.add_person_voice("Rubén", &first, "a").unwrap();
        store.add_person_voice("Rubén", &second, "b").unwrap();
        let people = store.people().unwrap();
        assert_eq!(people.as_array().unwrap().len(), 1);
        assert_eq!(people[0]["name"], "Rubén");
        assert_eq!(people[0]["voices"].as_array().unwrap().len(), 2);
        assert_eq!(people[0]["voices"][0]["source"], "a");
        assert!(people.to_string().find("embedding").is_none());
        assert_eq!(store.known_voices().unwrap().len(), 2);
        assert!(!store.snapshot().to_string().contains("0.123456"));
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert_eq!(reopened.known_voices().unwrap().len(), 2);
    }

    #[test]
    fn renombrar_juntar_y_quitar_huellas_conserva_solo_personas_con_voz() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("library")).unwrap();
        for (name, source, embedding) in [
            ("Ruben", "a", vec![1.0, 0.0]),
            ("Ruben", "b", vec![0.9, 0.1]),
            ("Rubén G.", "c", vec![0.0, 1.0]),
            ("Ana", "d", vec![1.0, 1.0]),
        ] {
            store
                .add_person_voice(
                    name,
                    &SpeakerVoice {
                        speaker: "S".into(),
                        model: "m".into(),
                        embedding,
                    },
                    source,
                )
                .unwrap();
        }
        let redundant = store
            .people()
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .find(|person| person["name"] == "Ruben")
            .unwrap()["voices"][1]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        store.remove_person_voice(&redundant).unwrap();
        store.rename_person("Ruben", "Rubén").unwrap();
        store.rename_person("Rubén G.", "Rubén").unwrap();
        store.remove_person("Ana").unwrap();
        let people = store.people().unwrap();
        assert_eq!(people.as_array().unwrap().len(), 1);
        assert_eq!(people[0]["name"], "Rubén");
        assert_eq!(
            people[0]["voices"]
                .as_array()
                .unwrap()
                .iter()
                .map(|voice| voice["source"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["a", "c"]
        );
        let first = people[0]["voices"][0]["id"].as_str().unwrap().to_owned();
        let last = people[0]["voices"][1]["id"].as_str().unwrap().to_owned();
        store.remove_person_voice(&first).unwrap();
        store.remove_person_voice(&last).unwrap();
        assert!(store.people().unwrap().as_array().unwrap().is_empty());
    }

    #[test]
    fn transcribir_reconoce_sin_exponer_huellas_y_la_version_las_conserva() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let recording = store.import(&audio, None).unwrap();
        let key = recording["id"].as_str().unwrap();
        store
            .add_person_voice(
                "Rubén",
                &SpeakerVoice {
                    speaker: "S".into(),
                    model: "m".into(),
                    embedding: vec![1.0, 0.0],
                },
                "muestra de voz",
            )
            .unwrap();
        let transcript = store.recognize_transcription(key, json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0.0,"end":1.0,"text":"hola","words":[]}],"voices":[{"speaker":"Speaker 1","model":"m","embedding":[1.0,0.01]}]})).unwrap();
        assert_eq!(transcript["segments"][0]["speaker"], "Rubén");
        assert_eq!(transcript["recognitions"][0]["speaker"], "Speaker 1");
        assert!(!transcript.to_string().contains("embedding"));
        let version = store
            .mutate(
                "version_save",
                &json!({"recordingId":key,"backend":"local-stt","transcript":transcript}),
            )
            .unwrap();
        assert_eq!(version["hasVoices"], true);
        assert_eq!(
            store
                .version_voices(version["id"].as_str().unwrap())
                .unwrap()[0]
                .speaker,
            "Rubén"
        );
        assert!(!store.snapshot().to_string().contains("embedding"));
        assert!(!store.library().to_string().contains("embedding"));
        assert!(!store
            .recording(key)
            .unwrap()
            .to_string()
            .contains("embedding"));
        assert!(!store
            .runtime_context(Some(key))
            .unwrap()
            .to_string()
            .contains("embedding"));
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert_eq!(
            reopened
                .version_voices(version["id"].as_str().unwrap())
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn copiar_version_reetiqueta_huellas_y_rechaza_origen_de_otra_nota() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let other = dir.path().join("other.wav");
        fs::write(&other, b"other synthetic audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let key = store.import(&audio, None).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let other_key = store.import(&other, None).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        store
            .add_person_voice(
                "Rubén",
                &SpeakerVoice {
                    speaker: "S".into(),
                    model: "m".into(),
                    embedding: vec![1.0, 0.0],
                },
                "muestra",
            )
            .unwrap();
        let recognized = store.recognize_transcription(&key, json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0,"end":1,"text":"hola","words":[]}],"voices":[{"speaker":"Speaker 1","model":"m","embedding":[1.0,0.01]}]})).unwrap();
        let source = store
            .mutate(
                "version_save",
                &json!({"recordingId":key,"transcript":recognized}),
            )
            .unwrap();
        let source_id = source["id"].as_str().unwrap();
        assert!(store.mutate("version_save", &json!({"recordingId":other_key,"sourceVersionId":source_id,"transcript":{"text":"otra","segments":[]}})).is_err());
        let corrected = json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0,"end":1,"text":"hola","words":[]}],"recognitions":[]});
        let copy = store.mutate("version_save", &json!({"recordingId":key,"sourceVersionId":source_id,"backend":"correccion","transcript":corrected})).unwrap();
        assert_eq!(copy["hasVoices"], true);
        assert_eq!(
            store.version_voices(copy["id"].as_str().unwrap()).unwrap()[0].speaker,
            "Speaker 1"
        );
        assert_eq!(store.version_voices(source_id).unwrap()[0].speaker, "Rubén");
    }

    #[test]
    fn corregir_ensena_huellas_atomicamente_y_fusion_sin_persona_solo_reetiqueta() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let key = store.import(&audio, None).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let transcript = store.recognize_transcription(&key, json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0,"end":1,"text":"hola","words":[]}],"voices":[{"speaker":"Speaker 1","model":"m","embedding":[1.0,0.0]}]})).unwrap();
        let source = store
            .mutate(
                "version_save",
                &json!({"recordingId":key,"transcript":transcript}),
            )
            .unwrap();
        let corrected = json!({"text":"hola","segments":[{"speaker":"Ana","start":0,"end":1,"text":"hola","words":[]}],"recognitions":[]});
        let taught = store.mutate("version_save", &json!({"recordingId":key,"sourceVersionId":source["id"],"backend":"correccion","transcript":corrected,"teaching":{"speaker":"Speaker 1","person":"Ana"}})).unwrap();
        assert_eq!(taught["learnedVoice"], true);
        assert_eq!(store.people().unwrap()[0]["name"], "Ana");
        assert_eq!(store.people().unwrap()[0]["voices"][0]["source"], key);
        assert_eq!(
            store
                .version_voices(taught["id"].as_str().unwrap())
                .unwrap()[0]
                .speaker,
            "Ana"
        );
        let merged = store.mutate("version_save", &json!({"recordingId":key,"sourceVersionId":taught["id"],"backend":"correccion","transcript":{"text":"hola","segments":[{"speaker":"Nadie","start":0,"end":1,"text":"hola","words":[]}],"recognitions":[]},"teaching":{"speaker":"Ana","person":"Nadie","existingOnly":true}})).unwrap();
        assert_eq!(merged["learnedVoice"], false);
        assert_eq!(
            store
                .version_voices(merged["id"].as_str().unwrap())
                .unwrap()[0]
                .speaker,
            "Nadie"
        );
        assert_eq!(store.people().unwrap().as_array().unwrap().len(), 1);
    }

    #[test]
    fn avisar_de_cada_nota_se_guarda_aunque_la_biblioteca_no_lo_tuviera() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        store
            .mutate(
                "settings_save",
                &json!({"settings":{"notifyEveryNote":false,"legacyWatchAdopted":true}}),
            )
            .unwrap();
        assert_eq!(store.data["settings"]["notifyEveryNote"], false);
        assert!(store.data["settings"].get("legacyWatchAdopted").is_none());
    }

    #[test]
    fn una_instalacion_nueva_vigila_notas_de_voz_una_sola_vez() {
        let dir = tempfile::tempdir().unwrap();
        let memos = dir.path().join("Recordings");
        let mut store = Store::open(dir.path().join("library")).unwrap();
        assert!(store.seed_voice_memos(&memos).unwrap());
        let folders = store.data["settings"]["watchedFolders"].clone();
        assert_eq!(folders.as_array().unwrap().len(), 1);
        assert_eq!(folders[0]["style"], "voiceMemos");
        assert_eq!(folders[0]["path"], json!(memos));
        store
            .mutate("settings_save", &json!({"settings":{"watchedFolders":[]}}))
            .unwrap();
        assert!(!store.seed_voice_memos(&memos).unwrap());
        assert_eq!(store.data["settings"]["watchedFolders"], json!([]));
    }

    #[test]
    fn las_carpetas_que_vienen_de_swift_no_reciben_notas_de_voz_de_regalo() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let mut next = store.data.clone();
        next["settings"]["legacyWatchAdopted"] = json!(true);
        store.replace(next).unwrap();
        assert!(!store
            .seed_voice_memos(&dir.path().join("Recordings"))
            .unwrap());
        assert_eq!(store.data["settings"]["watchedFolders"], json!([]));
        assert_eq!(store.data["settings"]["voiceMemosSeeded"], true);
    }

    #[test]
    fn carpeta_autorizada_persiste_y_el_bookmark_no_sale_en_respuestas() {
        let dir = tempfile::tempdir().unwrap();
        let library = dir.path().join("library");
        let folder = dir.path().join("VoiceMemos");
        fs::create_dir_all(&folder).unwrap();
        let bytes = b"synthetic-private-bookmark";
        let mut store = Store::open(library.clone()).unwrap();
        let created = store
            .authorize_watched_folder(None, &folder, Some("Notas"), "voiceMemos", bytes)
            .unwrap();
        let id = created["id"].as_str().unwrap().to_owned();
        assert_eq!(created["authorizationSaved"], true);
        assert!(created.get("accessBookmark").is_none());
        assert_eq!(store.watched_folder_bookmarks().unwrap()[0].2, bytes);
        let snapshot = store.snapshot();
        assert_eq!(
            snapshot["settings"]["watchedFolders"][0]["authorizationSaved"],
            true
        );
        assert!(snapshot["settings"]["watchedFolders"][0]
            .get("accessBookmark")
            .is_none());
        let reply = store
            .mutate(
                "settings_save",
                &json!({"settings":{"watchedFolders":snapshot["settings"]["watchedFolders"]}}),
            )
            .unwrap();
        assert!(reply["watchedFolders"][0].get("accessBookmark").is_none());
        assert_eq!(store.watched_folder_bookmarks().unwrap()[0].2, bytes);
        drop(store);
        let store = Store::open(library).unwrap();
        assert_eq!(store.watched_folder_bookmarks().unwrap()[0].0, id);
        assert_eq!(store.watched_folder_bookmarks().unwrap()[0].2, bytes);
        assert!(!store
            .snapshot()
            .to_string()
            .contains("synthetic-private-bookmark"));
    }

    #[test]
    fn reautorizar_misma_ruta_conserva_metadatos_y_cambiar_o_quitar_revoca() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first");
        let second = dir.path().join("second");
        fs::create_dir_all(&first).unwrap();
        fs::create_dir_all(&second).unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let folder = store
            .authorize_watched_folder(
                None,
                &first,
                Some("Original"),
                "voiceMemos",
                b"first-bookmark",
            )
            .unwrap();
        let id = folder["id"].as_str().unwrap().to_owned();
        store.mutate("settings_save", &json!({"settings":{"watchedFolders":[{"id":id,"path":first,"name":"Chosen","style":"any","enabled":false,"authorizationSaved":false,"accessBookmark":[1,2,3]}]}})).unwrap();
        assert_eq!(store.watched_folder_bookmarks().unwrap().len(), 0);
        let duplicate = store
            .authorize_watched_folder(
                None,
                &first,
                Some("Ignored"),
                "justPressRecord",
                b"second-bookmark",
            )
            .unwrap();
        assert_eq!(duplicate["id"], id);
        assert_eq!(duplicate["name"], "Chosen");
        assert_eq!(duplicate["style"], "any");
        assert_eq!(duplicate["enabled"], false);
        assert!(store
            .authorize_watched_folder(Some(&id), &second, None, "any", b"wrong-path")
            .is_err());
        assert_eq!(
            store.data["settings"]["watchedFolders"][0]["accessBookmark"],
            json!(b"second-bookmark")
        );
        store.mutate("settings_save", &json!({"settings":{"watchedFolders":[{"id":id,"path":second,"name":"Moved","style":"any","enabled":true,"accessBookmark":[9,9],"authorizationSaved":true}]}})).unwrap();
        assert!(store.watched_folder_bookmarks().unwrap().is_empty());
        assert!(store.data["settings"]["watchedFolders"][0]
            .get("accessBookmark")
            .is_none());
        store
            .mutate("settings_save", &json!({"settings":{"watchedFolders":[]}}))
            .unwrap();
        assert!(store.data["settings"]["watchedFolders"]
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn renovar_bookmark_respeta_actualizaciones_concurrentes_y_traslados() {
        let dir = tempfile::tempdir().unwrap();
        let old = dir.path().join("old");
        let moved = dir.path().join("moved");
        fs::create_dir_all(&old).unwrap();
        fs::create_dir_all(&moved).unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let folder = store
            .authorize_watched_folder(None, &old, None, "any", b"original")
            .unwrap();
        let id = folder["id"].as_str().unwrap().to_owned();
        assert!(!store
            .refresh_watched_folder_bookmark(&id, b"stale", &moved, Some(b"replacement"))
            .unwrap());
        assert_eq!(
            store.data["settings"]["watchedFolders"][0]["path"],
            json!(old.canonicalize().unwrap())
        );
        assert!(store
            .refresh_watched_folder_bookmark(&id, b"original", &moved, Some(b"replacement"))
            .unwrap());
        assert_eq!(
            store.data["settings"]["watchedFolders"][0]["path"],
            json!(moved.canonicalize().unwrap())
        );
        assert_eq!(
            store.watched_folder_bookmarks().unwrap()[0].2,
            b"replacement"
        );
        assert!(!store
            .refresh_watched_folder_bookmark(&id, b"original", &old, None)
            .unwrap());
        store
            .mutate("settings_save", &json!({"settings":{"watchedFolders":[]}}))
            .unwrap();
        assert!(!store
            .refresh_watched_folder_bookmark(&id, b"replacement", &old, None)
            .unwrap());
    }

    #[test]
    fn reautorizar_carpeta_trasladada_conserva_identidad_y_no_usurpa_otra() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first");
        let moved = dir.path().join("moved");
        let second = dir.path().join("second");
        fs::create_dir_all(&first).unwrap();
        fs::create_dir_all(&second).unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let original = store
            .authorize_watched_folder(None, &first, Some("Original"), "voiceMemos", b"old")
            .unwrap();
        let other = store
            .authorize_watched_folder(None, &second, Some("Otra"), "any", b"other")
            .unwrap();
        let id = original["id"].as_str().unwrap();
        store
            .mutate(
                "settings_save",
                &json!({"settings":{"watchedFolders":[
                    {"id":id,"path":first,"name":"Elegida","style":"voiceMemos","enabled":false},
                    other
                ]}}),
            )
            .unwrap();
        fs::rename(&first, &moved).unwrap();
        assert!(store
            .authorize_watched_folder(Some(id), &second, None, "any", b"wrong")
            .is_err());
        let saved = store
            .authorize_watched_folder(
                Some(id),
                &moved,
                Some("Ignorado"),
                "justPressRecord",
                b"new",
            )
            .unwrap();
        assert_eq!(saved["id"], original["id"]);
        assert_eq!(saved["path"], json!(moved.canonicalize().unwrap()));
        assert_eq!(saved["name"], "Elegida");
        assert_eq!(saved["style"], "voiceMemos");
        assert_eq!(saved["enabled"], false);
        assert_eq!(saved["authorizationSaved"], true);
        assert!(saved.get("accessBookmark").is_none());
        let folders = store.data["settings"]["watchedFolders"].as_array().unwrap();
        assert_eq!(folders.len(), 2);
        assert_eq!(folders[0]["accessBookmark"], json!(b"new"));
        assert_eq!(folders[1]["id"], other["id"]);
        assert_eq!(folders[1]["accessBookmark"], json!(b"other"));
    }

    #[test]
    fn biblioteca_importada_conserva_transcripcion_y_descarte_al_reabrir_y_vigilar() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("note.wav");
        fs::write(&source, b"synthetic imported audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let record = store.import(&source, None).unwrap();
        let id = record["id"].as_str().unwrap();
        store.mutate("version_save", &json!({"recordingId":id,"backend":"whisperkit","transcript":{"text":"Conservada","segments":[]}})).unwrap();
        let mut data = store.data.clone();
        data["recordings"][0]["sourceKey"] = json!("swift:123");
        data["recordings"][0]["legacyKey"] = json!("123");
        data["recordings"].as_array_mut().unwrap().push(json!({"id":"discarded","status":"discarded","source":dir.path().join("old.wav"),"sourceKey":"swift:456","legacyKey":"456"}));
        store.replace(data).unwrap();
        let versions = store.recording(id).unwrap()["versions"].clone();
        drop(store);
        let mut store = Store::open(root).unwrap();
        let renamed = dir.path().join("renamed.wav");
        fs::rename(&source, &renamed).unwrap();
        let refreshed = store
            .import_with_metadata(
                &renamed,
                None,
                "Renamed",
                SystemTime::now(),
                "voiceMemos:folder/123",
            )
            .unwrap();
        assert_eq!(refreshed["id"], id);
        assert_eq!(refreshed["versions"], versions);
        let discarded_source = dir.path().join("discarded-renamed.wav");
        fs::write(&discarded_source, b"discarded audio").unwrap();
        let discarded = store
            .import_with_metadata(
                &discarded_source,
                None,
                "Discarded",
                SystemTime::now(),
                "voiceMemos:folder/456",
            )
            .unwrap();
        assert_eq!(discarded["status"], "discarded");
        assert_eq!(discarded["id"], "discarded");
        assert_eq!(store.data["recordings"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn preserves_versions_and_selection_across_restart() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("test.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let root = dir.path().join("library");
        let mut store = Store::open(root.clone()).unwrap();
        let recording = store.import(&audio, None).unwrap();
        let key = recording["id"].as_str().unwrap();
        let first=store.mutate("version_save",&json!({"recordingId":key,"backend":"test","transcript":{"text":"hola","segments":[]}})).unwrap();
        let second=store.mutate("version_save",&json!({"recordingId":key,"backend":"test","transcript":{"text":"corregido","segments":[]}})).unwrap();
        store.mutate("version_update",&json!({"recordingId":key,"versionId":first["id"],"digest":{"title":"Primera","summary":"Resumen","tags":[]}})).unwrap();
        assert_eq!(
            store.recording(key).unwrap()["currentVersionId"],
            second["id"]
        );
        drop(store);
        let store = Store::open(root).unwrap();
        let saved = store.recording(key).unwrap();
        assert_eq!(saved["versions"].as_array().unwrap().len(), 2);
        assert_eq!(saved["versions"][0]["digest"]["title"], "Primera");
    }
    #[test]
    fn incorporar_sin_elegir_receta_no_fija_la_predeterminada() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("prueba.wav");
        fs::write(&audio, b"audio sintetico").unwrap();
        let root = dir.path().join("library");
        let mut store = Store::open(root.clone()).unwrap();
        let recording = store.import(&audio, None).unwrap();
        assert_eq!(recording["recipeId"], Value::Null);
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert_eq!(
            reopened
                .recording(recording["id"].as_str().unwrap())
                .unwrap()["recipeId"],
            Value::Null
        );
    }

    #[test]
    fn una_grabacion_vacia_no_fija_receta_y_la_eleccion_explicita_se_conserva() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("prueba.wav");
        let root = dir.path().join("library");
        let mut store = Store::open(root.clone()).unwrap();
        let empty = store
            .mutate("recording_abandoned", &json!({"path":audio}))
            .unwrap();
        assert_eq!(empty["recipeId"], Value::Null);
        fs::write(&audio, b"audio sintetico elegido").unwrap();
        let recording = store.import(&audio, Some("elegida")).unwrap();
        assert_eq!(recording["recipeId"], "elegida");
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert_eq!(
            reopened
                .recording(recording["id"].as_str().unwrap())
                .unwrap()["recipeId"],
            "elegida"
        );
    }

    #[test]
    fn deduplicates_audio_and_retains_discard_ledger() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("test.wav");
        fs::write(&audio, b"audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let r = store.import(&audio, None).unwrap();
        store
            .mutate("recording_discard", &json!({"id":r["id"]}))
            .unwrap();
        let again = store.import(&audio, None).unwrap();
        assert_eq!(again["status"], "discarded");
        assert_eq!(store.snapshot()["recordings"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn borrar_de_biblioteca_deja_solo_identidad_y_borra_contenido_y_copia() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("captura.wav");
        fs::write(&source, b"audio sintetico privado").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let record = store.import(&source, None).unwrap();
        let key = record["id"].as_str().unwrap().to_owned();
        let copy = store.audio(&key).unwrap();
        store
            .mutate(
                "version_save",
                &json!({
                    "recordingId":key,
                    "transcript":{"text":"transcripción privada","segments":[]},
                    "digest":{"title":"título privado","summary":"resumen privado"},
                    "data":{"detalle":"dato privado"}
                }),
            )
            .unwrap();

        let discarded = store
            .mutate("recording_discard", &json!({"id":key}))
            .unwrap();
        let tombstone = json!({
            "id":key,"source":source,"sourceKey":null,"legacyKey":null,"status":"discarded"
        });
        assert_eq!(discarded, tombstone);
        assert!(!copy.exists());
        assert!(source.exists());
        drop(store);

        let reopened = Store::open(root).unwrap();
        assert_eq!(reopened.recording(&key).unwrap(), tombstone);
    }

    #[test]
    fn descartar_guarda_borrado_pendiente_y_reintenta_tras_caida() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
        let record = store.import(&source, None).unwrap();
        let id = record["id"].as_str().unwrap();
        let copy = store.audio(id).unwrap();
        store
            .mutate("recording_discard", &json!({"id":id}))
            .unwrap();
        assert_eq!(
            store.recording(id).unwrap(),
            discarded_record(&record).unwrap()
        );
        assert!(copy.exists());
        assert_eq!(store.database.pending_audio_deletions().unwrap().len(), 1);
        assert!(!store
            .snapshot()
            .to_string()
            .contains(copy.to_str().unwrap()));
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert!(!copy.exists());
        assert!(source.exists());
        assert!(reopened
            .database
            .pending_audio_deletions()
            .unwrap()
            .is_empty());
        assert_eq!(
            reopened.recording(id).unwrap(),
            discarded_record(&record).unwrap()
        );
    }

    #[test]
    fn arranque_guarda_el_borrado_de_audio_antes_de_limpiar_lapida_antigua() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let record = store.import(&source, None).unwrap();
        let id = record["id"].as_str().unwrap();
        let copy = store.audio(id).unwrap();
        let mut legacy = store.data.clone();
        legacy["recordings"][0]["status"] = json!("discarded");
        store.replace(legacy).unwrap();
        drop(store);
        let interrupted = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
        assert_eq!(
            interrupted.recording(id).unwrap(),
            discarded_record(&record).unwrap()
        );
        assert!(copy.exists());
        assert_eq!(
            interrupted
                .database
                .pending_audio_deletions()
                .unwrap()
                .len(),
            1
        );
        drop(interrupted);
        let reopened = Store::open(root).unwrap();
        assert!(!copy.exists());
        assert!(source.exists());
        assert!(reopened
            .database
            .pending_audio_deletions()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn borrado_pendiente_ausente_se_da_por_completado_al_abrir() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
        let record = store.import(&source, None).unwrap();
        let copy = store.audio(record["id"].as_str().unwrap()).unwrap();
        store
            .mutate("recording_discard", &json!({"id":record["id"]}))
            .unwrap();
        fs::remove_file(&copy).unwrap();
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert!(reopened
            .database
            .pending_audio_deletions()
            .unwrap()
            .is_empty());
        assert!(source.exists());
    }

    #[test]
    fn borrado_pendiente_no_sigue_enlace_a_original_fuera_de_audio() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
        let record = store.import(&source, None).unwrap();
        let copy = store.audio(record["id"].as_str().unwrap()).unwrap();
        store
            .mutate("recording_discard", &json!({"id":record["id"]}))
            .unwrap();
        fs::remove_file(&copy).unwrap();
        std::os::unix::fs::symlink(&source, &copy).unwrap();
        drop(store);
        assert!(Store::open(root.clone()).is_err());
        assert!(Store::open(root.clone()).is_err());
        assert_eq!(fs::read(&source).unwrap(), b"audio sintetico");
        fs::remove_file(copy).unwrap();
        let reopened = Store::open(root).unwrap();
        assert!(reopened
            .database
            .pending_audio_deletions()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn borrado_pendiente_no_borra_otro_archivo_que_ocupa_la_misma_ruta() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
        let record = store.import(&source, None).unwrap();
        let copy = store.audio(record["id"].as_str().unwrap()).unwrap();
        store
            .mutate("recording_discard", &json!({"id":record["id"]}))
            .unwrap();
        fs::remove_file(&copy).unwrap();
        fs::write(&copy, b"otro audio sintetico").unwrap();
        drop(store);
        assert!(Store::open(root.clone()).is_err());
        assert_eq!(fs::read(&copy).unwrap(), b"otro audio sintetico");
        fs::remove_file(copy).unwrap();
        let reopened = Store::open(root).unwrap();
        assert!(reopened
            .database
            .pending_audio_deletions()
            .unwrap()
            .is_empty());
        assert!(source.exists());
    }

    #[test]
    fn origen_externo_no_comprobable_no_bloquea_borrado_de_copia_local() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        let other = dir.path().join("other.wav");
        let not_a_directory = dir.path().join("archivo");
        fs::write(&source, b"audio uno").unwrap();
        fs::write(&other, b"audio dos").unwrap();
        fs::write(&not_a_directory, b"no es carpeta").unwrap();
        let mut store = Store::open(root).unwrap();
        let first = store.import(&source, None).unwrap();
        let second = store.import(&other, None).unwrap();
        let copy = store.audio(first["id"].as_str().unwrap()).unwrap();
        let mut changed = store.data.clone();
        let records = changed["recordings"].as_array_mut().unwrap();
        records
            .iter_mut()
            .find(|record| record["id"] == second["id"])
            .unwrap()["source"] = json!(not_a_directory.join("child.wav"));
        store.replace(changed).unwrap();
        store
            .mutate("recording_discard", &json!({"id":first["id"]}))
            .unwrap();
        assert!(!copy.exists());
        assert!(source.exists());
        assert!(other.exists());
    }

    #[test]
    fn descarte_no_borra_original_ajeno_ni_copia_compartida_activa() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("original.wav");
        let other = dir.path().join("other.wav");
        fs::write(&source, b"audio uno").unwrap();
        fs::write(&other, b"audio dos").unwrap();
        let mut store = Store::open(root).unwrap();
        let first = store.import(&source, None).unwrap();
        let second = store.import(&other, None).unwrap();
        let copy = store.audio(first["id"].as_str().unwrap()).unwrap();
        let mut changed = store.data.clone();
        let records = changed["recordings"].as_array_mut().unwrap();
        records
            .iter_mut()
            .find(|record| record["id"] == second["id"])
            .unwrap()["audioPath"] = json!(copy);
        store.replace(changed).unwrap();
        store
            .mutate("recording_discard", &json!({"id":first["id"]}))
            .unwrap();
        assert!(copy.exists());
        assert!(store.database.pending_audio_deletions().unwrap().is_empty());

        let mut changed = store.data.clone();
        let records = changed["recordings"].as_array_mut().unwrap();
        records
            .iter_mut()
            .find(|record| record["id"] == second["id"])
            .unwrap()["audioPath"] = json!(source);
        store.replace(changed).unwrap();
        assert!(store
            .mutate("recording_discard", &json!({"id":second["id"]}))
            .is_err());
        assert!(source.exists());
        assert_eq!(
            store.recording(second["id"].as_str().unwrap()).unwrap()["status"],
            "pending"
        );
    }

    #[test]
    fn arranque_normaliza_descartados_antiguos_y_retira_su_copia_de_audio() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("captura.wav");
        fs::write(&source, b"audio sintetico privado").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let first = store.import(&source, None).unwrap();
        let key = first["id"].as_str().unwrap().to_owned();
        let copy = store.audio(&key).unwrap();
        let mut legacy = store.data.clone();
        legacy["recordings"][0]["status"] = json!("discarded");
        store.replace(legacy).unwrap();
        drop(store);

        let reopened = Store::open(root).unwrap();

        assert_eq!(
            reopened.recording(&key).unwrap(),
            discarded_record(&first).unwrap()
        );
        assert!(!copy.exists());
        assert!(source.exists());
    }

    #[test]
    fn borrar_limpia_memoria_traza_trabajo_y_huella_de_version_sin_olvidar_persona() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("captura.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let key = store.import(&source, None).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let voice = SpeakerVoice {
            speaker: "Hablante".into(),
            model: "modelo-sintetico".into(),
            embedding: vec![1.0, 0.0],
        };
        let transcript = store.recognize_transcription(&key, json!({
            "text":"texto privado","segments":[],"voices":[{"speaker":"Hablante","model":"modelo-sintetico","embedding":[1.0,0.0]}]
        })).unwrap();
        let version = store
            .mutate(
                "version_save",
                &json!({"recordingId":key,"transcript":transcript}),
            )
            .unwrap();
        let version_id = version["id"].as_str().unwrap();
        assert_eq!(store.version_voices(version_id).unwrap().len(), 1);
        store
            .memory_keep(
                &key,
                version_id,
                "huella-sintetica",
                &json!({"value":"recuerdo privado"}),
            )
            .unwrap();
        let memory_key = json!([key, version_id, "huella-sintetica"]).to_string();
        store.trace_save(&json!({"id":"traza","recordingId":key,"startedAt":"2026-10-10","detail":"privado"})).unwrap();
        store
            .job_save(&json!({"id":"trabajo","recordingId":key,"state":"cancelled"}))
            .unwrap();
        store.add_person_voice("Persona", &voice, &key).unwrap();

        store
            .mutate("recording_discard", &json!({"id":key}))
            .unwrap();

        assert!(store.version_voices(version_id).unwrap().is_empty());
        assert!(store.database.recall(&memory_key).unwrap().is_none());
        assert!(store.trace_list(Some(&key)).unwrap().is_empty());
        assert!(store.jobs().unwrap().is_empty());
        assert_eq!(store.people().unwrap()[0]["name"], "Persona");
    }

    #[test]
    fn vigilancia_no_resucita_una_lapida_aunque_cambie_el_audio() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("nota.m4a");
        fs::write(&source, b"primera version sintetica").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let first = store
            .import_with_metadata(
                &source,
                None,
                "Nota",
                SystemTime::now(),
                "voiceMemos:folder/42",
            )
            .unwrap();
        let key = first["id"].as_str().unwrap();
        let tombstone = store
            .mutate("recording_discard", &json!({"id":key}))
            .unwrap();

        fs::write(&source, b"segunda version sintetica").unwrap();
        let scanned = store
            .import_with_metadata(
                &source,
                None,
                "Título posterior",
                SystemTime::now(),
                "voiceMemos:folder/42",
            )
            .unwrap();

        assert_eq!(scanned, tombstone);
        assert_eq!(store.recording(key).unwrap(), tombstone);
        assert!(store.jobs().unwrap().is_empty());
    }

    #[test]
    fn vigilancia_reconoce_por_origen_la_lapida_de_una_importacion_manual() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("nota.m4a");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let first = store.import(&source, None).unwrap();
        let tombstone = store
            .mutate("recording_discard", &json!({"id":first["id"]}))
            .unwrap();

        let watched = store
            .import_with_metadata(
                &source,
                None,
                "Nota vigilada",
                SystemTime::now(),
                "voiceMemos:folder/42",
            )
            .unwrap();

        assert_eq!(watched, tombstone);
        assert_eq!(store.data["recordings"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn respuestas_tardias_no_escriben_sobre_una_grabacion_descartada() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("nota.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let key = store.import(&source, None).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let tombstone = store
            .mutate("recording_discard", &json!({"id":key}))
            .unwrap();

        assert!(store
            .mutate("recording_update", &json!({"id":key,"status":"done"}))
            .is_err());
        assert!(store
            .mutate(
                "version_save",
                &json!({"recordingId":key,"transcript":{"text":"tarde","segments":[]}})
            )
            .is_err());
        assert!(store
            .mutate(
                "publication_save",
                &json!({"recordingId":key,"destinationId":"d","receipt":{}})
            )
            .is_err());
        assert!(store
            .trace_save(&json!({"recordingId":key,"detail":"tarde"}))
            .is_err());
        assert!(store
            .job_save(&json!({"id":"tarde","recordingId":key,"state":"queued"}))
            .is_err());
        assert!(store
            .recognize_transcription(&key, json!({"text":"tarde","segments":[],"voices":[]}))
            .is_err());
        assert!(store
            .mutate("recording_restore", &json!({"id":key}))
            .is_err());
        assert_eq!(store.recording(&key).unwrap(), tombstone);
        assert!(store.jobs().unwrap().is_empty());
        assert!(store.trace_list(Some(&key)).unwrap().is_empty());
    }
    #[test]
    fn watched_voice_memo_rename_and_revision_keep_identity_and_versions() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("old.mov");
        fs::write(&source, b"first audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let started = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        let first = store
            .import_with_metadata(&source, None, "Antiguo", started, "voiceMemos:folder/42")
            .unwrap();
        let recording_id = first["id"].as_str().unwrap();
        let first_copy = store.audio(recording_id).unwrap();
        store
            .mutate(
                "version_save",
                &json!({"recordingId":recording_id,"transcript":{"text":"primera","segments":[]}}),
            )
            .unwrap();
        let renamed = dir.path().join("new.mov");
        fs::rename(&source, &renamed).unwrap();
        let same = store
            .import_with_metadata(&renamed, None, "Nuevo", started, "voiceMemos:folder/42")
            .unwrap();
        assert_eq!(same["id"], first["id"]);
        assert_eq!(same["title"], "Nuevo");
        assert_eq!(same["source"], json!(renamed));
        assert_eq!(store.data["recordings"].as_array().unwrap().len(), 1);
        fs::write(&renamed, b"second audio").unwrap();
        let revised = store
            .import_with_metadata(&renamed, None, "Nuevo", started, "voiceMemos:folder/42")
            .unwrap();
        assert_eq!(revised["id"], first["id"]);
        assert_eq!(revised["versions"].as_array().unwrap().len(), 1);
        assert_eq!(revised["status"], "pending");
        assert!(!first_copy.exists());
        assert_eq!(
            fs::read(store.audio(recording_id).unwrap()).unwrap(),
            b"second audio"
        );
    }
    #[test]
    fn changed_watched_audio_waits_for_active_job_before_replacing_copy() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("voice.m4a");
        fs::write(&source, b"first audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let started = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        let first = store
            .import_with_metadata(&source, None, "Original", started, "voiceMemos:folder/42")
            .unwrap();
        let recording_id = first["id"].as_str().unwrap();
        let old_copy = store.audio(recording_id).unwrap();
        store
            .mutate(
                "version_save",
                &json!({"recordingId":recording_id,"transcript":{"text":"primera","segments":[]}}),
            )
            .unwrap();
        store
            .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":"queued"}))
            .unwrap();
        let renamed = dir.path().join("voice-renamed.m4a");
        fs::rename(&source, &renamed).unwrap();
        let same_audio = store
            .import_with_metadata(&renamed, None, "Renamed", started, "voiceMemos:folder/42")
            .unwrap();
        assert_eq!(same_audio["id"], first["id"]);
        assert_eq!(same_audio["status"], first["status"]);
        assert_eq!(same_audio["title"], "Renamed");
        assert_eq!(store.audio(recording_id).unwrap(), old_copy);
        fs::write(&renamed, b"second audio").unwrap();
        for state in ["queued", "running", "retry"] {
            store
                .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":state}))
                .unwrap();
            let error = store
                .import_with_metadata(
                    &renamed,
                    None,
                    "Actualizado",
                    started,
                    "voiceMemos:folder/42",
                )
                .unwrap_err();
            assert!(error.contains("trabajo activo"), "{error}");
            assert_eq!(store.audio(recording_id).unwrap(), old_copy);
            assert_eq!(fs::read(&old_copy).unwrap(), b"first audio");
            assert_eq!(store.recording(recording_id).unwrap()["title"], "Renamed");
            assert_eq!(
                store.recording(recording_id).unwrap()["versions"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );
        }
        store
            .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":"succeeded"}))
            .unwrap();
        let revised = store
            .import_with_metadata(
                &renamed,
                None,
                "Actualizado",
                started,
                "voiceMemos:folder/42",
            )
            .unwrap();
        assert_eq!(revised["id"], first["id"]);
        assert_eq!(revised["title"], "Actualizado");
        assert_eq!(revised["versions"].as_array().unwrap().len(), 1);
        assert!(!old_copy.exists());
        assert_eq!(
            fs::read(store.audio(recording_id).unwrap()).unwrap(),
            b"second audio"
        );
    }
    #[test]
    fn credentials_do_not_enter_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        store.mutate("config_save",&json!({"collection":"accounts","item":{"id":"notion","name":"Notion","provider":"notion","enabled":true,"token":"must-not-persist"}})).unwrap();
        store
            .save_credential("notion", "fake-local-secret")
            .unwrap();
        let state = store.snapshot().to_string();
        assert!(!state.contains("fake-local-secret"));
        assert!(!state.contains("must-not-persist"));
        assert_eq!(
            store.credential("notion").unwrap().as_deref(),
            Some("fake-local-secret")
        );
    }
    #[test]
    fn runtime_context_limits_a_large_library_to_the_requested_recording() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let selected_path = "/private/audio/selected.wav";
        let other_marker = "foreign-recording-marker";
        let selected = json!({
            "id":"selected", "title":"Selected", "audioPath":selected_path,
            "source":"/private/source/selected.wav", "sourceKey":"/private/source-key",
            "legacyKey":"/private/legacy-key",
            "versions":[{"id":"version-1","transcript":{"text":"reusable transcript","segments":[]},"inputs":{"backend":"local-stt"}}],
            "publications":[{"destinationId":"destination-1","receipt":{"locator":"receipt-1"}}]
        });
        let mut data = store.data.clone();
        data["recordings"] = json!([
            selected.clone(),
            {"id":"other","title":other_marker,"audioPath":"/private/audio/other.wav",
             "versions":[{"id":"other-version","transcript":{"text":"X".repeat(33 * 1024 * 1024),"segments":[]}}],"publications":[]}
        ]);
        data["settings"]["watchedFolders"] = json!([{
            "id":"folder-1","path":"/private/watched","accessBookmark":[1,2,3]
        }]);
        data["logs"] = json!([{"id":"log-1","message":"private log marker"}]);
        data["accounts"] = json!([{"id":"account-1","name":"Account","provider":"okf","enabled":true,"folder":"/private/account-folder"}]);
        store.replace(data).unwrap();
        store
            .save_credential("account-1", "synthetic-secret")
            .unwrap();

        assert!(store.snapshot().to_string().len() > 32 * 1024 * 1024);
        let context = store.runtime_context(Some("selected")).unwrap();
        let serialized = context.to_string();
        assert!(serialized.len() < 1024 * 1024);
        assert_eq!(context["recordings"].as_array().unwrap().len(), 1);
        assert_eq!(context["recordings"][0]["id"], "selected");
        assert_eq!(context["recordings"][0]["audioPath"], "available");
        assert_eq!(
            context["recordings"][0]["source"],
            "urn:escriba:recording:selected"
        );
        assert!(context["recordings"][0].get("sourceKey").is_none());
        assert!(context["recordings"][0].get("legacyKey").is_none());
        assert_eq!(context["recordings"][0]["versions"], selected["versions"]);
        assert_eq!(
            context["recordings"][0]["publications"],
            selected["publications"]
        );
        assert_eq!(context["accounts"][0]["hasCredential"], true);
        assert_eq!(context["settings"].as_object().unwrap().len(), 3);
        assert!(context.get("logs").is_none());
        assert!(context.get("dataPath").is_none());
        assert!(!serialized.contains(other_marker));
        assert!(!serialized.contains("other-version"));
        assert!(!serialized.contains(selected_path));
        assert!(!serialized.contains("/private/"));
        assert!(!serialized.contains("private log marker"));
        assert!(!serialized.contains("synthetic-secret"));
        assert!(!serialized.contains("accessBookmark"));

        let folder_fingerprint = context["accounts"][0]["folder"].as_str().unwrap();
        assert!(folder_fingerprint.starts_with("urn:escriba:folder:"));
        assert_eq!(
            store.runtime_context(None).unwrap()["accounts"][0]["folder"],
            folder_fingerprint
        );
        store.data["accounts"][0]["folder"] = json!("/private/changed-folder");
        assert_ne!(
            store.runtime_context(None).unwrap()["accounts"][0]["folder"],
            folder_fingerprint
        );

        let catalog = store.runtime_context(None).unwrap();
        assert!(catalog["recordings"].as_array().unwrap().is_empty());
        assert_eq!(catalog["recipes"], store.snapshot()["recipes"]);
        assert_eq!(
            store.runtime_context(Some("missing")).unwrap_err(),
            "Grabación no encontrada"
        );
    }
    #[test]
    fn surrealkv_preserves_versions_after_json_is_removed() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let audio = dir.path().join("note.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let record = store.import(&audio, None).unwrap();
        store.mutate("version_save", &json!({"recordingId":record["id"],"backend":"test","transcript":{"text":"texto","segments":[]}})).unwrap();
        drop(store);
        if root.join("library.json").exists() {
            fs::remove_file(root.join("library.json")).unwrap();
        }
        let restored = Store::open(root.clone()).unwrap();
        assert!(root.join("library.surrealkv").is_dir());
        assert_eq!(
            restored.recording(record["id"].as_str().unwrap()).unwrap()["versions"][0]
                ["transcript"]["text"],
            "texto"
        );
    }
    #[test]
    fn committed_surreal_rows_survive_forced_process_termination() {
        const ENV_KEY: &str = "ESCRIBA_CRASH_TEST_ROOT";
        if let Ok(root) = std::env::var(ENV_KEY) {
            let root = PathBuf::from(root);
            let mut store = Store::open(root.clone()).unwrap();
            store
                .mutate("log", &json!({"message":"committed before kill"}))
                .unwrap();
            fs::write(root.join("child-ready"), []).unwrap();
            loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        fs::create_dir_all(&root).unwrap();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::tests::committed_surreal_rows_survive_forced_process_termination",
                "--nocapture",
            ])
            .env(ENV_KEY, &root)
            .spawn()
            .unwrap();
        let ready = root.join("child-ready");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        while !ready.exists() && std::time::Instant::now() < deadline {
            if child.try_wait().unwrap().is_some() {
                panic!("El proceso hijo terminó antes de guardar");
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(ready.exists(), "El proceso hijo no confirmó el commit");
        child.kill().unwrap();
        child.wait().unwrap();
        let store = Store::open(root).unwrap();
        assert_eq!(store.data["logs"][0]["message"], "committed before kill");
    }
    #[test]
    fn surreal_records_expose_native_fields_and_objects() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("note.wav");
        fs::write(&source, b"synthetic audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let recording = store.import(&source, None).unwrap();
        store.mutate("version_save", &json!({"recordingId":recording["id"],"backend":"whisper","transcript":{"text":"hola","segments":[]}})).unwrap();
        store
            .job_save(&json!({"id":"job-1","recordingId":recording["id"],"state":"queued"}))
            .unwrap();
        let records = store
            .database
            .select_test("SELECT title, status, payload.title AS nestedTitle FROM recording")
            .unwrap();
        assert_eq!(records[0]["title"], "note");
        assert_eq!(records[0]["status"], "pending");
        assert_eq!(records[0]["nestedTitle"], "note");
        let versions = store
            .database
            .select_test("SELECT backend, payload.transcript.text AS transcriptText FROM version")
            .unwrap();
        assert_eq!(versions[0]["backend"], "whisper");
        assert_eq!(versions[0]["transcriptText"], "hola");
        let jobs = store
            .database
            .select_test("SELECT state, recordingId FROM job")
            .unwrap();
        assert_eq!(jobs[0]["state"], "queued");
        assert_eq!(jobs[0]["recordingId"], recording["id"]);
    }
    #[test]
    fn earlier_surreal_string_rows_upgrade_transactionally_to_native_objects() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("note.wav");
        fs::write(&source, b"synthetic audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let recording = store.import(&source, None).unwrap();
        let recording_id = recording["id"].as_str().unwrap();
        store
            .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":"queued"}))
            .unwrap();
        store.database.downgrade_v1_test().unwrap();
        drop(store);
        let store = Store::open(root).unwrap();
        assert_eq!(store.recording(recording_id).unwrap()["title"], "note");
        assert_eq!(store.jobs().unwrap()[0]["state"], "queued");
        assert_eq!(
            store
                .database
                .select_test("SELECT status, payload.title AS nestedTitle FROM recording")
                .unwrap()[0]["nestedTitle"],
            "note"
        );
        assert_eq!(
            store
                .database
                .select_test("SELECT payload FROM meta WHERE key = 'schema'")
                .unwrap()[0]["payload"],
            "2"
        );
    }
    #[test]
    fn private_store_directories_and_imported_audio_have_restricted_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
        let source = dir.path().join("note.wav");
        fs::write(&source, b"synthetic audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(root.join("audio"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(root.join("library.surrealkv"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let recording = store.import(&source, None).unwrap();
        let audio = store.audio(recording["id"].as_str().unwrap()).unwrap();
        assert_eq!(
            fs::metadata(audio).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    #[test]
    fn trabajos_sobreviven_al_reinicio_y_a_cambios_de_la_biblioteca() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let mut store = Store::open(root.clone()).unwrap();
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let recording = store.import(&audio, None).unwrap();
        let job = json!({"id":"job-1","recordingId":recording["id"],"state":"queued","stage":"Transcribiendo","attempt":2});
        store.job_save(&job).unwrap();
        store
            .mutate("log", &json!({"message":"other change"}))
            .unwrap();
        assert_eq!(store.jobs().unwrap(), vec![job.clone()]);
        drop(store);
        let mut store = Store::open(root).unwrap();
        assert_eq!(store.jobs().unwrap(), vec![job]);
        store.job_remove("job-1").unwrap();
        assert!(store.jobs().unwrap().is_empty());
    }
    #[test]
    fn memories_and_traces_survive_restart_without_entering_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let recording = store.import(&audio, None).unwrap();
        let recording_id = recording["id"].as_str().unwrap();
        let version = store
            .mutate(
                "version_save",
                &json!({"recordingId":recording_id,"transcript":{"text":"hola","segments":[]}}),
            )
            .unwrap();
        let version_id = version["id"].as_str().unwrap();
        let answer = json!({"value":{"answer":"respuesta"}});
        store
            .memory_keep(recording_id, version_id, "fingerprint-1", &answer)
            .unwrap();
        store.trace_save(&json!({"recordingId":recording_id,"recipeId":"default","startedAt":"2026-10-01T00:00:00Z","finishedAt":"2026-10-01T00:00:01Z","steps":[]})).unwrap();
        assert_eq!(
            store
                .memory_recall(recording_id, version_id, "fingerprint-1")
                .unwrap(),
            Some(answer.clone())
        );
        assert_eq!(store.trace_list(Some(recording_id)).unwrap().len(), 1);
        assert!(!store.snapshot().to_string().contains("fingerprint-1"));
        drop(store);
        let store = Store::open(root).unwrap();
        assert_eq!(
            store
                .memory_recall(recording_id, version_id, "fingerprint-1")
                .unwrap(),
            Some(answer)
        );
        assert_eq!(store.trace_list(Some(recording_id)).unwrap().len(), 1);
    }
    #[test]
    fn deleting_recording_cleans_owned_audio_memory_and_traces_but_not_source() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let source = dir.path().join("sample.wav");
        fs::write(&source, b"synthetic audio").unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let recording = store.import(&source, None).unwrap();
        let recording_id = recording["id"].as_str().unwrap();
        let copy = store.audio(recording_id).unwrap();
        let version = store
            .mutate(
                "version_save",
                &json!({"recordingId":recording_id,"transcript":{"text":"hola","segments":[]}}),
            )
            .unwrap();
        let version_id = version["id"].as_str().unwrap();
        store
            .memory_keep(
                recording_id,
                version_id,
                "fingerprint-1",
                &json!({"value":"x"}),
            )
            .unwrap();
        store
            .trace_save(
                &json!({"recordingId":recording_id,"startedAt":"2026-10-01T00:00:00Z","steps":[]}),
            )
            .unwrap();
        store
            .job_save(&json!({"id":"job-active","recordingId":recording_id,"state":"running"}))
            .unwrap();
        store
            .mutate("recording_delete", &json!({"id":recording_id}))
            .unwrap();
        assert!(store.recording(recording_id).is_err());
        assert!(!copy.exists());
        assert_eq!(fs::read(&source).unwrap(), b"synthetic audio");
        assert!(store.trace_list(Some(recording_id)).unwrap().is_empty());
        assert!(store.jobs().unwrap().is_empty());
        drop(store);
        let store = Store::open(root).unwrap();
        assert!(store.recording(recording_id).is_err());
        assert!(store.trace_list(Some(recording_id)).unwrap().is_empty());
        assert!(store.jobs().unwrap().is_empty());
        assert!(store
            .database
            .recall(&json!([recording_id, version_id, "fingerprint-1"]).to_string())
            .unwrap()
            .is_none());
    }
    #[test]
    fn empty_file_is_visible_and_reactivated_when_audio_arrives() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("late.wav");
        fs::write(&path, []).unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let failed = store
            .mutate("recording_abandoned", &json!({"path":path}))
            .unwrap();
        assert_eq!(failed["status"], "failed");
        assert!(failed["audioPath"].is_null());
        fs::write(&path, b"synthetic audio").unwrap();
        let recovered = store.import(&path, None).unwrap();
        assert_eq!(recovered["id"], failed["id"]);
        assert_eq!(recovered["status"], "pending");
        assert_eq!(store.data["recordings"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn empty_voice_memo_recovers_after_rename_by_source_key() {
        let dir = tempfile::tempdir().unwrap();
        let old = dir.path().join("empty.m4a");
        fs::write(&old, []).unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let failed = store
            .mutate(
                "recording_abandoned",
                &json!({"path":old,"sourceKey":"voiceMemos:folder/42","title":"Sin audio"}),
            )
            .unwrap();
        let renamed = dir.path().join("complete.m4a");
        fs::rename(&old, &renamed).unwrap();
        fs::write(&renamed, b"synthetic audio").unwrap();
        let restored = store
            .import_with_metadata(
                &renamed,
                None,
                "Con audio",
                SystemTime::now(),
                "voiceMemos:folder/42",
            )
            .unwrap();
        assert_eq!(restored["id"], failed["id"]);
        assert_eq!(restored["status"], "pending");
        assert_eq!(restored["title"], "Con audio");
        assert_eq!(store.data["recordings"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn imports_previous_experiment_json_once_and_keeps_it_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        fs::create_dir_all(&root).unwrap();
        let mut previous = defaults();
        previous["settings"]["language"] = json!("gl");
        previous["logs"] = json!([{"id":"old-log","at":"2026-10-01T00:00:00Z","message":"original","level":"info"}]);
        let bytes = serde_json::to_vec(&previous).unwrap();
        fs::write(root.join("library.json"), &bytes).unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        assert_eq!(store.data["settings"]["language"], "gl");
        store
            .mutate("settings_save", &json!({"settings":{"language":"es"}}))
            .unwrap();
        drop(store);
        assert_eq!(fs::read(root.join("library.json")).unwrap(), bytes);
        let store = Store::open(root).unwrap();
        assert_eq!(store.data["settings"]["language"], "es");
        assert_eq!(store.data["logs"][0]["message"], "original");
    }
    #[test]
    fn removing_account_removes_its_credential() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let account = json!({"collection":"accounts","item":{"id":"notion","name":"Notion","provider":"notion","enabled":true}});
        store.mutate("config_save", &account).unwrap();
        store.save_credential("notion", "synthetic-secret").unwrap();
        store
            .mutate(
                "config_remove",
                &json!({"collection":"accounts","id":"notion"}),
            )
            .unwrap();
        store.mutate("config_save", &account).unwrap();
        assert_eq!(store.credential("notion").unwrap(), None);
    }
    #[test]
    fn guardar_una_receta_o_un_destino_sin_su_programa_conserva_el_compilado() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let recipe = json!({"id":"resumen","name":"Resumen","kind":"code","values":{},"bundle":"var __recipe = 1;"});
        store
            .mutate(
                "config_save",
                &json!({"collection":"recipes","item":recipe}),
            )
            .unwrap();
        store
            .mutate(
                "config_save",
                &json!({"collection":"recipes","item":{"id":"resumen","name":"Resumen","kind":"code","values":{"idioma":"en"},"bundleFingerprint":"abc"}}),
            )
            .unwrap();
        let saved = store.item("recipes", "resumen").unwrap();
        assert_eq!(saved["bundle"], "var __recipe = 1;");
        assert_eq!(saved["values"]["idioma"], "en");
        assert!(saved.get("bundleFingerprint").is_none());
    }

    #[test]
    fn quitar_conector_borra_cuenta_destino_token_y_valores_sin_borrar_publicaciones() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        store.mutate("config_save", &json!({"collection":"accounts","item":{"id":"conector","name":"Notion","provider":"notion","enabled":true}})).unwrap();
        store.mutate("config_save", &json!({"collection":"destinations","item":{"id":"conector","name":"Notion","provider":"notion","account":"conector","enabled":true,"configuration":{}}})).unwrap();
        store
            .save_credential("conector", "synthetic-token")
            .unwrap();
        store.mutate("config_save", &json!({"collection":"recipes","item":{"id":"form","name":"Form","kind":"form","values":{"conectores":["conector","otro"]}}})).unwrap();
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let record = store.import(&audio, None).unwrap();
        store.mutate("publication_save", &json!({"recordingId":record["id"],"destinationId":"conector","accountId":"conector","receipt":{"locator":"page-1","state":"published"}})).unwrap();

        store.remove_connector("conector").unwrap();

        assert!(store.item("accounts", "conector").is_err());
        assert!(store.item("destinations", "conector").is_err());
        assert_eq!(store.credential("conector").unwrap(), None);
        assert_eq!(
            store.item("recipes", "form").unwrap()["values"]["conectores"],
            json!(["otro"])
        );
        assert_eq!(
            store.recording(record["id"].as_str().unwrap()).unwrap()["publications"][0]["receipt"]
                ["locator"],
            "page-1"
        );
    }

    #[test]
    fn guardar_conector_persiste_cuenta_y_destino_juntos_y_rechaza_pareja_incoherente() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let folder = dir.path().join("bundle");
        fs::create_dir(&folder).unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let account = json!({"id":"connector","name":"OKF","provider":"okf","enabled":true,"folder":folder,"hasCredential":true});
        let destination = json!({"id":"connector","name":"OKF","provider":"okf","account":"connector","enabled":false,"configuration":{"folder":folder,"documents":[]}});
        store.save_connector(&account, &destination).unwrap();
        assert_eq!(
            store.item("accounts", "connector").unwrap()["folder"],
            json!(folder.canonicalize().unwrap())
        );
        assert_eq!(
            store.item("destinations", "connector").unwrap()["configuration"]["folder"],
            json!(folder.canonicalize().unwrap())
        );
        assert!(store
            .item("accounts", "connector")
            .unwrap()
            .get("hasCredential")
            .is_none());
        assert_eq!(
            store.item("destinations", "connector").unwrap()["account"],
            "connector"
        );
        let before = store.data.clone();
        assert!(store.save_connector(&account, &json!({"id":"wrong","name":"OKF","provider":"okf","account":"connector","configuration":{}})).is_err());
        assert!(store.save_connector(&account, &json!({"id":"connector","name":"OKF","provider":"notion","account":"connector","configuration":{}})).is_err());
        assert_eq!(store.data, before);
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert_eq!(
            reopened.item("accounts", "connector").unwrap()["name"],
            "OKF"
        );
        assert_eq!(
            reopened.item("destinations", "connector").unwrap()["provider"],
            "okf"
        );
    }

    #[test]
    fn failed_library_write_preserves_the_audio_copy() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("sample.wav");
        fs::write(&audio, b"synthetic audio").unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let recording = store.import(&audio, None).unwrap();
        let key = recording["id"].as_str().unwrap();
        let saved = store.audio(key).unwrap();
        store.database.query_test(
            "DEFINE FIELD OVERWRITE payload ON TABLE recording ASSERT !string::contains($value, '\"audioPath\":null')",
        ).unwrap();
        assert!(store
            .mutate("recording_remove_audio", &json!({"id":key}))
            .is_err());
        assert!(saved.exists());
        assert_eq!(store.audio(key).unwrap(), saved);
    }
    #[test]
    fn actualizar_olvida_recetas_antiguas_una_vez_y_conserva_elecciones_nuevas() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        fs::create_dir_all(&root).unwrap();
        let mut legacy = defaults();
        legacy["recordings"] = json!([{
            "id":"anterior", "source":"/synthetic/old.wav", "status":"done",
            "recipeId":"receta-antigua", "publications":[],
            "versions":[{"id":"version-anterior","recipeId":"receta-ejecutada","transcript":{"text":"ejemplo","segments":[]}}]
        }]);
        fs::write(
            root.join("library.json"),
            serde_json::to_vec(&legacy).unwrap(),
        )
        .unwrap();
        let mut store = Store::open(root.clone()).unwrap();
        let previous = store.recording("anterior").unwrap();
        assert_eq!(previous["recipeId"], Value::Null);
        assert_eq!(previous["versions"][0]["recipeId"], "receta-ejecutada");
        let audio = dir.path().join("nueva.wav");
        fs::write(&audio, b"eleccion nueva sintetica").unwrap();
        let added = store.import(&audio, Some("elegida-despues")).unwrap();
        drop(store);
        let reopened = Store::open(root).unwrap();
        assert_eq!(
            reopened.recording("anterior").unwrap()["recipeId"],
            Value::Null
        );
        assert_eq!(
            reopened.recording(added["id"].as_str().unwrap()).unwrap()["recipeId"],
            "elegida-despues"
        );
    }

    #[test]
    fn rejects_second_instance_without_replacing_data() {
        let dir = tempfile::tempdir().unwrap();
        let _first = Store::open(dir.path().into()).unwrap();
        assert!(Store::open(dir.path().into()).is_err());
    }
}
