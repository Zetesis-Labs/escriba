use super::*;
use serde_json::json;

#[tokio::test]
async fn la_base_expone_la_biblioteca_y_solo_permite_consultarla() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let change = crate::persistence::CoreChange {
        key: "recording:audio".into(),
        revision: "one".into(),
        kind: "recording".into(),
        id: "audio".into(),
        value: Some(
            json!({"id":"audio","title":"Prueba","status":"done","currentVersionId":"v1","versions":[{"id":"v1","transcript":{"text":"Hola mundo","segments":[{"start":0,"end":2,"text":"Hola mundo","speaker":"Ada","words":[{"text":"Hola","start":0,"end":1},{"text":"mundo","start":1,"end":2}]}]}}]}),
        ),
    };
    graph.sync_base_change(&change).await.unwrap();
    let rows = graph
        .query("escriba", 1, "SELECT text FROM segment", json!({}))
        .await
        .unwrap();
    assert_eq!(rows, vec![json!([{"text":"Hola mundo"}])]);
    assert_eq!(
        graph
            .query("escriba", 1, "SELECT VALUE words FROM segment", json!({}))
            .await
            .unwrap(),
        vec![json!([[{"text":"Hola","start":0,"end":1},{"text":"mundo","start":1,"end":2}]])]
    );
    assert_eq!(
        tables(&graph)
            .await
            .iter()
            .filter(|t| t.contains("word"))
            .count(),
        0
    );
    assert_eq!(graph.query("escriba",1,"SELECT VALUE ->has_version->version->has_transcript->transcript<~segment.text FROM recording",json!({})).await.unwrap(), vec![json!([["Hola mundo"]])]);
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE <~segment.text FROM speaker",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([["Hola mundo"]])]
    );
    let db = selected(&graph.root, "escriba").await.unwrap();
    let mut reverse = db
        .query("LET $t = (SELECT VALUE id FROM transcript)[0]; SELECT VALUE id FROM segment WHERE id IN $t<~segment; SELECT VALUE id FROM segment WHERE id IN $t<~(segment FIELD transcript)")
        .await
        .unwrap();
    let plain: Vec<Value> = reverse.take(1).unwrap();
    let field: Vec<Value> = reverse.take(2).unwrap();
    assert_eq!((plain.len(), field.len()), (1, 1));
    drop(db);
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE transcript.text FROM segment",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!(["Hola mundo"])]
    );
    let failed = graph
        .query(
            "escriba",
            1,
            "UPDATE segment SET text='Cambiado'",
            json!({}),
        )
        .await
        .unwrap_err();
    assert!(failed.contains("consultas de lectura"), "{failed}");
    assert_eq!(
        graph
            .query("escriba", 1, "SELECT VALUE text FROM segment", json!({}))
            .await
            .unwrap(),
        vec![json!(["Hola mundo"])]
    );
    assert!(graph
        .query("escriba", 1, "DEFINE TABLE stolen", json!({}))
        .await
        .is_err());
    assert!(graph.apply(base_definition()).await.is_err());
    graph
        .sync_base_change(&crate::persistence::CoreChange {
            value: None,
            revision: "two".into(),
            ..change
        })
        .await
        .unwrap();
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT * FROM segment; SELECT * FROM has_version",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([]), json!([])]
    );
}

async fn tables(graph: &Knowledge) -> Vec<String> {
    let mut info = selected(&graph.root, "escriba")
        .await
        .unwrap()
        .query("INFO FOR DB")
        .await
        .unwrap();
    let info: Option<Value> = info.take(0).unwrap();
    info.unwrap()["tables"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect()
}

async fn legacy(graph: &Knowledge) -> Surreal<Db> {
    let session = graph.root.clone();
    session
        .use_ns("knowledge")
        .use_db(crate::knowledge::hashed_database("escriba"))
        .await
        .unwrap();
    session
}

async fn has_legacy(graph: &Knowledge) -> bool {
    super::base::databases(&graph.root)
        .await
        .unwrap()
        .contains(&crate::knowledge::hashed_database("escriba"))
}

#[tokio::test]
async fn la_base_anterior_con_palabras_sueltas_se_elimina_al_abrir_y_la_nueva_se_proyecta() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    let graph = Knowledge::open(&path).await.unwrap();
    let old = legacy(&graph).await;
    old.query("DEFINE TABLE segment SCHEMALESS; DEFINE TABLE word SCHEMALESS; DEFINE TABLE has_word TYPE RELATION IN segment OUT word SCHEMALESS; UPSERT _escriba_manifest:current SET definition = $definition, epoch = 'anterior'; FOR $i IN 0..1200 { CREATE type::record('segment', $i) SET recordingId = 'nota'; CREATE type::record('word', $i) SET recordingId = 'nota'; RELATE (type::record('segment', $i))->has_word->(type::record('word', $i)) SET recordingId = 'nota'; };")
        .bind(("definition", serde_json::to_value(base_definition()).unwrap()))
        .await
        .unwrap()
        .check()
        .unwrap();
    assert!(has_legacy(&graph).await);
    drop(old);
    graph.close().await.unwrap();
    let graph = Knowledge::open(&path).await.unwrap();
    assert!(
        !has_legacy(&graph).await,
        "La base anterior se elimina al abrir"
    );
    graph
        .sync_base_change(&note("Nota", json!([version("v1", "uno")])))
        .await
        .unwrap();
    assert!(!tables(&graph)
        .await
        .iter()
        .any(|t| t == "word" || t == "has_word"));
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE array::len(words) FROM segment",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([2])]
    );
    graph.close().await.unwrap();
}

