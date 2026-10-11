use super::*;

impl Store {
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
        let mut next = self.data.edit();
        let folders = next
            .settings
            .watched_folders
            .as_mut()
            .ok_or("Carpetas inválidas")?;
        let found = if let Some(folder_id) = folder_id {
            Some(
                folders
                    .iter()
                    .position(|folder| folder.id == folder_id)
                    .ok_or("La carpeta vigilada ya no existe")?,
            )
        } else {
            folders
                .iter()
                .position(|folder| same_folder(Path::new(&folder.path), &canonical))
        };
        let saved = if let Some(index) = found {
            let relocation = {
                let existing = Path::new(&folders[index].path);
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
                    other_index != index && same_folder(Path::new(&folder.path), &canonical)
                })
            {
                return Err("La nueva ubicación ya pertenece a otra carpeta vigilada".into());
            }
            let folder = &mut folders[index];
            if relocation {
                folder.path = canonical.to_string_lossy().into_owned();
            }
            folder.access_bookmark = json!(bookmark).into();
            folder.extra.remove("authorizationSaved");
            json!(folder)
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
            folders.push(serde_json::from_value(folder.clone()).map_err(|_| "Carpeta inválida")?);
            folder
        };
        self.commit(next)?;
        Ok(redacted_folder(&saved))
    }

    pub fn seed_voice_memos(&mut self, path: &Path) -> Result<bool, String> {
        let settings = &self.data.settings;
        if settings.voice_memos_seeded.as_ref() == Some(&true) {
            return Ok(false);
        }
        let adopted = settings.legacy_watch_adopted.as_ref() == Some(&true);
        let present = settings
            .watched_folders
            .as_ref()
            .ok_or("Carpetas inválidas")?
            .iter()
            .any(|folder| {
                folder
                    .style
                    .as_ref()
                    .is_some_and(|style| style == "voiceMemos")
                    || same_folder(Path::new(&folder.path), path)
            });
        let seeds = !adopted && !present;
        let mut next = self.data.edit();
        if seeds {
            next.settings.watched_folders.as_mut()
                .ok_or("Carpetas inválidas")?
                .push(serde_json::from_value(json!({"id":id(),"path":path,"name":"Notas de Voz","style":"voiceMemos","enabled":true})).map_err(|_| "Carpeta inválida")?);
        }
        next.settings.voice_memos_seeded = true.into();
        self.commit(next)?;
        Ok(seeds)
    }

    pub fn watched_folder_bookmarks(&self) -> Result<Vec<(String, PathBuf, Vec<u8>)>, String> {
        let folders = self
            .data
            .settings
            .watched_folders
            .as_ref()
            .ok_or("Carpetas inválidas")?;
        folders
            .iter()
            .filter(|folder| {
                folder.enabled.as_ref() != Some(&false)
                    && folder
                        .access_bookmark
                        .as_ref()
                        .is_some_and(|value| !value.is_null())
            })
            .map(|folder| {
                Ok((
                    folder.id.clone(),
                    PathBuf::from(&folder.path),
                    bookmark_bytes(
                        folder
                            .access_bookmark
                            .as_ref()
                            .ok_or("Falta autorización guardada")?,
                    )?,
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
        let mut next = self.data.edit();
        let folders = next
            .settings
            .watched_folders
            .as_mut()
            .ok_or("Carpetas inválidas")?;
        let Some(folder) = folders.iter_mut().find(|folder| folder.id == folder_id) else {
            return Ok(false);
        };
        if folder.access_bookmark.as_ref().is_none_or(Value::is_null)
            || bookmark_bytes(
                folder
                    .access_bookmark
                    .as_ref()
                    .ok_or("Falta autorización guardada")?,
            )? != previous
        {
            return Ok(false);
        }
        folder.path = canonical_folder(resolved_path)?
            .to_string_lossy()
            .into_owned();
        if let Some(replacement) = replacement {
            folder.access_bookmark = json!(replacement).into();
        }
        self.commit(next)?;
        Ok(true)
    }
}

impl Settings {
    pub(super) fn read(value: &Value) -> Result<Self, String> {
        serde_json::from_value(value.clone()).map_err(|_| "Ajustes inválidos".into())
    }

    pub(super) fn update(&mut self, params: &Value) -> Result<(), String> {
        let incoming = params.as_object().ok_or("Ajustes inválidos")?;
        let mut accepted = serde_json::Map::new();
        for key in SETTABLE {
            if let Some(value) = incoming.get(key) {
                accepted.insert(key.to_owned(), value.clone());
            }
        }
        let update = Self::read(&Value::Object(accepted))?;
        if !update.default_recipe_id.is_missing() {
            self.default_recipe_id = update.default_recipe_id;
        }
        if !update.project_path.is_missing() {
            self.project_path = update.project_path;
        }
        if !update.whisper_model.is_missing() {
            self.whisper_model = update.whisper_model;
        }
        if !update.launch_at_login.is_missing() {
            self.launch_at_login = update.launch_at_login;
        }
        if !update.notify_every_note.is_missing() {
            self.notify_every_note = update.notify_every_note;
        }
        if !update.watched_folders.is_missing() {
            let sanitized = sanitize_watched_folders(
                &json!(update.watched_folders),
                &json!(self.watched_folders),
            )?;
            self.watched_folders =
                serde_json::from_value(sanitized).map_err(|_| "Carpetas inválidas")?;
        }
        Ok(())
    }
}

pub(super) fn canonical_folder(path: &Path) -> Result<PathBuf, String> {
    let path = path
        .canonicalize()
        .map_err(|error| format!("No se puede acceder a la carpeta: {error}"))?;
    if !path.is_dir() {
        return Err("La ruta elegida no es una carpeta".into());
    }
    Ok(path)
}
pub(super) fn same_folder(left: &Path, right: &Path) -> bool {
    left == right
        || left
            .canonicalize()
            .ok()
            .zip(right.canonicalize().ok())
            .is_some_and(|(left, right)| left == right)
}
pub(super) fn bookmark_bytes(value: &Value) -> Result<Vec<u8>, String> {
    let bytes = serde_json::from_value::<Vec<u8>>(value.clone())
        .map_err(|_| "La autorización guardada está dañada")?;
    if bytes.is_empty() {
        return Err("La autorización guardada está vacía".into());
    }
    Ok(bytes)
}
pub(super) fn redacted_folder(folder: &Value) -> Value {
    let mut redacted = folder.clone();
    let authorized = bookmark_bytes(&redacted["accessBookmark"]).is_ok();
    if let Some(object) = redacted.as_object_mut() {
        object.remove("accessBookmark");
        object.insert("authorizationSaved".into(), json!(authorized));
    }
    redacted
}
pub(super) fn redacted_settings(settings: &Value) -> Value {
    let mut redacted = settings.clone();
    if let Some(folders) = redacted["watchedFolders"].as_array_mut() {
        for folder in folders {
            *folder = redacted_folder(folder);
        }
    }
    redacted
}
pub(super) fn sanitize_watched_folders(
    incoming: &Value,
    existing: &Value,
) -> Result<Value, String> {
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

pub(super) const SETTABLE: [&str; 6] = [
    "defaultRecipeId",
    "projectPath",
    "watchedFolders",
    "whisperModel",
    "launchAtLogin",
    "notifyEveryNote",
];

pub(super) fn defaults() -> Value {
    json!({"schemaVersion":1,"recordings":[],"accounts":[],"destinations":[],"logs":[],"resolvers":[{"id":"local-stt","name":"Whisper · en este Mac","role":"stt","local":true,"enabled":true,"model":"openai_whisper-large-v3-v20240930"},{"id":"local-llm","name":"Apple Intelligence","role":"llm","local":true,"enabled":true}],"recipes":[{"id":"default","name":"Por defecto","kind":"form","values":{}}],"settings":{"defaultRecipeId":"default","projectPath":null,"watchedFolders":[],"language":"es","whisperModel":"openai_whisper-large-v3-v20240930","launchAtLogin":false}})
}
