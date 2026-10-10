use super::*;
use model::{Field, Transcript};

impl Version {
    pub(super) fn create(
        params: &Value,
        transcript: Transcript,
        has_voices: bool,
    ) -> Result<Self, String> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Options {
            #[serde(default)]
            recipe_id: Field<String>,
            #[serde(default)]
            digest: Field<Value>,
            #[serde(default)]
            data: Field<Value>,
            #[serde(default)]
            inputs: Field<Value>,
        }
        let options: Options =
            serde_json::from_value(params.clone()).map_err(|_| "Versión inválida")?;
        Ok(Self {
            id: id(),
            created_at: now().into(),
            backend: params["backend"]
                .as_str()
                .unwrap_or("local")
                .to_owned()
                .into(),
            transcript: transcript.into(),
            has_voices: has_voices.into(),
            recipe_id: options.recipe_id,
            digest: options.digest,
            data: options.data,
            inputs: options.inputs,
            extra: serde_json::Map::new(),
        })
    }
}

impl Recording {
    pub(super) fn append_version(&mut self, version: Version) -> Result<(), String> {
        self.current_version_id = version.id.clone().into();
        if let Some(duration) = version
            .transcript
            .as_ref()
            .and_then(|transcript| transcript.duration.as_ref())
        {
            self.duration = duration.clone().into();
        }
        self.versions_mut()?.push(version);
        Ok(())
    }
}

impl Store {
    pub(super) fn mutate_version(
        &self,
        next: &mut LibraryData,
        method: &str,
        p: &Value,
        voice_save: &mut Option<VersionCommit>,
    ) -> Result<Value, String> {
        Ok(match method {
            "version_save" => {
                let recording_id = text(p, "recordingId")?;
                let target = record_mut(next, recording_id)?;
                let record = target;
                let mut transcript_json = p["transcript"].clone();
                strip_embeddings(&mut transcript_json);
                let transcript: model::Transcript = serde_json::from_value(transcript_json)
                    .map_err(|_| "Transcripción inválida")?;
                let mut teaching = None;
                let voices = if let Some(source) = p["sourceVersionId"].as_str() {
                    let source_version = record
                        .versions
                        .as_ref()
                        .and_then(|versions| versions.iter().find(|version| version.id == source))
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
                    relabel_voices(
                        source_version
                            .transcript
                            .as_ref()
                            .ok_or("Transcripción de origen inválida")?,
                        &transcript,
                        &mut voices,
                    )?;
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
                let version = Version::create(p, transcript, !voices.is_empty())?;
                let version_id = version.id.clone();
                let result = serde_json::to_value(&version).map_err(|_| "Versión inválida")?;
                record.append_version(version)?;
                *voice_save = Some((recording_id.to_owned(), version_id, voices, teaching));
                result
            }
            "version_select" => {
                let target = record_mut(next, text(p, "recordingId")?)?;
                let record = target;
                record.select_version(text(p, "versionId")?)?;
                Value::Null
            }
            "version_update" => {
                let target = record_mut(next, text(p, "recordingId")?)?;
                let record = target;
                let key = text(p, "versionId")?;
                let version = record
                    .versions_mut()?
                    .iter_mut()
                    .find(|version| version.id == key)
                    .ok_or("Versión no encontrada")?;
                if let Some(value) = p.get("digest") {
                    version.digest = model::Field::Present(Some(value.clone()));
                }
                if let Some(value) = p.get("data") {
                    version.data = model::Field::Present(Some(value.clone()));
                }
                serde_json::to_value(version).map_err(|_| "Versión inválida")?
            }
            _ => return Err(format!("Operación desconocida: {method}")),
        })
    }
}
