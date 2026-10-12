use super::*;
use serde_json::json;

#[tokio::test]
async fn autentica_sesiones_de_registro_sin_escape_de_base() {
    let temp = tempfile::tempdir().unwrap();
    let knowledge = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let root = knowledge.root.clone();
    root.use_ns("knowledge").use_db("one").await.unwrap();
    root.query("DEFINE TABLE thing SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD title ON thing TYPE string; DEFINE TABLE principal PERMISSIONS NONE; CREATE principal:runtime; DEFINE ACCESS recipe ON DB TYPE RECORD SIGNIN (RETURN principal:runtime) DURATION FOR SESSION 1h; DEFINE USER migrator ON DB PASSWORD 'test' ROLES OWNER;").await.unwrap().check().unwrap();
    let session = root.clone();
    session
        .signin(Record {
            namespace: "knowledge".into(),
            database: "one".into(),
            access: "recipe".into(),
            params: json!({}),
        })
        .await
        .unwrap();
    session
        .query("CREATE thing:hello SET title = 'Hello'")
        .await
        .unwrap()
        .check()
        .unwrap();
    assert!(session
        .query("DEFINE TABLE forbidden")
        .await
        .unwrap()
        .check()
        .is_err());
    assert!(session
        .query("CREATE thing:bad SET title = 1")
        .await
        .unwrap()
        .check()
        .is_err());
    assert!(session
        .query("RETURN http::get('https://example.com')")
        .await
        .unwrap()
        .check()
        .is_err());
    assert!(session
        .query("USE NS knowledge DB registry; SELECT * FROM ontology")
        .await
        .unwrap()
        .check()
        .is_err());
    root.query("CREATE thing:root SET title = 'Root still scoped'")
        .await
        .unwrap()
        .check()
        .unwrap();
    let migration = root.clone();
    migration
        .signin(Database {
            namespace: "knowledge".into(),
            database: "one".into(),
            username: "migrator".into(),
            password: "test".into(),
        })
        .await
        .unwrap();
    assert!(migration
        .query("USE NS knowledge DB registry; DEFINE TABLE stolen")
        .await
        .unwrap()
        .check()
        .is_err());
}

fn ontology(id: &str) -> Ontology {
    serde_json::from_value(json!({"id":id,"name":"CRM","version":1,"migrations":[{"version":1,"sql":"DEFINE TABLE person SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD name ON person TYPE string;"}],"collections":[{"table":"person","label":"Personas","titleField":"name","fields":[{"key":"name","label":"Nombre","type":"text","required":true}]}]})).unwrap()
}
#[tokio::test]
async fn aplica_ontologias_aisladas_y_versiones_inmutables_con_rollback() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    {
        let db = Knowledge::open(&path).await.unwrap();
        db.apply(ontology("one")).await.unwrap();
        db.apply(ontology("two")).await.unwrap();
        db.query(
            "one",
            1,
            "CREATE person:a SET name = $name",
            json!({"name":"Ada"}),
        )
        .await
        .unwrap();
        assert_eq!(
            db.query("two", 1, "SELECT * FROM person", json!({}))
                .await
                .unwrap(),
            vec![json!([])]
        );
        let mut changed = ontology("one");
        changed.name = "Changed".into();
        assert!(db.apply(changed).await.is_err());
        let mut upgrade = ontology("one");
        upgrade.version = 2;
        upgrade.migrations.push(Migration {
            version: 2,
            sql: "DEFINE TABLE new_table PERMISSIONS FULL; THROW 'fail upgrade';".into(),
        });
        assert!(db.apply(upgrade.clone()).await.is_err());
        assert_eq!(db.list().await.unwrap()[0].version, 1);
        assert_eq!(
            db.query("one", 1, "CREATE new_table:a", json!({}))
                .await
                .unwrap(),
            vec![json!([])]
        );
        upgrade.migrations[1].sql = "DEFINE FIELD age ON person TYPE option<int>;".into();
        db.apply(upgrade).await.unwrap();
        assert!(db.apply(ontology("one")).await.is_err());
        assert_eq!(
            db.query("one", 2, "SELECT VALUE name FROM person", json!({}))
                .await
                .unwrap(),
            vec![json!(["Ada"])]
        );
        db.close().await.unwrap();
    }
    let db = Knowledge::open(&path).await.unwrap();
    assert_eq!(db.list().await.unwrap().len(), 2);
    assert_eq!(
        db.query("one", 2, "SELECT VALUE name FROM person", json!({}))
            .await
            .unwrap(),
        vec![json!(["Ada"])]
    );
}