#[tokio::test]
async fn una_extension_anterior_llamada_escriba_no_se_retira_ni_se_sustituye() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    let graph = Knowledge::open(&path).await.unwrap();
    let mut extension = base_definition();
    extension.migrations = vec![crate::knowledge::Migration {
        version: 1,
        sql: "DEFINE TABLE nota SCHEMALESS;".into(),
    }];
    legacy(&graph)
        .await
        .query("UPSERT _escriba_manifest:current SET definition = $definition")
        .bind(("definition", serde_json::to_value(extension).unwrap()))
        .await
        .unwrap()
        .check()
        .unwrap();
    assert!(has_legacy(&graph).await);
    graph.close().await.unwrap();
    let error = match Knowledge::open(&path).await {
        Ok(graph) => {
            graph.close().await.unwrap();
            panic!("Se sustituyó una extensión anterior")
        }
        Err(error) => error,
    };
    assert!(error.contains("identificador reservado"), "{error}");
}

fn note(title: &str, versions: Value) -> crate::persistence::CoreChange {
    note_at(title, Some("v1"), versions)
}

fn note_at(title: &str, current: Option<&str>, versions: Value) -> crate::persistence::CoreChange {
    crate::persistence::CoreChange {
        key: "recording:nota".into(),
        revision: Uuid::new_v4().to_string(),
        kind: "recording".into(),
        id: "nota".into(),
        value: Some(
            json!({"id":"nota","title":title,"status":"done","currentVersionId":current,"versions":versions}),
        ),
    }
}

fn version(id: &str, summary: &str) -> Value {
    json!({"id":id,"digest":{"title":format!("Versión {id}"),"summary":summary,"tags":[]},"transcript":{"text":"Hola Ana","segments":[{"start":0,"end":2,"text":"Hola Ana","speaker":"S1","personId":"ana","words":[{"text":"Hola","start":0,"end":1},{"text":"Ana","start":1,"end":2}]}]}})
}

async fn marked(graph: &Knowledge) -> Vec<String> {
    let db = selected(&graph.root, "escriba").await.unwrap();
    let mut response = db
        .query("SELECT VALUE versionId FROM segment WHERE marca = true ORDER BY versionId")
        .await
        .unwrap()
        .check()
        .unwrap();
    let mut versions: Vec<String> = response.take(0).unwrap();
    versions.dedup();
    versions
}

async fn mark(graph: &Knowledge) {
    selected(&graph.root, "escriba")
        .await
        .unwrap()
        .query("UPDATE segment SET marca = true")
        .await
        .unwrap()
        .check()
        .unwrap();
}

async fn projected(graph: &Knowledge) -> Value {
    let tables = graph
        .query(
            "escriba",
            1,
            "SELECT VALUE versionId FROM version; SELECT VALUE versionId FROM transcript; SELECT VALUE versionId FROM segment; SELECT VALUE versionId FROM speaker; SELECT VALUE versionId FROM has_version; SELECT VALUE versionId FROM has_transcript; SELECT VALUE versionId FROM identified_as; SELECT VALUE currentVersion.versionId FROM recording",
            json!({}),
        )
        .await
        .unwrap();
    let mut versions: Vec<Value> = tables
        .iter()
        .flat_map(|rows| rows.as_array().unwrap().clone())
        .collect();
    versions.sort_by_key(Value::to_string);
    versions.dedup();
    Value::Array(versions)
}

