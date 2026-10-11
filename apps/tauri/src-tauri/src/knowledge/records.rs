use super::*;
use sha2::{Digest, Sha256};
use surrealdb::types::{RecordId, ToSql};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Source {
    pub recording_id: String,
    pub version_id: String,
    #[serde(default)]
    pub recipe_id: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphRecord {
    pub id: String,
    pub ontology_id: String,
    pub table: String,
    pub values: Value,
    pub rev: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordPage {
    pub records: Vec<GraphRecord>,
    pub page: u32,
    pub has_more: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveRecord {
    pub ontology_id: String,
    pub expected_version: u32,
    pub table: String,
    pub record_id: Option<String>,
    pub expected_rev: Option<String>,
    pub values: Value,
    #[serde(default)]
    pub source: Option<Source>,
}
fn record_id(value: &str, table: Option<&str>) -> Result<RecordId, String> {
    let id = match surrealdb_core::syn::value(value).map_err(error)? {
        DbValue::RecordId(id) => id,
        _ => return Err("Se requiere un identificador de registro".into()),
    };
    identifier(id.table.as_str())?;
    if table.is_some_and(|table| table != id.table.as_str()) {
        return Err("El registro no pertenece a la colección".into());
    }
    Ok(id)
}
fn writable(id: &str) -> Result<(), String> {
    if id == "escriba" {
        Err(
            "La ontología base es de solo lectura; edita sus datos desde la biblioteca o Personas"
                .into(),
        )
    } else {
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BaseReference {
    ontology_id: String,
    table: String,
    id: String,
}
fn reference(value: &Value, target: &ReferenceTarget) -> Result<RecordId, String> {
    let reference: BaseReference =
        serde_json::from_value(value.clone()).map_err(|_| "Referencia a la base inválida")?;
    if reference.ontology_id != target.ontology_id || reference.table != target.table {
        return Err("La referencia no pertenece a la colección declarada".into());
    }
    record_id(&reference.id, Some(&target.table))
}
fn graph_record(ontology_id: &str, row: DbValue) -> Result<GraphRecord, String> {
    let DbValue::Object(mut object) = row.clone() else {
        return Err("Registro inválido".into());
    };
    let Some(DbValue::RecordId(id)) = object.remove("id") else {
        return Err("Registro sin identidad".into());
    };
    let bytes = surrealdb_core::rpc::format::cbor::encode(row).map_err(error)?;
    Ok(GraphRecord {
        id: id.to_sql(),
        ontology_id: ontology_id.into(),
        table: id.table.to_string(),
        values: DbValue::Object(object).into_json_value(),
        rev: format!("{:x}", Sha256::digest(bytes)),
    })
}
async fn collection(
    db: &Surreal<Db>,
    table: &str,
    expected_version: Option<u32>,
) -> Result<Collection, String> {
    let manifest = manifest(db).await?.ok_or("Ontología no instalada")?;
    if expected_version.is_some_and(|v| v != manifest.version) {
        return Err("La ontología cambió de versión; recarga la colección".into());
    }
    manifest
        .collections
        .into_iter()
        .find(|c| c.table == table)
        .ok_or("Colección no declarada".into())
}
async fn current(db: &Surreal<Db>, id: &RecordId) -> Result<Option<DbValue>, String> {
    let mut rows = db
        .query("SELECT * FROM $id")
        .bind(("id", id.clone()))
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    let rows: Vec<DbValue> = rows.take(0).map_err(error)?;
    Ok(rows.into_iter().next())
}
fn source_id(record: &RecordId, source: &Source) -> String {
    format!(
        "{:x}",
        Sha256::digest(format!(
            "{}\0{}\0{}",
            record.to_sql(),
            source.recording_id,
            source.version_id
        ))
    )
}
impl Knowledge {
    pub async fn records(
        &self,
        id: &str,
        table: &str,
        page: u32,
        recording_id: Option<&str>,
        version_id: Option<&str>,
    ) -> Result<RecordPage, String> {
        let root = &self.root;
        let db = selected(root, id).await?;
        collection(&db, table, None).await?;
        let mut response = db.query("SELECT * FROM type::table($table) WHERE ($recording = NONE OR ($base AND recordingId=$recording AND ($version=NONE OR versionId=$version)) OR (!$base AND id IN (SELECT VALUE record FROM _escriba_source WHERE recordingId = $recording AND ($version = NONE OR versionId = $version)))) ORDER BY id LIMIT 51 START $offset")
            .bind(("base",id=="escriba"))
            .bind(("table",table.to_string())).bind(("recording",recording_id.map(str::to_string))).bind(("version",version_id.map(str::to_string))).bind(("offset",u64::from(page)*50)).await.map_err(error)?.check().map_err(error)?;
        let mut rows: Vec<DbValue> = response.take(0).map_err(error)?;
        let has_more = rows.len() > 50;
        rows.truncate(50);
        Ok(RecordPage {
            records: rows
                .into_iter()
                .map(|r| graph_record(id, r))
                .collect::<Result<_, _>>()?,
            page,
            has_more,
        })
    }
    pub async fn save(&self, request: SaveRecord) -> Result<GraphRecord, String> {
        writable(&request.ontology_id)?;
        let root = &self.root;
        let db = selected(root, &request.ontology_id).await?;
        let collection = collection(&db, &request.table, Some(request.expected_version)).await?;
        let id = match &request.record_id {
            Some(id) => record_id(id, Some(&request.table))?,
            None => RecordId::new(request.table.clone(), Uuid::new_v4().to_string()),
        };
        let before = current(&db, &id).await?;
        match (&before, &request.expected_rev, &request.record_id) {
            (Some(row), Some(rev), _)
                if graph_record(&request.ontology_id, row.clone())?.rev == *rev => {}
            (None, None, None) => {}
            _ => return Err("Conflicto: el registro cambió; recarga antes de guardar".into()),
        }
        let Value::Object(input) = request.values else {
            return Err("Los valores deben ser un objeto".into());
        };
        let mut fields = surrealdb::types::Object::new();
        for definition in &collection.fields {
            if !input.contains_key(&definition.key) {
                if definition.required {
                    return Err(format!("El campo {} es obligatorio", definition.label));
                }
                fields.insert(definition.key.clone(), DbValue::None);
            }
        }
        for (key, value) in input {
            let definition = collection.fields.iter().find(|f| f.key == key);
            if let Some(definition) = definition {
                if value.is_null() && definition.required {
                    return Err(format!("El campo {} es obligatorio", definition.label));
                }
                let valid = value.is_null()
                    || match definition.kind {
                        FieldType::Text | FieldType::Date => value.is_string(),
                        FieldType::Number => value.is_number(),
                        FieldType::Boolean => value.is_boolean(),
                        FieldType::Json => true,
                        FieldType::Reference => value.is_object(),
                    };
                if !valid {
                    return Err(format!("Tipo inválido para {}", definition.label));
                }
                if definition.kind == FieldType::Reference && !value.is_null() {
                    let target = definition
                        .reference
                        .as_ref()
                        .ok_or("Referencia sin destino")?;
                    let target_id = reference(&value, target)?;
                    let unchanged = before.as_ref().is_some_and(|before| {
                        before.clone().into_json_value().get(&key) == Some(&value)
                    });
                    if !unchanged
                        && current(&selected(root, "escriba").await?, &target_id)
                            .await?
                            .is_none()
                    {
                        return Err("La entidad base ya no existe; elige otra referencia".into());
                    }
                }
                let native = if value.is_null() {
                    if definition.kind == FieldType::Json {
                        DbValue::Null
                    } else {
                        DbValue::None
                    }
                } else if definition.kind == FieldType::Date {
                    let date = chrono::DateTime::parse_from_rfc3339(
                        value.as_str().ok_or("Fecha inválida")?,
                    )
                    .map_err(error)?
                    .with_timezone(&chrono::Utc);
                    DbValue::Datetime(date.into())
                } else {
                    value.into_value()
                };
                fields.insert(key, native);
            } else if let Some(relation) = collection
                .relation
                .as_ref()
                .filter(|_| key == "in" || key == "out")
            {
                let endpoint = record_id(
                    value.as_str().ok_or("Extremo de relación inválido")?,
                    Some(if key == "in" {
                        &relation.from
                    } else {
                        &relation.to
                    }),
                )?;
                fields.insert(key, DbValue::RecordId(endpoint));
            } else {
                return Err(format!("Campo no editable: {key}"));
            }
        }
        let tx = db.clone().begin().await.map_err(error)?;
        let outcome:Result<GraphRecord,String>=async {
            let sql=if collection.relation.is_some() && before.is_none() {"RELATE ($data.in)->$id->($data.out) CONTENT $data RETURN AFTER"} else {"UPSERT $id MERGE $data RETURN AFTER"};
            let mut response=tx.query(sql).bind(("id",id.clone())).bind(("data",DbValue::Object(fields))).await.map_err(error)?.check().map_err(error)?;
            let rows:Vec<DbValue>=response.take(0).map_err(error)?;
            let row=rows.into_iter().next().ok_or("No se guardó el registro")?;
            tx.query("UPSERT type::record('_escriba_manual',$key) SET record=$record").bind(("key",id.to_sql())).bind(("record",id.clone())).await.map_err(error)?.check().map_err(error)?;
            if let Some(source)=request.source {
                tx.query("UPSERT type::record('_escriba_source',$key) SET record=$record, recordingId=$recording, versionId=$version, recipeId=$recipe ?? recipeId")
                    .bind(("key",source_id(&id,&source))).bind(("record",id)).bind(("recording",source.recording_id)).bind(("version",source.version_id)).bind(("recipe",source.recipe_id)).await.map_err(error)?.check().map_err(error)?;
            }
            graph_record(&request.ontology_id,row)
        }.await;
        match outcome {
            Ok(row) => {
                tx.commit().await.map_err(error)?;
                Ok(row)
            }
            Err(e) => {
                tx.cancel().await.map_err(error)?;
                Err(e)
            }
        }
    }
    pub async fn delete(
        &self,
        ontology_id: &str,
        expected_version: u32,
        table: &str,
        id: &str,
        expected_rev: &str,
    ) -> Result<(), String> {
        writable(ontology_id)?;
        let root = &self.root;
        let db = selected(root, ontology_id).await?;
        collection(&db, table, Some(expected_version)).await?;
        let id = record_id(id, Some(table))?;
        let row = current(&db, &id).await?.ok_or("El registro ya no existe")?;
        if graph_record(ontology_id, row)?.rev != expected_rev {
            return Err("Conflicto: el registro cambió; recarga antes de borrar".into());
        }
        db.query("BEGIN; DELETE $id; DELETE _escriba_source WHERE record=$id; DELETE _escriba_manual WHERE record=$id; COMMIT;")
            .bind(("id", id))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        Ok(())
    }
    pub async fn link(
        &self,
        ontology_id: &str,
        expected_version: u32,
        id: &str,
        source: Source,
    ) -> Result<(), String> {
        writable(ontology_id)?;
        let root = &self.root;
        let db = selected(root, ontology_id).await?;
        let id = record_id(id, None)?;
        let manifest = manifest(&db).await?.ok_or("Ontología no instalada")?;
        if expected_version != manifest.version {
            return Err("La ontología cambió de versión".into());
        }
        if !manifest
            .collections
            .iter()
            .any(|collection| collection.table == id.table.as_str())
        {
            return Err(format!("Declara la presentación de la tabla «{}» en collections antes de vincular sus registros",id.table));
        }
        if current(&db, &id).await?.is_none() {
            return Err("El registro no existe".into());
        }
        db.query("UPSERT type::record('_escriba_source',$key) SET record=$record, recordingId=$recording, versionId=$version, recipeId=$recipe ?? recipeId")
            .bind(("key",source_id(&id,&source))).bind(("record",id)).bind(("recording",source.recording_id)).bind(("version",source.version_id)).bind(("recipe",source.recipe_id)).await.map_err(error)?.check().map_err(error)?;
        Ok(())
    }
}

impl Knowledge {
    pub async fn unlink(
        &self,
        ontology_id: &str,
        expected_version: u32,
        id: &str,
        recording_id: &str,
    ) -> Result<(), String> {
        writable(ontology_id)?;
        let root = &self.root;
        let db = selected(root, ontology_id).await?;
        let id = record_id(id, None)?;
        let manifest = manifest(&db).await?.ok_or("Ontología no instalada")?;
        if expected_version != manifest.version {
            return Err("La ontología cambió de versión".into());
        }
        db.query("DELETE _escriba_source WHERE record=$record AND recordingId=$recording")
            .bind(("record", id))
            .bind(("recording", recording_id.to_string()))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        Ok(())
    }
}
