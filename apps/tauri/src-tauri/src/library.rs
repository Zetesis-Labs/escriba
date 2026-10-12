use crate::error::AppError;
use crate::jobs::{self, Cancellation, Claimed, Job, Lane};
use crate::persistence::{CoreChange, Persistence};
use crate::store::{IndexView, StagedAudio, Store};
use crate::voices::SpeakerVoice;
use futures_util::FutureExt;
use serde_json::Value;
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::sync::{mpsc, oneshot, watch};

#[derive(Clone)]
struct Published {
    index: IndexView,
    active_jobs: Arc<Vec<Value>>,
}

async fn publication(store: &Store) -> Result<Published, String> {
    Ok(Published {
        index: store.index_view(),
        active_jobs: Arc::new(jobs::visible(store.database()).await?),
    })
}

type Reply<T> = oneshot::Sender<Result<T, String>>;

enum Order {
    Mutate {
        method: String,
        params: Value,
        reply: Reply<Value>,
    },
    Log {
        params: Value,
        reply: Option<Reply<Value>>,
    },
    RemoveAudio {
        params: Value,
        reply: Reply<Value>,
    },
    ImportStaged {
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
        reply: Reply<Value>,
    },
    ImportRecorded {
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
        update: Value,
        reply: Reply<Value>,
    },
    ImportWatched {
        staged: StagedAudio,
        source: PathBuf,
        title: String,
        started_at: SystemTime,
        source_key: String,
        reply: Reply<Value>,
    },
    SaveCredential {
        key: String,
        value: String,
        reply: Reply<()>,
    },
    RemoveConnector {
        id: String,
        reply: Reply<()>,
    },
    SaveConnector {
        account: Value,
        destination: Value,
        reply: Reply<()>,
    },
    SetPersonColor {
        name: String,
        color: String,
        reply: Reply<()>,
    },
    RenamePerson {
        name: String,
        new_name: String,
        reply: Reply<()>,
    },
    RemovePerson {
        name: String,
        reply: Reply<()>,
    },
    RemovePersonVoice {
        id: String,
        reply: Reply<()>,
    },
    AddPersonVoice {
        name: String,
        voice: SpeakerVoice,
        source: String,
        reply: Reply<()>,
    },
    MemoryKeep {
        recording: String,
        version: String,
        fingerprint: String,
        value: Value,
        reply: Reply<()>,
    },
    TraceSave {
        trace: Value,
        reply: Reply<()>,
    },
    RecognizeTranscription {
        recording: String,
        transcript: Value,
        reply: Reply<Value>,
    },
    AuthorizeWatchedFolder {
        folder: Option<String>,
        path: PathBuf,
        name: Option<String>,
        style: String,
        bookmark: Vec<u8>,
        reply: Reply<Value>,
    },
    RefreshWatchedFolderBookmark {
        folder: String,
        previous: Vec<u8>,
        resolved: PathBuf,
        replacement: Option<Vec<u8>>,
        reply: Reply<bool>,
    },
    SeedVoiceMemos {
        root: PathBuf,
        reply: Reply<bool>,
    },
    Install {
        package: Value,
        reply: Reply<()>,
    },
    KnowledgePrepare {
        epoch: String,
        reply: Reply<()>,
    },
    KnowledgeAck {
        key: String,
        revision: String,
        reply: Reply<()>,
    },
    RecoverJobs {
        reply: Reply<()>,
    },
    EnqueueJob {
        operation: String,
        args: Value,
        automatic: bool,
        reply: Reply<(String, Lane)>,
    },
    EnqueueAutomaticJobs {
        reply: Reply<bool>,
    },
    ClaimJob {
        lane: Lane,
        now: i64,
        reply: Reply<Claimed>,
    },
    FinishJob {
        id: String,
        result: Result<Value, AppError>,
        reply: Reply<Option<Lane>>,
    },
    JobStages {
        stages: Value,
        reply: Reply<()>,
    },
    CancelJobs {
        recording: String,
        reply: Reply<Cancellation>,
    },
    Close {
        done: oneshot::Sender<()>,
    },
    #[cfg(test)]
    Test(TestOrder),
}

fn closed() -> String {
    "La biblioteca está cerrada".into()
}

struct Actor {
    store: Store,
    publisher: watch::Sender<Published>,
    #[cfg(test)]
    checkpoint: Arc<std::sync::Mutex<Option<Checkpoint>>>,
}

