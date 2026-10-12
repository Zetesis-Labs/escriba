use crate::error::{AppError, ErrorCode};
use crate::library::Library;
use crate::store::{self, Store};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
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
async fn load_active(store: &Store) -> Result<Vec<Job>, String> {
    parse_all(store.jobs_active().await?)
}
async fn load_for(store: &Store, recording: &str) -> Result<Vec<Job>, String> {
    parse_all(store.jobs_for(recording).await?)
}
async fn load_one(store: &Store, id: &str) -> Result<Option<Job>, String> {
    store.job(id).await?.map(parse).transpose()
}
async fn save(store: &mut Store, job: &Job) -> Result<(), String> {
    store
        .job_save(&serde_json::to_value(job).map_err(|e| e.to_string())?)
        .await
}
fn value(job: Job) -> Result<Value, String> {
    serde_json::to_value(job).map_err(|e| e.to_string())
}

pub enum Claimed {
    Job(Value),
    Blocked,
    Empty,
}

pub(crate) async fn recover(store: &mut Store) -> Result<(), String> {
    for mut job in load_active(store).await? {
        if job.state == JobState::Running {
            job.state = JobState::Queued;
            job.stage = "Recuperando trabajo interrumpido".into();
            job.next_attempt_at = 0;
            save(store, &job).await?;
        }
    }
    Ok(())
}

pub(crate) async fn enqueue(
    store: &mut Store,
    operation: &str,
    args: Value,
    automatic: bool,
) -> Result<(String, Lane), String> {
    let operation: JobOperation =
        serde_json::from_value(json!(operation)).map_err(|_| "Operación no encolable")?;
    let recording_id = store::text(&args, "recordingId")?.to_owned();
    let record = store
        .data
        .recordings
        .iter()
        .find(|r| r.id == recording_id)
        .ok_or("Grabación no encontrada")?;
    if record.status == store::RecordingStatus::Discarded {
        return Err("Restaura la grabación antes de procesarla".into());
    }
    let audio_hash = record.audio_hash.as_ref().cloned();
    if let Some(job) = load_for(store, &recording_id)
        .await?
        .into_iter()
        .find(Job::active)
    {
        if job.operation == operation && job.args == args {
            return Ok((job.id, operation.lane()));
        }
        return Err("La grabación ya tiene un trabajo pendiente".into());
    }
    let id = store::id();
    let time = chrono::Utc::now().timestamp_millis();
    save(
        store,
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
    )
    .await?;
    Ok((id, operation.lane()))
}

pub(crate) async fn automatic(store: &mut Store) -> Result<bool, String> {
    let pending: Vec<_> = store
        .data
        .recordings
        .iter()
        .filter(|record| {
            record.status == store::RecordingStatus::Pending && record.audio_path.as_ref().is_some()
        })
        .map(|record| (record.id.clone(), record.audio_hash.as_ref().cloned()))
        .collect();
    let mut enqueued = false;
    for (id, audio_hash) in pending {
        let handled = load_for(store, &id).await?.iter().any(|job| {
            job.operation == JobOperation::ProcessRecording
                && !job.dry_run()
                && (job.active() || job.audio_hash == audio_hash)
        });
        if !handled {
            enqueue(
                store,
                "processRecording",
                json!({"recordingId":id,"options":{"force":false}}),
                true,
            )
            .await?;
            enqueued = true;
        }
    }
    Ok(enqueued)
}

pub(crate) async fn claim(store: &mut Store, lane: Lane, now: i64) -> Result<Claimed, String> {
    let mut jobs = load_active(store).await?;
    let Some(index) = next_in_lane(&jobs, lane, now) else {
        return Ok(Claimed::Empty);
    };
    let mut job = jobs.swap_remove(index);
    if job.operation == JobOperation::ProcessRecording
        && (job.automatic || job.attempt > 0 || job.args["options"]["force"] == false)
        && store.recording(&job.recording_id).await?["accountEffectPending"] == true
    {
        let message = "Revisa la operación externa antes de reprocesar esta nota manualmente";
        job.state = JobState::Failed;
        job.stage = "Error".into();
        job.error = Some(message.into());
        job.error_code = Some(ErrorCode::Failed);
        store
            .mutate(
                "recording_update",
                &json!({"id":job.recording_id,"status":"failed","error":message}),
            )
            .await?;
        save(store, &job).await?;
        return Ok(Claimed::Blocked);
    }
    job.attempt += 1;
    if job.attempt > 1 && job.operation == JobOperation::ProcessRecording {
        job.args["options"]["force"] = json!(false);
    }
    job.state = JobState::Running;
    job.stage = "Procesando".into();
    save(store, &job).await?;
    value(job).map(Claimed::Job)
}

