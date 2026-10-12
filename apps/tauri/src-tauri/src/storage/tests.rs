use super::*;
use serde_json::json;

fn root() -> Root {
    Root {
        username: "escriba".into(),
        password: "clave".into(),
    }
}

async fn legacy_graph(path: &Path) {
    let db = connect(
        Engine::SurrealKv,
        path,
        Config::new().user(root()),
        Some(&root()),
    )
    .await
    .unwrap();
    db.use_ns("knowledge").use_db("registry").await.unwrap();
    db.query("DEFINE TABLE ontology SCHEMALESS PERMISSIONS NONE; UPSERT ontology:sintetica SET ontology_id = 'sintetica'")
        .await
        .unwrap()
        .check()
        .unwrap();
    db.use_ns("knowledge").use_db("sintetica").await.unwrap();
    db.query(format!("DEFINE TABLE nota SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD titulo ON nota TYPE string; DEFINE INDEX nota_titulo ON nota FIELDS titulo; DEFINE TABLE enlaza TYPE RELATION FROM nota TO nota PERMISSIONS FULL; DEFINE TABLE _escriba_principal SCHEMALESS PERMISSIONS NONE; UPSERT _escriba_principal:runtime; {}; DEFINE USER _escriba_migrator ON DB PASSWORD 'migrador' ROLES OWNER; CREATE nota:uno SET titulo = 'Sintética'; CREATE nota:dos SET titulo = 'Otra'; RELATE nota:uno->enlaza->nota:dos", crate::knowledge::RECIPE_ACCESS))
        .await
        .unwrap()
        .check()
        .unwrap();
    drop(db);
    released(path).await.unwrap();
}

async fn titles(db: &Surreal<Db>) -> Value {
    db.use_ns("knowledge").use_db("sintetica").await.unwrap();
    let mut response = db
        .query("SELECT VALUE titulo FROM nota ORDER BY titulo; SELECT VALUE out.titulo FROM enlaza")
        .await
        .unwrap()
        .check()
        .unwrap();
    let titles: DbValue = response.take(0).unwrap();
    let linked: DbValue = response.take(1).unwrap();
    json!([titles.into_json_value(), linked.into_json_value()])
}

async fn close(db: Surreal<Db>, path: &Path) {
    drop(db);
    released(path).await.unwrap();
}

#[tokio::test]
async fn convierte_surrealkv_a_rocksdb_y_conserva_el_origen_con_otro_nombre() {
    let temp = tempfile::tempdir().unwrap();
    let legacy = temp.path().join("knowledge.surrealkv");
    let target = temp.path().join("knowledge.rocksdb");
    legacy_graph(&legacy).await;
    let db = open(&target, Config::new().user(root()), Some(root()))
        .await
        .unwrap();
    assert_eq!(titles(&db).await, json!([["Otra", "Sintética"], ["Otra"]]));
    assert!(!legacy.exists());
    assert!(temp.path().join("knowledge.surrealkv.convertida").is_dir());
    assert!(!target.with_extension("exportacion").exists());
    let recipe = db.clone();
    recipe
        .signin(surrealdb::opt::auth::Record {
            namespace: "knowledge".into(),
            database: "sintetica".into(),
            access: "_escriba_recipe".into(),
            params: json!({}),
        })
        .await
        .expect("El acceso de recetas se conserva");
    let mut response = recipe
        .query("SELECT VALUE titulo FROM nota ORDER BY titulo")
        .await
        .unwrap()
        .check()
        .unwrap();
    let readable: DbValue = response.take(0).unwrap();
    assert_eq!(readable.into_json_value(), json!(["Otra", "Sintética"]));
    drop(recipe);
    db.query("CREATE nota:tres SET titulo = 'Posterior'")
        .await
        .unwrap()
        .check()
        .unwrap();
    close(db, &target).await;
    let db = open(&target, Config::new().user(root()), Some(root()))
        .await
        .unwrap();
    assert_eq!(
        titles(&db).await,
        json!([["Otra", "Posterior", "Sintética"], ["Otra"]]),
        "Una base convertida no se vuelve a convertir"
    );
}

#[tokio::test]
async fn una_conversion_interrumpida_se_descarta_y_se_rehace_desde_el_origen() {
    let temp = tempfile::tempdir().unwrap();
    let legacy = temp.path().join("knowledge.surrealkv");
    let target = temp.path().join("knowledge.rocksdb");
    legacy_graph(&legacy).await;
    let partial = connect(
        Engine::RocksDb,
        &target,
        Config::new().user(root()),
        Some(&root()),
    )
    .await
    .unwrap();
    partial
        .use_ns("knowledge")
        .use_db("sintetica")
        .await
        .unwrap();
    partial
        .query("CREATE nota:resto SET titulo = 'A medias'")
        .await
        .unwrap()
        .check()
        .unwrap();
    close(partial, &target).await;
    std::fs::create_dir(target.with_extension("exportacion")).unwrap();
    let db = open(&target, Config::new().user(root()), Some(root()))
        .await
        .unwrap();
    assert_eq!(titles(&db).await, json!([["Otra", "Sintética"], ["Otra"]]));
}

