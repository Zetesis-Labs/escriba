use super::*;
use crate::persistence::CoreChange;
use serde_json::json;
use std::collections::BTreeMap;
use surrealdb::types::{Object, RecordId};

fn field(key: &str, label: &str, kind: FieldType) -> Field {
    Field {
        key: key.into(),
        label: label.into(),
        kind,
        required: false,
        reference: None,
    }
}
fn entity(table: &str, label: &str, title: &str, fields: Vec<Field>) -> Collection {
    Collection {
        table: table.into(),
        label: label.into(),
        title_field: title.into(),
        fields,
        relation: None,
    }
}
pub fn base_definition() -> Ontology {
    let mut collections = vec![
        entity(
            "person",
            "Personas",
            "name",
            vec![
                field("name", "Nombre", FieldType::Text),
                field("color", "Color", FieldType::Text),
                field("createdAt", "Fecha de alta", FieldType::Date),
            ],
        ),
        entity(
            "recording",
            "Grabaciones",
            "title",
            vec![
                field("title", "Título", FieldType::Text),
                field("createdAt", "Fecha", FieldType::Date),
                field("duration", "Duración", FieldType::Number),
                field("status", "Estado", FieldType::Text),
                field("currentVersion", "Versión vigente", FieldType::Json),
            ],
        ),
        entity(
            "version",
            "Versiones",
            "title",
            vec![
                field("title", "Título", FieldType::Text),
                field("createdAt", "Fecha", FieldType::Date),
                field("backend", "Origen", FieldType::Text),
                field("summary", "Resumen", FieldType::Text),
                field("tags", "Etiquetas", FieldType::Json),
            ],
        ),
        entity(
            "transcript",
            "Transcripciones",
            "text",
            vec![
                field("text", "Texto", FieldType::Text),
                field("language", "Idioma", FieldType::Text),
                field("duration", "Duración", FieldType::Number),
            ],
        ),
        entity(
            "speaker",
            "Hablantes",
            "name",
            vec![
                field("name", "Nombre en la versión", FieldType::Text),
                field("personId", "Persona asignada", FieldType::Text),
            ],
        ),
        entity(
            "segment",
            "Segmentos",
            "text",
            vec![
                field("text", "Texto", FieldType::Text),
                field("start", "Inicio", FieldType::Number),
                field("end", "Fin", FieldType::Number),
                field("index", "Posición", FieldType::Number),
                field("speaker", "Hablante", FieldType::Text),
                field("personId", "Persona asignada", FieldType::Text),
            ],
        ),
        entity(
            "word",
            "Palabras",
            "text",
            vec![
                field("text", "Texto", FieldType::Text),
                field("start", "Inicio", FieldType::Number),
                field("end", "Fin", FieldType::Number),
                field("index", "Posición", FieldType::Number),
            ],
        ),
    ];
    for (table, label, from, to) in [
        ("has_version", "Tiene versión", "recording", "version"),
        (
            "has_transcript",
            "Tiene transcripción",
            "version",
            "transcript",
        ),
        ("has_segment", "Contiene segmento", "transcript", "segment"),
        ("has_word", "Contiene palabra", "segment", "word"),
        ("spoken_by", "Dicho por", "segment", "speaker"),
        ("identified_as", "Asignado a persona", "speaker", "person"),
        ("derived_from", "Corregida desde", "version", "version"),
    ] {
        collections.push(Collection {
            table: table.into(),
            label: label.into(),
            title_field: "title".into(),
            fields: vec![],
            relation: Some(Relation {
                from: from.into(),
                to: to.into(),
            }),
        });
    }
    Ontology {
        id: "escriba".into(),
        name: "Escriba".into(),
        version: 1,
        migrations: vec![],
        collections,
    }
}
pub fn base_listing() -> Value {
    json!({"id":"escriba","name":"Escriba","version":1,"migrations":[],"collections":base_definition().collections,"builtIn":true})
}

