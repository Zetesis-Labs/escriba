use crate::error::{AppError, ErrorCode};
use crate::store::{self, Store};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Retry,
    Failed,
    Succeeded,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::enum_variant_names)]
pub enum JobOperation {
    ProcessRecording,
    SummarizeRecording,
    PublishRecording,
    UnpublishRecording,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub recording_id: String,
    pub operation: JobOperation,
    pub args: Value,
    #[serde(default)]
    pub automatic: bool,
    #[serde(default)]
    pub audio_hash: Option<String>,
    pub state: JobState,
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub attempt: u64,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub started_at: i64,
    #[serde(default)]
    pub next_attempt_at: i64,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub error_code: Option<ErrorCode>,
    #[serde(default)]
    pub result: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Lane {
    Inference,
    Io,
}

impl Lane {
    pub const ALL: [Lane; 2] = [Lane::Inference, Lane::Io];
    pub fn capacity(self) -> usize {
        match self {
            Lane::Inference => 1,
            Lane::Io => 3,
        }
    }
    fn index(self) -> usize {
        match self {
            Lane::Inference => 0,
            Lane::Io => 1,
        }
    }
}

impl JobOperation {
    pub fn lane(self) -> Lane {
        match self {
            JobOperation::ProcessRecording | JobOperation::SummarizeRecording => Lane::Inference,
            JobOperation::PublishRecording | JobOperation::UnpublishRecording => Lane::Io,
        }
    }
}

impl Job {
    fn active(&self) -> bool {
        matches!(
            self.state,
            JobState::Queued | JobState::Running | JobState::Retry
        )
    }
    fn dry_run(&self) -> bool {
        self.args["options"]["dryRun"] == true
    }
}

#[derive(Debug, Default)]
pub struct Cancellation {
    pub ids: Vec<String>,
    pub inference: bool,
}

pub fn next_in_lane(jobs: &[Job], lane: Lane, now: i64) -> Option<usize> {
    let in_lane = |job: &&Job| job.operation.lane() == lane;
    let running = jobs
        .iter()
        .filter(in_lane)
        .filter(|job| job.state == JobState::Running)
        .count();
    if running >= lane.capacity() {
        return None;
    }
    let busy: std::collections::HashSet<&str> = jobs
        .iter()
        .filter(|job| job.state == JobState::Running)
        .map(|job| job.recording_id.as_str())
        .collect();
    jobs.iter()
        .enumerate()
        .filter(|(_, job)| in_lane(job))
        .filter(|(_, job)| matches!(job.state, JobState::Queued | JobState::Retry))
        .filter(|(_, job)| job.next_attempt_at <= now)
        .filter(|(_, job)| !busy.contains(job.recording_id.as_str()))
        .min_by_key(|(_, job)| (job.created_at, job.id.clone()))
        .map(|(index, _)| index)
}

fn parse(value: Value) -> Result<Job, String> {
    let mut job: Job =
        serde_json::from_value(value).map_err(|e| format!("Trabajo guardado inválido: {e}"))?;
    if job.state == JobState::Retry && job.error_code.is_none() {
        job.error_code = match job.error.as_deref() {
            Some(error) if error.starts_with("BACKEND_UNAVAILABLE:") => {
                Some(ErrorCode::BackendUnavailable)
            }
            Some(error) if error.starts_with("RECIPE_UNAVAILABLE:") => {
                Some(ErrorCode::RecipeUnavailable)
            }
            _ => None,
        };
    }
    Ok(job)
}
fn parse_all(values: Vec<Value>) -> Result<Vec<Job>, String> {
    values.into_iter().map(parse).collect()
}
fn load_active(store: &Store) -> Result<Vec<Job>, String> {
    parse_all(store.jobs_active()?)
}
fn load_for(store: &Store, recording: &str) -> Result<Vec<Job>, String> {
    parse_all(store.jobs_for(recording)?)
}
fn load_one(store: &Store, id: &str) -> Result<Option<Job>, String> {
    store.job(id)?.map(parse).transpose()
}
fn save(store: &mut Store, job: &Job) -> Result<(), String> {
    store.job_save(&serde_json::to_value(job).map_err(|e| e.to_string())?)
}
fn value(job: Job) -> Result<Value, String> {
    serde_json::to_value(job).map_err(|e| e.to_string())
}

pub struct Queue {
    store: Arc<Mutex<Store>>,
    wakes: [Notify; 2],
    pub changed: Notify,
}
pub fn durable(operation: &str) -> bool {
    matches!(
        operation,
        "processRecording" | "summarizeRecording" | "publishRecording" | "unpublishRecording"
    )
}
impl Queue {
    pub fn new(store: Arc<Mutex<Store>>) -> Result<Self, String> {
        {
            let mut guard = store.lock().map_err(|_| "Biblioteca ocupada")?;
            for mut job in load_active(&guard)? {
                if job.state == JobState::Running {
                    job.state = JobState::Queued;
                    job.stage = "Recuperando trabajo interrumpido".into();
                    job.next_attempt_at = 0;
                    save(&mut guard, &job)?;
                }
            }
        }
        Ok(Self {
            store,
            wakes: [Notify::new(), Notify::new()],
            changed: Notify::new(),
        })
    }
    pub fn wake(&self, lane: Lane) {
        self.wakes[lane.index()].notify_one();
    }
    pub fn wake_all(&self) {
        for lane in Lane::ALL {
            self.wake(lane);
        }
    }
    pub async fn idle(&self, lane: Lane) {
        tokio::select! {
            _ = self.wakes[lane.index()].notified() => {}
            _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {}
        }
    }
    pub fn enqueue(&self, operation: &str, args: Value) -> Result<String, String> {
        self.enqueue_with_origin(operation, args, false)
    }
    pub fn enqueue_automatic(&self, recording: &str) -> Result<String, String> {
        self.enqueue_with_origin(
            "processRecording",
            json!({"recordingId":recording,"options":{"force":false}}),
            true,
        )
    }
    fn enqueue_with_origin(
        &self,
        operation: &str,
        args: Value,
        automatic: bool,
    ) -> Result<String, String> {
        let operation: JobOperation =
            serde_json::from_value(json!(operation)).map_err(|_| "Operación no encolable")?;
        let recording_id = store::text(&args, "recordingId")?.to_owned();
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let record = guard
            .data
            .recordings
            .iter()
            .find(|r| r.id == recording_id)
            .ok_or("Grabación no encontrada")?;
        if record.status == store::RecordingStatus::Discarded {
            return Err("Restaura la grabación antes de procesarla".into());
        }
        let audio_hash = record.audio_hash.as_ref().cloned();
        if let Some(job) = load_for(&guard, &recording_id)?
            .into_iter()
            .find(Job::active)
        {
            if job.operation == operation && job.args == args {
                return Ok(job.id);
            }
            return Err("La grabación ya tiene un trabajo pendiente".into());
        }
        let id = store::id();
        let time = chrono::Utc::now().timestamp_millis();
        save(
            &mut guard,
            &Job {
                id: id.clone(),
                recording_id,
                operation,
                args,
                automatic,
                audio_hash,
                state: JobState::Queued,
                stage: "En cola".into(),
                attempt: 0,
                created_at: time,
                started_at: time,
                next_attempt_at: 0,
                error: None,
                error_code: None,
                result: None,
                extra: Map::new(),
            },
        )?;
        self.wake(operation.lane());
        self.changed.notify_waiters();
        Ok(id)
    }
    pub fn jobs(&self) -> Result<Vec<Value>, String> {
        let guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        parse_all(guard.jobs()?)?.into_iter().map(value).collect()
    }
    pub fn visible(&self) -> Result<Value, String> {
        let guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let mut active = load_active(&guard)?;
        active.sort_by_key(|job| job.created_at);
        Ok(json!(active))
    }
    pub fn automatic(&self) -> Result<(), String> {
        let candidates = {
            let guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
            let pending: Vec<_> = guard
                .data
                .recordings
                .iter()
                .filter(|record| {
                    record.status == store::RecordingStatus::Pending
                        && record.audio_path.as_ref().is_some()
                })
                .map(|record| (record.id.clone(), record.audio_hash.as_ref().cloned()))
                .collect();
            let mut candidates = Vec::new();
            for (id, audio_hash) in pending {
                let handled = load_for(&guard, &id)?.iter().any(|job| {
                    job.operation == JobOperation::ProcessRecording
                        && !job.dry_run()
                        && (job.active() || job.audio_hash == audio_hash)
                });
                if !handled {
                    candidates.push(id);
                }
            }
            candidates
        };
        for id in candidates {
            self.enqueue_automatic(&id)?;
        }
        Ok(())
    }
    pub fn claim(&self, lane: Lane) -> Result<Option<Value>, String> {
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let now = chrono::Utc::now().timestamp_millis();
        let mut jobs = load_active(&guard)?;
        let Some(index) = next_in_lane(&jobs, lane, now) else {
            return Ok(None);
        };
        let mut job = jobs.swap_remove(index);
        if job.operation == JobOperation::ProcessRecording
            && (job.automatic || job.attempt > 0 || job.args["options"]["force"] == false)
            && guard.recording(&job.recording_id)?["accountEffectPending"] == true
        {
            let message = "Revisa la operación externa antes de reprocesar esta nota manualmente";
            job.state = JobState::Failed;
            job.stage = "Error".into();
            job.error = Some(message.into());
            job.error_code = Some(ErrorCode::Failed);
            guard.mutate(
                "recording_update",
                &json!({"id":job.recording_id,"status":"failed","error":message}),
            )?;
            save(&mut guard, &job)?;
            self.changed.notify_waiters();
            self.wake(lane);
            return Ok(None);
        }
        job.attempt += 1;
        if job.attempt > 1 && job.operation == JobOperation::ProcessRecording {
            job.args["options"]["force"] = json!(false);
        }
        job.state = JobState::Running;
        job.stage = "Procesando".into();
        save(&mut guard, &job)?;
        self.changed.notify_waiters();
        self.wake(lane);
        value(job).map(Some)
    }
    pub fn finish(&self, id: &str, result: Result<Value, AppError>) -> Result<bool, String> {
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let Some(mut job) = load_one(&guard, id)? else {
            return Ok(false);
        };
        if job.state == JobState::Cancelled {
            return Ok(false);
        }
        match result {
            Ok(result) => {
                job.state = JobState::Succeeded;
                job.result = Some(result);
                job.stage = "Completado".into();
                job.error = None;
                job.error_code = None;
            }
            Err(error) => {
                let retry = error.retryable();
                job.state = if retry {
                    JobState::Retry
                } else {
                    JobState::Failed
                };
                job.stage = if retry {
                    "Esperando al servicio"
                } else {
                    "Error"
                }
                .into();
                job.error = Some(error.message.clone());
                job.error_code = Some(error.code);
                if retry {
                    let seconds = (10_u64 * 2_u64.pow(job.attempt.min(5) as u32)).min(300);
                    job.next_attempt_at =
                        chrono::Utc::now().timestamp_millis() + seconds as i64 * 1000;
                }
                if job.operation == JobOperation::ProcessRecording && !job.dry_run() {
                    guard.mutate("recording_update", &json!({"id":job.recording_id,"status":if retry { "pending" } else { "failed" },"error":error.message}))?;
                }
            }
        }
        save(&mut guard, &job)?;
        self.changed.notify_waiters();
        self.wake(job.operation.lane());
        Ok(true)
    }
    pub fn stages(&self, stages: &Value) -> Result<(), String> {
        let stages = stages.as_array().ok_or("Estado de trabajos inválido")?;
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        for mut job in load_active(&guard)?
            .into_iter()
            .filter(|job| job.state == JobState::Running)
        {
            if let Some(stage) = stages
                .iter()
                .find(|stage| stage["recordingId"] == job.recording_id)
            {
                let stage = store::text(stage, "stage")?;
                if job.stage != stage {
                    job.stage = stage.to_owned();
                    save(&mut guard, &job)?;
                }
            }
        }
        self.changed.notify_waiters();
        Ok(())
    }
    pub fn cancel(&self, recording: &str) -> Result<Cancellation, String> {
        let mut guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
        let mut cancellation = Cancellation::default();
        for mut job in load_for(&guard, recording)?.into_iter().filter(Job::active) {
            cancellation.ids.push(job.id.clone());
            cancellation.inference |=
                job.state == JobState::Running && job.operation.lane() == Lane::Inference;
            job.state = JobState::Cancelled;
            job.error = Some("Proceso cancelado".into());
            job.error_code = Some(ErrorCode::Failed);
            job.stage = "Cancelado".into();
            save(&mut guard, &job)?;
            if job.operation == JobOperation::ProcessRecording && !job.dry_run() {
                guard.mutate(
                    "recording_update",
                    &json!({"id":recording,"status":"failed","error":"Proceso cancelado"}),
                )?;
            }
        }
        self.changed.notify_waiters();
        Ok(cancellation)
    }
    pub async fn wait(&self, id: &str) -> Result<Value, String> {
        loop {
            let changed = self.changed.notified();
            let job = {
                let guard = self.store.lock().map_err(|_| "Biblioteca ocupada")?;
                load_one(&guard, id)?.ok_or("Trabajo desconocido")?
            };
            match job.state {
                JobState::Succeeded => return Ok(job.result.unwrap_or(Value::Null)),
                JobState::Failed | JobState::Cancelled => {
                    return Err(job.error.unwrap_or_else(|| "El trabajo falló".into()))
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

    fn job(
        id: &str,
        recording: &str,
        operation: JobOperation,
        state: JobState,
        created: i64,
    ) -> Job {
        Job {
            id: id.into(),
            recording_id: recording.into(),
            operation,
            args: json!({}),
            automatic: false,
            audio_hash: None,
            state,
            stage: String::new(),
            attempt: 0,
            created_at: created,
            started_at: created,
            next_attempt_at: 0,
            error: None,
            error_code: None,
            result: None,
            extra: Map::new(),
        }
    }

    #[test]
    fn una_transcripcion_en_curso_no_retiene_la_publicacion_de_otra_nota() {
        let jobs = vec![
            job(
                "t",
                "a",
                JobOperation::ProcessRecording,
                JobState::Running,
                1,
            ),
            job(
                "t2",
                "c",
                JobOperation::ProcessRecording,
                JobState::Queued,
                2,
            ),
            job(
                "p",
                "b",
                JobOperation::PublishRecording,
                JobState::Queued,
                3,
            ),
        ];
        assert_eq!(next_in_lane(&jobs, Lane::Inference, 10), None);
        assert_eq!(next_in_lane(&jobs, Lane::Io, 10), Some(2));
    }

    #[test]
    fn el_carril_de_red_admite_tres_y_respeta_esperas_y_orden() {
        let mut jobs: Vec<Job> = (0..4)
            .map(|index| {
                job(
                    &format!("p{index}"),
                    &format!("r{index}"),
                    JobOperation::PublishRecording,
                    JobState::Queued,
                    10 - index,
                )
            })
            .collect();
        assert_eq!(next_in_lane(&jobs, Lane::Io, 100), Some(3));
        for running in &mut jobs[1..] {
            running.state = JobState::Running;
        }
        assert_eq!(next_in_lane(&jobs, Lane::Io, 100), None);
        jobs[3].state = JobState::Retry;
        jobs[3].next_attempt_at = 500;
        assert_eq!(next_in_lane(&jobs, Lane::Io, 100), Some(0));
        jobs[0].next_attempt_at = 200;
        jobs[0].state = JobState::Retry;
        assert_eq!(next_in_lane(&jobs, Lane::Io, 100), None);
        assert_eq!(next_in_lane(&jobs, Lane::Io, 600), Some(3));
    }

    #[test]
    fn nunca_corren_dos_trabajos_de_la_misma_nota() {
        let jobs = vec![
            job(
                "t",
                "a",
                JobOperation::ProcessRecording,
                JobState::Running,
                1,
            ),
            job(
                "p",
                "a",
                JobOperation::PublishRecording,
                JobState::Queued,
                2,
            ),
        ];
        assert_eq!(next_in_lane(&jobs, Lane::Io, 10), None);
    }

    #[test]
    fn publicar_otra_nota_no_espera_a_la_transcripcion() {
        let temp = tempfile::tempdir().unwrap();
        let store = library(&temp.path().join("library"));
        let mut ids = Vec::new();
        for name in ["una.wav", "otra.wav"] {
            let path = temp.path().join(name);
            std::fs::write(&path, name.as_bytes()).unwrap();
            ids.push(store.lock().unwrap().import(&path, None).unwrap()["id"].clone());
        }
        let queue = Queue::new(store.clone()).unwrap();
        queue
            .enqueue("processRecording", json!({"recordingId":ids[0]}))
            .unwrap();
        assert!(queue.claim(Lane::Inference).unwrap().is_some());
        let publish = queue
            .enqueue(
                "publishRecording",
                json!({"recordingId":ids[1],"destinationId":"d"}),
            )
            .unwrap();
        assert_eq!(queue.claim(Lane::Io).unwrap().unwrap()["id"], publish);
        assert!(queue.claim(Lane::Inference).unwrap().is_none());
        assert_eq!(queue.visible().unwrap().as_array().unwrap().len(), 2);
    }
    #[test]
    fn cancelar_una_publicacion_no_corta_la_inferencia_de_otra_nota() {
        let temp = tempfile::tempdir().unwrap();
        let store = library(&temp.path().join("library"));
        let mut ids = Vec::new();
        for name in ["una.wav", "otra.wav"] {
            let path = temp.path().join(name);
            std::fs::write(&path, name.as_bytes()).unwrap();
            ids.push(
                store.lock().unwrap().import(&path, None).unwrap()["id"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            );
        }
        let queue = Queue::new(store.clone()).unwrap();
        queue
            .enqueue("processRecording", json!({"recordingId":ids[0]}))
            .unwrap();
        queue.claim(Lane::Inference).unwrap().unwrap();
        let publish = queue
            .enqueue(
                "publishRecording",
                json!({"recordingId":ids[1],"destinationId":"d"}),
            )
            .unwrap();
        queue.claim(Lane::Io).unwrap().unwrap();
        let publication = queue.cancel(&ids[1]).unwrap();
        assert_eq!(publication.ids, vec![publish]);
        assert!(!publication.inference);
        assert!(queue.cancel(&ids[0]).unwrap().inference);
    }
    #[test]
    fn trabajo_automatico_no_repite_efecto_externo_incierto() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library"));
        let record = store.lock().unwrap().import(&audio, None).unwrap();
        store
            .lock()
            .unwrap()
            .mutate("account_effect_begin", &json!({"recordingId":record["id"]}))
            .unwrap();
        let queue = Queue::new(store.clone()).unwrap();
        let job = queue
            .enqueue_automatic(record["id"].as_str().unwrap())
            .unwrap();
        assert!(queue.claim(Lane::Inference).unwrap().is_none());
        let failed = queue
            .jobs()
            .unwrap()
            .into_iter()
            .find(|item| item["id"] == job)
            .unwrap();
        assert_eq!(failed["state"], "failed");
        assert!(failed["error"]
            .as_str()
            .unwrap()
            .contains("Revisa la operación externa"));
    }
    #[test]
    fn trabajo_manual_recuperado_no_repite_efecto_externo_incierto() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library"));
        let record = store.lock().unwrap().import(&audio, None).unwrap();
        let queue = Queue::new(store.clone()).unwrap();
        let id = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":record["id"],"options":{"force":true}}),
            )
            .unwrap();
        assert!(queue.claim(Lane::Inference).unwrap().is_some());
        store
            .lock()
            .unwrap()
            .mutate("account_effect_begin", &json!({"recordingId":record["id"]}))
            .unwrap();
        queue
            .finish(
                &id,
                Err(AppError::new(ErrorCode::BackendUnavailable, "temporary")),
            )
            .unwrap();
        {
            let mut guard = store.lock().unwrap();
            let mut job = load_one(&guard, &id).unwrap().unwrap();
            job.next_attempt_at = 0;
            save(&mut guard, &job).unwrap();
        }
        assert!(queue.claim(Lane::Inference).unwrap().is_none());
        let failed = queue
            .jobs()
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == id)
            .unwrap();
        assert_eq!(failed["state"], "failed");
    }
    fn library(path: &std::path::Path) -> Arc<Mutex<Store>> {
        Arc::new(Mutex::new(Store::open(path.to_owned()).unwrap()))
    }
    #[test]
    fn cancelar_tras_la_inferencia_impide_confirmar_el_resultado_y_avisar_del_exito() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library"));
        let record = store.lock().unwrap().import(&audio, None).unwrap();
        let queue = Queue::new(store).unwrap();
        let id = queue
            .enqueue_automatic(record["id"].as_str().unwrap())
            .unwrap();
        queue.claim(Lane::Inference).unwrap().unwrap();
        queue.cancel(record["id"].as_str().unwrap()).unwrap();
        assert!(!queue.finish(&id, Ok(Value::Null)).unwrap());
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
        assert_eq!(queue.claim(Lane::Inference).unwrap().unwrap()["attempt"], 1);
        drop(queue);
        drop(store);
        let queue = Queue::new(library(&root)).unwrap();
        let resumed = queue.claim(Lane::Inference).unwrap().unwrap();
        assert_eq!(resumed["id"], id);
        assert_eq!(resumed["attempt"], 2);
        assert_eq!(resumed["args"]["options"]["force"], false);
        assert_eq!(resumed["automatic"], false);
    }
    #[test]
    fn el_origen_automatico_se_conserva_al_recuperar_un_trabajo() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let root = temp.path().join("library");
        let store = library(&root);
        store.lock().unwrap().import(&audio, None).unwrap();
        let queue = Queue::new(store.clone()).unwrap();
        queue.automatic().unwrap();
        let first = queue.claim(Lane::Inference).unwrap().unwrap();
        assert_eq!(first["automatic"], true);
        drop(queue);
        drop(store);
        let queue = Queue::new(library(&root)).unwrap();
        let resumed = queue.claim(Lane::Inference).unwrap().unwrap();
        assert_eq!(resumed["id"], first["id"]);
        assert_eq!(resumed["automatic"], true);
    }

