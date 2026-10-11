use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

pub const PREVIEW_CHARACTERS: usize = 400;

fn without<'a>(
    object: &'a Map<String, Value>,
    skipped: &'a str,
) -> impl Iterator<Item = (String, Value)> + 'a {
    object
        .iter()
        .filter(move |(key, _)| key.as_str() != skipped)
        .map(|(key, value)| (key.clone(), value.clone()))
}

pub fn light_version(version: &Value) -> Result<Value, String> {
    let version = <crate::store::Version as serde::Deserialize>::deserialize(version)
        .map_err(|_| "Versión guardada inválida")?;
    serde_json::to_value(version.preview()).map_err(|_| "Proyección de versión inválida".into())
}

pub fn light_publication(publication: &Value) -> Value {
    let mut light = selected(
        publication,
        &[
            "destinationId",
            "accountId",
            "provider",
            "error",
            "updatedAt",
        ],
    );
    light.insert(
        "receipt".into(),
        Value::Object(selected(
            &publication["receipt"],
            &["state", "locator", "url", "folder"],
        )),
    );
    Value::Object(light)
}

fn selected(value: &Value, keys: &[&str]) -> Map<String, Value> {
    keys.iter()
        .filter_map(|key| {
            value
                .get(key)
                .map(|value| ((*key).to_owned(), value.clone()))
        })
        .collect()
}

