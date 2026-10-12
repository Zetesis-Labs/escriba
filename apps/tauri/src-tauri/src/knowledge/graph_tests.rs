use super::*;
use serde_json::json;

async fn fixture() -> (tempfile::TempDir, Knowledge) {
    let temp = tempfile::tempdir().unwrap();
    let graph = Knowledge::open(&temp.path().join("graph")).await.unwrap();
    graph.apply(serde_json::from_value(json!({"id":"test","name":"Test","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE topic SCHEMALESS PERMISSIONS FULL; DEFINE TABLE connects TYPE RELATION IN topic OUT topic SCHEMALESS PERMISSIONS FULL;"}],"collections":[{"table":"topic","label":"Temas","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text"}]},{"table":"connects","label":"Conecta","titleField":"name","fields":[],"relation":{"from":"topic","to":"topic"}}]})).unwrap()).await.unwrap();
    (temp, graph)
}

#[tokio::test]
async fn explora_raices_con_identidad_canonica_y_sin_campos_ocultos() {
    let (_temp, graph) = fixture().await;
    graph
        .query(
            "test",
            1,
            "CREATE topic:`con espacio` SET name='Visible', secret='oculto'",
            json!({}),
        )
        .await
        .unwrap();
    let page = graph.graph_roots("test", "topic", 0).await.unwrap();
    assert_eq!(page.nodes.len(), 1);
    assert_eq!(page.nodes[0].label, "Visible");
    let detail = graph
        .graph_detail("test", "topic:`con espacio`")
        .await
        .unwrap();
    assert_eq!(detail.values, json!({"name":"Visible"}));
    assert_eq!(detail.id, page.nodes[0].record_id);
    assert!(graph
        .graph_roots("test", "_escriba_manifest", 0)
        .await
        .is_err());
    assert!(graph.graph_roots("absent", "topic", 0).await.is_err());
    graph.close().await.unwrap();
}

#[tokio::test]
async fn expande_relaciones_dirigidas_paralelas_y_bucles_sin_duplicar() {
    let (_temp, graph) = fixture().await;
    graph.query("test",1,"CREATE topic:a SET name='A'; CREATE topic:b SET name='B'; RELATE topic:a->connects:first->topic:b; RELATE topic:a->connects:second->topic:b; RELATE topic:a->connects:self->topic:a;",json!({})).await.unwrap();
    let page = graph.graph_expand("test", "topic:a", 0).await.unwrap();
    assert_eq!(page.nodes.len(), 2);
    assert_eq!(page.edges.len(), 3);
    assert!(page.edges.iter().any(|e| e.source == e.target));
    assert_eq!(
        graph
            .graph_expand("test", "topic:b", 0)
            .await
            .unwrap()
            .edges
            .len(),
        2
    );
    let relation_roots = graph.graph_roots("test", "connects", 0).await.unwrap();
    assert_eq!(relation_roots.edges.len(), 3);
    assert_eq!(relation_roots.nodes.len(), 2);
    graph.close().await.unwrap();
}

#[tokio::test]
async fn recorre_referencias_entre_ontologias_y_conserva_destinos_borrados() {
    let (_temp, graph) = fixture().await;
    graph.apply(serde_json::from_value(json!({"id":"contacts","name":"Contactos","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE contact SCHEMALESS PERMISSIONS FULL;"}],"collections":[{"table":"contact","label":"Contactos","titleField":"name","fields":[{"key":"person","label":"Persona","type":"reference","reference":{"ontologyId":"escriba","table":"person"}}]}]})).unwrap()).await.unwrap();
    graph
        .sync_base_change(&crate::persistence::CoreChange {
            key: "person:ada".into(),
            revision: "one".into(),
            kind: "person".into(),
            id: "ada".into(),
            value: Some(json!({"id":"ada","name":"Ada"})),
        })
        .await
        .unwrap();
    graph.query("contacts",1,"CREATE contact:a SET name='Ada', person={ontologyId:'escriba',table:'person',id:'person:`ada`'}; CREATE contact:gone SET person={ontologyId:'escriba',table:'person',id:'person:gone'}; CREATE contact:empty SET name='Sin referencia'; CREATE contact:null SET person=NULL",json!({})).await.unwrap();
    let forward = graph
        .graph_expand("contacts", "contact:a", 0)
        .await
        .unwrap();
    assert_eq!(forward.edges.len(), 1);
    assert_eq!(forward.edges[0].kind, graph::EdgeKind::Reference);
    assert_eq!(forward.edges[0].target, "[\"escriba\",\"person:ada\"]");
    let backward = graph
        .graph_expand("escriba", "person:ada", 0)
        .await
        .unwrap();
    assert_eq!(backward.edges.len(), 1);
    assert_eq!(backward.edges[0].key, forward.edges[0].key);
    let dangling = graph
        .graph_expand("contacts", "contact:gone", 0)
        .await
        .unwrap();
    assert!(dangling
        .nodes
        .iter()
        .any(|n| n.missing && n.record_id == "person:gone"));
    graph.close().await.unwrap();
}

