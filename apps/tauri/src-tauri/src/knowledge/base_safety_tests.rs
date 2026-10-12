use super::*;
use crate::persistence::CoreChange;
use serde_json::json;

fn recording(segments: Value) -> CoreChange {
    CoreChange {
        key: "recording:synthetic".into(),
        revision: "one".into(),
        kind: "recording".into(),
        id: "synthetic".into(),
        value: Some(
            json!({"id":"synthetic","title":"Sintética","status":"done","versions":[{"id":"v1","transcript":{"text":"Texto sintético","segments":segments}}]}),
        ),
    }
}
fn person(name: Option<&str>) -> CoreChange {
    CoreChange {
        key: "person:ana".into(),
        revision: "one".into(),
        kind: "person".into(),
        id: "ana".into(),
        value: name.map(|name| json!({"id":"ana","name":name,"createdAt":"2026-10-11T00:00:00Z"})),
    }
}
async fn spoken(graph: &Knowledge) -> usize {
    graph
        .records("escriba", "segment", 0, None, None)
        .await
        .unwrap()
        .records
        .iter()
        .filter(|record| !record.values["speakerRecord"].is_null())
        .count()
}
async fn count(graph: &Knowledge, table: &str) -> usize {
    graph
        .records("escriba", table, 0, None, None)
        .await
        .unwrap()
        .records
        .len()
}

#[tokio::test]
async fn base_safety_identifica_solo_personas_existentes_y_conserva_hablantes_tras_borrarlas() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    graph
        .sync_base_change(&recording(
            json!([{"start":0,"end":1,"text":"Hola","speaker":"Voz sintética","personId":"ana"}]),
        ))
        .await
        .unwrap();
    assert_eq!(count(&graph, "identified_as").await, 0);
    assert_eq!(count(&graph, "speaker").await, 1);
    graph.sync_base_change(&person(Some("Ana"))).await.unwrap();
    assert_eq!(count(&graph, "identified_as").await, 1);
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE ->identified_as->person.name FROM speaker",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([["Ana"]])]
    );
    let original = graph
        .records("escriba", "identified_as", 0, None, None)
        .await
        .unwrap()
        .records[0]
        .id
        .clone();
    graph
        .sync_base_change(&person(Some("Ana corregida")))
        .await
        .unwrap();
    assert_eq!(
        graph
            .records("escriba", "identified_as", 0, None, None)
            .await
            .unwrap()
            .records[0]
            .id,
        original
    );
    assert_eq!(
        graph
            .query(
                "escriba",
                1,
                "SELECT VALUE ->identified_as->person.name FROM speaker",
                json!({})
            )
            .await
            .unwrap(),
        vec![json!([["Ana corregida"]])]
    );
    graph.sync_base_change(&person(None)).await.unwrap();
    assert_eq!(count(&graph, "identified_as").await, 0);
    assert_eq!(count(&graph, "person").await, 0);
    assert_eq!(count(&graph, "speaker").await, 1);
    assert_eq!(count(&graph, "segment").await, 1);
    assert_eq!(spoken(&graph).await, 1);
    graph.close().await.unwrap();
}

#[tokio::test]
async fn base_safety_etiquetas_iguales_ambiguas_no_atribuyen_identidad_a_todos_los_segmentos() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    graph.sync_base_change(&person(Some("Ana"))).await.unwrap();
    graph
        .sync_base_change(&CoreChange {
            key: "person:bea".into(),
            id: "bea".into(),
            value: Some(json!({"id":"bea","name":"Bea"})),
            ..person(Some("Ana"))
        })
        .await
        .unwrap();
    for segments in [
        json!([{"start":0,"end":1,"text":"Uno","speaker":"Voz","personId":"ana"},{"start":1,"end":2,"text":"Dos","speaker":"Voz","personId":"bea"}]),
        json!([{"start":0,"end":1,"text":"Uno","speaker":"Voz","personId":"ana"},{"start":1,"end":2,"text":"Dos","speaker":"Voz"}]),
        json!([{"start":0,"end":1,"text":"Uno","speaker":"Voz"},{"start":1,"end":2,"text":"Dos","speaker":"Voz","personId":"ana"}]),
    ] {
        graph
            .sync_base_change(&recording(segments.clone()))
            .await
            .unwrap();
        assert_eq!(count(&graph, "identified_as").await, 0);
        assert_eq!(count(&graph, "speaker").await, 1);
        assert_eq!(count(&graph, "segment").await, 2);
        assert_eq!(spoken(&graph).await, 2);
        let projected = graph
            .records("escriba", "segment", 0, None, None)
            .await
            .unwrap();
        for (index, segment) in projected.records.iter().enumerate() {
            assert_eq!(
                segment.values.get("personId"),
                segments[index].get("personId")
            );
        }
        let speakers = graph
            .records("escriba", "speaker", 0, None, None)
            .await
            .unwrap();
        assert!(speakers.records[0].values.get("personId").is_none());
        graph
            .sync_base_change(&person(Some("Ana renombrada")))
            .await
            .unwrap();
        assert_eq!(count(&graph, "identified_as").await, 0);
    }
    graph.sync_base_change(&recording(json!([{"start":0,"end":1,"text":"Uno","speaker":"Voz","personId":"ana"},{"start":1,"end":2,"text":"Dos","speaker":"Voz","personId":"ana"}]))).await.unwrap();
    assert_eq!(count(&graph, "identified_as").await, 1);
    graph.close().await.unwrap();
}

