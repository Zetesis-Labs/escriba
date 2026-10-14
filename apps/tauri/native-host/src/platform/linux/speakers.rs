//! Speakers with sherpa-onnx: pyannote 3.0 splits the audio by voice and NeMo
//! TitaNet small gives each voice its embedding. TitaNet was chosen on public
//! real voices: it kept the same person and different people apart where the
//! WeSpeaker extractors overlapped (see docs/plan-linux.md, L5). Both models
//! come with any Whisper download.

use super::{download, models_root};
use crate::protocol::Failure;
use sherpa_onnx::{
    FastClusteringConfig, OfflineSpeakerDiarization, OfflineSpeakerDiarizationConfig,
    OfflineSpeakerSegmentationModelConfig, OfflineSpeakerSegmentationPyannoteModelConfig,
    SpeakerEmbeddingExtractor, SpeakerEmbeddingExtractorConfig,
};
use std::path::PathBuf;

pub const VOICE_MODEL: &str = "sherpa-onnx/nemo-titanet-small";
const SEGMENTATION: &str = "pyannote-segmentation-3-0.onnx";
const EMBEDDING: &str = "nemo_en_titanet_small.onnx";
const SEGMENTATION_URL: &str =
    "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx";
const EMBEDDING_URL: &str = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx";
const FILES: [(&str, &str, u64); 2] = [
    (SEGMENTATION, SEGMENTATION_URL, 5_992_913),
    (EMBEDDING, EMBEDDING_URL, 40_257_283),
];
const SAMPLE_RATE: usize = 16_000;
/// Shorter turns give unreliable embeddings; they still count when a voice has nothing longer.
const RELIABLE_SECONDS: f64 = 1.0;

fn folder() -> Option<PathBuf> {
    Some(models_root()?.join("speakers"))
}

fn path(name: &str) -> Option<PathBuf> {
    Some(folder()?.join(name))
}

fn present(name: &str) -> bool {
    path(name)
        .and_then(|path| std::fs::metadata(path).ok())
        .is_some_and(|metadata| metadata.is_file() && metadata.len() > 0)
}

pub fn installed() -> bool {
    FILES.iter().all(|(name, ..)| present(name))
}

pub fn missing_bytes() -> u64 {
    FILES
        .iter()
        .filter(|(name, ..)| !present(name))
        .map(|(.., bytes)| bytes)
        .sum()
}

pub fn unavailable() -> Failure {
    Failure::new(
        "backend_unavailable",
        "faltan los modelos para detectar hablantes: se descargan al descargar Whisper en STT",
    )
}

/// `ESCRIBA_SPEAKER_MODELS_URL` serves both files by name, for tests.
pub fn download(progress: &mut dyn FnMut(f64)) -> Result<(), Failure> {
    let total = missing_bytes().max(1) as f64;
    let base = std::env::var("ESCRIBA_SPEAKER_MODELS_URL").ok();
    let mut done = 0.0;
    for (name, url, bytes) in FILES {
        if present(name) {
            continue;
        }
        let target = path(name).ok_or_else(|| download::failed("no hay carpeta de datos"))?;
        let url = base
            .as_ref()
            .map_or_else(|| url.to_owned(), |base| format!("{base}/{name}"));
        let share = bytes as f64 / total;
        download::fetch(&url, &target, &mut |fraction| {
            progress(done + fraction * share)
        })?;
        done += share;
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq)]
pub struct Span {
    pub speaker: usize,
    pub start: f64,
    pub end: f64,
}

pub struct Diarization {
    pub spans: Vec<Span>,
    /// One embedding per speaker, in speaker order.
    pub voices: Vec<(usize, Vec<f32>)>,
}

pub fn label(speaker: usize) -> String {
    format!("Speaker {}", speaker + 1)
}

struct Engine {
    diarizer: OfflineSpeakerDiarization,
    extractor: SpeakerEmbeddingExtractor,
}

#[derive(Default)]
pub struct Speakers {
    engine: Option<Engine>,
}

fn failed(error: impl std::fmt::Display) -> Failure {
    Failure::new("transcription_failed", error.to_string())
}

fn threads() -> i32 {
    std::thread::available_parallelism()
        .map(|cores| cores.get().min(8) as i32)
        .unwrap_or(4)
}

