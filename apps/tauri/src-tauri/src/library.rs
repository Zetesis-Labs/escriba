use crate::error::AppError;
use crate::jobs::{self, Cancellation, Claimed, Job, Lane};
use crate::persistence::CoreChange;
use crate::store::{IndexView, StagedAudio, Store};
use crate::voices::SpeakerVoice;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::sync::{watch, Mutex};

#[derive(Clone)]
struct Published {
    index: IndexView,
    active_jobs: Arc<Vec<Value>>,
}

async fn publication(store: &Store) -> Result<Published, String> {
    Ok(Published {
        index: store.index_view(),
        active_jobs: Arc::new(jobs::visible(store).await?),
    })
}

#[derive(Clone)]
pub struct Library {
    store: Arc<Mutex<Store>>,
    published: Arc<watch::Sender<Published>>,
    #[cfg(test)]
    checkpoint: Arc<std::sync::Mutex<Option<Checkpoint>>>,
}

impl Library {
    pub async fn new(store: Store) -> Result<Self, String> {
        let (published, _) = watch::channel(publication(&store).await?);
        Ok(Self {
            store: Arc::new(Mutex::new(store)),
            published: Arc::new(published),
            #[cfg(test)]
            checkpoint: Arc::default(),
        })
    }

    pub fn index(&self) -> IndexView {
        self.published.borrow().index.clone()
    }

    pub fn active_jobs(&self) -> Arc<Vec<Value>> {
        self.published.borrow().active_jobs.clone()
    }

    async fn read<R>(
        &self,
        operation: impl AsyncFnOnce(&Store) -> Result<R, String>,
    ) -> Result<R, String> {
        let store = self.store.lock().await;
        operation(&store).await
    }

    async fn write<R>(
        &self,
        operation: impl AsyncFnOnce(&mut Store) -> Result<R, String>,
    ) -> Result<R, String> {
        let mut store = self.store.lock().await;
        #[cfg(test)]
        reach(&self.checkpoint).await;
        let result = operation(&mut store).await;
        let state = publication(&store).await.map_err(|e| {
            format!("La biblioteca guardó el cambio pero no pudo leer los trabajos activos: {e}")
        })?;
        self.published.send_replace(state);
        result
    }

    pub async fn snapshot(&self) -> Result<Value, String> {
        self.read(async |store| store.snapshot().await).await
    }

    pub async fn recording(&self, id: String) -> Result<Value, String> {
        self.read(async move |store| store.recording(&id).await)
            .await
    }

    pub async fn runtime_context(&self, recording: Option<String>) -> Result<Value, String> {
        self.read(async move |store| store.runtime_context(recording.as_deref()).await)
            .await
    }

    pub async fn log_list(&self, params: Value) -> Result<Value, String> {
        self.read(async move |store| store.log_list(&params).await)
            .await
    }

    pub async fn memory_recall(
        &self,
        recording: String,
        version: String,
        fingerprint: String,
    ) -> Result<Option<Value>, String> {
        self.read(async move |store| {
            store
                .memory_recall(&recording, &version, &fingerprint)
                .await
        })
        .await
    }

    pub async fn trace_list(&self, recording: Option<String>) -> Result<Vec<Value>, String> {
        self.read(async move |store| store.trace_list(recording.as_deref()).await)
            .await
    }

    pub async fn people(&self) -> Result<Value, String> {
        self.read(async |store| store.people().await).await
    }

    pub async fn knowledge_change(&self) -> Result<Option<CoreChange>, String> {
        self.read(async |store| store.knowledge_change().await)
            .await
    }

    pub async fn job(&self, id: String) -> Result<Option<Job>, String> {
        self.read(async move |store| jobs::find(store, &id).await)
            .await
    }

    pub async fn job_history(&self) -> Result<Vec<Value>, String> {
        self.read(async |store| jobs::history(store).await).await
    }

    pub async fn mutate(&self, method: String, params: Value) -> Result<Value, String> {
        self.write(async move |store| store.mutate(&method, &params).await)
            .await
    }

    pub async fn remove_audio(&self, params: Value) -> Result<Value, String> {
        self.write(async move |store| {
            if jobs::busy(store, crate::store::text(&params, "id")?).await? {
                return Err("Cancela el trabajo antes de quitar su audio".into());
            }
            store.mutate("recording_remove_audio", &params).await
        })
        .await
    }

