use super::*;
use std::collections::{BTreeMap, BTreeSet};
use surrealdb::types::{Object, RecordId};

const MAX_RESULTS: usize = 10_000;
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilterCondition {
    pub ontology_id: String,
    pub table: String,
    pub field: String,
    pub operator: FilterOperator,
    #[serde(default)]
    pub value: Value,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum FilterOperator {
    Eq,
    Ne,
    Contains,
    StartsWith,
    Gt,
    Gte,
    Lt,
    Lte,
    Empty,
    NotEmpty,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum FilterMatch {
    All,
    Any,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum LibraryFilter {
    Visual {
        r#match: FilterMatch,
        conditions: Vec<FilterCondition>,
    },
    Surrealql {
        #[serde(rename = "ontologyId")]
        ontology_id: String,
        sql: String,
    },
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FilterResult {
    pub recording_ids: Vec<String>,
}

impl Knowledge {
    pub async fn filter_notes(&self, filter: LibraryFilter) -> Result<FilterResult, String> {
        tokio::time::timeout(Duration::from_secs(10), self.run_filter(filter))
            .await
            .map_err(|_| "El filtro superó el límite de 10 segundos".to_string())?
    }
    async fn run_filter(&self, filter: LibraryFilter) -> Result<FilterResult, String> {
        let root = &self.root;
        let result = match filter {
            LibraryFilter::Surrealql { ontology_id, sql } => {
                if sql.trim().is_empty() || sql.len() > 1_000_000 {
                    return Err("Consulta vacía o demasiado grande".into());
                }
                base_query::validate(&sql)?;
                let db = selected(root, &ontology_id).await?;
                let definition = manifest(&db).await?.ok_or("Ontología no instalada")?;
                let session = runtime(root, &ontology_id).await?;
                let mut results = discarded_read(&session, &sql).await?;
                check_size(&results)?;
                let mut identities = BTreeMap::<String, Vec<RecordId>>::new();
                let last = results
                    .pop()
                    .ok_or("La consulta no devuelve un resultado")?;
                collect_ids(last, &ontology_id, &mut identities, 0)?;
                let mut result = BTreeSet::new();
                for (ontology, ids) in identities {
                    if ontology == "escriba" {
                        result.extend(base_notes(root, ids).await?);
                    } else {
                        result.extend(extension_notes(root, &db, &definition, ids).await?);
                    }
                }
                result
            }
            LibraryFilter::Visual {
                r#match,
                conditions,
            } => {
                if conditions.is_empty() || conditions.len() > 32 {
                    return Err("El filtro necesita entre 1 y 32 condiciones".into());
                }
                let mut combined: Option<BTreeSet<String>> = None;
                for condition in conditions {
                    let db = selected(root, &condition.ontology_id).await?;
                    let definition = manifest(&db).await?.ok_or("Ontología no instalada")?;
                    let collection = declared(&definition, &condition.table)?;
                    let (predicate, value) = predicate(&condition, collection)?;
                    let session = runtime(root, &condition.ontology_id).await?;
                    let rows = query(
                        &session,
                        &format!(
                            "SELECT VALUE id FROM `{}` WHERE {predicate} LIMIT 10001",
                            condition.table
                        ),
                        bindings([("value", value)]),
                    )
                    .await?;
                    let ids = rows
                        .into_iter()
                        .map(native_id)
                        .collect::<Result<Vec<_>, _>>()?;
                    let found = if condition.ontology_id == "escriba" {
                        base_notes(root, ids).await?
                    } else {
                        extension_notes(root, &db, &definition, ids).await?
                    };
                    combined = Some(match combined {
                        None => found,
                        Some(previous) => match r#match {
                            FilterMatch::All => previous.intersection(&found).cloned().collect(),
                            FilterMatch::Any => previous.union(&found).cloned().collect(),
                        },
                    });
                }
                combined.unwrap_or_default()
            }
        };
        if result.len() > MAX_RESULTS {
            return Err("El filtro supera 10000 notas; concreta los criterios".into());
        }
        Ok(FilterResult {
            recording_ids: result.into_iter().collect(),
        })
    }
}
pub(super) async fn discarded_read(
    session: &Surreal<Db>,
    sql: &str,
) -> Result<Vec<DbValue>, String> {
    let tx = session.clone().begin().await.map_err(error)?;
    let outcome = match tx.query(sql.to_owned()).await {
        Ok(response) => values(response),
        Err(failure) => Err(error(failure)),
    };
    tx.cancel().await.map_err(error)?;
    outcome
}
fn bindings<const N: usize>(items: [(&str, DbValue); N]) -> DbValue {
    DbValue::Object(items.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}
struct ResultBudget(usize);
impl std::io::Write for ResultBudget {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 = self.0.checked_sub(bytes.len()).ok_or_else(|| {
            std::io::Error::other("El resultado del filtro supera 8 MiB; concreta los criterios")
        })?;
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
fn check_size(rows: &[DbValue]) -> Result<(), String> {
    if rows.len() > MAX_RESULTS {
        return Err(
            "El resultado del filtro supera 10000 entidades; concreta los criterios".into(),
        );
    }
    serde_json::to_writer(ResultBudget(8_388_608), rows).map_err(error)
}
async fn query(db: &Surreal<Db>, sql: &str, values: DbValue) -> Result<Vec<DbValue>, String> {
    let mut response = db
        .query(sql)
        .bind(values)
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    let rows: Vec<DbValue> = response.take(0).map_err(error)?;
    check_size(&rows)?;
    Ok(rows)
}
pub(super) fn declared<'a>(
    definition: &'a Ontology,
    table: &str,
) -> Result<&'a Collection, String> {
    identifier(table)?;
    definition
        .collections
        .iter()
        .find(|c| c.table == table)
        .ok_or_else(|| format!("Colección no declarada: {table}"))
}
fn native_id(value: DbValue) -> Result<RecordId, String> {
    let DbValue::RecordId(id) = value else {
        return Err("El resultado debe identificar una entidad".into());
    };
    identifier(id.table.as_str())?;
    Ok(id)
}
fn parse_id(value: &str) -> Result<RecordId, String> {
    if value.len() > 4096 {
        return Err("Identidad demasiado larga".into());
    }
    native_id(surrealdb_core::syn::value(value).map_err(error)?)
}
fn reference(value: DbValue) -> Result<RecordId, String> {
    let DbValue::Object(object) = value else {
        return Err("Referencia a Escriba inválida".into());
    };
    if object.get("ontologyId") != Some(&"escriba".into_value()) {
        return Err("Solo se admiten referencias a la base Escriba".into());
    }
    let Some(DbValue::String(id)) = object.get("id") else {
        return Err("Referencia sin identidad".into());
    };
    let id = parse_id(id)?;
    if object.get("table") != Some(&id.table.as_str().into_value())
        || base_definition()
            .collections
            .iter()
            .all(|c| c.table != id.table.as_str())
    {
        return Err("Referencia a colección base inválida".into());
    }
    Ok(id)
}
fn collect_ids(
    value: DbValue,
    ontology: &str,
    result: &mut BTreeMap<String, Vec<RecordId>>,
    depth: usize,
) -> Result<(), String> {
    if depth > 16 {
        return Err("Resultado excesivamente anidado".into());
    }
    match value {
        DbValue::None => return Err("La consulta no devuelve entidades".into()),
        DbValue::Array(values) => {
            for value in values {
                collect_ids(value, ontology, result, depth + 1)?;
            }
        }
        DbValue::Object(mut object) if matches!(object.get("id"), Some(DbValue::RecordId(_))) => {
            let id = native_id(
                object
                    .remove("id")
                    .ok_or("El resultado no identifica entidades")?,
            )?;
            result.entry(ontology.into()).or_default().push(id);
        }
        DbValue::Object(object) => result
            .entry("escriba".into())
            .or_default()
            .push(reference(DbValue::Object(object))?),
        value => result
            .entry(ontology.into())
            .or_default()
            .push(native_id(value)?),
    }
    if result.values().map(Vec::len).sum::<usize>() > MAX_RESULTS {
        return Err("El filtro supera 10000 entidades; concreta la consulta".into());
    }
    Ok(())
}
pub(super) fn predicate(
    condition: &FilterCondition,
    collection: &Collection,
) -> Result<(String, DbValue), String> {
    use FilterOperator::*;
    let identity_table = if condition.field == "id" {
        Some(collection.table.as_str())
    } else if condition.ontology_id == "escriba"
        && collection.table == "recording"
        && condition.field == "currentVersion"
    {
        Some("version")
    } else if let Some(relation) = &collection.relation {
        match condition.field.as_str() {
            "in" => Some(relation.from.as_str()),
            "out" => Some(relation.to.as_str()),
            _ => None,
        }
    } else {
        None
    };
    let definition = collection.fields.iter().find(|f| f.key == condition.field);
    if identity_table.is_none() && definition.is_none() {
        return Err(format!("Campo no declarado: {}", condition.field));
    }
    identifier(&condition.field)?;
    let mut field = format!("`{}`", condition.field);
    if matches!(condition.operator, Empty | NotEmpty) {
        let empty = format!("({field} = NONE OR {field} = NULL OR {field} = '' OR {field} = [])");
        return Ok((
            if matches!(condition.operator, NotEmpty) {
                format!("!{empty}")
            } else {
                empty
            },
            DbValue::None,
        ));
    }
    let value = if let Some(table) = identity_table {
        if !matches!(condition.operator, Eq | Ne) {
            return Err("Las identidades admiten igualdad o desigualdad".into());
        }
        let id = parse_id(condition.value.as_str().ok_or("Identidad inválida")?)?;
        if id.table.as_str() != table {
            return Err("La identidad pertenece a otra colección".into());
        }
        DbValue::RecordId(id)
    } else {
        let definition = definition.ok_or("Campo no declarado")?;
        let valid = match definition.kind {
            FieldType::Text | FieldType::Date => condition.value.is_string(),
            FieldType::Number => condition.value.is_number(),
            FieldType::Boolean => condition.value.is_boolean(),
            FieldType::Reference => condition.value.is_object(),
            FieldType::Json => true,
        };
        if !valid {
            return Err(format!("Valor incompatible con {}", definition.label));
        }
        if matches!(condition.operator, Contains)
            && !matches!(definition.kind, FieldType::Text | FieldType::Json)
        {
            return Err("Contiene requiere texto o un array JSON".into());
        }
        if matches!(condition.operator, StartsWith) && definition.kind != FieldType::Text {
            return Err("Empieza por requiere un campo de texto".into());
        }
        if matches!(condition.operator, Gt | Gte | Lt | Lte)
            && !matches!(definition.kind, FieldType::Number | FieldType::Date)
        {
            return Err("La comparación requiere un número o fecha".into());
        }
        if definition.kind == FieldType::Date {
            field = format!(
                "(IF {field} != NONE AND {field} != NULL THEN <datetime>{field} ELSE NONE END)"
            );
            let input = condition.value.as_str().ok_or("Fecha inválida")?;
            if input.len() == 10 {
                let day = chrono::NaiveDate::parse_from_str(input, "%Y-%m-%d").map_err(error)?;
                let start = day.and_hms_opt(0, 0, 0).ok_or("Fecha inválida")?.and_utc();
                let end = day
                    .succ_opt()
                    .ok_or("Fecha fuera de rango")?
                    .and_hms_opt(0, 0, 0)
                    .ok_or("Fecha inválida")?
                    .and_utc();
                let sql = match condition.operator {
                    Eq => format!("({field} >= $value.start AND {field} < $value.end)"),
                    Ne => format!("!({field} >= $value.start AND {field} < $value.end)"),
                    Gt => format!("{field} >= $value.end"),
                    Gte => format!("{field} >= $value.start"),
                    Lt => format!("{field} < $value.start"),
                    Lte => format!("{field} < $value.end"),
                    _ => return Err("Operador de fecha inválido".into()),
                };
                return Ok((
                    ordered_guard(&condition.operator, &field, sql),
                    bindings([
                        ("start", DbValue::Datetime(start.into())),
                        ("end", DbValue::Datetime(end.into())),
                    ]),
                ));
            }
            DbValue::Datetime(
                chrono::DateTime::parse_from_rfc3339(input)
                    .map_err(error)?
                    .with_timezone(&chrono::Utc)
                    .into(),
            )
        } else if definition.kind == FieldType::Reference {
            let id = reference(condition.value.clone().into_value())?;
            if !definition
                .reference
                .as_ref()
                .is_some_and(|r| r.ontology_id == "escriba" && r.table == id.table.as_str())
            {
                return Err("La referencia no corresponde al campo".into());
            }
            condition.value.clone().into_value()
        } else {
            condition.value.clone().into_value()
        }
    };
    let sql = match condition.operator {
        Eq => format!("{field} = $value"),
        Ne => format!("{field} != $value"),
        Contains if definition.is_some_and(|f| f.kind == FieldType::Json) => {
            format!("{field} CONTAINS $value")
        }
        Contains => format!("string::contains({field} ?? '', $value)"),
        StartsWith => format!("string::starts_with({field} ?? '', $value)"),
        Gt => format!("{field} > $value"),
        Gte => format!("{field} >= $value"),
        Lt => format!("{field} < $value"),
        Lte => format!("{field} <= $value"),
        Empty | NotEmpty => unreachable!(),
    };
    Ok((ordered_guard(&condition.operator, &field, sql), value))
}
fn ordered_guard(operator: &FilterOperator, field: &str, sql: String) -> String {
    if matches!(
        operator,
        FilterOperator::Gt | FilterOperator::Gte | FilterOperator::Lt | FilterOperator::Lte
    ) {
        format!("({field} != NONE AND {field} != NULL AND ({sql}))")
    } else {
        sql
    }
}
fn string_field<'a>(object: &'a Object, field: &str) -> Option<&'a str> {
    match object.get(field) {
        Some(DbValue::String(value)) => Some(value),
        _ => None,
    }
}
async fn metadata(db: &Surreal<Db>, ids: Vec<RecordId>) -> Result<Vec<Object>, String> {
    if ids.is_empty() {
        return Ok(vec![]);
    }
    query(
        db,
        "SELECT id,recordingId,versionId,in,out FROM $ids LIMIT 10001",
        bindings([("ids", ids.into_value())]),
    )
    .await?
    .into_iter()
    .map(|row| match row {
        DbValue::Object(row) => Ok(row),
        _ => Err("Entidad inválida".into()),
    })
    .collect()
}
async fn current_versions(
    db: &Surreal<Db>,
    ids: BTreeSet<String>,
) -> Result<BTreeMap<String, DbValue>, String> {
    let ids: Vec<RecordId> = ids
        .into_iter()
        .map(|id| RecordId::new("recording", id))
        .collect();
    let rows = query(
        db,
        "SELECT recordingId,currentVersion FROM $ids LIMIT 10001",
        bindings([("ids", ids.into_value())]),
    )
    .await?;
    rows.into_iter()
        .map(|row| {
            let DbValue::Object(row) = row else {
                return Err("Grabación inválida".into());
            };
            Ok((
                string_field(&row, "recordingId")
                    .ok_or("Grabación sin identidad")?
                    .to_string(),
                row.get("currentVersion").cloned().unwrap_or(DbValue::None),
            ))
        })
        .collect()
}
fn active(row: &Object, current: &BTreeMap<String, DbValue>) -> bool {
    let Some(recording) = string_field(row, "recordingId") else {
        return false;
    };
    let Some(version) = current.get(recording) else {
        return false;
    };
    if let Some(id) = string_field(row, "versionId") {
        *version
            == RecordId::new(
                "version",
                surrealdb::types::RecordIdKey::Array(
                    vec![recording.into_value(), id.into_value()].into(),
                ),
            )
            .into_value()
    } else {
        matches!(row.get("id"),Some(DbValue::RecordId(id)) if id.table.as_str()=="recording")
    }
}
async fn base_notes(root: &Surreal<Db>, ids: Vec<RecordId>) -> Result<BTreeSet<String>, String> {
    let definition = base_definition();
    for id in &ids {
        declared(&definition, id.table.as_str())?;
    }
    let db = selected(root, "escriba").await?;
    let mut rows = metadata(&db, ids).await?;
    let mut endpoints = vec![];
    let mut people = vec![];
    for row in &rows {
        for key in ["in", "out"] {
            if let Some(DbValue::RecordId(id)) = row.get(key) {
                endpoints.push(id.clone());
            }
        }
        if let Some(DbValue::RecordId(id)) = row.get("id") {
            if id.table.as_str() == "person" {
                people.push(id.key.clone().into_value());
            }
        }
    }
    let endpoint_rows = metadata(&db, endpoints).await?;
    if !people.is_empty() {
        rows.extend(query(&db,"SELECT id,recordingId,versionId FROM segment WHERE personId IN $people LIMIT 10001",bindings([("people",DbValue::Array(people.into()))])).await?.into_iter().filter_map(|v|match v {DbValue::Object(o)=>Some(o),_=>None}));
    }
    let recordings = rows
        .iter()
        .chain(&endpoint_rows)
        .filter_map(|r| string_field(r, "recordingId").map(str::to_owned))
        .collect();
    let current = current_versions(&db, recordings).await?;
    let mut result = BTreeSet::new();
    for row in rows {
        let Some(recording) = string_field(&row, "recordingId") else {
            continue;
        };
        let matches = if matches!(row.get("in"), Some(DbValue::RecordId(_)))
            && matches!(row.get("out"), Some(DbValue::RecordId(_)))
        {
            let derived = matches!(row.get("id"),Some(DbValue::RecordId(id)) if id.table.as_str()=="derived_from");
            ["in","out"].iter().all(|key| endpoint_rows.iter().find(|endpoint|endpoint.get("id")==row.get(*key)).is_some_and(|endpoint| {
                if derived && *key == "out" {string_field(endpoint,"recordingId")==Some(recording)}
                else {matches!(endpoint.get("id"),Some(DbValue::RecordId(id)) if id.table.as_str()=="person") || active(endpoint,&current)}
            }))
        } else {
            active(&row, &current)
        };
        if matches {
            result.insert(recording.to_string());
        }
    }
    Ok(result)
}
async fn extension_notes(
    root: &Surreal<Db>,
    db: &Surreal<Db>,
    definition: &Ontology,
    ids: Vec<RecordId>,
) -> Result<BTreeSet<String>, String> {
    let mut grouped = BTreeMap::<String, Vec<RecordId>>::new();
    for id in ids {
        declared(definition, id.table.as_str())?;
        grouped.entry(id.table.to_string()).or_default().push(id);
    }
    let mut sources = vec![];
    let mut references = vec![];
    for (table, ids) in grouped {
        let collection = declared(definition, &table)?;
        let fields: Vec<&Field> = collection
            .fields
            .iter()
            .filter(|f| f.kind == FieldType::Reference)
            .collect();
        let projection = std::iter::once("id".to_string())
            .chain(fields.iter().map(|f| format!("`{}`", f.key)))
            .collect::<Vec<_>>()
            .join(",");
        let existing = query(
            db,
            &format!("SELECT {projection} FROM $ids LIMIT 10001"),
            bindings([("ids", ids.into_value())]),
        )
        .await?;
        let mut existing_ids = vec![];
        for row in existing {
            let DbValue::Object(mut row) = row else {
                return Err("Entidad inválida".into());
            };
            existing_ids.push(native_id(row.remove("id").ok_or("Entidad sin identidad")?)?);
            for field in &fields {
                if let Some(value) = row
                    .remove(&field.key)
                    .filter(|v| !matches!(v, DbValue::None | DbValue::Null))
                {
                    let id = reference(value)?;
                    if !field
                        .reference
                        .as_ref()
                        .is_some_and(|r| r.table == id.table.as_str() && r.ontology_id == "escriba")
                    {
                        return Err("Referencia incompatible con su declaración".into());
                    }
                    references.push(id);
                }
            }
        }
        sources.extend(query(db,"SELECT recordingId,versionId FROM _escriba_source WHERE record IN $ids LIMIT 10001",bindings([("ids",existing_ids.into_value())])).await?);
    }
    check_size(&sources)?;
    let base = selected(root, "escriba").await?;
    let source_rows: Vec<Object> = sources
        .into_iter()
        .map(|v| match v {
            DbValue::Object(o) => Ok(o),
            _ => Err("Procedencia inválida".to_string()),
        })
        .collect::<Result<_, _>>()?;
    let current = current_versions(
        &base,
        source_rows
            .iter()
            .filter_map(|o| string_field(o, "recordingId").map(str::to_owned))
            .collect(),
    )
    .await?;
    let mut result = base_notes(root, references).await?;
    for row in source_rows {
        if active(&row, &current) {
            result.insert(
                string_field(&row, "recordingId")
                    .ok_or("Procedencia sin grabación")?
                    .to_string(),
            );
        }
    }
    Ok(result)
}
