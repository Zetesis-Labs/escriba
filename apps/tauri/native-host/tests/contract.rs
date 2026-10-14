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
    progress: Vec<f64>,
    _data: Option<tempfile::TempDir>,
}

impl Host {
    fn start() -> Self {
        Self::start_with(&[])
    }

    /// Without an explicit XDG_DATA_HOME the host gets a temporary one, so no
    /// test reads or writes the real models folder.
    fn start_with(env: &[(&str, &Path)]) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_EscribaNativeHost"));
        let data = (!env.iter().any(|(key, _)| *key == "XDG_DATA_HOME"))
            .then(|| tempfile::tempdir().unwrap());
        if let Some(data) = &data {
            command.env("XDG_DATA_HOME", data.path());
        }
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
            progress: Vec::new(),
            _data: data,
        }
    }

    fn line(&mut self, line: &str) -> Value {
        writeln!(self.input, "{line}").unwrap();
        self.input.flush().unwrap();
        self.reply()
    }

    /// The final reply, keeping the progress lines that come before it.
    fn reply(&mut self) -> Value {
        loop {
            let mut line = String::new();
            self.output.read_line(&mut line).unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            match reply.get("progress") {
                Some(progress) => self.progress.push(progress["fraction"].as_f64().unwrap()),
                None => return reply,
            }
        }
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
    let data = tempfile::tempdir().unwrap();
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    let audio = fixture("tono.wav");
    for (method, params) in [
        ("transcribe", json!({"audioPath": audio, "language": "es"})),
        ("diarizedVoices", json!({"audioPath": audio})),
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

/// Serves `size` synthetic bytes once per connection; `cut` closes the body early.
fn model_server(size: usize, cut: Option<usize>) -> (String, std::thread::JoinHandle<()>) {
    use std::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let thread = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0u8; 2048];
        let read = std::io::Read::read(&mut stream, &mut request).unwrap();
        let first = String::from_utf8_lossy(&request[..read])
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        assert!(first.starts_with("GET /ggml-tiny.bin "), "{first}");
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let body = vec![7u8; cut.unwrap_or(size)];
        for chunk in body.chunks(4096) {
            stream.write_all(chunk).unwrap();
        }
    });
    (base, thread)
}

#[test]
fn descargar_un_modelo_informa_del_progreso_y_lo_deja_instalado() {
    let data = tempfile::tempdir().unwrap();
    let (base, server) = model_server(300_000, None);
    let mut host = Host::start_with(&[
        ("XDG_DATA_HOME", data.path()),
        ("ESCRIBA_MODELS_URL", Path::new(&base)),
    ]);
    assert_eq!(
        host.result("status", json!({"model": "tiny"}))["whisper"]["available"],
        false
    );
    let downloaded = host.result("downloadModel", json!({"model": "tiny"}));
    server.join().unwrap();
    let file = data.path().join("escriba/models/ggml-tiny.bin");
    assert_eq!(downloaded["model"], "tiny");
    assert_eq!(downloaded["path"], file.to_str().unwrap());
    assert_eq!(std::fs::metadata(&file).unwrap().len(), 300_000);
    assert!(!host.progress.is_empty());
    assert!(
        host.progress.windows(2).all(|pair| pair[0] <= pair[1]),
        "{:?}",
        host.progress
    );
    assert!(host
        .progress
        .iter()
        .all(|fraction| (0.0..=1.0).contains(fraction)));
    assert_eq!(
        host.result("status", json!({"model": "tiny"}))["whisper"]["available"],
        true
    );
}

#[test]
fn una_descarga_cortada_no_deja_un_modelo_a_medias() {
    let data = tempfile::tempdir().unwrap();
    let (base, server) = model_server(300_000, Some(100_000));
    let mut host = Host::start_with(&[
        ("XDG_DATA_HOME", data.path()),
        ("ESCRIBA_MODELS_URL", Path::new(&base)),
    ]);
    let error = host.error("downloadModel", json!({"model": "tiny"}));
    server.join().unwrap();
    assert_eq!(error["code"], "download_failed", "{error}");
    let models = data.path().join("escriba/models");
    let left: Vec<_> = std::fs::read_dir(&models)
        .map(|entries| entries.flatten().map(|entry| entry.file_name()).collect())
        .unwrap_or_default();
    assert!(left.is_empty(), "{left:?}");
    assert_eq!(
        host.result("status", json!({"model": "tiny"}))["whisper"]["available"],
        false
    );
}

#[test]
fn el_modelo_del_mac_guardado_en_la_biblioteca_se_toma_como_el_de_serie() {
    let mut host = Host::start();
    let status = host.result(
        "status",
        json!({"model": "openai_whisper-large-v3-v20240930"}),
    );
    assert_eq!(status["whisper"]["model"], "large-v3-turbo");
}

