use crate::knowledge::{
    self, CoreChange, FilterResult, GraphDetail, GraphPage, GraphRecord, Knowledge, LibraryFilter,
    ListedOntology, Ontology, RecordPage, SaveLibraryFilter, SaveRecord, SavedLibraryFilter,
    Source,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{future::Future, path::Path, pin::Pin, sync::Arc};
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

pub type PortCall = Arc<
    dyn Fn(&'static str, Value) -> Pin<Box<dyn Future<Output = Result<Value, String>> + Send>>
        + Send
        + Sync,
>;

/// Lo que el conocimiento necesita de la biblioteca, que vive en el controlador TypeScript.
#[derive(Clone)]
pub struct LibraryPort {
    call: PortCall,
}

impl LibraryPort {
    pub fn new(call: PortCall) -> Self {
        Self { call }
    }
    async fn call(&self, method: &'static str, params: Value) -> Result<Value, String> {
        (self.call)(method, params).await
    }
    async fn ontologies(&self) -> Result<Vec<Ontology>, String> {
        serde_json::from_value(self.call("knowledge_ontologies", json!({})).await?)
            .map_err(|error| format!("Ontologías del proyecto inválidas: {error}"))
    }
    async fn context(&self, recipe_id: &str, recording_id: &str) -> Result<Value, String> {
        self.call(
            "knowledge_context",
            json!({"recipeId": recipe_id, "recordingId": recording_id}),
        )
        .await
    }
    async fn recording(&self, id: &str) -> Result<Value, String> {
        self.call("recording_detail", json!({"id": id})).await
    }
    async fn feed_prepare(&self, epoch: &str) -> Result<(), String> {
        self.call("knowledge_feed_prepare", json!({"epoch": epoch}))
            .await
            .map(|_| ())
    }
    async fn feed_changes(&self, limit: usize) -> Result<Vec<CoreChange>, String> {
        serde_json::from_value(
            self.call("knowledge_feed_changes", json!({"limit": limit}))
                .await?,
        )
        .map_err(|error| format!("Cambios de la biblioteca inválidos: {error}"))
    }
    async fn feed_ack(&self, acks: &[(String, String)]) -> Result<(), String> {
        if acks.is_empty() {
            return Ok(());
        }
        let acks: Vec<Value> = acks
            .iter()
            .map(|(key, revision)| json!({"key": key, "revision": revision}))
            .collect();
        self.call("knowledge_feed_ack", json!({"acks": acks}))
            .await
            .map(|_| ())
    }
}

fn requirement(
    context: &Value,
    ontology_id: &str,
    expected: &Dependency,
) -> Result<Dependency, String> {
    let recipe = &context["recipe"];
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
    let recording = &context["recording"];
    if recording.is_null() {
        return Err("Grabación no encontrada".into());
    }
    if recording["status"] == "discarded" {
        return Err("La grabación se ha descartado".into());
    }
    Ok(declared)
}

async fn granted(
    knowledge: &Knowledge,
    library: &LibraryPort,
    recipe_id: &str,
    recording_id: &str,
    ontology_id: &str,
    expected: &Dependency,
) -> Result<(String, u32), String> {
    let context = library.context(recipe_id, recording_id).await?;
    let required = requirement(&context, ontology_id, expected)?;
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

async fn source(
    library: &LibraryPort,
    recording_id: &str,
    version_id: &str,
    recipe_id: Option<String>,
) -> Result<Source, String> {
    let recording = library.recording(recording_id).await?;
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
const FEED_BATCH: usize = 64;

struct Synchronized<'a> {
    _guard: tokio::sync::MutexGuard<'a, ()>,
    complete: bool,
}

async fn synchronize_base<'a>(
    knowledge: &'a Knowledge,
    library: &LibraryPort,
    budget: Option<std::time::Duration>,
) -> Result<Synchronized<'a>, String> {
    let guard = knowledge.base_sync.lock().await;
    let started = std::time::Instant::now();
    let epoch = knowledge.base_epoch().await?;
    library.feed_prepare(&epoch).await?;
    loop {
        let changes = library.feed_changes(FEED_BATCH).await?;
        if changes.is_empty() {
            return Ok(Synchronized {
                _guard: guard,
                complete: true,
            });
        }
        let mut acks = Vec::with_capacity(changes.len());
        let mut exhausted = false;
        for change in &changes {
            if budget.is_some_and(|budget| started.elapsed() >= budget) {
                exhausted = true;
                break;
            }
            knowledge.sync_base_change(change).await?;
            acks.push((change.key.clone(), change.revision.clone()));
        }
        library.feed_ack(&acks).await?;
        if exhausted {
            return Ok(Synchronized {
                _guard: guard,
                complete: false,
            });
        }
    }
}

pub async fn sync_step(knowledge: &Knowledge, library: &LibraryPort) -> Result<bool, String> {
    Ok(
        synchronize_base(knowledge, library, Some(BACKGROUND_SYNC_BUDGET))
            .await?
            .complete,
    )
}

pub async fn run(
    cell: &tokio::sync::OnceCell<Knowledge>,
    path: &Path,
    library: &LibraryPort,
    command: KnowledgeCommand,
) -> Result<KnowledgeReply, String> {
    let listing = matches!(
        command,
        KnowledgeCommand::KnowledgeList(_) | KnowledgeCommand::KnowledgeFiltersList(_)
    );
    if let KnowledgeCommand::KnowledgeCandidates(NoParams {}) = command {
        return Ok(KnowledgeReply::KnowledgeCandidates(
            library.ontologies().await?,
        ));
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
    dispatch(knowledge, library, command).await
}

pub async fn dispatch(
    knowledge: &Knowledge,
    library: &LibraryPort,
    command: KnowledgeCommand,
) -> Result<KnowledgeReply, String> {
    use KnowledgeCommand as C;
    use KnowledgeReply as R;
    Ok(match command {
        C::KnowledgeCandidates(NoParams {}) => R::KnowledgeCandidates(library.ontologies().await?),
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
            if !library.ontologies().await?.contains(&definition) {
                return Err(
                    "La ontología del proyecto cambió; actualiza la lista antes de instalar".into(),
                );
            }
            R::KnowledgeInstall(knowledge.apply(definition).await?)
        }
        C::KnowledgeOpen(p) => {
            let (_, version) = granted(
                knowledge,
                library,
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
                library,
                &p.recipe_id,
                &p.recording_id,
                &p.ontology_id,
                &p.dependency,
            )
            .await?;
            let _base_guard = if ontology == "escriba" {
                Some(synchronize_base(knowledge, library, None).await?)
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
                library,
                &p.recipe_id,
                &p.recording_id,
                &p.ontology_id,
                &p.dependency,
            )
            .await?;
            let provenance =
                source(library, &p.recording_id, &p.version_id, Some(p.recipe_id)).await?;
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
            let _base_guard = synchronize_base(knowledge, library, Some(UI_SYNC_BUDGET)).await?;
            R::KnowledgeGraphRoots(
                knowledge
                    .graph_roots(&p.ontology_id, &p.table, p.page.unwrap_or(0))
                    .await?,
            )
        }
        C::KnowledgeGraphExpand(p) => {
            let _base_guard = synchronize_base(knowledge, library, Some(UI_SYNC_BUDGET)).await?;
            R::KnowledgeGraphExpand(
                knowledge
                    .graph_expand(&p.ontology_id, &p.record_id, p.page.unwrap_or(0))
                    .await?,
            )
        }
        C::KnowledgeGraphDetail(p) => {
            let _base_guard = synchronize_base(knowledge, library, Some(UI_SYNC_BUDGET)).await?;
            R::KnowledgeGraphDetail(knowledge.graph_detail(&p.ontology_id, &p.record_id).await?)
        }
        C::KnowledgeRecords(p) => {
            let _base_guard = if p.id == "escriba" {
                Some(synchronize_base(knowledge, library, Some(UI_SYNC_BUDGET)).await?)
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
            let _base_guard = synchronize_base(knowledge, library, None).await?;
            let provenance = match &p.recording_id {
                Some(recording_id) => Some(
                    source(
                        library,
                        recording_id,
                        p.version_id.as_deref().ok_or("Falta versionId")?,
                        None,
                    )
                    .await?,
                ),
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
            let provenance = source(library, &p.recording_id, &p.version_id, None).await?;
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
            let synchronized = synchronize_base(knowledge, library, Some(UI_SYNC_BUDGET)).await?;
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
    library: &LibraryPort,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    dispatch(knowledge, library, parse(method, params)?)
        .await?
        .into_value(method)
}

/// Doble del controlador para probar el conocimiento sin la biblioteca TypeScript.
#[cfg(test)]
pub mod testing {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct FakeLibrary {
        pub recipes: Vec<Value>,
        pub recordings: Vec<Value>,
        pub people: Vec<Value>,
        pub ontologies: Vec<Value>,
        dirty: Vec<CoreChange>,
        epoch: Option<String>,
        feed_pages: Vec<(usize, usize)>,
        ack_batches: Vec<usize>,
    }

    impl FakeLibrary {
        pub fn new() -> Arc<Mutex<Self>> {
            Arc::new(Mutex::new(Self::default()))
        }
        pub fn add_recording(&mut self, id: &str, versions: Vec<Value>) -> Value {
            let current = versions
                .last()
                .map(|v| v["id"].clone())
                .unwrap_or(Value::Null);
            let record = json!({"id": id, "title": "Nota", "status": "pending", "createdAt": "2026-10-13T10:00:00+00:00", "currentVersionId": current, "versions": versions, "publications": []});
            self.recordings.push(record.clone());
            self.mark_dirty(id);
            record
        }
        pub fn mark_dirty(&mut self, id: &str) {
            let snapshot = self
                .recordings
                .iter()
                .find(|r| r["id"] == id && r["status"] != "discarded")
                .cloned();
            self.dirty
                .retain(|change| change.key != format!("recording:{id}"));
            self.dirty.push(CoreChange {
                key: format!("recording:{id}"),
                revision: crate::util::id(),
                kind: "recording".into(),
                id: id.into(),
                value: snapshot,
            });
        }
        pub fn put_person(&mut self, id: &str, name: &str) {
            self.people.retain(|person| person["id"] != id);
            self.people.push(json!({"id": id, "name": name}));
            self.mark_person_dirty(id);
        }
        pub fn remove_person(&mut self, id: &str) {
            self.people.retain(|person| person["id"] != id);
            self.mark_person_dirty(id);
        }
        pub fn pending_changes(&self) -> usize {
            self.dirty.len()
        }
        pub fn feed_stats(&self) -> (&[(usize, usize)], &[usize]) {
            (&self.feed_pages, &self.ack_batches)
        }
        fn mark_person_dirty(&mut self, id: &str) {
            let snapshot = self
                .people
                .iter()
                .find(|person| person["id"] == id)
                .cloned();
            self.dirty
                .retain(|change| change.key != format!("person:{id}"));
            self.dirty.push(CoreChange {
                key: format!("person:{id}"),
                revision: crate::util::id(),
                kind: "person".into(),
                id: id.into(),
                value: snapshot,
            });
        }
        fn context(&self, recipe_id: &str, recording_id: &str) -> Result<Value, String> {
            let mut recipe = self
                .recipes
                .iter()
                .find(|r| r["id"] == recipe_id)
                .cloned()
                .ok_or_else(|| format!("No existe {recipe_id} en recipes"))?;
            if recipe["kind"] == "form" {
                let base = recipe["base"].clone();
                recipe = self
                    .recipes
                    .iter()
                    .find(|r| r["id"] == base || r["name"] == base)
                    .cloned()
                    .ok_or("Receta base no disponible")?;
            }
            let recording = self
                .recordings
                .iter()
                .find(|r| r["id"] == recording_id)
                .map(|r| json!({"id": r["id"], "status": r["status"]}))
                .unwrap_or(Value::Null);
            Ok(json!({"recipe": recipe, "recording": recording}))
        }
    }

    pub fn port(state: Arc<Mutex<FakeLibrary>>) -> LibraryPort {
        LibraryPort::new(Arc::new(move |method, params| {
            let state = state.clone();
            Box::pin(async move {
                let mut library = state.lock().map_err(|_| "doble bloqueado".to_owned())?;
                match method {
                    "knowledge_ontologies" => Ok(json!(library.ontologies)),
                    "knowledge_context" => library.context(
                        params["recipeId"].as_str().unwrap_or(""),
                        params["recordingId"].as_str().unwrap_or(""),
                    ),
                    "recording_detail" => library
                        .recordings
                        .iter()
                        .find(|r| r["id"] == params["id"])
                        .cloned()
                        .ok_or_else(|| "Grabación no encontrada".to_owned()),
                    "knowledge_feed_prepare" => {
                        let epoch = params["epoch"].as_str().unwrap_or("").to_owned();
                        if library.epoch.as_deref() != Some(&epoch) {
                            library.epoch = Some(epoch);
                            let ids: Vec<String> = library
                                .recordings
                                .iter()
                                .filter_map(|r| r["id"].as_str().map(str::to_owned))
                                .collect();
                            for id in ids {
                                library.mark_dirty(&id);
                            }
                            let ids: Vec<String> = library
                                .people
                                .iter()
                                .filter_map(|person| person["id"].as_str().map(str::to_owned))
                                .collect();
                            for id in ids {
                                library.mark_person_dirty(&id);
                            }
                        }
                        Ok(Value::Null)
                    }
                    "knowledge_feed_changes" => {
                        let limit = params["limit"].as_u64().unwrap_or(1) as usize;
                        let count = library.dirty.len().min(limit);
                        library.feed_pages.push((limit, count));
                        Ok(json!(library.dirty.iter().take(limit).collect::<Vec<_>>()))
                    }
                    "knowledge_feed_ack" => {
                        let acks = params["acks"].as_array().cloned().unwrap_or_default();
                        library.ack_batches.push(acks.len());
                        for ack in acks {
                            library.dirty.retain(|change| {
                                !(change.key == ack["key"] && change.revision == ack["revision"])
                            });
                        }
                        Ok(Value::Null)
                    }
                    _ => Err(format!("Método inesperado en el doble: {method}")),
                }
            })
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{port, FakeLibrary};
    use super::*;

    #[tokio::test]
    async fn filtra_con_la_proyeccion_actual_y_guarda_consultas_desde_la_interfaz() {
        let temp = tempfile::tempdir().unwrap();
        let state = FakeLibrary::new();
        let record = state.lock().unwrap().add_recording(
            "nota",
            vec![json!({"id":"v1","createdAt":"2026-10-13T10:00:00+00:00","backend":"test","transcript":{"text":"Sintético","segments":[]}})],
        );
        let store = port(state);
        let knowledge = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
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
            json!({"filter":{"name":"Visual","filter":{"kind":"visual","match":"any","conditions":[{"ontologyId":"escriba","table":"recording","field":"title","operator":"contains","value":"Nota"}]}}}),
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
        for id in [&saved["id"], &visual["id"]] {
            call(
                &knowledge,
                &store,
                "knowledge_filter_remove",
                json!({"id":id}),
            )
            .await
            .unwrap();
        }
        assert_eq!(
            call(&knowledge, &store, "knowledge_filters_list", json!({}))
                .await
                .unwrap(),
            json!([])
        );
        knowledge.close().await.unwrap();
    }

    #[tokio::test]
    async fn la_sincronizacion_acusa_por_lotes_y_respeta_el_presupuesto() {
        let temp = tempfile::tempdir().unwrap();
        let state = FakeLibrary::new();
        for index in 0..70 {
            state
                .lock()
                .unwrap()
                .add_recording(&format!("nota-{index}"), vec![]);
        }
        let store = port(state.clone());
        let knowledge = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
            .await
            .unwrap();
        let synchronized = synchronize_base(&knowledge, &store, Some(std::time::Duration::ZERO))
            .await
            .unwrap();
        assert!(!synchronized.complete);
        drop(synchronized);
        assert_eq!(state.lock().unwrap().pending_changes(), 70);
        let _ = sync_step(&knowledge, &store).await.unwrap();
        let complete = synchronize_base(&knowledge, &store, None).await.unwrap();
        assert!(complete.complete);
        drop(complete);
        assert_eq!(state.lock().unwrap().pending_changes(), 0);
        {
            let library = state.lock().unwrap();
            let (pages, acks) = library.feed_stats();
            assert!(pages
                .iter()
                .all(|&(limit, count)| limit == FEED_BATCH && count <= FEED_BATCH));
            assert!(pages.iter().any(|&(_, count)| count == FEED_BATCH));
            assert!(acks.iter().all(|&count| count <= FEED_BATCH));
            assert_eq!(acks.iter().sum::<usize>(), 70);
        }
        let result = call(
            &knowledge,
            &store,
            "knowledge_filter_notes",
            json!({"filter":{"kind":"surrealql","ontologyId":"escriba","sql":"SELECT VALUE id FROM recording"}}),
        )
        .await
        .unwrap();
        assert_eq!(result["recordingIds"].as_array().unwrap().len(), 70);
        knowledge.close().await.unwrap();
    }

    #[tokio::test]
    async fn valida_dependencias_persistidas_version_y_origen_antes_de_abrir_el_grafo() {
        let temp = tempfile::tempdir().unwrap();
        let state = FakeLibrary::new();
        let record = state.lock().unwrap().add_recording(
            "nota",
            vec![json!({"id":"v1","createdAt":"2026-10-13T10:00:00+00:00","backend":"test","transcript":{"text":"Sintético","segments":[]}})],
        );
        let ontology = json!({"id":"example","name":"Ejemplo","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE topic SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON topic TYPE string;"}],"collections":[{"table":"topic","label":"Temas","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text","required":true}]}]});
        let dependency = json!({"id":"example","minVersion":1,"maxVersion":1});
        {
            let mut library = state.lock().unwrap();
            library.recipes.push(json!({"id":"graph","name":"Grafo","kind":"code","values":{},"bundle":"program","ontologies":[dependency]}));
            library.recipes.push(
                json!({"id":"form","name":"Formulario","kind":"form","base":"Grafo","values":{}}),
            );
            library.ontologies.push(ontology.clone());
        }
        let store = port(state.clone());
        let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
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
        let mut via_form = params.clone();
        via_form["recipeId"] = json!("form");
        assert_eq!(
            call(&graph, &store, "knowledge_open", via_form)
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
        let mut missing = params.clone();
        missing["recordingId"] = json!("otra");
        assert_eq!(
            call(&graph, &store, "knowledge_open", missing)
                .await
                .unwrap_err(),
            "Grabación no encontrada"
        );
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
        let attach = json!({"id":"example","expectedVersion":1,"recordId":"topic:a","recordingId":record["id"],"versionId":"v1"});
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
        state.lock().unwrap().recipes.clear();
        assert!(call(&graph, &store, "knowledge_open", params)
            .await
            .unwrap_err()
            .contains("No existe graph"));
        assert_eq!(graph.list().await.unwrap().len(), 1);
        graph.close().await.unwrap();
    }
}
