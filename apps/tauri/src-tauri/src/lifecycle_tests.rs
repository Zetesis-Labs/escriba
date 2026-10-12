use super::*;
use std::sync::mpsc::RecvTimeoutError;

fn within<T: Send + 'static>(seconds: u64, body: impl FnOnce() -> T + Send + 'static) -> T {
    let (done, finished) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = done.send(body());
    });
    match finished.recv_timeout(Duration::from_secs(seconds)) {
        Ok(value) => value,
        Err(RecvTimeoutError::Timeout) => panic!("La app se quedó colgada"),
        Err(RecvTimeoutError::Disconnected) => panic!("La prueba falló fuera del runtime"),
    }
}

#[test]
fn salir_de_la_app_guarda_lo_encolado_sin_colgarse() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("library");
    let lines = within(30, move || {
        let (library, jobs) = tauri::async_runtime::block_on(open_library(root.clone())).unwrap();
        for index in 0..20 {
            library
                .log(json!({"level":"error","message":format!("Antes de salir {index}")}))
                .unwrap();
        }
        close_library(&library);
        assert!(library
            .log(json!({"level":"error","message":"Después de salir"}))
            .is_err());
        drop(jobs);
        drop(library);
        let (library, _jobs) = tauri::async_runtime::block_on(open_library(root)).unwrap();
        tauri::async_runtime::block_on(library.log_list(json!({"limit":100}))).unwrap()
    });
    let saved: Vec<&str> = lines
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|line| line["message"].as_str())
        .collect();
    assert_eq!(
        saved
            .iter()
            .filter(|message| message.starts_with("Antes de salir"))
            .count(),
        20
    );
    assert!(!saved.contains(&"Después de salir"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn un_audio_de_una_carpeta_vigilada_se_incorpora_una_sola_vez() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("library");
    let (library, _jobs) = open_library(root.clone()).await.unwrap();
    let watched = temp.path().join("vigilada");
    std::fs::create_dir(&watched).unwrap();
    let audio = watched.join("nota.wav");
    std::fs::write(&audio, b"audio sintetico vigilado").unwrap();
    let folder = watcher::Folder {
        id: "vigilada".into(),
        path: watched.canonicalize().unwrap(),
        enabled: true,
        style: watcher::Style::Any,
    };
    let folders = std::slice::from_ref(&folder);
    let mut scanner = watcher::Scanner::new();
    let now = SystemTime::now() + Duration::from_secs(16);
    assert!(scanner.scan(folders, now).ready.is_empty());
    let candidate = scanner.scan(folders, now).ready.remove(0);

    let first = incorporate(&library, &root, &candidate).await.unwrap();
    let again = incorporate(&library, &root, &candidate).await.unwrap();
    scanner.acknowledge(&candidate);

    assert_eq!(first["id"], again["id"]);
    assert!(scanner.scan(folders, now).ready.is_empty());
    let index = library.index();
    assert_eq!(index.recordings.len(), 1);
    let note = serde_json::to_value(&index.recordings[0]).unwrap();
    assert_eq!(note["sourceKey"], json!(candidate.source_key));
    assert_eq!(note["status"], "pending");
    assert_eq!(
        std::fs::read(&audio).unwrap(),
        b"audio sintetico vigilado",
        "Incorporar no puede tocar el original"
    );
    let detail = library
        .recording(text(&first, "id").unwrap().to_owned())
        .await
        .unwrap();
    assert_eq!(detail["sourceKey"], json!(candidate.source_key));
}
