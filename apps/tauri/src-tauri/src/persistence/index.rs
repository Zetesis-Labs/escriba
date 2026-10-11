use super::*;

#[derive(Clone, Debug, SurrealValue)]
struct KeyRow {
    key: String,
    parent: String,
}

async fn row_by_key(db: &Surreal<Db>, table: &str, key: &str) -> Result<Option<Row>, String> {
    let mut response = db
        .query("SELECT key, parent, position, payload FROM type::record($table, $key)")
        .bind(("table", table))
        .bind(("key", key))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let mut found: Vec<Row> = response.take(0).map_err(|e| e.to_string())?;
    Ok(found.pop())
}

async fn child_keys(db: &Surreal<Db>, table: &str) -> Result<Vec<KeyRow>, String> {
    let mut response = db
        .query("SELECT key, parent FROM type::table($table)")
        .bind(("table", table))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    response.take(0).map_err(|e| e.to_string())
}

async fn backfill_previews(db: &Surreal<Db>) -> Result<bool, String> {
    let metadata = rows(db, "meta").await?;
    if metadata
        .iter()
        .any(|row| row.key == "preview_v1" && row.payload == json!("1"))
    {
        return Ok(false);
    }
    if !metadata
        .iter()
        .any(|row| row.key == "initialized" && row.payload == json!("1"))
    {
        return Ok(false);
    }
    let records: HashSet<String> = rows(db, "recording")
        .await?
        .into_iter()
        .map(|row| row.key)
        .collect();
    for table in ["version", "publication"] {
        for key in child_keys(db, table).await? {
            if !records.contains(&key.parent) {
                return Err(format!("SurrealDB contiene {table} huérfana"));
            }
            let row = row_by_key(db, table, &key.key)
                .await?
                .ok_or("Fila de biblioteca desaparecida")?;
            let preview = preview_for(table, &row.payload)?;
            let id_field = if table == "version" {
                "id"
            } else {
                "destinationId"
            };
            let id = preview[id_field]
                .as_str()
                .ok_or_else(|| format!("{table} sin {id_field}"))?;
            let expected_key =
                serde_json::to_string(&[key.parent.as_str(), id]).map_err(|e| e.to_string())?;
            if row.parent != key.parent || key.key != expected_key {
                return Err(format!("Identidad de {table} incoherente"));
            }
            let preview_table = format!("{table}_preview");
            db.query("UPSERT type::record($table, $key) SET key = $key, parent = $parent, position = $position, payload = $payload")
                .bind(("table", preview_table))
                .bind(("key", key.key.as_str()))
                .bind(("parent", key.parent.as_str()))
                .bind(("position", row.position))
                .bind(("payload", preview))
                .await
                .map_err(|e| e.to_string())?
                .check()
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(true)
}

pub(super) fn preview_for(table: &str, payload: &Value) -> Result<Value, String> {
    match table {
        "version" => crate::library_view::light_version(payload),
        "publication" => {
            if !payload.is_object() || payload["destinationId"].as_str().is_none() {
                return Err("Recibo guardado inválido".into());
            }
            Ok(crate::library_view::light_publication(payload))
        }
        _ => Err("Tabla sin proyección".into()),
    }
}

pub(super) async fn load_index(db: &Surreal<Db>) -> Result<Option<Value>, String> {
    let metadata = rows(db, "meta").await?;
    if !metadata
        .iter()
        .any(|row| row.key == "initialized" && row.payload == json!("1"))
    {
        for table in table_names()
            .into_iter()
            .chain(["version_preview", "publication_preview"])
        {
            if !rows(db, table).await?.is_empty() {
                return Err("SurrealDB contiene datos sin marca de migración completa".into());
            }
        }
        return Ok(None);
    }
    if !metadata
        .iter()
        .any(|row| row.key == "schema" && row.payload == json!("2"))
    {
        return Err("Versión de esquema SurrealDB incompatible".into());
    }
    let needs_preview_mark = backfill_previews(db).await?;
    let mut data = json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"providers":[],"settings":{}});
    let mut parents = HashSet::new();
    for table in [
        "recording",
        "account",
        "resolver",
        "recipe",
        "destination",
        "provider",
        "setting",
    ] {
        let mut items = rows(db, table).await?;
        if table == "recording" {
            order_recordings(&mut items);
        } else {
            items.sort_by_key(|row| row.position);
        }
        for row in items {
            if table == "setting" {
                data["settings"][&row.key] = row.payload;
                continue;
            }
            let field = match table {
                "recording" => "recordings",
                "account" => "accounts",
                "resolver" => "resolvers",
                "recipe" => "recipes",
                "destination" => "destinations",
                "provider" => "providers",
                _ => return Err(format!("Tabla inesperada: {table}")),
            };
            let mut item = row.payload;
            if table == "recording" {
                if item["id"] != row.key {
                    return Err("Grabación guardada inválida".into());
                }
                parents.insert(row.key);
                item["versions"] = json!([]);
                item["publications"] = json!([]);
            }
            data[field]
                .as_array_mut()
                .ok_or("Biblioteca inválida")?
                .push(item);
        }
    }
    type OrderedRows = Vec<(i64, Value)>;
    type OrderedChildren = (OrderedRows, OrderedRows);
    let mut children: HashMap<String, OrderedChildren> = HashMap::new();
    for (table, preview_table) in [
        ("version", "version_preview"),
        ("publication", "publication_preview"),
    ] {
        for row in rows(db, preview_table).await? {
            if !parents.contains(&row.parent) {
                return Err(format!("SurrealDB contiene {table} huérfana"));
            }
            if !row.payload.is_object() {
                return Err(format!("Proyección de {table} inválida"));
            }
            let id = if table == "version" {
                "id"
            } else {
                "destinationId"
            };
            let child_id = row.payload[id]
                .as_str()
                .ok_or_else(|| format!("Proyección de {table} sin {id}"))?;
            let expected_key = serde_json::to_string(&[row.parent.as_str(), child_id])
                .map_err(|e| e.to_string())?;
            if row.key != expected_key {
                return Err(format!("Identidad de {table} incoherente"));
            }
            let entry = children.entry(row.parent).or_default();
            if table == "version" {
                entry.0.push((row.position, row.payload));
            } else {
                entry.1.push((row.position, row.payload));
            }
        }
    }
    for record in data["recordings"]
        .as_array_mut()
        .ok_or("Biblioteca inválida")?
    {
        let id = record["id"].as_str().ok_or("Grabación sin ID")?;
        if let Some((mut versions, mut publications)) = children.remove(id) {
            versions.sort_by_key(|(position, _)| *position);
            publications.sort_by_key(|(position, _)| *position);
            record["versions"] =
                Value::Array(versions.into_iter().map(|(_, value)| value).collect());
            record["publications"] =
                Value::Array(publications.into_iter().map(|(_, value)| value).collect());
        }
    }
    crate::store::LibraryData::read(&data)?;
    if needs_preview_mark {
        db.query("UPSERT meta:preview_v1 SET key = 'preview_v1', parent = '', position = 0, payload = '1'")
            .await.map_err(|e| e.to_string())?.check().map_err(|e| e.to_string())?;
    }
    Ok(Some(data))
}

