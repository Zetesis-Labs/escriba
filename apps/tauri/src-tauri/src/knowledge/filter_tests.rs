use super::*;
use serde_json::json;

async fn sample() -> (tempfile::TempDir, Knowledge) {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
        .await
        .unwrap();
    graph.sync_base_change(&crate::persistence::CoreChange {
        key: "recording:audio".into(), revision: "one".into(), kind: "recording".into(), id: "audio".into(),
        value: Some(json!({"id":"audio","title":"Nota actual","currentVersionId":"v2","versions":[
            {"id":"v1","transcript":{"text":"Antiguo","segments":[{"text":"Antiguo","start":0,"end":2,"personId":"ada"}]}},
            {"id":"v2","sourceVersionId":"v1","digest":{"tags":["work","test"]},"transcript":{"text":"Vigente","segments":[{"text":"Vigente","start":0,"end":2,"personId":"bea"}]}}
        ]})),
    }).await.unwrap();
    (temp, graph)
}
fn visual(table: &str, field: &str, operator: &str, value: Value) -> LibraryFilter {
    serde_json::from_value(json!({"kind":"visual","match":"all","conditions":[{"ontologyId":"escriba","table":table,"field":field,"operator":operator,"value":value}]})).unwrap()
}
fn sql(ontology: &str, sql: &str) -> LibraryFilter {
    serde_json::from_value(json!({"kind":"surrealql","ontologyId":ontology,"sql":sql})).unwrap()
}
#[tokio::test]
async fn selecciona_solo_segmentos_de_la_version_vigente() {
    let (_temp, graph) = sample().await;
    assert_eq!(
        graph
            .filter_notes(visual("segment", "text", "eq", json!("Vigente")))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    assert!(graph
        .filter_notes(visual("segment", "text", "eq", json!("Antiguo")))
        .await
        .unwrap()
        .recording_ids
        .is_empty());
}

#[tokio::test]
async fn corresponde_personas_y_relaciones_con_asignaciones_vigentes() {
    let (_temp, graph) = sample().await;
    for person in ["ada", "bea"] {
        graph
            .sync_base_change(&crate::persistence::CoreChange {
                key: format!("person:{person}"),
                revision: "one".into(),
                kind: "person".into(),
                id: person.into(),
                value: Some(json!({"id":person,"name":person})),
            })
            .await
            .unwrap();
    }
    assert!(graph
        .filter_notes(visual("person", "name", "eq", json!("ada")))
        .await
        .unwrap()
        .recording_ids
        .is_empty());
    assert_eq!(
        graph
            .filter_notes(visual("person", "name", "eq", json!("bea")))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    assert_eq!(
        graph
            .filter_notes(visual(
                "has_version",
                "out",
                "eq",
                json!("version:['audio', 'v2']")
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    assert!(graph
        .filter_notes(visual(
            "has_version",
            "out",
            "eq",
            json!("version:['audio', 'v1']")
        ))
        .await
        .unwrap()
        .recording_ids
        .is_empty());
    assert_eq!(
        graph
            .filter_notes(sql(
                "escriba",
                "LET $ids = (SELECT VALUE id FROM segment); RETURN $ids"
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
}
async fn extension(graph: &Knowledge) {
    graph.apply(serde_json::from_value(json!({"id":"test","name":"Prueba","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE topic SCHEMALESS PERMISSIONS FULL; DEFINE TABLE related TYPE RELATION IN topic OUT topic SCHEMALESS PERMISSIONS FULL; DEFINE TABLE secret SCHEMALESS PERMISSIONS NONE;"}],"collections":[
        {"table":"topic","label":"Temas","titleField":"name","fields":[
            {"key":"name","label":"Nombre","type":"text"},
            {"key":"score","label":"Puntos","type":"number"},
            {"key":"enabled","label":"Activo","type":"boolean"},
            {"key":"at","label":"Fecha","type":"date"},
            {"key":"data","label":"Datos","type":"json"},
            {"key":"note","label":"Nota","type":"reference","reference":{"ontologyId":"escriba","table":"recording"}}
        ]},
        {"table":"related","label":"Relaciones","titleField":"title","fields":[],"relation":{"from":"topic","to":"topic"}}
    ]})).unwrap()).await.unwrap();
    graph.query("test",1,"CREATE topic:current SET name='Actual', score=4, enabled=true, at=d'2026-10-11T14:00:00Z', data={a:1}; CREATE topic:old SET name='Anterior'; CREATE topic:ref SET name='Referencia', note={ontologyId:'escriba', table:'recording', id:'recording:audio'}; RELATE topic:current->related:edge->topic:old",json!({})).await.unwrap();
    for (id, version) in [
        ("topic:current", "v2"),
        ("topic:old", "v1"),
        ("related:edge", "v2"),
    ] {
        graph
            .link(
                "test",
                1,
                id,
                Source {
                    recording_id: "audio".into(),
                    version_id: version.into(),
                    recipe_id: None,
                },
            )
            .await
            .unwrap();
    }
}
fn extension_visual(field: &str, operator: &str, value: Value) -> LibraryFilter {
    serde_json::from_value(json!({"kind":"visual","match":"all","conditions":[{"ontologyId":"test","table":"topic","field":field,"operator":operator,"value":value}]})).unwrap()
}
#[tokio::test]
async fn filtra_tipos_y_relaciones_de_extensiones_con_procedencia_y_referencias() {
    let (_temp, graph) = sample().await;
    extension(&graph).await;
    for (field, operator, value) in [
        ("name", "contains", json!("ctu")),
        ("name", "startsWith", json!("Act")),
        ("score", "eq", json!(4)),
        ("score", "ne", json!(8)),
        ("score", "gt", json!(3)),
        ("score", "gte", json!(4)),
        ("score", "lt", json!(5)),
        ("score", "lte", json!(4)),
        ("enabled", "eq", json!(true)),
        ("at", "eq", json!("2026-10-11")),
        ("at", "gte", json!("2026-10-11T14:00:00Z")),
        ("data", "eq", json!({"a":1})),
        ("name", "notEmpty", Value::Null),
        ("note", "empty", Value::Null),
        ("id", "eq", json!("topic:current")),
        (
            "note",
            "eq",
            json!({"ontologyId":"escriba","table":"recording","id":"recording:audio"}),
        ),
    ] {
        assert_eq!(
            graph
                .filter_notes(extension_visual(field, operator, value))
                .await
                .unwrap()
                .recording_ids,
            vec!["audio"],
            "{field}/{operator}"
        );
    }
    assert!(graph
        .filter_notes(extension_visual("name", "eq", json!("Anterior")))
        .await
        .unwrap()
        .recording_ids
        .is_empty());
    assert_eq!(
        graph
            .filter_notes(extension_visual("name", "eq", json!("Referencia")))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    assert_eq!(
        graph
            .filter_notes(sql("test", "SELECT VALUE id FROM related"))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    assert_eq!(
        graph
            .filter_notes(sql(
                "test",
                "SELECT VALUE note FROM topic WHERE note != NONE"
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    assert_eq!(
        graph
            .filter_notes(sql("test", "SELECT id FROM topic WHERE name='Actual'"))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
    for (field, operator, value) in [
        ("score", "eq", json!("4")),
        ("enabled", "gt", json!(true)),
        ("unknown", "eq", json!(1)),
        ("score", "contains", json!(4)),
        ("at", "eq", json!("yesterday")),
        ("id", "eq", json!("other:one")),
    ] {
        assert!(
            graph
                .filter_notes(extension_visual(field, operator, value))
                .await
                .is_err(),
            "{field}/{operator}"
        );
    }
    assert!(graph
        .filter_notes(extension_visual("name", "eq", json!("'; DELETE topic; --")))
        .await
        .unwrap()
        .recording_ids
        .is_empty());
}
#[tokio::test]
async fn combina_identidades_de_notas_y_falla_visiblemente_sin_escribir() {
    let (_temp, graph) = sample().await;
    extension(&graph).await;
    for (mode, expected) in [("all", vec![]), ("any", vec!["audio"])] {
        let filter=serde_json::from_value(json!({"kind":"visual","match":mode,"conditions":[
            {"ontologyId":"escriba","table":"recording","field":"title","operator":"eq","value":"Nota actual"},
            {"ontologyId":"test","table":"topic","field":"name","operator":"eq","value":"No existe"}
        ]})).unwrap();
        assert_eq!(
            graph.filter_notes(filter).await.unwrap().recording_ids,
            expected
        );
    }
    for query in [
        "UPDATE topic SET name='mal'",
        "RETURN (DELETE topic)",
        "LET $deleted=(DELETE topic); RETURN topic:current",
        "IF true { CREATE topic:bad; }",
        "DEFINE TABLE bad",
        "USE NS knowledge DB registry; SELECT * FROM ontology",
        "RETURN fn::write()",
        "RETURN sleep(20s)",
        "SELECT name FROM topic",
        "RETURN [topic:current, 4]",
        "RETURN NULL",
        "RETURN _escriba_manifest:current",
        "SELECT ???",
    ] {
        assert!(
            graph.filter_notes(sql("test", query)).await.is_err(),
            "{query}"
        );
    }
    for query in [
        "SELECT * FROM _escriba_manifest",
        "SELECT * FROM _escriba_principal",
        "SELECT * FROM secret",
    ] {
        assert!(
            graph
                .filter_notes(sql("test", query))
                .await
                .unwrap()
                .recording_ids
                .is_empty(),
            "{query}"
        );
    }
    assert!(graph
        .filter_notes(sql("absent", "SELECT VALUE id FROM topic"))
        .await
        .is_err());
    assert_eq!(
        graph
            .filter_notes(extension_visual("name", "eq", json!("Actual")))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
}

#[tokio::test]
async fn la_version_vigente_corregida_conserva_su_correspondencia_por_derivacion() {
    let (_temp, graph) = sample().await;
    assert_eq!(
        graph
            .filter_notes(sql("escriba", "SELECT VALUE id FROM derived_from"))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
}

#[tokio::test]
async fn encuentra_etiquetas_dentro_de_campos_json() {
    let (_temp, graph) = sample().await;
    assert_eq!(
        graph
            .filter_notes(visual("version", "tags", "contains", json!("work")))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
}

#[tokio::test]
async fn filtra_la_referencia_a_version_vigente_de_una_grabacion() {
    let (_temp, graph) = sample().await;
    assert_eq!(
        graph
            .filter_notes(visual(
                "recording",
                "currentVersion",
                "eq",
                json!("version:['audio','v2']")
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
}

#[tokio::test]
async fn deduplica_notas_compartidas_sin_recorrer_relaciones_implicitas() {
    let (_temp, graph) = sample().await;
    extension(&graph).await;
    graph.sync_base_change(&crate::persistence::CoreChange {
        key:"recording:second".into(),revision:"one".into(),kind:"recording".into(),id:"second".into(),
        value:Some(json!({"id":"second","title":"Segunda nota","createdAt":"2026-10-11T18:30:00Z","currentVersionId":"v1","versions":[{"id":"v1"}]})),
    }).await.unwrap();
    graph
        .link(
            "test",
            1,
            "topic:current",
            Source {
                recording_id: "second".into(),
                version_id: "v1".into(),
                recipe_id: None,
            },
        )
        .await
        .unwrap();
    graph.query("test",1,"CREATE topic:neighbor SET name='Vecino'; RELATE topic:neighbor->related:neighbor->topic:current",json!({})).await.unwrap();
    assert_eq!(
        graph
            .filter_notes(sql(
                "test",
                "SELECT VALUE [id,id] FROM topic WHERE id=topic:current"
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio", "second"]
    );
    assert!(graph
        .filter_notes(extension_visual("name", "eq", json!("Vecino")))
        .await
        .unwrap()
        .recording_ids
        .is_empty());
    assert_eq!(
        graph
            .filter_notes(sql(
                "test",
                "SELECT VALUE ->related->topic FROM topic:neighbor"
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio", "second"]
    );
    assert_eq!(
        graph
            .filter_notes(visual("recording", "createdAt", "eq", json!("2026-10-11")))
            .await
            .unwrap()
            .recording_ids,
        vec!["second"]
    );
    let excessive = graph
        .filter_notes(sql(
            "escriba",
            "RETURN array::repeat(recording:audio, 10001)",
        ))
        .await
        .unwrap_err();
    assert!(excessive.contains("10000"), "{excessive}");
}

#[tokio::test]
async fn acepta_registros_con_id_nativo_y_otros_campos_de_dominio() {
    let (_temp, graph) = sample().await;
    assert_eq!(
        graph
            .filter_notes(sql(
                "escriba",
                "RETURN {id: recording:audio, ontologyId: 'campo de dominio'}"
            ))
            .await
            .unwrap()
            .recording_ids,
        vec!["audio"]
    );
}

#[tokio::test]
async fn las_comparaciones_ordenadas_no_incluyen_campos_ausentes() {
    let (_temp, graph) = sample().await;
    extension(&graph).await;
    for (field, operator, value) in [
        ("score", "lt", json!(4)),
        ("score", "lte", json!(3)),
        ("at", "lt", json!("2026-10-11")),
        ("at", "lte", json!("2026-10-10")),
    ] {
        assert!(
            graph
                .filter_notes(extension_visual(field, operator, value))
                .await
                .unwrap()
                .recording_ids
                .is_empty(),
            "{field}/{operator}"
        );
    }
}
