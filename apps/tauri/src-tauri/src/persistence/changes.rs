use crate::store::{LibraryData, Recording, RecordingStatus};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Table {
    Recording,
    Version,
    Publication,
    Account,
    Resolver,
    Recipe,
    Destination,
    Provider,
    Setting,
}

impl Table {
    pub fn name(self) -> &'static str {
        match self {
            Self::Recording => "recording",
            Self::Version => "version",
            Self::Publication => "publication",
            Self::Account => "account",
            Self::Resolver => "resolver",
            Self::Recipe => "recipe",
            Self::Destination => "destination",
            Self::Provider => "provider",
            Self::Setting => "setting",
        }
    }
    pub fn preview(self) -> Option<&'static str> {
        match self {
            Self::Version => Some("version_preview"),
            Self::Publication => Some("publication_preview"),
            _ => None,
        }
    }
}

const CATALOGS: [(Table, &str); 5] = [
    (Table::Account, "accounts"),
    (Table::Resolver, "resolvers"),
    (Table::Recipe, "recipes"),
    (Table::Destination, "destinations"),
    (Table::Provider, "providers"),
];

#[derive(Clone, Debug, PartialEq)]
pub struct RowWrite {
    pub table: Table,
    pub key: String,
    pub parent: String,
    pub position: i64,
    pub payload: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub enum RowOp {
    Upsert(RowWrite),
    Delete {
        table: Table,
        key: String,
        id: String,
    },
}

pub enum Children<'a> {
    All,
    Only(&'a HashSet<String>),
}

impl Children<'_> {
    fn includes(&self, recording_id: &str) -> bool {
        match self {
            Self::All => true,
            Self::Only(ids) => ids.contains(recording_id),
        }
    }
}

pub fn changes(
    before: &LibraryData,
    after: &LibraryData,
    children: Children<'_>,
) -> Result<Vec<RowOp>, String> {
    let mut upserts = Vec::new();
    let mut deletes = Vec::new();
    recordings(before, after, &children, &mut upserts, &mut deletes)?;
    for (table, field) in CATALOGS {
        catalog(
            table,
            field,
            before.catalog(field)?,
            after.catalog(field)?,
            &mut upserts,
            &mut deletes,
        )?;
    }
    settings(before, after, &mut upserts, &mut deletes)?;
    upserts.extend(deletes);
    Ok(upserts)
}

pub fn recording_payload(record: &Recording) -> Result<Value, String> {
    let mut payload =
        serde_json::to_value(record).map_err(|_| "No se pudo codificar la grabación")?;
    let fields = payload.as_object_mut().ok_or("Grabación inválida")?;
    fields.remove("versions");
    fields.remove("publications");
    Ok(payload)
}

fn recordings(
    before: &LibraryData,
    after: &LibraryData,
    children: &Children<'_>,
    upserts: &mut Vec<RowOp>,
    deletes: &mut Vec<RowOp>,
) -> Result<(), String> {
    let previous: HashMap<&str, &Recording> = before
        .recordings
        .iter()
        .map(|record| (record.id.as_str(), record))
        .collect();
    let mut seen = HashSet::new();
    for record in &after.recordings {
        if !seen.insert(record.id.as_str()) {
            return Err("Identificador duplicado en la biblioteca".into());
        }
        let old = previous.get(record.id.as_str()).copied();
        if old != Some(record) {
            let payload = recording_payload(record)?;
            if old.map(recording_payload).transpose()?.as_ref() != Some(&payload) {
                upserts.push(RowOp::Upsert(RowWrite {
                    table: Table::Recording,
                    key: record.id.clone(),
                    parent: String::new(),
                    position: 0,
                    payload,
                }));
            }
        }
        if children.includes(&record.id) {
            child_rows(old, record, upserts, deletes)?;
        }
    }
    for old in &before.recordings {
        if !seen.contains(old.id.as_str()) {
            deletes.push(RowOp::Delete {
                table: Table::Recording,
                key: old.id.clone(),
                id: old.id.clone(),
            });
        }
    }
    Ok(())
}

fn child_values(record: &Recording, table: Table) -> Result<Vec<Value>, String> {
    let (values, field) = match table {
        Table::Version => (
            record
                .versions
                .as_ref()
                .map(|versions| versions.iter().map(|version| json!(version)).collect()),
            "versions",
        ),
        _ => (record.publications.as_ref().cloned(), "publications"),
    };
    match values {
        Some(values) => Ok(values),
        None if record.status == RecordingStatus::Discarded => Ok(Vec::new()),
        None => Err(format!("{field} inválido")),
    }
}

