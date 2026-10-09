use serde::Deserialize;
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

pub const MATCH_THRESHOLD: f32 = 0.30;

pub fn public_reply(value: Value) -> Result<Value, String> {
    fn has_embedding(value: &Value) -> bool {
        match value {
            Value::Object(fields) => fields.iter().any(|(key, value)| {
                key.to_ascii_lowercase().contains("embedding") || has_embedding(value)
            }),
            Value::Array(items) => items.iter().any(has_embedding),
            _ => false,
        }
    }
    if has_embedding(&value) {
        Err("La respuesta incluye una huella de voz privada".into())
    } else {
        Ok(value)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SpeakerVoice {
    pub speaker: String,
    pub embedding: Vec<f32>,
    pub model: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct KnownVoice {
    pub person: String,
    pub embedding: Vec<f32>,
    pub model: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Recognition {
    pub speaker: String,
    pub person: String,
    pub distance: f32,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SpeakerSpan {
    pub speaker: String,
    pub start: f64,
    pub end: f64,
}

pub fn cosine_distance(a: &[f32], b: &[f32]) -> Option<f32> {
    if a.is_empty() || a.len() != b.len() {
        return None;
    }
    let (dot, norm_a, norm_b) = a.iter().zip(b).fold((0.0, 0.0, 0.0), |sum, (a, b)| {
        (sum.0 + a * b, sum.1 + a * a, sum.2 + b * b)
    });
    if !dot.is_finite()
        || !norm_a.is_finite()
        || !norm_b.is_finite()
        || norm_a <= 0.0
        || norm_b <= 0.0
    {
        return None;
    }
    Some((1.0 - dot / (norm_a.sqrt() * norm_b.sqrt())).clamp(0.0, 2.0))
}

pub fn recognize(voices: &[SpeakerVoice], known: &[KnownVoice]) -> Vec<Recognition> {
    let mut candidates = Vec::new();
    let mut speakers = HashSet::new();
    for voice in voices {
        if !speakers.insert(voice.speaker.as_str()) {
            continue;
        }
        let mut people = HashSet::new();
        for person in known {
            if !people.insert(person.person.as_str()) {
                continue;
            }
            let nearest = voices
                .iter()
                .filter(|own| own.speaker == voice.speaker)
                .flat_map(|own| {
                    known
                        .iter()
                        .filter(move |candidate| {
                            candidate.person == person.person && candidate.model == own.model
                        })
                        .filter_map(move |candidate| {
                            cosine_distance(&own.embedding, &candidate.embedding)
                        })
                })
                .min_by(|left, right| left.partial_cmp(right).unwrap_or(Ordering::Equal));
            if let Some(distance) = nearest.filter(|distance| *distance <= MATCH_THRESHOLD) {
                candidates.push(Recognition {
                    speaker: voice.speaker.clone(),
                    person: person.person.clone(),
                    distance,
                });
            }
        }
    }
    candidates.sort_by(|left, right| {
        left.distance
            .partial_cmp(&right.distance)
            .unwrap_or(Ordering::Equal)
    });
    let mut used_speakers = HashSet::new();
    let mut used_people = HashSet::new();
    candidates
        .into_iter()
        .filter(|candidate| {
            if used_speakers.contains(&candidate.speaker) || used_people.contains(&candidate.person)
            {
                return false;
            }
            used_speakers.insert(candidate.speaker.clone());
            used_people.insert(candidate.person.clone());
            true
        })
        .collect()
}

pub fn speech_by_speaker(spans: &[SpeakerSpan]) -> HashMap<String, f64> {
    let mut speech = HashMap::new();
    for span in spans {
        *speech.entry(span.speaker.clone()).or_insert(0.0) += span.end - span.start;
    }
    speech
}

pub fn dominant_voice(
    voices: &[SpeakerVoice],
    spans: &[SpeakerSpan],
    minimum_speech: f64,
) -> Option<SpeakerVoice> {
    let speech = speech_by_speaker(spans);
    let (speaker, seconds) = speech
        .into_iter()
        .max_by(|left, right| left.1.partial_cmp(&right.1).unwrap_or(Ordering::Equal))?;
    (seconds >= minimum_speech)
        .then(|| {
            voices
                .iter()
                .find(|voice| voice.speaker == speaker)
                .cloned()
        })
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn voice(speaker: &str, embedding: &[f32], model: &str) -> SpeakerVoice {
        SpeakerVoice {
            speaker: speaker.into(),
            embedding: embedding.into(),
            model: model.into(),
        }
    }

    fn known(person: &str, embedding: &[f32], model: &str) -> KnownVoice {
        KnownVoice {
            person: person.into(),
            embedding: embedding.into(),
            model: model.into(),
        }
    }

    #[test]
    fn coseno_mide_direccion_y_descarta_huellas_invalidas() {
        assert_eq!(cosine_distance(&[1.0, 0.0], &[2.0, 0.0]), Some(0.0));
        assert_eq!(cosine_distance(&[1.0, 0.0], &[-1.0, 0.0]), Some(2.0));
        assert_eq!(cosine_distance(&[1.0, 0.0], &[0.0, 1.0]), Some(1.0));
        assert_eq!(cosine_distance(&[1.0], &[1.0, 0.0]), None);
        assert_eq!(cosine_distance(&[0.0, 0.0], &[1.0, 0.0]), None);
    }

    #[test]
    fn reconoce_por_modelo_y_umbral_con_asignacion_uno_a_uno() {
        let found = recognize(
            &[
                voice("Speaker 1", &[1.0, 0.2], "m"),
                voice("Speaker 2", &[1.0, 0.05], "m"),
                voice("Speaker 3", &[0.0, 1.0], "otro"),
            ],
            &[
                known("Rubén", &[1.0, 0.0], "m"),
                known("Nuria", &[0.0, 1.0], "m"),
            ],
        );
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].speaker, "Speaker 2");
        assert_eq!(found[0].person, "Rubén");
        assert!(found[0].distance < 0.01);
    }

    #[test]
    fn reconoce_la_huella_mas_cercana_entre_varias_de_cada_persona() {
        let found = recognize(
            &[
                voice("Speaker 1", &[0.01, 1.0], "m"),
                voice("Speaker 1", &[1.0, 0.0], "m"),
                voice("Speaker 2", &[0.0, 1.0], "m"),
            ],
            &[
                known("Rubén", &[1.0, 0.01], "m"),
                known("Nuria", &[0.0, 1.0], "m"),
            ],
        );
        assert_eq!(
            found
                .iter()
                .map(|item| (item.speaker.as_str(), item.person.as_str()))
                .collect::<Vec<_>>(),
            vec![("Speaker 2", "Nuria"), ("Speaker 1", "Rubén")]
        );
    }

    #[test]
    fn la_muestra_elige_la_voz_que_habla_al_menos_treinta_segundos() {
        let voices = vec![voice("S1", &[1.0, 0.0], "m"), voice("S2", &[0.0, 1.0], "m")];
        let spans = vec![
            SpeakerSpan {
                speaker: "S1".into(),
                start: 0.0,
                end: 15.0,
            },
            SpeakerSpan {
                speaker: "S2".into(),
                start: 15.0,
                end: 46.0,
            },
            SpeakerSpan {
                speaker: "S1".into(),
                start: 46.0,
                end: 47.0,
            },
        ];
        assert_eq!(speech_by_speaker(&spans).get("S1"), Some(&16.0));
        assert_eq!(
            dominant_voice(&voices, &spans, 30.0),
            Some(voices[1].clone())
        );
        assert_eq!(dominant_voice(&voices, &spans, 32.0), None);
    }

    #[test]
    fn ninguna_respuesta_publica_contiene_embedding_ni_revela_su_valor_en_el_error() {
        let private = serde_json::json!({"recording":{"segments":[{"voiceEmbedding":[0.123456]}]}});
        let error = public_reply(private).unwrap_err();
        assert!(!error.contains("0.123456"));
        assert_eq!(
            public_reply(serde_json::json!({"recognitions":[{"person":"Rubén","distance":0.1}]}))
                .unwrap()["recognitions"][0]["person"],
            "Rubén"
        );
    }
}
