//! Local transcription with whisper.cpp. Models are ggml files downloaded
//! explicitly into the models folder; transcribing never downloads.

use crate::platform::{models_root, DEFAULT_MODEL, MODELS};
use crate::protocol::{required_string, Failure, Params};
use serde_json::{json, Value};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

const MODELS_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";
const SAMPLE_RATE: u32 = 16_000;

/// A library created before Linux had its own engine may name a macOS model.
pub fn normalized(model: &str) -> &str {
    if model.starts_with("openai_whisper-") || model.starts_with("distil-whisper") {
        DEFAULT_MODEL
    } else {
        model
    }
}

pub fn model_path(model: &str) -> Option<PathBuf> {
    Some(models_root()?.join(format!("ggml-{}.bin", normalized(model))))
}

pub fn installed(model: &str) -> bool {
    model_path(model)
        .and_then(|path| fs::metadata(path).ok())
        .is_some_and(|metadata| metadata.is_file() && metadata.len() > 0)
}

/// The catalog with the real size of installed models.
pub fn catalog() -> Value {
    let models: Vec<Value> = MODELS
        .iter()
        .map(|(model, approximate)| {
            let installed = installed(model);
            let bytes = model_path(model)
                .and_then(|path| fs::metadata(path).ok())
                .filter(|_| installed)
                .map_or(*approximate, |metadata| metadata.len());
            json!({"model": model, "label": model, "bytes": bytes, "installed": installed})
        })
        .collect();
    json!({"models": models, "default": DEFAULT_MODEL})
}

fn download_failed(error: impl std::fmt::Display) -> Failure {
    Failure::new(
        "download_failed",
        format!("no se pudo descargar el modelo: {error}"),
    )
}

/// Downloads into a temporary file and only keeps a complete model.
pub fn download(model: &str, progress: &mut dyn FnMut(f64)) -> Result<Value, Failure> {
    let model = normalized(model);
    let path = model_path(model).ok_or_else(|| download_failed("no hay carpeta de datos"))?;
    let partial = path.with_extension("bin.part");
    let base = std::env::var("ESCRIBA_MODELS_URL").unwrap_or_else(|_| MODELS_URL.into());
    let fetched = (|| -> Result<(), Failure> {
        fs::create_dir_all(path.parent().expect("carpeta de modelos")).map_err(download_failed)?;
        let response = ureq::get(&format!("{base}/ggml-{model}.bin"))
            .call()
            .map_err(download_failed)?;
        let body = response.into_body();
        let total = body.content_length();
        let mut reader = body.into_reader();
        let mut file = File::create(&partial).map_err(download_failed)?;
        let mut buffer = vec![0; 1 << 16];
        let (mut received, mut reported) = (0u64, -1.0);
        loop {
            let read = reader.read(&mut buffer).map_err(download_failed)?;
            if read == 0 {
                break;
            }
            file.write_all(&buffer[..read]).map_err(download_failed)?;
            received += read as u64;
            if let Some(total) = total.filter(|total| *total > 0) {
                let fraction = (received as f64 / total as f64).min(1.0);
                if fraction - reported >= 0.01 {
                    progress(fraction);
                    reported = fraction;
                }
            }
        }
        if received == 0 || total.is_some_and(|total| total != received) {
            return Err(download_failed("la descarga se cortó"));
        }
        file.sync_all().map_err(download_failed)?;
        fs::rename(&partial, &path).map_err(download_failed)
    })();
    if let Err(failure) = fetched {
        let _ = fs::remove_file(&partial);
        return Err(failure);
    }
    Ok(json!({"model": model, "path": path}))
}

pub struct Engine {
    model: String,
    context: WhisperContext,
}

#[derive(Default)]
pub struct Whisper {
    engine: Option<Engine>,
}

fn unavailable(model: &str) -> Failure {
    Failure::new(
        "backend_unavailable",
        format!("el modelo de Whisper {model} no está descargado"),
    )
}