#[tokio::test]
async fn pagina_conexiones_y_procedencia_en_ambas_direcciones_sin_perdidas() {
    let (_temp, graph) = fixture().await;
    graph.query("test",1,"CREATE topic:a SET name='A'; CREATE topic:b SET name='B'; FOR $n IN 0..45 { RELATE topic:a->(type::record('connects',<string>$n))->topic:b; };",json!({})).await.unwrap();
    graph
        .link(
            "test",
            1,
            "topic:a",
            Source {
                recording_id: "audio".into(),
                version_id: "v1".into(),
                recipe_id: None,
            },
        )
        .await
        .unwrap();
    let first = graph.graph_expand("test", "topic:a", 0).await.unwrap();
    let second = graph.graph_expand("test", "topic:a", 1).await.unwrap();
    assert_eq!(first.edges.len(), 40);
    assert!(first.has_more);
    assert_eq!(second.edges.len(), 6);
    assert!(!second.has_more);
    let keys: std::collections::HashSet<_> = first
        .edges
        .iter()
        .chain(&second.edges)
        .map(|e| &e.key)
        .collect();
    assert_eq!(keys.len(), 46);
    let provenance = second
        .edges
        .iter()
        .find(|e| e.kind == graph::EdgeKind::Provenance)
        .unwrap();
    let backward = graph
        .graph_expand("escriba", "version:['audio', 'v1']", 0)
        .await
        .unwrap();
    assert_eq!(backward.edges.len(), 1);
    assert_eq!(backward.edges[0].key, provenance.key);
    assert!(backward
        .nodes
        .iter()
        .any(|n| n.missing && n.table == "version"));
    graph.close().await.unwrap();
}

#[tokio::test]
async fn detalle_acota_textos_y_senala_recortes_sin_modificar_registros() {
    let (_temp, graph) = fixture().await;
    let name = "x".repeat(3000);
    graph
        .query(
            "test",
            1,
            "CREATE topic:large SET name=$name",
            json!({"name":name}),
        )
        .await
        .unwrap();
    let detail = graph.graph_detail("test", "topic:large").await.unwrap();
    assert_eq!(detail.values["name"].as_str().unwrap().len(), 2000);
    assert_eq!(detail.truncated_fields, vec!["name"]);
    assert!(
        graph.graph_roots("test", "topic", 0).await.unwrap().nodes[0]
            .label
            .ends_with('…')
    );
    let persisted = graph.records("test", "topic", 0, None, None).await.unwrap();
    assert_eq!(persisted.records[0].values["name"], name);
    graph.close().await.unwrap();
}

#[tokio::test]
async fn comandos_sincronizan_la_base_y_rechazan_paginas_invalidas() {
    use crate::knowledge_commands::call as dispatch;
    let temp = tempfile::tempdir().unwrap();
    let mut store = crate::store::Store::open(temp.path().join("library")).unwrap();
    let audio = temp.path().join("prueba.wav");
    std::fs::write(&audio, b"sintetico").unwrap();
    store.import(&audio, None).unwrap();
    let store = crate::library::Library::new(store).unwrap();
    let graph = Knowledge::open(&temp.path().join("graph")).await.unwrap();
    let roots = dispatch(
        &graph,
        &store,
        "knowledge_graph_roots",
        json!({"ontologyId":"escriba","table":"recording"}),
    )
    .await
    .unwrap();
    assert_eq!(roots["nodes"].as_array().unwrap().len(), 1);
    let record = roots["nodes"][0]["recordId"].as_str().unwrap();
    let detail = dispatch(
        &graph,
        &store,
        "knowledge_graph_detail",
        json!({"ontologyId":"escriba","recordId":record}),
    )
    .await
    .unwrap();
    assert_eq!(detail["table"], "recording");
    assert!(dispatch(
        &graph,
        &store,
        "knowledge_graph_expand",
        json!({"ontologyId":"escriba","recordId":record,"page":-1})
    )
    .await
    .is_err());
    graph.close().await.unwrap();
}

