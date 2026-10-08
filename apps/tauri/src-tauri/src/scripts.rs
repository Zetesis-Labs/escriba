use serde_json::{json, Value};
use std::{
    collections::HashMap,
    future::Future,
    path::PathBuf,
    pin::Pin,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, Command},
    sync::{oneshot, Mutex},
};

#[derive(Clone)]
pub struct Lease(Arc<AtomicBool>);
impl Lease {
    fn new() -> Self {
        Self(Arc::new(AtomicBool::new(true)))
    }
    fn revoke(&self) {
        self.0.store(false, Ordering::SeqCst);
    }
    pub fn ensure_active(&self) -> Result<(), String> {
        if self.0.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err("Proceso cancelado".into())
        }
    }
}
pub type Capability = Arc<
    dyn Fn(
            String,
            Value,
            String,
            Lease,
        ) -> Pin<Box<dyn Future<Output = Result<Value, String>> + Send>>
        + Send
        + Sync,
>;
pub type Events = Arc<dyn Fn(Value) + Send + Sync>;
struct PendingTask {
    reply: oneshot::Sender<Result<Value, String>>,
    lease: Lease,
}
type Pending = Arc<Mutex<HashMap<String, PendingTask>>>;
type Input = Arc<Mutex<ChildStdin>>;
const MAX_FRAME: u64 = 48 * 1024 * 1024;

