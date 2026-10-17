#![cfg(target_os = "windows")]

mod support;
use serde_json::json;
use support::{fixture, Host};

#[test]
fn windows_usa_modelos_locales_y_no_incluye_llm() {
    let root = tempfile::tempdir().unwrap();
    let mut host = Host::start_with(&[("LOCALAPPDATA", root.path())]);
    let status = host.result("status", json!({}));
    assert_eq!(status["whisper"]["model"], "large-v3-turbo");
    assert_eq!(
        status["whisper"]["modelsPath"],
        root.path().join("escriba/models").to_str().unwrap()
    );
    assert_eq!(status["llm"]["available"], false);
    assert_eq!(
        host.error("transcribe", json!({"audioPath": fixture("tono.wav")}))["code"],
        "backend_unavailable"
    );
}

#[test]
fn windows_graba_pausa_y_recupera_audio_sin_microfono_real() {
    let root = tempfile::tempdir().unwrap();
    let output = root.path().join("Grabación con espacios.ogg");
    let mut host = Host::start_with(&[("ESCRIBA_AUDIO_SOURCE", &fixture("tono.wav"))]);
    host.result("recordingStart", json!({"outputPath": output}));
    support::wait(250);
    host.result("recordingPause", json!({}));
    host.result("recordingResume", json!({}));
    support::wait(250);
    host.result("recordingStop", json!({}));
    let info = host.result("audioInfo", json!({"audioPath": output}));
    assert!(info["duration"].as_f64().unwrap() > 0.1);
}
