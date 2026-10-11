use super::*;
use serde_json::json;
use surrealdb::types::{RecordId, ToSql};

const PAGE_SIZE: usize = 40;
#[derive(Debug, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct GraphDetail {
    pub id: String,
    pub ontology_id: String,
    pub table: String,
    #[ts(type = "Record<string, unknown>")]
    pub values: Value,
    pub rev: String,
    pub truncated_fields: Vec<String>,
}
#[derive(Clone, Debug, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct GraphNode {
    pub key: String,
    pub ontology_id: String,
    pub table: String,
    pub record_id: String,
    pub label: String,
    pub missing: bool,
}
#[derive(Clone, Debug, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct GraphEdge {
    pub key: String,
    pub source: String,
    pub target: String,
    pub label: String,
    pub kind: EdgeKind,
    pub ontology_id: String,
    pub table: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub record_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub field: Option<String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, TS)]
#[serde(rename_all = "lowercase")]
pub enum EdgeKind {
    Relation,
    Reference,
    Provenance,
}
#[derive(Debug, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct GraphPage {
    pub nodes: Vec<GraphNode>,
    pub edges: Vec<GraphEdge>,
    pub page: u32,
    pub has_more: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub root: Option<String>,
}
fn parse(value: &str) -> Result<RecordId, String> {
    if value.len() > 4096 {
        return Err("Identidad demasiado larga".into());
    }
    let DbValue::RecordId(id) = surrealdb_core::syn::value(value).map_err(error)? else {
        return Err("Se requiere un identificador de registro".into());
    };
    identifier(id.table.as_str())?;
    Ok(id)
}
fn key(ontology: &str, id: &RecordId) -> String {
    json!([ontology, id.to_sql()]).to_string()
}
async fn declared(db: &Surreal<Db>, table: &str) -> Result<Collection, String> {
    identifier(table)?;
    manifest(db)
        .await?
        .ok_or("Ontología no instalada")?
        .collections
        .into_iter()
        .find(|c| c.table == table)
        .ok_or("Colección no declarada".into())
}
fn row_id(row: &DbValue, field: &str) -> Result<RecordId, String> {
    if let DbValue::Object(object) = row {
        if let Some(DbValue::RecordId(id)) = object.get(field) {
            return Ok(id.clone());
        }
    }
    Err(format!("Registro sin identidad {field}"))
}
async fn rows(db: &Surreal<Db>, sql: String, bindings: Value) -> Result<Vec<DbValue>, String> {
    let mut result = db
        .query(sql)
        .bind(bindings)
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    result.take(0).map_err(error)
}
fn node(ontology: &str, id: &RecordId, row: Option<&DbValue>) -> GraphNode {
    let mut label = row
        .and_then(|r| {
            r.clone().into_json_value()["label"]
                .as_str()
                .map(str::to_owned)
        })
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| id.to_sql().chars().take(120).collect());
    if label.chars().count() > 120 {
        label = label.chars().take(120).collect::<String>() + "…";
    }
    GraphNode {
        key: key(ontology, id),
        ontology_id: ontology.into(),
        table: id.table.to_string(),
        record_id: id.to_sql(),
        label,
        missing: row.is_none(),
    }
}
fn title(collection: &Collection) -> String {
    format!(
        "string::slice(<string>(`{}` ?? ''), 0, 121) AS label",
        collection.title_field
    )
}
impl Knowledge {
    pub async fn graph_roots(
        &self,
        ontology: &str,
        table: &str,
        page: u32,
    ) -> Result<GraphPage, String> {
        let root = &self.root;
        let db = selected(root, ontology).await?;
        let collection = declared(&db, table).await?;
        let endpoints = if collection.relation.is_some() {
            "in,out,"
        } else {
            ""
        };
        let mut found = rows(&db, format!("SELECT id, {endpoints} {} FROM type::table($table) ORDER BY id LIMIT 41 START $offset",title(&collection)),json!({"table":table,"offset":u64::from(page)*40})).await?;
        let has_more = found.len() > PAGE_SIZE;
        found.truncate(PAGE_SIZE);
        let mut result = GraphPage {
            nodes: vec![],
            edges: vec![],
            page,
            has_more,
            root: None,
        };
        if collection.relation.is_some() {
            for row in found {
                add_relation(root, ontology, &collection, &row, &mut result).await?;
            }
        } else {
            result.nodes = found
                .iter()
                .map(|r| Ok(node(ontology, &row_id(r, "id")?, Some(r))))
                .collect::<Result<_, String>>()?;
        }
        Ok(result)
    }
    pub async fn graph_detail(&self, ontology: &str, record: &str) -> Result<GraphDetail, String> {
        let id = parse(record)?;
        let root = &self.root;
        let db = selected(root, ontology).await?;
        let collection = declared(&db, id.table.as_str()).await?;
        if collection.fields.len() > 128 {
            return Err("El detalle admite hasta 128 campos declarados".into());
        }
        let mut fields = vec!["id".to_string()];
        for field in &collection.fields {
            fields.push(format!("IF string::len(<string>(`{0}` ?? '')) > 2000 THEN string::slice(<string>`{0}`,0,2000) ELSE `{0}` END AS `{0}`",field.key));
            fields.push(format!(
                "string::len(<string>(`{0}` ?? '')) > 2000 AS `__truncated_{0}`",
                field.key
            ));
        }
        if collection.relation.is_some() {
            fields.extend(["in".into(), "out".into()]);
        }
        let mut response = db
            .query(format!("SELECT {} FROM $id", fields.join(",")))
            .bind(("id", id.clone()))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let rows: Vec<DbValue> = response.take(0).map_err(error)?;
        let mut value = rows
            .into_iter()
            .next()
            .ok_or("El registro ya no existe")?
            .into_json_value();
        value
            .as_object_mut()
            .ok_or("Registro inválido")?
            .remove("id");
        let mut truncated_fields = vec![];
        let object = value.as_object_mut().ok_or("Registro inválido")?;
        for field in &collection.fields {
            if object.remove(&format!("__truncated_{}", field.key)) == Some(Value::Bool(true)) {
                truncated_fields.push(field.key.clone());
            }
        }
        Ok(GraphDetail {
            id: id.to_sql(),
            ontology_id: ontology.into(),
            table: id.table.to_string(),
            values: value,
            rev: String::new(),
            truncated_fields,
        })
    }
}

