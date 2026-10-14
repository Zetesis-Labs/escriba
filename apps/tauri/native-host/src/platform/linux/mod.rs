//! Linux: whisper.cpp, no bundled LLM, Opus in Ogg and no on-demand files.

mod download;
mod opus_ogg;
mod speakers;
mod transcript;
mod whisper;

use crate::protocol::{required_string, Failure, Params};
use serde_json::{json, Value};
use std::{
    ffi::OsStr,
    fs::Metadata,
    path::{Path, PathBuf},
    time::Duration,
};

pub use opus_ogg::{OpusOgg as Encoder, RATES as ENCODER_RATES};
pub use whisper::normalized as normalized_model;

pub fn file_flags(_: &Metadata) -> u32 {
    0
}

pub fn dataless(_: u32) -> bool {
    false
}

/// Nothing to download: a file is ready once it has data.
pub fn materialize(_: &Path, _: Duration) -> bool {
    true
}

#[derive(Default)]
pub struct Inference {
    whisper: whisper::Whisper,
    speakers: speakers::Speakers,
}

fn audio(params: &Params) -> Result<&Path, Failure> {
    let audio = Path::new(required_string(params, "audioPath")?);
    if audio.is_file() {
        Ok(audio)
    } else {
        Err(Failure::new(
            "audio_missing",
            format!("no existe el fichero de audio: {}", audio.display()),
        ))
    }
}

/// Omitted or `null` leaves the count open; otherwise a positive integer.
fn speaker_count(params: &Params) -> Result<Option<u32>, Failure> {
    match params.get("speakers") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|count| *count > 0)
            .and_then(|count| u32::try_from(count).ok())
            .map(Some)
            .ok_or_else(|| Failure::new("invalid_params", "speakers debe ser un entero positivo")),
    }
}

fn voices(diarization: &speakers::Diarization) -> Value {
    Value::Array(
        diarization
            .voices
            .iter()
            .map(|(speaker, embedding)| {
                json!({"speaker": speakers::label(*speaker), "embedding": embedding, "model": speakers::VOICE_MODEL})
            })
            .collect(),
    )
}

impl Inference {
    pub fn status(&self, model: &str) -> Value {
        json!({
            "whisper": {
                "available": whisper::installed(model),
                "model": model,
                "modelsPath": models_root().map(|root| root.display().to_string()),
            },
            "llm": {"available": false, "reason": LLM_UNAVAILABLE, "capacity": 0},
        })
    }

    pub fn transcribe(&mut self, params: &Params, model: &str) -> Result<Value, Failure> {
        let audio = audio(params)?;
        let diarize = params.get("diarize").and_then(Value::as_bool) == Some(true);
        let count = speaker_count(params)?;
        let language = whisper::language(params)?;
        if !whisper::installed(model) {
            return Err(whisper::unavailable(model));
        }
        if diarize && !speakers::installed() {
            return Err(speakers::unavailable());
        }
        let samples = crate::audio::decode_16k(audio)?;
        let segments = self
            .whisper
            .transcribe(&samples, language.as_deref(), model)?;
        let duration = samples.len() as f64 / whisper::SAMPLE_RATE as f64;
        if !diarize {
            let plain = segments
                .into_iter()
                .map(|segment| (None, segment))
                .collect();
            return Ok(transcript::reply(plain, json!([]), language, duration));
        }
        let diarization = self.speakers.diarize(&samples, count)?;
        let voices = voices(&diarization);
        Ok(transcript::reply(
            transcript::by_speaker(segments, &diarization.spans),
            voices,
            language,
            duration,
        ))
    }

    pub fn diarized_voices(&mut self, params: &Params) -> Result<Value, Failure> {
        let audio = audio(params)?;
        let count = speaker_count(params)?;
        if !speakers::installed() {
            return Err(speakers::unavailable());
        }
        let samples = crate::audio::decode_16k(audio)?;
        let diarization = self.speakers.diarize(&samples, count)?;
        let spans: Vec<Value> = diarization
            .spans
            .iter()
            .map(|span| json!({"speaker": speakers::label(span.speaker), "start": span.start, "end": span.end}))
            .collect();
        Ok(json!({"voices": voices(&diarization), "spans": spans}))
    }

    pub fn generate(&mut self, _: &Params) -> Result<Value, Failure> {
        Err(Failure::new("backend_unavailable", LLM_UNAVAILABLE))
    }

    /// Any Whisper download also brings the speaker models; what is already
    /// there is not downloaded again.
    pub fn download(
        &mut self,
        model: &str,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Value, Failure> {
        let model = whisper::normalized(model);
        let own = if whisper::installed(model) {
            0
        } else {
            whisper::approximate_bytes(model)
        };
        let total = (own + speakers::missing_bytes()).max(1) as f64;
        let share = own as f64 / total;
        let reply = if own > 0 {
            whisper::download(model, &mut |fraction| progress(fraction * share))?
        } else {
            json!({"model": model, "path": whisper::model_path(model)})
        };
        speakers::download(&mut |fraction| progress(share + fraction * (1.0 - share)))?;
        Ok(reply)
    }

    pub fn models(&self) -> Value {
        whisper::catalog()
    }

    pub fn delete_model(&mut self, model: &str) -> Result<Value, Failure> {
        self.whisper.delete(model)
    }
}

pub const DEFAULT_MODEL: &str = "large-v3-turbo";

/// whisper.cpp models offered in STT, with their approximate download size.
const MODELS: [(&str, u64); 6] = [
    ("large-v3-turbo", 1_620_000_000),
    ("tiny", 78_000_000),
    ("base", 148_000_000),
    ("small", 488_000_000),
    ("medium", 1_530_000_000),
    ("large-v3", 3_100_000_000),
];
const LLM_UNAVAILABLE: &str =
    "Escriba no incluye un LLM en Linux: añade uno en LLMs y elígelo en la receta";

pub fn models_root() -> Option<PathBuf> {
    models_root_from(
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}

// XDG asks to ignore a relative XDG_DATA_HOME.
fn models_root_from(data_home: Option<&OsStr>, home: Option<&OsStr>) -> Option<PathBuf> {
    let data = data_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join(".local/share"))
        })?;
    Some(data.join("escriba/models"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn la_carpeta_de_modelos_sigue_xdg_como_la_app() {
        assert_eq!(
            models_root_from(Some(OsStr::new("/datos")), Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/datos/escriba/models"))
        );
        assert_eq!(
            models_root_from(Some(OsStr::new("rel")), Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/home/ana/.local/share/escriba/models"))
        );
        assert_eq!(models_root_from(None, None), None);
    }
}