#[tokio::test]
async fn conserva_tipos_del_sdk_y_no_confirma_migraciones_interrumpidas() {
    let fixture = "o2JpZMiCZnBlcnNvbmNhZGFlcHJpY2XKZTEyLjM0ZGRhdGXMghplk30lAA==";
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    db.apply(ontology("typed")).await.unwrap();
    let result = db
        .query_cbor(
            "typed",
            1,
            "RETURN { id: $id, price: $price, date: $date }",
            fixture,
        )
        .await
        .unwrap();
    let input = surrealdb_core::rpc::format::cbor::decode(
        &base64::engine::general_purpose::STANDARD
            .decode(fixture)
            .unwrap(),
        64,
    )
    .unwrap();
    let output = surrealdb_core::rpc::format::cbor::decode(
        &base64::engine::general_purpose::STANDARD
            .decode(result)
            .unwrap(),
        64,
    )
    .unwrap();
    assert_eq!(output, DbValue::Array(vec![input].into()));
    let mut upgrade = ontology("typed");
    upgrade.version = 2;
    upgrade.migrations.push(Migration {
        version: 2,
        sql: "DEFINE TABLE escape PERMISSIONS FULL; COMMIT; THROW 'abort'".into(),
    });
    assert!(db.apply(upgrade).await.is_err());
    assert_eq!(db.list().await.unwrap()[0].version, 1);
    assert_eq!(
        db.query("typed", 1, "CREATE escape:a", json!({}))
            .await
            .unwrap(),
        vec![json!([])]
    );
}

