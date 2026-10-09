use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

pub const PREVIEW_CHARACTERS: usize = 400;

fn preview(transcript: &Value) -> String {
    let text = transcript["text"].as_str().unwrap_or("");
    if !text.is_empty() {
        return text.chars().take(PREVIEW_CHARACTERS).collect();
    }
    let mut joined = String::new();
    for segment in transcript["segments"].as_array().into_iter().flatten() {
        if joined.chars().count() >= PREVIEW_CHARACTERS {
            break;
        }
        if !joined.is_empty() {
            joined.push('\n');
        }
        joined.push_str(segment["text"].as_str().unwrap_or(""));
    }
    joined.chars().take(PREVIEW_CHARACTERS).collect()
}

fn light_transcript(transcript: &Value) -> Value {
    let duration = transcript
        .get("duration")
        .filter(|value| value.is_number())
        .cloned()
        .or_else(|| {
            transcript["segments"]
                .as_array()
                .and_then(|segments| segments.last())
                .map(|last| last["end"].clone())
        })
        .unwrap_or(Value::Null);
    json!({"text": preview(transcript), "segments": [], "duration": duration, "language": transcript["language"]})
}

fn without<'a>(
    object: &'a Map<String, Value>,
    skipped: &'a str,
) -> impl Iterator<Item = (String, Value)> + 'a {
    object
        .iter()
        .filter(move |(key, _)| key.as_str() != skipped)
        .map(|(key, value)| (key.clone(), value.clone()))
}

pub fn light_version(version: &Value) -> Value {
    let Some(object) = version.as_object() else {
        return version.clone();
    };
    let mut light: Map<String, Value> = without(object, "transcript").collect();
    light.insert(
        "transcript".into(),
        light_transcript(&version["transcript"]),
    );
    Value::Object(light)
}

pub fn light_recording(recording: &Value) -> Value {
    let Some(object) = recording.as_object() else {
        return recording.clone();
    };
    let mut light: Map<String, Value> = without(object, "versions").collect();
    let versions = recording["versions"]
        .as_array()
        .map(|versions| versions.iter().map(light_version).collect())
        .unwrap_or_default();
    light.insert("versions".into(), Value::Array(versions));
    Value::Object(light)
}

fn fingerprint(program: &str) -> String {
    Sha256::digest(program.as_bytes())
        .iter()
        .take(6)
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn without_program(items: &Value, field: &str, renamed: &str) -> Value {
    let Some(items) = items.as_array() else {
        return items.clone();
    };
    Value::Array(
        items
            .iter()
            .map(|item| {
                let Some(object) = item.as_object() else {
                    return item.clone();
                };
                let mut light: Map<String, Value> = without(object, field).collect();
                if let Some(program) = item[field].as_str() {
                    light.insert(renamed.into(), json!(fingerprint(program)));
                }
                Value::Object(light)
            })
            .collect(),
    )
}

pub fn light_library(data: &Value) -> Value {
    let Some(object) = data.as_object() else {
        return data.clone();
    };
    let mut light: Map<String, Value> = without(object, "recordings").collect();
    light.insert(
        "recipes".into(),
        without_program(&data["recipes"], "bundle", "bundleFingerprint"),
    );
    light.insert(
        "destinations".into(),
        without_program(&data["destinations"], "program", "programFingerprint"),
    );
    let recordings = data["recordings"]
        .as_array()
        .map(|recordings| recordings.iter().map(light_recording).collect())
        .unwrap_or_default();
    light.insert("recordings".into(), Value::Array(recordings));
    Value::Object(light)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segment(start: f64, text: &str) -> Value {
        json!({"start": start, "end": start + 2.0, "speaker": "Ana", "text": text, "words": [{"start": start, "end": start + 1.0, "text": text}]})
    }

    #[test]
    fn la_lista_viaja_sin_segmentos_y_con_un_avance_del_texto() {
        let long = "palabra ".repeat(200);
        let data = json!({
            "settings": {"language": "es"},
            "recordings": [{
                "id": "r", "title": "nota", "status": "done",
                "versions": [{"id": "v", "backend": "local-stt", "digest": {"title": "T", "summary": "S", "tags": []},
                    "transcript": {"text": long, "segments": [segment(0.0, "hola"), segment(2.0, "adiós")], "language": "es"}}],
                "publications": [{"destinationId": "d"}]
            }]
        });
        let light = light_library(&data);
        let version = &light["recordings"][0]["versions"][0];
        assert_eq!(version["transcript"]["segments"], json!([]));
        assert_eq!(
            version["transcript"]["text"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            PREVIEW_CHARACTERS
        );
        assert_eq!(version["transcript"]["duration"], json!(4.0));
        assert_eq!(version["digest"]["summary"], "S");
        assert_eq!(
            light["recordings"][0]["publications"],
            data["recordings"][0]["publications"]
        );
        assert_eq!(light["settings"], data["settings"]);
    }

    #[test]
    fn los_programas_compilados_viajan_solo_con_su_huella() {
        let data = json!({
            "recipes": [{"id": "resumen", "kind": "code", "bundle": "var __recipe = 1;"}, {"id": "default", "kind": "form"}],
            "destinations": [{"id": "d", "program": "var __conectores = 1;"}],
            "recordings": []
        });
        let light = light_library(&data);
        assert!(light["recipes"][0].get("bundle").is_none());
        assert_eq!(
            light["recipes"][0]["bundleFingerprint"]
                .as_str()
                .unwrap()
                .len(),
            12
        );
        assert!(light["recipes"][1].get("bundleFingerprint").is_none());
        assert!(light["destinations"][0].get("program").is_none());
        assert_eq!(
            light["destinations"][0]["programFingerprint"]
                .as_str()
                .unwrap()
                .len(),
            12
        );
    }

    #[test]
    fn sin_texto_guardado_el_avance_sale_de_los_segmentos() {
        let version = light_version(
            &json!({"transcript": {"text": "", "segments": [segment(0.0, "hola"), segment(2.0, "adiós")], "duration": 9.5}}),
        );
        assert_eq!(version["transcript"]["text"], "hola\nadiós");
        assert_eq!(version["transcript"]["duration"], json!(9.5));
    }
}