impl Actor {
    async fn run(mut self, mut inbox: mpsc::UnboundedReceiver<Order>) {
        let mut closing = Vec::new();
        while let Some(order) = inbox.recv().await {
            match order {
                Order::Close { done } => {
                    inbox.close();
                    closing.push(done);
                }
                order => self.serve(order).await,
            }
        }
        drop(self);
        for done in closing {
            let _ = done.send(());
        }
    }

    async fn serve(&mut self, order: Order) {
        if AssertUnwindSafe(self.handle(order))
            .catch_unwind()
            .await
            .is_err()
        {
            if let Err(error) = self.store.reload().await {
                eprintln!("La biblioteca no pudo recargar su índice tras un fallo: {error}");
            }
            if let Err(error) = self.publish().await {
                eprintln!("La biblioteca no pudo publicar su estado tras un fallo: {error}");
            }
        }
    }

    async fn publish(&self) -> Result<(), String> {
        self.publisher.send_replace(publication(&self.store).await?);
        Ok(())
    }

    async fn answer<T>(&self, reply: Reply<T>, result: Result<T, String>) {
        let result = match self.publish().await {
            Ok(()) => result,
            Err(error) => Err(format!(
                "La biblioteca guardó el cambio pero no pudo leer los trabajos activos: {error}"
            )),
        };
        let _ = reply.send(result);
    }

    async fn handle(&mut self, order: Order) {
        #[cfg(test)]
        reach(&self.checkpoint).await;
        let store = &mut self.store;
        match order {
            Order::Mutate {
                method,
                params,
                reply,
            } => {
                let result = store.mutate(&method, &params).await;
                self.answer(reply, result).await
            }
            Order::Log { params, reply } => {
                let result = store.mutate("log", &params).await;
                match (reply, result) {
                    (Some(reply), result) => {
                        let _ = reply.send(result);
                    }
                    (None, Err(error)) => {
                        eprintln!(
                            "{}; no se pudo guardar en el registro: {error}",
                            params["message"]
                        )
                    }
                    (None, Ok(_)) => {}
                }
            }
            Order::RemoveAudio { params, reply } => {
                let result = async {
                    if jobs::busy(store.database(), crate::store::text(&params, "id")?).await? {
                        return Err("Cancela el trabajo antes de quitar su audio".into());
                    }
                    store.mutate("recording_remove_audio", &params).await
                }
                .await;
                self.answer(reply, result).await
            }
            Order::ImportStaged {
                staged,
                source,
                recipe,
                reply,
            } => {
                let result = store
                    .import_staged(staged, &source, recipe.as_deref())
                    .await;
                self.answer(reply, result).await
            }
            Order::ImportRecorded {
                staged,
                source,
                recipe,
                mut update,
                reply,
            } => {
                let result = async {
                    let record = store
                        .import_staged(staged, &source, recipe.as_deref())
                        .await?;
                    update["id"] = record["id"].clone();
                    store.mutate("recording_update", &update).await
                }
                .await;
                self.answer(reply, result).await
            }
            Order::ImportWatched {
                staged,
                source,
                title,
                started_at,
                source_key,
                reply,
            } => {
                let result = store
                    .import_staged_with_metadata(staged, &source, &title, started_at, &source_key)
                    .await;
                self.answer(reply, result).await
            }
            Order::SaveCredential { key, value, reply } => {
                let result = store.save_credential(&key, &value);
                self.answer(reply, result).await
            }
            Order::RemoveConnector { id, reply } => {
                let result = store.remove_connector(&id).await;
                self.answer(reply, result).await
            }
            Order::SaveConnector {
                account,
                destination,
                reply,
            } => {
                let result = store.save_connector(&account, &destination).await;
                self.answer(reply, result).await
            }
            Order::SetPersonColor { name, color, reply } => {
                let result = store.set_person_color(&name, &color).await;
                self.answer(reply, result).await
            }
            Order::RenamePerson {
                name,
                new_name,
                reply,
            } => {
                let result = store.rename_person(&name, &new_name).await;
                self.answer(reply, result).await
            }
            Order::RemovePerson { name, reply } => {
                let result = store.remove_person(&name).await;
                self.answer(reply, result).await
            }
            Order::RemovePersonVoice { id, reply } => {
                let result = store.remove_person_voice(&id).await;
                self.answer(reply, result).await
            }
            Order::AddPersonVoice {
                name,
                voice,
                source,
                reply,
            } => {
                let result = store.add_person_voice(&name, &voice, &source).await;
                self.answer(reply, result).await
            }
            Order::MemoryKeep {
                recording,
                version,
                fingerprint,
                value,
                reply,
            } => {
                let result = store
                    .memory_keep(&recording, &version, &fingerprint, &value)
                    .await;
                self.answer(reply, result).await
            }
            Order::TraceSave { trace, reply } => {
                let result = store.trace_save(&trace).await;
                self.answer(reply, result).await
            }
            Order::RecognizeTranscription {
                recording,
                transcript,
                reply,
            } => {
                let result = store.recognize_transcription(&recording, transcript).await;
                self.answer(reply, result).await
            }
            Order::AuthorizeWatchedFolder {
                folder,
                path,
                name,
                style,
                bookmark,
                reply,
            } => {
                let result = store
                    .authorize_watched_folder(
                        folder.as_deref(),
                        &path,
                        name.as_deref(),
                        &style,
                        &bookmark,
                    )
                    .await;
                self.answer(reply, result).await
            }
            Order::RefreshWatchedFolderBookmark {
                folder,
                previous,
                resolved,
                replacement,
                reply,
            } => {
                let result = store
                    .refresh_watched_folder_bookmark(
                        &folder,
                        &previous,
                        &resolved,
                        replacement.as_deref(),
                    )
                    .await;
                self.answer(reply, result).await
            }
            Order::SeedVoiceMemos { root, reply } => {
                let result = store.seed_voice_memos(&root).await;
                self.answer(reply, result).await
            }
            Order::Install { package, reply } => {
                let result = crate::catalog::install(store, &package).await;
                self.answer(reply, result).await
            }
            Order::KnowledgePrepare { epoch, reply } => {
                let result = store.knowledge_prepare(&epoch).await;
                self.answer(reply, result).await
            }
            Order::KnowledgeAck {
                key,
                revision,
                reply,
            } => {
                let result = store.knowledge_ack(&key, &revision).await;
                self.answer(reply, result).await
            }
            Order::RecoverJobs { reply } => {
                let result = jobs::recover(store).await;
                self.answer(reply, result).await
            }
            Order::EnqueueJob {
                operation,
                args,
                automatic,
                reply,
            } => {
                let result = jobs::enqueue(store, &operation, args, automatic).await;
                self.answer(reply, result).await
            }
            Order::EnqueueAutomaticJobs { reply } => {
                let result = jobs::automatic(store).await;
                self.answer(reply, result).await
            }
            Order::ClaimJob { lane, now, reply } => {
                let result = jobs::claim(store, lane, now).await;
                self.answer(reply, result).await
            }
            Order::FinishJob { id, result, reply } => {
                let result = jobs::finish(store, &id, result).await;
                self.answer(reply, result).await
            }
            Order::JobStages { stages, reply } => {
                let result = jobs::stages(store, &stages).await;
                self.answer(reply, result).await
            }
            Order::CancelJobs { recording, reply } => {
                let result = jobs::cancel(store, &recording).await;
                self.answer(reply, result).await
            }
            Order::Close { done } => {
                let _ = done.send(());
            }
            #[cfg(test)]
            Order::Test(operation) => {
                operation(store).await;
                let _ = self.publish().await;
            }
        }
    }
}

