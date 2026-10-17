//! What the Rust host does on Linux beyond the common contract of
//! tests/contract.rs: Opus recording, whisper.cpp models and no LLM.

#![cfg(any(target_os = "linux", target_os = "windows"))]

mod support;

use serde_json::json;
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
use support::{fixture, seconds, wait, Host};

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
fn la_duracion_se_lee_tambien_del_ogg() {
    let mut host = Host::start();
    let info = host.result("audioInfo", json!({"audioPath": fixture("tono.ogg")}));
    let duration = seconds(&info["duration"]);
    assert!((0.95..1.1).contains(&duration), "{duration}");
}

#[test]
fn audio_ilegible_falla_como_audio_invalido() {
    let folder = tempfile::tempdir().unwrap();
    let text = folder.path().join("nota.m4a");
    std::fs::write(&text, "esto no es audio").unwrap();
    let mut host = Host::start();
    let invalid = host.error("audioInfo", json!({"audioPath": text}));
    assert_eq!(invalid["code"], "invalid_audio");
}

#[test]
fn sin_icloud_ningun_archivo_es_dataless() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("nota.ogg");
    std::fs::write(&file, b"audio sintetico").unwrap();
    let mut host = Host::start();
    let status = host.result("fileStatus", json!({"path": file}));
    assert_eq!(status["flags"], 0);
    assert_eq!(status["dataless"], false);
    let modified = status["modifiedAt"].as_str().unwrap();
    assert!(modified.ends_with('Z'), "{modified}");
}

#[test]
fn materializar_esta_listo_al_momento_sin_icloud() {
    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("nota.m4a");
    std::fs::write(&file, b"audio").unwrap();
    let mut host = Host::start();
    assert_eq!(
        host.result("materialize", json!({"path": file, "timeoutSeconds": 5})),
        json!({"ready": true, "dataless": false, "size": 5})
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
fn sin_grabacion_activa_no_hay_pausa_ni_reanudacion() {
    let mut host = Host::start();
    assert_eq!(
        host.result("recordingStatus", json!({})),
        json!({"active": false, "paused": false, "audioPath": null, "duration": 0, "level": 0})
    );
    for method in ["recordingPause", "recordingResume"] {
        assert_eq!(
            host.error(method, json!({}))["code"],
            "recording_inactive",
            "{method}"
        );
    }
}

const SEGMENTATION: &str = "pyannote-segmentation-3-0.onnx";
const EMBEDDING: &str = "nemo_en_titanet_small.onnx";

/// Serves each `(path, size, cut)` once, in any order, and returns the paths
/// it was asked for; `cut` closes the body early.
fn files_server(
    files: &[(&str, usize, Option<usize>)],
) -> (String, std::thread::JoinHandle<Vec<String>>) {
    use std::net::TcpListener;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let files: Vec<(String, usize, Option<usize>)> = files
        .iter()
        .map(|(path, size, cut)| (format!("/{path}"), *size, *cut))
        .collect();
    let thread = std::thread::spawn(move || {
        let mut asked = Vec::new();
        for _ in 0..files.len() {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 2048];
            let read = std::io::Read::read(&mut stream, &mut request).unwrap();
            let first = String::from_utf8_lossy(&request[..read])
                .lines()
                .next()
                .unwrap_or_default()
                .to_owned();
            let path = first.split(' ').nth(1).unwrap_or_default().to_owned();
            let (_, size, cut) = files
                .iter()
                .find(|(file, ..)| *file == path)
                .unwrap_or_else(|| panic!("petición inesperada: {first}"));
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
            let body = vec![7u8; cut.unwrap_or(*size)];
            for chunk in body.chunks(4096) {
                stream.write_all(chunk).unwrap();
            }
            asked.push(path);
            if cut.is_some() {
                break;
            }
        }
        asked
    });
    (base, thread)
}

fn install_speakers(data: &Path) {
    let folder = data.join("escriba/models/speakers");
    std::fs::create_dir_all(&folder).unwrap();
    for name in [SEGMENTATION, EMBEDDING] {
        std::fs::write(folder.join(name), b"modelo falso").unwrap();
    }
}

fn downloader(data: &Path, base: &str) -> Host {
    Host::start_with(&[
        ("XDG_DATA_HOME", data),
        ("ESCRIBA_MODELS_URL", Path::new(base)),
        ("ESCRIBA_SPEAKER_MODELS_URL", Path::new(base)),
    ])
}

#[test]
fn descargar_un_modelo_informa_del_progreso_y_lo_deja_instalado() {
    let data = tempfile::tempdir().unwrap();
    install_speakers(data.path());
    let (base, server) = files_server(&[("ggml-tiny.bin", 300_000, None)]);
    let mut host = downloader(data.path(), &base);
    assert_eq!(
        host.result("status", json!({"model": "tiny"}))["whisper"]["available"],
        false
    );
    let downloaded = host.result("downloadModel", json!({"model": "tiny"}));
    server.join().unwrap();
    let file = data.path().join("escriba/models").join("ggml-tiny.bin");
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
    install_speakers(data.path());
    let (base, server) = files_server(&[("ggml-tiny.bin", 300_000, Some(100_000))]);
    let mut host = downloader(data.path(), &base);
    let error = host.error("downloadModel", json!({"model": "tiny"}));
    server.join().unwrap();
    assert_eq!(error["code"], "download_failed", "{error}");
    let models = data.path().join("escriba/models");
    let left: Vec<_> = std::fs::read_dir(&models)
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name())
                .filter(|name| name != "speakers")
                .collect()
        })
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
fn descargar_whisper_baja_tambien_los_modelos_de_hablantes() {
    let data = tempfile::tempdir().unwrap();
    let (base, server) = files_server(&[
        ("ggml-tiny.bin", 300_000, None),
        (SEGMENTATION, 50_000, None),
        (EMBEDDING, 80_000, None),
    ]);
    let mut host = downloader(data.path(), &base);
    host.result("downloadModel", json!({"model": "tiny"}));
    let mut asked = server.join().unwrap();
    asked.sort();
    let mut expected = vec![
        "/ggml-tiny.bin".to_owned(),
        format!("/{SEGMENTATION}"),
        format!("/{EMBEDDING}"),
    ];
    expected.sort();
    assert_eq!(asked, expected);
    let speakers = data.path().join("escriba/models/speakers");
    assert_eq!(
        std::fs::metadata(speakers.join(SEGMENTATION))
            .unwrap()
            .len(),
        50_000
    );
    assert_eq!(
        std::fs::metadata(speakers.join(EMBEDDING)).unwrap().len(),
        80_000
    );
    assert!(
        host.progress.windows(2).all(|pair| pair[0] <= pair[1]),
        "{:?}",
        host.progress
    );
    assert!(host
        .progress
        .iter()
        .all(|fraction| (0.0..=1.0).contains(fraction)));
}