#[tokio::test]
async fn pagina_raices_y_conserva_el_tipo_de_detalles_json_cortos() {
    let (_temp, graph) = fixture().await;
    graph
        .query(
            "test",
            1,
            "FOR $n IN 0..41 { CREATE type::record('topic',<string>$n) SET name='Tema'; };",
            json!({}),
        )
        .await
        .unwrap();
    let first = graph.graph_roots("test", "topic", 0).await.unwrap();
    let second = graph.graph_roots("test", "topic", 1).await.unwrap();
    assert_eq!(first.nodes.len(), 40);
    assert!(first.has_more);
    assert_eq!(second.nodes.len(), 1);
    assert!(!second.has_more);
    assert!(!first.nodes.iter().any(|n| n.key == second.nodes[0].key));
    graph
        .query(
            "test",
            1,
            "UPDATE topic:⟨0⟩ SET name={nested:[1,true]}",
            json!({}),
        )
        .await
        .unwrap();
    let detail = graph.graph_detail("test", "topic:`0`").await.unwrap();
    assert_eq!(detail.values["name"], json!({"nested":[1,true]}));
    assert!(detail.truncated_fields.is_empty());
    graph.close().await.unwrap();
}

#[tokio::test]
async fn los_segmentos_se_conectan_por_referencia_con_su_transcripcion_y_su_hablante() {
    let (_temp, graph) = fixture().await;
    graph
        .sync_base_change(&crate::persistence::CoreChange {
            key: "recording:audio".into(),
            revision: "uno".into(),
            kind: "recording".into(),
            id: "audio".into(),
            value: Some(json!({"id":"audio","title":"Prueba","status":"done","currentVersionId":"v1","versions":[{"id":"v1","transcript":{"text":"Hola. Adiós.","segments":[{"start":0,"end":1,"text":"Hola.","speaker":"Ada"},{"start":1,"end":2,"text":"Adiós.","speaker":"Ada"}]}}]})),
        })
        .await
        .unwrap();
    let transcript = graph
        .graph_expand("escriba", "transcript:['audio', 'v1']", 0)
        .await
        .unwrap();
    let to_segments: Vec<_> = transcript
        .edges
        .iter()
        .filter(|e| {
            e.kind == graph::EdgeKind::Reference && e.field.as_deref() == Some("transcript")
        })
        .collect();
    assert_eq!(to_segments.len(), 2);
    let speaker = graph
        .graph_expand("escriba", "speaker:['audio', 'v1', 'Ada']", 0)
        .await
        .unwrap();
    assert_eq!(
        speaker
            .edges
            .iter()
            .filter(|e| e.field.as_deref() == Some("speakerRecord"))
            .count(),
        2
    );
    let segment = graph
        .graph_expand("escriba", "segment:['audio', 'v1', 0]", 0)
        .await
        .unwrap();
    let fields: std::collections::BTreeSet<_> = segment
        .edges
        .iter()
        .filter_map(|e| e.field.as_deref())
        .collect();
    assert_eq!(fields, ["speakerRecord", "transcript"].into());
    let filtered = graph
        .filter_notes(serde_json::from_value(json!({"kind":"visual","match":"all","conditions":[{"ontologyId":"escriba","table":"segment","field":"transcript","operator":"eq","value":{"ontologyId":"escriba","table":"transcript","id":"transcript:['audio', 'v1']"}}]})).unwrap())
        .await
        .unwrap();
    assert_eq!(filtered.recording_ids, vec!["audio".to_string()]);
    graph.close().await.unwrap();
}