pub(crate) async fn finish(
    store: &mut Store,
    id: &str,
    result: Result<Value, AppError>,
) -> Result<Option<Lane>, String> {
    let Some(mut job) = load_one(store, id).await? else {
        return Ok(None);
    };
    if job.state == JobState::Cancelled {
        return Ok(None);
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
                job.next_attempt_at = chrono::Utc::now().timestamp_millis() + seconds as i64 * 1000;
            }
            if job.operation == JobOperation::ProcessRecording && !job.dry_run() {
                store.mutate("recording_update", &json!({"id":job.recording_id,"status":if retry { "pending" } else { "failed" },"error":error.message})).await?;
            }
        }
    }
    save(store, &job).await?;
    Ok(Some(job.operation.lane()))
}

pub(crate) async fn stages(store: &mut Store, stages: &Value) -> Result<(), String> {
    let stages = stages.as_array().ok_or("Estado de trabajos inválido")?;
    for mut job in load_active(store)
        .await?
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
                save(store, &job).await?;
            }
        }
    }
    Ok(())
}

pub(crate) async fn cancel(store: &mut Store, recording: &str) -> Result<Cancellation, String> {
    let mut cancellation = Cancellation::default();
    for mut job in load_for(store, recording)
        .await?
        .into_iter()
        .filter(Job::active)
    {
        cancellation.ids.push(job.id.clone());
        cancellation.inference |=
            job.state == JobState::Running && job.operation.lane() == Lane::Inference;
        job.state = JobState::Cancelled;
        job.error = Some("Proceso cancelado".into());
        job.error_code = Some(ErrorCode::Failed);
        job.stage = "Cancelado".into();
        save(store, &job).await?;
        if job.operation == JobOperation::ProcessRecording && !job.dry_run() {
            store
                .mutate(
                    "recording_update",
                    &json!({"id":recording,"status":"failed","error":"Proceso cancelado"}),
                )
                .await?;
        }
    }
    Ok(cancellation)
}

pub(crate) async fn busy(store: &Store, recording: &str) -> Result<bool, String> {
    Ok(load_for(store, recording).await?.iter().any(Job::active))
}

pub(crate) async fn visible(store: &Store) -> Result<Vec<Value>, String> {
    let mut active = load_active(store).await?;
    active.sort_by_key(|job| job.created_at);
    active.into_iter().map(value).collect()
}

pub(crate) async fn history(store: &Store) -> Result<Vec<Value>, String> {
    parse_all(store.jobs().await?)?
        .into_iter()
        .map(value)
        .collect()
}

pub(crate) async fn find(store: &Store, id: &str) -> Result<Option<Job>, String> {
    load_one(store, id).await
}

