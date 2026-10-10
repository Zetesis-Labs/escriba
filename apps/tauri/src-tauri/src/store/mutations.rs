use super::*;

impl Store {
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
        let mut voice_save: Option<VersionCommit> = None;
        let mut result = match method {
            "recording_update"
            | "recording_abandoned"
            | "recording_discard"
            | "recording_remove_audio"
            | "recording_delete" => self.mutate_recording(
                &mut next,
                method,
                p,
                &mut delete_after_commit,
                &mut audio_to_delete,
            )?,
            "version_save" | "version_select" | "version_update" => {
                self.mutate_version(&mut next, method, p, &mut voice_save)?
            }
            "config_save" | "config_remove" => {
                self.mutate_configuration(&mut next, method, p, &mut delete_after_commit)?
            }
            "settings_save" => {
                next.settings.update(&p["settings"])?;
                redacted_settings(&json!(&next.settings))
            }
            "log" => {
                let entry = json!({"id":id(),"at":now(),"message":text(p,"message")?,"level":p["level"].as_str().unwrap_or("info"),"recordingId":p["recordingId"],"recipeId":p["recipeId"]});
                let logs = next.logs.as_array_mut().ok_or("Registro inválido")?;
                logs.insert(0, entry);
                logs.truncate(3000);
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
            _ => return Err(format!("Operación desconocida: {method}")),
        };
        if let Some((recording_id, version_id, voices, teaching)) = voice_save {
            let report_learning = teaching.is_some();
            let learned = self.database.save_version(
                self.data_json(),
                json!(&next),
                &version_id,
                &voices,
                teaching,
            )?;
            self.data = next;
            self.pending_voices.remove(&recording_id);
            if report_learning {
                result["learnedVoice"] = json!(learned);
            }
        } else if method == "recording_discard" {
            self.database.save_with_audio_deletions(
                self.data_json(),
                json!(&next),
                &audio_to_delete,
            )?;
            self.data = next;
        } else {
            self.commit(next)?;
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
