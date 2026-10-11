use crate::{
    knowledge::{Knowledge, LibraryFilter, Ontology, SaveLibraryFilter, SaveRecord, Source},
    store::{text, Store},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
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

fn requirement(store: &Store, p: &Value) -> Result<Dependency, String> {
    let mut recipe = store.item("recipes", text(p, "recipeId")?)?;
    if recipe["kind"] == "form" {
        let base = text(&recipe, "base")?;
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
    let id = text(p, "ontologyId")?;
    let declared = dependencies(recipe.get("ontologies"))?
        .into_iter()
        .find(|d| d.id == id)
        .or_else(|| {
            (id == "escriba").then(|| Dependency {
                id: "escriba".into(),
                min_version: 1,
                max_version: 1,
            })
        })
        .ok_or("La receta no declara esta ontología")?;
    let expected: Dependency = serde_json::from_value(p["dependency"].clone())
        .map_err(|_| "Dependencia de ontología inválida")?;
    if declared != expected {
        return Err("Las dependencias de la receta cambiaron; vuelve a procesar".into());
    }
    let recording_id = text(p, "recordingId")?;
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

fn source(store: &Store, p: &Value, recipe_id: Option<String>) -> Result<Source, String> {
    let recording_id = text(p, "recordingId")?;
    let version_id = text(p, "versionId")?;
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

fn version(p: &Value) -> Result<u32, String> {
    p["expectedVersion"]
        .as_u64()
        .and_then(|v| u32::try_from(v).ok())
        .filter(|v| *v > 0)
        .ok_or_else(|| "Versión de ontología inválida".into())
}

async fn synchronize_base<'a>(
    knowledge: &'a Knowledge,
    store: &Arc<Mutex<Store>>,
) -> Result<tokio::sync::MutexGuard<'a, ()>, String> {
    let guard = knowledge.base_sync.lock().await;
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
            return Ok(guard);
        };
        knowledge.sync_base_change(&change).await?;
        store
            .lock()
            .map_err(|_| "Biblioteca no disponible")?
            .knowledge_ack(&change.key, &change.revision)?;
    }
}

