use super::Library;
use crate::jobs::{JobState, Lane, Queue};
use crate::store::Store;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::task::JoinSet;

async fn open(root: &Path) -> Library {
    Library::new(Store::open(root.to_owned()).await.unwrap())
        .await
        .unwrap()
}

async fn reopen(root: &Path) -> Store {
    for _ in 0..400 {
        match Store::open(root.to_owned()).await {
            Ok(store) => return store,
            Err(error) if error.contains("ya está abierta") => {
                tokio::time::sleep(Duration::from_millis(25)).await
            }
            Err(error) => panic!("{error}"),
        }
    }
    panic!("La biblioteca no se liberó al cerrarla");
}

async fn notes(library: &Library, dir: &Path, count: usize) -> Vec<String> {
    let mut ids = Vec::new();
    for index in 0..count {
        let audio = dir.join(format!("sintetica-{index}.wav"));
        std::fs::write(&audio, format!("audio sintético {index}")).unwrap();
        ids.push(
            library.import(&audio).await.unwrap()["id"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
    }
    ids
}

async fn retitle(library: &Library, id: &str, title: &str) -> Result<Value, String> {
    library
        .mutate("recording_update".into(), json!({"id":id,"title":title}))
        .await
}

fn title(library: &Library, id: &str) -> Value {
    let index = library.index();
    let recording = index.recordings.iter().find(|r| r.id == id).unwrap();
    serde_json::to_value(recording).unwrap()["title"].clone()
}

fn shape(library: &Library) -> Vec<Value> {
    serde_json::to_value(&library.index().recordings)
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|recording| {
            let versions: Vec<Value> = recording["versions"]
                .as_array()
                .map(|versions| versions.iter().map(|v| v["id"].clone()).collect())
                .unwrap_or_default();
            json!({"id":recording["id"],"title":recording["title"],"versions":versions})
        })
        .collect()
}

fn writer(library: &Library, id: &str) -> tokio::task::JoinHandle<Result<Value, String>> {
    let library = library.clone();
    let id = id.to_owned();
    tokio::spawn(async move { retitle(&library, &id, "Escrita en curso").await })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn las_escrituras_no_se_solapan() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("library");
    let library = open(&root).await;
    let ids = notes(&library, temp.path(), 6).await;
    let mut versions = JoinSet::new();
    let mut titles = JoinSet::new();
    for index in 0..20 {
        let saving = library.clone();
        let id = ids[0].clone();
        versions.spawn(async move {
            saving
                .mutate(
                    "version_save".into(),
                    json!({"recordingId":id,"transcript":{"text":format!("versión {index}"),"segments":[]}}),
                )
                .await
                .map(|version| version["id"].clone())
        });
        let renaming = library.clone();
        let id = ids[1 + index % 5].clone();
        titles.spawn(async move { retitle(&renaming, &id, &format!("Título {index}")).await });
    }
    let mut saved = HashSet::new();
    while let Some(version) = versions.join_next().await {
        saved.insert(version.unwrap().unwrap());
    }
    while let Some(title) = titles.join_next().await {
        title.unwrap().unwrap();
    }
    assert_eq!(saved.len(), 20);
    let stored: HashSet<Value> = library.recording(ids[0].clone()).await.unwrap()["versions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|version| version["id"].clone())
        .collect();
    assert_eq!(stored, saved);
    let published = shape(&library);
    drop(library);
    assert_eq!(
        shape(&Library::new(reopen(&root).await).await.unwrap()),
        published
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn leer_no_espera_a_un_commit() {
    let temp = tempfile::tempdir().unwrap();
    let library = open(&temp.path().join("library")).await;
    let ids = notes(&library, temp.path(), 2).await;
    let mut stopped = library.stop_next_write();
    let writing = writer(&library, &ids[1]);
    stopped.parked().await;
    let started = Instant::now();
    assert!(library.index().recordings.len() == 2);
    assert!(started.elapsed() < Duration::from_millis(100));
    let detail = tokio::time::timeout(
        Duration::from_millis(100),
        library.recording(ids[0].clone()),
    )
    .await;
    assert!(
        detail.is_ok(),
        "El detalle de una nota esperó a que terminara la escritura de otra"
    );
    drop(stopped);
    writing.await.unwrap().unwrap();
}

#[test]
fn ningun_hilo_de_tokio_se_bloquea() {
    let (done, finished) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let temp = tempfile::tempdir().unwrap();
            let library = open(&temp.path().join("library")).await;
            let ids = notes(&library, temp.path(), 1).await;
            let graph = crate::knowledge::Knowledge::open(&temp.path().join("knowledge.rocksdb"))
                .await
                .unwrap();
            let mut stopped = library.stop_next_write();
            let writing = writer(&library, &ids[0]);
            stopped.parked().await;
            let reading = {
                let library = library.clone();
                let id = ids[0].clone();
                tokio::spawn(async move { library.recording(id).await })
            };
            tokio::time::sleep(Duration::from_millis(10)).await;
            graph.list().await.unwrap();
            drop(stopped);
            writing.await.unwrap().unwrap();
            reading.await.unwrap().unwrap();
        });
        let _ = done.send(());
    });
    match finished.recv_timeout(Duration::from_secs(20)) {
        Ok(()) => {}
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            panic!("El único hilo de tokio quedó bloqueado esperando a la biblioteca")
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            panic!("La prueba falló dentro del runtime")
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lees_lo_que_escribes_y_en_orden() {
    let temp = tempfile::tempdir().unwrap();
    let library = open(&temp.path().join("library")).await;
    let ids = notes(&library, temp.path(), 4).await;
    let stop = Arc::new(AtomicBool::new(false));
    let mut noise = JoinSet::new();
    for id in &ids[1..] {
        let id = id.clone();
        let library = library.clone();
        let stop = stop.clone();
        noise.spawn(async move {
            let mut round = 0;
            while !stop.load(Ordering::SeqCst) {
                retitle(&library, &id, &format!("Ruido {round}"))
                    .await
                    .unwrap();
                round += 1;
            }
        });
    }
    for index in 0..50 {
        let expected = json!(format!("Orden {index}"));
        retitle(&library, &ids[0], expected.as_str().unwrap())
            .await
            .unwrap();
        assert_eq!(title(&library, &ids[0]), expected);
        assert_eq!(
            library.recording(ids[0].clone()).await.unwrap()["title"],
            expected
        );
    }
    stop.store(true, Ordering::SeqCst);
    while let Some(round) = noise.join_next().await {
        round.unwrap();
    }
}

#[tokio::test]
async fn un_error_no_inutiliza_la_biblioteca() {
    let temp = tempfile::tempdir().unwrap();
    let library = open(&temp.path().join("library")).await;
    let ids = notes(&library, temp.path(), 1).await;
    assert!(retitle(&library, "no-existe", "Sin nota").await.is_err());
    retitle(&library, &ids[0], "Tras el error").await.unwrap();
    library.panic_next_write();
    assert!(retitle(&library, &ids[0], "Durante el pánico")
        .await
        .is_err());
    retitle(&library, &ids[0], "Tras el pánico")
        .await
        .expect("La biblioteca quedó inutilizada tras un pánico");
    assert_eq!(title(&library, &ids[0]), json!("Tras el pánico"));
}

#[derive(Default)]
struct Ledger {
    claimed: HashSet<String>,
    running: HashSet<String>,
    finished: usize,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn la_cola_no_entrega_un_trabajo_dos_veces() {
    let temp = tempfile::tempdir().unwrap();
    let library = open(&temp.path().join("library")).await;
    let ids = notes(&library, temp.path(), 30).await;
    let queue = Arc::new(Queue::new(library.clone()).await.unwrap());
    for (index, id) in ids.iter().enumerate() {
        if index % 2 == 0 {
            queue
                .enqueue("processRecording", json!({"recordingId":id}))
                .await
                .unwrap();
        } else {
            queue
                .enqueue(
                    "publishRecording",
                    json!({"recordingId":id,"destinationId":"d"}),
                )
                .await
                .unwrap();
        }
    }
    let expected = 45;
    let ledger = Arc::new(Mutex::new(Ledger::default()));
    let mut claimers = JoinSet::new();
    for lane in [
        Lane::Inference,
        Lane::Inference,
        Lane::Io,
        Lane::Io,
        Lane::Io,
        Lane::Io,
    ] {
        let queue = queue.clone();
        let ledger = ledger.clone();
        claimers.spawn(async move {
            while ledger.lock().unwrap().finished < expected {
                let Some(job) = queue.claim(lane).await.unwrap() else {
                    tokio::time::sleep(Duration::from_millis(1)).await;
                    continue;
                };
                let id = job["id"].as_str().unwrap().to_owned();
                let note = job["recordingId"].as_str().unwrap().to_owned();
                {
                    let mut ledger = ledger.lock().unwrap();
                    assert!(
                        ledger.claimed.insert(id.clone()),
                        "La cola entregó dos veces el mismo trabajo"
                    );
                    assert!(
                        ledger.running.insert(note.clone()),
                        "La cola entregó dos trabajos de la misma nota a la vez"
                    );
                }
                tokio::task::yield_now().await;
                ledger.lock().unwrap().running.remove(&note);
                assert!(queue.finish(&id, Ok(json!({}))).await.unwrap());
                if job["operation"] == "processRecording" {
                    queue
                        .enqueue(
                            "publishRecording",
                            json!({"recordingId":note,"destinationId":"d"}),
                        )
                        .await
                        .unwrap();
                }
                ledger.lock().unwrap().finished += 1;
            }
        });
    }
    tokio::time::timeout(Duration::from_secs(60), async {
        while let Some(claimer) = claimers.join_next().await {
            claimer.unwrap();
        }
    })
    .await
    .expect("La cola dejó de entregar trabajos");
    assert_eq!(ledger.lock().unwrap().claimed.len(), expected);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancelar_y_terminar_a_la_vez() {
    let temp = tempfile::tempdir().unwrap();
    let library = open(&temp.path().join("library")).await;
    let ids = notes(&library, temp.path(), 20).await;
    let queue = Queue::new(library.clone()).await.unwrap();
    for note in &ids {
        let id = queue
            .enqueue("processRecording", json!({"recordingId":note}))
            .await
            .unwrap();
        assert_eq!(
            queue.claim(Lane::Inference).await.unwrap().unwrap()["id"],
            json!(id)
        );
        let (finished, cancellation) =
            tokio::join!(queue.finish(&id, Ok(json!({}))), queue.cancel(note));
        let finished = finished.unwrap();
        let cancelled = cancellation.unwrap().ids.contains(&id);
        assert!(
            finished != cancelled,
            "El trabajo quedó terminado y cancelado a la vez, o ninguna de las dos"
        );
        let state = library.job(id.clone()).await.unwrap().unwrap().state;
        let expected = if finished {
            JobState::Succeeded
        } else {
            JobState::Cancelled
        };
        assert_eq!(state, expected);
    }
}

#[tokio::test]
async fn cerrar_confirma_lo_encolado() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("library");
    let library = open(&root).await;
    for index in 0..20 {
        library
            .log(json!({"level":"error","message":format!("Orden encolada {index}")}))
            .unwrap();
    }
    library.close().await.unwrap();
    assert!(library
        .log(json!({"level":"error","message":"Orden encolada tras cerrar"}))
        .is_err());
    assert!(retitle(&library, "cualquiera", "Tras cerrar")
        .await
        .is_err());
    drop(library);
    let lines = reopen(&root)
        .await
        .log_list(&json!({"limit":100}))
        .await
        .unwrap();
    let queued = lines
        .as_array()
        .unwrap()
        .iter()
        .filter(|line| {
            line["message"]
                .as_str()
                .is_some_and(|message| message.starts_with("Orden encolada"))
        })
        .count();
    assert_eq!(queued, 20);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn un_evento_de_carpeta_no_bloquea_al_vigilante() {
    let temp = tempfile::tempdir().unwrap();
    let library = open(&temp.path().join("library")).await;
    let ids = notes(&library, temp.path(), 1).await;
    let folder = temp.path().join("vigilada");
    std::fs::create_dir(&folder).unwrap();
    let folder = folder.canonicalize().unwrap();
    let (wake, mut woken) = tokio::sync::mpsc::channel(1);
    let _watching = crate::watcher::watch(
        &[crate::watcher::Folder {
            id: "vigilada".into(),
            path: folder.clone(),
            enabled: true,
            style: crate::watcher::Style::Any,
        }],
        wake,
    )
    .unwrap();
    let mut stopped = library.stop_next_write();
    let writing = writer(&library, &ids[0]);
    stopped.parked().await;
    while woken.try_recv().is_ok() {}
    std::fs::write(folder.join("nueva.m4a"), b"audio sintetico").unwrap();
    tokio::time::timeout(Duration::from_secs(5), woken.recv())
        .await
        .expect("El vigilante no recibió el evento con la biblioteca ocupada")
        .unwrap();
    drop(stopped);
    writing.await.unwrap().unwrap();
}