#[tokio::test]
async fn base_safety_formularios_y_vinculos_no_pueden_mutar_la_ontologia_integrada() {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    graph.sync_base_change(&person(Some("Ana"))).await.unwrap();
    let rows = graph
        .records("escriba", "person", 0, None, None)
        .await
        .unwrap();
    let original = &rows.records[0];
    let saved = graph
        .save(SaveRecord {
            ontology_id: "escriba".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: Some(original.id.clone()),
            expected_rev: Some(original.rev.clone()),
            values: json!({"name":"Alterada"}),
            source: None,
        })
        .await
        .unwrap_err();
    assert!(saved.contains("solo lectura"), "{saved}");
    let created = graph
        .save(SaveRecord {
            ontology_id: "escriba".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: None,
            expected_rev: None,
            values: json!({"name":"Intrusa"}),
            source: None,
        })
        .await
        .unwrap_err();
    assert!(created.contains("solo lectura"), "{created}");
    let deleted = graph
        .delete("escriba", 1, "person", &original.id, &original.rev)
        .await
        .unwrap_err();
    assert!(deleted.contains("solo lectura"), "{deleted}");
    let linked = graph
        .link(
            "escriba",
            1,
            &original.id,
            Source {
                recording_id: "synthetic".into(),
                version_id: "v1".into(),
                recipe_id: None,
            },
        )
        .await
        .unwrap_err();
    assert!(linked.contains("solo lectura"), "{linked}");
    let unlinked = graph
        .unlink("escriba", 1, &original.id, "synthetic")
        .await
        .unwrap_err();
    assert!(unlinked.contains("solo lectura"), "{unlinked}");
    let after = graph
        .records("escriba", "person", 0, None, None)
        .await
        .unwrap();
    assert_eq!(after.records.len(), 1);
    assert_eq!(after.records[0].id, original.id);
    assert_eq!(after.records[0].rev, original.rev);
    assert_eq!(after.records[0].values["name"], "Ana");
    graph.close().await.unwrap();
}

#[tokio::test]
async fn base_safety_rechaza_extension_legada_escriba_sin_alterar_su_esquema_ni_datos() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    let graph = Knowledge::open(&path).await.unwrap();
    let legacy = json!({"id":"escriba","name":"Extensión anterior","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE person SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON person TYPE string;"}],"collections":[{"table":"person","label":"Legado","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text"}]}]});
    let before = {
        let root = graph.root.clone();
        let db = selected(&root, "escriba").await.unwrap();
        db.query("DEFINE TABLE OVERWRITE person SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON person TYPE string; CREATE person:legacy SET name = 'Persona sintética anterior'; UPSERT _escriba_manifest:current SET definition=$definition, epoch='epoch-anterior';")
            .bind(("definition",legacy)).await.unwrap().check().unwrap();
        values(
            db.query("INFO FOR DB; SELECT * FROM _escriba_manifest; SELECT * FROM person")
                .await
                .unwrap(),
        )
        .unwrap()
    };
    graph.close().await.unwrap();
    let error = match Knowledge::open(&path).await {
        Ok(graph) => {
            graph.close().await.unwrap();
            panic!("Se sustituyó una extensión anterior")
        }
        Err(error) => error,
    };
    assert!(error.contains("identificador reservado"), "{error}");
    let credentials = Root {
        username: "escriba".into(),
        password: std::fs::read_to_string(path.with_extension("key")).unwrap(),
    };
    let mut attempts = 0;
    let inspector = loop {
        match Surreal::new::<surrealdb::engine::local::RocksDb>((
            path.as_path(),
            Config::new().user(credentials.clone()),
        ))
        .await
        {
            Ok(db) => break db,
            Err(error) => {
                attempts += 1;
                assert!(
                    attempts < 200,
                    "No se liberó la base tras rechazarla: {error}"
                );
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        }
    };
    inspector.signin(credentials).await.unwrap();
    inspector
        .use_ns("knowledge")
        .use_db(database("escriba"))
        .await
        .unwrap();
    let after = values(
        inspector
            .query("INFO FOR DB; SELECT * FROM _escriba_manifest; SELECT * FROM person")
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        before, after,
        "La apertura rechazada cambió la extensión anterior"
    );
}
