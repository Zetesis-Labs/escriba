use crate::error::AppError;
use crate::jobs::{self, Cancellation, Claimed, Job, Lane};
use crate::persistence::CoreChange;
use crate::store::{IndexView, StagedAudio, Store};
use crate::voices::SpeakerVoice;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;
use tokio::sync::watch;

#[derive(Clone)]
struct Published {
    index: IndexView,
    active_jobs: Arc<Vec<Value>>,
}

fn publication(store: &Store) -> Result<Published, String> {
    Ok(Published {
        index: store.index_view(),
        active_jobs: Arc::new(jobs::visible(store)?),
    })
}

fn unavailable() -> String {
    "No se pudo acceder a la biblioteca".into()
}

#[derive(Clone)]
pub struct Library {
    store: Arc<Mutex<Store>>,
    published: Arc<watch::Sender<Published>>,
}

impl Library {
    pub fn new(store: Store) -> Result<Self, String> {
        let (published, _) = watch::channel(publication(&store)?);
        Ok(Self {
            store: Arc::new(Mutex::new(store)),
            published: Arc::new(published),
        })
    }

    pub fn index(&self) -> IndexView {
        self.published.borrow().index.clone()
    }

    pub fn active_jobs(&self) -> Arc<Vec<Value>> {
        self.published.borrow().active_jobs.clone()
    }