#[test]
fn con_whisper_ya_descargado_solo_se_bajan_los_de_hablantes() {
    let data = tempfile::tempdir().unwrap();
    install(data.path(), "tiny", 10);
    let (base, server) = files_server(&[(SEGMENTATION, 50_000, None), (EMBEDDING, 80_000, None)]);
    let mut host = downloader(data.path(), &base);
    host.result("downloadModel", json!({"model": "tiny"}));
    assert_eq!(server.join().unwrap().len(), 2);
    assert_eq!(
        std::fs::metadata(data.path().join("escriba/models/ggml-tiny.bin"))
            .unwrap()
            .len(),
        10
    );
}

#[test]
fn una_descarga_de_hablantes_cortada_no_deja_modelos_a_medias() {
    let data = tempfile::tempdir().unwrap();
    install(data.path(), "tiny", 10);
    let (base, server) = files_server(&[
        (SEGMENTATION, 50_000, Some(1_000)),
        (EMBEDDING, 80_000, Some(1_000)),
    ]);
    let mut host = downloader(data.path(), &base);
    let error = host.error("downloadModel", json!({"model": "tiny"}));
    server.join().unwrap();
    assert_eq!(error["code"], "download_failed", "{error}");
    let speakers = data.path().join("escriba/models/speakers");
    let left: Vec<_> = std::fs::read_dir(&speakers)
        .map(|entries| entries.flatten().map(|entry| entry.file_name()).collect())
        .unwrap_or_default();
    assert!(left.is_empty(), "{left:?}");
}

#[test]
fn detectar_hablantes_sin_sus_modelos_espera_como_no_disponible() {
    let data = tempfile::tempdir().unwrap();
    install(data.path(), "tiny", 10);
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    for (method, params) in [
        (
            "transcribe",
            json!({"audioPath": fixture("tono.wav"), "model": "tiny", "diarize": true}),
        ),
        ("diarizedVoices", json!({"audioPath": fixture("tono.wav")})),
    ] {
        let error = host.error(method, params);
        assert_eq!(error["code"], "backend_unavailable", "{method}: {error}");
        assert!(
            error["message"].as_str().unwrap().contains("hablantes"),
            "{error}"
        );
    }
}

#[cfg(unix)]
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

const VOICE_MODEL: &str = "sherpa-onnx/nemo-titanet-small";

#[cfg(unix)]
fn say(folder: &Path, name: &str, voice: &str, text: &str) -> PathBuf {
    let path = folder.join(format!("{name}.wav"));
    let status = Command::new("espeak-ng")
        .args(["-v", voice, "-s", "150", "-w"])
        .arg(&path)
        .arg(text)
        .status()
        .unwrap();
    assert!(status.success());
    path
}

