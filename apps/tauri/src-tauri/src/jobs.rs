use crate::error::{AppError, ErrorCode};
use crate::library::Library;
use crate::persistence::Persistence;
use crate::store::{self, Store};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tokio::sync::Notify;
use ts_rs::TS;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Retry,
    Failed,
    Succeeded,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::enum_variant_names)]
pub enum JobOperation {
    ProcessRecording,
    SummarizeRecording,
    PublishRecording,
    UnpublishRecording,
}
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct RecipeRef {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
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
    #[serde(default)]
    pub recipe: Option<RecipeRef>,
    pub state: JobState,
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    #[ts(type = "number")]
    pub attempt: u64,
    #[serde(default)]
    #[ts(type = "number")]
    pub created_at: i64,
    #[serde(default)]
    #[ts(type = "number")]
    pub started_at: i64,
    #[serde(default)]
    #[ts(type = "number | null")]
    pub finished_at: Option<i64>,
    #[serde(default)]
    #[ts(type = "number")]
    pub next_attempt_at: i64,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub error_code: Option<ErrorCode>,
    #[serde(default)]
    pub result: Option<Value>,
    #[serde(flatten)]
    #[ts(skip)]
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
    fn ended_at(&self) -> i64 {
        self.finished_at
            .unwrap_or_else(|| self.started_at.max(self.created_at))
    }
    fn end(&mut self) {
        self.finished_at = Some(chrono::Utc::now().timestamp_millis());
    }
}

pub fn recipe_for(
    args: &Value,
    note: Option<&str>,
    default: Option<&str>,
    recipes: &Value,
) -> Option<RecipeRef> {
    let requested = [args["options"]["recipeId"].as_str(), note, default]
        .into_iter()
        .flatten()
        .find(|value| !value.is_empty())?;
    let found = recipes.as_array().and_then(|recipes| {
        recipes
            .iter()
            .find(|recipe| recipe["id"] == requested || recipe["name"] == requested)
    });
    let field = |key: &str| {
        found
            .and_then(|recipe| recipe[key].as_str())
            .unwrap_or(requested)
            .to_owned()
    };
    Some(RecipeRef {
        id: field("id"),
        name: field("name"),
    })
}

fn recipe_of(store: &Store, job: &Job) -> Option<RecipeRef> {
    if job.operation != JobOperation::ProcessRecording {
        return None;
    }
    let note = store
        .data
        .recordings
        .iter()
        .find(|record| record.id == job.recording_id)
        .and_then(|record| record.recipe_id.as_ref().cloned());
    recipe_for(
        &job.args,
        note.as_deref(),
        store
            .data
            .settings
            .default_recipe_id
            .as_ref()
            .map(String::as_str),
        &store.data.recipes,
    )
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct HistoryCursor {
    #[ts(type = "number")]
    pub ended_at: i64,
    pub id: String,
}

#[derive(Debug, Default, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HistoryQuery {
    #[serde(default)]
    #[ts(optional)]
    pub before: Option<HistoryCursor>,
    #[serde(default)]
    #[ts(optional)]
    pub state: Option<JobState>,
    #[serde(default)]
    #[ts(optional)]
    pub recipe_id: Option<String>,
    #[serde(default)]
    #[ts(optional)]
    pub operation: Option<JobOperation>,
    #[ts(type = "number")]
    pub limit: usize,
}

#[derive(Debug, Serialize, TS)]
pub struct HistoryPage {
    pub jobs: Vec<Job>,
    pub recipes: Vec<RecipeRef>,
    pub next: Option<HistoryCursor>,
}