#[tokio::test]
async fn edita_con_conflictos_y_vincula_sin_perder_datos_compartidos() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    db.apply(ontology("crm")).await.unwrap();
    let source = Source {
        recording_id: "note1".into(),
        version_id: "version1".into(),
        recipe_id: None,
    };
    let saved = db
        .save(SaveRecord {
            ontology_id: "crm".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: None,
            expected_rev: None,
            values: json!({"name":"Ada"}),
            source: Some(source.clone()),
        })
        .await
        .unwrap();
    assert_eq!(
        db.records("crm", "person", 0, Some("note1"), None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
    assert!(db
        .records("crm", "person", 0, Some("note2"), None)
        .await
        .unwrap()
        .records
        .is_empty());
    db.link(
        "crm",
        1,
        &saved.id,
        Source {
            recording_id: "note2".into(),
            ..source.clone()
        },
    )
    .await
    .unwrap();
    db.link("crm", 1, &saved.id, source).await.unwrap();
    assert_eq!(
        db.query("crm", 1, "SELECT * FROM _escriba_source", json!({}))
            .await
            .unwrap()[0]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    db.save(SaveRecord {
        ontology_id: "crm".into(),
        expected_version: 1,
        table: "person".into(),
        record_id: Some(saved.id.clone()),
        expected_rev: Some(saved.rev.clone()),
        values: json!({"name":"Augusta"}),
        source: None,
    })
    .await
    .unwrap();
    assert!(db
        .save(SaveRecord {
            ontology_id: "crm".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: Some(saved.id.clone()),
            expected_rev: Some(saved.rev.clone()),
            values: json!({"name":"Lost"}),
            source: None
        })
        .await
        .is_err());
    assert!(db
        .delete("crm", 1, "person", &saved.id, &saved.rev)
        .await
        .is_err());
    let row = db
        .records("crm", "person", 0, Some("note2"), None)
        .await
        .unwrap()
        .records
        .remove(0);
    let edited = db
        .save(SaveRecord {
            ontology_id: "crm".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: Some(row.id.clone()),
            expected_rev: Some(row.rev),
            values: json!({"name":"Ada Lovelace"}),
            source: None,
        })
        .await
        .unwrap();
    db.delete("crm", 1, "person", &edited.id, &edited.rev)
        .await
        .unwrap();
    assert!(db
        .records("crm", "person", 0, None, None)
        .await
        .unwrap()
        .records
        .is_empty());
    assert_eq!(
        db.query("crm", 1, "SELECT * FROM _escriba_source", json!({}))
            .await
            .unwrap(),
        vec![json!([])]
    );
}
#[tokio::test]
async fn crea_relaciones_con_extremos_y_fechas_nativos() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let mut definition = ontology("relations");
    definition.migrations[0].sql.push_str(" DEFINE TABLE knows TYPE RELATION IN person OUT person ENFORCED SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD since ON knows TYPE datetime;");
    definition.collections.push(Collection {
        table: "knows".into(),
        label: "Conoce".into(),
        title_field: "since".into(),
        fields: vec![Field {
            reference: None,
            key: "since".into(),
            label: "Desde".into(),
            kind: FieldType::Date,
            required: true,
        }],
        relation: Some(Relation {
            from: "person".into(),
            to: "person".into(),
        }),
    });
    db.apply(definition).await.unwrap();
    db.query(
        "relations",
        1,
        "CREATE person:a SET name='Ada'; CREATE person:b SET name='Grace';",
        json!({}),
    )
    .await
    .unwrap();
    let relation = db
        .save(SaveRecord {
            ontology_id: "relations".into(),
            expected_version: 1,
            table: "knows".into(),
            record_id: None,
            expected_rev: None,
            values: json!({"in":"person:a","out":"person:b","since":"2024-01-02T03:04:05Z"}),
            source: None,
        })
        .await
        .unwrap();
    assert_eq!(relation.values["in"], "person:a");
    assert_eq!(
        db.query(
            "relations",
            1,
            "SELECT VALUE ->knows->person.name FROM person:a",
            json!({})
        )
        .await
        .unwrap(),
        vec![json!([["Grace"]])]
    );
}

#[tokio::test]
async fn rechaza_eventos_y_administracion_en_cualquier_nivel_de_la_migracion() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    for statement in [
        "DEFINE EVENT hostile ON person WHEN $event = 'CREATE' THEN (RETURN true);",
        "IF true { DEFINE EVENT hidden ON person WHEN true THEN (RETURN true); };",
        "DEFINE FUNCTION fn::bad() { DEFINE EVENT hidden ON person WHEN true THEN (RETURN true); };",
        "DEFINE USER bad ON DB PASSWORD 'abc' ROLES OWNER;",
        "DEFINE TABLE view_person AS SELECT * FROM person;",
        "DEFINE FIELD friend ON person TYPE option<record<person>> REFERENCE ON DELETE THEN { RETURN true; };",
        "REMOVE EVENT _escriba_manual_guard ON person;",
        "DEFINE TABLE OVERWRITE `_escriba_manifest` PERMISSIONS FULL;",
    ] {
        let mut definition=ontology("blocked");
        definition.migrations[0].sql.push_str(statement);
        assert!(db.apply(definition).await.is_err(),"{statement}");
    }
    assert!(db.list().await.unwrap().is_empty());
}
#[tokio::test]
async fn las_funciones_no_elevan_permisos_ni_sobrescriben_correcciones_manuales() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let mut definition = ontology("functions");
    definition.migrations[0].sql.push_str(" DEFINE FUNCTION fn::metadata() { RETURN (UPDATE type::record('_' + 'escriba_manifest','current') SET definition.name='Corrupted'); } PERMISSIONS FULL; DEFINE FUNCTION fn::schema() { DEFINE TABLE forbidden; } PERMISSIONS FULL; DEFINE FUNCTION fn::edit($id:record) { RETURN (UPDATE $id SET name='Changed'); } PERMISSIONS FULL;");
    db.apply(definition).await.unwrap();
    db.query("functions", 1, "RETURN fn::metadata()", json!({}))
        .await
        .unwrap();
    assert_eq!(db.list().await.unwrap()[0].name, "CRM");
    assert!(db
        .query("functions", 1, "RETURN fn::schema()", json!({}))
        .await
        .is_err());
    let saved = db
        .save(SaveRecord {
            ontology_id: "functions".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: None,
            expected_rev: None,
            values: json!({"name":"Manual"}),
            source: None,
        })
        .await
        .unwrap();
    for sql in [
        "UPDATE type::record($id) SET name='Changed'",
        "UPSERT type::record($id) SET name='Changed'",
        "DELETE type::record($id)",
        "RETURN fn::edit(type::record($id))",
    ] {
        assert!(
            db.query("functions", 1, sql, json!({"id":saved.id}))
                .await
                .is_err(),
            "{sql}"
        );
    }
    assert_eq!(
        db.records("functions", "person", 0, None, None)
            .await
            .unwrap()
            .records[0]
            .values["name"],
        "Manual"
    );
}

