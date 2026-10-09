use crate::migration;
use crate::persistence::Persistence;
use chrono::Utc;
use fs2::FileExt;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::SystemTime,
};
use uuid::Uuid;

pub fn now() -> String {
    Utc::now().to_rfc3339()
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

pub struct Store {
    pub root: PathBuf,
    pub data: Value,
    database: Persistence,
    _lock: File,
}

impl Store {
    pub fn import_startup_legacy(&mut self, source: &Path) -> Result<Option<Value>, String> {
        if self.data["settings"]["legacyImported"] == true
            || self.data["recordings"]
                .as_array()
                .is_some_and(|records| !records.is_empty())
        {
            return Ok(None);
        }
        let database = source.join("library.sqlite");
        match fs::metadata(&database) {
            Ok(metadata) if metadata.is_file() => {}
            Ok(_) => {
                let status = self.record_startup_import_error(
                    "La biblioteca anterior no contiene un archivo library.sqlite válido",
                )?;
                return Ok(Some(status));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(None);
            }
            Err(error) => {
                let status = self.record_startup_import_error(&format!(
                    "No se puede comprobar la biblioteca anterior: {error}"
                ))?;
                return Ok(Some(status));
            }
        }
        match self.import_legacy_with_settings(source, None) {
            Ok(report) => {
                let status = json!({"state":"imported","report":report});
                Ok(Some(status))
            }
            Err(error) => {
                let status = self.record_startup_import_error(&error)?;
                Ok(Some(status))
            }
        }
    }

    pub fn adopt_legacy_watched_folders(
        &mut self,
        settings_plist: &Path,
    ) -> Result<Option<Value>, String> {
        if self.data["settings"]["legacyImported"] != true
            || self.data["settings"]["legacyWatchAdopted"] == true
        {
            return Ok(None);
        }
        let existing = self.data["settings"]["watchedFolders"]
            .as_array()
            .ok_or("Carpetas inválidas")?;
        if !existing.is_empty() {
            let status = json!({"state":"preserved","count":existing.len()});
            let mut next = self.data.clone();
            next["settings"]["legacyWatchAdopted"] = json!(true);
            next["settings"]["watchMigration"] = status.clone();
            self.replace(next)?;
            return Ok(Some(status));
        }
        match fs::metadata(settings_plist) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return self.record_watch_import_error(&format!(
                    "No se pueden leer las preferencias anteriores: {error}"
                ));
            }
            Ok(metadata) if !metadata.is_file() => {
                return self
                    .record_watch_import_error("Las preferencias anteriores no son un archivo");
            }
            Ok(_) => {}
        }
        let folders = match migration::watched_folders_from_plist(settings_plist) {
            Ok(Some(folders)) => folders,
            Ok(None) => json!([]),
            Err(error) => return self.record_watch_import_error(&error),
        };
        let count = folders
            .as_array()
            .ok_or("Carpetas SwiftUI inválidas")?
            .len();
        let status = json!({"state":"adopted","count":count,"paused":true});
        let mut next = self.data.clone();
        next["settings"]["watchedFolders"] = folders;
        next["settings"]["autoProcess"] = json!(false);
        next["settings"]["legacyWatchAdopted"] = json!(true);
        next["settings"]["watchMigration"] = status.clone();
        self.replace(next)?;
        Ok(Some(status))
    }

    fn record_watch_import_error(&mut self, error: &str) -> Result<Option<Value>, String> {
        let status = json!({"state":"error","message":error});
        let mut next = self.data.clone();
        next["settings"]["watchMigration"] = status.clone();
        self.replace(next)?;
        Ok(Some(status))
    }

    fn record_startup_import_error(&mut self, error: &str) -> Result<Value, String> {
        let status = json!({"state":"error","message":error});
        let mut next = self.data.clone();
        next["settings"]["startupMigration"] = status.clone();
        next["settings"]["autoProcess"] = json!(false);
        self.replace(next)?;
        Ok(status)
    }

    pub fn open(root: PathBuf) -> Result<Self, String> {
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
            .map_err(|_| "Escriba Tauri ya está abierta con esta biblioteca")?;
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
        for record in data["recordings"]
            .as_array_mut()
            .ok_or("Biblioteca incompleta")?
        {
            if record["status"] == "processing" {
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
        let previous = stored.unwrap_or_else(|| json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}));
        database.save(&previous, &data)?;
        let store = Self {
            root,
            data,
            database,
            _lock: lock,
        };
        Ok(store)
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
        let record = self.recording(recording_id)?;
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
        self.recording(text(trace, "recordingId")?)?;
        let mut trace = trace.clone();
        if trace["id"].as_str().is_none_or(str::is_empty) {
            trace["id"] = json!(id());
        }
        self.database.trace_save(&trace)
    }
    pub fn trace_list(&self, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
        self.database.trace_list(recording_id)
    }
    pub fn import_legacy(&mut self, source: &Path) -> Result<Value, String> {
        self.import_legacy_with_settings(source, None)
    }
    pub fn import_legacy_with_settings(
        &mut self,
        source: &Path,
        settings_plist: Option<&Path>,
    ) -> Result<Value, String> {
        if source.canonicalize().map_err(|e| e.to_string())?
            == self.root.canonicalize().map_err(|e| e.to_string())?
        {
            return Err("Elige la biblioteca SwiftUI, no la biblioteca Tauri actual".into());
        }
        let mut plan = migration::plan(source, &self.root, &self.data, settings_plist)?;
        plan.data["settings"]["autoProcess"] = json!(false);
        plan.data["settings"]["legacyImported"] = json!(true);
        if settings_plist.is_some() {
            plan.data["settings"]["legacyWatchAdopted"] = json!(true);
            let count = plan.data["settings"]["watchedFolders"]
                .as_array()
                .map_or(0, Vec::len);
            plan.data["settings"]["watchMigration"] =
                json!({"state":"adopted","count":count,"paused":true});
        }
        plan.data["settings"]["startupMigration"] =
            json!({"state":"imported","report":plan.report.clone(),"completedAt":now()});
        let mut copied = ImportCopies::default();
        for (source, target) in &plan.copies {
            if target.exists() {
                if file_hash(source)? != file_hash(target)? {
                    return Err(
                        "La copia de audio existente difiere de la biblioteca SwiftUI".into(),
                    );
                }
                continue;
            }
            let temporary = self.root.join("audio").join(format!(".{}.import", id()));
            let result = (|| {
                fs::copy(source, &temporary).map_err(|e| e.to_string())?;
                fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))
                    .map_err(|e| e.to_string())?;
                File::open(&temporary)
                    .and_then(|file| file.sync_all())
                    .map_err(|e| e.to_string())?;
                if file_hash(source)? != file_hash(&temporary)? {
                    return Err("El audio SwiftUI cambió durante la importación".into());
                }
                fs::rename(&temporary, target).map_err(|e| e.to_string())?;
                copied.paths.push(target.clone());
                Ok::<(), String>(())
            })();
            if result.is_err() {
                let _ = fs::remove_file(&temporary);
            }
            result?;
        }
        if let Err(error) =
            self.database
                .import(&self.data, &plan.data, &plan.memories, &plan.traces)
        {
            return match copied.rollback() {
                Ok(()) => Err(error),
                Err(cleanup) => Err(format!(
                    "{error}; además falló la limpieza del audio copiado: {cleanup}"
                )),
            };
        }
        self.data = plan.data;
        copied.committed = true;
        Ok(plan.report)
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
    pub fn import(&mut self, source: &Path, recipe_id: Option<&str>) -> Result<Value, String> {
        self.import_internal(source, recipe_id, None)
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
        self.import_internal(source, recipe_id, Some((title, started_at, source_key)))
    }
    fn import_internal(
        &mut self,
        source: &Path,
        recipe_id: Option<&str>,
        metadata_from_watcher: Option<(&str, SystemTime, &str)>,
    ) -> Result<Value, String> {
        let metadata = source
            .metadata()
            .map_err(|e| format!("No se puede leer {}: {e}", source.display()))?;
        if !metadata.is_file() || metadata.len() == 0 {
            return Err("El audio está vacío o no es un archivo".into());
        }
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
                    .cloned()
            })
        } else {
            None
        };
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
                        now(),
                        None,
                    )
                });
            let record = json!({"id":key,"title":title,"createdAt":started_at,"sourceKey":source_key,"source":source_text,"audioPath":target,"audioHash":content_hash,"duration":0,"status":"pending","recipeId":recipe_id.unwrap_or(self.data["settings"]["defaultRecipeId"].as_str().unwrap_or("default")),"versions":[],"publications":[]});
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
        let mut next = self.data.clone();
        let mut delete_after_commit: Option<PathBuf> = None;
        let result = match method {
            "recording_update" => {
                let r = record_mut(&mut next, text(p, "id")?)?;
                for key in ["title", "status", "error", "duration", "recipeId"] {
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
                let recipe = next["settings"]["defaultRecipeId"].clone();
                let records = next["recordings"]
                    .as_array_mut()
                    .ok_or("Biblioteca inválida")?;
                if let Some(record) = records.iter().find(|r| r["id"] == key) {
                    record.clone()
                } else {
                    let record = json!({"id":key,"title":p["title"].as_str().unwrap_or_else(||Path::new(path).file_stem().and_then(|s|s.to_str()).unwrap_or("Grabación vacía")),"createdAt":created_at,"source":path,"sourceKey":source_key,"audioPath":null,"duration":0,"status":"failed","error":"La grabación permanece vacía tras una hora; vuelve a intentarlo cuando contenga audio.","recipeId":recipe,"versions":[],"publications":[]});
                    records.insert(0, record.clone());
                    record
                }
            }
            "recording_discard" | "recording_restore" => {
                let r = record_mut(&mut next, text(p, "id")?)?;
                r["status"] = json!(if method == "recording_discard" {
                    "discarded"
                } else if r["versions"].as_array().is_some_and(|a| !a.is_empty()) {
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
                let r = record_mut(&mut next, text(p, "recordingId")?)?;
                if !p["transcript"].is_object()
                    || !p["transcript"]["text"].is_string()
                    || !p["transcript"]["segments"].is_array()
                {
                    return Err("Transcripción inválida".into());
                }
                let mut v = json!({"id":id(),"createdAt":now(),"backend":p["backend"].as_str().unwrap_or("local"),"transcript":p["transcript"]});
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
                let items = next[collection]
                    .as_array_mut()
                    .ok_or("Colección inválida")?;
                if let Some(old) = items.iter_mut().find(|i| i["id"] == key) {
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
                    if target.contains_key(key) {
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
        self.replace(next)?;
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
#[derive(Default)]
struct ImportCopies {
    paths: Vec<PathBuf>,
    committed: bool,
}
impl ImportCopies {
    fn rollback(&mut self) -> Result<(), String> {
        let mut failures = Vec::new();
        for path in &self.paths {
            if let Err(error) = fs::remove_file(path) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    failures.push(format!("{}: {error}", path.display()));
                }
            }
        }
        if failures.is_empty() {
            self.committed = true;
            Ok(())
        } else {
            Err(failures.join(", "))
        }
    }
}
impl Drop for ImportCopies {
    fn drop(&mut self) {
        if !self.committed {
            for path in &self.paths {
                let _ = fs::remove_file(path);
            }
        }
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
fn defaults() -> Value {
    json!({"schemaVersion":1,"recordings":[],"accounts":[],"destinations":[],"logs":[],"resolvers":[{"id":"local-stt","name":"Whisper · en este Mac","role":"stt","local":true,"enabled":true,"model":"openai_whisper-large-v3-v20240930"},{"id":"local-llm","name":"Apple Intelligence","role":"llm","local":true,"enabled":true}],"recipes":[{"id":"default","name":"Por defecto","kind":"form","values":{}}],"settings":{"defaultRecipeId":"default","projectPath":null,"watchedFolders":[],"language":"es","whisperModel":"openai_whisper-large-v3-v20240930","autoProcess":true,"launchAtLogin":false,"theme":"system"}})
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn startup_imports_discovered_swift_notes_once_without_processing_them() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = dir.path().join("escriba/library");
        let root = dir.path().join("tauri");
        fs::create_dir_all(legacy.join("audio")).unwrap();
        fs::write(legacy.join("audio/first.m4a"), b"synthetic first audio").unwrap();
        fs::write(legacy.join("audio/second.m4a"), b"synthetic second audio").unwrap();
        let sql = rusqlite::Connection::open(legacy.join("library.sqlite")).unwrap();
        sql.execute_batch("CREATE TABLE recording(id INTEGER PRIMARY KEY,key TEXT,sourcePath TEXT,audioPath TEXT,startedAt TEXT,importedAt TEXT,status TEXT,lastError TEXT,currentTranscriptId INTEGER); CREATE TABLE transcript(id INTEGER PRIMARY KEY,recordingId INTEGER,backend TEXT,createdAt TEXT,text TEXT,language TEXT,diarize INTEGER,speakerCount INTEGER,optionsKnown INTEGER,digestTitle TEXT,digestSummary TEXT,digestTags TEXT,data TEXT,dataSchema TEXT,recipe TEXT); CREATE TABLE publication(id INTEGER PRIMARY KEY,recordingId INTEGER,connector TEXT,pageId TEXT,url TEXT,syncedAt TEXT,error TEXT);").unwrap();
        sql.execute("INSERT INTO recording VALUES (1,'2026-10-09/09-30-00','/synthetic/first.m4a','audio/first.m4a','2026-10-09 09:30:00','2026-10-09 09:31:00','done',NULL,NULL)",[]).unwrap();
        sql.execute("INSERT INTO recording VALUES (2,'voice-2','/synthetic/second.m4a','audio/second.m4a','2026-10-09 10:30:00','2026-10-09 10:31:00','pending',NULL,NULL)",[]).unwrap();
        drop(sql);
        let original = fs::read(legacy.join("library.sqlite")).unwrap();

        let mut store = Store::open(root.clone()).unwrap();
        let report = store.import_startup_legacy(&legacy).unwrap();
        assert_eq!(report.unwrap()["report"]["recordings"], 2);
        assert_eq!(store.snapshot()["recordings"].as_array().unwrap().len(), 2);
        assert_eq!(store.jobs().unwrap().len(), 0);
        assert_eq!(store.recording("voice-2").unwrap()["status"], "pending");
        assert_eq!(store.data["settings"]["autoProcess"], false);
        assert_eq!(store.data["settings"]["legacyImported"], true);
        assert_eq!(fs::read(legacy.join("library.sqlite")).unwrap(), original);
        assert!(!legacy.join("library.sqlite-shm").exists());
        let ids = store.snapshot()["recordings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|record| record["id"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        for id in ids {
            store.mutate("recording_delete", &json!({"id":id})).unwrap();
        }
        drop(store);
        let mut reopened = Store::open(root).unwrap();
        let report = reopened.import_startup_legacy(&legacy).unwrap();
        assert!(report.is_none());
        assert!(reopened.snapshot()["recordings"]
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(fs::read(legacy.join("library.sqlite")).unwrap(), original);
    }

    #[test]
    fn startup_import_error_is_visible_and_retries_after_source_is_repaired() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = dir.path().join("escriba/library");
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join("library.sqlite"), b"invalid sqlite fixture").unwrap();
        let root = dir.path().join("tauri");
        let mut store = Store::open(root.clone()).unwrap();
        let status = store.import_startup_legacy(&legacy).unwrap();
        assert_eq!(status.unwrap()["state"], "error");
        assert_eq!(
            store.snapshot()["settings"]["startupMigration"]["state"],
            "error"
        );
        assert_eq!(store.data["settings"]["autoProcess"], false);
        assert!(store.data["settings"]["legacyImported"].is_null());
        assert!(store.data["recordings"].as_array().unwrap().is_empty());
        drop(store);

        fs::remove_file(legacy.join("library.sqlite")).unwrap();
        let sql = rusqlite::Connection::open(legacy.join("library.sqlite")).unwrap();
        sql.execute_batch("CREATE TABLE recording(id INTEGER PRIMARY KEY,key TEXT,sourcePath TEXT,audioPath TEXT,startedAt TEXT,importedAt TEXT,status TEXT,lastError TEXT,currentTranscriptId INTEGER); CREATE TABLE transcript(id INTEGER PRIMARY KEY,recordingId INTEGER,backend TEXT,createdAt TEXT,text TEXT,language TEXT,diarize INTEGER,speakerCount INTEGER,optionsKnown INTEGER,digestTitle TEXT,digestSummary TEXT,digestTags TEXT,data TEXT,dataSchema TEXT,recipe TEXT); CREATE TABLE publication(id INTEGER PRIMARY KEY,recordingId INTEGER,connector TEXT,pageId TEXT,url TEXT,syncedAt TEXT,error TEXT);").unwrap();
        sql.execute("INSERT INTO recording VALUES (1,'recovered','/synthetic/source.m4a','','2026-10-09 09:30:00','2026-10-09 09:31:00','done',NULL,NULL)",[]).unwrap();
        drop(sql);
        let mut store = Store::open(root).unwrap();
        let status = store.import_startup_legacy(&legacy).unwrap();
        assert_eq!(status.unwrap()["report"]["recordings"], 1);
        assert_eq!(
            store.snapshot()["settings"]["startupMigration"]["state"],
            "imported"
        );
        assert_eq!(store.recording("recovered").unwrap()["status"], "done");
    }

    #[test]
    fn startup_discovery_preserves_an_existing_tauri_library_and_queue() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("tauri-note.wav");
        fs::write(&source, b"synthetic audio").unwrap();
        let legacy = dir.path().join("escriba/library");
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join("library.sqlite"), b"invalid sqlite fixture").unwrap();
        let mut store = Store::open(dir.path().join("tauri")).unwrap();
        let recording = store.import(&source, None).unwrap();
        store
            .job_save(&json!({"id":"existing-job","recordingId":recording["id"],"state":"queued"}))
            .unwrap();
        assert!(store.import_startup_legacy(&legacy).unwrap().is_none());
        assert_eq!(store.data["settings"]["autoProcess"], true);
        assert_eq!(store.jobs().unwrap()[0]["id"], "existing-job");
        assert_eq!(store.data["recordings"].as_array().unwrap().len(), 1);
        assert!(store.data["settings"]["startupMigration"].is_null());
    }

    #[test]
    fn startup_import_restores_voice_memos_watch_configuration_without_running_it() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let legacy = home.join("Library/Application Support/escriba/library");
        let preferences = home.join("Library/Preferences/dev.ruben.escriba.plist");
        let voice = home.join("VoiceMemos");
        fs::create_dir_all(&legacy).unwrap();
        fs::create_dir_all(preferences.parent().unwrap()).unwrap();
        fs::create_dir_all(&voice).unwrap();
        let new_audio = voice.join("new.m4a");
        fs::write(&new_audio, b"synthetic audio").unwrap();
        let sql = rusqlite::Connection::open(legacy.join("library.sqlite")).unwrap();
        sql.execute_batch("CREATE TABLE recording(id INTEGER PRIMARY KEY,key TEXT,sourcePath TEXT,audioPath TEXT,startedAt TEXT,importedAt TEXT,status TEXT,lastError TEXT,currentTranscriptId INTEGER); CREATE TABLE transcript(id INTEGER PRIMARY KEY,recordingId INTEGER,backend TEXT,createdAt TEXT,text TEXT,language TEXT,diarize INTEGER,speakerCount INTEGER,optionsKnown INTEGER,digestTitle TEXT,digestSummary TEXT,digestTags TEXT,data TEXT,dataSchema TEXT,recipe TEXT); CREATE TABLE publication(id INTEGER PRIMARY KEY,recordingId INTEGER,connector TEXT,pageId TEXT,url TEXT,syncedAt TEXT,error TEXT);").unwrap();
        sql.execute("INSERT INTO recording VALUES (1,'old','/synthetic/old.m4a','','2026-10-09 09:30:00','2026-10-09 09:31:00','done',NULL,NULL)",[]).unwrap();
        drop(sql);
        let mut settings = plist::Dictionary::new();
        let watched = json!([{"path":voice,"style":"voiceMemos"}]).to_string();
        settings.insert(
            "watchedFolders".into(),
            plist::Value::Data(watched.into_bytes()),
        );
        plist::to_file_binary(&preferences, &plist::Value::Dictionary(settings)).unwrap();
        let mut store = Store::open(home.join("tauri")).unwrap();
        store.import_startup_legacy(&legacy).unwrap();
        let adoption = store
            .adopt_legacy_watched_folders(&preferences)
            .unwrap()
            .unwrap();
        assert_eq!(adoption["state"], "adopted");
        assert_eq!(adoption["paused"], true);
        let watched = store.data["settings"]["watchedFolders"].as_array().unwrap();
        assert_eq!(watched.len(), 1);
        assert_eq!(watched[0]["style"], "voiceMemos");
        assert_eq!(watched[0]["path"], json!(voice));
        assert_eq!(store.data["settings"]["autoProcess"], false);
        let folder = crate::watcher::Folder {
            id: watched[0]["id"].as_str().unwrap().to_owned(),
            path: voice,
            enabled: watched[0]["enabled"] == true,
            style: crate::watcher::Style::parse(watched[0]["style"].as_str()).unwrap(),
        };
        let mut scanner = crate::watcher::Scanner::new();
        let now = SystemTime::now() + std::time::Duration::from_secs(16);
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        assert_eq!(scanner.scan(&[folder], now).ready.len(), 1);
        assert!(store
            .adopt_legacy_watched_folders(&preferences)
            .unwrap()
            .is_none());
        drop(store);
        let store = Store::open(home.join("tauri")).unwrap();
        assert_eq!(store.data["settings"]["legacyWatchAdopted"], true);
        assert_eq!(
            store.data["settings"]["watchedFolders"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(store.data["settings"]["autoProcess"], false);
    }

    #[test]
    fn watch_adoption_retries_invalid_preferences_and_preserves_tauri_choices() {
        let dir = tempfile::tempdir().unwrap();
        let preferences = dir.path().join("settings.plist");
        fs::write(&preferences, b"invalid plist").unwrap();
        let mut store = Store::open(dir.path().join("tauri")).unwrap();
        let mut next = store.data.clone();
        next["settings"]["legacyImported"] = json!(true);
        store.replace(next).unwrap();
        let error = store
            .adopt_legacy_watched_folders(&preferences)
            .unwrap()
            .unwrap();
        assert_eq!(error["state"], "error");
        assert_ne!(store.data["settings"]["legacyWatchAdopted"], true);
        let mut plist = plist::Dictionary::new();
        plist.insert(
            "watchedFolders".into(),
            plist::Value::Data(
                json!([{"path":dir.path().join("VoiceMemos"),"style":"voiceMemos"}])
                    .to_string()
                    .into_bytes(),
            ),
        );
        plist::to_file_binary(&preferences, &plist::Value::Dictionary(plist)).unwrap();
        assert_eq!(
            store
                .adopt_legacy_watched_folders(&preferences)
                .unwrap()
                .unwrap()["state"],
            "adopted"
        );
        assert_eq!(
            store.data["settings"]["watchedFolders"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let mut next = store.data.clone();
        next["settings"]["legacyWatchAdopted"] = json!(false);
        next["settings"]["watchedFolders"] =
            json!([{"id":"custom","path":"/my/chosen/folder","enabled":false,"style":"any"}]);
        store.replace(next).unwrap();
        fs::write(&preferences, b"invalid plist again").unwrap();
        assert_eq!(
            store
                .adopt_legacy_watched_folders(&preferences)
                .unwrap()
                .unwrap()["state"],
            "preserved"
        );
        assert_eq!(store.data["settings"]["watchedFolders"][0]["id"], "custom");
        assert_eq!(
            store.data["settings"]["watchedFolders"][0]["enabled"],
            false
        );
    }

    #[test]
    fn imported_voice_memo_is_not_duplicated_when_its_folder_is_watched() {
        use std::os::unix::fs::MetadataExt;
        let dir = tempfile::tempdir().unwrap();
        let legacy = dir.path().join("swift-library");
        let voice = dir.path().join("VoiceMemos");
        fs::create_dir_all(legacy.join("audio")).unwrap();
        fs::create_dir_all(&voice).unwrap();
        let source = voice.join("old.m4a");
        fs::write(&source, b"same audio").unwrap();
        let discarded_source = voice.join("discarded.m4a");
        fs::write(&discarded_source, b"discarded audio").unwrap();
        let new_source = voice.join("new.m4a");
        fs::write(&new_source, b"new audio").unwrap();
        fs::write(legacy.join("audio/old.m4a"), b"same audio").unwrap();
        let key = fs::metadata(&source).unwrap().ino().to_string();
        let discarded_key = fs::metadata(&discarded_source).unwrap().ino().to_string();
        let sql = rusqlite::Connection::open(legacy.join("library.sqlite")).unwrap();
        sql.execute_batch("CREATE TABLE recording(id INTEGER PRIMARY KEY,key TEXT,sourcePath TEXT,audioPath TEXT,startedAt TEXT,importedAt TEXT,status TEXT,lastError TEXT,currentTranscriptId INTEGER); CREATE TABLE transcript(id INTEGER PRIMARY KEY,recordingId INTEGER,backend TEXT,createdAt TEXT,text TEXT,language TEXT,diarize INTEGER,speakerCount INTEGER,optionsKnown INTEGER,digestTitle TEXT,digestSummary TEXT,digestTags TEXT,data TEXT,dataSchema TEXT,recipe TEXT); CREATE TABLE publication(id INTEGER PRIMARY KEY,recordingId INTEGER,connector TEXT,pageId TEXT,url TEXT,syncedAt TEXT,error TEXT);").unwrap();
        sql.execute("INSERT INTO recording VALUES (1,?1,?2,'audio/old.m4a','2026-10-09 09:30:00','2026-10-09 09:31:00','done',NULL,NULL)",[format!("Notas de Voz/{key}"),source.to_string_lossy().into_owned()]).unwrap();
        sql.execute("INSERT INTO recording VALUES (2,?1,?2,'','2026-10-09 09:30:00','2026-10-09 09:31:00','discarded',NULL,NULL)",[format!("Notas de Voz/{discarded_key}"),discarded_source.to_string_lossy().into_owned()]).unwrap();
        sql.execute_batch("CREATE TABLE segment(transcriptId INTEGER,position INTEGER,startTime REAL,endTime REAL,speaker TEXT,text TEXT,words TEXT); INSERT INTO transcript (id,recordingId,backend,createdAt,text,diarize,optionsKnown) VALUES (1,1,'synthetic','2026-10-09 09:31:00','Transcripción sintética',0,0); UPDATE recording SET currentTranscriptId=1 WHERE id=1; INSERT INTO publication VALUES (1,1,'synthetic','page','https://example.invalid/note','2026-10-09 09:32:00',NULL);").unwrap();
        drop(sql);
        let mut preferences = plist::Dictionary::new();
        preferences.insert(
            "watchedFolders".into(),
            plist::Value::Data(
                json!([{"path":voice,"style":"voiceMemos"}])
                    .to_string()
                    .into_bytes(),
            ),
        );
        let plist_path = dir.path().join("settings.plist");
        plist::to_file_binary(&plist_path, &plist::Value::Dictionary(preferences)).unwrap();
        let mut store = Store::open(dir.path().join("tauri")).unwrap();
        store
            .record_watch_import_error("Preferencias inválidas")
            .unwrap();
        store
            .import_legacy_with_settings(&legacy, Some(&plist_path))
            .unwrap();
        assert_eq!(store.data["settings"]["watchMigration"]["state"], "adopted");
        let imported = store.data["recordings"].as_array().unwrap();
        let done = imported
            .iter()
            .find(|record| record["status"] == "done")
            .unwrap()
            .clone();
        let discarded = imported
            .iter()
            .find(|record| record["status"] == "discarded")
            .unwrap()
            .clone();
        let old_audio = store.audio(done["id"].as_str().unwrap()).unwrap();
        let folder_id = store.data["settings"]["watchedFolders"][0]["id"]
            .as_str()
            .unwrap();
        let renamed = voice.join("renamed.m4a");
        fs::rename(&source, &renamed).unwrap();
        let folder = crate::watcher::Folder {
            id: folder_id.to_owned(),
            path: voice,
            enabled: true,
            style: crate::watcher::Style::VoiceMemos,
        };
        let mut scanner = crate::watcher::Scanner::new();
        let now = SystemTime::now() + std::time::Duration::from_secs(16);
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        let candidates = scanner.scan(&[folder], now).ready;
        assert_eq!(candidates.len(), 3);
        for candidate in candidates {
            store
                .import_with_metadata(
                    &candidate.path,
                    None,
                    &candidate.title,
                    candidate.started_at,
                    &candidate.source_key,
                )
                .unwrap();
        }
        let recordings = store.data["recordings"].as_array().unwrap();
        assert_eq!(recordings.len(), 3);
        let same_done = recordings
            .iter()
            .find(|record| record["id"] == done["id"])
            .unwrap();
        assert_eq!(same_done["status"], "done");
        assert_eq!(same_done["createdAt"], done["createdAt"]);
        assert_eq!(same_done["audioPath"], done["audioPath"]);
        assert_eq!(same_done["versions"], done["versions"]);
        assert_eq!(same_done["publications"], done["publications"]);
        assert_eq!(same_done["versions"].as_array().unwrap().len(), 1);
        assert_eq!(same_done["publications"].as_array().unwrap().len(), 1);
        assert_eq!(same_done["source"], json!(renamed));
        assert!(old_audio.exists());
        let same_discarded = recordings
            .iter()
            .find(|record| record["id"] == discarded["id"])
            .unwrap();
        assert_eq!(same_discarded["status"], "discarded");
        assert!(same_discarded["audioPath"].is_null());
        assert_eq!(
            recordings
                .iter()
                .filter(|record| record["status"] == "pending")
                .count(),
            1
        );
        assert_eq!(store.data["settings"]["autoProcess"], false);
        assert!(store.jobs().unwrap().is_empty());
        let new_id = recordings
            .iter()
            .find(|record| record["status"] == "pending")
            .unwrap()["id"]
            .clone();
        let shared = std::sync::Arc::new(std::sync::Mutex::new(store));
        let queue = crate::jobs::Queue::new(shared.clone()).unwrap();
        queue.automatic().unwrap();
        assert!(queue.jobs().unwrap().is_empty());
        shared
            .lock()
            .unwrap()
            .mutate("settings_save", &json!({"settings":{"autoProcess":true}}))
            .unwrap();
        queue.automatic().unwrap();
        assert_eq!(queue.jobs().unwrap().len(), 1);
        assert_eq!(queue.claim().unwrap().unwrap()["recordingId"], new_id);
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
    fn imports_selected_swift_library_and_settings_without_touching_source_or_tokens() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift-library");
        fs::create_dir_all(source.join("audio")).unwrap();
        fs::write(source.join("audio/legacy.wav"), b"synthetic-only").unwrap();
        let sql = rusqlite::Connection::open(source.join("library.sqlite")).unwrap();
        sql.execute_batch("CREATE TABLE recording(id INTEGER PRIMARY KEY,key TEXT,sourcePath TEXT,audioPath TEXT,startedAt TEXT,importedAt TEXT,status TEXT,lastError TEXT,currentTranscriptId INTEGER); CREATE TABLE transcript(id INTEGER PRIMARY KEY,recordingId INTEGER,backend TEXT,createdAt TEXT,text TEXT,language TEXT,diarize INTEGER,speakerCount INTEGER,optionsKnown INTEGER,digestTitle TEXT,digestSummary TEXT,digestTags TEXT,data TEXT,dataSchema TEXT,recipe TEXT); CREATE TABLE segment(transcriptId INTEGER,position INTEGER,startTime REAL,endTime REAL,speaker TEXT,text TEXT,words TEXT); CREATE TABLE publication(id INTEGER PRIMARY KEY,recordingId INTEGER,connector TEXT,pageId TEXT,url TEXT,syncedAt TEXT,error TEXT); CREATE TABLE answer(transcriptId INTEGER,fingerprint TEXT,payload TEXT,savedAt TEXT); CREATE TABLE recipeRun(id INTEGER PRIMARY KEY,recordingId INTEGER,recipeKey TEXT,trigger TEXT,startedAt TEXT,payload TEXT);").unwrap();
        sql.execute("INSERT INTO recording VALUES (1,'legacy','/synthetic/original.wav','audio/legacy.wav','2026-10-01 12:00:00','2026-10-01 12:01:00','done',NULL,7)",[]).unwrap();
        sql.execute("INSERT INTO transcript VALUES (7,1,'whisper','2026-10-01 12:02:00','hola','es',0,NULL,1,'Título','Resumen','[\"tag\"]','{\"x\":1}','{\"type\":\"object\"}','formulario')",[]).unwrap();
        sql.execute("INSERT INTO segment VALUES (7,0,0,2,'A','hola','[]')", [])
            .unwrap();
        sql.execute("INSERT INTO publication VALUES (1,1,'destino','page-1','https://example.invalid/page','2026-10-01 12:03:00',NULL)",[]).unwrap();
        sql.execute("INSERT INTO answer VALUES (7,'fingerprint-1','{\"answer\":\"cached\"}','2026-10-01 12:04:00')",[]).unwrap();
        sql.execute("INSERT INTO recipeRun VALUES (4,1,'formulario','pipeline','2026-10-01 12:05:00','{\"steps\":[],\"error\":null,\"outcome\":\"ok\"}')",[]).unwrap();
        drop(sql);
        let original = fs::read(source.join("library.sqlite")).unwrap();
        let mut preferences = plist::Dictionary::new();
        preferences.insert("language".into(), plist::Value::String("gl".into()));
        preferences.insert(
            "watchedFolders".into(),
            plist::Value::Data(br#"[{"path":"/synthetic/watch","style":"any"}]"#.to_vec()),
        );
        preferences.insert(
            "recipeBook".into(),
            plist::Value::Data(
                br#"{"forms":[{"key":"form-1","name":"Formulario","base":"mi-receta"}],"defaultKey":"mi-receta","values":{"form-1":"{\"x\":\"form\"}","mi-receta":"{\"topic\":\"code\",\"apiKey\":\"fake-code-secret\"}","orphan":"{\"v\":1}"}}"#.to_vec(),
            ),
        );
        preferences.insert(
            "connectorAccounts".into(),
            plist::Value::Data(
                br#"[{"id":"account-1","name":"Cuenta","provider":"notion","enabled":true}]"#
                    .to_vec(),
            ),
        );
        preferences.insert(
            "connectors".into(),
            plist::Value::Data(
                br#"[{"id":"destination-1","name":"Destino","provider":"notion","accountID":"account-1","configurationJSON":"{\"databaseId\":\"db-1\",\"nested\":{\"apiKey\":\"fake-import-secret\"}}"}]"#.to_vec(),
            ),
        );
        let plist_path = dir.path().join("preferences.plist");
        plist::to_file_binary(&plist_path, &plist::Value::Dictionary(preferences)).unwrap();
        let root = dir.path().join("tauri-library");
        let mut store = Store::open(root.clone()).unwrap();
        let report = store
            .import_legacy_with_settings(&source, Some(&plist_path))
            .unwrap();
        assert_eq!(report["recordings"], 1);
        assert_eq!(report["credentialsImported"], 0);
        assert_eq!(report["answers"], 1);
        assert_eq!(report["runs"], 1);
        assert_eq!(
            store.recording("legacy").unwrap()["versions"][0]["digest"]["title"],
            "Título"
        );
        assert_eq!(
            store.recording("legacy").unwrap()["versions"][0]["dataSchema"]["type"],
            "object"
        );
        assert_eq!(
            store.recording("legacy").unwrap()["publications"][0]["receipt"]["locator"],
            "page-1"
        );
        assert_eq!(store.data["settings"]["language"], "gl");
        assert_eq!(store.data["settings"]["defaultRecipeId"], "mi-receta");
        assert_eq!(
            store.data["recipes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["id"] == "form-1")
                .unwrap()["base"],
            "mi-receta"
        );
        let imported_code = store.data["recipes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == "mi-receta")
            .unwrap();
        assert_eq!(imported_code["kind"], "code");
        assert_eq!(imported_code["values"]["topic"], "code");
        assert!(imported_code["values"].get("apiKey").is_none());
        assert!(imported_code["bundle"].is_null());
        assert!(imported_code["error"]
            .as_str()
            .unwrap()
            .contains("Compilar"));
        assert_eq!(
            store.data["recipes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["id"] == "orphan")
                .unwrap()["values"]["v"],
            1
        );
        assert_eq!(store.data["settings"]["watchedFolders"][0]["style"], "any");
        assert_eq!(store.data["accounts"][0]["enabled"], false);
        assert_eq!(
            store.data["destinations"][0]["configuration"]["databaseId"],
            "db-1"
        );
        assert!(!store.snapshot().to_string().contains("fake-import-secret"));
        assert_eq!(store.trace_list(Some("legacy")).unwrap().len(), 1);
        assert_eq!(
            store
                .memory_recall("legacy", "swift:1:7", "fingerprint-1")
                .unwrap()
                .unwrap()["value"]["answer"],
            "cached"
        );
        assert!(!root.join("secrets/account-1.token").exists());
        assert_eq!(fs::read(source.join("library.sqlite")).unwrap(), original);
        assert!(!source.join("library.sqlite-shm").exists());
        assert!(!source.join("library.sqlite-wal").exists());
        assert!(!fs::read_dir(&root).unwrap().flatten().any(|entry| entry
            .file_name()
            .to_string_lossy()
            .starts_with(".swift-import-")));
        assert_eq!(
            fs::read(source.join("audio/legacy.wav")).unwrap(),
            b"synthetic-only"
        );
        drop(store);
        let restored = Store::open(root).unwrap();
        assert_eq!(
            restored.recording("legacy").unwrap()["versions"][0]["transcript"]["text"],
            "hola"
        );
    }
    #[test]
    fn imports_swift_jpr_and_voice_memo_keys_with_related_history() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift-library");
        fs::create_dir_all(source.join("audio")).unwrap();
        fs::write(source.join("audio/jpr.m4a"), b"jpr audio").unwrap();
        fs::write(source.join("audio/voice.m4a"), b"voice audio").unwrap();
        let sql = rusqlite::Connection::open(source.join("library.sqlite")).unwrap();
        sql.execute_batch("CREATE TABLE recording(id INTEGER PRIMARY KEY,key TEXT,sourcePath TEXT,audioPath TEXT,startedAt TEXT,importedAt TEXT,status TEXT,lastError TEXT,currentTranscriptId INTEGER); CREATE TABLE transcript(id INTEGER PRIMARY KEY,recordingId INTEGER,backend TEXT,createdAt TEXT,text TEXT,language TEXT,diarize INTEGER,speakerCount INTEGER,optionsKnown INTEGER,digestTitle TEXT,digestSummary TEXT,digestTags TEXT,data TEXT,dataSchema TEXT,recipe TEXT); CREATE TABLE segment(transcriptId INTEGER,position INTEGER,startTime REAL,endTime REAL,speaker TEXT,text TEXT,words TEXT); CREATE TABLE publication(id INTEGER PRIMARY KEY,recordingId INTEGER,connector TEXT,pageId TEXT,url TEXT,syncedAt TEXT,error TEXT); CREATE TABLE answer(transcriptId INTEGER,fingerprint TEXT,payload TEXT,savedAt TEXT); CREATE TABLE recipeRun(id INTEGER PRIMARY KEY,recordingId INTEGER,recipeKey TEXT,trigger TEXT,startedAt TEXT,payload TEXT);").unwrap();
        sql.execute("INSERT INTO recording VALUES (1,'2026-10-09/09-30-00','/synthetic/jpr.m4a','audio/jpr.m4a','2026-10-09 09:30:00','2026-10-09 09:31:00','done',NULL,7)",[]).unwrap();
        sql.execute("INSERT INTO recording VALUES (2,'123456789','/synthetic/voice.m4a','audio/voice.m4a','2026-10-09 10:30:00','2026-10-09 10:31:00','done',NULL,NULL)",[]).unwrap();
        sql.execute("INSERT INTO transcript VALUES (7,1,'whisper','2026-10-09 09:32:00','hola','es',0,NULL,1,NULL,NULL,NULL,NULL,NULL,NULL)",[]).unwrap();
        sql.execute("INSERT INTO publication VALUES (1,1,'notion','page-1',NULL,'2026-10-09 09:33:00',NULL)",[]).unwrap();
        sql.execute("INSERT INTO answer VALUES (7,'fingerprint','{\"answer\":\"cached\"}','2026-10-09 09:34:00')",[]).unwrap();
        sql.execute("INSERT INTO recipeRun VALUES (4,1,'default','pipeline','2026-10-09 09:35:00','{\"steps\":[],\"error\":null}')",[]).unwrap();
        drop(sql);
        let root = dir.path().join("tauri-library");
        let mut store = Store::open(root.clone()).unwrap();
        let first = store.import_legacy(&source).unwrap();
        assert_eq!(first["recordings"], 2);
        let jpr = store.data["recordings"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["legacyKey"] == "2026-10-09/09-30-00")
            .unwrap();
        let jpr_id = jpr["id"].as_str().unwrap().to_owned();
        assert_ne!(jpr_id, "2026-10-09/09-30-00");
        safe_id(&jpr_id).unwrap();
        assert_eq!(jpr["sourceKey"], "swift:2026-10-09/09-30-00");
        assert_eq!(jpr["versions"][0]["id"], "swift:1:7");
        assert_eq!(jpr["publications"][0]["receipt"]["locator"], "page-1");
        assert_eq!(
            store
                .memory_recall(&jpr_id, "swift:1:7", "fingerprint")
                .unwrap()
                .unwrap()["value"]["answer"],
            "cached"
        );
        assert_eq!(store.trace_list(Some(&jpr_id)).unwrap().len(), 1);
        assert_eq!(
            store.data["recordings"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["legacyKey"] == "123456789")
                .unwrap()["id"],
            "123456789"
        );
        assert_eq!(
            fs::read(store.audio(&jpr_id).unwrap()).unwrap(),
            b"jpr audio"
        );
        assert_eq!(store.import_legacy(&source).unwrap()["recordings"], 0);
        drop(store);
        let restored = Store::open(root).unwrap();
        assert_eq!(
            restored.recording(&jpr_id).unwrap()["legacyKey"],
            "2026-10-09/09-30-00"
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
    fn jobs_survive_restart_independently_of_snapshot_changes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let mut store = Store::open(root.clone()).unwrap();
        let job = json!({"id":"job-1","recordingId":"recording-1","state":"queued","stage":"Transcribiendo","attempt":2});
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
    fn rejects_second_instance_without_replacing_data() {
        let dir = tempfile::tempdir().unwrap();
        let _first = Store::open(dir.path().into()).unwrap();
        assert!(Store::open(dir.path().into()).is_err());
    }
}
