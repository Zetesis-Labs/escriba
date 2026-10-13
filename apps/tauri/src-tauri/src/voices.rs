use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::HashMap;

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

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct SpeakerVoice {
    pub speaker: String,
    pub embedding: Vec<f32>,
    pub model: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SpeakerSpan {
    pub speaker: String,
    pub start: f64,
    pub end: f64,
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
    fn la_voz_se_serializa_para_guardarla_en_el_controlador() {
        let value = serde_json::to_value(voice("S1", &[1.0, 0.0], "m")).unwrap();
        assert_eq!(
            value,
            serde_json::json!({"speaker":"S1","embedding":[1.0,0.0],"model":"m"})
        );
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
