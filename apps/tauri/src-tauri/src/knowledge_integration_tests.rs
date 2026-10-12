use crate::{
    catalog, knowledge::Knowledge, knowledge_commands, native, project, scripts, store::Store,
};
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};

#[tokio::test]
async fn receta_empaquetada_ejecuta_sdk_sobre_grafo_real_y_conserva_vinculos_al_cambiar_proyecto() {
    let temporary = tempfile::tempdir().unwrap();
    let project_root = temporary.path().join("proyecto");
    let recipe_root = project_root.join("recetas/grafo");
    std::fs::create_dir_all(&recipe_root).unwrap();
    std::fs::write(recipe_root.join("receta.ts"), r#"
import { RecordId, Table } from "surrealdb";
export const receta = { nombre: "Grafo sintético" };
export const ontologias = [{ id: "ejemplo.grafo", minVersion: 1, maxVersion: 1 }];
export async function flujo(audio, api) {
  const base = await api.grafo("escriba");
  const recordings = await base.query("SELECT id FROM recording");
  if (!(recordings[0]?.[0]?.id instanceof RecordId)) throw Error("La base no conserva la identidad de la grabación");
  const db = await api.grafo("ejemplo.grafo");
  const ada = new RecordId("person", "ada");
  const grace = new RecordId("person", "grace");
  await db.create(ada).content({ name: "Ada" });
  await db.create(grace).content({ name: "Grace" });
  await db.relate(ada, new Table("knows"), grace, { since: "2026-10-11" });
  const selected = await db.select(ada);
  if (!selected || selected.name !== "Ada" || !(selected.id instanceof RecordId)) throw Error("SDK perdió el registro tipado");
  const names = await db.query("SELECT VALUE ->knows->person.name FROM person:ada");
  if (names[0]?.[0]?.[0] !== "Grace") throw Error("No se recorrió la relación");
  const note = await api.transcribir(audio);
  await note.guardar();
  const transcripts = await base.query("SELECT id, text FROM transcript");
  if (transcripts[0]?.[0]?.text !== "Audio sintético" || !(transcripts[0]?.[0]?.id instanceof RecordId)) throw Error("La base no sincronizó la nota confirmada");
  await note.vincular("ejemplo.grafo", "person:ada");
}
"#).unwrap();

    let runtime = native::binary("escriba-runtime").unwrap();
    let vendor = Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor");
    let modules = project_root.join("node_modules");
    std::fs::create_dir_all(&modules).unwrap();
    std::os::unix::fs::symlink(
        vendor.join("node_modules/surrealdb"),
        modules.join("surrealdb"),
    )
    .unwrap();
    let built = project::build(&project_root, &runtime, &vendor).unwrap();
    let ontology = json!({
        "id":"ejemplo.grafo", "name":"Personas", "version":1,
        "migrations":[{"version":1,"sql":"DEFINE TABLE person SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON person TYPE string; DEFINE TABLE knows TYPE RELATION IN person OUT person ENFORCED SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD since ON knows TYPE string;"}],
        "collections":[
            {"table":"person","label":"Personas","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text","required":true}]},
            {"table":"knows","label":"Conoce","titleField":"since","fields":[{"key":"since","label":"Desde","type":"text"}],"relation":{"from":"person","to":"person"}}
        ]
    });
    let dependency = json!({"id":"ejemplo.grafo","minVersion":1,"maxVersion":1});
    let mut compiled = built["recipes"][0].clone();
    compiled["ontologies"] = json!([dependency]);

    let audio = temporary.path().join("audio-sintetico.wav");
    std::fs::write(&audio, b"audio sintetico").unwrap();
    let library_path = temporary.path().join("library.rocksdb");
    let knowledge_path = temporary.path().join("knowledge.rocksdb");
    let mut store = Store::open(library_path.clone()).unwrap();
    let recording = store.import(&audio, Some("grafo")).unwrap();
    let recording_id = recording["id"].as_str().unwrap().to_string();
    catalog::install(
        &mut store,
        &json!({"recipes":[compiled],"destinations":[],"ontologies":[ontology.clone()]}),
    )
    .unwrap();
    let store = Arc::new(Mutex::new(store));
    let graph = Arc::new(Knowledge::open(&knowledge_path).await.unwrap());
    knowledge_commands::call(
        &graph,
        &store,
        "knowledge_install",
        json!({"definition":ontology}),
    )
    .await
    .unwrap();

    let capability: scripts::Capability = Arc::new({
        let store = store.clone();
        let graph = graph.clone();
        move |method, params, _task, lease| {
            let store = store.clone();
            let graph = graph.clone();
            Box::pin(async move {
                lease.ensure_active()?;
                let response = if method.starts_with("knowledge_") {
                    knowledge_commands::call(&graph, &store, &method, params).await
                } else if method == "runtime_context" {
                    store
                        .lock()
                        .unwrap()
                        .runtime_context(params["recordingId"].as_str())
                } else if method == "transcribe" {
                    Ok(json!({"text":"Audio sintético","segments":[]}))
                } else if matches!(
                    method.as_str(),
                    "recording_update"
                        | "version_save"
                        | "version_select"
                        | "version_update"
                        | "account_effect_begin"
                        | "account_effect_finish"
                        | "log"
                ) {
                    store.lock().unwrap().mutate(&method, &params)
                } else if method == "trace_save" {
                    store
                        .lock()
                        .unwrap()
                        .trace_save(&params)
                        .map(|_| Value::Null)
                } else if method == "memory_recall" {
                    Ok(Value::Null)
                } else {
                    Err(format!("Capacidad inesperada: {method}"))
                };
                response.map_err(Into::into)
            })
        }
    });
    let scripts = scripts::Scripts::new(runtime);
    tokio::time::timeout(
        Duration::from_secs(40),
        scripts.call(
            "graph-real",
            "processRecording",
            json!({"recordingId":recording_id}),
            capability.clone(),
            Arc::new(|_| {}),
        ),
    )
    .await
    .unwrap()
    .unwrap();

    let note = store.lock().unwrap().recording(&recording_id).unwrap();
    assert_eq!(note["versions"].as_array().unwrap().len(), 1);
    let linked = graph
        .records("ejemplo.grafo", "person", 0, Some(&recording_id), None)
        .await
        .unwrap();
    assert_eq!(linked.records.len(), 1);
    assert_eq!(linked.records[0].values["name"], "Ada");
    assert_eq!(
        graph
            .records("ejemplo.grafo", "knows", 0, None, None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );

    catalog::install(
        &mut store.lock().unwrap(),
        &json!({"recipes":[],"destinations":[]}),
    )
    .unwrap();
    drop(scripts);
    drop(capability);
    drop(store);
    for _ in 0..40 {
        if Arc::strong_count(&graph) == 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    Arc::try_unwrap(graph).ok().unwrap().close().await.unwrap();
    let reopened_store = Store::open(library_path).unwrap();
    let reopened_graph = Knowledge::open(&knowledge_path).await.unwrap();
    assert_eq!(
        reopened_store.recording(&recording_id).unwrap()["versions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(reopened_graph.list().await.unwrap().len(), 1);
    assert_eq!(
        reopened_graph
            .records("ejemplo.grafo", "person", 0, Some(&recording_id), None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
}
