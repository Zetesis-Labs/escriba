//! Linux: whisper.cpp, no bundled LLM, Opus in Ogg and no on-demand files.

mod opus_ogg;
mod whisper;

use crate::protocol::{Failure, Params};
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
        self.whisper.transcribe(params, model)
    }

    pub fn diarized_voices(&mut self, _: &Params) -> Result<Value, Failure> {
        Err(Failure::new(
            "backend_unavailable",
            "detectar hablantes aún no está disponible en Linux",
        ))
    }

    pub fn generate(&mut self, _: &Params) -> Result<Value, Failure> {
        Err(Failure::new("backend_unavailable", LLM_UNAVAILABLE))
    }

    pub fn download(
        &mut self,
        model: &str,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Value, Failure> {
        whisper::download(model, progress)
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
