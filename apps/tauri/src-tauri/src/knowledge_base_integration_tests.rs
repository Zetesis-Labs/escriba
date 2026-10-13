use crate::{
    knowledge::Knowledge,
    knowledge_commands::{
        call,
        testing::{port, FakeLibrary},
        LibraryPort,
    },
};
use base64::Engine;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use surrealdb::types::Value as DbValue;

fn extension() -> Value {
    json!({
        "id":"sintetica", "name":"Ampliación sintética", "version":1,
        "migrations":[{"version":1,"sql":"DEFINE TABLE annotation SCHEMALESS PERMISSIONS FULL;"}],
        "collections":[{"table":"annotation","label":"Anotaciones","titleField":"title","fields":[
            {"key":"title","label":"Título","type":"text","required":true},
            {"key":"person","label":"Persona","type":"reference","reference":{"ontologyId":"escriba","table":"person"}}
        ]}]
    })
}

fn library() -> (Arc<Mutex<FakeLibrary>>, LibraryPort) {
    let state = FakeLibrary::new();
    {
        let mut library = state.lock().unwrap();
        library.recipes.push(json!({"id":"sintetica","name":"Sintética","kind":"code","values":{},"bundle":"programa sintético"}));
        library.ontologies.push(extension());
    }
    let adapter = port(state.clone());
    (state, adapter)
}

async fn page(graph: &Knowledge, adapter: &LibraryPort, table: &str) -> Value {
    call(
        graph,
        adapter,
        "knowledge_records",
        json!({"id":"escriba","table":table}),
    )
    .await
    .unwrap()
}

async fn query(graph: &Knowledge, adapter: &LibraryPort, recording: &str, sql: &str) -> DbValue {
    let result = call(
        graph,
        adapter,
        "knowledge_query",
        json!({
            "recipeId":"sintetica", "recordingId":recording, "ontologyId":"escriba",
            "dependency":{"id":"escriba","minVersion":1,"maxVersion":1},
            "expectedVersion":1,"sql":sql,"bindings":"oA=="
        }),
    )
    .await
    .unwrap();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(result.as_str().unwrap())
        .unwrap();
    surrealdb_core::rpc::format::cbor::decode(&bytes, 64).unwrap()
}

fn count(page: &Value) -> usize {
    page["records"].as_array().unwrap().len()
}

