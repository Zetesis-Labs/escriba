use super::*;

mod scoped_tests {
    use super::*;

    fn library() -> Value {
        json!({"schemaVersion":1,"recordings":[{"id":"r","status":"done","title":"Nota","currentVersionId":"v","versions":[{"id":"v","recipeId":"old","backend":"local","transcript":{"text":"secreto completo","segments":[{"start":0,"end":1,"text":"secreto","words":[{"start":0,"end":1,"text":"secreto"}]}]}}],"publications":[]}],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}})
    }

    #[tokio::test]
    async fn indice_ligero_y_detalle_conservan_transcripcion() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        let mut full = library();
        let long_text = format!("{}MARCADOR_FINAL", "x".repeat(500));
        full["recordings"][0]["versions"][0]["transcript"]["text"] = json!(long_text);
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), full.clone()).await.unwrap();
        let index = db.load_index().await.unwrap().unwrap();
        assert!(!index.to_string().contains("MARCADOR_FINAL"));
        assert_eq!(
            index["recordings"][0]["versions"][0]["transcript"]["text"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            400
        );
        assert!(
            index["recordings"][0]["versions"][0]["transcript"]["segments"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            db.recording("r").await.unwrap().unwrap(),
            full["recordings"][0]
        );
    }

    #[tokio::test]
    async fn cambio_acotado_conserva_hijos_ajenos_y_remapea_receta() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        let mut full = library();
        full["recordings"][0]["publications"] = json!([{"destinationId":"d","provider":"notion","receipt":{"state":"published","locator":"x","privateBundle":"paquete oculto"}}]);
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), full).await.unwrap();
        let before = db.load_index().await.unwrap().unwrap();
        let mut after = before.clone();
        after["recordings"][0]["title"] = json!("Nuevo");
        let scope = WriteScope {
            recipe_aliases: HashMap::from([("old".into(), "new".into())]),
            ..Default::default()
        };
        db.save_scoped(before, after, scope).await.unwrap();
        let record = db.recording("r").await.unwrap().unwrap();
        assert_eq!(
            record["versions"][0]["transcript"]["text"],
            "secreto completo"
        );
        assert_eq!(
            record["publications"][0]["receipt"]["privateBundle"],
            "paquete oculto"
        );
        assert!(!db
            .load_index()
            .await
            .unwrap()
            .unwrap()
            .to_string()
            .contains("paquete oculto"));
        assert_eq!(record["versions"][0]["recipeId"], "new");
        assert_eq!(
            db.load_index().await.unwrap().unwrap()["recordings"][0]["versions"][0]["recipeId"],
            "new"
        );
    }

    #[tokio::test]
    async fn intercambio_de_aliases_usa_la_receta_original_de_cada_version() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        let mut full = library();
        full["recordings"][0]["versions"][0]["recipeId"] = json!("A");
        let mut second = full["recordings"][0]["versions"][0].clone();
        second["id"] = json!("w");
        second["recipeId"] = json!("B");
        full["recordings"][0]["versions"]
            .as_array_mut()
            .unwrap()
            .push(second);
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), full).await.unwrap();
        let before = db.load_index().await.unwrap().unwrap();
        let scope = WriteScope {
            recipe_aliases: HashMap::from([("A".into(), "B".into()), ("B".into(), "A".into())]),
            ..Default::default()
        };
        db.save_scoped(before.clone(), before, scope).await.unwrap();
        let record = db.recording("r").await.unwrap().unwrap();
        assert_eq!(record["versions"][0]["recipeId"], "B");
        assert_eq!(record["versions"][1]["recipeId"], "A");
        let index = db.load_index().await.unwrap().unwrap();
        assert_eq!(index["recordings"][0]["versions"][0]["recipeId"], "B");
        assert_eq!(index["recordings"][0]["versions"][1]["recipeId"], "A");
    }

    #[tokio::test]
    async fn cadena_de_aliases_no_aplica_dos_saltos_a_una_version() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        let mut full = library();
        full["recordings"][0]["versions"][0]["recipeId"] = json!("A");
        let mut second = full["recordings"][0]["versions"][0].clone();
        second["id"] = json!("w");
        second["recipeId"] = json!("B");
        full["recordings"][0]["versions"]
            .as_array_mut()
            .unwrap()
            .push(second);
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), full).await.unwrap();
        let before = db.load_index().await.unwrap().unwrap();
        let scope = WriteScope {
            recipe_aliases: HashMap::from([("A".into(), "B".into()), ("B".into(), "C".into())]),
            ..Default::default()
        };
        db.save_scoped(before.clone(), before, scope).await.unwrap();
        let record = db.recording("r").await.unwrap().unwrap();
        assert_eq!(record["versions"][0]["recipeId"], "B");
        assert_eq!(record["versions"][1]["recipeId"], "C");
    }

    #[tokio::test]
    async fn version_hidratada_actualiza_proyeccion_y_detalle() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), library()).await.unwrap();
        let mut before = db.load_index().await.unwrap().unwrap();
        before["recordings"][0] = db.recording("r").await.unwrap().unwrap();
        let mut after = before.clone();
        after["recordings"][0]["versions"][0]["transcript"]["text"] = json!("nuevo texto");
        let scope = WriteScope {
            full_recordings: HashSet::from(["r".into()]),
            ..Default::default()
        };
        db.save_scoped(before, after, scope).await.unwrap();
        assert_eq!(
            db.recording("r").await.unwrap().unwrap()["versions"][0]["transcript"]["text"],
            "nuevo texto"
        );
        assert_eq!(
            db.load_index().await.unwrap().unwrap()["recordings"][0]["versions"][0]["transcript"]
                ["text"],
            "nuevo texto"
        );
    }

    #[tokio::test]
    async fn fallo_de_escritura_acotada_revierte_metadatos() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), library()).await.unwrap();
        let before = db.load_index().await.unwrap().unwrap();
        db.query_test(
            "DEFINE FIELD OVERWRITE title ON TABLE recording ASSERT $value != 'Prohibido'",
        )
        .await
        .unwrap();
        let mut after = before.clone();
        after["recordings"][0]["title"] = json!("Prohibido");
        assert!(db
            .save_scoped(before.clone(), after, WriteScope::default())
            .await
            .is_err());
        assert_eq!(db.load_index().await.unwrap().unwrap(), before);
        assert_eq!(
            db.recording("r").await.unwrap().unwrap()["versions"][0]["transcript"]["text"],
            "secreto completo"
        );
    }

    #[tokio::test]
    async fn descarte_acotado_borra_versiones_y_recibos_no_hidratados() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        let mut full = library();
        full["recordings"][0]["publications"] =
            json!([{"destinationId":"d","receipt":{"state":"published","locator":"x"}}]);
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), full).await.unwrap();
        let before = db.load_index().await.unwrap().unwrap();
        let mut after = before.clone();
        after["recordings"][0] =
            json!({"id":"r","status":"discarded","source":null,"sourceKey":null,"legacyKey":null});
        db.save_scoped(before, after, WriteScope::default())
            .await
            .unwrap();
        let record = db.recording("r").await.unwrap().unwrap();
        assert!(record.get("versions").is_none());
        assert!(record.get("publications").is_none());
        assert_eq!(record["status"], "discarded");
    }

    #[tokio::test]
    async fn indice_rechaza_proyeccion_huerfana_y_detalle_hijo_sin_proyeccion() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), library()).await.unwrap();
        db.load_index().await.unwrap();
        db.query_test("CREATE version_preview:orphan SET key = '[\"ausente\",\"v\"]', parent = 'ausente', position = 0, payload = { id: 'v', transcript: { text: 'contenido', segments: [] } }").await.unwrap();
        assert!(db.load_index().await.unwrap_err().contains("huérfana"));
        db.query_test("DELETE version_preview:orphan")
            .await
            .unwrap();
        db.query_test("CREATE version:extra SET key = '[\"r\",\"extra\"]', parent = 'r', position = 1, payload = { id: 'extra', transcript: { text: 'contenido', segments: [] } }").await.unwrap();
        assert!(db.recording("r").await.unwrap_err().contains("proyección"));
    }

    #[tokio::test]
    async fn backfill_rechaza_version_corrupta_sin_marcarse_completo() {
        let temp = tempfile::tempdir().unwrap();
        let db = Persistence::open(temp.path()).await.unwrap();
        db.save(json!({"schemaVersion":1,"recordings":[],"accounts":[],"resolvers":[],"recipes":[],"destinations":[],"logs":[],"settings":{}}), library()).await.unwrap();
        db.query_test("UPDATE version SET payload.backend = true")
            .await
            .unwrap();
        assert!(db
            .load_index()
            .await
            .unwrap_err()
            .contains("Versión guardada inválida"));
        let marks = db
            .select_test("SELECT key FROM meta WHERE key = 'preview_v1'")
            .await
            .unwrap();
        assert!(marks.is_empty());
    }
}