fn failed(error: impl std::fmt::Display) -> Failure {
    Failure::new("transcription_failed", error.to_string())
}

/// `null` or `auto` detect the language; otherwise a two or three letter code.
fn language(params: &Params) -> Result<Option<String>, Failure> {
    match params.get("language") {
        None => Ok(Some("es".into())),
        Some(Value::Null) => Ok(None),
        Some(Value::String(code)) if code == "auto" => Ok(None),
        Some(Value::String(code))
            if (2..=3).contains(&code.len()) && code.chars().all(|c| c.is_ascii_lowercase()) =>
        {
            Ok(Some(code.clone()))
        }
        _ => Err(Failure::new(
            "invalid_params",
            "language debe ser un código de dos o tres letras, auto o null",
        )),
    }
}

impl Whisper {
    pub fn delete(&mut self, model: &str) -> Result<Value, Failure> {
        let path = model_path(model)
            .filter(|_| installed(model))
            .ok_or_else(|| {
                Failure::new(
                    "model_missing",
                    format!("el modelo {model} no está descargado"),
                )
            })?;
        if self
            .engine
            .as_ref()
            .is_some_and(|engine| engine.model == model)
        {
            self.engine = None;
        }
        fs::remove_file(&path).map_err(|error| {
            Failure::new(
                "delete_failed",
                format!("no se pudo borrar el modelo: {error}"),
            )
        })?;
        Ok(json!({"model": model}))
    }

    fn engine(&mut self, model: &str) -> Result<&Engine, Failure> {
        if self
            .engine
            .as_ref()
            .is_some_and(|engine| engine.model == model)
        {
            return Ok(self.engine.as_ref().expect("motor cargado"));
        }
        self.engine = None;
        let path = model_path(model)
            .filter(|_| installed(model))
            .ok_or_else(|| unavailable(model))?;
        let context = WhisperContext::new_with_params(
            path.to_str()
                .ok_or_else(|| failed("ruta del modelo no UTF-8"))?,
            WhisperContextParameters::default(),
        )
        .map_err(|error| failed(format!("no se pudo cargar el modelo: {error}")))?;
        self.engine = Some(Engine {
            model: model.to_owned(),
            context,
        });
        Ok(self.engine.as_ref().expect("motor cargado"))
    }

    pub fn transcribe(&mut self, params: &Params, model: &str) -> Result<Value, Failure> {
        let audio = Path::new(required_string(params, "audioPath")?);
        if !audio.is_file() {
            return Err(Failure::new(
                "audio_missing",
                format!("no existe el fichero de audio: {}", audio.display()),
            ));
        }
        if params.get("diarize").and_then(Value::as_bool) == Some(true) {
            return Err(failed("detectar hablantes aún no está disponible en Linux"));
        }
        let language = language(params)?;
        if !installed(model) {
            return Err(unavailable(model));
        }
        let samples = crate::audio::decode_16k(audio)?;
        let engine = self.engine(model)?;
        let mut state = engine.context.create_state().map_err(failed)?;
        let mut full = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        full.set_language(Some(language.as_deref().unwrap_or("auto")));
        full.set_token_timestamps(true);
        full.set_print_progress(false);
        full.set_print_realtime(false);
        full.set_print_special(false);
        full.set_print_timestamps(false);
        full.set_n_threads(
            std::thread::available_parallelism()
                .map(|cores| cores.get().min(8) as i32)
                .unwrap_or(4),
        );
        state.full(full, &samples).map_err(failed)?;
        let special = engine.context.token_eot();
        let mut segments = Vec::new();
        for index in 0..state.full_n_segments() {
            let Some(segment) = state.get_segment(index) else {
                continue;
            };
            let mut words: Vec<Word> = Vec::new();
            for position in 0..segment.n_tokens() {
                let Some(token) = segment.get_token(position) else {
                    continue;
                };
                let data = token.token_data();
                if data.id >= special {
                    continue;
                }
                let text = token.to_str_lossy().map_err(failed)?.into_owned();
                words::push(
                    &mut words,
                    &text,
                    data.t0 as f64 / 100.0,
                    data.t1 as f64 / 100.0,
                );
            }
            let text = segment.to_str_lossy().map_err(failed)?.trim().to_owned();
            if text.is_empty() {
                continue;
            }
            segments.push(json!({
                "start": segment.start_timestamp() as f64 / 100.0,
                "end": segment.end_timestamp() as f64 / 100.0,
                "text": text,
                "speaker": null,
                "words": words.iter().map(Word::json).collect::<Vec<_>>(),
            }));
        }
        let text = segments
            .iter()
            .filter_map(|segment| segment["text"].as_str())
            .collect::<Vec<_>>()
            .join(" ");
        Ok(json!({
            "text": text,
            "segments": segments,
            "voices": [],
            "language": language.unwrap_or_else(|| "auto".into()),
            "duration": samples.len() as f64 / SAMPLE_RATE as f64,
        }))
    }
}