    pub async fn import_staged(
        &self,
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
    ) -> Result<Value, String> {
        self.write(async move |store| {
            store
                .import_staged(staged, &source, recipe.as_deref())
                .await
        })
        .await
    }

    pub async fn import_recorded(
        &self,
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
        update: Value,
    ) -> Result<Value, String> {
        self.write(async move |store| {
            let record = store
                .import_staged(staged, &source, recipe.as_deref())
                .await?;
            let mut update = update;
            update["id"] = record["id"].clone();
            store.mutate("recording_update", &update).await
        })
        .await
    }

    pub async fn import_watched(
        &self,
        staged: StagedAudio,
        source: PathBuf,
        title: String,
        started_at: SystemTime,
        source_key: String,
    ) -> Result<Value, String> {
        self.write(async move |store| {
            store
                .import_staged_with_metadata(staged, &source, &title, started_at, &source_key)
                .await
        })
        .await
    }

    pub async fn save_credential(&self, key: String, value: String) -> Result<(), String> {
        self.write(async move |store| store.save_credential(&key, &value))
            .await
    }

    pub async fn remove_connector(&self, id: String) -> Result<(), String> {
        self.write(async move |store| store.remove_connector(&id).await)
            .await
    }

    pub async fn save_connector(&self, account: Value, destination: Value) -> Result<(), String> {
        self.write(async move |store| store.save_connector(&account, &destination).await)
            .await
    }

    pub async fn set_person_color(&self, name: String, color: String) -> Result<(), String> {
        self.write(async move |store| store.set_person_color(&name, &color).await)
            .await
    }

    pub async fn rename_person(&self, name: String, new_name: String) -> Result<(), String> {
        self.write(async move |store| store.rename_person(&name, &new_name).await)
            .await
    }

    pub async fn remove_person(&self, name: String) -> Result<(), String> {
        self.write(async move |store| store.remove_person(&name).await)
            .await
    }

    pub async fn remove_person_voice(&self, id: String) -> Result<(), String> {
        self.write(async move |store| store.remove_person_voice(&id).await)
            .await
    }

    pub async fn add_person_voice(
        &self,
        name: String,
        voice: SpeakerVoice,
        source: String,
    ) -> Result<(), String> {
        self.write(async move |store| store.add_person_voice(&name, &voice, &source).await)
            .await
    }

    pub async fn memory_keep(
        &self,
        recording: String,
        version: String,
        fingerprint: String,
        value: Value,
    ) -> Result<(), String> {
        self.write(async move |store| {
            store
                .memory_keep(&recording, &version, &fingerprint, &value)
                .await
        })
        .await
    }

    pub async fn trace_save(&self, trace: Value) -> Result<(), String> {
        self.write(async move |store| store.trace_save(&trace).await)
            .await
    }

    pub async fn recognize_transcription(
        &self,
        recording: String,
        transcript: Value,
    ) -> Result<Value, String> {
        self.write(async move |store| store.recognize_transcription(&recording, transcript).await)
            .await
    }

    pub async fn authorize_watched_folder(
        &self,
        folder: Option<String>,
        path: PathBuf,
        name: Option<String>,
        style: String,
        bookmark: Vec<u8>,
    ) -> Result<Value, String> {
        self.write(async move |store| {
            store
                .authorize_watched_folder(
                    folder.as_deref(),
                    &path,
                    name.as_deref(),
                    &style,
                    &bookmark,
                )
                .await
        })
        .await
    }

    pub async fn refresh_watched_folder_bookmark(
        &self,
        folder: String,
        previous: Vec<u8>,
        resolved: PathBuf,
        replacement: Option<Vec<u8>>,
    ) -> Result<bool, String> {
        self.write(async move |store| {
            store
                .refresh_watched_folder_bookmark(
                    &folder,
                    &previous,
                    &resolved,
                    replacement.as_deref(),
                )
                .await
        })
        .await
    }

    pub async fn seed_voice_memos(&self, root: PathBuf) -> Result<bool, String> {
        self.write(async move |store| store.seed_voice_memos(&root).await)
            .await
    }