/// Joins espeak-ng WAVs, which share format and a 44-byte header.
fn join_wavs(path: &Path, parts: &[PathBuf]) -> PathBuf {
    let mut header = Vec::new();
    let mut data = Vec::new();
    for part in parts {
        let bytes = std::fs::read(part).unwrap();
        header = bytes[..44].to_vec();
        data.extend_from_slice(&bytes[44..]);
    }
    header[4..8].copy_from_slice(&(36 + data.len() as u32).to_le_bytes());
    header[40..44].copy_from_slice(&(data.len() as u32).to_le_bytes());
    std::fs::write(path, [header, data].concat()).unwrap();
    path.to_path_buf()
}

fn cosine_distance(a: &[f64], b: &[f64]) -> f64 {
    let dot: f64 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let norm = |v: &[f64]| v.iter().map(|x| x * x).sum::<f64>().sqrt();
    1.0 - dot / (norm(a) * norm(b))
}

fn embedding(voice: &serde_json::Value) -> Vec<f64> {
    voice["embedding"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_f64().unwrap())
        .collect()
}

fn speaker_at(transcript: &serde_json::Value, second: f64) -> String {
    transcript["segments"]
        .as_array()
        .unwrap()
        .iter()
        .find(|segment| seconds(&segment["start"]) <= second && second <= seconds(&segment["end"]))
        .and_then(|segment| segment["speaker"].as_str())
        .unwrap_or_else(|| panic!("nadie habla en {second} s: {transcript}"))
        .to_owned()
}

const FIRST: &str = "Buenos días a todos. Hoy repasamos el presupuesto del trimestre y las contrataciones previstas para el equipo de diseño.";
const SECOND: &str = "Gracias. Antes de empezar quiero comentar que el proveedor ha retrasado la entrega de los equipos hasta finales de mes.";
const THIRD: &str = "De acuerdo, entonces movemos la presentación al lunes y avisamos al cliente esta misma tarde por correo.";

#[test]
#[ignore = "Descarga whisper tiny y los modelos de hablantes (unos 125 MB) y separa dos voces sintéticas"]
fn separa_dos_voces_sinteticas_y_sus_huellas_las_distinguen() {
    let data = tempfile::tempdir().unwrap();
    let folder = tempfile::tempdir().unwrap();
    let first = say(folder.path(), "a1", "es", FIRST);
    let second = say(folder.path(), "b1", "es+f3", SECOND);
    let third = say(folder.path(), "a2", "es", THIRD);
    let dialog = join_wavs(
        &folder.path().join("dialogo.wav"),
        &[first.clone(), second.clone(), third.clone()],
    );
    let length = |path: &Path| (std::fs::metadata(path).unwrap().len() - 44) as f64 / 44_100.0;
    let (first_end, second_end) = (length(&first), length(&first) + length(&second));
    let mut host = Host::start_with(&[("XDG_DATA_HOME", data.path())]);
    host.result("downloadModel", json!({"model": "tiny"}));

    let transcript = host.result(
        "transcribe",
        json!({"audioPath": dialog, "model": "tiny", "language": "es", "diarize": true, "speakers": 2}),
    );
    let a = speaker_at(&transcript, first_end / 2.0);
    let b = speaker_at(&transcript, (first_end + second_end) / 2.0);
    assert_ne!(a, b, "{transcript}");
    assert_eq!(speaker_at(&transcript, second_end + 2.0), a, "{transcript}");
    let voices = transcript["voices"].as_array().unwrap();
    assert_eq!(voices.len(), 2, "{transcript}");
    for voice in voices {
        assert_eq!(voice["model"], VOICE_MODEL);
        assert!(embedding(voice).len() >= 128);
    }

    let heard = host.result("diarizedVoices", json!({"audioPath": dialog}));
    assert!(!heard["spans"].as_array().unwrap().is_empty(), "{heard}");
    let alone = host.result("diarizedVoices", json!({"audioPath": third}));
    assert_eq!(alone["voices"].as_array().unwrap().len(), 1, "{alone}");
    let voice = |name: &str| {
        voices
            .iter()
            .find(|voice| voice["speaker"] == name)
            .map(embedding)
            .unwrap()
    };
    let own = embedding(&alone["voices"][0]);
    let same = cosine_distance(&own, &voice(&a));
    let other = cosine_distance(&own, &voice(&b));
    eprintln!(
        "distancias: misma voz {same:.3}, otra voz {other:.3}, hablantes sin fijar {}",
        heard["voices"].as_array().unwrap().len()
    );
    assert!(same < other, "misma {same} otra {other}");
}

#[cfg(windows)]
fn speech(folder: &Path) -> PathBuf {
    support::synthesize(
        folder,
        "voz",
        false,
        "Hola, esta es una prueba de transcripción de Escriba. Mañana revisamos el diseño.",
    )
}
#[cfg(windows)]
fn say(folder: &Path, name: &str, voice: &str, text: &str) -> PathBuf {
    support::synthesize(folder, name, voice.contains("f3"), text)
}