#[test]
fn consulta_dinamica_por_parent_usa_el_indice_en_surrealdb() {
    let temp = tempfile::tempdir().unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let db = Surreal::new::<surrealdb::engine::local::RocksDb>(temp.path().join("plan.rocksdb")).await.unwrap();
        db.use_ns("test").use_db("index_plan").await.unwrap();
        db.query("DEFINE TABLE version SCHEMALESS; DEFINE INDEX idx_version_parent ON TABLE version FIELDS parent; CREATE version:a SET parent = 'r', position = 0, payload = {id: 'a'}; CREATE version:b SET parent = 'other', position = 1, payload = {id: 'b'}")
            .await.unwrap().check().unwrap();
        let unusual = "comilla ' doble \" barra \\ eñe ñ\nlínea";
        db.query("CREATE version:quoted SET key = 'quoted', parent = $parent, position = 2, payload = {id: 'quoted'}")
            .bind(("parent", unusual)).await.unwrap().check().unwrap();
        let rows = rows_for_parent(&db, "version", unusual).await.unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].key, "quoted");
        let literal = serde_json::to_string("r").unwrap();
        for source in ["version", "type::table($table)"] {
            for condition in ["parent = $parent".to_owned(), format!("parent = {literal}")] {
                let query = format!("EXPLAIN ANALYZE SELECT key, parent, position, payload FROM {source} WHERE {condition}");
                let mut response = db.query(query)
                    .bind(("table", "version"))
                    .bind(("parent", "r"))
                    .await.unwrap().check().unwrap();
                let plan: Option<String> = response.take(0).unwrap();
                let plan = plan.unwrap();
                if condition != "parent = $parent" {
                    assert!(plan.contains("IndexScan") && plan.contains("idx_version_parent"), "{source} no usó el índice: {plan}");
                }
            }
        }
    });
}