#[tokio::test]
async fn revierte_mutaciones_reservadas_dinamicas_y_no_permite_suplantar_auth() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    db.apply(ontology("private")).await.unwrap();
    let saved = db
        .save(SaveRecord {
            ontology_id: "private".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: None,
            expected_rev: None,
            values: json!({"name":"Manual"}),
            source: None,
        })
        .await
        .unwrap();
    for (sql, bindings) in [
        (
            "LET $auth = NONE; UPDATE type::record($id) SET name='Changed'",
            json!({"id":saved.id}),
        ),
        (
            "UPDATE type::record($id) SET name='Changed'",
            json!({"id":saved.id,"auth":null}),
        ),
        (
            "OPTION IMPORT; UPDATE type::record($id) SET name='Changed'",
            json!({"id":saved.id}),
        ),
    ] {
        assert!(
            db.query("private", 1, sql, bindings).await.is_err(),
            "{sql}"
        );
    }
    let mut upgrade = ontology("private");
    upgrade.version = 2;
    upgrade.migrations.push(Migration {
        version: 2,
        sql: "DEFINE TABLE lost PERMISSIONS FULL; DELETE type::table('_'+'escriba_manual');".into(),
    });
    assert!(db.apply(upgrade).await.is_err());
    assert_eq!(db.list().await.unwrap()[0].version, 1);
    assert!(db
        .query(
            "private",
            1,
            "DELETE type::record($id)",
            json!({"id":saved.id})
        )
        .await
        .is_err());
    assert_eq!(
        db.query("private", 1, "CREATE lost:a", json!({}))
            .await
            .unwrap(),
        vec![json!([])]
    );
}
#[tokio::test]
async fn instala_el_ejemplo_de_reuniones_y_acuerdos() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    db.sync_base_change(&crate::persistence::CoreChange {
        key: "recording:note1".into(),
        revision: "one".into(),
        kind: "recording".into(),
        id: "note1".into(),
        value: Some(json!({
            "id": "note1",
            "title": "Meeting",
            "versions": [{
                "id": "version1",
                "transcript": {"text": "Agreed", "segments": [{"text": "Agreed", "start": 0, "end": 1}]}
            }]
        })),
    })
    .await
    .unwrap();
    let segment_id = db
        .records("escriba", "segment", 0, None, None)
        .await
        .unwrap()
        .records[0]
        .id
        .clone();
    let mut definition = ontology("meeting");
    definition.collections.clear();
    definition.migrations[0].sql="DEFINE TABLE reunion SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD titulo ON reunion TYPE string; DEFINE FIELD fecha ON reunion TYPE datetime; DEFINE TABLE acuerdo SCHEMAFULL PERMISSIONS FULL; DEFINE FIELD titulo ON acuerdo TYPE string; DEFINE FIELD estado ON acuerdo TYPE string; DEFINE TABLE surgio_en TYPE RELATION IN acuerdo OUT reunion ENFORCED SCHEMAFULL PERMISSIONS FULL;".into();
    definition.version = 2;
    definition.migrations.push(Migration {
        version: 2,
        sql: "DEFINE FIELD segmento ON acuerdo TYPE option<object>; DEFINE FIELD segmento.ontologyId ON acuerdo TYPE string; DEFINE FIELD segmento.table ON acuerdo TYPE string; DEFINE FIELD segmento.id ON acuerdo TYPE string;".into(),
    });
    db.apply(definition).await.unwrap();
    let reference = json!({"ontologyId": "escriba", "table": "segment", "id": segment_id});
    db.query("meeting",2,"CREATE reunion:a SET titulo='Meeting',fecha=d'2024-01-02T03:04:05Z'; CREATE acuerdo:a SET titulo='Agree',estado='pending',segmento=$segmento; RELATE acuerdo:a->surgio_en->reunion:a",json!({"segmento": reference})).await.unwrap();
    let agreement = db
        .query(
            "meeting",
            2,
            "SELECT VALUE segmento FROM acuerdo:a",
            json!({}),
        )
        .await
        .unwrap();
    assert_eq!(agreement, vec![json!([reference])]);
}

