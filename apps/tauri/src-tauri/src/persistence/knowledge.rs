use super::*;

#[derive(Clone, Debug)]
pub struct CoreChange {
    pub key: String,
    pub revision: String,
    pub kind: String,
    pub id: String,
    pub value: Option<Value>,
}

#[derive(SurrealValue)]
struct Dirty {
    key: String,
    revision: String,
    kind: String,
    entity_id: String,
}

pub(super) async fn initialize(db: &Surreal<Db>) -> Result<(), String> {
    db.query("DEFINE TABLE IF NOT EXISTS knowledge_dirty SCHEMALESS PERMISSIONS NONE; DEFINE TABLE IF NOT EXISTS knowledge_meta SCHEMALESS PERMISSIONS NONE")
        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    for (table, kind, owner) in [
        ("recording", "recording", "key"),
        ("version", "recording", "parent"),
        ("person", "person", "key"),
    ] {
        db.query(format!("DEFINE EVENT OVERWRITE knowledge_changed ON TABLE {table} WHEN $before != $after THEN {{ LET $entity = IF $event = 'DELETE' {{ $before.{owner} }} ELSE {{ $after.{owner} }}; LET $key = '{kind}:' + $entity; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = '{kind}', entity_id = $entity, revision = type::string(rand::uuid()); }}"))
            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    }
    db.query("BEGIN; IF !record::exists(knowledge_meta:backfill_v1) { FOR $row IN (SELECT key FROM recording) { LET $key = 'recording:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'recording', entity_id = $row.key, revision = type::string(rand::uuid()); }; FOR $row IN (SELECT key FROM person) { LET $key = 'person:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'person', entity_id = $row.key, revision = type::string(rand::uuid()); }; CREATE knowledge_meta:backfill_v1; }; COMMIT;")
        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    Ok(())
}

pub(super) async fn prepare(db: &Surreal<Db>, epoch: &str) -> Result<(), String> {
    if epoch.is_empty() || epoch.len() > 200 {
        return Err("Identidad de proyección inválida".into());
    }
    db.query("BEGIN; LET $current = (SELECT VALUE epoch FROM knowledge_meta:projection); IF $current != [$epoch] { FOR $row IN (SELECT key FROM recording) { LET $key = 'recording:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'recording', entity_id = $row.key, revision = type::string(rand::uuid()); }; FOR $row IN (SELECT key FROM person) { LET $key = 'person:' + $row.key; UPSERT type::record('knowledge_dirty', $key) SET key = $key, kind = 'person', entity_id = $row.key, revision = type::string(rand::uuid()); }; UPSERT knowledge_meta:projection SET epoch = $epoch; }; COMMIT;")
        .bind(("epoch", epoch.to_owned()))
        .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    Ok(())
}

pub(super) async fn change(db: &Surreal<Db>) -> Result<Option<CoreChange>, String> {
    let mut response = db
        .query("SELECT key, revision, kind, entity_id FROM knowledge_dirty ORDER BY key LIMIT 1")
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let mut rows: Vec<Dirty> = response.take(0).map_err(|e| e.to_string())?;
    let Some(row) = rows.pop() else {
        return Ok(None);
    };
    let value = match row.kind.as_str() {
        "recording" => recording_snapshot(db, &row.entity_id).await?,
        "person" => {
            let mut response = db.query("SELECT payload.id AS id, payload.name AS name, payload.color AS color, payload.created_at AS createdAt FROM type::record('person', $key)")
                .bind(("key", row.entity_id.clone())).await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
            let mut people: Vec<Value> = response.take(0).map_err(|e| e.to_string())?;
            people
                .pop()
                .map(|value| strings(&value, &["id", "name", "color", "createdAt"]))
        }
        _ => return Err("Tipo de cambio de conocimiento desconocido".into()),
    };
    Ok(Some(CoreChange {
        key: row.key,
        revision: row.revision,
        kind: row.kind,
        id: row.entity_id,
        value,
    }))
}

pub(super) async fn ack(db: &Surreal<Db>, key: &str, revision: &str) -> Result<(), String> {
    db.query("DELETE type::record('knowledge_dirty', $key) WHERE revision = $revision")
        .bind(("key", key.to_owned()))
        .bind(("revision", revision.to_owned()))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn strings(value: &Value, keys: &[&str]) -> Value {
    Value::Object(
        keys.iter()
            .filter_map(|key| {
                value[*key]
                    .as_str()
                    .map(|text| ((*key).into(), json!(text)))
            })
            .collect(),
    )
}
fn timing(value: &Value, mut result: Value) -> Value {
    for key in ["start", "end", "duration"] {
        if value[key].is_number() {
            result[key] = value[key].clone();
        }
    }
    result
}
fn transcript(value: &Value) -> Value {
    let mut result = timing(value, strings(value, &["text", "language"]));
    result["segments"] = Value::Array(
        value["segments"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|segment| {
                let mut result =
                    timing(segment, strings(segment, &["text", "speaker", "personId"]));
                if let Some(words) = segment["words"].as_array() {
                    result["words"] = Value::Array(
                        words
                            .iter()
                            .map(|word| timing(word, strings(word, &["text"])))
                            .collect(),
                    );
                }
                result
            })
            .collect(),
    );
    result
}
async fn recording_snapshot(db: &Surreal<Db>, id: &str) -> Result<Option<Value>, String> {
    let row: Option<Row> = db
        .select(("recording", id))
        .await
        .map_err(|e| e.to_string())?;
    let Some(row) = row else {
        return Ok(None);
    };
    if row.payload["status"] == "discarded" {
        return Ok(None);
    }
    if row.payload["id"] != id {
        return Err("Grabación guardada inválida".into());
    }
    let mut result = timing(
        &row.payload,
        strings(
            &row.payload,
            &["id", "status", "title", "createdAt", "currentVersionId"],
        ),
    );
    let mut versions = rows_for_parent(db, "version", id).await?;
    versions.sort_by_key(|row| row.position);
    result["versions"] = Value::Array(
        versions
            .into_iter()
            .map(|row| {
                let value = row.payload;
                crate::store::Version::deserialize(&value).map_err(|_| {
                    "Versión guardada inválida para la base de conocimiento".to_owned()
                })?;
                let mut result =
                    strings(&value, &["id", "createdAt", "backend", "recipeId", "title"]);
                if value["transcript"].is_object() {
                    result["transcript"] = transcript(&value["transcript"]);
                }
                if value["digest"].is_object() {
                    let mut digest =
                        strings(&value["digest"], &["title", "summary", "description"]);
                    if let Some(tags) = value["digest"]["tags"].as_array() {
                        digest["tags"] = Value::Array(
                            tags.iter()
                                .filter_map(|v| v.as_str().map(|s| json!(s)))
                                .collect(),
                        );
                    }
                    result["digest"] = digest;
                }
                Ok(result)
            })
            .collect::<Result<Vec<_>, String>>()?,
    );
    Ok(Some(result))
}