#[tokio::test]
async fn base_dispatch_expone_cbor_sin_datos_privados_y_rechaza_escritura_de_receta() {
    let temporary = tempfile::tempdir().unwrap();
    let (state, adapter) = library();
    {
        let mut library = state.lock().unwrap();
        library.put_person("ana", "Ana sintética");
        library.add_recording("nota", vec![json!({
            "id":"v1","createdAt":"2026-10-13T10:00:00+00:00", "backend":"sintetico",
            "transcript":{"text":"Texto sintético","language":"es","segments":[{
                "start":0,"end":1,"text":"Texto sintético","speaker":"Ana sintética",
                "secret":"EXTRA_PRIVADO","words":[{"start":0,"end":1,"text":"Texto","secret":"EXTRA_PRIVADO"}]
            }],"secret":"EXTRA_PRIVADO"},
            "inputs":{"token":"TOKEN_PRIVADO"},"digest":{"secret":"DATO_PRIVADO"}
        })]);
        library.people[0]["embedding"] = json!([0.25, 0.75]);
        library.people[0]["model"] = json!("MODELO_PRIVADO");
        library.recordings[0]["audioPath"] = json!("RUTA_PRIVADA");
        library.recordings[0]["sourceKey"] = json!("ORIGEN_PRIVADO");
        library.mark_dirty("nota");
    }
    let graph = Knowledge::open(&temporary.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let listed = call(&graph, &adapter, "knowledge_list", json!({}))
        .await
        .unwrap();
    assert_eq!(listed[0]["id"], "escriba");
    assert_eq!(listed[0]["builtIn"], true);
    call(
        &graph,
        &adapter,
        "knowledge_install",
        json!({"definition":extension()}),
    )
    .await
    .unwrap();
    assert_eq!(
        call(&graph, &adapter, "knowledge_list", json!({}))
            .await
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(call(&graph, &adapter, "knowledge_open", json!({"recipeId":"sintetica","recordingId":"nota","ontologyId":"escriba","dependency":{"id":"escriba","minVersion":1,"maxVersion":1}})).await.unwrap()["version"], 1);
    let result = query(&graph, &adapter, "nota", "SELECT * FROM person; SELECT * FROM recording; SELECT * FROM version; SELECT * FROM transcript; SELECT * FROM segment;").await;
    let DbValue::Array(statements) = &result else {
        panic!("El SDK no devolvió un lote")
    };
    assert_eq!(statements.len(), 5);
    for statement in statements.iter() {
        let DbValue::Array(records) = statement else {
            panic!("Consulta sin registros")
        };
        assert_eq!(records.len(), 1);
        let DbValue::Object(record) = &records[0] else {
            panic!("Registro inválido")
        };
        assert!(matches!(record.get("id"), Some(DbValue::RecordId(_))));
    }
    let public = result.into_json_value().to_string();
    for forbidden in [
        "MODELO_PRIVADO",
        "RUTA_PRIVADA",
        "ORIGEN_PRIVADO",
        "EXTRA_PRIVADO",
        "TOKEN_PRIVADO",
        "DATO_PRIVADO",
        "embedding",
        "audioPath",
        "sourceKey",
    ] {
        assert!(!public.contains(forbidden), "Se expuso {forbidden}");
    }
    assert_eq!(count(&page(&graph, &adapter, "has_version").await), 1);
    assert_eq!(count(&page(&graph, &adapter, "identified_as").await), 0);
    let rejected = call(
        &graph,
        &adapter,
        "knowledge_query",
        json!({
            "recipeId":"sintetica","recordingId":"nota","ontologyId":"escriba",
            "dependency":{"id":"escriba","minVersion":1,"maxVersion":1},
            "expectedVersion":1,"sql":"UPDATE person SET name = 'Alterada'","bindings":"oA=="
        }),
    )
    .await
    .unwrap_err();
    assert!(rejected.contains("consultas de lectura"), "{rejected}");
    assert_eq!(
        query(&graph, &adapter, "nota", "SELECT VALUE name FROM person")
            .await
            .into_json_value()[0][0],
        "Ana sintética"
    );
    graph.close().await.unwrap();
}

#[tokio::test]
async fn base_dispatch_sincroniza_cambios_borrados_y_reconstruye_grafo_perdido() {
    let temporary = tempfile::tempdir().unwrap();
    let (state, adapter) = library();
    state.lock().unwrap().add_recording("nota", vec![]);
    let graph_path = temporary.path().join("knowledge.rocksdb");
    let graph = Knowledge::open(&graph_path).await.unwrap();
    let epoch = graph.base_epoch().await.unwrap();
    assert_eq!(count(&page(&graph, &adapter, "recording").await), 1);
    {
        let mut library = state.lock().unwrap();
        library.recordings[0]["title"] = json!("Título corregido");
        library.mark_dirty("nota");
    }
    assert_eq!(
        page(&graph, &adapter, "recording").await["records"][0]["values"]["title"],
        "Título corregido"
    );
    {
        let mut library = state.lock().unwrap();
        library.recordings[0]["versions"] = json!([{"id":"v1","transcript":{"text":"Primera versión","segments":[{"start":0,"end":1,"text":"Primera versión","words":[{"start":0,"end":1,"text":"Primera"}]}]}}]);
        library.recordings[0]["currentVersionId"] = json!("v1");
        library.mark_dirty("nota");
    }
    assert_eq!(count(&page(&graph, &adapter, "version").await), 1);
    graph.close().await.unwrap();
    let graph = Knowledge::open(&graph_path).await.unwrap();
    assert_eq!(graph.base_epoch().await.unwrap(), epoch);
    assert_eq!(
        page(&graph, &adapter, "segment").await["records"][0]["values"]["words"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    graph.close().await.unwrap();
    std::fs::remove_dir_all(&graph_path).unwrap();
    let graph = Knowledge::open(&graph_path).await.unwrap();
    assert_ne!(graph.base_epoch().await.unwrap(), epoch);
    assert_eq!(count(&page(&graph, &adapter, "version").await), 1);
    {
        let mut library = state.lock().unwrap();
        library.recordings[0]["status"] = json!("discarded");
        library.mark_dirty("nota");
    }
    for table in [
        "recording",
        "version",
        "transcript",
        "segment",
        "has_version",
        "speaker",
    ] {
        assert_eq!(
            count(&page(&graph, &adapter, table).await),
            0,
            "{table} retuvo contenido descartado"
        );
    }
    graph.close().await.unwrap();
}

#[tokio::test]
async fn ampliacion_conserva_referencia_huerfana_sin_permitir_otra_nueva() {
    let temporary = tempfile::tempdir().unwrap();
    let (state, adapter) = library();
    state.lock().unwrap().put_person("ana", "Ana");
    let graph = Knowledge::open(&temporary.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    call(
        &graph,
        &adapter,
        "knowledge_install",
        json!({"definition":extension()}),
    )
    .await
    .unwrap();
    let people = page(&graph, &adapter, "person").await;
    let reference =
        json!({"ontologyId":"escriba","table":"person","id":people["records"][0]["id"]});
    let saved = call(&graph, &adapter, "knowledge_save", json!({"id":"sintetica","table":"annotation","expectedVersion":1,"values":{"title":"Acuerdo","person":reference}})).await.unwrap();
    assert_eq!(saved["values"]["person"], reference);
    state.lock().unwrap().remove_person("ana");
    assert_eq!(count(&page(&graph, &adapter, "person").await), 0);
    let corrected = call(&graph, &adapter, "knowledge_save", json!({"id":"sintetica","table":"annotation","expectedVersion":1,"recordId":saved["id"],"expectedRev":saved["rev"],"values":{"title":"Acuerdo corregido","person":reference}})).await.unwrap();
    assert_eq!(corrected["values"]["person"], reference);
    let rejected = call(&graph, &adapter, "knowledge_save", json!({"id":"sintetica","table":"annotation","expectedVersion":1,"values":{"title":"Nueva referencia inexistente","person":reference}})).await.unwrap_err();
    assert!(rejected.contains("no existe"), "{rejected}");
    graph.close().await.unwrap();
}