#[tokio::test]
async fn desvincula_una_nota_sin_borrar_el_registro_compartido_y_limpia_campos_opcionales() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let mut definition = ontology("unlink");
    definition.migrations[0].sql.push_str(" DEFINE FIELD age ON person TYPE option<number>; DEFINE FIELD derived ON person TYPE option<string>;");
    definition.collections[0].fields.push(Field {
        reference: None,
        key: "age".into(),
        label: "Edad".into(),
        kind: FieldType::Number,
        required: false,
    });
    db.apply(definition).await.unwrap();
    db.query(
        "unlink",
        1,
        "CREATE person:a SET name='Ada',age=36,derived='Keep'",
        json!({}),
    )
    .await
    .unwrap();
    let original = db
        .records("unlink", "person", 0, None, None)
        .await
        .unwrap()
        .records
        .remove(0);
    let source = Source {
        recording_id: "note1".into(),
        version_id: "version1".into(),
        recipe_id: None,
    };
    let saved = db
        .save(SaveRecord {
            ontology_id: "unlink".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: Some(original.id),
            expected_rev: Some(original.rev),
            values: json!({"name":"Augusta"}),
            source: Some(source),
        })
        .await
        .unwrap();
    assert!(saved.values.get("age").is_none());
    assert_eq!(saved.values["derived"], "Keep");
    db.unlink("unlink", 1, &saved.id, "note1").await.unwrap();
    db.unlink("unlink", 1, &saved.id, "note1").await.unwrap();
    assert!(db
        .records("unlink", "person", 0, Some("note1"), None)
        .await
        .unwrap()
        .records
        .is_empty());
    assert_eq!(
        db.records("unlink", "person", 0, None, None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
}

#[tokio::test]
async fn consulta_tablas_internas_pero_solo_vincula_colecciones_presentables() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let mut definition = ontology("presentation");
    definition.migrations[0]
        .sql
        .push_str(" DEFINE TABLE internal SCHEMALESS PERMISSIONS FULL;");
    db.apply(definition).await.unwrap();
    db.query(
        "presentation",
        1,
        "CREATE internal:a SET value='Internal'; CREATE person:a SET name='Ada'",
        json!({}),
    )
    .await
    .unwrap();
    assert_eq!(
        db.query(
            "presentation",
            1,
            "SELECT VALUE value FROM internal",
            json!({})
        )
        .await
        .unwrap(),
        vec![json!(["Internal"])]
    );
    let source = Source {
        recording_id: "note1".into(),
        version_id: "version1".into(),
        recipe_id: None,
    };
    let error = db
        .link("presentation", 1, "internal:a", source.clone())
        .await
        .unwrap_err();
    assert!(error.contains("collections"));
    assert_eq!(
        db.query(
            "presentation",
            1,
            "SELECT * FROM _escriba_source",
            json!({})
        )
        .await
        .unwrap(),
        vec![json!([])]
    );
    db.link("presentation", 1, "person:a", source)
        .await
        .unwrap();
    assert_eq!(
        db.records("presentation", "person", 0, Some("note1"), None)
            .await
            .unwrap()
            .records
            .len(),
        1
    );
}