#[derive(Clone)]
pub struct Library {
    orders: mpsc::UnboundedSender<Order>,
    published: watch::Receiver<Published>,
    database: Persistence,
    #[cfg(test)]
    checkpoint: Arc<std::sync::Mutex<Option<Checkpoint>>>,
}

impl Library {
    pub async fn new(store: Store) -> Result<Self, String> {
        let (publisher, published) = watch::channel(publication(&store).await?);
        let (orders, inbox) = mpsc::unbounded_channel();
        let database = store.database().clone();
        let actor = Actor {
            store,
            publisher,
            #[cfg(test)]
            checkpoint: Arc::default(),
        };
        #[cfg(test)]
        let checkpoint = actor.checkpoint.clone();
        tokio::spawn(actor.run(inbox));
        Ok(Self {
            orders,
            published,
            database,
            #[cfg(test)]
            checkpoint,
        })
    }

    pub fn index(&self) -> IndexView {
        self.published.borrow().index.clone()
    }

    pub fn active_jobs(&self) -> Arc<Vec<Value>> {
        self.published.borrow().active_jobs.clone()
    }

    fn send(&self, order: Order) -> Result<(), String> {
        self.orders.send(order).map_err(|_| closed())
    }

    async fn request<T>(&self, order: impl FnOnce(Reply<T>) -> Order) -> Result<T, String> {
        let (reply, answer) = oneshot::channel();
        self.send(order(reply))?;
        answer
            .await
            .map_err(|_| "La biblioteca falló al atender la orden".to_owned())?
    }