    pub async fn install(&self, package: Value) -> Result<(), String> {
        self.write(async move |store| crate::catalog::install(store, &package).await)
            .await
    }

    pub async fn knowledge_prepare(&self, epoch: String) -> Result<(), String> {
        self.write(async move |store| store.knowledge_prepare(&epoch).await)
            .await
    }

    pub async fn knowledge_ack(&self, key: String, revision: String) -> Result<(), String> {
        self.write(async move |store| store.knowledge_ack(&key, &revision).await)
            .await
    }

    pub async fn recover_jobs(&self) -> Result<(), String> {
        self.write(async |store| jobs::recover(store).await).await
    }

    pub async fn enqueue_job(
        &self,
        operation: String,
        args: Value,
        automatic: bool,
    ) -> Result<(String, Lane), String> {
        self.write(async move |store| jobs::enqueue(store, &operation, args, automatic).await)
            .await
    }

    pub async fn enqueue_automatic_jobs(&self) -> Result<bool, String> {
        self.write(async |store| jobs::automatic(store).await).await
    }

    pub async fn claim_job(&self, lane: Lane, now: i64) -> Result<Claimed, String> {
        self.write(async move |store| jobs::claim(store, lane, now).await)
            .await
    }

    pub async fn finish_job(
        &self,
        id: String,
        result: Result<Value, AppError>,
    ) -> Result<Option<Lane>, String> {
        self.write(async move |store| jobs::finish(store, &id, result).await)
            .await
    }

    pub async fn job_stages(&self, stages: Value) -> Result<(), String> {
        self.write(async move |store| jobs::stages(store, &stages).await)
            .await
    }

    pub async fn cancel_jobs(&self, recording: String) -> Result<Cancellation, String> {
        self.write(async move |store| jobs::cancel(store, &recording).await)
            .await
    }
}

#[cfg(test)]
impl Library {
    pub(crate) async fn with_store<R: Send + 'static>(
        &self,
        operation: impl for<'a> FnOnce(&'a mut Store) -> futures_util::future::BoxFuture<'a, R>
            + Send
            + 'static,
    ) -> R {
        let mut store = self.store.lock().await;
        let result = operation(&mut store).await;
        self.published.send_replace(
            publication(&store)
                .await
                .expect("No se pudo publicar la biblioteca"),
        );
        result
    }

    pub(crate) async fn import(&self, audio: &std::path::Path) -> Result<Value, String> {
        let audio = audio.to_owned();
        self.with_store(move |store| Box::pin(async move { store.import(&audio, None).await }))
            .await
    }

    pub(crate) fn stop_next_write(&self) -> Stopped {
        let (parked, reached) = tokio::sync::oneshot::channel();
        let (release, released) = tokio::sync::oneshot::channel();
        *self.checkpoint.lock().expect("Punto de control envenenado") = Some(Checkpoint::Stop {
            parked,
            release: released,
        });
        Stopped {
            parked: Some(reached),
            _release: release,
        }
    }

    pub(crate) fn panic_next_write(&self) {
        *self.checkpoint.lock().expect("Punto de control envenenado") = Some(Checkpoint::Panic);
    }
}

#[cfg(test)]
enum Checkpoint {
    Stop {
        parked: tokio::sync::oneshot::Sender<()>,
        release: tokio::sync::oneshot::Receiver<()>,
    },
    Panic,
}

#[cfg(test)]
async fn reach(checkpoint: &std::sync::Mutex<Option<Checkpoint>>) {
    let checkpoint = checkpoint
        .lock()
        .expect("Punto de control envenenado")
        .take();
    match checkpoint {
        Some(Checkpoint::Stop { parked, release }) => {
            let _ = parked.send(());
            let _ = release.await;
        }
        Some(Checkpoint::Panic) => panic!("Pánico provocado por la prueba"),
        None => {}
    }
}

#[cfg(test)]
pub(crate) struct Stopped {
    parked: Option<tokio::sync::oneshot::Receiver<()>>,
    _release: tokio::sync::oneshot::Sender<()>,
}

#[cfg(test)]
impl Stopped {
    pub(crate) async fn parked(&mut self) {
        if let Some(parked) = self.parked.take() {
            parked
                .await
                .expect("La escritura no llegó al punto de control");
        }
    }
}

#[cfg(test)]
mod tests;