pub(super) async fn migration_checkpoint(version: u32) -> Result<(), String> {
    if version == 2 {
        if let Some(path) = std::env::var_os("ESCRIBA_KNOWLEDGE_CRASH_CHECKPOINT") {
            std::fs::write(
                path,
                b"migration statements applied, transaction uncommitted",
            )
            .map_err(error)?;
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    }
    Ok(())
}

#[tokio::test]
async fn el_cierre_forzado_revierte_esquema_datos_y_version_juntos() {
    const CHILD: &str = "ESCRIBA_KNOWLEDGE_CRASH_DATABASE";
    if let Some(path) = std::env::var_os(CHILD) {
        let db = Knowledge::open(Path::new(&path)).await.unwrap();
        let mut definition = ontology("crash");
        definition.version = 2;
        definition.migrations.push(Migration{version:2,sql:"DEFINE TABLE transient PERMISSIONS FULL; CREATE transient:a SET value='Uncommitted'; UPDATE person:a SET name='Uncommitted'; DEFINE FIELD age ON person TYPE option<int>;".into()});
        db.apply(definition).await.unwrap();
        panic!("The parent must terminate the child before commit");
    }
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knowledge.rocksdb");
    let checkpoint = temp.path().join("checkpoint");
    let db = Knowledge::open(&path).await.unwrap();
    db.apply(ontology("crash")).await.unwrap();
    db.query(
        "crash",
        1,
        "CREATE person:a SET name='Committed'",
        json!({}),
    )
    .await
    .unwrap();
    db.close().await.unwrap();
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "knowledge::tests::el_cierre_forzado_revierte_esquema_datos_y_version_juntos",
            "--nocapture",
        ])
        .env(CHILD, &path)
        .env("ESCRIBA_KNOWLEDGE_CRASH_CHECKPOINT", &checkpoint)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while !checkpoint.exists() {
        if let Some(status) = child.try_wait().unwrap() {
            panic!("Migration child exited before checkpoint: {status}")
        }
        if std::time::Instant::now() > deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("Migration child did not reach checkpoint")
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    child.kill().unwrap();
    child.wait().unwrap();
    let db = Knowledge::open(&path).await.unwrap();
    assert_eq!(db.list().await.unwrap()[0].version, 1);
    assert_eq!(
        db.query("crash", 1, "SELECT VALUE name FROM person", json!({}))
            .await
            .unwrap(),
        vec![json!(["Committed"])]
    );
    assert_eq!(
        db.query("crash", 1, "CREATE transient:b", json!({}))
            .await
            .unwrap(),
        vec![json!([])]
    );
    assert!(db
        .query(
            "crash",
            1,
            "UPDATE person:a SET age=99 RETURN AFTER",
            json!({})
        )
        .await
        .unwrap_err()
        .contains("no such field"));
    db.close().await.unwrap();
}