    async fn read<R: Send + 'static>(
        &self,
        operation: impl FnOnce(&Store) -> Result<R, String> + Send + 'static,
    ) -> Result<R, String> {
        let store = self.store.clone();
        tokio::task::spawn_blocking(move || operation(&*store.lock().map_err(|_| unavailable())?))
            .await
            .map_err(|e| e.to_string())?
    }

    async fn write<R: Send + 'static>(
        &self,
        operation: impl FnOnce(&mut Store) -> Result<R, String> + Send + 'static,
    ) -> Result<R, String> {
        let store = self.store.clone();
        let published = self.published.clone();
        tokio::task::spawn_blocking(move || {
            let mut store = store.lock().map_err(|_| unavailable())?;
            let result = operation(&mut store);
            let state = publication(&store).map_err(|e| {
                format!(
                    "La biblioteca guardó el cambio pero no pudo leer los trabajos activos: {e}"
                )
            })?;
            published.send_replace(state);
            result
        })
        .await
        .map_err(|e| e.to_string())?
    }

    pub async fn snapshot(&self) -> Result<Value, String> {
        self.read(|store| store.snapshot()).await
    }

    pub async fn recording(&self, id: String) -> Result<Value, String> {
        self.read(move |store| store.recording(&id)).await
    }

    pub async fn runtime_context(&self, recording: Option<String>) -> Result<Value, String> {
        self.read(move |store| store.runtime_context(recording.as_deref()))
            .await
    }

    pub async fn log_list(&self, params: Value) -> Result<Value, String> {
        self.read(move |store| store.log_list(&params)).await
    }

    pub async fn memory_recall(
        &self,
        recording: String,
        version: String,
        fingerprint: String,
    ) -> Result<Option<Value>, String> {
        self.read(move |store| store.memory_recall(&recording, &version, &fingerprint))
            .await
    }

    pub async fn trace_list(&self, recording: Option<String>) -> Result<Vec<Value>, String> {
        self.read(move |store| store.trace_list(recording.as_deref()))
            .await
    }

    pub async fn people(&self) -> Result<Value, String> {
        self.read(|store| store.people()).await
    }

    pub async fn knowledge_change(&self) -> Result<Option<CoreChange>, String> {
        self.read(|store| store.knowledge_change()).await
    }

    pub async fn job(&self, id: String) -> Result<Option<Job>, String> {
        self.read(move |store| jobs::find(store, &id)).await
    }

    pub async fn job_history(&self) -> Result<Vec<Value>, String> {
        self.read(jobs::history).await
    }

    pub async fn mutate(&self, method: String, params: Value) -> Result<Value, String> {
        self.write(move |store| store.mutate(&method, &params))
            .await
    }

    pub async fn remove_audio(&self, params: Value) -> Result<Value, String> {
        self.write(move |store| {
            if jobs::busy(store, crate::store::text(&params, "id")?)? {
                return Err("Cancela el trabajo antes de quitar su audio".into());
            }
            store.mutate("recording_remove_audio", &params)
        })
        .await
    }

    pub async fn import_staged(
        &self,
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
    ) -> Result<Value, String> {
        self.write(move |store| store.import_staged(staged, &source, recipe.as_deref()))
            .await
    }

    pub async fn import_recorded(
        &self,
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
        update: Value,
    ) -> Result<Value, String> {
        self.write(move |store| {
            let record = store.import_staged(staged, &source, recipe.as_deref())?;
            let mut update = update;
            update["id"] = record["id"].clone();
            store.mutate("recording_update", &update)
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
        self.write(move |store| {
            store.import_staged_with_metadata(staged, &source, &title, started_at, &source_key)
        })
        .await
    }

    pub async fn save_credential(&self, key: String, value: String) -> Result<(), String> {
        self.write(move |store| store.save_credential(&key, &value))
            .await
    }

    pub async fn remove_connector(&self, id: String) -> Result<(), String> {
        self.write(move |store| store.remove_connector(&id)).await
    }

    pub async fn save_connector(&self, account: Value, destination: Value) -> Result<(), String> {
        self.write(move |store| store.save_connector(&account, &destination))
            .await
    }

    pub async fn set_person_color(&self, name: String, color: String) -> Result<(), String> {
        self.write(move |store| store.set_person_color(&name, &color))
            .await
    }

    pub async fn rename_person(&self, name: String, new_name: String) -> Result<(), String> {
        self.write(move |store| store.rename_person(&name, &new_name))
            .await
    }

    pub async fn remove_person(&self, name: String) -> Result<(), String> {
        self.write(move |store| store.remove_person(&name)).await
    }

    pub async fn remove_person_voice(&self, id: String) -> Result<(), String> {
        self.write(move |store| store.remove_person_voice(&id))
            .await
    }

    pub async fn add_person_voice(
        &self,
        name: String,
        voice: SpeakerVoice,
        source: String,
    ) -> Result<(), String> {
        self.write(move |store| store.add_person_voice(&name, &voice, &source))
            .await
    }

    pub async fn memory_keep(
        &self,
        recording: String,
        version: String,
        fingerprint: String,
        value: Value,
    ) -> Result<(), String> {
        self.write(move |store| store.memory_keep(&recording, &version, &fingerprint, &value))
            .await
    }

    pub async fn trace_save(&self, trace: Value) -> Result<(), String> {
        self.write(move |store| store.trace_save(&trace)).await
    }

    pub async fn recognize_transcription(
        &self,
        recording: String,
        transcript: Value,
    ) -> Result<Value, String> {
        self.write(move |store| store.recognize_transcription(&recording, transcript))
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
        self.write(move |store| {
            store.authorize_watched_folder(
                folder.as_deref(),
                &path,
                name.as_deref(),
                &style,
                &bookmark,
            )
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
        self.write(move |store| {
            store.refresh_watched_folder_bookmark(
                &folder,
                &previous,
                &resolved,
                replacement.as_deref(),
            )
        })
        .await
    }

    pub async fn seed_voice_memos(&self, root: PathBuf) -> Result<bool, String> {
        self.write(move |store| store.seed_voice_memos(&root)).await
    }

    pub async fn install(&self, package: Value) -> Result<(), String> {
        self.write(move |store| crate::catalog::install(store, &package))
            .await
    }

    pub async fn knowledge_prepare(&self, epoch: String) -> Result<(), String> {
        self.write(move |store| store.knowledge_prepare(&epoch))
            .await
    }

    pub async fn knowledge_ack(&self, key: String, revision: String) -> Result<(), String> {
        self.write(move |store| store.knowledge_ack(&key, &revision))
            .await
    }

    pub async fn recover_jobs(&self) -> Result<(), String> {
        self.write(jobs::recover).await
    }

    pub async fn enqueue_job(
        &self,
        operation: String,
        args: Value,
        automatic: bool,
    ) -> Result<(String, Lane), String> {
        self.write(move |store| jobs::enqueue(store, &operation, args, automatic))
            .await
    }

    pub async fn enqueue_automatic_jobs(&self) -> Result<bool, String> {
        self.write(jobs::automatic).await
    }

    pub async fn claim_job(&self, lane: Lane, now: i64) -> Result<Claimed, String> {
        self.write(move |store| jobs::claim(store, lane, now)).await
    }

    pub async fn finish_job(
        &self,
        id: String,
        result: Result<Value, AppError>,
    ) -> Result<Option<Lane>, String> {
        self.write(move |store| jobs::finish(store, &id, result))
            .await
    }

    pub async fn job_stages(&self, stages: Value) -> Result<(), String> {
        self.write(move |store| jobs::stages(store, &stages)).await
    }

    pub async fn cancel_jobs(&self, recording: String) -> Result<Cancellation, String> {
        self.write(move |store| jobs::cancel(store, &recording))
            .await
    }
}

#[cfg(test)]
pub(crate) struct Locked<'a> {
    store: std::sync::MutexGuard<'a, Store>,
    published: &'a watch::Sender<Published>,
}

#[cfg(test)]
impl std::ops::Deref for Locked<'_> {
    type Target = Store;
    fn deref(&self) -> &Store {
        &self.store
    }
}

#[cfg(test)]
impl std::ops::DerefMut for Locked<'_> {
    fn deref_mut(&mut self) -> &mut Store {
        &mut self.store
    }
}

#[cfg(test)]
impl Drop for Locked<'_> {
    fn drop(&mut self) {
        self.published
            .send_replace(publication(&self.store).expect("No se pudo publicar la biblioteca"));
    }
}

#[cfg(test)]
impl Library {
    pub(crate) fn lock(&self) -> Result<Locked<'_>, String> {
        Ok(Locked {
            store: self.store.lock().map_err(|_| unavailable())?,
            published: &self.published,
        })
    }
}