pub async fn dispatch(
    knowledge: &Knowledge,
    store: &Arc<Mutex<Store>>,
    method: &str,
    p: Value,
) -> Result<Value, String> {
    match method {
        "knowledge_filter_notes" => {
            let filter: LibraryFilter = serde_json::from_value(p["filter"].clone())
                .map_err(|e| format!("Filtro de Biblioteca inválido: {e}"))?;
            let _base_guard = synchronize_base(knowledge, store).await?;
            Ok(json!(knowledge.filter_notes(filter).await?))
        }
        "knowledge_filters_list" => Ok(json!(knowledge.saved_filters().await?)),
        "knowledge_filter_save" => {
            let filter: SaveLibraryFilter = serde_json::from_value(p["filter"].clone())
                .map_err(|e| format!("Filtro guardado inválido: {e}"))?;
            Ok(json!(knowledge.save_filter(filter).await?))
        }
        "knowledge_filter_remove" => {
            knowledge.remove_filter(text(&p, "id")?).await?;
            Ok(Value::Null)
        }
        "knowledge_list" => {
            let mut listed = vec![crate::knowledge::base_listing()];
            for ontology in knowledge.list().await? {
                listed.push(json!(ontology));
            }
            Ok(json!(listed))
        }
        "knowledge_install" => {
            let definition: Ontology = serde_json::from_value(p["definition"].clone())
                .map_err(|_| "Ontología inválida")?;
            let candidates = store
                .lock()
                .map_err(|_| "Biblioteca no disponible")?
                .data
                .settings
                .project_ontologies
                .as_ref()
                .cloned()
                .unwrap_or_default();
            if !candidates.contains(&definition) {
                return Err(
                    "La ontología del proyecto cambió; actualiza la lista antes de instalar".into(),
                );
            }
            Ok(json!(knowledge.apply(definition).await?))
        }
        "knowledge_open" | "knowledge_query" | "knowledge_link" => {
            let required = {
                let store = store.lock().map_err(|_| "Biblioteca no disponible")?;
                requirement(&store, &p)?
            };
            let installed = if required.id == "escriba" {
                crate::knowledge::base_definition()
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
            if method == "knowledge_open" {
                return Ok(json!({"version":installed.version}));
            }
            if method == "knowledge_query" {
                let _base_guard = if required.id == "escriba" {
                    Some(synchronize_base(knowledge, store).await?)
                } else {
                    None
                };
                return Ok(json!(
                    knowledge
                        .query_cbor(
                            &required.id,
                            version(&p)?,
                            text(&p, "sql")?,
                            text(&p, "bindings")?
                        )
                        .await?
                ));
            }
            let provenance = {
                let store = store.lock().map_err(|_| "Biblioteca no disponible")?;
                source(&store, &p, Some(text(&p, "recipeId")?.into()))?
            };
            knowledge
                .link(
                    &required.id,
                    version(&p)?,
                    text(&p, "recordId")?,
                    provenance,
                )
                .await?;
            Ok(Value::Null)
        }
        "knowledge_graph_roots" | "knowledge_graph_expand" | "knowledge_graph_detail" => {
            let ontology = text(&p, "ontologyId")?;
            let page = p
                .get("page")
                .map(|v| {
                    v.as_u64()
                        .and_then(|v| u32::try_from(v).ok())
                        .ok_or("Página inválida")
                })
                .transpose()?
                .unwrap_or(0);
            let _base_guard = synchronize_base(knowledge, store).await?;
            match method {
                "knowledge_graph_roots" => Ok(json!(
                    knowledge
                        .graph_roots(ontology, text(&p, "table")?, page)
                        .await?
                )),
                "knowledge_graph_expand" => Ok(json!(
                    knowledge
                        .graph_expand(ontology, text(&p, "recordId")?, page)
                        .await?
                )),
                _ => Ok(json!(
                    knowledge
                        .graph_detail(ontology, text(&p, "recordId")?)
                        .await?
                )),
            }
        }
        "knowledge_records" => {
            let _base_guard = if text(&p, "id")? == "escriba" {
                Some(synchronize_base(knowledge, store).await?)
            } else {
                None
            };
            let page = p
                .get("page")
                .map(|v| {
                    v.as_u64()
                        .and_then(|v| u32::try_from(v).ok())
                        .ok_or("Página inválida")
                })
                .transpose()?
                .unwrap_or(0);
            Ok(json!(
                knowledge
                    .records(
                        text(&p, "id")?,
                        text(&p, "table")?,
                        page,
                        p["recordingId"].as_str(),
                        p["versionId"].as_str()
                    )
                    .await?
            ))
        }
        "knowledge_save" => {
            let _base_guard = synchronize_base(knowledge, store).await?;
            let provenance = if p.get("recordingId").is_some() {
                let store = store.lock().map_err(|_| "Biblioteca no disponible")?;
                Some(source(&store, &p, None)?)
            } else {
                None
            };
            let request = SaveRecord {
                ontology_id: text(&p, "id")?.into(),
                expected_version: version(&p)?,
                table: text(&p, "table")?.into(),
                record_id: p["recordId"].as_str().map(str::to_owned),
                expected_rev: p["expectedRev"].as_str().map(str::to_owned),
                values: p["values"].clone(),
                source: provenance,
            };
            Ok(json!(knowledge.save(request).await?))
        }
        "knowledge_delete" => {
            knowledge
                .delete(
                    text(&p, "id")?,
                    version(&p)?,
                    text(&p, "table")?,
                    text(&p, "recordId")?,
                    text(&p, "expectedRev")?,
                )
                .await?;
            Ok(Value::Null)
        }
        "knowledge_unlink" => {
            knowledge
                .unlink(
                    text(&p, "id")?,
                    version(&p)?,
                    text(&p, "recordId")?,
                    text(&p, "recordingId")?,
                )
                .await?;
            Ok(Value::Null)
        }
        "knowledge_attach" => {
            let provenance = {
                let store = store.lock().map_err(|_| "Biblioteca no disponible")?;
                source(&store, &p, None)?
            };
            knowledge
                .link(
                    text(&p, "id")?,
                    version(&p)?,
                    text(&p, "recordId")?,
                    provenance,
                )
                .await?;
            Ok(Value::Null)
        }
        _ => Err("Operación de conocimiento desconocida".into()),
    }
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
        let result = dispatch(
            &knowledge,
            &store,
            "knowledge_filter_notes",
            json!({"filter":filter}),
        )
        .await
        .unwrap();
        assert_eq!(result, json!({"recordingIds":[record["id"]]}));
        let saved = dispatch(
            &knowledge,
            &store,
            "knowledge_filter_save",
            json!({"filter":{"name":"Todas","ontologyId":"escriba","sql":filter["sql"]}}),
        )
        .await
        .unwrap();
        assert_eq!(
            dispatch(&knowledge, &store, "knowledge_filters_list", json!({}))
                .await
                .unwrap(),
            json!([saved])
        );
        dispatch(
            &knowledge,
            &store,
            "knowledge_filter_remove",
            json!({"id":saved["id"]}),
        )
        .await
        .unwrap();
        assert_eq!(
            dispatch(&knowledge, &store, "knowledge_filters_list", json!({}))
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
        let unavailable = dispatch(&graph, &store, "knowledge_open", params.clone())
            .await
            .unwrap_err();
        assert!(unavailable.contains("Instala"), "{unavailable}");
        dispatch(
            &graph,
            &store,
            "knowledge_install",
            json!({"definition":ontology}),
        )
        .await
        .unwrap();
        assert_eq!(
            dispatch(&graph, &store, "knowledge_open", params.clone())
                .await
                .unwrap(),
            json!({"version":1})
        );
        let mut forged = params.clone();
        forged["dependency"]["maxVersion"] = json!(99);
        assert!(dispatch(&graph, &store, "knowledge_open", forged)
            .await
            .unwrap_err()
            .contains("cambiaron"));
        let mut query = params.clone();
        query["expectedVersion"] = json!(2);
        query["sql"] = json!("CREATE topic:a SET name = 'Prueba'");
        query["bindings"] = json!("oA==");
        assert!(dispatch(&graph, &store, "knowledge_query", query.clone())
            .await
            .is_err());
        query["expectedVersion"] = json!(1);
        dispatch(&graph, &store, "knowledge_query", query)
            .await
            .unwrap();
        let attach = json!({"id":"example","expectedVersion":1,"recordId":"topic:a","recordingId":record["id"],"versionId":version["id"]});
        let mut invalid = attach.clone();
        invalid["versionId"] = json!("otra");
        assert!(dispatch(&graph, &store, "knowledge_attach", invalid)
            .await
            .is_err());
        dispatch(&graph, &store, "knowledge_attach", attach.clone())
            .await
            .unwrap();
        let page = dispatch(
            &graph,
            &store,
            "knowledge_records",
            json!({"id":"example","table":"topic","recordingId":record["id"]}),
        )
        .await
        .unwrap();
        assert_eq!(page["records"].as_array().unwrap().len(), 1);
        dispatch(&graph, &store, "knowledge_unlink", attach)
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
        assert!(dispatch(&graph, &store, "knowledge_open", params)
            .await
            .unwrap_err()
            .contains("disponible"));
        assert_eq!(graph.list().await.unwrap().len(), 1);
        graph.close().await.unwrap();
    }
}