    pub async fn close(&self) -> Result<(), String> {
        let (done, closed) = oneshot::channel();
        self.send(Order::Close { done })?;
        closed
            .await
            .map_err(|_| "La biblioteca no terminó de cerrarse".to_owned())
    }

    pub fn log(&self, params: Value) -> Result<(), String> {
        self.send(Order::Log {
            params,
            reply: None,
        })
    }

    pub async fn snapshot(&self) -> Result<Value, String> {
        self.index().snapshot(&self.database).await
    }

    pub async fn recording(&self, id: String) -> Result<Value, String> {
        self.database
            .recording(&id)
            .await?
            .ok_or_else(|| "Grabación no encontrada".into())
    }

    pub async fn runtime_context(&self, recording: Option<String>) -> Result<Value, String> {
        self.index()
            .runtime_context(&self.database, recording.as_deref())
            .await
    }

    pub async fn log_list(&self, params: Value) -> Result<Value, String> {
        crate::store::log_list(&self.database, &params).await
    }

    pub async fn memory_recall(
        &self,
        recording: String,
        version: String,
        fingerprint: String,
    ) -> Result<Option<Value>, String> {
        self.index()
            .memory_recall(&self.database, &recording, &version, &fingerprint)
            .await
    }

    pub async fn trace_list(&self, recording: Option<String>) -> Result<Vec<Value>, String> {
        self.database.trace_list(recording.as_deref()).await
    }

    pub async fn people(&self) -> Result<Value, String> {
        self.database.people().await
    }

    pub async fn knowledge_change(&self) -> Result<Option<CoreChange>, String> {
        self.database.knowledge_change().await
    }

    pub async fn job(&self, id: String) -> Result<Option<Job>, String> {
        jobs::find(&self.database, &id).await
    }

    pub async fn job_history(
        &self,
        query: jobs::HistoryQuery,
    ) -> Result<jobs::HistoryPage, String> {
        jobs::history(&self.database, &query).await
    }

    pub async fn mutate(&self, method: String, params: Value) -> Result<Value, String> {
        if method == "log" {
            return self
                .request(|reply| Order::Log {
                    params,
                    reply: Some(reply),
                })
                .await;
        }
        self.request(|reply| Order::Mutate {
            method,
            params,
            reply,
        })
        .await
    }

    pub async fn remove_audio(&self, params: Value) -> Result<Value, String> {
        self.request(|reply| Order::RemoveAudio { params, reply })
            .await
    }