async fn add_node(
    root: &Surreal<Db>,
    ontology: &str,
    id: &RecordId,
    page: &mut GraphPage,
) -> Result<String, String> {
    let identity = key(ontology, id);
    if page.nodes.iter().any(|n| n.key == identity) {
        return Ok(identity);
    }
    let db = selected(root, ontology).await?;
    let collection = declared(&db, id.table.as_str()).await?;
    let found = rows(
        &db,
        format!(
            "SELECT id, {} FROM type::record($record)",
            title(&collection)
        ),
        json!({"record":id.to_sql()}),
    )
    .await?;
    page.nodes.push(node(ontology, id, found.first()));
    Ok(identity)
}
async fn add_relation(
    root: &Surreal<Db>,
    ontology: &str,
    collection: &Collection,
    row: &DbValue,
    page: &mut GraphPage,
) -> Result<(), String> {
    let id = row_id(row, "id")?;
    let from = row_id(row, "in")?;
    let to = row_id(row, "out")?;
    let relation = collection.relation.as_ref().ok_or("No es una relación")?;
    if from.table.as_str() != relation.from || to.table.as_str() != relation.to {
        return Err("Extremos de relación incompatibles con la declaración".into());
    }
    let source = add_node(root, ontology, &from, page).await?;
    let target = add_node(root, ontology, &to, page).await?;
    page.edges.push(GraphEdge {
        key: key(ontology, &id),
        source,
        target,
        label: collection.label.clone(),
        kind: EdgeKind::Relation,
        ontology_id: ontology.into(),
        table: collection.table.clone(),
        record_id: Some(id.to_sql()),
        field: None,
    });
    Ok(())
}
enum Connection {
    Relation,
    Reference(Field),
    Provenance,
}
struct Group {
    ontology: String,
    collection: Collection,
    filter: String,
    connection: Connection,
}
async fn add_provenance(
    root: &Surreal<Db>,
    ontology: &str,
    row: &DbValue,
    page: &mut GraphPage,
) -> Result<(), String> {
    let id = row_id(row, "record")?;
    let value = row.clone().into_json_value();
    let recording = value["recordingId"]
        .as_str()
        .ok_or("Vínculo sin grabación")?;
    let version = value["versionId"].as_str().ok_or("Vínculo sin versión")?;
    let destination = RecordId::new(
        "version",
        surrealdb::types::RecordIdKey::Array(
            vec![recording.into_value(), version.into_value()].into(),
        ),
    );
    let source = add_node(root, ontology, &id, page).await?;
    let target = add_node(root, "escriba", &destination, page).await?;
    page.edges.push(GraphEdge {
        key: json!(["provenance", ontology, id.to_sql(), recording, version]).to_string(),
        source,
        target,
        label: "Procedencia".into(),
        kind: EdgeKind::Provenance,
        ontology_id: ontology.into(),
        table: id.table.to_string(),
        record_id: Some(id.to_sql()),
        field: None,
    });
    Ok(())
}
async fn add_reference(
    root: &Surreal<Db>,
    ontology: &str,
    collection: &Collection,
    field: &Field,
    row: &DbValue,
    page: &mut GraphPage,
) -> Result<(), String> {
    let id = row_id(row, "id")?;
    let target = field.reference.as_ref().ok_or("Referencia sin destino")?;
    let value = row.clone().into_json_value();
    let reference = &value[&field.key];
    if reference["ontologyId"] != target.ontology_id || reference["table"] != target.table {
        return Err("Referencia incompatible con su declaración".into());
    }
    let destination = parse(reference["id"].as_str().ok_or("Referencia sin identidad")?)?;
    if destination.table.as_str() != target.table {
        return Err("Referencia a una colección distinta".into());
    }
    let source = add_node(root, ontology, &id, page).await?;
    let target_key = add_node(root, &target.ontology_id, &destination, page).await?;
    page.edges.push(GraphEdge {
        key: json!(["reference", ontology, id.to_sql(), field.key]).to_string(),
        source,
        target: target_key,
        label: field.label.clone(),
        kind: EdgeKind::Reference,
        ontology_id: ontology.into(),
        table: collection.table.clone(),
        record_id: Some(id.to_sql()),
        field: Some(field.key.clone()),
    });
    Ok(())
}
impl Knowledge {
    pub async fn graph_expand(
        &self,
        ontology: &str,
        record: &str,
        page: u32,
    ) -> Result<GraphPage, String> {
        let id = parse(record)?;
        let root = &self.root;
        let mut listed = root
            .query("SELECT VALUE ontology_id FROM ontology ORDER BY ontology_id LIMIT 129")
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        let ids: Vec<String> = listed.take(0).map_err(error)?;
        if ids.len() > 128 {
            return Err("La exploración admite hasta 128 ontologías instaladas".into());
        }
        let mut catalog = vec![base_definition()];
        for installed in ids {
            catalog.push(
                manifest(&selected(root, &installed).await?)
                    .await?
                    .ok_or("Ontología instalada sin definición")?,
            );
        }
        let db = selected(root, ontology).await?;
        declared(&db, id.table.as_str()).await?;
        let definition = manifest(&db).await?.ok_or("Ontología no instalada")?;
        let mut groups = vec![];
        for collection in definition.collections {
            if collection
                .relation
                .as_ref()
                .is_some_and(|r| r.from == id.table.as_str() || r.to == id.table.as_str())
            {
                groups.push(Group {
                    ontology: ontology.into(),
                    collection,
                    filter: "in=type::record($record) OR out=type::record($record)".into(),
                    connection: Connection::Relation,
                });
            }
        }
        for definition in catalog {
            if definition.id != "escriba"
                && (definition.id == ontology
                    || (ontology == "escriba" && id.table.as_str() == "version"))
            {
                groups.push(Group {
                    ontology: definition.id.clone(),
                    collection: Collection {
                        table: "_escriba_source".into(),
                        label: String::new(),
                        title_field: String::new(),
                        fields: vec![],
                        relation: None,
                    },
                    filter: if definition.id == ontology {
                        "record=type::record($record)".into()
                    } else {
                        "type::record('version',[recordingId,versionId])=type::record($record)"
                            .into()
                    },
                    connection: Connection::Provenance,
                });
            }
            for collection in definition.collections {
                for field in &collection.fields {
                    let Some(target) = &field.reference else {
                        continue;
                    };
                    let forward =
                        definition.id == ontology && collection.table == id.table.as_str();
                    let reverse =
                        target.ontology_id == ontology && target.table == id.table.as_str();
                    if !forward && !reverse {
                        continue;
                    }
                    let filter = if forward {
                        format!(
                            "id=type::record($record) AND `{}` != NONE AND `{}` != NULL",
                            field.key, field.key
                        )
                    } else {
                        format!("`{0}`.ontologyId=$ontology AND `{0}`.table=$recordTable AND type::record(`{0}`.id)=type::record($record)",field.key)
                    };
                    groups.push(Group {
                        ontology: definition.id.clone(),
                        collection: collection.clone(),
                        filter,
                        connection: Connection::Reference(field.clone()),
                    });
                }
            }
        }
        if groups.len() > 512 {
            return Err(
                "Demasiadas conexiones declaradas para una consulta de grafo (máximo 512)".into(),
            );
        }
        let mut result = GraphPage {
            nodes: vec![],
            edges: vec![],
            page,
            has_more: false,
            root: Some(key(ontology, &id)),
        };
        add_node(root, ontology, &id, &mut result).await?;
        let mut offset = u64::from(page) * 40;
        for group in groups {
            let db = selected(root, &group.ontology).await?;
            let bindings = json!({"table":group.collection.table,"record":id.to_sql(),"offset":offset,"limit":41-result.edges.len(),"ontology":ontology,"recordTable":id.table.as_str()});
            if offset > 0 {
                let count = rows(
                    &db,
                    format!(
                        "SELECT count() AS total FROM type::table($table) WHERE {} GROUP ALL",
                        group.filter
                    ),
                    bindings.clone(),
                )
                .await?;
                let count = count
                    .first()
                    .map(|r| r.clone().into_json_value()["total"].as_u64().unwrap_or(0))
                    .unwrap_or(0);
                if offset >= count {
                    offset -= count;
                    continue;
                }
            }
            let projection = match &group.connection {
                Connection::Relation => "id,in,out".into(),
                Connection::Reference(field) => {
                    format!("id, `{0}`.{{ontologyId,table,id}} AS `{0}`", field.key)
                }
                Connection::Provenance => "id,record,recordingId,versionId".into(),
            };
            let found = rows(&db,format!("SELECT {projection} FROM type::table($table) WHERE {} ORDER BY id LIMIT $limit START $offset",group.filter),bindings).await?;
            offset = 0;
            for row in found {
                if result.edges.len() == PAGE_SIZE {
                    result.has_more = true;
                    return Ok(result);
                }
                match &group.connection {
                    Connection::Relation => {
                        add_relation(root, &group.ontology, &group.collection, &row, &mut result)
                            .await?
                    }
                    Connection::Reference(field) => {
                        add_reference(
                            root,
                            &group.ontology,
                            &group.collection,
                            field,
                            &row,
                            &mut result,
                        )
                        .await?
                    }
                    Connection::Provenance => {
                        add_provenance(root, &group.ontology, &row, &mut result).await?
                    }
                }
            }
        }
        Ok(result)
    }
}
