use super::*;
use model::Transcript;
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DraftContent {
    title: String,
    transcript: Transcript,
    digest: Option<DraftDigest>,
    data: Value,
}

#[derive(Clone, Deserialize, Serialize)]
struct DraftDigest {
    title: String,
    summary: String,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    description: Field<String>,
    tags: Vec<String>,
    #[serde(flatten)]
    extra: serde_json::Map<String, Value>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct NoteDraft {
    id: String,
    recording_id: String,
    base_version_id: String,
    base_fingerprint: String,
    revision: u64,
    created_at: String,
    updated_at: String,
    content: DraftContent,
}

fn fingerprint(version: &Version, title: &Field<String>) -> String {
    format!(
        "{:x}",
        Sha256::digest(json!([version, title]).to_string().as_bytes())
    )
}

fn current(record: &Recording) -> Result<&Version, String> {
    record
        .versions
        .as_ref()
        .and_then(|versions| {
            versions
                .iter()
                .find(|v| Some(&v.id) == record.current_version_id.as_ref())
                .or_else(|| {
                    versions
                        .iter()
                        .max_by_key(|version| version.created_at.as_ref())
                })
        })
        .ok_or_else(|| "La nota no tiene una versión vigente".into())
}

fn content(record: &Recording, version: &Version) -> Result<DraftContent, String> {
    let mut content: DraftContent = serde_json::from_value(json!({
        "title": version.extra.get("title").and_then(Value::as_str).or_else(|| version.digest.as_ref().and_then(|d| d["title"].as_str())).or_else(|| record.title.as_ref().map(String::as_str)).unwrap_or(""),
        "transcript": version.transcript,
        "digest": version.digest,
        "data": version.data,
    })).map_err(|_| "La versión no tiene un formato editable válido".to_owned())?;
    if let Some(digest) = &mut content.digest {
        digest.title = content.title.clone();
    }
    Ok(content)
}

impl Store {
    pub(super) fn draft_command(&mut self, method: &str, p: &Value) -> Result<Value, String> {
        let key = text(p, "recordingId")?;
        self.recording_for_write(key)?;
        let stored = self
            .database
            .draft_read(key, false)?
            .map(serde_json::from_value::<NoteDraft>)
            .transpose()
            .map_err(|_| "Borrador guardado inválido")?;
        if stored
            .as_ref()
            .is_some_and(|draft| draft.recording_id != key)
        {
            return Err("El borrador no pertenece a la grabación".into());
        }
        if method == "note_draft_get" {
            return Ok(json!(stored));
        }
        let before = self.recording_edit(key)?;
        let record = before
            .recordings
            .iter()
            .find(|r| r.id == key)
            .ok_or("Grabación no encontrada")?;
        let base = current(record)?;
        if method == "note_draft_begin" {
            if let Some(stored) = stored {
                return Ok(json!(stored));
            }
            let draft = NoteDraft {
                id: id(),
                recording_id: key.into(),
                base_version_id: base.id.clone(),
                base_fingerprint: fingerprint(base, &record.title),
                revision: 0,
                created_at: now(),
                updated_at: now(),
                content: content(record, base)?,
            };
            let result = json!(draft);
            self.database.save_scoped(
                json!(&before),
                json!(&before),
                WriteScope {
                    draft_change: Some((key.into(), Some(result.clone()))),
                    full_recordings: [key.into()].into_iter().collect(),
                    ..WriteScope::default()
                },
            )?;
            return Ok(result);
        }
        let draft_id = text(p, "draftId")?;
        let revision = p["expectedRevision"]
            .as_u64()
            .ok_or("Falta expectedRevision")?;
        if method == "note_draft_commit" {
            if let Some(receipt) = self.database.draft_read(draft_id, true)? {
                if receipt["recordingId"] != key || receipt["revision"] != revision {
                    return Err("La confirmación del borrador no coincide".into());
                }
                let version = record
                    .versions
                    .as_ref()
                    .and_then(|versions| {
                        versions
                            .iter()
                            .find(|v| v.id == receipt["versionId"].as_str().unwrap_or_default())
                    })
                    .ok_or("Versión confirmada no encontrada")?;
                return Ok(json!({"version":version,"created":receipt["created"]}));
            }
        }
        let mut draft = stored.ok_or("El borrador ya no existe")?;
        if draft.id != draft_id || draft.revision != revision {
            return Err(
                "El borrador cambió en otra ventana. Vuelve a cargarlo antes de guardar.".into(),
            );
        }
        let mut scope = WriteScope {
            full_recordings: [key.into()].into_iter().collect(),
            ..WriteScope::default()
        };
        if method == "note_draft_discard" {
            scope.draft_change = Some((key.into(), None));
            self.database
                .save_scoped(json!(&before), json!(&before), scope)?;
            return Ok(Value::Null);
        }
        if draft.base_version_id != base.id
            || draft.base_fingerprint != fingerprint(base, &record.title)
        {
            return Err("La versión de origen cambió. El borrador se conserva; descártalo para editar la versión vigente.".into());
        }
        if method == "note_draft_save" {
            let mut proposed = p["content"].clone();
            if let Some(transcript) = proposed.get_mut("transcript") {
                strip_embeddings(transcript);
            }
            draft.content =
                serde_json::from_value(proposed).map_err(|_| "Contenido del borrador inválido")?;
            validate_content(&draft.content)?;
            if let Some(digest) = &mut draft.content.digest {
                digest.title = draft.content.title.clone();
            }
            draft.revision = draft.revision.checked_add(1).ok_or("Revisión agotada")?;
            draft.updated_at = now();
            let result = json!(draft);
            scope.draft_change = Some((key.into(), Some(result.clone())));
            self.database
                .save_scoped(json!(&before), json!(&before), scope)?;
            return Ok(result);
        }
        if method == "note_draft_commit" {
            let created = json!(draft.content) != json!(content(record, base)?);
            let mut version = base.clone();
            let mut voices = Vec::new();
            if created {
                version.id = id();
                version.created_at = now().into();
                version.backend = "manual".to_owned().into();
                version
                    .extra
                    .insert("title".into(), json!(draft.content.title));
                version
                    .extra
                    .insert("sourceVersionId".into(), json!(base.id));
                voices = conservative_voices(
                    base.transcript
                        .as_ref()
                        .ok_or("Transcripción de origen inválida")?,
                    &draft.content.transcript,
                    self.database.version_voices(&base.id)?,
                );
                version.has_voices = (!voices.is_empty()).into();
                version.transcript = draft.content.transcript.into();
                version.digest = Field::Present(draft.content.digest.map(|digest| json!(digest)));
                version.data = draft.content.data.into();
            }
            let result = json!({"version":version,"created":created});
            scope.draft_change = Some((key.into(), None));
            scope.draft_receipt = Some((
                draft.id,
                key.into(),
                json!({"recordingId":key,"revision":revision,"versionId":version.id,"created":created}),
            ));
            let mut next = before.clone();
            if created {
                let target = record_mut(&mut next, key)?;
                target.title = draft.content.title.into();
                target.append_version(version.clone())?;
            }
            let index = LibraryIndex::from_edit(next.clone(), &scope.full_recordings)?;
            if created {
                self.database.save_scoped_version(
                    json!(before),
                    json!(next),
                    scope,
                    &version.id,
                    &voices,
                    None,
                )?;
            } else {
                self.database
                    .save_scoped(json!(before), json!(next), scope)?;
            }
            self.data = index;
            return Ok(result);
        }
        Err(format!("Operación desconocida: {method}"))
    }
}

fn conservative_voices(
    source: &Transcript,
    corrected: &Transcript,
    voices: Vec<SpeakerVoice>,
) -> Vec<SpeakerVoice> {
    let unique_intervals = |transcript: &Transcript| {
        let mut intervals = HashMap::new();
        for (index, segment) in transcript.segments.iter().enumerate() {
            intervals
                .entry((segment.start.clone(), segment.end.clone()))
                .and_modify(|entry| *entry = None)
                .or_insert(Some(index));
        }
        intervals
    };
    let source_intervals = unique_intervals(source);
    let corrected_intervals = unique_intervals(corrected);
    let mut label_counts = HashMap::new();
    for segment in &corrected.segments {
        if let Some(label) = segment.speaker.as_ref() {
            *label_counts.entry(label.as_str()).or_insert(0usize) += 1;
        }
    }
    voices
        .into_iter()
        .filter_map(|mut voice| {
            let mut label = None;
            let mut matched = 0;
            for segment in source
                .segments
                .iter()
                .filter(|segment| segment.speaker.as_ref() == Some(&voice.speaker))
            {
                let interval = (segment.start.clone(), segment.end.clone());
                source_intervals.get(&interval).copied().flatten()?;
                let index = corrected_intervals.get(&interval).copied().flatten()?;
                let next_label = corrected.segments[index].speaker.as_ref()?.as_str();
                if label.is_some_and(|previous| previous != next_label) {
                    return None;
                }
                label = Some(next_label);
                matched += 1;
            }
            let label = label?;
            if label_counts.get(label).copied() != Some(matched) {
                return None;
            }
            voice.speaker = label.into();
            Some(voice)
        })
        .collect()
}

fn validate_content(content: &DraftContent) -> Result<(), String> {
    for segment in &content.transcript.segments {
        let start = segment
            .start
            .as_f64()
            .ok_or("Inicio de segmento inválido")?;
        let end = segment.end.as_f64().ok_or("Fin de segmento inválido")?;
        if start < 0.0 || end < start {
            return Err("Intervalo de segmento inválido".into());
        }
        if let Some(words) = segment.words.as_ref() {
            for word in words {
                let word_start = word.start.as_f64().ok_or("Inicio de palabra inválido")?;
                let word_end = word.end.as_f64().ok_or("Fin de palabra inválido")?;
                if word_start < 0.0 || word_end < word_start {
                    return Err("Intervalo de palabra inválido".into());
                }
            }
        }
    }
    if content
        .transcript
        .duration
        .as_ref()
        .is_some_and(|duration| duration.as_f64().is_none_or(|value| value < 0.0))
    {
        return Err("Duración inválida".into());
    }
    Ok(())
}