#[tokio::test]
async fn solo_se_proyecta_la_version_vigente_y_elegir_otra_la_sustituye() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    graph
        .sync_base_change(&crate::persistence::CoreChange {
            key: "person:ana".into(),
            revision: "p".into(),
            kind: "person".into(),
            id: "ana".into(),
            value: Some(json!({"id":"ana","name":"Ana"})),
        })
        .await
        .unwrap();
    let three = json!([
        version("v1", "uno"),
        version("v2", "dos"),
        version("v3", "tres")
    ]);
    graph
        .sync_base_change(&note("Primera", three.clone()))
        .await
        .unwrap();
    assert_eq!(projected(&graph).await, json!(["v1"]));
    mark(&graph).await;
    graph
        .sync_base_change(&note("Retitulada", three))
        .await
        .unwrap();
    assert_eq!(marked(&graph).await, vec!["v1"]);
    assert_eq!(
        graph
            .query("escriba", 1, "SELECT VALUE title FROM recording", json!({}))
            .await
            .unwrap(),
        vec![json!(["Retitulada"])]
    );
    let corrected = json!([
        version("v1", "uno"),
        version("v2", "corregida"),
        version("v3", "tres")
    ]);
    graph
        .sync_base_change(&note("Retitulada", corrected.clone()))
        .await
        .unwrap();
    assert_eq!(marked(&graph).await, vec!["v1"]);
    graph
        .sync_base_change(&note_at("Retitulada", Some("v3"), corrected.clone()))
        .await
        .unwrap();
    assert_eq!(projected(&graph).await, json!(["v3"]));
    assert!(marked(&graph).await.is_empty());
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE ->has_version->version->has_transcript->transcript<~segment.text FROM recording",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([["Hola Ana"]])]
    );
    let reprocessed = json!([
        version("v1", "uno"),
        version("v2", "corregida"),
        version("v3", "tres"),
        version("v4", "cuatro")
    ]);
    graph
        .sync_base_change(&note_at("Retitulada", None, reprocessed))
        .await
        .unwrap();
    assert_eq!(
        projected(&graph).await,
        json!(["v4"]),
        "Sin marca, la vigente es la última, como en la interfaz"
    );
}

#[tokio::test]
async fn una_proyeccion_anterior_sin_huellas_se_rehace_entera_una_vez() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let versions = json!([version("v1", "uno")]);
    graph
        .sync_base_change(&note("Nota", versions.clone()))
        .await
        .unwrap();
    let db = selected(&graph.root, "escriba").await.unwrap();
    db.query("DELETE _escriba_projection; CREATE segment:huerfano SET recordingId = 'nota', versionId = 'antigua', text = 'resto', transcript = type::record('transcript', ['nota', 'antigua'])")
        .await
        .unwrap()
        .check()
        .unwrap();
    mark(&graph).await;
    graph
        .sync_base_change(&note("Nota", versions.clone()))
        .await
        .unwrap();
    assert!(marked(&graph).await.is_empty());
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE text FROM segment ORDER BY text",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!(["Hola Ana"])]
    );
    mark(&graph).await;
    graph
        .sync_base_change(&note("Nota", versions))
        .await
        .unwrap();
    assert_eq!(marked(&graph).await, vec!["v1"]);
}

#[tokio::test]
async fn cambiar_el_titulo_conserva_las_aristas_de_la_nota() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let versions = json!([version("v1", "uno")]);
    graph
        .sync_base_change(&note("Primera", versions.clone()))
        .await
        .unwrap();
    graph
        .sync_base_change(&note("Retitulada", versions))
        .await
        .unwrap();
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE ->has_version->version.versionId FROM recording",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([["v1"]])]
    );
    let mut units = selected(&graph.root, "escriba")
        .await
        .unwrap()
        .query("SELECT VALUE unit FROM _escriba_projection ORDER BY unit")
        .await
        .unwrap()
        .check()
        .unwrap();
    let units: Vec<String> = units.take(0).unwrap();
    assert_eq!(units, vec!["recording", "v1"]);
}

#[tokio::test]
async fn un_formato_de_proyeccion_anterior_se_rehace_una_vez_y_recupera_las_aristas() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    let graph = Knowledge::open(&path).await.unwrap();
    let versions = json!([version("v1", "uno")]);
    graph
        .sync_base_change(&note("Nota", versions.clone()))
        .await
        .unwrap();
    let epoch = graph.base_epoch().await.unwrap();
    selected(&graph.root, "escriba")
        .await
        .unwrap()
        .query("DELETE has_version; UPDATE _escriba_manifest:current SET projection = 1")
        .await
        .unwrap()
        .check()
        .unwrap();
    graph.close().await.unwrap();
    let graph = Knowledge::open(&path).await.unwrap();
    let renewed = graph.base_epoch().await.unwrap();
    assert_ne!(
        renewed, epoch,
        "La época nueva vuelve a encolar todas las notas"
    );
    graph
        .sync_base_change(&note("Nota", versions))
        .await
        .unwrap();
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE ->has_version->version.versionId FROM recording",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([["v1"]])]
    );
    graph.close().await.unwrap();
    let graph = Knowledge::open(&path).await.unwrap();
    assert_eq!(graph.base_epoch().await.unwrap(), renewed);
    graph.close().await.unwrap();
}
