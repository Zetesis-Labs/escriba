use super::*;
use serde_json::json;

#[tokio::test]
async fn la_base_expone_la_biblioteca_y_solo_permite_consultarla() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
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
    assert_eq!(graph.query("escriba",1,"SELECT VALUE ->has_version->version->has_transcript->transcript->has_segment->segment.text FROM recording",json!({})).await.unwrap(), vec![json!([["Hola mundo"]])]);
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

fn note(title: &str, versions: Value) -> crate::persistence::CoreChange {
    crate::persistence::CoreChange {
        key: "recording:nota".into(),
        revision: Uuid::new_v4().to_string(),
        kind: "recording".into(),
        id: "nota".into(),
        value: Some(
            json!({"id":"nota","title":title,"status":"done","currentVersionId":"v1","versions":versions}),
        ),
    }
}

fn version(id: &str, summary: &str) -> Value {
    json!({"id":id,"digest":{"title":format!("Versión {id}"),"summary":summary,"tags":[]},"transcript":{"text":"Hola Ana","segments":[{"start":0,"end":2,"text":"Hola Ana","speaker":"S1","personId":"ana","words":[{"text":"Hola","start":0,"end":1},{"text":"Ana","start":1,"end":2}]}]}})
}

async fn marked(graph: &Knowledge) -> Vec<String> {
    let db = selected(&graph.root, "escriba").await.unwrap();
    let mut response = db
        .query("SELECT VALUE versionId FROM word WHERE marca = true ORDER BY versionId")
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
        .query("UPDATE word SET marca = true")
        .await
        .unwrap()
        .check()
        .unwrap();
}

#[tokio::test]
async fn editar_el_titulo_no_reproyecta_las_versiones_y_corregir_una_solo_rehace_esa() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
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
    mark(&graph).await;
    graph
        .sync_base_change(&note("Retitulada", three))
        .await
        .unwrap();
    assert_eq!(marked(&graph).await, vec!["v1", "v2", "v3"]);
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
        .sync_base_change(&note("Retitulada", corrected))
        .await
        .unwrap();
    assert_eq!(marked(&graph).await, vec!["v1", "v3"]);
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT count() FROM identified_as GROUP ALL",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([{"count":3}])]
    );
    let reprocessed = json!([
        version("v1", "uno"),
        version("v2", "corregida"),
        version("v4", "cuatro")
    ]);
    graph
        .sync_base_change(&note("Retitulada", reprocessed))
        .await
        .unwrap();
    assert_eq!(marked(&graph).await, vec!["v1"]);
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE versionId FROM version ORDER BY versionId",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!(["v1", "v2", "v4"])]
    );
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT count() FROM word WHERE versionId = 'v3' GROUP ALL",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([])]
    );
}

#[tokio::test]
async fn una_proyeccion_anterior_sin_huellas_se_rehace_entera_una_vez() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
        .await
        .unwrap();
    let versions = json!([version("v1", "uno")]);
    graph
        .sync_base_change(&note("Nota", versions.clone()))
        .await
        .unwrap();
    let db = selected(&graph.root, "escriba").await.unwrap();
    db.query("DELETE _escriba_projection; CREATE segment:huerfano SET recordingId = 'nota', versionId = 'antigua', text = 'resto'")
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