pub(super) async fn recording(db: &Surreal<Db>, id: &str) -> Result<Option<Value>, String> {
    let Some(row) = row_by_key(db, "recording", id).await? else {
        return Ok(None);
    };
    let mut value = row.payload;
    if value["id"] != id {
        return Err("Grabación guardada inválida".into());
    }
    for (table, field) in [("version", "versions"), ("publication", "publications")] {
        let mut children = rows_for_parent(db, table, id).await?;
        let mut previews = rows_for_parent(db, &format!("{table}_preview"), id).await?;
        children.sort_by_key(|row| row.position);
        previews.sort_by_key(|row| row.position);
        let id_field = if table == "version" {
            "id"
        } else {
            "destinationId"
        };
        if children.len() != previews.len()
            || children.iter().zip(&previews).any(|(full, preview)| {
                full.key != preview.key
                    || full.position != preview.position
                    || full.payload[id_field] != preview.payload[id_field]
            })
        {
            return Err(format!("{table} y su proyección no coinciden"));
        }
        if value["status"] == "discarded" {
            if !children.is_empty() {
                return Err("Lápida con versiones o recibos".into());
            }
        } else {
            value[field] = Value::Array(children.into_iter().map(|row| row.payload).collect());
        }
    }
    let _: crate::store::Recording =
        serde_json::from_value(value.clone()).map_err(|_| "Grabación guardada inválida")?;
    Ok(Some(value))
}