struct Worker {
    _child: Child,
    input: Input,
    reader: tokio::task::JoinHandle<()>,
    task: String,
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.reader.abort();
    }
}
struct Session {
    _child: Child,
    input: Input,
    pending: Pending,
    workers: Arc<Mutex<HashMap<String, Worker>>>,
    alive: Arc<AtomicBool>,
    reader: tokio::task::JoinHandle<()>,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

pub struct Scripts {
    path: PathBuf,
    session: Mutex<Option<Arc<Session>>>,
}
async fn frame<R: AsyncRead + Unpin>(reader: &mut BufReader<R>) -> Result<Value, String> {
    let mut bytes = Vec::new();
    let count = reader
        .take(MAX_FRAME + 1)
        .read_until(b'\n', &mut bytes)
        .await
        .map_err(|e| format!("Se perdió el canal TypeScript: {e}"))?;
    if count == 0 {
        return Err("El motor TypeScript se detuvo".into());
    }
    if count as u64 > MAX_FRAME || bytes.last() != Some(&b'\n') {
        return Err("Mensaje TypeScript demasiado grande o incompleto".into());
    }
    serde_json::from_slice(&bytes).map_err(|_| "Mensaje TypeScript inválido".into())
}
async fn send(input: &Input, value: &Value) -> Result<(), String> {
    let mut data = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    if data.len() as u64 > MAX_FRAME {
        return Err("Petición TypeScript demasiado grande".into());
    }
    data.push(b'\n');
    let mut input = input.lock().await;
    input
        .write_all(&data)
        .await
        .map_err(|e| format!("No se pudo escribir al motor TypeScript: {e}"))?;
    input.flush().await.map_err(|e| e.to_string())
}
fn spawn(path: &PathBuf, worker: bool) -> Result<Child, String> {
    let mut command = Command::new(path);
    if worker {
        command.arg("--worker");
    }
    command
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("No se pudo iniciar TypeScript: {e}"))
}
fn allowed(method: &str) -> bool {
    matches!(
        method,
        "snapshot"
            | "recording_update"
            | "version_save"
            | "version_select"
            | "version_update"
            | "log"
            | "transcribe"
            | "summarize"
            | "ask"
            | "native_cancel"
            | "project_build"
            | "project_install"
            | "connector_http"
            | "connector_files"
            | "connector_audio"
            | "publication_save"
            | "publication_remove"
            | "memory_recall"
            | "memory_keep"
            | "trace_save"
    )
}
impl Scripts {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            session: Mutex::new(None),
        }
    }
    async fn session(
        &self,
        capability: Capability,
        events: Events,
    ) -> Result<Arc<Session>, String> {
        let mut slot = self.session.lock().await;
        if let Some(session) = slot.as_ref().filter(|s| s.alive.load(Ordering::SeqCst)) {
            return Ok(session.clone());
        }
        *slot = None;
        let mut child = spawn(&self.path, false)?;
        let input = Arc::new(Mutex::new(
            child.stdin.take().ok_or("TypeScript sin entrada")?,
        ));
        let mut output = BufReader::new(child.stdout.take().ok_or("TypeScript sin salida")?);
        let hello = tokio::time::timeout(Duration::from_secs(30), frame(&mut output))
            .await
            .map_err(|_| "TypeScript no arrancó a tiempo")??;
        if hello["type"] != "ready" || hello["protocolVersion"] != 1 {
            return Err("Versión de protocolo TypeScript incompatible".into());
        }
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let workers: Arc<Mutex<HashMap<String, Worker>>> = Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));
        let (reader_input, reader_pending, reader_workers, reader_alive, path) = (
            input.clone(),
            pending.clone(),
            workers.clone(),
            alive.clone(),
            self.path.clone(),
        );
        let reader = tokio::spawn(async move {
            let error = loop {
                let value = match frame(&mut output).await {
                    Ok(v) => v,
                    Err(e) => break e,
                };
                let kind = value["type"].as_str().unwrap_or("");
                let key = value["id"].as_str().unwrap_or("").to_owned();
                match kind {
                    "result" | "error" => {
                        reader_workers
                            .lock()
                            .await
                            .retain(|_, worker| worker.task != key);
                        if let Some(task) = reader_pending.lock().await.remove(&key) {
                            let result = if kind == "result" {
                                Ok(value["value"].clone())
                            } else {
                                Err(value["message"]
                                    .as_str()
                                    .unwrap_or("Falló TypeScript")
                                    .to_owned())
                            };
                            task.lease.revoke();
                            let _ = task.reply.send(result);
                        }
                    }
                    "event" => events(value),
                    "call" => {
                        let method = value["method"].as_str().unwrap_or("").to_owned();
                        let task = value["taskId"].as_str().unwrap_or("").to_owned();
                        let lease = reader_pending
                            .lock()
                            .await
                            .get(&task)
                            .map(|pending| pending.lease.clone());
                        let valid = allowed(&method) && lease.is_some();
                        let input = reader_input.clone();
                        let callback = capability.clone();
                        let pending = reader_pending.clone();
                        tokio::spawn(async move {
                            let result = if valid {
                                callback(
                                    method,
                                    value["params"].clone(),
                                    task.clone(),
                                    lease.unwrap(),
                                )
                                .await
                            } else {
                                Err("Capacidad no autorizada o trabajo terminado".into())
                            };
                            if !pending.lock().await.contains_key(&task) {
                                return;
                            }
                            let response = match result {
                                Ok(v) => json!({"type":"resolve","id":value["id"],"value":v}),
                                Err(e) => json!({"type":"reject","id":value["id"],"message":e}),
                            };
                            let _ = send(&input, &response).await;
                        });
                    }
                    "worker_create" => {
                        let task = value["taskId"].as_str().unwrap_or("").to_owned();
                        let mut slots = reader_workers.lock().await;
                        if key.is_empty()
                            || slots.contains_key(&key)
                            || slots.len() >= 8
                            || !reader_pending.lock().await.contains_key(&task)
                        {
                            let _ = send(&reader_input, &json!({"type":"worker_error","id":key,"message":"No se puede abrir este proceso de receta"})).await;
                            continue;
                        }
                        let result = (|| {
                            let mut child = spawn(&path, true)?;
                            let input = Arc::new(Mutex::new(
                                child.stdin.take().ok_or("Receta sin entrada")?,
                            ));
                            let output =
                                BufReader::new(child.stdout.take().ok_or("Receta sin salida")?);
                            Ok::<_, String>((child, input, output))
                        })();
                        match result {
                            Ok((child, worker_input, mut worker_output)) => {
                                let destination = reader_input.clone();
                                let worker_key = key.clone();
                                let reader = tokio::spawn(async move {
                                    loop {
                                        let response = match frame(&mut worker_output).await {
                                            Ok(value) => {
                                                json!({"type":"worker_message","id":worker_key,"value":value})
                                            }
                                            Err(message) => {
                                                let _ = send(&destination, &json!({"type":"worker_error","id":worker_key,"message":message})).await;
                                                break;
                                            }
                                        };
                                        if send(&destination, &response).await.is_err() {
                                            break;
                                        }
                                    }
                                });
                                slots.insert(
                                    key,
                                    Worker {
                                        _child: child,
                                        input: worker_input,
                                        reader,
                                        task,
                                    },
                                );
                            }
                            Err(message) => {
                                let _ = send(
                                    &reader_input,
                                    &json!({"type":"worker_error","id":key,"message":message}),
                                )
                                .await;
                            }
                        }
                    }
                    "worker_send" => {
                        let input = reader_workers
                            .lock()
                            .await
                            .get(&key)
                            .map(|w| w.input.clone());
                        if let Some(input) = input {
                            if let Err(message) = send(&input, &value["value"]).await {
                                let _ = send(
                                    &reader_input,
                                    &json!({"type":"worker_error","id":key,"message":message}),
                                )
                                .await;
                            }
                        }
                    }
                    "worker_terminate" => {
                        reader_workers.lock().await.remove(&key);
                    }
                    _ => break "Mensaje desconocido del motor TypeScript".into(),
                }
            };
            reader_alive.store(false, Ordering::SeqCst);
            reader_workers.lock().await.clear();
            for (_, task) in reader_pending.lock().await.drain() {
                task.lease.revoke();
                let _ = task.reply.send(Err(error.clone()));
            }
        });
        let session = Arc::new(Session {
            _child: child,
            input,
            pending,
            workers,
            alive,
            reader,
        });
        *slot = Some(session.clone());
        Ok(session)
    }
    pub async fn call(
        &self,
        id: &str,
        operation: &str,
        args: Value,
        capability: Capability,
        events: Events,
    ) -> Result<Value, String> {
        let session = self.session(capability, events).await?;
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = session.pending.lock().await;
            if pending.contains_key(id) {
                return Err("ID de ejecución repetido".into());
            }
            pending.insert(
                id.to_owned(),
                PendingTask {
                    reply: tx,
                    lease: Lease::new(),
                },
            );
        }
        if let Err(error) = send(
            &session.input,
            &json!({"type":"run","id":id,"operation":operation,"args":args}),
        )
        .await
        {
            if let Some(task) = session.pending.lock().await.remove(id) {
                task.lease.revoke();
            }
            session.alive.store(false, Ordering::SeqCst);
            return Err(error);
        }
        match tokio::time::timeout(Duration::from_secs(7200), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("El proceso TypeScript perdió el trabajo".into()),
            Err(_) => {
                self.cancel(id).await;
                Err("El trabajo superó dos horas".into())
            }
        }
    }
    pub async fn cancel(&self, id: &str) {
        let session = self.session.lock().await.clone();
        if let Some(session) = session {
            if let Some(task) = session.pending.lock().await.remove(id) {
                task.lease.revoke();
                let _ = task.reply.send(Err("Proceso cancelado".into()));
            }
            let _ = send(&session.input, &json!({"type":"cancel","id":id})).await;
            session
                .workers
                .lock()
                .await
                .retain(|_, worker| worker.task != id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    async fn wait_until(mut condition: impl AsyncFnMut() -> bool) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while !condition().await {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("No llegó el estado esperado del sidecar");
    }

    fn fixture() -> Value {
        json!({
            "recordings":[{"id":"r","title":"Nota","createdAt":"2026-10-09T10:00:00Z","source":"sintético","audioPath":"/opaque","duration":0,"status":"pending","versions":[],"publications":[]}],
            "resolvers":[{"id":"local-stt","name":"Whisper","role":"stt","local":true,"enabled":true},{"id":"local-llm","name":"Apple","role":"llm","local":true,"enabled":true}],
            "recipes":[{"id":"default","name":"Por defecto","kind":"form","values":{"resumir":false}}],
            "accounts":[],"destinations":[],"settings":{"defaultRecipeId":"default","projectPath":null,"watchedFolders":[],"language":"es","whisperModel":"large","autoProcess":false,"launchAtLogin":false,"theme":"system"},
            "logs":[],"dataPath":"/synthetic"
        })
    }

    fn fake_host(state: Arc<StdMutex<Value>>) -> Capability {
        Arc::new(move |method, params, _task, lease| {
            let state = state.clone();
            Box::pin(async move {
                lease.ensure_active()?;
                let mut snapshot = state.lock().unwrap();
                let record = &mut snapshot["recordings"][0];
                match method.as_str() {
                    "snapshot" => Ok(snapshot.clone()),
                    "transcribe" => Ok(json!({"text":"Audio sintético","segments":[]})),
                    "version_save" => {
                        let mut version = params.clone();
                        version["id"] = json!("v1");
                        version["createdAt"] = json!("now");
                        record["versions"]
                            .as_array_mut()
                            .unwrap()
                            .push(version.clone());
                        record["currentVersionId"] = json!("v1");
                        Ok(version)
                    }
                    "version_update" => {
                        for key in ["digest", "data"] {
                            if let Some(value) = params.get(key) {
                                record["versions"][0][key] = value.clone();
                            }
                        }
                        Ok(Value::Null)
                    }
                    "version_select" => {
                        record["currentVersionId"] = params["versionId"].clone();
                        Ok(Value::Null)
                    }
                    "recording_update" => {
                        for key in ["status", "error", "recipeId"] {
                            if let Some(value) = params.get(key) {
                                record[key] = value.clone();
                            }
                        }
                        Ok(record.clone())
                    }
                    "log" | "memory_recall" | "memory_keep" | "trace_save" => Ok(Value::Null),
                    _ => Err(format!("Capacidad inesperada: {method}")),
                }
            })
        })
    }

    #[tokio::test]
    async fn sidecar_compilado_inspecciona_formulario_y_procesa_nota() {
        let path = crate::native::binary("escriba-runtime").unwrap();
        let scripts = Scripts::new(path);
        let state = Arc::new(StdMutex::new(fixture()));
        let cap = fake_host(state.clone());
        let events: Events = Arc::new(|_| {});
        let schema = tokio::time::timeout(
            Duration::from_secs(20),
            scripts.call(
                "schema-1",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                cap.clone(),
                events.clone(),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(schema["properties"]["idioma"].is_object(), "{schema}");
        tokio::time::timeout(
            Duration::from_secs(20),
            scripts.call(
                "job-1",
                "processRecording",
                json!({"recordingId":"r","options":{"force":false}}),
                cap,
                events,
            ),
        )
        .await
        .unwrap()
        .unwrap();
        let saved = state.lock().unwrap();
        assert_eq!(
            saved["recordings"][0]["versions"].as_array().unwrap().len(),
            1
        );
        assert_eq!(saved["recordings"][0]["status"], "done");
    }

    #[tokio::test]
    async fn cancelacion_cierra_worker_cpu_y_deja_sidecar_usable() {
        let path = crate::native::binary("escriba-runtime").unwrap();
        let scripts = Arc::new(Scripts::new(path));
        let mut fixture = fixture();
        fixture["recipes"][0] = json!({"id":"default","name":"Bucle","kind":"code","values":{},"bundle":"var __recipe={flujo(){while(true){}}}"});
        let state = Arc::new(StdMutex::new(fixture));
        let cap = fake_host(state.clone());
        let events: Events = Arc::new(|_| {});
        let handle = {
            let scripts = scripts.clone();
            let cap = cap.clone();
            let events = events.clone();
            tokio::spawn(async move {
                scripts
                    .call(
                        "cpu",
                        "processRecording",
                        json!({"recordingId":"r"}),
                        cap,
                        events,
                    )
                    .await
            })
        };
        wait_until(|| async {
            let session = scripts.session.lock().await.clone();
            if let Some(session) = session {
                !session.workers.lock().await.is_empty()
            } else {
                false
            }
        })
        .await;
        scripts.cancel("cpu").await;
        let error = tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert!(error.contains("cancelado"), "{error}");
        let session = scripts.session.lock().await.clone().unwrap();
        assert!(session.workers.lock().await.is_empty());
        state.lock().unwrap()["recipes"][0] =
            json!({"id":"default","name":"Por defecto","kind":"form","values":{"resumir":false}});
        tokio::time::timeout(
            Duration::from_secs(5),
            scripts.call(
                "schema-after-cancel",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                cap,
                events,
            ),
        )
        .await
        .unwrap()
        .unwrap();
    }

    #[tokio::test]
    async fn caida_del_sidecar_reinicia_en_siguiente_peticion() {
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        let cap = fake_host(Arc::new(StdMutex::new(fixture())));
        let events: Events = Arc::new(|_| {});
        scripts
            .call(
                "schema-before-crash",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                cap.clone(),
                events.clone(),
            )
            .await
            .unwrap();
        let old = scripts.session.lock().await.clone().unwrap();
        let old_pid = old._child.id().unwrap();
        unsafe {
            libc::kill(old_pid as i32, libc::SIGKILL);
        }
        wait_until(|| async { !old.alive.load(Ordering::SeqCst) }).await;
        let schema = scripts
            .call(
                "schema-after-crash",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                cap,
                events,
            )
            .await
            .unwrap();
        assert!(schema["properties"]["idioma"].is_object());
        assert_ne!(
            scripts.session.lock().await.as_ref().unwrap()._child.id(),
            Some(old_pid)
        );
    }

    #[tokio::test]
    async fn lease_revocada_impide_efecto_tardio_tras_cancelacion() {
        let scripts = Arc::new(Scripts::new(
            crate::native::binary("escriba-runtime").unwrap(),
        ));
        let started = Arc::new(AtomicBool::new(false));
        let wrote = Arc::new(AtomicBool::new(false));
        let fixture = fixture();
        let cap: Capability = {
            let started = started.clone();
            let wrote = wrote.clone();
            Arc::new(move |method, _, _, lease| {
                let started = started.clone();
                let wrote = wrote.clone();
                let fixture = fixture.clone();
                Box::pin(async move {
                    if method != "snapshot" {
                        return Err("Capacidad inesperada".into());
                    }
                    started.store(true, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    lease.ensure_active()?;
                    wrote.store(true, Ordering::SeqCst);
                    Ok(fixture)
                })
            })
        };
        let events: Events = Arc::new(|_| {});
        let handle = {
            let scripts = scripts.clone();
            tokio::spawn(async move {
                scripts
                    .call(
                        "late",
                        "processRecording",
                        json!({"recordingId":"r"}),
                        cap,
                        events,
                    )
                    .await
            })
        };
        wait_until(|| async { started.load(Ordering::SeqCst) }).await;
        scripts.cancel("late").await;
        let error = tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert!(error.contains("cancelado"), "{error}");
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(!wrote.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn rejects_incomplete_frames() {
        let mut input = BufReader::new(b"{\"type\":\"result\"}".as_slice());
        assert!(frame(&mut input).await.unwrap_err().contains("incompleto"));
    }
    #[test]
    fn recipes_cannot_request_credentials_or_shell_commands() {
        for supported in ["memory_recall", "memory_keep", "trace_save"] {
            assert!(allowed(supported));
        }
        for forbidden in [
            "credential_save",
            "settings_save",
            "export_file",
            "open_url",
            "recording_start",
            "import_audio",
            "runtime_run",
        ] {
            assert!(!allowed(forbidden));
        }
    }
}