    pub async fn import_staged(
        &self,
        staged: StagedAudio,
        source: PathBuf,
        recipe: Option<String>,
    ) -> Result<Value, String> {
        self.request(|reply| Order::ImportStaged {
            staged,
            source,
            recipe,
            reply,
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
        self.request(|reply| Order::ImportRecorded {
            staged,
            source,
            recipe,
            update,
            reply,
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
        self.request(|reply| Order::ImportWatched {
            staged,
            source,
            title,
            started_at,
            source_key,
            reply,
        })
        .await
    }

    pub async fn save_credential(&self, key: String, value: String) -> Result<(), String> {
        self.request(|reply| Order::SaveCredential { key, value, reply })
            .await
    }

    pub async fn remove_connector(&self, id: String) -> Result<(), String> {
        self.request(|reply| Order::RemoveConnector { id, reply })
            .await
    }

    pub async fn save_connector(&self, account: Value, destination: Value) -> Result<(), String> {
        self.request(|reply| Order::SaveConnector {
            account,
            destination,
            reply,
        })
        .await
    }

    pub async fn set_person_color(&self, name: String, color: String) -> Result<(), String> {
        self.request(|reply| Order::SetPersonColor { name, color, reply })
            .await
    }

    pub async fn rename_person(&self, name: String, new_name: String) -> Result<(), String> {
        self.request(|reply| Order::RenamePerson {
            name,
            new_name,
            reply,
        })
        .await
    }

    pub async fn remove_person(&self, name: String) -> Result<(), String> {
        self.request(|reply| Order::RemovePerson { name, reply })
            .await
    }

    pub async fn remove_person_voice(&self, id: String) -> Result<(), String> {
        self.request(|reply| Order::RemovePersonVoice { id, reply })
            .await
    }

    pub async fn add_person_voice(
        &self,
        name: String,
        voice: SpeakerVoice,
        source: String,
    ) -> Result<(), String> {
        self.request(|reply| Order::AddPersonVoice {
            name,
            voice,
            source,
            reply,
        })
        .await
    }

    pub async fn memory_keep(
        &self,
        recording: String,
        version: String,
        fingerprint: String,
        value: Value,
    ) -> Result<(), String> {
        self.request(|reply| Order::MemoryKeep {
            recording,
            version,
            fingerprint,
            value,
            reply,
        })
        .await
    }

    pub async fn trace_save(&self, trace: Value) -> Result<(), String> {
        self.request(|reply| Order::TraceSave { trace, reply })
            .await
    }

    pub async fn recognize_transcription(
        &self,
        recording: String,
        transcript: Value,
    ) -> Result<Value, String> {
        self.request(|reply| Order::RecognizeTranscription {
            recording,
            transcript,
            reply,
        })
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
        self.request(|reply| Order::AuthorizeWatchedFolder {
            folder,
            path,
            name,
            style,
            bookmark,
            reply,
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
        self.request(|reply| Order::RefreshWatchedFolderBookmark {
            folder,
            previous,
            resolved,
            replacement,
            reply,
        })
        .await
    }

    pub async fn seed_voice_memos(&self, root: PathBuf) -> Result<bool, String> {
        self.request(|reply| Order::SeedVoiceMemos { root, reply })
            .await
    }

    pub async fn install(&self, package: Value) -> Result<(), String> {
        self.request(|reply| Order::Install { package, reply })
            .await
    }

    pub async fn knowledge_prepare(&self, epoch: String) -> Result<(), String> {
        self.request(|reply| Order::KnowledgePrepare { epoch, reply })
            .await
    }

    pub async fn knowledge_ack(&self, key: String, revision: String) -> Result<(), String> {
        self.request(|reply| Order::KnowledgeAck {
            key,
            revision,
            reply,
        })
        .await
    }

    pub async fn recover_jobs(&self) -> Result<(), String> {
        self.request(|reply| Order::RecoverJobs { reply }).await
    }

    pub async fn enqueue_job(
        &self,
        operation: String,
        args: Value,
        automatic: bool,
    ) -> Result<(String, Lane), String> {
        self.request(|reply| Order::EnqueueJob {
            operation,
            args,
            automatic,
            reply,
        })
        .await
    }

    pub async fn enqueue_automatic_jobs(&self) -> Result<bool, String> {
        self.request(|reply| Order::EnqueueAutomaticJobs { reply })
            .await
    }

    pub async fn claim_job(&self, lane: Lane, now: i64) -> Result<Claimed, String> {
        self.request(|reply| Order::ClaimJob { lane, now, reply })
            .await
    }

    pub async fn finish_job(
        &self,
        id: String,
        result: Result<Value, AppError>,
    ) -> Result<Option<Lane>, String> {
        self.request(|reply| Order::FinishJob { id, result, reply })
            .await
    }

    pub async fn job_stages(&self, stages: Value) -> Result<(), String> {
        self.request(|reply| Order::JobStages { stages, reply })
            .await
    }

    pub async fn cancel_jobs(&self, recording: String) -> Result<Cancellation, String> {
        self.request(|reply| Order::CancelJobs { recording, reply })
            .await
    }
}

#[cfg(test)]
type TestOrder =
    Box<dyn for<'a> FnOnce(&'a mut Store) -> futures_util::future::BoxFuture<'a, ()> + Send>;

#[cfg(test)]
fn test_order(
    operation: impl for<'a> FnOnce(&'a mut Store) -> futures_util::future::BoxFuture<'a, ()>
        + Send
        + 'static,
) -> TestOrder {
    Box::new(operation)
}

#[cfg(test)]
impl Library {
    pub(crate) async fn with_store<R: Send + 'static>(
        &self,
        operation: impl for<'a> FnOnce(&'a mut Store) -> futures_util::future::BoxFuture<'a, R>
            + Send
            + 'static,
    ) -> R {
        let (reply, answer) = oneshot::channel();
        self.send(Order::Test(test_order(move |store| {
            Box::pin(async move {
                let _ = reply.send(operation(store).await);
            })
        })))
        .expect("La biblioteca está cerrada");
        answer.await.expect("La biblioteca falló en la prueba")
    }

    pub(crate) async fn import(&self, audio: &std::path::Path) -> Result<Value, String> {
        let audio = audio.to_owned();
        self.with_store(move |store| Box::pin(async move { store.import(&audio, None).await }))
            .await
    }

    pub(crate) fn stop_next_write(&self) -> Stopped {
        let (parked, reached) = oneshot::channel();
        let (release, released) = oneshot::channel();
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
        parked: oneshot::Sender<()>,
        release: oneshot::Receiver<()>,
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
    parked: Option<oneshot::Receiver<()>>,
    _release: oneshot::Sender<()>,
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
