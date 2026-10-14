//! Protocol v1 contract (docs/tauri-native-protocol.md) that every native host
//! honours, spoken to the real binary. `ESCRIBA_NATIVE_HOST=<binary> cargo
//! test --test contract` runs it against another host, such as the Swift one.

mod support;

use serde_json::{json, Value};
use std::{io::Write, process::Stdio};
use support::{command, fixture, seconds, Host};

#[test]
fn un_error_de_peticion_no_detiene_el_proceso() {
    let mut host = Host::start();
    let broken = host.line("{no es json");
    assert_eq!(broken["id"], Value::Null);
    assert_eq!(broken["error"]["code"], "invalid_json");
    let no_id = host.line(r#"{"method":"status","params":{}}"#);
    assert_eq!(no_id["error"]["code"], "invalid_request");
    let empty_id = host.line(r#"{"id":"","method":"status","params":{}}"#);
    assert_eq!(empty_id["id"], "");
    assert_eq!(empty_id["error"]["code"], "invalid_request");
    let bad_params = host.line(r#"{"id":"x","method":"status","params":[]}"#);
    assert_eq!(bad_params["id"], "x");
    assert_eq!(bad_params["error"]["code"], "invalid_request");
    assert_eq!(host.error("inventado", json!({}))["code"], "unknown_method");
    assert_eq!(host.result("status", json!({}))["protocolVersion"], 1);
}

#[test]
fn cerrar_la_entrada_termina_el_proceso() {
    let mut child = command()
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(
        child.stdin.as_mut().unwrap(),
        r#"{{"id":"a","method":"status","params":{{}}}}"#
    )
    .unwrap();
    drop(child.stdin.take());
    assert!(child.wait().unwrap().success());
}

#[test]
fn status_describe_whisper_y_el_llm() {
    let mut host = Host::start();
    let status = host.result("status", json!({}));
    assert_eq!(status["protocolVersion"], 1);
    assert!(status["whisper"]["available"].is_boolean(), "{status}");
    assert!(
        status["whisper"]["model"]
            .as_str()
            .is_some_and(|model| !model.is_empty()),
        "{status}"
    );
    assert!(status["whisper"]["modelsPath"].is_string(), "{status}");
    assert!(status["llm"]["available"].is_boolean(), "{status}");
    assert!(
        status["llm"]["reason"].is_null() || status["llm"]["reason"].is_string(),
        "{status}"
    );
    assert!(status["llm"]["capacity"].is_number(), "{status}");
    let error = host.error("status", json!({"model": "../fuera"}));
    assert_eq!(error["code"], "invalid_params");
}

#[test]
fn la_duracion_se_lee_de_los_formatos_comunes() {
    let mut host = Host::start();
    for name in ["tono.m4a", "tono.mp3", "tono.flac", "tono.wav"] {
        let info = host.result("audioInfo", json!({"audioPath": fixture(name)}));
        let duration = seconds(&info["duration"]);
        assert!((0.95..1.1).contains(&duration), "{name}: {duration}");
    }
}

#[test]
fn audio_ausente_o_ilegible_falla() {
    let folder = tempfile::tempdir().unwrap();
    let mut host = Host::start();
    let missing = host.error(
        "audioInfo",
        json!({"audioPath": folder.path().join("no-esta.m4a")}),
    );
    assert_eq!(missing["code"], "audio_missing");
    let directory = host.error("audioInfo", json!({"audioPath": folder.path()}));
    assert_eq!(directory["code"], "audio_missing");
    let text = folder.path().join("nota.m4a");
    std::fs::write(&text, "esto no es audio").unwrap();
    host.error("audioInfo", json!({"audioPath": text}));
}

#[test]
fn estado_de_archivo_usa_lstat() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("nota.m4a");
    std::fs::write(&file, b"audio sintetico").unwrap();
    let mut host = Host::start();
    let status = host.result("fileStatus", json!({"path": file}));
    assert_eq!(status["size"], 15);
    assert_eq!(status["dataless"], false);
    assert!(status["blocks"].as_u64().is_some(), "{status}");
    assert!(status["flags"].as_u64().is_some(), "{status}");
    let modified = status["modifiedAt"].as_str().unwrap();
    assert!(
        chrono::DateTime::parse_from_rfc3339(modified).is_ok(),
        "{modified}"
    );
    let link = folder.path().join("atajo.m4a");
    std::os::unix::fs::symlink(&file, &link).unwrap();
    assert_eq!(
        host.error("fileStatus", json!({"path": link}))["code"],
        "invalid_audio"
    );
    assert_eq!(
        host.error("fileStatus", json!({"path": folder.path()}))["code"],
        "invalid_audio"
    );
    assert_eq!(
        host.error("fileStatus", json!({"path": folder.path().join("no")}))["code"],
        "audio_missing"
    );
}

#[test]
fn materializar_valida_el_tiempo_y_la_ruta() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("nota.m4a");
    std::fs::write(&file, b"audio").unwrap();
    let empty = folder.path().join("vacia.m4a");
    std::fs::write(&empty, b"").unwrap();
    let mut host = Host::start();
    assert_eq!(
        host.result("materialize", json!({"path": empty}))["ready"],
        false
    );
    assert_eq!(
        host.error("materialize", json!({"path": file, "timeoutSeconds": 301}))["code"],
        "invalid_params"
    );
    assert_eq!(
        host.error("materialize", json!({"path": folder.path().join("no")}))["code"],
        "audio_missing"
    );
}

#[test]
fn sin_grabacion_activa_el_estado_lo_dice_y_parar_falla() {
    let mut host = Host::start();
    let status = host.result("recordingStatus", json!({}));
    assert_eq!(status["active"], false, "{status}");
    assert_eq!(status["audioPath"], Value::Null, "{status}");
    assert_eq!(seconds(&status["duration"]), 0.0, "{status}");
    assert_eq!(seconds(&status["level"]), 0.0, "{status}");
    for method in ["recordingStop", "recordingCancel"] {
        assert_eq!(
            host.error(method, json!({}))["code"],
            "recording_inactive",
            "{method}"
        );
    }
}

#[test]
fn el_catalogo_de_modelos_tiene_el_de_serie_y_tamanos() {
    let mut host = Host::start();
    let catalog = host.result("models", json!({}));
    let default = catalog["default"].as_str().unwrap();
    let models = catalog["models"].as_array().unwrap();
    assert!(
        models.iter().any(|model| model["model"] == default),
        "{catalog}"
    );
    for model in models {
        assert!(
            model["model"]
                .as_str()
                .is_some_and(|name| !name.is_empty() && !name.contains('/')),
            "{model}"
        );
        assert!(
            model["label"]
                .as_str()
                .is_some_and(|label| !label.is_empty()),
            "{model}"
        );
        assert!(
            model["bytes"].as_u64().is_some_and(|bytes| bytes > 0),
            "{model}"
        );
        assert!(model["installed"].is_boolean(), "{model}");
    }
    assert_eq!(
        host.error("deleteModel", json!({"model": "../fuera"}))["code"],
        "invalid_params"
    );
}
