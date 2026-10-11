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