pub struct Queue {
    library: Library,
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
    pub async fn new(library: Library) -> Result<Self, String> {
        library.recover_jobs().await?;
        Ok(Self {
            library,
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
    pub async fn enqueue(&self, operation: &str, args: Value) -> Result<String, String> {
        self.enqueue_with_origin(operation, args, false).await
    }
    #[cfg(test)]
    pub async fn enqueue_automatic(&self, recording: &str) -> Result<String, String> {
        self.enqueue_with_origin(
            "processRecording",
            json!({"recordingId":recording,"options":{"force":false}}),
            true,
        )
        .await
    }
    async fn enqueue_with_origin(
        &self,
        operation: &str,
        args: Value,
        automatic: bool,
    ) -> Result<String, String> {
        let (id, lane) = self
            .library
            .enqueue_job(operation.to_owned(), args, automatic)
            .await?;
        self.wake(lane);
        self.changed.notify_waiters();
        Ok(id)
    }
    pub async fn jobs(&self) -> Result<Vec<Value>, String> {
        self.library.job_history().await
    }
    pub fn visible(&self) -> Value {
        json!(*self.library.active_jobs())
    }
    pub async fn automatic(&self) -> Result<(), String> {
        if self.library.enqueue_automatic_jobs().await? {
            self.wake(Lane::Inference);
            self.changed.notify_waiters();
        }
        Ok(())
    }
    pub async fn claim(&self, lane: Lane) -> Result<Option<Value>, String> {
        let now = chrono::Utc::now().timestamp_millis();
        match self.library.claim_job(lane, now).await? {
            Claimed::Job(job) => {
                self.changed.notify_waiters();
                self.wake(lane);
                Ok(Some(job))
            }
            Claimed::Blocked => {
                self.changed.notify_waiters();
                self.wake(lane);
                Ok(None)
            }
            Claimed::Empty => Ok(None),
        }
    }
    pub async fn finish(&self, id: &str, result: Result<Value, AppError>) -> Result<bool, String> {
        match self.library.finish_job(id.to_owned(), result).await? {
            Some(lane) => {
                self.changed.notify_waiters();
                self.wake(lane);
                Ok(true)
            }
            None => Ok(false),
        }
    }
    pub async fn stages(&self, stages: &Value) -> Result<(), String> {
        self.library.job_stages(stages.clone()).await?;
        self.changed.notify_waiters();
        Ok(())
    }
    pub async fn cancel(&self, recording: &str) -> Result<Cancellation, String> {
        let cancellation = self.library.cancel_jobs(recording.to_owned()).await?;
        self.changed.notify_waiters();
        Ok(cancellation)
    }
    pub async fn wait(&self, id: &str) -> Result<Value, String> {
        loop {
            let changed = self.changed.notified();
            let job = self
                .library
                .job(id.to_owned())
                .await?
                .ok_or("Trabajo desconocido")?;
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

    #[tokio::test]
    async fn publicar_otra_nota_no_espera_a_la_transcripcion() {
        let temp = tempfile::tempdir().unwrap();
        let store = library(&temp.path().join("library")).await;
        let mut ids = Vec::new();
        for name in ["una.wav", "otra.wav"] {
            let path = temp.path().join(name);
            std::fs::write(&path, name.as_bytes()).unwrap();
            ids.push(store.import(&path).await.unwrap()["id"].clone());
        }
        let queue = Queue::new(store.clone()).await.unwrap();
        queue
            .enqueue("processRecording", json!({"recordingId":ids[0]}))
            .await
            .unwrap();
        assert!(queue.claim(Lane::Inference).await.unwrap().is_some());
        let publish = queue
            .enqueue(
                "publishRecording",
                json!({"recordingId":ids[1],"destinationId":"d"}),
            )
            .await
            .unwrap();
        assert_eq!(queue.claim(Lane::Io).await.unwrap().unwrap()["id"], publish);
        assert!(queue.claim(Lane::Inference).await.unwrap().is_none());
        assert_eq!(queue.visible().as_array().unwrap().len(), 2);
    }
    #[tokio::test]
    async fn cancelar_una_publicacion_no_corta_la_inferencia_de_otra_nota() {
        let temp = tempfile::tempdir().unwrap();
        let store = library(&temp.path().join("library")).await;
        let mut ids = Vec::new();
        for name in ["una.wav", "otra.wav"] {
            let path = temp.path().join(name);
            std::fs::write(&path, name.as_bytes()).unwrap();
            ids.push(
                store.import(&path).await.unwrap()["id"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            );
        }
        let queue = Queue::new(store.clone()).await.unwrap();
        queue
            .enqueue("processRecording", json!({"recordingId":ids[0]}))
            .await
            .unwrap();
        queue.claim(Lane::Inference).await.unwrap().unwrap();
        let publish = queue
            .enqueue(
                "publishRecording",
                json!({"recordingId":ids[1],"destinationId":"d"}),
            )
            .await
            .unwrap();
        queue.claim(Lane::Io).await.unwrap().unwrap();
        let publication = queue.cancel(&ids[1]).await.unwrap();
        assert_eq!(publication.ids, vec![publish]);
        assert!(!publication.inference);
        assert!(queue.cancel(&ids[0]).await.unwrap().inference);
    }
    #[tokio::test]
    async fn trabajo_automatico_no_repite_efecto_externo_incierto() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library")).await;
        let record = store.import(&audio).await.unwrap();
        store
            .mutate(
                "account_effect_begin".into(),
                json!({"recordingId":record["id"]}),
            )
            .await
            .unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        let job = queue
            .enqueue_automatic(record["id"].as_str().unwrap())
            .await
            .unwrap();
        assert!(queue.claim(Lane::Inference).await.unwrap().is_none());
        let failed = queue
            .jobs()
            .await
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
    #[tokio::test]
    async fn trabajo_manual_recuperado_no_repite_efecto_externo_incierto() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library")).await;
        let record = store.import(&audio).await.unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        let id = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":record["id"],"options":{"force":true}}),
            )
            .await
            .unwrap();
        assert!(queue.claim(Lane::Inference).await.unwrap().is_some());
        store
            .mutate(
                "account_effect_begin".into(),
                json!({"recordingId":record["id"]}),
            )
            .await
            .unwrap();
        queue
            .finish(
                &id,
                Err(AppError::new(ErrorCode::BackendUnavailable, "temporary")),
            )
            .await
            .unwrap();
        let waiting = id.clone();
        store
            .with_store(move |store| {
                Box::pin(async move {
                    let mut job = load_one(store, &waiting).await.unwrap().unwrap();
                    job.next_attempt_at = 0;
                    save(store, &job).await.unwrap();
                })
            })
            .await;
        assert!(queue.claim(Lane::Inference).await.unwrap().is_none());
        let failed = queue
            .jobs()
            .await
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == id)
            .unwrap();
        assert_eq!(failed["state"], "failed");
    }
    async fn library(path: &std::path::Path) -> Library {
        Library::new(Store::open(path.to_owned()).await.unwrap())
            .await
            .unwrap()
    }
    #[tokio::test]
    async fn cancelar_tras_la_inferencia_impide_confirmar_el_resultado_y_avisar_del_exito() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library")).await;
        let record = store.import(&audio).await.unwrap();
        let queue = Queue::new(store).await.unwrap();
        let id = queue
            .enqueue_automatic(record["id"].as_str().unwrap())
            .await
            .unwrap();
        queue.claim(Lane::Inference).await.unwrap().unwrap();
        queue.cancel(record["id"].as_str().unwrap()).await.unwrap();
        assert!(!queue.finish(&id, Ok(Value::Null)).await.unwrap());
    }
    #[tokio::test]
    async fn interrupted_job_resumes_without_creating_another_manual_version() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let root = temp.path().join("library");
        let store = library(&root).await;
        let record = store.import(&audio).await.unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        let id = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":record["id"],"options":{"force":true}}),
            )
            .await
            .unwrap();
        assert_eq!(
            queue.claim(Lane::Inference).await.unwrap().unwrap()["attempt"],
            1
        );
        drop(queue);
        drop(store);
        let queue = Queue::new(library(&root).await).await.unwrap();
        let resumed = queue.claim(Lane::Inference).await.unwrap().unwrap();
        assert_eq!(resumed["id"], id);
        assert_eq!(resumed["attempt"], 2);
        assert_eq!(resumed["args"]["options"]["force"], false);
        assert_eq!(resumed["automatic"], false);
    }
    #[tokio::test]
    async fn el_origen_automatico_se_conserva_al_recuperar_un_trabajo() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let root = temp.path().join("library");
        let store = library(&root).await;
        store.import(&audio).await.unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        queue.automatic().await.unwrap();
        let first = queue.claim(Lane::Inference).await.unwrap().unwrap();
        assert_eq!(first["automatic"], true);
        drop(queue);
        drop(store);
        let queue = Queue::new(library(&root).await).await.unwrap();
        let resumed = queue.claim(Lane::Inference).await.unwrap().unwrap();
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