fn child_rows(
    old: Option<&Recording>,
    record: &Recording,
    upserts: &mut Vec<RowOp>,
    deletes: &mut Vec<RowOp>,
) -> Result<(), String> {
    for (table, id_field) in [
        (Table::Version, "id"),
        (Table::Publication, "destinationId"),
    ] {
        let mut previous = HashMap::new();
        if let Some(old) = old {
            for (position, child) in child_values(old, table)?.into_iter().enumerate() {
                let id = child[id_field]
                    .as_str()
                    .ok_or_else(|| format!("{} sin {id_field}", table.name()))?
                    .to_owned();
                previous.insert(id, (position as i64, child));
            }
        }
        let mut seen = HashSet::new();
        for (position, child) in child_values(record, table)?.into_iter().enumerate() {
            let id = child[id_field]
                .as_str()
                .ok_or_else(|| format!("{} sin {id_field}", table.name()))?
                .to_owned();
            if !seen.insert(id.clone()) {
                return Err("Identificador duplicado en la biblioteca".into());
            }
            let position = position as i64;
            if previous
                .get(&id)
                .is_some_and(|(old_position, old)| *old_position == position && *old == child)
            {
                continue;
            }
            upserts.push(RowOp::Upsert(RowWrite {
                table,
                key: child_key(&record.id, &id),
                parent: record.id.clone(),
                position,
                payload: child,
            }));
        }
        for id in previous.into_keys() {
            if !seen.contains(&id) {
                deletes.push(RowOp::Delete {
                    table,
                    key: child_key(&record.id, &id),
                    id,
                });
            }
        }
    }
    Ok(())
}

pub fn child_key(recording_id: &str, id: &str) -> String {
    json!([recording_id, id]).to_string()
}

fn catalog(
    table: Table,
    field: &str,
    before: &Value,
    after: &Value,
    upserts: &mut Vec<RowOp>,
    deletes: &mut Vec<RowOp>,
) -> Result<(), String> {
    let invalid = || format!("{field} inválido");
    let mut previous = HashMap::new();
    for (position, item) in before.as_array().ok_or_else(invalid)?.iter().enumerate() {
        let id = item["id"]
            .as_str()
            .ok_or_else(|| format!("{field} sin ID"))?;
        previous.insert(id, (position as i64, item));
    }
    let mut seen = HashSet::new();
    for (position, item) in after.as_array().ok_or_else(invalid)?.iter().enumerate() {
        let id = item["id"]
            .as_str()
            .ok_or_else(|| format!("{field} sin ID"))?;
        if !seen.insert(id) {
            return Err("Identificador duplicado en la biblioteca".into());
        }
        let position = position as i64;
        if previous.get(id) == Some(&(position, item)) {
            continue;
        }
        upserts.push(RowOp::Upsert(RowWrite {
            table,
            key: id.to_owned(),
            parent: String::new(),
            position,
            payload: item.clone(),
        }));
    }
    for id in previous.into_keys() {
        if !seen.contains(id) {
            deletes.push(RowOp::Delete {
                table,
                key: id.to_owned(),
                id: id.to_owned(),
            });
        }
    }
    Ok(())
}