#[tokio::test]
async fn conserva_json_null_y_distingue_la_omision_del_campo() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    let mut definition = ontology("json");
    definition.migrations[0]
        .sql
        .push_str(" DEFINE FIELD details ON person TYPE any;");
    definition.collections[0].fields.push(Field {
        reference: None,
        key: "details".into(),
        label: "Detalles".into(),
        kind: FieldType::Json,
        required: false,
    });
    db.apply(definition).await.unwrap();
    let saved = db
        .save(SaveRecord {
            ontology_id: "json".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: None,
            expected_rev: None,
            values: json!({"name":"Ada","details":null}),
            source: None,
        })
        .await
        .unwrap();
    assert_eq!(saved.values.get("details"), Some(&Value::Null));
    let read = db
        .records("json", "person", 0, None, None)
        .await
        .unwrap()
        .records
        .remove(0);
    assert_eq!(read.values.get("details"), Some(&Value::Null));
    let cleared = db
        .save(SaveRecord {
            ontology_id: "json".into(),
            expected_version: 1,
            table: "person".into(),
            record_id: Some(read.id),
            expected_rev: Some(read.rev),
            values: json!({"name":"Ada"}),
            source: None,
        })
        .await
        .unwrap();
    assert!(cleared.values.get("details").is_none());
}

#[tokio::test]
async fn editar_y_vincular_manualmente_conserva_la_receta_de_origen() {
    let temp = tempfile::tempdir().unwrap();
    let db = Knowledge::open(&temp.path().join("knowledge.rocksdb"))
        .await
        .unwrap();
    db.apply(ontology("provenance")).await.unwrap();
    db.query("provenance", 1, "CREATE person:a SET name='Ada'", json!({}))
        .await
        .unwrap();
    let source = Source {
        recording_id: "note1".into(),
        version_id: "version1".into(),
        recipe_id: Some("original-recipe".into()),
    };
    db.link("provenance", 1, "person:a", source.clone())
        .await
        .unwrap();
    let row = db
        .records("provenance", "person", 0, None, None)
        .await
        .unwrap()
        .records
        .remove(0);
    let manual = Source {
        recipe_id: None,
        ..source
    };
    db.save(SaveRecord {
        ontology_id: "provenance".into(),
        expected_version: 1,
        table: "person".into(),
        record_id: Some(row.id),
        expected_rev: Some(row.rev),
        values: json!({"name":"Augusta"}),
        source: Some(manual.clone()),
    })
    .await
    .unwrap();
    let recipes = db
        .query(
            "provenance",
            1,
            "SELECT VALUE recipeId FROM _escriba_source WHERE recordingId='note1'",
            json!({}),
        )
        .await
        .unwrap();
    assert_eq!(recipes, vec![json!(["original-recipe"])]);
    db.link("provenance", 1, "person:a", manual.clone())
        .await
        .unwrap();
    assert_eq!(
        db.query(
            "provenance",
            1,
            "SELECT VALUE recipeId FROM _escriba_source WHERE recordingId='note1'",
            json!({})
        )
        .await
        .unwrap(),
        vec![json!(["original-recipe"])]
    );
    db.link(
        "provenance",
        1,
        "person:a",
        Source {
            recording_id: "note2".into(),
            ..manual.clone()
        },
    )
    .await
    .unwrap();
    let rows = db
        .query(
            "provenance",
            1,
            "SELECT * FROM _escriba_source WHERE recordingId='note2'",
            json!({}),
        )
        .await
        .unwrap();
    assert_eq!(rows[0].as_array().unwrap().len(), 1);
    assert!(rows[0][0].get("recipeId").is_none());
    db.link(
        "provenance",
        1,
        "person:a",
        Source {
            recipe_id: Some("new-recipe".into()),
            ..manual
        },
    )
    .await
    .unwrap();
    assert_eq!(
        db.query(
            "provenance",
            1,
            "SELECT VALUE recipeId FROM _escriba_source WHERE recordingId='note1'",
            json!({})
        )
        .await
        .unwrap(),
        vec![json!(["new-recipe"])]
    );
}