    #[tokio::test]
    async fn trabajo_legacy_en_espera_conserva_codigo_al_reabrir() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic").unwrap();
        let root = temp.path().join("library");
        let store = library(&root).await;
        let recording = store.import(&audio).await.unwrap();
        let old = json!({
            "id":"old-job", "recordingId":recording["id"], "operation":"processRecording",
            "args":{"recordingId":recording["id"]}, "state":"retry", "stage":"Esperando al servicio",
            "attempt":1, "createdAt":1, "startedAt":1, "nextAttemptAt":i64::MAX,
            "error":"BACKEND_UNAVAILABLE: modelo ausente", "externalReceipt":{"id":"receipt"}
        });
        store
            .with_store(move |store| Box::pin(async move { store.job_save(&old).await }))
            .await
            .unwrap();
        drop(store);
        let queue = Queue::new(library(&root).await).await.unwrap();
        let old = queue
            .jobs()
            .await
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == "old-job")
            .unwrap();
        assert_eq!(old["state"], "retry");
        assert_eq!(old["errorCode"], "backend_unavailable");
        queue
            .cancel(recording["id"].as_str().unwrap())
            .await
            .unwrap();
        let saved = queue
            .jobs()
            .await
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == "old-job")
            .unwrap();
        assert_eq!(saved["externalReceipt"]["id"], "receipt");
    }

    #[tokio::test]
    async fn a_waiting_service_does_not_hold_back_the_next_recording() {
        let temp = tempfile::tempdir().unwrap();
        let store = library(&temp.path().join("library")).await;
        let mut recordings = Vec::new();
        for name in ["one.wav", "two.wav"] {
            let path = temp.path().join(name);
            std::fs::write(&path, name.as_bytes()).unwrap();
            recordings.push(store.import(&path).await.unwrap());
        }
        let queue = Queue::new(store.clone()).await.unwrap();
        let first = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":recordings[0]["id"]}),
            )
            .await
            .unwrap();
        queue
            .enqueue(
                "processRecording",
                json!({"recordingId":recordings[1]["id"]}),
            )
            .await
            .unwrap();
        assert_eq!(
            queue.claim(Lane::Inference).await.unwrap().unwrap()["id"],
            first
        );
        queue
            .finish(
                &first,
                Err(AppError::new(ErrorCode::BackendUnavailable, "429")),
            )
            .await
            .unwrap();
        assert_eq!(
            queue.claim(Lane::Inference).await.unwrap().unwrap()["recordingId"],
            recordings[1]["id"]
        );
        assert_eq!(
            store
                .recording(recordings[0]["id"].as_str().unwrap().to_owned())
                .await
                .unwrap()["status"],
            "pending"
        );
    }

    #[tokio::test]
    async fn a_failed_dry_run_preserves_the_recording_and_does_not_disable_automatic_work() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic").unwrap();
        let store = library(&temp.path().join("library")).await;
        let record = store.import(&audio).await.unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        let id = queue
            .enqueue(
                "processRecording",
                json!({"recordingId":record["id"],"options":{"dryRun":true}}),
            )
            .await
            .unwrap();
        queue.claim(Lane::Inference).await.unwrap();
        queue
            .finish(&id, Err("Receta inválida".into()))
            .await
            .unwrap();
        assert_eq!(
            store
                .recording(record["id"].as_str().unwrap().to_owned())
                .await
                .unwrap(),
            record
        );
        queue.automatic().await.unwrap();
        let next = queue.claim(Lane::Inference).await.unwrap().unwrap();
        assert_ne!(next["id"], id);
        assert_eq!(next["args"]["options"]["force"], false);
    }

    async fn metadata(
        store: &Library,
        audio: &std::path::Path,
        started: std::time::SystemTime,
    ) -> Value {
        let audio = audio.to_owned();
        store
            .with_store(move |store| {
                Box::pin(async move {
                    store
                        .import_with_metadata(&audio, None, "Nota", started, "voiceMemos:test/1")
                        .await
                })
            })
            .await
            .unwrap()
    }
    #[tokio::test]
    async fn changed_audio_is_enqueued_again_after_a_completed_run() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"first contents").unwrap();
        let store = library(&temp.path().join("library")).await;
        let started = std::time::SystemTime::now();
        let record = metadata(&store, &audio, started).await;
        let queue = Queue::new(store.clone()).await.unwrap();
        queue.automatic().await.unwrap();
        let job = queue.claim(Lane::Inference).await.unwrap().unwrap();
        queue
            .finish(job["id"].as_str().unwrap(), Ok(Value::Null))
            .await
            .unwrap();
        std::fs::write(&audio, b"changed contents").unwrap();
        metadata(&store, &audio, started).await;
        queue.automatic().await.unwrap();
        let next = queue.claim(Lane::Inference).await.unwrap().unwrap();
        assert_eq!(next["recordingId"], record["id"]);
        assert_ne!(next["audioHash"], job["audioHash"]);
    }
}