    #[test]
    fn unavailable_services_retry_but_bad_input_does_not() {
        assert!(AppError::new(ErrorCode::BackendUnavailable, "429").retryable());
        assert!(!AppError::new(ErrorCode::Failed, "El resolutor respondió 413").retryable());
        assert!(
            !AppError::new(ErrorCode::Failed, "BACKEND_UNAVAILABLE: texto de usuario").retryable()
        );
    }

    #[test]
    fn trabajo_legacy_en_espera_conserva_codigo_al_reabrir() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic").unwrap();
        let root = temp.path().join("library");
        let store = library(&root);
        let recording = store.lock().unwrap().import(&audio, None).unwrap();
        store.lock().unwrap().job_save(&json!({
            "id":"old-job", "recordingId":recording["id"], "operation":"processRecording",
            "args":{"recordingId":recording["id"]}, "state":"retry", "stage":"Esperando al servicio",
            "attempt":1, "createdAt":1, "startedAt":1, "nextAttemptAt":i64::MAX,
            "error":"BACKEND_UNAVAILABLE: modelo ausente", "externalReceipt":{"id":"receipt"}
        })).unwrap();
        drop(store);
        let queue = Queue::new(library(&root)).unwrap();
        let old = queue
            .jobs()
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == "old-job")
            .unwrap();
        assert_eq!(old["state"], "retry");
        assert_eq!(old["errorCode"], "backend_unavailable");
        queue.cancel(recording["id"].as_str().unwrap()).unwrap();
        let saved = queue
            .jobs()
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == "old-job")
            .unwrap();
        assert_eq!(saved["externalReceipt"]["id"], "receipt");
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
        assert_eq!(queue.claim(Lane::Inference).unwrap().unwrap()["id"], first);
        queue
            .finish(
                &first,
                Err(AppError::new(ErrorCode::BackendUnavailable, "429")),
            )
            .unwrap();
        assert_eq!(
            queue.claim(Lane::Inference).unwrap().unwrap()["recordingId"],
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
        queue.claim(Lane::Inference).unwrap();
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
        let next = queue.claim(Lane::Inference).unwrap().unwrap();
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
        let job = queue.claim(Lane::Inference).unwrap().unwrap();
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
        let next = queue.claim(Lane::Inference).unwrap().unwrap();
        assert_eq!(next["recordingId"], record["id"]);
        assert_ne!(next["audioHash"], job["audioHash"]);
    }
}
