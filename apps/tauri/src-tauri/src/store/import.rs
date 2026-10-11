use super::*;

impl Store {
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
    pub(super) fn import_internal(
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
            if let Some(existing) = self.data.recordings.iter().find(|record| {
                record.audio_hash.as_ref() == Some(&content_hash)
                    && record.status != RecordingStatus::Failed
            }) {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                return existing.write();
            }
        }
        let prior = metadata_from_watcher.and_then(|(_, _, source_key)| {
            self.data
                .recordings
                .iter()
                .find(|record| {
                    record
                        .source_key
                        .as_ref()
                        .is_some_and(|key| key == source_key)
                })
                .or_else(|| {
                    let inode = source_key.strip_prefix("voiceMemos:")?.rsplit('/').next()?;
                    self.data.recordings.iter().find(|record| {
                        let same_folder = record
                            .source
                            .as_ref()
                            .and_then(|path| Path::new(path).parent())
                            == source.parent();
                        let legacy_inode = record.legacy_key.as_ref().is_some_and(|key| {
                            key == inode || key == &format!("Notas de Voz/{inode}")
                        });
                        record
                            .source_key
                            .as_ref()
                            .is_some_and(|key| key.starts_with("swift:"))
                            && same_folder
                            && legacy_inode
                    })
                })
                .or_else(|| {
                    self.data.recordings.iter().find(|record| {
                        record
                            .source_key
                            .as_ref()
                            .is_some_and(|key| key.starts_with("swift:"))
                            && record.legacy_key.as_ref().is_some()
                            && record
                                .source
                                .as_ref()
                                .is_some_and(|path| path == source_text.as_ref())
                    })
                })
                .or_else(|| {
                    self.data.recordings.iter().find(|record| {
                        record.status == RecordingStatus::Discarded
                            && record
                                .source
                                .as_ref()
                                .is_some_and(|path| path == source_text.as_ref())
                    })
                })
                .cloned()
        });
        if let Some(discarded) = prior
            .as_ref()
            .filter(|record| record.status == RecordingStatus::Discarded)
        {
            fs::remove_file(&temp).map_err(|e| e.to_string())?;
            return discarded.write();
        }
        let abandoned = self
            .data
            .recordings
            .iter()
            .find(|record| {
                record
                    .source
                    .as_ref()
                    .is_some_and(|path| path == source_text.as_ref())
                    && record.status == RecordingStatus::Failed
                    && record.audio_path.as_ref().is_none()
                    && record.id.starts_with("empty-")
            })
            .cloned();
        let key = if let Some(record) = prior.as_ref().or(abandoned.as_ref()) {
            record.id.clone()
        } else if let Some((_, _, source_key)) = metadata_from_watcher {
            format!("watch-{:x}", Sha256::digest(source_key.as_bytes()))
        } else {
            content_hash.clone()
        };
        if let Some(prior) = &prior {
            let changed = if let Some(previous) = prior.audio_hash.as_ref() {
                previous != &content_hash
            } else {
                match self.audio(&key) {
                    Ok(path) => file_hash(&path)?.as_slice() != content_digest.as_slice(),
                    Err(_) => true,
                }
            };
            if let Some((title, started_at, source_key)) = metadata_from_watcher
                .filter(|_| !changed || prior.status == RecordingStatus::Discarded)
            {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                let mut next = self.data.edit();
                let existing = record_mut(&mut next, &key)?;
                existing.source = source_text.to_string().into();
                existing.source_key = source_key.to_owned().into();
                if !changed {
                    existing.audio_hash = content_hash.clone().into();
                }
                if prior.legacy_key.as_ref().is_none() {
                    existing.title = title.to_owned().into();
                    existing.created_at = chrono::DateTime::<Utc>::from(started_at)
                        .to_rfc3339()
                        .into();
                }
                let record = existing.write()?;
                self.commit(next)?;
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
            if let Some(existing) = self.data.recordings.iter().find(|record| record.id == key) {
                fs::remove_file(&temp).map_err(|e| e.to_string())?;
                return existing.write();
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
        let mut next = self.data.edit();
        let records = &mut next.recordings;
        let old_audio = prior
            .as_ref()
            .and_then(|record| record.audio_path.as_ref())
            .map(PathBuf::from);
        let record = if let Some(existing) = records.iter_mut().find(|record| record.id == key) {
            let recording = existing;
            let target_path = target.to_string_lossy().into_owned();
            let changed_audio = recording.audio_path.as_ref() != Some(&target_path);
            recording.audio_path = target_path.into();
            recording.audio_hash = content_hash.clone().into();
            recording.source = source_text.to_string().into();
            if changed_audio || recording.status == RecordingStatus::Failed {
                recording.status = RecordingStatus::Pending;
                recording.error = model::Field::Present(None);
            }
            if let Some(recipe) = recipe_id {
                recording.recipe_id = recipe.to_owned().into();
            }
            if let Some((title, started_at, source_key)) = metadata_from_watcher {
                recording.title = title.to_owned().into();
                recording.created_at = chrono::DateTime::<Utc>::from(started_at)
                    .to_rfc3339()
                    .into();
                recording.source_key = source_key.to_owned().into();
            }
            recording.write()?
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
            let record = Recording {
                id: key,
                title: title.into(),
                created_at: started_at.into(),
                source_key: model::Field::Present(source_key.map(str::to_owned)),
                source: source_text.to_string().into(),
                audio_path: target.to_string_lossy().into_owned().into(),
                audio_hash: content_hash.into(),
                duration: serde_json::Number::from(0).into(),
                status: RecordingStatus::Pending,
                recipe_id: model::Field::Present(recipe_id.map(str::to_owned)),
                versions: Vec::new().into(),
                publications: Vec::new().into(),
                ..Recording::default()
            }
            .write()?;
            records.insert(0, Recording::read(&record)?);
            record
        };
        if let Err(error) = self.commit(next) {
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
}

pub(super) fn file_hash(path: &Path) -> Result<Vec<u8>, String> {
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
