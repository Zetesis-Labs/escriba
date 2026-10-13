use super::*;
use std::os::unix::fs::PermissionsExt;
use surrealdb::types::Value as DbValue;

#[tokio::test]
async fn abre_rocksdb_privada_y_conserva_lo_escrito_al_reabrir() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("library.rocksdb");
    let db = open(&target, Config::new(), None).await.unwrap();
    db.use_ns("escriba").use_db("library").await.unwrap();
    db.query("CREATE meta:uno SET valor = 'sintético'")
        .await
        .unwrap()
        .check()
        .unwrap();
    drop(db);
    released(&target).await.unwrap();
    assert_eq!(
        std::fs::metadata(&target).unwrap().permissions().mode() & 0o777,
        0o700
    );
    let db = open(&target, Config::new(), None).await.unwrap();
    db.use_ns("escriba").use_db("library").await.unwrap();
    let mut response = db
        .query("SELECT VALUE valor FROM meta")
        .await
        .unwrap()
        .check()
        .unwrap();
    let values: DbValue = response.take(0).unwrap();
    assert_eq!(values.into_json_value(), serde_json::json!(["sintético"]));
}

#[tokio::test]
async fn una_base_surrealkv_sin_convertir_no_se_sustituye_por_una_vacia() {
    let temp = tempfile::tempdir().unwrap();
    let legacy = temp.path().join("knowledge.surrealkv");
    let target = temp.path().join("knowledge.rocksdb");
    std::fs::create_dir(&legacy).unwrap();
    let error = open(&target, Config::new(), None)
        .await
        .expect_err("Una base anterior sin convertir no puede dar una base vacía");
    assert!(error.contains("knowledge.surrealkv"), "{error}");
    assert!(!target.exists());
    assert!(legacy.is_dir());
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn en_linux_liberada_espera_a_que_rocksdb_suelte_el_bloqueo() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("library.rocksdb");
    let db = open(&target, Config::new(), None).await.unwrap();
    db.use_ns("escriba").use_db("library").await.unwrap();
    assert!(held_by_this_process(&target.join("LOCK")));
    drop(db);
    released(&target).await.unwrap();
    assert!(!held_by_this_process(&target.join("LOCK")));
}