pub fn history_page(mut jobs: Vec<Job>, query: &HistoryQuery) -> HistoryPage {
    jobs.retain(|job| !job.active());
    jobs.sort_by(|a, b| (b.ended_at(), &b.id).cmp(&(a.ended_at(), &a.id)));
    let mut recipes: Vec<RecipeRef> = Vec::new();
    for recipe in jobs.iter().filter_map(|job| job.recipe.as_ref()) {
        if !recipes.iter().any(|known| known.id == recipe.id) {
            recipes.push(recipe.clone());
        }
    }
    let mut matching: Vec<Job> = jobs
        .into_iter()
        .filter(|job| query.state.is_none_or(|state| job.state == state))
        .filter(|job| {
            query
                .recipe_id
                .as_ref()
                .is_none_or(|id| job.recipe.as_ref().is_some_and(|recipe| &recipe.id == id))
        })
        .filter(|job| {
            query
                .operation
                .is_none_or(|operation| job.operation == operation)
        })
        .filter(|job| {
            query
                .before
                .as_ref()
                .is_none_or(|cursor| (job.ended_at(), &job.id) < (cursor.ended_at, &cursor.id))
        })
        .take(query.limit + 1)
        .collect();
    let next = if matching.len() > query.limit {
        matching.truncate(query.limit);
        matching.last().map(|job| HistoryCursor {
            ended_at: job.ended_at(),
            id: job.id.clone(),
        })
    } else {
        None
    };
    HistoryPage {
        jobs: matching,
        recipes,
        next,
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
async fn load_active(database: &Persistence) -> Result<Vec<Job>, String> {
    parse_all(database.jobs_active().await?)
}
async fn load_for(database: &Persistence, recording: &str) -> Result<Vec<Job>, String> {
    parse_all(database.jobs_for(recording).await?)
}
async fn load_one(database: &Persistence, id: &str) -> Result<Option<Job>, String> {
    database.job(id).await?.map(parse).transpose()
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
    for mut job in load_active(store.database()).await? {
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
    if let Some(job) = load_for(store.database(), &recording_id)
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
    let mut job = Job {
        id: id.clone(),
        recording_id,
        operation,
        args,
        automatic,
        audio_hash,
        recipe: None,
        state: JobState::Queued,
        stage: "En cola".into(),
        attempt: 0,
        created_at: time,
        started_at: time,
        finished_at: None,
        next_attempt_at: 0,
        error: None,
        error_code: None,
        result: None,
        extra: Map::new(),
    };
    job.recipe = recipe_of(store, &job);
    save(store, &job).await?;
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
        let handled = load_for(store.database(), &id).await?.iter().any(|job| {
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
    let mut jobs = load_active(store.database()).await?;
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
        job.end();
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
    job.started_at = now;
    job.recipe = recipe_of(store, &job);
    save(store, &job).await?;
    value(job).map(Claimed::Job)
}

pub(crate) async fn finish(
    store: &mut Store,
    id: &str,
    result: Result<Value, AppError>,
) -> Result<Option<Lane>, String> {
    let Some(mut job) = load_one(store.database(), id).await? else {
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
            job.end();
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
            } else {
                job.end();
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
    for mut job in load_active(store.database())
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
    for mut job in load_for(store.database(), recording)
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
        job.end();
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

pub(crate) async fn busy(database: &Persistence, recording: &str) -> Result<bool, String> {
    Ok(load_for(database, recording).await?.iter().any(Job::active))
}

pub(crate) async fn visible(database: &Persistence) -> Result<Vec<Value>, String> {
    let mut active = load_active(database).await?;
    active.sort_by_key(|job| job.created_at);
    active.into_iter().map(value).collect()
}

pub(crate) async fn history(
    database: &Persistence,
    query: &HistoryQuery,
) -> Result<HistoryPage, String> {
    Ok(history_page(
        parse_all(database.jobs_finished().await?)?,
        query,
    ))
}

pub(crate) async fn find(database: &Persistence, id: &str) -> Result<Option<Job>, String> {
    load_one(database, id).await
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
    pub async fn history(&self, query: HistoryQuery) -> Result<HistoryPage, String> {
        self.library.job_history(query).await
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
            recipe: None,
            state,
            stage: String::new(),
            attempt: 0,
            created_at: created,
            started_at: created,
            finished_at: None,
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
        let failed = history(&queue)
            .await
            .into_iter()
            .find(|item| item.id == job)
            .unwrap();
        assert_eq!(failed.state, JobState::Failed);
        assert!(failed.finished_at.is_some());
        assert!(failed
            .error
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
                    let mut job = load_one(store.database(), &waiting).await.unwrap().unwrap();
                    job.next_attempt_at = 0;
                    save(store, &job).await.unwrap();
                })
            })
            .await;
        assert!(queue.claim(Lane::Inference).await.unwrap().is_none());
        let failed = history(&queue)
            .await
            .into_iter()
            .find(|job| job.id == id)
            .unwrap();
        assert_eq!(failed.state, JobState::Failed);
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
        store.close().await.unwrap();
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
        store.close().await.unwrap();
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
        store.close().await.unwrap();
        drop(store);
        let queue = Queue::new(library(&root).await).await.unwrap();
        let old = queue.visible()[0].clone();
        assert_eq!(old["id"], "old-job");
        assert_eq!(old["state"], "retry");
        assert_eq!(old["errorCode"], "backend_unavailable");
        queue
            .cancel(recording["id"].as_str().unwrap())
            .await
            .unwrap();
        let saved = history(&queue)
            .await
            .into_iter()
            .find(|job| job.id == "old-job")
            .unwrap();
        assert_eq!(saved.extra["externalReceipt"]["id"], "receipt");
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

    fn recipes() -> Value {
        json!([{"id":"default","name":"Por defecto"},{"id":"resumen","name":"Resumen"}])
    }

    #[test]
    fn la_receta_de_un_trabajo_sigue_la_misma_prioridad_que_el_runtime() {
        let chosen = |args: Value, note: Option<&str>, default: Option<&str>| {
            recipe_for(&args, note, default, &recipes())
        };
        let resumen = Some(RecipeRef {
            id: "resumen".into(),
            name: "Resumen".into(),
        });
        assert_eq!(
            chosen(
                json!({"options":{"recipeId":"resumen"}}),
                Some("default"),
                Some("default")
            ),
            resumen
        );
        assert_eq!(chosen(json!({}), Some("resumen"), Some("default")), resumen);
        assert_eq!(
            chosen(json!({"options":{"recipeId":""}}), None, Some("resumen")),
            resumen
        );
        assert_eq!(chosen(json!({}), None, Some("Resumen")), resumen);
        assert_eq!(
            chosen(json!({}), Some("borrada"), Some("default")),
            Some(RecipeRef {
                id: "borrada".into(),
                name: "borrada".into(),
            })
        );
        assert_eq!(chosen(json!({}), None, None), None);
    }

    fn finished(
        id: &str,
        operation: JobOperation,
        state: JobState,
        ended: i64,
        recipe: Option<(&str, &str)>,
    ) -> Job {
        let mut job = job(id, &format!("nota-{id}"), operation, state, ended - 10);
        job.finished_at = Some(ended);
        job.recipe = recipe.map(|(id, name)| RecipeRef {
            id: id.into(),
            name: name.into(),
        });
        job
    }

    fn page(jobs: Vec<Job>, query: HistoryQuery) -> (Vec<String>, Option<HistoryCursor>) {
        let page = history_page(jobs, &query);
        (page.jobs.into_iter().map(|job| job.id).collect(), page.next)
    }

    fn query(limit: usize) -> HistoryQuery {
        HistoryQuery {
            limit,
            ..HistoryQuery::default()
        }
    }

    #[test]
    fn el_historial_va_del_mas_reciente_al_mas_antiguo_sin_los_activos() {
        let mut legacy = job(
            "antiguo",
            "nota",
            JobOperation::PublishRecording,
            JobState::Succeeded,
            25,
        );
        legacy.started_at = 25;
        let jobs = vec![
            finished(
                "a",
                JobOperation::ProcessRecording,
                JobState::Succeeded,
                10,
                None,
            ),
            job(
                "activo",
                "x",
                JobOperation::ProcessRecording,
                JobState::Running,
                50,
            ),
            job(
                "cola",
                "y",
                JobOperation::PublishRecording,
                JobState::Queued,
                60,
            ),
            job(
                "espera",
                "z",
                JobOperation::ProcessRecording,
                JobState::Retry,
                70,
            ),
            finished(
                "c",
                JobOperation::ProcessRecording,
                JobState::Failed,
                30,
                None,
            ),
            legacy,
            finished(
                "b",
                JobOperation::SummarizeRecording,
                JobState::Cancelled,
                20,
                None,
            ),
        ];
        assert_eq!(page(jobs, query(100)).0, vec!["c", "antiguo", "b", "a"]);
    }

    #[test]
    fn el_historial_se_carga_por_paginas_sin_repetir_ni_saltarse_ninguno() {
        let jobs: Vec<Job> = (0..250)
            .map(|index| {
                finished(
                    &format!("j{index:03}"),
                    JobOperation::ProcessRecording,
                    JobState::Succeeded,
                    1_000 + index / 2,
                    None,
                )
            })
            .collect();
        let mut seen = Vec::new();
        let mut cursor = None;
        let mut pages = 0;
        loop {
            let (ids, next) = page(
                jobs.clone(),
                HistoryQuery {
                    before: cursor.clone(),
                    ..query(100)
                },
            );
            pages += 1;
            assert!(ids.len() <= 100);
            seen.extend(ids);
            match next {
                Some(next) => cursor = Some(next),
                None => break,
            }
        }
        assert_eq!(pages, 3);
        let mut expected: Vec<String> = (0..250).map(|index| format!("j{index:03}")).collect();
        expected.reverse();
        assert_eq!(seen, expected);
    }

    #[test]
    fn el_historial_filtra_por_estado_receta_y_accion_manual() {
        let jobs = vec![
            finished(
                "ok",
                JobOperation::ProcessRecording,
                JobState::Succeeded,
                50,
                Some(("resumen", "Resumen")),
            ),
            finished(
                "mal",
                JobOperation::ProcessRecording,
                JobState::Failed,
                40,
                Some(("default", "Por defecto")),
            ),
            finished(
                "pub",
                JobOperation::PublishRecording,
                JobState::Failed,
                30,
                None,
            ),
            finished(
                "off",
                JobOperation::UnpublishRecording,
                JobState::Cancelled,
                20,
                None,
            ),
            finished(
                "viejo",
                JobOperation::ProcessRecording,
                JobState::Failed,
                10,
                Some(("resumen", "Resumen antiguo")),
            ),
        ];
        let failed = HistoryQuery {
            state: Some(JobState::Failed),
            ..query(100)
        };
        assert_eq!(page(jobs.clone(), failed).0, vec!["mal", "pub", "viejo"]);
        let resumen = HistoryQuery {
            recipe_id: Some("resumen".into()),
            ..query(100)
        };
        assert_eq!(page(jobs.clone(), resumen).0, vec!["ok", "viejo"]);
        let publish = HistoryQuery {
            operation: Some(JobOperation::PublishRecording),
            ..query(100)
        };
        assert_eq!(page(jobs.clone(), publish).0, vec!["pub"]);
        let nothing = HistoryQuery {
            state: Some(JobState::Cancelled),
            operation: Some(JobOperation::PublishRecording),
            ..query(100)
        };
        assert_eq!(page(jobs.clone(), nothing), (vec![], None));
        assert_eq!(
            history_page(jobs, &query(1)).recipes,
            vec![
                RecipeRef {
                    id: "resumen".into(),
                    name: "Resumen".into(),
                },
                RecipeRef {
                    id: "default".into(),
                    name: "Por defecto".into(),
                },
            ]
        );
    }

    #[test]
    fn el_historial_no_acepta_estados_activos_como_filtro() {
        let jobs = vec![job(
            "activo",
            "x",
            JobOperation::ProcessRecording,
            JobState::Running,
            1,
        )];
        let running = HistoryQuery {
            state: Some(JobState::Running),
            ..query(100)
        };
        assert!(history_page(jobs, &running).jobs.is_empty());
    }

    async fn history(queue: &Queue) -> Vec<Job> {
        queue
            .history(HistoryQuery {
                limit: 1_000,
                ..HistoryQuery::default()
            })
            .await
            .unwrap()
            .jobs
    }

    #[tokio::test]
    async fn un_trabajo_guarda_su_receta_y_cuando_empezo_y_acabo() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library")).await;
        let record = store.import(&audio).await.unwrap();
        let id = record["id"].as_str().unwrap().to_owned();
        store
            .mutate(
                "config_save".into(),
                json!({"collection":"recipes","item":{"id":"resumen","name":"Resumen","kind":"form","values":{}}}),
            )
            .await
            .unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        let job = queue
            .enqueue("processRecording", json!({"recordingId":id}))
            .await
            .unwrap();
        let queued = queue.visible();
        assert_eq!(
            queued[0]["recipe"],
            json!({"id":"default","name":"Por defecto"})
        );
        assert_eq!(queued[0]["finishedAt"], Value::Null);
        store
            .mutate(
                "recording_update".into(),
                json!({"id":id,"recipeId":"resumen"}),
            )
            .await
            .unwrap();
        let before = chrono::Utc::now().timestamp_millis();
        let running = queue.claim(Lane::Inference).await.unwrap().unwrap();
        assert_eq!(running["recipe"], json!({"id":"resumen","name":"Resumen"}));
        assert_eq!(running["args"], json!({"recordingId":id}));
        assert!(running["startedAt"].as_i64().unwrap() >= before);
        queue.finish(&job, Ok(Value::Null)).await.unwrap();
        store
            .mutate(
                "config_save".into(),
                json!({"collection":"recipes","item":{"id":"resumen","name":"Resumen corto","kind":"form","values":{}}}),
            )
            .await
            .unwrap();
        let done = history(&queue).await.remove(0);
        assert_eq!(done.state, JobState::Succeeded);
        assert_eq!(done.recipe.unwrap().name, "Resumen");
        assert!(done.finished_at.unwrap() >= done.started_at);
    }

    #[tokio::test]
    async fn las_acciones_manuales_no_tienen_receta_y_cancelar_marca_el_final() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("note.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = library(&temp.path().join("library")).await;
        let record = store.import(&audio).await.unwrap();
        let queue = Queue::new(store.clone()).await.unwrap();
        queue
            .enqueue(
                "publishRecording",
                json!({"recordingId":record["id"],"destinationId":"d"}),
            )
            .await
            .unwrap();
        assert_eq!(queue.visible()[0]["recipe"], Value::Null);
        queue.cancel(record["id"].as_str().unwrap()).await.unwrap();
        let cancelled = history(&queue).await.remove(0);
        assert_eq!(cancelled.state, JobState::Cancelled);
        assert!(cancelled.finished_at.is_some());
        assert!(queue.visible().as_array().unwrap().is_empty());
    }
}
