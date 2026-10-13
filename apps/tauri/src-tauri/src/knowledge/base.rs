use super::*;
use crate::knowledge::CoreChange;
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
fn link(key: &str, label: &str, table: &str) -> Field {
    Field {
        reference: Some(ReferenceTarget {
            ontology_id: "escriba".into(),
            table: table.into(),
        }),
        ..field(key, label, FieldType::Reference)
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
                field("words", "Palabras", FieldType::Json),
                link("transcript", "Transcripción", "transcript"),
                link("speakerRecord", "Hablante de la versión", "speaker"),
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
        ("identified_as", "Asignado a persona", "speaker", "person"),
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
#[derive(Debug, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct ListedOntology {
    #[serde(flatten)]
    pub ontology: Ontology,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub built_in: Option<bool>,
}

pub fn base_listing() -> ListedOntology {
    ListedOntology {
        ontology: base_definition(),
        built_in: Some(true),
    }
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
// Subirlo rehace la proyección entera una vez: la 2 recupera las aristas que borraba retitular.
const PROJECTION_FORMAT: u32 = 2;

struct Unit {
    version: Option<String>,
    hash: String,
    rows: Projection,
}

fn fingerprint(value: &Value) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(value.to_string().as_bytes()))
}

fn project_person(change: &CoreChange) -> Result<Projection, String> {
    let mut rows = Projection::new();
    let Some(value) = &change.value else {
        return Ok(rows);
    };
    if text(value, "id")? != change.id {
        return Err("Identidad de proyección incoherente".into());
    }
    put(
        &mut rows,
        RecordId::new("person", change.id.clone()),
        object(value, &["name", "color", "createdAt"]),
        None,
    );
    Ok(rows)
}