#[cfg(test)]
pub fn light_recording(recording: &Value) -> Value {
    let Some(object) = recording.as_object() else {
        return recording.clone();
    };
    let mut light: Map<String, Value> = without(object, "versions").collect();
    let versions = recording["versions"]
        .as_array()
        .map(|versions| {
            versions
                .iter()
                .map(|version| light_version(version).unwrap())
                .collect()
        })
        .unwrap_or_default();
    light.insert("versions".into(), Value::Array(versions));
    if let Some(publications) = recording["publications"].as_array() {
        light.insert(
            "publications".into(),
            Value::Array(publications.iter().map(light_publication).collect()),
        );
    }
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

#[cfg(test)]
pub fn light_library(data: &Value) -> Value {
    let Some(object) = data.as_object() else {
        return data.clone();
    };
    let mut light: Map<String, Value> = object
        .iter()
        .filter(|(key, _)| {
            !["recordings", "recipes", "destinations", "providers"].contains(&key.as_str())
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    light.insert(
        "recipes".into(),
        without_program(&data["recipes"], "bundle", "bundleFingerprint"),
    );
    light.insert(
        "destinations".into(),
        without_program(&data["destinations"], "program", "programFingerprint"),
    );
    light.insert(
        "providers".into(),
        without_program(&data["providers"], "program", "programFingerprint"),
    );
    let recordings = data["recordings"]
        .as_array()
        .map(|recordings| {
            recordings
                .iter()
                .filter(|recording| recording["status"] != "discarded")
                .map(light_recording)
                .collect()
        })
        .unwrap_or_default();
    light.insert("recordings".into(), Value::Array(recordings));
    Value::Object(light)
}

pub fn typed_library(data: &crate::store::LibraryIndex) -> Value {
    use crate::store::{Field, RecordingStatus};
    fn field<T: serde::Serialize>(fields: &mut Map<String, Value>, name: &str, value: &Field<T>) {
        if !value.is_missing() {
            fields.insert(name.to_owned(), json!(value));
        }
    }
    let recordings = data
        .recordings
        .iter()
        .filter(|record| record.status != RecordingStatus::Discarded)
        .map(|record| {
            let mut fields = record.extra.clone();
            fields.insert("id".into(), json!(record.id));
            fields.insert("status".into(), json!(record.status));
            field(&mut fields, "title", &record.title);
            field(&mut fields, "createdAt", &record.created_at);
            field(&mut fields, "source", &record.source);
            field(&mut fields, "sourceKey", &record.source_key);
            field(&mut fields, "legacyKey", &record.legacy_key);
            field(&mut fields, "audioPath", &record.audio_path);
            field(&mut fields, "audioHash", &record.audio_hash);
            field(&mut fields, "duration", &record.duration);
            field(&mut fields, "error", &record.error);
            field(&mut fields, "recipeId", &record.recipe_id);
            field(&mut fields, "currentVersionId", &record.current_version_id);
            field(&mut fields, "publications", &record.publications);
            fields.insert(
                "versions".into(),
                record
                    .versions
                    .as_ref()
                    .map(|versions| json!(versions))
                    .unwrap_or_else(|| json!([])),
            );
            Value::Object(fields)
        })
        .collect();
    let mut fields = data.extra.clone();
    fields.insert("schemaVersion".into(), json!(data.schema_version));
    fields.insert("recordings".into(), Value::Array(recordings));
    fields.insert("settings".into(), json!(data.settings));
    fields.insert("accounts".into(), data.accounts.clone());
    fields.insert("resolvers".into(), data.resolvers.clone());
    fields.insert("logs".into(), data.logs.clone());
    fields.insert(
        "recipes".into(),
        without_program(&data.recipes, "bundle", "bundleFingerprint"),
    );
    fields.insert(
        "destinations".into(),
        without_program(&data.destinations, "program", "programFingerprint"),
    );
    fields.insert(
        "providers".into(),
        without_program(&data.providers, "program", "programFingerprint"),
    );
    Value::Object(fields)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cambiar_contenido_fuera_del_extracto_invalida_el_detalle() {
        let mut version = json!({"id":"v","digest":{"title":"Nota","summary":"Mismo comienzo. Contenido anterior","tags":[]},"transcript":{"text":"texto","segments":[]}});
        let before = light_version(&version).unwrap();
        version["digest"]["summary"] = json!("Mismo comienzo. Contenido renovado");
        let after = light_version(&version).unwrap();
        assert_eq!(before["digest"], after["digest"]);
        assert_ne!(before["revision"], after["revision"]);
    }

    #[test]
    fn la_lista_no_carga_resumen_datos_ni_codigo_de_publicaciones() {
        let version = json!({"id":"v","digest":{"title":"Título","description":"Extracto","tags":["tema"],"summary":"resumen muy largo"},"data":{"large":"muchos datos"},"inputs":{"source":"criterios"},"transcript":{"text":"texto ".repeat(200),"segments":[segment(0.0,"palabra")]}});
        let light = light_version(&version).unwrap();
        assert!(light["digest"].get("summary").is_none());
        assert!(light.get("data").is_none());
        assert!(light.get("inputs").is_none());
        assert_eq!(light["digest"]["description"], "resumen muy largo");
        assert_eq!(light["transcript"]["segments"], json!([]));
        let publication = light_publication(
            &json!({"destinationId":"d","provider":"notion","program":"codigo grande","configuration":{"body":"plantilla"},"receipt":{"url":"https://example.com/nota","state":"published","large":"respuesta completa"}}),
        );
        assert!(publication.get("program").is_none());
        assert!(publication.get("configuration").is_none());
        assert!(publication["receipt"].get("large").is_none());
        assert_eq!(publication["receipt"]["url"], "https://example.com/nota");
    }

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
        assert_eq!(version["digest"]["description"], "S");
        assert_eq!(
            light["recordings"][0]["publications"],
            json!([light_publication(&data["recordings"][0]["publications"][0])])
        );
        assert_eq!(light["settings"], data["settings"]);
    }

    #[test]
    fn la_biblioteca_visible_omite_lapidas_sin_fecha_ni_versiones() {
        let data = json!({
            "recipes":[],"destinations":[],
            "recordings":[
                {"id":"descartada","source":"/origen.m4a","sourceKey":null,"legacyKey":null,"status":"discarded"},
                {"id":"visible","title":"Nota","createdAt":"2026-10-10T00:00:00Z","status":"pending","versions":[],"publications":[]}
            ]
        });

        let light = light_library(&data);

        assert_eq!(light["recordings"].as_array().unwrap().len(), 1);
        assert_eq!(light["recordings"][0]["id"], "visible");
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
            &json!({"id":"v", "transcript": {"text": "", "segments": [segment(0.0, "hola"), segment(2.0, "adiós")], "duration": 9.5}}),
        ).unwrap();
        assert_eq!(version["transcript"]["text"], "hola\nadiós");
        assert_eq!(version["transcript"]["duration"], json!(9.5));
    }
}