fn config(speakers: Option<u32>) -> Option<OfflineSpeakerDiarizationConfig> {
    Some(OfflineSpeakerDiarizationConfig {
        segmentation: OfflineSpeakerSegmentationModelConfig {
            pyannote: OfflineSpeakerSegmentationPyannoteModelConfig {
                model: Some(path(SEGMENTATION)?.to_str()?.to_owned()),
                ..Default::default()
            },
            num_threads: threads(),
            ..Default::default()
        },
        embedding: embedding_config()?,
        clustering: FastClusteringConfig {
            num_clusters: speakers.map_or(-1, |count| count as i32),
            ..Default::default()
        },
        ..Default::default()
    })
}

fn embedding_config() -> Option<SpeakerEmbeddingExtractorConfig> {
    Some(SpeakerEmbeddingExtractorConfig {
        model: Some(path(EMBEDDING)?.to_str()?.to_owned()),
        num_threads: threads(),
        ..Default::default()
    })
}

impl Speakers {
    fn engine(&mut self, speakers: Option<u32>) -> Result<&Engine, Failure> {
        if !installed() {
            return Err(unavailable());
        }
        let config = config(speakers).ok_or_else(|| failed("ruta de modelos no UTF-8"))?;
        if let Some(engine) = &self.engine {
            engine.diarizer.set_config(&config);
        } else {
            let diarizer = OfflineSpeakerDiarization::create(&config)
                .ok_or_else(|| failed("no se pudo cargar el modelo de hablantes"))?;
            let extractor = embedding_config()
                .and_then(|config| SpeakerEmbeddingExtractor::create(&config))
                .ok_or_else(|| failed("no se pudo cargar el modelo de huellas"))?;
            self.engine = Some(Engine {
                diarizer,
                extractor,
            });
        }
        self.engine
            .as_ref()
            .ok_or_else(|| failed("motor de hablantes sin cargar"))
    }

    /// `samples` are mono at 16 kHz; `speakers` fixes how many voices there are.
    pub fn diarize(
        &mut self,
        samples: &[f32],
        speakers: Option<u32>,
    ) -> Result<Diarization, Failure> {
        let engine = self.engine(speakers)?;
        let result = engine
            .diarizer
            .process(samples)
            .ok_or_else(|| failed("no se pudieron detectar los hablantes"))?;
        let spans = in_order_of_appearance(
            result
                .sort_by_start_time()
                .into_iter()
                .filter(|segment| segment.speaker >= 0 && segment.end > segment.start)
                .map(|segment| Span {
                    speaker: segment.speaker as usize,
                    start: segment.start as f64,
                    end: segment.end as f64,
                })
                .collect(),
        );
        let mut voices = Vec::new();
        let mut ids: Vec<usize> = spans.iter().map(|span| span.speaker).collect();
        ids.sort_unstable();
        ids.dedup();
        for speaker in ids {
            let own: Vec<&Span> = spans
                .iter()
                .filter(|span| span.speaker == speaker)
                .collect();
            let reliable: Vec<&Span> = own
                .iter()
                .copied()
                .filter(|span| span.end - span.start >= RELIABLE_SECONDS)
                .collect();
            let mut weighted = Vec::new();
            for span in if reliable.is_empty() { own } else { reliable } {
                if let Some(embedding) = embed(&engine.extractor, samples, span) {
                    weighted.push((embedding, span.end - span.start));
                }
            }
            if let Some(centroid) = centroid(&weighted) {
                voices.push((speaker, centroid));
            }
        }
        Ok(Diarization { spans, voices })
    }
}

fn embed(extractor: &SpeakerEmbeddingExtractor, samples: &[f32], span: &Span) -> Option<Vec<f32>> {
    let start = ((span.start * SAMPLE_RATE as f64) as usize).min(samples.len());
    let end = ((span.end * SAMPLE_RATE as f64) as usize).min(samples.len());
    let stream = extractor.create_stream()?;
    stream.accept_waveform(SAMPLE_RATE as i32, &samples[start..end]);
    stream.input_finished();
    extractor
        .is_ready(&stream)
        .then(|| extractor.compute(&stream))
        .flatten()
}