fn project_units(change: &CoreChange) -> Result<Vec<Unit>, String> {
    let Some(value) = &change.value else {
        return Ok(Vec::new());
    };
    if text(value, "id")? != change.id {
        return Err("Identidad de proyección incoherente".into());
    }
    let recording = RecordId::new("recording", change.id.clone());
    let versions = value["versions"]
        .as_array()
        .ok_or("Versiones de proyección inválidas")?;
    let active = versions
        .iter()
        .find(|version| version["id"] == value["currentVersionId"])
        .or_else(|| versions.last());
    let active_id = active.map(|version| text(version, "id")).transpose()?;
    let mut rows = Projection::new();
    let mut data = object(value, &["title", "createdAt", "duration", "status"]);
    if let Some(current) = active_id {
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
    let mut units = vec![Unit {
        version: None,
        hash: fingerprint(&json!({
            "title": value["title"],
            "createdAt": value["createdAt"],
            "duration": value["duration"],
            "status": value["status"],
            "currentVersionId": active_id,
        })),
        rows,
    }];
    if let Some(version) = active {
        let version_id = text(version, "id")?.to_owned();
        let titled = version["title"].is_string() || version["digest"]["title"].is_string();
        let mut rows = project_version(change, value, &recording, version)?;
        for table in rows.values_mut() {
            for row in table {
                if let DbValue::Object(data) = row {
                    if !data.contains_key("versionId") {
                        data.insert("versionId", version_id.clone().into_value());
                    }
                }
            }
        }
        units.push(Unit {
            hash: fingerprint(&json!({
                "version": version,
                "fallbackTitle": if titled { Value::Null } else { value["title"].clone() },
            })),
            version: Some(version_id),
            rows,
        });
    }
    Ok(units)
}

fn project_version(
    change: &CoreChange,
    value: &Value,
    recording: &RecordId,
    version: &Value,
) -> Result<Projection, String> {
    let mut rows = Projection::new();
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
    let Some(transcript) = version.get("transcript").filter(|value| value.is_object()) else {
        return Ok(rows);
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
    let mut speaker_people = BTreeMap::<String, std::collections::BTreeSet<Option<String>>>::new();
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
        if let Some(words) = segment["words"].as_array() {
            let words: Vec<DbValue> = words
                .iter()
                .map(|word| DbValue::Object(object(word, &["text", "start", "end"])))
                .collect();
            data.insert("words", words.into_value());
        }
        data.insert("index", (index as i64).into_value());
        data.insert("versionId", version_id.into_value());
        data.insert("version", vid.clone().into_value());
        data.insert("transcript", tid.clone().into_value());
        if let Some(label) = segment["speaker"].as_str().filter(|s| !s.is_empty()) {
            let speaker = identity(
                "speaker",
                vec![parts[0].clone(), parts[1].clone(), label.into_value()],
            );
            data.insert("speakerRecord", speaker.into_value());
        }
        put(&mut rows, sid.clone(), data, Some(&change.id));
        if let Some(label) = segment["speaker"].as_str().filter(|s| !s.is_empty()) {
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
    Ok(rows)
}

pub(super) async fn databases(root: &Surreal<Db>) -> Result<Vec<String>, String> {
    let mut response = root
        .query("INFO FOR NS")
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    let info: Option<Value> = response.take(0).map_err(error)?;
    Ok(info
        .as_ref()
        .and_then(|info| info["databases"].as_object())
        .map(|databases| databases.keys().cloned().collect())
        .unwrap_or_default())
}

async fn legacy_base(root: &Surreal<Db>) -> Result<Option<Surreal<Db>>, String> {
    let name = hashed_database("escriba");
    let session = root.clone();
    session.use_ns("knowledge").await.map_err(error)?;
    if !databases(&session).await?.contains(&name) {
        return Ok(None);
    }
    session.use_db(name).await.map_err(error)?;
    Ok(Some(session))
}

impl Knowledge {
    pub(super) async fn initialize_base(&self) -> Result<(), String> {
        let root = &self.root;
        let db = selected(root, "escriba").await?;
        db.query("DEFINE TABLE IF NOT EXISTS _escriba_manifest SCHEMALESS PERMISSIONS NONE")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let legacy = match legacy_base(root).await? {
            Some(legacy) => manifest(&legacy).await?,
            None => None,
        };
        if manifest(&db)
            .await?
            .into_iter()
            .chain(legacy)
            .any(|definition| !definition.migrations.is_empty())
        {
            return Err("Ya existe una extensión con el identificador reservado «escriba»; se conserva sin sustituirla por la base".into());
        }
        db.query(format!("DEFINE TABLE IF NOT EXISTS _escriba_manifest SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS _escriba_principal SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS _escriba_source SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS _escriba_projection SCHEMALESS PERMISSIONS NONE; DEFINE INDEX IF NOT EXISTS projection_recording ON TABLE _escriba_projection FIELDS recordingId; UPSERT _escriba_principal:runtime; {RECIPE_ACCESS}; LET $stale = (SELECT VALUE projection FROM _escriba_manifest:current) != [$format]; IF $stale {{ DELETE _escriba_projection; }}; UPSERT _escriba_manifest:current SET definition=$definition, epoch = IF $stale {{ $epoch }} ELSE {{ epoch ?? $epoch }}, projection=$format;"))
            .bind(("definition",serde_json::to_value(base_definition()).map_err(error)?)).bind(("epoch",Uuid::new_v4().to_string())).bind(("format",PROJECTION_FORMAT)).await.map_err(error)?.check().map_err(error)?;
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
        db.query("DEFINE FIELD OVERWRITE transcript ON segment TYPE record<transcript> REFERENCE; DEFINE FIELD OVERWRITE speakerRecord ON segment TYPE option<record<speaker>> REFERENCE;")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        self.retire_legacy_base().await
    }
    async fn retire_legacy_base(&self) -> Result<(), String> {
        let Some(db) = legacy_base(&self.root).await? else {
            return Ok(());
        };
        if manifest(&db)
            .await?
            .is_some_and(|definition| !definition.migrations.is_empty())
        {
            return Ok(());
        }
        let session = self.root.clone();
        session.use_ns("knowledge").await.map_err(error)?;
        session
            .query(format!(
                "REMOVE DATABASE IF EXISTS `{}`",
                hashed_database("escriba")
            ))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        Ok(())
    }
    pub async fn base_epoch(&self) -> Result<String, String> {
        let root = &self.root;
        let mut result = selected(root, "escriba")
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
        match change.kind.as_str() {
            "recording" => self.sync_recording(change).await,
            "person" => self.sync_person(change).await,
            _ => Err("Entidad base desconocida".into()),
        }
    }
    async fn insert_rows(
        tx: &surrealdb::method::Transaction<Db>,
        rows: &Projection,
    ) -> Result<(), String> {
        let collections = base_definition().collections;
        for collection in collections
            .iter()
            .filter(|c| c.relation.is_none())
            .chain(collections.iter().filter(|c| c.relation.is_some()))
        {
            let Some(values) = rows.get(&collection.table) else {
                continue;
            };
            let relation = if collection.relation.is_some() {
                "RELATION "
            } else {
                ""
            };
            for chunk in values.chunks(256) {
                tx.query(format!(
                    "INSERT {relation}INTO `{}` $rows",
                    collection.table
                ))
                .bind(("rows", DbValue::Array(chunk.to_vec().into())))
                .await
                .map_err(error)?
                .check()
                .map_err(error)?;
            }
        }
        Ok(())
    }
    async fn replace_rows(
        tx: &surrealdb::method::Transaction<Db>,
        rows: &Projection,
    ) -> Result<(), String> {
        for row in rows.values().flatten() {
            let DbValue::Object(data) = row else {
                return Err("Fila de proyección inválida".into());
            };
            let Some(DbValue::RecordId(id)) = data.get("id") else {
                return Err("Fila de proyección sin ID".into());
            };
            tx.query("UPSERT $id CONTENT $data")
                .bind(("id", id.clone()))
                .bind(("data", row.clone()))
                .await
                .map_err(error)?
                .check()
                .map_err(error)?;
        }
        Ok(())
    }
    async fn relate_speakers(
        tx: &surrealdb::method::Transaction<Db>,
        query: &str,
        bindings: Vec<(&'static str, DbValue)>,
    ) -> Result<(), String> {
        let mut request = tx.query(query);
        for binding in bindings {
            request = request.bind(binding);
        }
        let mut response = request.await.map_err(error)?.check().map_err(error)?;
        let speakers: Vec<DbValue> = response.take(0).map_err(error)?;
        for speaker in speakers {
            let DbValue::Object(speaker) = speaker else {
                return Err("Hablante de la base inválido".into());
            };
            let Some(DbValue::RecordId(id)) = speaker.get("id") else {
                return Err("Hablante sin ID".into());
            };
            let Some(DbValue::String(person)) = speaker.get("personId") else {
                continue;
            };
            let person = RecordId::new("person", person.clone());
            let mut response = tx
                .query("RETURN record::exists($id)")
                .bind(("id", person.clone()))
                .await
                .map_err(error)?
                .check()
                .map_err(error)?;
            let exists: DbValue = response.take(0).map_err(error)?;
            if exists == DbValue::Bool(true) {
                let edge = identity(
                    "identified_as",
                    vec![id.clone().into_value(), person.clone().into_value()],
                );
                tx.query("DELETE $edge; RELATE $speaker->$edge->$person SET recordingId=$recording, versionId=$version")
                    .bind(("speaker", id.clone()))
                    .bind(("edge", edge))
                    .bind(("person", person))
                    .bind(("recording", speaker.get("recordingId").cloned().ok_or("Hablante sin grabación")?))
                    .bind(("version", speaker.get("versionId").cloned().unwrap_or(DbValue::None)))
                    .await
                    .map_err(error)?
                    .check()
                    .map_err(error)?;
            }
        }
        Ok(())
    }
    async fn sync_recording(&self, change: &CoreChange) -> Result<(), String> {
        let units = project_units(change)?;
        let db = selected(&self.root, "escriba").await?;
        let mut response = db
            .query("SELECT unit, hash FROM _escriba_projection WHERE recordingId = $recording")
            .bind(("recording", change.id.clone()))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let stored: Vec<Value> = response.take(0).map_err(error)?;
        let stored: BTreeMap<String, String> = stored
            .into_iter()
            .filter_map(|row| {
                Some((
                    row["unit"].as_str()?.to_owned(),
                    row["hash"].as_str()?.to_owned(),
                ))
            })
            .collect();
        let unit_key = |unit: &Unit| unit.version.clone().unwrap_or_else(|| "recording".into());
        let current: BTreeMap<String, &Unit> =
            units.iter().map(|unit| (unit_key(unit), unit)).collect();
        let fresh = stored.is_empty();
        if !fresh
            && current.len() == stored.len()
            && current
                .iter()
                .all(|(key, unit)| stored.get(key) == Some(&unit.hash))
        {
            return Ok(());
        }
        let per_version: Vec<String> = base_definition()
            .collections
            .into_iter()
            .map(|collection| collection.table)
            .filter(|table| table != "person" && table != "recording")
            .collect();
        let tx = db.begin().await.map_err(error)?;
        let outcome: Result<(), String> = async {
            if fresh {
                for table in per_version.iter().chain(std::iter::once(&"recording".to_owned())) {
                    tx.query(format!("DELETE `{table}` WHERE recordingId=$recording"))
                        .bind(("recording", change.id.clone()))
                        .await.map_err(error)?.check().map_err(error)?;
                }
            }
            let mut changed_versions = Vec::new();
            for (key, unit) in &current {
                if !fresh && stored.get(key) == Some(&unit.hash) {
                    continue;
                }
                match (&unit.version, fresh) {
                    (Some(version), false) => {
                        for table in &per_version {
                            tx.query(format!("DELETE `{table}` WHERE recordingId=$recording AND versionId=$version"))
                                .bind(("recording", change.id.clone()))
                                .bind(("version", version.clone()))
                                .await.map_err(error)?.check().map_err(error)?;
                        }
                        Self::insert_rows(&tx, &unit.rows).await?;
                    }
                    (None, false) => Self::replace_rows(&tx, &unit.rows).await?,
                    (_, true) => Self::insert_rows(&tx, &unit.rows).await?,
                }
                if let Some(version) = &unit.version {
                    changed_versions.push(version.clone());
                }
                tx.query("UPSERT type::record('_escriba_projection', [$recording, $unit]) SET recordingId=$recording, unit=$unit, hash=$hash")
                    .bind(("recording", change.id.clone()))
                    .bind(("unit", key.clone()))
                    .bind(("hash", unit.hash.clone()))
                    .await.map_err(error)?.check().map_err(error)?;
            }
            for key in stored.keys().filter(|key| !current.contains_key(*key)) {
                if key == "recording" {
                    tx.query("DELETE $id")
                        .bind(("id", RecordId::new("recording", change.id.clone())))
                        .await.map_err(error)?.check().map_err(error)?;
                } else {
                    for table in &per_version {
                        tx.query(format!("DELETE `{table}` WHERE recordingId=$recording AND versionId=$version"))
                            .bind(("recording", change.id.clone()))
                            .bind(("version", key.clone()))
                            .await.map_err(error)?.check().map_err(error)?;
                    }
                }
                tx.query("DELETE type::record('_escriba_projection', [$recording, $unit])")
                    .bind(("recording", change.id.clone()))
                    .bind(("unit", key.clone()))
                    .await.map_err(error)?.check().map_err(error)?;
            }
            if !changed_versions.is_empty() {
                Self::relate_speakers(
                    &tx,
                    "SELECT id, personId, recordingId, versionId FROM speaker WHERE personId != NONE AND recordingId = $recording AND versionId IN $versions",
                    vec![
                        ("recording", change.id.clone().into_value()),
                        ("versions", changed_versions.into_value()),
                    ],
                )
                .await?;
            }
            Ok(())
        }
        .await;
        match outcome {
            Ok(()) => tx.commit().await.map(|_| ()).map_err(error),
            Err(e) => {
                tx.cancel().await.map_err(error)?;
                Err(e)
            }
        }
    }
    async fn sync_person(&self, change: &CoreChange) -> Result<(), String> {
        let rows = project_person(change)?;
        let db = selected(&self.root, "escriba").await?;
        let tx = db.begin().await.map_err(error)?;
        let outcome: Result<(), String> = async {
            let id = RecordId::new("person", change.id.clone());
            if change.value.is_none() {
                tx.query("DELETE identified_as WHERE out=$id")
                    .bind(("id", id.clone()))
                    .await
                    .map_err(error)?
                    .check()
                    .map_err(error)?;
                tx.query("DELETE $id")
                    .bind(("id", id))
                    .await
                    .map_err(error)?
                    .check()
                    .map_err(error)?;
            }
            for value in rows.get("person").into_iter().flatten() {
                let DbValue::Object(data) = value else {
                    return Err("Persona inválida".into());
                };
                tx.query("UPSERT $id CONTENT $data")
                    .bind(("id", data.get("id").cloned().ok_or("Persona sin ID")?))
                    .bind(("data", value.clone()))
                    .await
                    .map_err(error)?
                    .check()
                    .map_err(error)?;
            }
            Self::relate_speakers(
                &tx,
                "SELECT id, personId, recordingId, versionId FROM speaker WHERE personId = $person",
                vec![("person", change.id.clone().into_value())],
            )
            .await
        }
        .await;
        match outcome {
            Ok(()) => tx.commit().await.map(|_| ()).map_err(error),
            Err(e) => {
                tx.cancel().await.map_err(error)?;
                Err(e)
            }
        }
    }
}