#[test]
fn detectar_hablantes_aun_no_esta_y_lo_dice() {
    let data = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(data.path().join("escriba/models")).unwrap();
    std::fs::write(
        data.path().join("escriba/models/ggml-tiny.bin"),
        b"modelo falso",
    )
    .unwrap();
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    let error = host.error(
        "transcribe",
        json!({"audioPath": fixture("tono.wav"), "model": "tiny", "diarize": true}),
    );
    assert_eq!(error["code"], "transcription_failed", "{error}");
}

fn speech(folder: &Path) -> PathBuf {
    let path = folder.join("voz.wav");
    let status = Command::new("espeak-ng")
        .args(["-v", "es", "-s", "150", "-w"])
        .arg(&path)
        .arg("Hola, esta es una prueba de transcripción de Escriba. Mañana revisamos el diseño.")
        .status()
        .unwrap();
    assert!(status.success());
    path
}

#[test]
#[ignore = "Descarga el modelo tiny de whisper.cpp (75 MB) y transcribe voz sintética"]
fn transcribe_voz_sintetica_en_wav_y_en_la_grabacion_opus() {
    let data = tempfile::tempdir().unwrap();
    let folder = tempfile::tempdir().unwrap();
    let voice = speech(folder.path());
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    host.result("downloadModel", json!({"model": "tiny"}));
    let spanish = host.result(
        "transcribe",
        json!({"audioPath": voice, "model": "tiny", "language": "es"}),
    );
    assert_eq!(spanish["language"], "es");
    let text = spanish["text"].as_str().unwrap().to_lowercase();
    assert!(
        text.contains("prueba") || text.contains("escriba"),
        "{text}"
    );
    let segments = spanish["segments"].as_array().unwrap();
    assert!(!segments.is_empty());
    for segment in segments {
        assert!(seconds(&segment["end"]) >= seconds(&segment["start"]));
        assert!(segment["speaker"].is_null());
        assert!(
            !segment["words"].as_array().unwrap().is_empty(),
            "{segment}"
        );
    }
    assert_eq!(spanish["voices"], json!([]));
    assert!(seconds(&spanish["duration"]) > 2.0);
    let detected = host.result(
        "transcribe",
        json!({"audioPath": voice, "model": "tiny", "language": null}),
    );
    assert_eq!(detected["language"], "auto");
    let recording = folder.path().join("grabada.ogg");
    let mut recorder = recorder(&voice);
    recorder.result("recordingStart", json!({"outputPath": recording}));
    wait(6000);
    recorder.result("recordingStop", json!({}));
    let recorded = host.result(
        "transcribe",
        json!({"audioPath": recording, "model": "tiny", "language": "es"}),
    );
    let text = recorded["text"].as_str().unwrap().to_lowercase();
    assert!(
        text.contains("prueba") || text.contains("escriba"),
        "{text}"
    );
}

fn install(data: &Path, model: &str, bytes: usize) {
    let folder = data.join("escriba/models");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join(format!("ggml-{model}.bin")), vec![1u8; bytes]).unwrap();
}

#[test]
fn el_catalogo_dice_que_modelos_hay_cuanto_ocupan_y_cuales_estan_instalados() {
    let data = tempfile::tempdir().unwrap();
    install(data.path(), "base", 1234);
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    let catalog = host.result("models", json!({}));
    assert_eq!(catalog["default"], "large-v3-turbo");
    let models = catalog["models"].as_array().unwrap();
    let names: Vec<_> = models
        .iter()
        .map(|model| model["model"].as_str().unwrap())
        .collect();
    assert!(
        names.contains(&"large-v3-turbo") && names.contains(&"tiny") && names.contains(&"base"),
        "{names:?}"
    );
    let mut unique = names.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), names.len());
    for model in models {
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
    }
    let base = models
        .iter()
        .find(|model| model["model"] == "base")
        .unwrap();
    assert_eq!(base["installed"], true);
    assert_eq!(base["bytes"], 1234);
    assert!(models
        .iter()
        .filter(|model| model["model"] != "base")
        .all(|model| model["installed"] == false));
}

#[test]
fn borrar_un_modelo_borra_solo_ese() {
    let data = tempfile::tempdir().unwrap();
    install(data.path(), "base", 10);
    install(data.path(), "tiny", 10);
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    assert_eq!(
        host.result("deleteModel", json!({"model": "base"})),
        json!({"model": "base"})
    );
    assert_eq!(
        host.result("status", json!({"model": "base"}))["whisper"]["available"],
        false
    );
    assert_eq!(
        host.result("status", json!({"model": "tiny"}))["whisper"]["available"],
        true
    );
    assert_eq!(
        host.error("deleteModel", json!({"model": "base"}))["code"],
        "model_missing"
    );
    assert_eq!(
        host.error("deleteModel", json!({"model": "../tiny"}))["code"],
        "invalid_params"
    );
}
