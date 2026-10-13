use crate::{
    knowledge::Knowledge,
    knowledge_commands::{
        call,
        testing::{port, FakeLibrary},
    },
};
use base64::Engine;
use serde_json::json;
use surrealdb::types::Value as DbValue;

#[tokio::test]
async fn grafo_real_conserva_consultas_tipos_y_vinculos_al_reabrir() {
    let temporary = tempfile::tempdir().unwrap();
    let graph_path = temporary.path().join("knowledge.rocksdb");
    let state = FakeLibrary::new();
    let ontology = json!({
        "id":"ejemplo.grafo","name":"Personas","version":1,
        "migrations":[{"version":1,"sql":"DEFINE TABLE person SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON person TYPE string; DEFINE TABLE knows TYPE RELATION IN person OUT person ENFORCED SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD since ON knows TYPE string;"}],
        "collections":[
            {"table":"person","label":"Personas","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text","required":true}]},
            {"table":"knows","label":"Conoce","titleField":"since","fields":[{"key":"since","label":"Desde","type":"text"}],"relation":{"from":"person","to":"person"}}
        ]
    });
    let dependency = json!({"id":"ejemplo.grafo","minVersion":1,"maxVersion":1});
    {
        let mut library = state.lock().unwrap();
        library.recipes.push(json!({"id":"graph-real","name":"Grafo","kind":"code","bundle":"programa sintético","ontologies":[dependency]}));
        library.ontologies.push(ontology.clone());
        library.add_recording(
            "nota",
            vec![json!({"id":"v1","transcript":{"text":"Audio sintético","segments":[]}})],
        );
    }
    let adapter = port(state.clone());
    let graph = Knowledge::open(&graph_path).await.unwrap();
    call(
        &graph,
        &adapter,
        "knowledge_install",
        json!({"definition":ontology}),
    )
    .await
    .unwrap();
    assert_eq!(call(&graph, &adapter, "knowledge_open", json!({"recipeId":"graph-real","recordingId":"nota","ontologyId":"ejemplo.grafo","dependency":dependency})).await.unwrap()["version"], 1);
    let query = |sql: &str| {
        json!({
            "recipeId":"graph-real","recordingId":"nota","ontologyId":"ejemplo.grafo",
            "dependency":dependency,"expectedVersion":1,"sql":sql,"bindings":"oA=="
        })
    };
    call(&graph, &adapter, "knowledge_query", query("CREATE person:ada CONTENT { name: 'Ada' }; CREATE person:grace CONTENT { name: 'Grace' }; RELATE person:ada->knows->person:grace SET since='2026-10-11'")).await.unwrap();
    let result = call(
        &graph,
        &adapter,
        "knowledge_query",
        query("SELECT * FROM person:ada; SELECT VALUE ->knows->person.name FROM person:ada"),
    )
    .await
    .unwrap();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(result.as_str().unwrap())
        .unwrap();
    let decoded = surrealdb_core::rpc::format::cbor::decode(&bytes, 64).unwrap();
    let DbValue::Array(statements) = &decoded else {
        panic!("El SDK no devolvió un lote")
    };
    let DbValue::Array(records) = &statements[0] else {
        panic!("La consulta no devolvió registros")
    };
    let DbValue::Object(ada) = &records[0] else {
        panic!("Ada no es un registro")
    };
    assert!(matches!(ada.get("id"), Some(DbValue::RecordId(_))));
    let public = decoded.into_json_value();
    assert_eq!(public[0][0]["name"], "Ada");
    assert_eq!(public[1][0][0], "Grace");
    call(
        &graph,
        &adapter,
        "knowledge_link",
        json!({
            "recipeId":"graph-real","recordingId":"nota","ontologyId":"ejemplo.grafo",
            "dependency":dependency,"expectedVersion":1,"versionId":"v1","recordId":"person:ada"
        }),
    )
    .await
    .unwrap();
    assert_eq!(
        graph
            .records("ejemplo.grafo", "person", 0, Some("nota"), None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
    graph.close().await.unwrap();

    state.lock().unwrap().recipes.clear();
    let reopened = Knowledge::open(&graph_path).await.unwrap();
    assert_eq!(reopened.list().await.unwrap().len(), 1);
    assert_eq!(
        reopened
            .records("ejemplo.grafo", "person", 0, Some("nota"), None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
    assert_eq!(
        reopened
            .records("ejemplo.grafo", "knows", 0, None, None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
    reopened.close().await.unwrap();
}
