use super::*;

impl Store {
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
}

pub(super) fn strip_embeddings(value: &mut Value) {
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
pub(super) fn relabel_voices(
    source: &model::Transcript,
    corrected: &model::Transcript,
    voices: &mut [SpeakerVoice],
) -> Result<(), String> {
    let old = &source.segments;
    let new = &corrected.segments;
    if old.len() != new.len() {
        return Err("La corrección cambió los segmentos".into());
    }
    let mut labels = HashMap::new();
    for (before, after) in old.iter().zip(new) {
        if let (Some(before), Some(after)) = (
            before.speaker.as_ref().map(String::as_str),
            after.speaker.as_ref().map(String::as_str),
        ) {
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