use words::Word;

mod words {
    use serde_json::{json, Value};

    #[derive(Debug, PartialEq)]
    pub struct Word {
        pub start: f64,
        pub end: f64,
        pub text: String,
    }

    impl Word {
        pub fn json(&self) -> Value {
            json!({"start": self.start, "end": self.end, "text": self.text})
        }
    }

    /// Whisper tokens are word pieces: a leading space starts a new word.
    pub fn push(words: &mut Vec<Word>, piece: &str, start: f64, end: f64) {
        let starts_word = piece.starts_with(' ') || words.is_empty();
        let text = piece.trim();
        if text.is_empty() {
            return;
        }
        match words.last_mut() {
            Some(word) if !starts_word => {
                word.text.push_str(text);
                word.end = end.max(word.end);
            }
            _ => words.push(Word {
                start,
                end: end.max(start),
                text: text.to_owned(),
            }),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn los_trozos_sin_espacio_se_unen_a_su_palabra() {
            let mut words = Vec::new();
            for (piece, start, end) in [
                (" Ho", 0.0, 0.2),
                ("la", 0.2, 0.4),
                (",", 0.4, 0.4),
                (" prue", 0.5, 0.7),
                ("ba", 0.7, 0.9),
                (" ", 0.9, 0.9),
            ] {
                push(&mut words, piece, start, end);
            }
            assert_eq!(
                words,
                vec![
                    Word {
                        start: 0.0,
                        end: 0.4,
                        text: "Hola,".into()
                    },
                    Word {
                        start: 0.5,
                        end: 0.9,
                        text: "prueba".into()
                    },
                ]
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(value: Value) -> Params {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn el_idioma_de_serie_es_espanol_y_null_o_auto_lo_detectan() {
        assert_eq!(
            language(&params(json!({}))).ok().unwrap().as_deref(),
            Some("es")
        );
        assert_eq!(
            language(&params(json!({"language": null}))).ok().unwrap(),
            None
        );
        assert_eq!(
            language(&params(json!({"language": "auto"}))).ok().unwrap(),
            None
        );
        assert_eq!(
            language(&params(json!({"language": "en"})))
                .ok()
                .unwrap()
                .as_deref(),
            Some("en")
        );
        assert!(language(&params(json!({"language": "ES"}))).is_err());
        assert!(language(&params(json!({"language": "es-ES"}))).is_err());
    }

    #[test]
    fn los_nombres_de_modelos_del_mac_pasan_al_de_serie_de_linux() {
        assert_eq!(
            normalized("openai_whisper-large-v3-v20240930"),
            "large-v3-turbo"
        );
        assert_eq!(normalized("base"), "base");
        assert_eq!(normalized("large-v3-turbo"), "large-v3-turbo");
    }
}