type Projection = BTreeMap<String, Vec<DbValue>>;
fn identity(table: &str, parts: Vec<DbValue>) -> RecordId {
    RecordId::new(table, surrealdb::types::RecordIdKey::Array(parts.into()))
}
fn object(value: &Value, keys: &[&str]) -> Object {
    keys.iter()
        .filter_map(|key| {
            value
                .get(*key)
                .map(|value| ((*key).to_string(), value.clone().into_value()))
        })
        .collect()
}
fn put(rows: &mut Projection, id: RecordId, mut data: Object, recording: Option<&str>) {
    if let Some(recording) = recording {
        data.insert("recordingId", recording.into_value());
    }
    data.insert("id", DbValue::RecordId(id.clone()));
    rows.entry(id.table.to_string())
        .or_default()
        .push(DbValue::Object(data));
}
fn edge(rows: &mut Projection, table: &str, from: RecordId, to: RecordId, recording: &str) {
    let id = identity(
        table,
        vec![from.clone().into_value(), to.clone().into_value()],
    );
    let mut data = Object::new();
    data.insert("in", from.into_value());
    data.insert("out", to.into_value());
    put(rows, id, data, Some(recording));
}
fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value[key]
        .as_str()
        .ok_or_else(|| format!("Falta {key} en la proyección base"))
}
fn project(change: &CoreChange) -> Result<Projection, String> {
    let mut rows = Projection::new();
    let Some(value) = &change.value else {
        return Ok(rows);
    };
    if text(value, "id")? != change.id {
        return Err("Identidad de proyección incoherente".into());
    }
    if change.kind == "person" {
        put(
            &mut rows,
            RecordId::new("person", change.id.clone()),
            object(value, &["name", "color", "createdAt"]),
            None,
        );
        return Ok(rows);
    }
    if change.kind != "recording" {
        return Err("Entidad base desconocida".into());
    }
    let recording = RecordId::new("recording", change.id.clone());
    let mut data = object(value, &["title", "createdAt", "duration", "status"]);
    if let Some(current) = value["currentVersionId"].as_str() {
        data.insert(
            "currentVersion",
            identity(
                "version",
                vec![change.id.clone().into_value(), current.into_value()],
            )
            .into_value(),
        );
    }
    put(&mut rows, recording.clone(), data, Some(&change.id));
    for version in value["versions"]
        .as_array()
        .ok_or("Versiones de proyección inválidas")?
    {
        let version_id = text(version, "id")?;
        let parts = vec![change.id.clone().into_value(), version_id.into_value()];
        let vid = identity("version", parts.clone());
        let tid = identity("transcript", parts.clone());
        let mut data = object(version, &["createdAt", "backend", "recipeId", "title"]);
        if !data.contains_key("title") {
            data.insert(
                "title",
                version["digest"]["title"]
                    .as_str()
                    .or_else(|| value["title"].as_str())
                    .unwrap_or("Versión")
                    .into_value(),
            );
        }
        for key in ["summary", "description", "tags"] {
            if let Some(value) = version["digest"].get(key) {
                data.insert(key, value.clone().into_value());
            }
        }
        data.insert("recording", recording.clone().into_value());
        data.insert("versionId", version_id.into_value());
        put(&mut rows, vid.clone(), data, Some(&change.id));
        edge(
            &mut rows,
            "has_version",
            recording.clone(),
            vid.clone(),
            &change.id,
        );
        if let Some(source) = version["sourceVersionId"].as_str() {
            edge(
                &mut rows,
                "derived_from",
                vid.clone(),
                identity(
                    "version",
                    vec![change.id.clone().into_value(), source.into_value()],
                ),
                &change.id,
            );
        }
        let Some(transcript) = version.get("transcript").filter(|value| value.is_object()) else {
            continue;
        };
        let mut data = object(transcript, &["text", "language", "duration"]);
        data.insert("version", vid.clone().into_value());
        data.insert("versionId", version_id.into_value());
        put(&mut rows, tid.clone(), data, Some(&change.id));
        edge(
            &mut rows,
            "has_transcript",
            vid.clone(),
            tid.clone(),
            &change.id,
        );
        let mut speakers = BTreeMap::<String, Object>::new();
        let mut speaker_people =
            BTreeMap::<String, std::collections::BTreeSet<Option<String>>>::new();
        for (index, segment) in transcript["segments"]
            .as_array()
            .ok_or("Segmentos de proyección inválidos")?
            .iter()
            .enumerate()
        {
            let sid = identity(
                "segment",
                vec![
                    parts[0].clone(),
                    parts[1].clone(),
                    (index as i64).into_value(),
                ],
            );
            let mut data = object(segment, &["text", "start", "end", "speaker", "personId"]);
            data.insert("index", (index as i64).into_value());
            data.insert("versionId", version_id.into_value());
            data.insert("version", vid.clone().into_value());
            data.insert("transcript", tid.clone().into_value());
            put(&mut rows, sid.clone(), data, Some(&change.id));
            edge(
                &mut rows,
                "has_segment",
                tid.clone(),
                sid.clone(),
                &change.id,
            );
            if let Some(label) = segment["speaker"].as_str().filter(|s| !s.is_empty()) {
                let speaker = identity(
                    "speaker",
                    vec![parts[0].clone(), parts[1].clone(), label.into_value()],
                );
                speakers.entry(label.into()).or_insert_with(|| {
                    let mut data = Object::new();
                    data.insert("name", label.into_value());
                    data.insert("versionId", version_id.into_value());
                    data.insert("version", vid.clone().into_value());
                    data
                });
                speaker_people
                    .entry(label.into())
                    .or_default()
                    .insert(segment["personId"].as_str().map(str::to_owned));
                edge(&mut rows, "spoken_by", sid.clone(), speaker, &change.id);
            }
            if let Some(words) = segment["words"].as_array() {
                for (word_index, word) in words.iter().enumerate() {
                    let wid = identity(
                        "word",
                        vec![
                            parts[0].clone(),
                            parts[1].clone(),
                            (index as i64).into_value(),
                            (word_index as i64).into_value(),
                        ],
                    );
                    let mut data = object(word, &["text", "start", "end"]);
                    data.insert("index", (word_index as i64).into_value());
                    data.insert("versionId", version_id.into_value());
                    data.insert("segment", sid.clone().into_value());
                    put(&mut rows, wid.clone(), data, Some(&change.id));
                    edge(&mut rows, "has_word", sid.clone(), wid, &change.id);
                }
            }
        }
        for (label, mut data) in speakers {
            let speaker = identity(
                "speaker",
                vec![
                    parts[0].clone(),
                    parts[1].clone(),
                    label.clone().into_value(),
                ],
            );
            if let Some(people) = speaker_people
                .get(&label)
                .filter(|people| people.len() == 1)
            {
                if let Some(Some(person)) = people.iter().next() {
                    data.insert("personId", person.clone());
                }
            }
            put(&mut rows, speaker, data, Some(&change.id));
        }
    }
    Ok(rows)
}

