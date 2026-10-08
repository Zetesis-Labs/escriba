use crate::store::{self, Store};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

pub struct Queue {
    store: Arc<Mutex<Store>>,
    pub wake: Notify,
    pub changed: Notify,
}
pub fn durable(operation: &str) -> bool {
    matches!(
        operation,
        "processRecording" | "summarizeRecording" | "publishRecording" | "unpublishRecording"
    )
}
fn active(job: &Value) -> bool {
    matches!(job["state"].as_str(), Some("queued" | "running" | "retry"))
}
fn retryable(message: &str) -> bool {
    message.contains("BACKEND_UNAVAILABLE:")
        || message.contains("RECIPE_UNAVAILABLE:")
        || message.contains("El motor TypeScript se detuvo")
        || message.contains("El proceso TypeScript perdió")
}
impl Queue {
    pub fn new(store: Arc<Mutex<Store>>) -> Result<Self, String> {
        {
            let mut guard = store.lock().map_err(|_| "Biblioteca ocupada")?;
            for mut job in guard.jobs()? {
                if job["state"] == "running" {
                    job["state"] = json!("queued");
                    job["stage"] = json!("Recuperando trabajo interrumpido");
                    job["nextAttemptAt"] = json!(0);
                    guard.job_save(&job)?;
                }
            }
        }
        Ok(Self {
            store,
            wake: Notify::new(),
            changed: Notify::new(),
        })
    }
    pub fn enqueue(&self, operation: &str, args: Value) -> Result<String, String> {
        if !durable(operation) {
            return Err("Operación no encolable".into());
        }
        let recording = store::text(&args, "recordingId")?;
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let record = guard.recording(recording)?;
        if record["status"] == "discarded" {
            return Err("Restaura la grabación antes de procesarla".into());
        }
        for job in guard.jobs()?.into_iter().filter(active) {
            if job["recordingId"] == recording {
                if job["operation"] == operation && job["args"] == args {
                    return Ok(store::text(&job, "id")?.to_owned());
                }
                return Err("La grabación ya tiene un trabajo pendiente".into());
            }
        }
        let id = store::id();
        let time = chrono::Utc::now().timestamp_millis();
        guard.job_save(&json!({"id":id,"recordingId":recording,"operation":operation,"args":args,"audioHash":record["audioHash"],"state":"queued","stage":"En cola","attempt":0,"createdAt":time,"startedAt":time,"nextAttemptAt":0}))?;
        self.wake.notify_one();
        self.changed.notify_waiters();
        Ok(id)
    }
    pub fn jobs(&self) -> Result<Vec<Value>, String> {
        self.store.lock().map_err(|_| "Biblioteca ocupada")?.jobs()
    }
    pub fn visible(&self) -> Result<Value, String> {
        Ok(json!(self
            .jobs()?
            .into_iter()
            .filter(active)
            .collect::<Vec<_>>()))
    }
    pub fn automatic(&self) -> Result<(), String> {
        let candidates = {
            let guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
            if guard.data["settings"]["autoProcess"] != true {
                return Ok(());
            }
            let jobs = guard.jobs()?;
            guard.data["recordings"]
                .as_array()
                .ok_or("Biblioteca inválida")?
                .iter()
                .filter(|r| {
                    r["status"] == "pending"
                        && r["audioPath"].is_string()
                        && !jobs.iter().any(|j| {
                            j["recordingId"] == r["id"]
                                && j["operation"] == "processRecording"
                                && j["args"]["options"]["dryRun"] != true
                                && (active(j) || j["audioHash"] == r["audioHash"])
                        })
                })
                .map(|r| r["id"].clone())
                .collect::<Vec<_>>()
        };
        for id in candidates {
            self.enqueue(
                "processRecording",
                json!({"recordingId":id,"options":{"force":false}}),
            )?;
        }
        Ok(())
    }
    pub fn claim(&self) -> Result<Option<Value>, String> {
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let now = chrono::Utc::now().timestamp_millis();
        let mut jobs = guard.jobs()?;
        jobs.sort_by_key(|j| j["createdAt"].as_i64().unwrap_or(0));
        if jobs.iter().any(|j| j["state"] == "running") {
            return Ok(None);
        }
        let Some(mut job) = jobs.into_iter().find(|j| {
            matches!(j["state"].as_str(), Some("queued" | "retry"))
                && j["nextAttemptAt"].as_i64().unwrap_or(0) <= now
        }) else {
            return Ok(None);
        };
        job["attempt"] = json!(job["attempt"].as_u64().unwrap_or(0) + 1);
        if job["attempt"].as_u64().unwrap_or(1) > 1 && job["operation"] == "processRecording" {
            job["args"]["options"]["force"] = json!(false);
        }
        job["state"] = json!("running");
        job["stage"] = json!("Procesando");
        guard.job_save(&job)?;
        self.changed.notify_waiters();
        Ok(Some(job))
    }
    pub fn finish(&self, id: &str, result: Result<Value, String>) -> Result<(), String> {
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let Some(mut job) = guard.jobs()?.into_iter().find(|j| j["id"] == id) else {
            return Ok(());
        };
        if job["state"] == "cancelled" {
            return Ok(());
        }
        match result {
            Ok(value) => {
                job["state"] = json!("succeeded");
                job["result"] = value;
                job["stage"] = json!("Completado");
                job["error"] = Value::Null;
            }
            Err(error) => {
                let retry = retryable(&error);
                job["state"] = json!(if retry { "retry" } else { "failed" });
                job["stage"] = json!(if retry {
                    "Esperando al servicio"
                } else {
                    "Error"
                });
                job["error"] = json!(error);
                if retry {
                    let seconds = (10_u64
                        * 2_u64.pow(job["attempt"].as_u64().unwrap_or(1).min(5) as u32))
                    .min(300);
                    job["nextAttemptAt"] =
                        json!(chrono::Utc::now().timestamp_millis() + seconds as i64 * 1000);
                    if job["operation"] == "processRecording"
                        && job["args"]["options"]["dryRun"] != true
                    {
                        guard.mutate(
                            "recording_update",
                            &json!({"id":job["recordingId"],"status":"pending","error":error}),
                        )?;
                    }
                } else if job["operation"] == "processRecording"
                    && job["args"]["options"]["dryRun"] != true
                {
                    guard.mutate(
                        "recording_update",
                        &json!({"id":job["recordingId"],"status":"failed","error":error}),
                    )?;
                }
            }
        }
        guard.job_save(&job)?;
        self.changed.notify_waiters();
        self.wake.notify_one();
        Ok(())
    }
    pub fn stages(&self, stages: &Value) -> Result<(), String> {
        let Some(stages) = stages.as_array() else {
            return Err("Estado de trabajos inválido".into());
        };
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        for mut job in guard
            .jobs()?
            .into_iter()
            .filter(|j| j["state"] == "running")
        {
            if let Some(stage) = stages
                .iter()
                .find(|s| s["recordingId"] == job["recordingId"])
            {
                job["stage"] = stage["stage"].clone();
                guard.job_save(&job)?;
            }
        }
        self.changed.notify_waiters();
        Ok(())
    }
    pub fn cancel(&self, recording: &str) -> Result<Vec<String>, String> {
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let mut ids = Vec::new();
        for mut job in guard
            .jobs()?
            .into_iter()
            .filter(|j| j["recordingId"] == recording && active(j))
        {
            ids.push(store::text(&job, "id")?.to_owned());
            job["state"] = json!("cancelled");
            job["error"] = json!("Proceso cancelado");
            job["stage"] = json!("Cancelado");
            guard.job_save(&job)?;
            if job["operation"] == "processRecording" && job["args"]["options"]["dryRun"] != true {
                guard.mutate(
                    "recording_update",
                    &json!({"id":recording,"status":"failed","error":"Proceso cancelado"}),
                )?;
            }
        }
        self.changed.notify_waiters();
        Ok(ids)
    }
    pub async fn wait(&self, id: &str) -> Result<Value, String> {
        loop {
            let changed = self.changed.notified();
            let job = self
                .jobs()?
                .into_iter()
                .find(|j| j["id"] == id)
                .ok_or("Trabajo desconocido")?;
            match job["state"].as_str() {
                Some("succeeded") => return Ok(job["result"].clone()),
                Some("failed" | "cancelled") => {
                    return Err(job["error"]
                        .as_str()
                        .unwrap_or("El trabajo falló")
                        .to_owned())
                }
                _ => {
                    tokio::select! { _ = changed => {}, _ = tokio::time::sleep(std::time::Duration::from_secs(2)) => {} }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn library(path: &std::path::Path) -> Arc<Mutex<Store>> {
        Arc::new(Mutex::new(Store::open(path.to_owned()).unwrap()))
    }
    #[test]
    fn interrupted_job_resumes_without_creating_another_manual_version() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let root = temp.path().join("library");
        let store = library(&root);
        let record = store.lock().unwrap().import(&audio, None).unwrap();
        let queue = Queue::new(store.clone()).unwrap();
        let id = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":record["id"],"options":{"force":true}}),
            )
            .unwrap();
        assert_eq!(queue.claim().unwrap().unwrap()["attempt"], 1);
        drop(queue);
        drop(store);
        let queue = Queue::new(library(&root)).unwrap();
        let resumed = queue.claim().unwrap().unwrap();
        assert_eq!(resumed["id"], id);
        assert_eq!(resumed["attempt"], 2);
        assert_eq!(resumed["args"]["options"]["force"], false);
    }
    #[test]
    fn unavailable_services_retry_but_bad_input_does_not() {
        assert!(retryable("BACKEND_UNAVAILABLE: 429"));
        assert!(!retryable("El resolutor respondió 413"));
    }

    #[test]
    fn a_waiting_service_does_not_hold_back_the_next_recording() {
        let temp = tempfile::tempdir().unwrap();
        let store = library(&temp.path().join("library"));
        let mut recordings = Vec::new();
        for name in ["one.wav", "two.wav"] {
            let path = temp.path().join(name);
            std::fs::write(&path, name.as_bytes()).unwrap();
            recordings.push(store.lock().unwrap().import(&path, None).unwrap());
        }
        let queue = Queue::new(store.clone()).unwrap();
        let first = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":recordings[0]["id"]}),
            )
            .unwrap();
        queue
            .enqueue(
                "processRecording",
                json!({"recordingId":recordings[1]["id"]}),
            )
            .unwrap();
        assert_eq!(queue.claim().unwrap().unwrap()["id"], first);
        queue
            .finish(&first, Err("BACKEND_UNAVAILABLE: 429".into()))
            .unwrap();
        assert_eq!(
            queue.claim().unwrap().unwrap()["recordingId"],
            recordings[1]["id"]
        );
        assert_eq!(
            store
                .lock()
                .unwrap()
                .recording(recordings[0]["id"].as_str().unwrap())
                .unwrap()["status"],
            "pending"
        );
    }

    #[test]
    fn a_failed_dry_run_preserves_the_recording_and_does_not_disable_automatic_work() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic").unwrap();
        let store = library(&temp.path().join("library"));
        let record = store.lock().unwrap().import(&audio, None).unwrap();
        let queue = Queue::new(store.clone()).unwrap();
        let id = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":record["id"],"options":{"dryRun":true}}),
            )
            .unwrap();
        queue.claim().unwrap();
        queue.finish(&id, Err("Receta inválida".into())).unwrap();
        assert_eq!(
            store
                .lock()
                .unwrap()
                .recording(record["id"].as_str().unwrap())
                .unwrap(),
            record
        );
        queue.automatic().unwrap();
        let next = queue.claim().unwrap().unwrap();
        assert_ne!(next["id"], id);
        assert_eq!(next["args"]["options"]["force"], false);
    }

    #[test]
    fn changed_audio_is_enqueued_again_after_a_completed_run() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"first contents").unwrap();
        let store = library(&temp.path().join("library"));
        let started = std::time::SystemTime::now();
        let record = store
            .lock()
            .unwrap()
            .import_with_metadata(&audio, None, "Nota", started, "voiceMemos:test/1")
            .unwrap();
        let queue = Queue::new(store.clone()).unwrap();
        queue.automatic().unwrap();
        let job = queue.claim().unwrap().unwrap();
        queue
            .finish(job["id"].as_str().unwrap(), Ok(Value::Null))
            .unwrap();
        std::fs::write(&audio, b"changed contents").unwrap();
        store
            .lock()
            .unwrap()
            .import_with_metadata(&audio, None, "Nota", started, "voiceMemos:test/1")
            .unwrap();
        queue.automatic().unwrap();
        let next = queue.claim().unwrap().unwrap();
        assert_eq!(next["recordingId"], record["id"]);
        assert_ne!(next["audioHash"], job["audioHash"]);
    }
}
