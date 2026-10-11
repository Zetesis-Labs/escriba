use super::*;

impl Store {
    pub fn recording(&self, record_id: &str) -> Result<Value, String> {
        self.database
            .recording(record_id)?
            .ok_or_else(|| "Grabación no encontrada".into())
    }
    pub(super) fn recording_for_write(&self, record_id: &str) -> Result<&Recording, String> {
        let record = self
            .data
            .recordings
            .iter()
            .find(|record| record.id == record_id)
            .ok_or("Grabación no encontrada")?;
        if record.status == RecordingStatus::Discarded {
            return Err("La grabación está descartada".into());
        }
        Ok(record)
    }
    pub fn item(&self, collection: &str, item_id: &str) -> Result<Value, String> {
        self.data
            .catalog(collection)?
            .as_array()
            .and_then(|items| items.iter().find(|item| item["id"] == item_id))
            .cloned()
            .ok_or_else(|| format!("No existe {item_id} en {collection}"))
    }
    pub fn audio(&self, record_id: &str) -> Result<PathBuf, String> {
        let record = self
            .data
            .recordings
            .iter()
            .find(|record| record.id == record_id)
            .ok_or("Grabación no encontrada")?;
        let path = PathBuf::from(
            record
                .audio_path
                .as_ref()
                .filter(|path| !path.is_empty())
                .ok_or("Falta audioPath")?,
        );
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
}

impl Recording {
    pub(super) fn read(value: &Value) -> Result<Self, String> {
        serde_json::from_value(value.clone()).map_err(|_| "Grabación inválida".into())
    }

    pub(super) fn write(&self) -> Result<Value, String> {
        serde_json::to_value(self).map_err(|_| "No se pudo codificar la grabación".into())
    }

    pub(super) fn versions_mut(&mut self) -> Result<&mut Vec<Version>, String> {
        self.versions
            .as_mut()
            .ok_or_else(|| "Versiones inválidas".into())
    }

    pub(super) fn update(&mut self, params: &Value) -> Result<(), String> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Update {
            #[serde(default)]
            title: model::Field<String>,
            #[serde(default)]
            status: model::Field<RecordingStatus>,
            #[serde(default)]
            error: model::Field<String>,
            #[serde(default)]
            duration: model::Field<serde_json::Number>,
            #[serde(default)]
            recipe_id: model::Field<String>,
            #[serde(default)]
            created_at: model::Field<String>,
        }
        let update: Update = serde_json::from_value(params.clone())
            .map_err(|_| "Actualización de grabación inválida")?;
        if !update.title.is_missing() {
            self.title = update.title;
        }
        if !update.error.is_missing() {
            self.error = update.error;
        }
        if !update.duration.is_missing() {
            self.duration = update.duration;
        }
        if !update.recipe_id.is_missing() {
            self.recipe_id = update.recipe_id;
        }
        if !update.created_at.is_missing() {
            self.created_at = update.created_at;
        }
        if !update.status.is_missing() {
            self.status = *update.status.as_ref().ok_or("Estado no válido")?;
        }
        Ok(())
    }

    pub(super) fn select_version(&mut self, id: &str) -> Result<(), String> {
        if !self.versions_mut()?.iter().any(|version| version.id == id) {
            return Err("Versión no encontrada".into());
        }
        self.current_version_id = id.to_owned().into();
        Ok(())
    }
}

impl Store {
    pub(super) fn mutate_recording(
        &self,
        next: &mut LibraryData,
        method: &str,
        p: &Value,
        delete_after_commit: &mut Option<PathBuf>,
        audio_to_delete: &mut Vec<AudioDeletion>,
    ) -> Result<Value, String> {
        Ok(match method {
            "recording_update" => {
                let target = record_mut(next, text(p, "id")?)?;
                let record = target;
                record.update(p)?;
                record.write()?
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
                let records = &mut next.recordings;
                if let Some(record) = records.iter().find(|r| r.id == key) {
                    record.write()?
                } else {
                    let record = json!({"id":key,"title":p["title"].as_str().unwrap_or_else(||Path::new(path).file_stem().and_then(|s|s.to_str()).unwrap_or("Grabación vacía")),"createdAt":created_at,"source":path,"sourceKey":source_key,"audioPath":null,"duration":0,"status":"failed","error":"La grabación permanece vacía tras una hora; vuelve a intentarlo cuando contenga audio.","recipeId":null,"versions":[],"publications":[]});
                    records.insert(0, Recording::read(&record)?);
                    record
                }
            }
            "recording_discard" => {
                let key = text(p, "id")?;
                let prior = record_mut(next, key)?.write()?;
                let r = record_mut(next, key)?;
                *r = Recording::read(&discarded_record(&r.write()?)?)?;
                let result = r.write()?;
                if let Some(path) = prior["audioPath"].as_str().filter(|path| !path.is_empty()) {
                    if let Some(copy) = audio_copy_to_delete(&self.root, next, Path::new(path))? {
                        audio_to_delete.push(copy);
                    }
                }
                result
            }
            "recording_remove_audio" => {
                let key = text(p, "id")?;
                let path = self.audio(key)?;
                *delete_after_commit = Some(path);
                let r = record_mut(next, key)?;
                r.audio_path = Field::Present(None);
                Value::Null
            }
            #[cfg(test)]
            "recording_delete" => {
                let key = text(p, "id")?;
                let record = self.recording(key)?;
                if let Some(path) = record["audioPath"].as_str() {
                    if Path::new(path).try_exists().map_err(|e| e.to_string())? {
                        *delete_after_commit = Some(self.audio(key)?);
                    }
                }
                next.recordings.retain(|record| record.id != key);
                Value::Null
            }
            _ => return Err(format!("Operación desconocida: {method}")),
        })
    }
}

pub(super) fn audio_copy_root(root: &Path) -> Result<PathBuf, String> {
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

pub(super) fn references_audio(data: &LibraryData, copy: &Path) -> Result<bool, String> {
    for record in &data.recordings {
        let paths = [
            record.source.as_ref(),
            (record.status != RecordingStatus::Discarded)
                .then(|| record.audio_path.as_ref())
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

pub(super) fn audio_copy_to_delete(
    root: &Path,
    data: &LibraryData,
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