impl Knowledge {
    pub(super) async fn initialize_base(&self) -> Result<(), String> {
        let root = self.root.lock().await;
        let db = selected(&root, "escriba").await?;
        db.query("DEFINE TABLE IF NOT EXISTS _escriba_manifest SCHEMALESS PERMISSIONS NONE")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        if manifest(&db)
            .await?
            .is_some_and(|definition| !definition.migrations.is_empty())
        {
            return Err("Ya existe una extensión con el identificador reservado «escriba»; se conserva sin sustituirla por la base".into());
        }
        db.query("DEFINE TABLE IF NOT EXISTS _escriba_manifest SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS _escriba_principal SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS _escriba_source SCHEMALESS PERMISSIONS NONE; UPSERT _escriba_principal:runtime; DEFINE ACCESS OVERWRITE _escriba_recipe ON DB TYPE RECORD SIGNIN (RETURN _escriba_principal:runtime) DURATION FOR SESSION 1h; UPSERT _escriba_manifest:current SET definition=$definition, epoch=epoch ?? $epoch;")
            .bind(("definition",serde_json::to_value(base_definition()).map_err(error)?)).bind(("epoch",Uuid::new_v4().to_string())).await.map_err(error)?.check().map_err(error)?;
        for collection in base_definition().collections {
            let kind = collection
                .relation
                .as_ref()
                .map(|relation| {
                    format!("TYPE RELATION IN `{}` OUT `{}`", relation.from, relation.to)
                })
                .unwrap_or_default();
            db.query(format!("DEFINE TABLE OVERWRITE `{}` {kind} SCHEMALESS PERMISSIONS FOR select FULL FOR create,update,delete NONE; DEFINE INDEX IF NOT EXISTS base_recording ON TABLE `{}` FIELDS recordingId",collection.table,collection.table)).await.map_err(error)?.check().map_err(error)?;
        }
        Ok(())
    }
    pub async fn base_epoch(&self) -> Result<String, String> {
        let root = self.root.lock().await;
        let mut result = selected(&root, "escriba")
            .await?
            .query("SELECT VALUE epoch FROM _escriba_manifest:current")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let epochs: Vec<String> = result.take(0).map_err(error)?;
        epochs
            .into_iter()
            .next()
            .ok_or_else(|| "La base no tiene identidad de sincronización".into())
    }
    pub async fn sync_base_change(&self, change: &CoreChange) -> Result<(), String> {
        let rows = project(change)?;
        let root = self.root.lock().await;
        let db = selected(&root, "escriba").await?;
        let tx = db.begin().await.map_err(error)?;
        let outcome:Result<(),String>=async {
            if change.kind=="recording" {
                for collection in base_definition().collections.into_iter().filter(|c|c.table!="person") {
                    tx.query(format!("DELETE `{}` WHERE recordingId=$recording",collection.table)).bind(("recording",change.id.clone())).await.map_err(error)?.check().map_err(error)?;
                }
            } else if change.kind=="person" && change.value.is_none() {
                tx.query("DELETE identified_as WHERE out=$id").bind(("id",RecordId::new("person",change.id.clone()))).await.map_err(error)?.check().map_err(error)?;
                tx.query("DELETE $id").bind(("id",RecordId::new("person",change.id.clone()))).await.map_err(error)?.check().map_err(error)?;
            } else if change.kind!="person" { return Err("Entidad base desconocida".into()); }
            let collections=base_definition().collections;
            for collection in collections.iter().filter(|c|c.relation.is_none()).chain(collections.iter().filter(|c|c.relation.is_some())) {
                let Some(values)=rows.get(&collection.table) else {continue};
                if collection.table=="person" {
                    for value in values { let DbValue::Object(data)=value else {return Err("Persona inválida".into())};tx.query("UPSERT $id CONTENT $data").bind(("id",data.get("id").cloned().ok_or("Persona sin ID")?)).bind(("data",value.clone())).await.map_err(error)?.check().map_err(error)?; }
                    continue;
                }
                let relation=if collection.relation.is_some(){"RELATION "}else{""};
                for chunk in values.chunks(256) {
                    tx.query(format!("INSERT {relation}INTO `{}` $rows",collection.table)).bind(("rows",DbValue::Array(chunk.to_vec().into()))).await.map_err(error)?.check().map_err(error)?;
                }
            }
            let mut response=tx.query("SELECT id,personId,recordingId FROM speaker WHERE personId != NONE AND (($kind='person' AND personId=$key) OR ($kind='recording' AND recordingId=$key))").bind(("kind",change.kind.clone())).bind(("key",change.id.clone())).await.map_err(error)?.check().map_err(error)?;
            let speakers:Vec<DbValue>=response.take(0).map_err(error)?;
            for speaker in speakers {
                let DbValue::Object(speaker)=speaker else {return Err("Hablante de la base inválido".into())};
                let Some(DbValue::RecordId(id))=speaker.get("id") else {return Err("Hablante sin ID".into())};
                let Some(DbValue::String(person))=speaker.get("personId") else {continue};
                let person=RecordId::new("person",person.clone());
                let mut response=tx.query("RETURN record::exists($id)").bind(("id",person.clone())).await.map_err(error)?.check().map_err(error)?;
                let exists:DbValue=response.take(0).map_err(error)?;
                if exists==DbValue::Bool(true) {
                    let edge=identity("identified_as",vec![id.clone().into_value(),person.clone().into_value()]);
                    tx.query("DELETE $edge; RELATE $speaker->$edge->$person SET recordingId=$recording").bind(("speaker",id.clone())).bind(("edge",edge)).bind(("person",person)).bind(("recording",speaker.get("recordingId").cloned().ok_or("Hablante sin grabación")?)).await.map_err(error)?.check().map_err(error)?;
                }
            }
            Ok(())
        }.await;
        match outcome {
            Ok(()) => tx.commit().await.map(|_| ()).map_err(error),
            Err(e) => {
                tx.cancel().await.map_err(error)?;
                Err(e)
            }
        }
    }
}
