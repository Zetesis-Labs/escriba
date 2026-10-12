use super::*;

impl Store {
    pub async fn mutate(&mut self, method: &str, p: &Value) -> Result<Value, String> {
        if method.starts_with("note_draft_") {
            return self.draft_command(method, p).await;
        }
        if method == "log" {
            self.append_log(p).await?;
            return Ok(Value::Null);
        }
        let guarded = match method {
            "recording_update" | "recording_remove_audio" => Some(text(p, "id")?),
            "version_save"
            | "version_select"
            | "version_update"
            | "publication_save"
            | "publication_remove"
            | "account_effect_begin"
            | "account_effect_finish" => Some(text(p, "recordingId")?),
            _ => None,
        };
        if let Some(recording_id) = guarded {
            self.recording_for_write(recording_id)?;
        }
        let full_recording = match method {
            "version_save"
            | "version_select"
            | "version_update"
            | "publication_save"
            | "publication_remove"
            | "account_effect_begin"
            | "account_effect_finish" => Some(text(p, "recordingId")?),
            _ => None,
        };
        let before = match full_recording {
            Some(id) => self.recording_edit(id).await?,
            None => self.data.edit(),
        };
        let mut next = before.clone();
        let scope = WriteScope {
            full_recordings: full_recording.map(str::to_owned).into_iter().collect(),
            ..WriteScope::default()
        };
        let mut delete_after_commit: Option<PathBuf> = None;
        let mut audio_to_delete = Vec::new();
        let mut voice_save: Option<VersionCommit> = None;
        let mut result = match method {
            "recording_update"
            | "recording_abandoned"
            | "recording_discard"
            | "recording_remove_audio"
            | "recording_delete" => {
                self.mutate_recording(
                    &mut next,
                    method,
                    p,
                    &mut delete_after_commit,
                    &mut audio_to_delete,
                )
                .await?
            }
            "version_save" | "version_select" | "version_update" => {
                self.mutate_version(&mut next, method, p, &mut voice_save)
                    .await?
            }
            "config_save" | "config_remove" => {
                self.mutate_configuration(&mut next, method, p, &mut delete_after_commit)?
            }
            "settings_save" => {
                next.settings.update(&p["settings"])?;
                redacted_settings(&json!(&next.settings))
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
                let pubs = r.publications.as_mut().ok_or("Publicaciones inválidas")?;
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
                r.publications
                    .as_mut()
                    .ok_or("Publicaciones inválidas")?
                    .retain(|v| v["destinationId"] != key);
                Value::Null
            }
            "account_effect_begin" | "account_effect_finish" => {
                let record = record_mut(&mut next, text(p, "recordingId")?)?;
                if method == "account_effect_begin" {
                    record
                        .extra
                        .insert("accountEffectPending".into(), json!(true));
                } else {
                    record.extra.remove("accountEffectPending");
                }
                Value::Null
            }
            _ => return Err(format!("Operación desconocida: {method}")),
        };
        let index = LibraryIndex::from_edit(next.clone(), &scope.full_recordings)?;
        let mut write = Self::scoped_write(&before, &next, scope)?;
        let mut taught = None;
        if let Some((recording_id, version_id, voices, teaching)) = voice_save {
            taught = Some((recording_id, teaching.is_some()));
            write.version_voices = Some((version_id, voices));
            write.teaching = teaching;
        }
        write.audio_deletions = audio_to_delete;
        let learned = self.database.write(write).await?;
        self.data = index;
        if let Some((recording_id, report_learning)) = taught {
            self.pending_voices.remove(&recording_id);
            if report_learning {
                result["learnedVoice"] = json!(learned);
            }
        }
        if method == "recording_discard" {
            self.pending_voices.remove(text(p, "id")?);
            self.drain_audio_deletions().await?;
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