#[tokio::test]
async fn un_origen_que_no_se_puede_leer_falla_sin_retirarlo_ni_abrir_una_base_vacia() {
    let temp = tempfile::tempdir().unwrap();
    let legacy = temp.path().join("knowledge.surrealkv");
    let target = temp.path().join("knowledge.rocksdb");
    legacy_graph(&legacy).await;
    let wrong = Root {
        username: "escriba".into(),
        password: "otra".into(),
    };
    let error = open(&target, Config::new().user(wrong.clone()), Some(wrong))
        .await
        .expect_err("Unas credenciales que no abren el origen no pueden dar una base vacía");
    assert!(error.contains("knowledge.surrealkv"), "{error}");
    assert!(legacy.is_dir());
    assert!(!temp.path().join("knowledge.surrealkv.convertida").exists());
    let db = open(&target, Config::new().user(root()), Some(root()))
        .await
        .unwrap();
    assert_eq!(titles(&db).await, json!([["Otra", "Sintética"], ["Otra"]]));
}

#[tokio::test]
async fn sin_origen_abre_rocksdb_y_un_nombre_ajeno_se_rechaza() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("library.rocksdb");
    let db = open(&target, Config::new(), None).await.unwrap();
    db.use_ns("escriba").use_db("library").await.unwrap();
    db.query("CREATE meta:uno").await.unwrap().check().unwrap();
    close(db, &target).await;
    assert!(!temp.path().join("library.surrealkv.convertida").exists());
    assert!(
        open(&temp.path().join("library.surrealkv"), Config::new(), None)
            .await
            .is_err()
    );
}

#[test]
fn convierte_solo_mientras_exista_el_origen() {
    assert_eq!(plan(true), Plan::Convert);
    assert_eq!(plan(false), Plan::Open);
}

#[test]
fn el_origen_retirado_no_pisa_uno_anterior() {
    let temp = tempfile::tempdir().unwrap();
    let legacy = temp.path().join("library.surrealkv");
    std::fs::create_dir(temp.path().join("library.surrealkv.convertida")).unwrap();
    assert_eq!(
        retired(&legacy),
        temp.path().join("library.surrealkv.convertida-2")
    );
}

async fn back_to_surrealkv(target: &Path, root: Option<Root>) {
    let config = match &root {
        Some(root) => Config::new().user(root.clone()),
        None => Config::new(),
    };
    let current = connect(Engine::RocksDb, target, config.clone(), root.as_ref())
        .await
        .unwrap();
    let databases = inventory(&current, root.as_ref()).await.unwrap();
    let legacy = target.with_extension("surrealkv");
    let previous = connect(Engine::SurrealKv, &legacy, config, root.as_ref())
        .await
        .unwrap();
    let dumps = tempfile::tempdir().unwrap();
    copy(&current, &previous, &databases, dumps.path())
        .await
        .unwrap();
    close(current, target).await;
    close(previous, &legacy).await;
    std::fs::remove_dir_all(target).unwrap();
}

#[test]
fn una_biblioteca_surrealkv_se_abre_convertida_con_sus_versiones() {
    let dir = tempfile::tempdir().unwrap();
    let library = dir.path().join("library");
    let audio = dir.path().join("nota.wav");
    std::fs::write(&audio, b"audio sintetico").unwrap();
    let mut store = crate::store::Store::open(library.clone()).unwrap();
    let record = store.import(&audio, None).unwrap();
    store
        .mutate(
            "version_save",
            &json!({"recordingId":record["id"],"backend":"sintetico","transcript":{"text":"Texto sintético","segments":[{"start":0,"end":1,"text":"Texto sintético","words":[{"start":0,"end":1,"text":"Texto"}]}]}}),
        )
        .unwrap();
    let id = record["id"].as_str().unwrap().to_owned();
    let before = store.recording(&id).unwrap();
    drop(store);
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(back_to_surrealkv(&library.join("library.rocksdb"), None));
    assert!(library.join("library.surrealkv").is_dir());
    let store = crate::store::Store::open(library.clone()).unwrap();
    assert_eq!(store.recording(&id).unwrap(), before);
    assert!(library.join("library.surrealkv.convertida").is_dir());
    assert!(!library.join("library.surrealkv").exists());
}

#[tokio::test]
async fn un_grafo_surrealkv_con_extension_se_abre_convertido_y_las_recetas_lo_leen() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    let graph = crate::knowledge::Knowledge::open(&path).await.unwrap();
    let extension: crate::knowledge::Ontology = serde_json::from_value(json!({
        "id":"sintetica","name":"Sintética","version":1,
        "migrations":[{"version":1,"sql":"DEFINE TABLE nota SCHEMALESS PERMISSIONS FULL;"}],
        "collections":[{"table":"nota","label":"Notas","titleField":"titulo","fields":[{"key":"titulo","label":"Título","type":"text"}]}]
    }))
    .unwrap();
    graph.apply(extension).await.unwrap();
    graph
        .query("sintetica", 1, "RETURN true", json!({}))
        .await
        .unwrap();
    let saved = graph.list().await.unwrap();
    graph.close().await.unwrap();
    let password = std::fs::read_to_string(temp.path().join("knowledge.key")).unwrap();
    back_to_surrealkv(
        &path,
        Some(Root {
            username: "escriba".into(),
            password,
        }),
    )
    .await;
    let graph = crate::knowledge::Knowledge::open(&path).await.unwrap();
    assert_eq!(graph.list().await.unwrap(), saved);
    graph
        .query("sintetica", 1, "SELECT * FROM nota", json!({}))
        .await
        .expect("Las recetas leen la extensión convertida");
    assert!(temp.path().join("knowledge.surrealkv.convertida").is_dir());
    graph.close().await.unwrap();
}