/// Clustering numbers voices in no particular order: the first to speak is Speaker 1.
pub fn in_order_of_appearance(mut spans: Vec<Span>) -> Vec<Span> {
    let mut order: Vec<usize> = Vec::new();
    for span in &spans {
        if !order.contains(&span.speaker) {
            order.push(span.speaker);
        }
    }
    for span in &mut spans {
        span.speaker = order
            .iter()
            .position(|speaker| *speaker == span.speaker)
            .unwrap_or(span.speaker);
    }
    spans
}

/// Duration-weighted mean of unit embeddings, so a long turn counts more
/// than a short one and no turn counts for its loudness.
pub fn centroid(weighted: &[(Vec<f32>, f64)]) -> Option<Vec<f32>> {
    let dim = weighted.first()?.0.len();
    let mut sum = vec![0f64; dim];
    for (embedding, weight) in weighted {
        let norm = embedding
            .iter()
            .map(|value| (*value as f64).powi(2))
            .sum::<f64>()
            .sqrt();
        if embedding.len() != dim || norm == 0.0 || !norm.is_finite() {
            continue;
        }
        for (total, value) in sum.iter_mut().zip(embedding) {
            *total += *value as f64 / norm * weight;
        }
    }
    let norm = sum.iter().map(|value| value.powi(2)).sum::<f64>().sqrt();
    (norm > 0.0).then(|| sum.iter().map(|value| (value / norm) as f32).collect())
}

/// The speaker who talks most during `start..end`; in a pause, the nearest one.
pub fn speaker_at(spans: &[Span], start: f64, end: f64) -> Option<usize> {
    let overlap = |span: &Span| (span.end.min(end) - span.start.max(start)).max(0.0);
    let gap = |span: &Span| {
        if span.end < start {
            start - span.end
        } else if span.start > end {
            span.start - end
        } else {
            0.0
        }
    };
    let best = spans
        .iter()
        .max_by(|a, b| overlap(a).total_cmp(&overlap(b)))?;
    if overlap(best) > 0.0 {
        return Some(best.speaker);
    }
    spans
        .iter()
        .min_by(|a, b| gap(a).total_cmp(&gap(b)))
        .map(|span| span.speaker)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(speaker: usize, start: f64, end: f64) -> Span {
        Span {
            speaker,
            start,
            end,
        }
    }

    #[test]
    fn cada_tramo_es_de_quien_mas_habla_en_el_y_una_pausa_del_mas_cercano() {
        let spans = [span(0, 0.0, 4.0), span(1, 4.2, 8.0)];
        assert_eq!(speaker_at(&spans, 1.0, 2.0), Some(0));
        assert_eq!(speaker_at(&spans, 3.5, 5.0), Some(1));
        assert_eq!(speaker_at(&spans, 4.05, 4.1), Some(0));
        assert_eq!(speaker_at(&spans, 9.0, 9.5), Some(1));
        assert_eq!(speaker_at(&[], 0.0, 1.0), None);
    }

    #[test]
    fn la_huella_de_un_hablante_pesa_cada_turno_por_su_duracion_y_no_por_su_volumen() {
        let mixed = centroid(&[(vec![10.0, 0.0], 1.0), (vec![0.0, 1.0], 3.0)]).unwrap();
        assert!(mixed[1] > mixed[0] * 2.9, "{mixed:?}");
        let norm: f32 = mixed.iter().map(|value| value * value).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-5);
        assert_eq!(centroid(&[]), None);
        assert_eq!(centroid(&[(vec![0.0, 0.0], 1.0)]), None);
    }

    #[test]
    fn el_primero_en_hablar_es_el_hablante_1() {
        let spans = in_order_of_appearance(vec![
            span(3, 0.0, 1.0),
            span(1, 1.0, 2.0),
            span(3, 2.0, 3.0),
        ]);
        let speakers: Vec<usize> = spans.iter().map(|span| span.speaker).collect();
        assert_eq!(speakers, [0, 1, 0]);
    }

    #[test]
    fn los_hablantes_se_llaman_como_en_el_mac() {
        assert_eq!(label(0), "Speaker 1");
        assert_eq!(label(2), "Speaker 3");
    }
}
