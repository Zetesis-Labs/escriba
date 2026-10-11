use crate::{
    catalog, knowledge::Knowledge, knowledge_commands::call as dispatch, store::Store,
    voices::SpeakerVoice,
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

fn library(path: &std::path::Path) -> (Arc<Mutex<Store>>, String) {
    let audio = path.join("sintetico.wav");
    std::fs::write(&audio, b"audio sintetico").unwrap();
    let mut store = Store::open(path.join("library")).unwrap();
    let recording = store.import(&audio, None).unwrap();
    catalog::install(&mut store, &json!({"recipes":[{"id":"sintetica","name":"Sintética","kind":"code","values":{},"bundle":"programa sintetico"}],"destinations":[],"ontologies":[extension()]})).unwrap();
    (
        Arc::new(Mutex::new(store)),
        recording["id"].as_str().unwrap().into(),
    )
}

async fn page(graph: &Knowledge, store: &Arc<Mutex<Store>>, table: &str) -> Value {
    dispatch(
        graph,
        store,
        "knowledge_records",
        json!({"id":"escriba","table":table}),
    )
    .await
    .unwrap()
}

async fn query(
    graph: &Knowledge,
    store: &Arc<Mutex<Store>>,
    recording: &str,
    sql: &str,
) -> DbValue {
    let result = dispatch(
        graph,
        store,
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
async fn base_dispatch_expone_biblioteca_con_sdk_cbor_sin_declaracion_ni_datos_privados() {
    let temporary = tempfile::tempdir().unwrap();
    let (store, recording) = library(temporary.path());
    {
        let mut store = store.lock().unwrap();
        store
            .add_person_voice(
                "Ana sintética",
                &SpeakerVoice {
                    speaker: "Speaker 1".into(),
                    model: "MODELO_PRIVADO".into(),
                    embedding: vec![0.25, 0.75],
                },
                "RUTA_PRIVADA",
            )
            .unwrap();
        store.mutate("version_save", &json!({"recordingId":recording,"backend":"sintetico","transcript":{"text":"Texto sintético","language":"es","segments":[{"start":0,"end":1,"text":"Texto sintético","speaker":"Ana sintética","secret":"EXTRA_PRIVADO","words":[{"start":0,"end":1,"text":"Texto","secret":"EXTRA_PRIVADO"}]}],"secret":"EXTRA_PRIVADO"},"inputs":{"token":"TOKEN_PRIVADO"},"data":{"secret":"DATO_PRIVADO"}})).unwrap();
    }
    let graph = Knowledge::open(&temporary.path().join("knowledge.surrealkv"))
        .await
        .unwrap();
    let listed = dispatch(&graph, &store, "knowledge_list", json!({}))
        .await
        .unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["id"], "escriba");
    assert_eq!(listed[0]["builtIn"], true);
    dispatch(
        &graph,
        &store,
        "knowledge_install",
        json!({"definition":extension()}),
    )
    .await
    .unwrap();
    let listed = dispatch(&graph, &store, "knowledge_list", json!({}))
        .await
        .unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 2);
    assert!(listed
        .as_array()
        .unwrap()
        .iter()
        .any(|o| o["id"] == "sintetica"));
    let opened = dispatch(&graph, &store, "knowledge_open", json!({"recipeId":"sintetica","recordingId":recording,"ontologyId":"escriba","dependency":{"id":"escriba","minVersion":1,"maxVersion":1}})).await.unwrap();
    assert_eq!(opened["version"], 1);
    let result = query(&graph, &store, &recording, "SELECT * FROM person; SELECT * FROM recording; SELECT * FROM version; SELECT * FROM transcript; SELECT * FROM segment; SELECT * FROM word;").await;
    let DbValue::Array(statements) = &result else {
        panic!("El SDK no devolvió un lote")
    };
    assert_eq!(statements.len(), 6);
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
        "EXTRA_PRIVADO",
        "TOKEN_PRIVADO",
        "DATO_PRIVADO",
        "embedding",
        "audioPath",
        "sourceKey",
    ] {
        assert!(!public.contains(forbidden), "Se expuso {forbidden}");
    }
    assert_eq!(count(&page(&graph, &store, "has_version").await), 1);
    assert_eq!(count(&page(&graph, &store, "has_word").await), 1);
    assert_eq!(
        count(&page(&graph, &store, "identified_as").await),
        0,
        "Un nombre histórico no prueba identidad"
    );
    let rejected = dispatch(
        &graph,
        &store,
        "knowledge_query",
        json!({
            "recipeId":"sintetica", "recordingId":recording, "ontologyId":"escriba",
            "dependency":{"id":"escriba","minVersion":1,"maxVersion":1},
            "expectedVersion":1,"sql":"UPDATE person SET name = 'Alterada'", "bindings":"oA=="
        }),
    )
    .await
    .unwrap_err();
    assert!(rejected.contains("consultas de lectura"), "{rejected}");
    let unchanged = query(&graph, &store, &recording, "SELECT VALUE name FROM person")
        .await
        .into_json_value();
    assert_eq!(unchanged[0][0], "Ana sintética");
    graph.close().await.unwrap();
}

