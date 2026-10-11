use crate::{
    knowledge::{
        self, FilterResult, GraphDetail, GraphPage, GraphRecord, Knowledge, LibraryFilter,
        ListedOntology, Ontology, RecordPage, SaveLibraryFilter, SaveRecord, SavedLibraryFilter,
        Source,
    },
    store::Store,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Arc, Mutex, MutexGuard},
};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Dependency {
    pub id: String,
    pub min_version: u32,
    pub max_version: u32,
}

pub fn dependencies(value: Option<&Value>) -> Result<Vec<Dependency>, String> {
    let values: Vec<Dependency> = serde_json::from_value(value.cloned().unwrap_or(json!([])))
        .map_err(|_| "Dependencias de ontología inválidas")?;
    let mut ids = std::collections::HashSet::new();
    if values.len() > 64
        || values.iter().any(|v| {
            v.id.trim().is_empty()
                || v.id.len() > 200
                || v.min_version == 0
                || v.max_version < v.min_version
                || !ids.insert(v.id.clone())
        })
    {
        return Err("Dependencias de ontología inválidas o repetidas".into());
    }
    Ok(values)
}

#[derive(Debug, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct NoParams {}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InstallParams {
    pub definition: Ontology,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpenParams {
    pub recipe_id: String,
    pub recording_id: String,
    pub ontology_id: String,
    pub dependency: Dependency,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryParams {
    pub recipe_id: String,
    pub recording_id: String,
    pub ontology_id: String,
    pub dependency: Dependency,
    pub expected_version: u32,
    pub sql: String,
    pub bindings: String,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LinkParams {
    pub recipe_id: String,
    pub recording_id: String,
    pub ontology_id: String,
    pub dependency: Dependency,
    pub expected_version: u32,
    pub version_id: String,
    pub record_id: String,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[ts(optional_fields)]
pub struct RecordsParams {
    pub id: String,
    pub table: String,
    pub page: Option<u32>,
    pub recording_id: Option<String>,
    pub version_id: Option<String>,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[ts(optional_fields)]
pub struct RootsParams {
    pub ontology_id: String,
    pub table: String,
    pub page: Option<u32>,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[ts(optional_fields)]
pub struct ExpandParams {
    pub ontology_id: String,
    pub record_id: String,
    pub page: Option<u32>,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DetailParams {
    pub ontology_id: String,
    pub record_id: String,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[ts(optional_fields)]
pub struct SaveParams {
    pub id: String,
    pub expected_version: u32,
    pub table: String,
    pub record_id: Option<String>,
    pub expected_rev: Option<String>,
    #[ts(type = "Record<string, unknown>")]
    pub values: Value,
    pub recording_id: Option<String>,
    pub version_id: Option<String>,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeleteParams {
    pub id: String,
    pub expected_version: u32,
    pub table: String,
    pub record_id: String,
    pub expected_rev: String,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UnlinkParams {
    pub id: String,
    pub expected_version: u32,
    pub record_id: String,
    pub recording_id: String,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AttachParams {
    pub id: String,
    pub expected_version: u32,
    pub record_id: String,
    pub recording_id: String,
    pub version_id: String,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilterNotesParams {
    pub filter: LibraryFilter,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilterSaveParams {
    pub filter: SaveLibraryFilter,
}

#[derive(Debug, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilterRemoveParams {
    pub id: String,
}

#[derive(Debug, Deserialize, TS)]
#[allow(clippy::enum_variant_names)]
#[serde(tag = "method", content = "params", rename_all = "snake_case")]
pub enum KnowledgeCommand {
    KnowledgeCandidates(NoParams),
    KnowledgeList(NoParams),
    KnowledgeInstall(InstallParams),
    KnowledgeOpen(OpenParams),
    KnowledgeQuery(QueryParams),
    KnowledgeLink(LinkParams),
    KnowledgeRecords(RecordsParams),
    KnowledgeSave(SaveParams),
    KnowledgeDelete(DeleteParams),
    KnowledgeUnlink(UnlinkParams),
    KnowledgeAttach(AttachParams),
    KnowledgeGraphRoots(RootsParams),
    KnowledgeGraphExpand(ExpandParams),
    KnowledgeGraphDetail(DetailParams),
    KnowledgeFilterNotes(FilterNotesParams),
    KnowledgeFiltersList(NoParams),
    KnowledgeFilterSave(FilterSaveParams),
    KnowledgeFilterRemove(FilterRemoveParams),
}

#[derive(Debug, Serialize, TS)]
pub struct OpenedGraph {
    pub version: u32,
}

#[derive(Serialize, TS)]
#[allow(clippy::enum_variant_names)]
#[serde(tag = "method", content = "value", rename_all = "snake_case")]
pub enum KnowledgeReply {
    KnowledgeCandidates(Vec<Ontology>),
    KnowledgeList(Vec<ListedOntology>),
    KnowledgeInstall(Ontology),
    KnowledgeOpen(OpenedGraph),
    KnowledgeQuery(String),
    KnowledgeLink(()),
    KnowledgeRecords(RecordPage),
    KnowledgeSave(GraphRecord),
    KnowledgeDelete(()),
    KnowledgeUnlink(()),
    KnowledgeAttach(()),
    KnowledgeGraphRoots(GraphPage),
    KnowledgeGraphExpand(GraphPage),
    KnowledgeGraphDetail(GraphDetail),
    KnowledgeFilterNotes(FilterResult),
    KnowledgeFiltersList(Vec<SavedLibraryFilter>),
    KnowledgeFilterSave(SavedLibraryFilter),
    KnowledgeFilterRemove(()),
}

pub fn parse(method: &str, params: Value) -> Result<KnowledgeCommand, String> {
    crate::command::tagged(method, params)
}

impl KnowledgeReply {
    pub fn into_value(self, method: &str) -> Result<Value, String> {
        let mut tagged = serde_json::to_value(self).map_err(|e| e.to_string())?;
        if tagged["method"] != method {
            return Err(format!(
                "Respuesta de conocimiento incoherente para {method}"
            ));
        }
        Ok(tagged["value"].take())
    }
}

fn library(store: &Arc<Mutex<Store>>) -> Result<MutexGuard<'_, Store>, String> {
    store.lock().map_err(|_| "Biblioteca no disponible".into())
}

fn candidates(store: &Arc<Mutex<Store>>) -> Result<Vec<Ontology>, String> {
    Ok(library(store)?
        .data
        .settings
        .project_ontologies
        .as_ref()
        .cloned()
        .unwrap_or_default())
}

fn requirement(
    store: &Store,
    recipe_id: &str,
    recording_id: &str,
    ontology_id: &str,
    expected: &Dependency,
) -> Result<Dependency, String> {
    let mut recipe = store.item("recipes", recipe_id)?;
    if recipe["kind"] == "form" {
        let base = crate::store::text(&recipe, "base")?;
        recipe = store
            .data
            .recipes
            .as_array()
            .and_then(|recipes| {
                recipes
                    .iter()
                    .find(|r| r["id"] == base || r["name"] == base)
            })
            .cloned()
            .ok_or("Receta base no disponible")?;
    }
    if recipe["bundle"].as_str().is_none_or(str::is_empty) {
        return Err("La receta ya no está disponible".into());
    }
    let declared = dependencies(recipe.get("ontologies"))?
        .into_iter()
        .find(|d| d.id == ontology_id)
        .or_else(|| {
            (ontology_id == "escriba").then(|| Dependency {
                id: "escriba".into(),
                min_version: 1,
                max_version: 1,
            })
        })
        .ok_or("La receta no declara esta ontología")?;
    if &declared != expected {
        return Err("Las dependencias de la receta cambiaron; vuelve a procesar".into());
    }
    let recording = store
        .data
        .recordings
        .iter()
        .find(|recording| recording.id == recording_id)
        .ok_or("Grabación no encontrada")?;
    if recording.status == crate::store::RecordingStatus::Discarded {
        return Err("La grabación se ha descartado".into());
    }
    Ok(declared)
}

async fn granted(
    knowledge: &Knowledge,
    store: &Arc<Mutex<Store>>,
    recipe_id: &str,
    recording_id: &str,
    ontology_id: &str,
    expected: &Dependency,
) -> Result<(String, u32), String> {
    let required = requirement(
        &*library(store)?,
        recipe_id,
        recording_id,
        ontology_id,
        expected,
    )?;
    let installed = if required.id == "escriba" {
        knowledge::base_definition()
    } else {
        knowledge
            .list()
            .await?
            .into_iter()
            .find(|o| o.id == required.id)
            .ok_or("Instala la ontología desde Recetas antes de ejecutar esta receta")?
    };
    if !(required.min_version..=required.max_version).contains(&installed.version) {
        return Err(format!(
            "La receta requiere «{}» entre v{} y v{}; está instalada v{}",
            required.id, required.min_version, required.max_version, installed.version
        ));
    }
    Ok((required.id, installed.version))
}

fn source(
    store: &Store,
    recording_id: &str,
    version_id: &str,
    recipe_id: Option<String>,
) -> Result<Source, String> {
    let recording = store.recording(recording_id)?;
    if recording["status"] == "discarded"
        || !recording["versions"]
            .as_array()
            .is_some_and(|versions| versions.iter().any(|v| v["id"] == version_id))
    {
        return Err("La versión de origen ya no está en la biblioteca".into());
    }
    Ok(Source {
        recording_id: recording_id.into(),
        version_id: version_id.into(),
        recipe_id,
    })
}

fn version(expected: u32) -> Result<u32, String> {
    if expected == 0 {
        return Err("Versión de ontología inválida".into());
    }
    Ok(expected)
}

const UI_SYNC_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);
const BACKGROUND_SYNC_BUDGET: std::time::Duration = std::time::Duration::from_millis(500);

struct Synchronized<'a> {
    _guard: tokio::sync::MutexGuard<'a, ()>,
    complete: bool,
}

async fn synchronize_base<'a>(
    knowledge: &'a Knowledge,
    store: &Arc<Mutex<Store>>,
    budget: Option<std::time::Duration>,
) -> Result<Synchronized<'a>, String> {
    let guard = knowledge.base_sync.lock().await;
    let started = std::time::Instant::now();
    let epoch = knowledge.base_epoch().await?;
    store
        .lock()
        .map_err(|_| "Biblioteca no disponible")?
        .knowledge_prepare(&epoch)?;
    loop {
        let change = store
            .lock()
            .map_err(|_| "Biblioteca no disponible")?
            .knowledge_change()?;
        let Some(change) = change else {
            return Ok(Synchronized {
                _guard: guard,
                complete: true,
            });
        };
        if budget.is_some_and(|budget| started.elapsed() >= budget) {
            return Ok(Synchronized {
                _guard: guard,
                complete: false,
            });
        }
        knowledge.sync_base_change(&change).await?;
        store
            .lock()
            .map_err(|_| "Biblioteca no disponible")?
            .knowledge_ack(&change.key, &change.revision)?;
    }
}

pub async fn sync_step(knowledge: &Knowledge, store: &Arc<Mutex<Store>>) -> Result<bool, String> {
    Ok(
        synchronize_base(knowledge, store, Some(BACKGROUND_SYNC_BUDGET))
            .await?
            .complete,
    )
}

pub async fn run(
    cell: &tokio::sync::OnceCell<Knowledge>,
    path: &Path,
    store: &Arc<Mutex<Store>>,
    command: KnowledgeCommand,
) -> Result<KnowledgeReply, String> {
    let listing = matches!(
        command,
        KnowledgeCommand::KnowledgeList(_) | KnowledgeCommand::KnowledgeFiltersList(_)
    );
    if let KnowledgeCommand::KnowledgeCandidates(NoParams {}) = command {
        return Ok(KnowledgeReply::KnowledgeCandidates(candidates(store)?));
    }
    if listing
        && cell.get().is_none()
        && !path
            .try_exists()
            .map_err(|error| format!("No se pudo acceder al conocimiento: {error}"))?
    {
        return Ok(match command {
            KnowledgeCommand::KnowledgeList(_) => {
                KnowledgeReply::KnowledgeList(vec![knowledge::base_listing()])
            }
            _ => KnowledgeReply::KnowledgeFiltersList(Vec::new()),
        });
    }
    let knowledge = cell.get_or_try_init(|| Knowledge::open(path)).await?;
    dispatch(knowledge, store, command).await
}

pub async fn dispatch(
    knowledge: &Knowledge,
    store: &Arc<Mutex<Store>>,
    command: KnowledgeCommand,
) -> Result<KnowledgeReply, String> {
    use KnowledgeCommand as C;
    use KnowledgeReply as R;
    Ok(match command {
        C::KnowledgeCandidates(NoParams {}) => R::KnowledgeCandidates(candidates(store)?),
        C::KnowledgeList(NoParams {}) => {
            let mut listed = vec![knowledge::base_listing()];
            listed.extend(
                knowledge
                    .list()
                    .await?
                    .into_iter()
                    .map(|ontology| ListedOntology {
                        ontology,
                        built_in: None,
                    }),
            );
            R::KnowledgeList(listed)
        }
        C::KnowledgeInstall(InstallParams { definition }) => {
            if !candidates(store)?.contains(&definition) {
                return Err(
                    "La ontología del proyecto cambió; actualiza la lista antes de instalar".into(),
                );
            }
            R::KnowledgeInstall(knowledge.apply(definition).await?)
        }
        C::KnowledgeOpen(p) => {
            let (_, version) = granted(
                knowledge,
                store,
                &p.recipe_id,
                &p.recording_id,
                &p.ontology_id,
                &p.dependency,
            )
            .await?;
            R::KnowledgeOpen(OpenedGraph { version })
        }
        C::KnowledgeQuery(p) => {
            let (ontology, _) = granted(
                knowledge,
                store,
                &p.recipe_id,
                &p.recording_id,
                &p.ontology_id,
                &p.dependency,
            )
            .await?;
            let _base_guard = if ontology == "escriba" {
                Some(synchronize_base(knowledge, store, None).await?)
            } else {
                None
            };
            R::KnowledgeQuery(
                knowledge
                    .query_cbor(&ontology, version(p.expected_version)?, &p.sql, &p.bindings)
                    .await?,
            )
        }
        C::KnowledgeLink(p) => {
            let (ontology, _) = granted(
                knowledge,
                store,
                &p.recipe_id,
                &p.recording_id,
                &p.ontology_id,
                &p.dependency,
            )
            .await?;
            let provenance = source(
                &*library(store)?,
                &p.recording_id,
                &p.version_id,
                Some(p.recipe_id),
            )?;
            knowledge
                .link(
                    &ontology,
                    version(p.expected_version)?,
                    &p.record_id,
                    provenance,
                )
                .await?;
            R::KnowledgeLink(())
        }
        C::KnowledgeGraphRoots(p) => {
            let _base_guard = synchronize_base(knowledge, store, Some(UI_SYNC_BUDGET)).await?;
            R::KnowledgeGraphRoots(
                knowledge
                    .graph_roots(&p.ontology_id, &p.table, p.page.unwrap_or(0))
                    .await?,
            )
        }
        C::KnowledgeGraphExpand(p) => {
            let _base_guard = synchronize_base(knowledge, store, Some(UI_SYNC_BUDGET)).await?;
            R::KnowledgeGraphExpand(
                knowledge
                    .graph_expand(&p.ontology_id, &p.record_id, p.page.unwrap_or(0))
                    .await?,
            )
        }
        C::KnowledgeGraphDetail(p) => {
            let _base_guard = synchronize_base(knowledge, store, Some(UI_SYNC_BUDGET)).await?;
            R::KnowledgeGraphDetail(knowledge.graph_detail(&p.ontology_id, &p.record_id).await?)
        }
        C::KnowledgeRecords(p) => {
            let _base_guard = if p.id == "escriba" {
                Some(synchronize_base(knowledge, store, Some(UI_SYNC_BUDGET)).await?)
            } else {
                None
            };
            R::KnowledgeRecords(
                knowledge
                    .records(
                        &p.id,
                        &p.table,
                        p.page.unwrap_or(0),
                        p.recording_id.as_deref(),
                        p.version_id.as_deref(),
                    )
                    .await?,
            )
        }
        C::KnowledgeSave(p) => {
            let _base_guard = synchronize_base(knowledge, store, None).await?;
            let provenance = match &p.recording_id {
                Some(recording_id) => Some(source(
                    &*library(store)?,
                    recording_id,
                    p.version_id.as_deref().ok_or("Falta versionId")?,
                    None,
                )?),
                None => None,
            };
            R::KnowledgeSave(
                knowledge
                    .save(SaveRecord {
                        ontology_id: p.id,
                        expected_version: version(p.expected_version)?,
                        table: p.table,
                        record_id: p.record_id,
                        expected_rev: p.expected_rev,
                        values: p.values,
                        source: provenance,
                    })
                    .await?,
            )
        }
        C::KnowledgeDelete(p) => {
            knowledge
                .delete(
                    &p.id,
                    version(p.expected_version)?,
                    &p.table,
                    &p.record_id,
                    &p.expected_rev,
                )
                .await?;
            R::KnowledgeDelete(())
        }
        C::KnowledgeUnlink(p) => {
            knowledge
                .unlink(
                    &p.id,
                    version(p.expected_version)?,
                    &p.record_id,
                    &p.recording_id,
                )
                .await?;
            R::KnowledgeUnlink(())
        }
        C::KnowledgeAttach(p) => {
            let provenance = source(&*library(store)?, &p.recording_id, &p.version_id, None)?;
            knowledge
                .link(
                    &p.id,
                    version(p.expected_version)?,
                    &p.record_id,
                    provenance,
                )
                .await?;
            R::KnowledgeAttach(())
        }
        C::KnowledgeFilterNotes(FilterNotesParams { filter }) => {
            let synchronized = synchronize_base(knowledge, store, Some(UI_SYNC_BUDGET)).await?;
            let mut result = knowledge.filter_notes(filter).await?;
            if !synchronized.complete {
                result.incomplete = Some(true);
            }
            R::KnowledgeFilterNotes(result)
        }
        C::KnowledgeFiltersList(NoParams {}) => {
            R::KnowledgeFiltersList(knowledge.saved_filters().await?)
        }
        C::KnowledgeFilterSave(FilterSaveParams { filter }) => {
            R::KnowledgeFilterSave(knowledge.save_filter(filter).await?)
        }
        C::KnowledgeFilterRemove(FilterRemoveParams { id }) => {
            knowledge.remove_filter(&id).await?;
            R::KnowledgeFilterRemove(())
        }
    })
}

#[cfg(test)]
pub async fn call(
    knowledge: &Knowledge,
    store: &Arc<Mutex<Store>>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    dispatch(knowledge, store, parse(method, params)?)
        .await?
        .into_value(method)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn filtra_con_la_proyeccion_actual_y_guarda_consultas_desde_la_interfaz() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("prueba.wav");
        std::fs::write(&audio, b"audio sintetico").unwrap();
        let mut store = Store::open(temp.path().join("library")).unwrap();
        let record = store.import(&audio, None).unwrap();
        store.mutate("version_save", &json!({"recordingId":record["id"],"backend":"test","transcript":{"text":"Sintético","segments":[]}})).unwrap();
        let store = Arc::new(Mutex::new(store));
        let knowledge = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
            .await
            .unwrap();
        let filter = json!({"kind":"surrealql","ontologyId":"escriba","sql":"SELECT VALUE id FROM recording"});
        let result = call(
            &knowledge,
            &store,
            "knowledge_filter_notes",
            json!({"filter":filter}),
        )
        .await
        .unwrap();
        assert_eq!(result, json!({"recordingIds":[record["id"]]}));
        let saved = call(
            &knowledge,
            &store,
            "knowledge_filter_save",
            json!({"filter":{"name":"Todas","filter":filter}}),
        )
        .await
        .unwrap();
        assert_eq!(
            call(&knowledge, &store, "knowledge_filters_list", json!({}))
                .await
                .unwrap(),
            json!([saved])
        );
        let visual = call(
            &knowledge,
            &store,
            "knowledge_filter_save",
            json!({"filter":{"name":"Visual","filter":{"kind":"visual","match":"any","conditions":[{"ontologyId":"escriba","table":"recording","field":"title","operator":"contains","value":"Sintético"}]}}}),
        )
        .await
        .unwrap();
        assert_eq!(visual["filter"]["kind"], "visual");
        assert_eq!(
            call(&knowledge, &store, "knowledge_filters_list", json!({}))
                .await
                .unwrap(),
            json!([saved, visual])
        );
        call(
            &knowledge,
            &store,
            "knowledge_filter_remove",
            json!({"id":saved["id"]}),
        )
        .await
        .unwrap();
        call(
            &knowledge,
            &store,
            "knowledge_filter_remove",
            json!({"id":visual["id"]}),
        )
        .await
        .unwrap();
        assert_eq!(
            call(&knowledge, &store, "knowledge_filters_list", json!({}))
                .await
                .unwrap(),
            json!([])
        );
        knowledge.close().await.unwrap();
    }

    #[tokio::test]
    async fn valida_dependencias_persistidas_version_y_origen_antes_de_abrir_el_grafo() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("prueba.wav");
        std::fs::write(&audio, b"audio sintetico").unwrap();
        let mut store = Store::open(temp.path().join("library")).unwrap();
        let record = store.import(&audio, None).unwrap();
        let version = store.mutate("version_save", &json!({"recordingId":record["id"],"backend":"test","transcript":{"text":"Sintético","segments":[]}})).unwrap();
        let ontology = json!({"id":"example","name":"Ejemplo","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE topic SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON topic TYPE string;"}],"collections":[{"table":"topic","label":"Temas","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text","required":true}]}]});
        let dependency = json!({"id":"example","minVersion":1,"maxVersion":1});
        crate::catalog::install(&mut store, &json!({"recipes":[{"id":"graph","name":"Grafo","kind":"code","values":{},"bundle":"program","ontologies":[dependency]}],"destinations":[],"ontologies":[ontology]})).unwrap();
        let store = Arc::new(Mutex::new(store));
        let graph = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
            .await
            .unwrap();
        let params = json!({"recipeId":"graph","recordingId":record["id"],"ontologyId":"example","dependency":dependency});
        let unavailable = call(&graph, &store, "knowledge_open", params.clone())
            .await
            .unwrap_err();
        assert!(unavailable.contains("Instala"), "{unavailable}");
        call(
            &graph,
            &store,
            "knowledge_install",
            json!({"definition":ontology}),
        )
        .await
        .unwrap();
        assert_eq!(
            call(&graph, &store, "knowledge_open", params.clone())
                .await
                .unwrap(),
            json!({"version":1})
        );
        let mut forged = params.clone();
        forged["dependency"]["maxVersion"] = json!(99);
        assert!(call(&graph, &store, "knowledge_open", forged)
            .await
            .unwrap_err()
            .contains("cambiaron"));
        let mut query = params.clone();
        query["expectedVersion"] = json!(2);
        query["sql"] = json!("CREATE topic:a SET name = 'Prueba'");
        query["bindings"] = json!("oA==");
        assert!(call(&graph, &store, "knowledge_query", query.clone())
            .await
            .is_err());
        query["expectedVersion"] = json!(1);
        call(&graph, &store, "knowledge_query", query)
            .await
            .unwrap();
        let attach = json!({"id":"example","expectedVersion":1,"recordId":"topic:a","recordingId":record["id"],"versionId":version["id"]});
        let mut invalid = attach.clone();
        invalid["versionId"] = json!("otra");
        assert!(call(&graph, &store, "knowledge_attach", invalid)
            .await
            .is_err());
        call(&graph, &store, "knowledge_attach", attach.clone())
            .await
            .unwrap();
        let page = call(
            &graph,
            &store,
            "knowledge_records",
            json!({"id":"example","table":"topic","recordingId":record["id"]}),
        )
        .await
        .unwrap();
        assert_eq!(page["records"].as_array().unwrap().len(), 1);
        let mut unlink = attach;
        unlink.as_object_mut().unwrap().remove("versionId");
        call(&graph, &store, "knowledge_unlink", unlink)
            .await
            .unwrap();
        assert_eq!(
            graph
                .records("example", "topic", 0, None, None)
                .await
                .unwrap()
                .records
                .len(),
            1
        );
        crate::catalog::install(
            &mut store.lock().unwrap(),
            &json!({"recipes":[],"destinations":[]}),
        )
        .unwrap();
        assert!(call(&graph, &store, "knowledge_open", params)
            .await
            .unwrap_err()
            .contains("disponible"));
        assert_eq!(graph.list().await.unwrap().len(), 1);
        graph.close().await.unwrap();
    }
}
