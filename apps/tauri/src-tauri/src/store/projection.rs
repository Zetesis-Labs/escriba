use super::model::{Field, Transcript, Version};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

impl Version {
    pub(crate) fn preview(&self) -> Self {
        let transcript = self.transcript.as_ref();
        let text = transcript.map(transcript_preview).unwrap_or_default();
        let duration = transcript.and_then(|value| {
            value
                .duration
                .as_ref()
                .cloned()
                .or_else(|| value.segments.last().map(|segment| segment.end.clone()))
        });
        let language = transcript.and_then(|value| value.language.as_ref().cloned());
        let digest = match self.digest.as_ref() {
            Some(Value::Object(fields)) => {
                let mut preview: Map<String, Value> = ["title", "description", "tags"]
                    .into_iter()
                    .filter_map(|key| fields.get(key).map(|value| (key.to_owned(), value.clone())))
                    .collect();
                if let Some(summary) = fields.get("summary").and_then(Value::as_str) {
                    preview.insert("description".into(), json!(summary_description(summary)));
                }
                Field::from(Value::Object(preview))
            }
            _ => self.digest.clone(),
        };
        Self {
            id: self.id.clone(),
            created_at: self.created_at.clone(),
            backend: self.backend.clone(),
            has_voices: self.has_voices.clone(),
            recipe_id: self.recipe_id.clone(),
            digest,
            transcript: Field::from(Transcript {
                text,
                segments: Vec::new(),
                duration: Field::Present(duration),
                language: Field::Present(language),
                recognitions: Field::Missing,
                extra: Map::new(),
            }),
            data: Field::Missing,
            inputs: Field::Missing,
            extra: {
                let mut extra = Map::from_iter([("revision".into(), json!(revision(self)))]);
                if let Some(title) = self.extra.get("title").and_then(Value::as_str) {
                    extra.insert("title".into(), json!(title));
                }
                extra
            },
        }
    }
}

fn transcript_preview(transcript: &Transcript) -> String {
    if !transcript.text.is_empty() {
        return transcript
            .text
            .chars()
            .take(crate::library_view::PREVIEW_CHARACTERS)
            .collect();
    }
    let mut text = String::new();
    for segment in &transcript.segments {
        let count = text.chars().count();
        if count >= crate::library_view::PREVIEW_CHARACTERS {
            break;
        }
        if !text.is_empty() {
            text.push('\n');
        }
        let remaining =
            crate::library_view::PREVIEW_CHARACTERS.saturating_sub(text.chars().count());
        text.extend(segment.text.chars().take(remaining));
    }
    text
}

fn summary_description(summary: &str) -> Option<String> {
    let summary = summary.trim();
    if summary.is_empty() {
        return None;
    }
    let line = summary.lines().next().unwrap_or(summary);
    let mut characters = line.char_indices().peekable();
    let mut sentence = line;
    while let Some((index, character)) = characters.next() {
        if ".?!".contains(character)
            && characters
                .peek()
                .is_none_or(|(_, next)| next.is_whitespace())
        {
            sentence = &line[..index + character.len_utf8()];
            break;
        }
    }
    if sentence.chars().count() <= 200 {
        return Some(sentence.to_owned());
    }
    let mut taken = String::new();
    for word in sentence.split_whitespace() {
        let length = taken.chars().count() + usize::from(!taken.is_empty()) + word.chars().count();
        if length >= 200 {
            break;
        }
        if !taken.is_empty() {
            taken.push(' ');
        }
        taken.push_str(word);
    }
    if taken.is_empty() {
        taken.extend(sentence.chars().take(199));
    }
    taken.push('…');
    Some(taken)
}

fn revision(value: &impl std::hash::Hash) -> String {
    use std::hash::Hasher;
    struct HashWriter(Sha256);
    impl Hasher for HashWriter {
        fn write(&mut self, bytes: &[u8]) {
            self.0.update(bytes);
        }
        fn finish(&self) -> u64 {
            let mut bytes = [0; 8];
            bytes.copy_from_slice(&self.0.clone().finalize()[..8]);
            u64::from_be_bytes(bytes)
        }
    }
    let mut writer = HashWriter(Sha256::new());
    value.hash(&mut writer);
    format!("{:x}", writer.0.finalize())
}