fn settings(
    before: &LibraryData,
    after: &LibraryData,
    upserts: &mut Vec<RowOp>,
    deletes: &mut Vec<RowOp>,
) -> Result<(), String> {
    let encode = |data: &LibraryData| {
        serde_json::to_value(&data.settings)
            .ok()
            .and_then(|value| value.as_object().cloned())
            .ok_or_else(|| "Ajustes inválidos".to_owned())
    };
    let previous = encode(before)?;
    let current = encode(after)?;
    for (key, value) in &current {
        if previous.get(key) == Some(value) {
            continue;
        }
        upserts.push(RowOp::Upsert(RowWrite {
            table: Table::Setting,
            key: key.clone(),
            parent: String::new(),
            position: 0,
            payload: value.clone(),
        }));
    }
    for key in previous.keys() {
        if !current.contains_key(key) {
            deletes.push(RowOp::Delete {
                table: Table::Setting,
                key: key.clone(),
                id: key.clone(),
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn library(recordings: Value) -> LibraryData {
        LibraryData::read(&json!({
            "schemaVersion": 1,
            "recordings": recordings,
            "accounts": [],
            "resolvers": [{"id":"local-stt","name":"Whisper","role":"stt"},{"id":"remoto","name":"Remoto","role":"stt"}],
            "recipes": [{"id":"default","name":"Por defecto","kind":"form","values":{"stt":"remoto"}}],
            "destinations": [],
            "settings": {"language":"es","defaultRecipeId":"default"}
        }))
        .unwrap()
    }

    fn note(id: &str, created_at: &str) -> Value {
        json!({"id":id,"title":id,"createdAt":created_at,"status":"done","versions":[{"id":format!("{id}-v"),"transcript":{"text":"texto","segments":[]}}],"publications":[]})
    }

    fn recording(value: Value) -> Recording {
        serde_json::from_value(value).unwrap()
    }

    fn many() -> Value {
        json!((0..50)
            .map(|index| note(
                &format!("n{index}"),
                &format!("2026-10-{:02}T00:00:00Z", index % 28 + 1)
            ))
            .collect::<Vec<_>>())
    }

    fn written(ops: &[RowOp]) -> Vec<(&'static str, &str)> {
        ops.iter()
            .map(|op| match op {
                RowOp::Upsert(row) => (row.table.name(), row.key.as_str()),
                RowOp::Delete { table, key, .. } => (table.name(), key.as_str()),
            })
            .collect()
    }

    #[test]
    fn incorporar_una_nota_al_principio_solo_escribe_esa_nota() {
        let before = library(many());
        let mut after = before.clone();
        after
            .recordings
            .insert(0, recording(note("nueva", "2026-10-11T10:00:00Z")));
        let ops = changes(&before, &after, Children::Only(&HashSet::new())).unwrap();
        assert_eq!(written(&ops), vec![("recording", "nueva")]);
    }

    #[test]
    fn una_nota_nueva_acotada_escribe_tambien_sus_versiones() {
        let before = library(many());
        let mut after = before.clone();
        after
            .recordings
            .insert(0, recording(note("nueva", "2026-10-11T10:00:00Z")));
        let scope = HashSet::from(["nueva".to_owned()]);
        let ops = changes(&before, &after, Children::Only(&scope)).unwrap();
        assert_eq!(
            written(&ops),
            vec![
                ("recording", "nueva"),
                ("version", r#"["nueva","nueva-v"]"#)
            ]
        );
    }

    #[test]
    fn cambiar_el_titulo_no_reescribe_versiones_ni_otras_notas() {
        let before = library(many());
        let mut after = before.clone();
        after.recordings[7].title = "Otro".to_owned().into();
        let scope = HashSet::from([after.recordings[7].id.clone()]);
        let ops = changes(&before, &after, Children::Only(&scope)).unwrap();
        assert_eq!(written(&ops), vec![("recording", "n7")]);
    }

    #[test]
    fn corregir_una_version_no_reescribe_la_nota() {
        let before = library(many());
        let mut after = before.clone();
        after.recordings[3].versions.as_mut().unwrap()[0].digest =
            crate::store::Field::from(json!({"title":"T","summary":"S","tags":[]}));
        let scope = HashSet::from(["n3".to_owned()]);
        let ops = changes(&before, &after, Children::Only(&scope)).unwrap();
        assert_eq!(written(&ops), vec![("version", r#"["n3","n3-v"]"#)]);
    }

    #[test]
    fn versiones_de_notas_fuera_del_ambito_no_se_escriben() {
        let before = library(many());
        let mut after = before.clone();
        after.recordings[3].versions.as_mut().unwrap()[0].digest =
            crate::store::Field::from(json!({"title":"T","summary":"S","tags":[]}));
        let ops = changes(&before, &after, Children::Only(&HashSet::new())).unwrap();
        assert!(ops.is_empty());
    }

    #[test]
    fn quitar_un_resolutor_escribe_el_catalogo_y_la_receta_que_lo_nombraba() {
        let before = library(many());
        let mut after = before.clone();
        after.resolvers.as_array_mut().unwrap().remove(1);
        after.recipes[0]["values"] = json!({});
        let ops = changes(&before, &after, Children::Only(&HashSet::new())).unwrap();
        assert_eq!(
            written(&ops),
            vec![("recipe", "default"), ("resolver", "remoto")]
        );
        assert!(matches!(ops[1], RowOp::Delete { .. }));
    }

    #[test]
    fn un_ajuste_cambiado_es_una_sola_fila() {
        let before = library(many());
        let mut after = before.clone();
        after.settings.language = "en".to_owned().into();
        let ops = changes(&before, &after, Children::Only(&HashSet::new())).unwrap();
        assert_eq!(written(&ops), vec![("setting", "language")]);
    }

    #[test]
    fn quitar_una_nota_la_borra_por_su_identidad() {
        let before = library(many());
        let mut after = before.clone();
        after.recordings.remove(10);
        let ops = changes(&before, &after, Children::Only(&HashSet::new())).unwrap();
        assert_eq!(written(&ops), vec![("recording", "n10")]);
        assert!(matches!(ops[0], RowOp::Delete { .. }));
    }

    #[test]
    fn rechaza_identidades_duplicadas_y_notas_sin_versiones() {
        let before = library(json!([]));
        let mut duplicated = before.clone();
        let copy = recording(note("igual", "2026-10-11T00:00:00Z"));
        duplicated.recordings = vec![copy.clone(), copy];
        assert!(changes(&before, &duplicated, Children::All).is_err());
        let broken = library(json!([{"id":"rota","status":"done"}]));
        assert!(changes(&before, &broken, Children::All).is_err());
        let tombstone = library(json!([{"id":"lapida","status":"discarded"}]));
        assert_eq!(
            written(&changes(&before, &tombstone, Children::All).unwrap()),
            vec![("recording", "lapida")]
        );
    }

    #[test]
    fn sin_cambios_no_hay_escrituras() {
        let before = library(many());
        assert!(changes(&before, &before.clone(), Children::All)
            .unwrap()
            .is_empty());
    }
}
