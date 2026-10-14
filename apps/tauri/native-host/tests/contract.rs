//! Protocol v1 contract (docs/tauri-native-protocol.md), spoken to the real binary.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};

struct Host {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next: u32,
}

impl Host {
    fn start() -> Self {
        Self::start_with(&[])
    }

    fn start_with(env: &[(&str, &Path)]) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_EscribaNativeHost"));
        for (key, value) in env {
            command.env(key, value);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            input,
            output,
            next: 0,
        }
    }

    fn line(&mut self, line: &str) -> Value {
        writeln!(self.input, "{line}").unwrap();
        self.input.flush().unwrap();
        let mut reply = String::new();
        self.output.read_line(&mut reply).unwrap();
        serde_json::from_str(&reply).unwrap()
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let reply = self.line(&json!({"id": id, "method": method, "params": params}).to_string());
        assert_eq!(reply["id"], id.as_str(), "{reply}");
        reply
    }

    fn result(&mut self, method: &str, params: Value) -> Value {
        let reply = self.call(method, params);
        assert!(reply.get("error").is_none(), "{reply}");
        reply["result"].clone()
    }

    fn error(&mut self, method: &str, params: Value) -> Value {
        let reply = self.call(method, params);
        assert!(reply.get("result").is_none(), "{reply}");
        reply["error"].clone()
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn status_informa_de_whisper_sin_modelo_y_de_que_no_hay_llm() {
    let data = tempfile::tempdir().unwrap();
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    let status = host.result("status", json!({}));
    assert_eq!(status["protocolVersion"], 1);
    assert_eq!(status["whisper"]["available"], false);
    assert_eq!(status["whisper"]["model"], "large-v3-turbo");
    assert_eq!(
        status["whisper"]["modelsPath"],
        data.path().join("escriba/models").to_str().unwrap()
    );
    assert_eq!(status["llm"]["available"], false);
    assert!(status["llm"]["reason"]
        .as_str()
        .is_some_and(|reason| !reason.is_empty()));
    assert_eq!(status["llm"]["capacity"], 0);
    let other = host.result("status", json!({"model": "base"}));
    assert_eq!(other["whisper"]["model"], "base");
    let error = host.error("status", json!({"model": "../fuera"}));
    assert_eq!(error["code"], "invalid_params");
}

#[test]
fn la_duracion_se_lee_de_los_formatos_que_entran_por_carpeta() {
    let mut host = Host::start();
    for name in ["tono.m4a", "tono.ogg", "tono.mp3", "tono.flac", "tono.wav"] {
        let info = host.result("audioInfo", json!({"audioPath": fixture(name)}));
        let duration = info["duration"].as_f64().unwrap();
        assert!((0.95..1.1).contains(&duration), "{name}: {duration}");
    }
}

#[test]
fn audio_ausente_o_ilegible_falla_con_su_codigo() {
    let folder = tempfile::tempdir().unwrap();
    let mut host = Host::start();
    let missing = host.error(
        "audioInfo",
        json!({"audioPath": folder.path().join("no-esta.m4a")}),
    );
    assert_eq!(missing["code"], "audio_missing");
    let text = folder.path().join("nota.m4a");
    std::fs::write(&text, "esto no es audio").unwrap();
    let invalid = host.error("audioInfo", json!({"audioPath": text}));
    assert_eq!(invalid["code"], "invalid_audio");
    let directory = host.error("audioInfo", json!({"audioPath": folder.path()}));
    assert_eq!(directory["code"], "audio_missing");
}

#[test]
fn estado_de_archivo_usa_lstat_y_nunca_es_dataless() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("nota.ogg");
    std::fs::write(&file, b"audio sintetico").unwrap();
    let mut host = Host::start();
    let status = host.result("fileStatus", json!({"path": file}));
    assert_eq!(status["size"], 15);
    assert_eq!(status["flags"], 0);
    assert_eq!(status["dataless"], false);
    assert!(status["blocks"].as_u64().is_some());
    let modified = status["modifiedAt"].as_str().unwrap();
    assert!(
        chrono::DateTime::parse_from_rfc3339(modified).is_ok(),
        "{modified}"
    );
    assert!(modified.ends_with('Z'), "{modified}");
    let link = folder.path().join("atajo.ogg");
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
fn materializar_esta_listo_al_momento_sin_icloud() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("nota.m4a");
    std::fs::write(&file, b"audio").unwrap();
    let empty = folder.path().join("vacia.m4a");
    std::fs::write(&empty, b"").unwrap();
    let mut host = Host::start();
    assert_eq!(
        host.result("materialize", json!({"path": file, "timeoutSeconds": 5})),
        json!({"ready": true, "dataless": false, "size": 5})
    );
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
fn resumir_y_preguntar_no_tienen_motor_en_linux() {
    let mut host = Host::start();
    for method in ["summarize", "ask"] {
        let error = host.error(method, json!({"instructions": "i", "prompt": "p"}));
        assert_eq!(error["code"], "backend_unavailable", "{method}");
    }
}

#[test]
fn transcribir_sin_modelo_instalado_es_reintentable() {
    let mut host = Host::start();
    let audio = fixture("tono.wav");
    for (method, params) in [
        ("transcribe", json!({"audioPath": audio, "language": "es"})),
        ("diarizedVoices", json!({"audioPath": audio})),
        ("downloadModel", json!({})),
    ] {
        assert_eq!(
            host.error(method, params)["code"],
            "backend_unavailable",
            "{method}"
        );
    }
}

fn recorder(source: &Path) -> Host {
    Host::start_with(&[("ESCRIBA_AUDIO_SOURCE", source)])
}

fn wait(milliseconds: u64) {
    std::thread::sleep(std::time::Duration::from_millis(milliseconds));
}

fn seconds(value: &Value) -> f64 {
    value.as_f64().unwrap()
}

#[test]
fn graba_opus_en_ogg_desde_la_fuente_y_el_fichero_se_lee() {
    let folder = tempfile::tempdir().unwrap();
    let output = folder.path().join("capturas/Grabación.ogg");
    let mut host = recorder(&fixture("tono.wav"));
    let started = host.result("recordingStart", json!({"outputPath": output}));
    assert_eq!(started["audioPath"], output.to_str().unwrap());
    wait(700);
    let status = host.result("recordingStatus", json!({}));
    assert_eq!(status["active"], true);
    assert_eq!(status["paused"], false);
    assert_eq!(status["audioPath"], output.to_str().unwrap());
    assert!(seconds(&status["duration"]) > 0.3, "{status}");
    assert!(seconds(&status["level"]) > 0.3, "{status}");
    let stopped = host.result("recordingStop", json!({}));
    assert_eq!(stopped["audioPath"], output.to_str().unwrap());
    let duration = seconds(&stopped["duration"]);
    assert!((0.4..1.2).contains(&duration), "{duration}");
    let bytes = std::fs::read(&output).unwrap();
    assert_eq!(&bytes[..4], b"OggS");
    assert!(bytes.windows(8).any(|window| window == b"OpusHead"));
    let info = host.result("audioInfo", json!({"audioPath": output}));
    assert!(
        (seconds(&info["duration"]) - duration).abs() < 0.1,
        "{info} {duration}"
    );
    assert_eq!(host.result("recordingStatus", json!({}))["active"], false);
}

#[test]
fn en_pausa_no_avanza_y_al_reanudar_sigue() {
    let folder = tempfile::tempdir().unwrap();
    let output = folder.path().join("pausa.ogg");
    let mut host = recorder(&fixture("tono.wav"));
    host.result("recordingStart", json!({"outputPath": output}));
    wait(400);
    let paused = host.result("recordingPause", json!({}));
    assert_eq!(paused["audioPath"], output.to_str().unwrap());
    let at_pause = seconds(&paused["duration"]);
    wait(600);
    let status = host.result("recordingStatus", json!({}));
    assert_eq!(status["paused"], true);
    assert_eq!(status["level"], 0.0);
    assert!(
        seconds(&status["duration"]) - at_pause < 0.1,
        "{status} {at_pause}"
    );
    assert_eq!(
        host.error("recordingPause", json!({}))["code"],
        "recording_paused"
    );
    host.result("recordingResume", json!({}));
    assert_eq!(
        host.error("recordingResume", json!({}))["code"],
        "recording_active"
    );
    wait(400);
    let duration = seconds(&host.result("recordingStop", json!({}))["duration"]);
    assert!(
        (0.6..1.2).contains(&duration),
        "la pausa no cuenta: {duration}"
    );
}

#[test]
fn cancelar_borra_la_grabacion() {
    let folder = tempfile::tempdir().unwrap();
    let output = folder.path().join("descartada.ogg");
    let mut host = recorder(&fixture("tono.wav"));
    host.result("recordingStart", json!({"outputPath": output}));
    wait(200);
    host.result("recordingCancel", json!({}));
    assert!(!output.exists());
    assert_eq!(host.result("recordingStatus", json!({}))["active"], false);
}

#[test]
fn una_sola_grabacion_y_nunca_sobre_un_fichero_existente() {
    let folder = tempfile::tempdir().unwrap();
    let existing = folder.path().join("existe.ogg");
    std::fs::write(&existing, b"no tocar").unwrap();
    let mut host = recorder(&fixture("tono.wav"));
    assert_eq!(
        host.error("recordingStart", json!({"outputPath": existing}))["code"],
        "file_exists"
    );
    assert_eq!(std::fs::read(&existing).unwrap(), b"no tocar");
    let output = folder.path().join("nueva.ogg");
    host.result("recordingStart", json!({"outputPath": output}));
    let again = folder.path().join("otra.ogg");
    assert_eq!(
        host.error("recordingStart", json!({"outputPath": again}))["code"],
        "recording_active"
    );
    assert!(!again.exists());
    host.result("recordingStop", json!({}));
}

#[test]
fn sin_microfono_no_se_crea_ninguna_grabacion() {
    let folder = tempfile::tempdir().unwrap();
    let output = folder.path().join("nada.ogg");
    let mut host = recorder(Path::new("none"));
    let error = host.error("recordingStart", json!({"outputPath": output}));
    assert_eq!(error["code"], "recording_failed");
    assert!(
        error["message"].as_str().unwrap().contains("micrófono"),
        "{error}"
    );
    assert!(!output.exists());
    assert_eq!(host.result("recordingStatus", json!({}))["active"], false);
}

#[test]
fn cerrar_la_entrada_mientras_graba_termina_el_proceso() {
    let folder = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_EscribaNativeHost"))
        .env("ESCRIBA_AUDIO_SOURCE", fixture("tono.wav"))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let request = json!({"id": "a", "method": "recordingStart", "params": {"outputPath": folder.path().join("viva.ogg")}});
    writeln!(child.stdin.as_mut().unwrap(), "{request}").unwrap();
    wait(300);
    drop(child.stdin.take());
    let started = std::time::Instant::now();
    while child.try_wait().unwrap().is_none() {
        assert!(started.elapsed().as_secs() < 5, "el host sigue vivo");
        wait(50);
    }
}

#[test]
#[ignore = "Graba un segundo del micrófono real del equipo"]
fn graba_del_microfono_real() {
    let folder = tempfile::tempdir().unwrap();
    let output = folder.path().join("microfono.ogg");
    let mut host = Host::start();
    host.result("recordingStart", json!({"outputPath": output}));
    wait(1000);
    let duration = seconds(&host.result("recordingStop", json!({}))["duration"]);
    assert!(duration > 0.8, "{duration}");
    let info = host.result("audioInfo", json!({"audioPath": output}));
    assert!(
        (seconds(&info["duration"]) - duration).abs() < 0.1,
        "{info}"
    );
}

#[test]
fn sin_grabacion_activa_el_estado_lo_dice_y_parar_falla() {
    let mut host = Host::start();
    assert_eq!(
        host.result("recordingStatus", json!({})),
        json!({"active": false, "paused": false, "audioPath": null, "duration": 0, "level": 0})
    );
    for method in [
        "recordingStop",
        "recordingCancel",
        "recordingPause",
        "recordingResume",
    ] {
        assert_eq!(
            host.error(method, json!({}))["code"],
            "recording_inactive",
            "{method}"
        );
    }
}

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
    let mut child = Command::new(env!("CARGO_BIN_EXE_EscribaNativeHost"))
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
