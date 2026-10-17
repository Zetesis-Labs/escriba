//! The `transcribe` reply: Whisper's segments, split by speaker when asked.

use super::speakers::{label, speaker_at, Span};
use super::whisper::{Segment, Word};
use serde_json::{json, Value};

/// Each word goes to whoever speaks at its time; consecutive words of the
/// same speaker stay together, so a segment splits where the voice changes.
pub fn by_speaker(segments: Vec<Segment>, spans: &[Span]) -> Vec<(Option<usize>, Segment)> {
    let mut split = Vec::new();
    for segment in segments {
        if segment.words.is_empty() {
            let speaker = speaker_at(spans, segment.start, segment.end);
            split.push((speaker, segment));
            continue;
        }
        let mut current: Option<(Option<usize>, Vec<Word>)> = None;
        for word in segment.words {
            let speaker = speaker_at(spans, word.start, word.end);
            match &mut current {
                Some((owner, words)) if *owner == speaker => words.push(word),
                _ => {
                    if let Some((owner, words)) = current.take() {
                        split.push((owner, joined(words)));
                    }
                    current = Some((speaker, vec![word]));
                }
            }
        }
        if let Some((owner, words)) = current {
            split.push((owner, joined(words)));
        }
    }
    split
}

fn joined(words: Vec<Word>) -> Segment {
    Segment {
        start: words.first().map_or(0.0, |word| word.start),
        end: words.last().map_or(0.0, |word| word.end),
        text: words
            .iter()
            .map(|word| word.text.as_str())
            .collect::<Vec<_>>()
            .join(" "),
        words,
    }
}

pub fn reply(
    segments: Vec<(Option<usize>, Segment)>,
    voices: Value,
    language: Option<String>,
    duration: f64,
) -> Value {
    let segments: Vec<Value> = segments
        .into_iter()
        .map(|(speaker, segment)| {
            json!({
                "start": segment.start,
                "end": segment.end,
                "text": segment.text,
                "speaker": speaker.map(label),
                "words": segment.words.iter().map(Word::json).collect::<Vec<_>>(),
            })
        })
        .collect();
    let text = segments
        .iter()
        .filter_map(|segment| segment["text"].as_str())
        .collect::<Vec<_>>()
        .join(" ");
    json!({
        "text": text,
        "segments": segments,
        "voices": voices,
        "language": language.unwrap_or_else(|| "auto".into()),
        "duration": duration,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str, start: f64, end: f64) -> Word {
        Word {
            start,
            end,
            text: text.into(),
        }
    }

    #[test]
    fn un_segmento_se_parte_donde_cambia_la_voz() {
        let segment = Segment {
            start: 0.0,
            end: 4.0,
            text: "Hola, ¿qué tal? Bien.".into(),
            words: vec![
                word("Hola,", 0.0, 0.8),
                word("¿qué", 0.9, 1.3),
                word("tal?", 1.3, 1.8),
                word("Bien.", 2.6, 3.2),
            ],
        };
        let spans = [
            Span {
                speaker: 0,
                start: 0.0,
                end: 2.0,
            },
            Span {
                speaker: 1,
                start: 2.4,
                end: 4.0,
            },
        ];
        let split = by_speaker(vec![segment], &spans);
        let shape: Vec<_> = split
            .iter()
            .map(|(speaker, segment)| (*speaker, segment.text.as_str(), segment.start, segment.end))
            .collect();
        assert_eq!(
            shape,
            [
                (Some(0), "Hola, ¿qué tal?", 0.0, 1.8),
                (Some(1), "Bien.", 2.6, 3.2)
            ]
        );
    }

    #[test]
    fn sin_hablantes_cada_segmento_queda_como_vino_y_sin_nombre() {
        let segment = Segment {
            start: 0.0,
            end: 1.0,
            text: "Hola".into(),
            words: vec![word("Hola", 0.0, 1.0)],
        };
        let reply = reply(vec![(None, segment)], json!([]), Some("es".into()), 1.0);
        assert_eq!(reply["segments"][0]["speaker"], Value::Null);
        assert_eq!(reply["text"], "Hola");
        assert_eq!(reply["language"], "es");
    }
}