#[tokio::test]
async fn base_dispatch_sincroniza_ediciones_borrados_y_reconstruye_un_grafo_perdido() {
    let temporary = tempfile::tempdir().unwrap();
    let (store, recording) = library(temporary.path());
    let graph_path = temporary.path().join("knowledge.surrealkv");
    let graph = Knowledge::open(&graph_path).await.unwrap();
    let epoch = graph.base_epoch().await.unwrap();
    assert_eq!(count(&page(&graph, &store, "recording").await), 1);
    store
        .lock()
        .unwrap()
        .mutate(
            "recording_update",
            &json!({"id":recording,"title":"Título corregido"}),
        )
        .unwrap();
    assert_eq!(
        page(&graph, &store, "recording").await["records"][0]["values"]["title"],
        "Título corregido"
    );
    store.lock().unwrap().mutate("version_save",&json!({"recordingId":recording,"transcript":{"text":"Primera versión","segments":[{"start":0,"end":1,"text":"Primera versión","words":[{"start":0,"end":1,"text":"Primera"}]}]}})).unwrap();
    assert_eq!(count(&page(&graph, &store, "version").await), 1);
    graph.close().await.unwrap();
    let graph = Knowledge::open(&graph_path).await.unwrap();
    assert_eq!(graph.base_epoch().await.unwrap(), epoch);
    assert_eq!(count(&page(&graph, &store, "word").await), 1);
    graph.close().await.unwrap();
    std::fs::remove_dir_all(&graph_path).unwrap();
    let graph = Knowledge::open(&graph_path).await.unwrap();
    assert_ne!(graph.base_epoch().await.unwrap(), epoch);
    assert_eq!(count(&page(&graph, &store, "recording").await), 1);
    assert_eq!(count(&page(&graph, &store, "version").await), 1);
    assert_eq!(count(&page(&graph, &store, "word").await), 1);
    store
        .lock()
        .unwrap()
        .mutate("recording_discard", &json!({"id":recording}))
        .unwrap();
    for table in [
        "recording",
        "version",
        "transcript",
        "segment",
        "word",
        "has_version",
        "has_word",
    ] {
        assert_eq!(
            count(&page(&graph, &store, table).await),
            0,
            "{table} retuvo contenido descartado"
        );
    }
    graph.close().await.unwrap();
}

#[tokio::test]
async fn base_dispatch_ampliacion_reutiliza_persona_y_conserva_referencia_huerfana_sin_recrearla() {
    let temporary = tempfile::tempdir().unwrap();
    let (store, _) = library(temporary.path());
    store
        .lock()
        .unwrap()
        .add_person_voice(
            "Ana",
            &SpeakerVoice {
                speaker: "Speaker 1".into(),
                model: "sintetico".into(),
                embedding: vec![0.5],
            },
            "sintetico",
        )
        .unwrap();
    let graph = Knowledge::open(&temporary.path().join("knowledge.surrealkv"))
        .await
        .unwrap();
    dispatch(
        &graph,
        &store,
        "knowledge_install",
        json!({"definition":extension()}),
    )
    .await
    .unwrap();
    let people = page(&graph, &store, "person").await;
    let reference =
        json!({"ontologyId":"escriba","table":"person","id":people["records"][0]["id"]});
    let saved = dispatch(&graph,&store,"knowledge_save",json!({"id":"sintetica","table":"annotation","expectedVersion":1,"values":{"title":"Acuerdo","person":reference}})).await.unwrap();
    assert_eq!(saved["values"]["person"], reference);
    assert_eq!(count(&page(&graph, &store, "person").await), 1);
    store.lock().unwrap().remove_person("Ana").unwrap();
    assert_eq!(count(&page(&graph, &store, "person").await), 0);
    let corrected = dispatch(&graph,&store,"knowledge_save",json!({"id":"sintetica","table":"annotation","expectedVersion":1,"recordId":saved["id"],"expectedRev":saved["rev"],"values":{"title":"Acuerdo corregido","person":reference}})).await.unwrap();
    assert_eq!(corrected["values"]["person"], reference);
    let rejected = dispatch(&graph,&store,"knowledge_save",json!({"id":"sintetica","table":"annotation","expectedVersion":1,"values":{"title":"Nueva referencia inexistente","person":reference}})).await.unwrap_err();
    assert!(rejected.contains("no existe"), "{rejected}");
    assert_eq!(count(&page(&graph, &store, "person").await), 0);
    graph.close().await.unwrap();
}
