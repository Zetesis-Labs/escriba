use crate::error::{AppError, ErrorCode};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStderr, ChildStdin, Command},
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
        ) -> Pin<Box<dyn Future<Output = Result<Value, AppError>> + Send>>
        + Send
        + Sync,
>;
pub type Events = Arc<dyn Fn(Value) + Send + Sync>;
struct PendingTask {
    reply: oneshot::Sender<Result<Value, AppError>>,
    lease: Lease,
}
type Pending = Arc<Mutex<HashMap<String, PendingTask>>>;
type Input = Arc<Mutex<ChildStdin>>;
const MAX_FRAME: u64 = 32 * 1024 * 1024;
const MAX_WORKER_RSS: u64 = 512 * 1024 * 1024;
const MAX_STARTUP_STDERR: usize = 2048;
const SANDBOX: &str = include_str!("../../runtime-host/sandbox.sb");

struct StderrCapture {
    bytes: Arc<StdMutex<Vec<u8>>>,
    recording: Arc<AtomicBool>,
    reader: tokio::task::JoinHandle<()>,
}
impl StderrCapture {
    fn new(mut stderr: ChildStderr, capture: bool) -> Self {
        let bytes = Arc::new(StdMutex::new(Vec::new()));
        let recording = Arc::new(AtomicBool::new(capture));
        let saved = bytes.clone();
        let active = recording.clone();
        let reader = tokio::spawn(async move {
            let mut buffer = [0; 4096];
            loop {
                match stderr.read(&mut buffer).await {
                    Ok(0) | Err(_) => break,
                    Ok(count) if active.load(Ordering::SeqCst) => {
                        let Ok(mut bytes) = saved.lock() else { break };
                        let remaining = MAX_STARTUP_STDERR.saturating_sub(bytes.len());
                        bytes.extend_from_slice(&buffer[..count.min(remaining)]);
                    }
                    Ok(_) => {}
                }
            }
        });
        Self {
            bytes,
            recording,
            reader,
        }
    }
    fn stop_capture(&self) {
        self.recording.store(false, Ordering::SeqCst);
        if let Ok(mut bytes) = self.bytes.lock() {
            bytes.clear();
        }
    }
    async fn startup_error(&mut self, error: String) -> String {
        let _ = tokio::time::timeout(Duration::from_millis(100), &mut self.reader).await;
        let Ok(bytes) = self.bytes.lock() else {
            return error;
        };
        let detail = String::from_utf8_lossy(&bytes);
        let detail = detail.trim().replace('\n', " ");
        if detail.is_empty() {
            error
        } else {
            format!("{error}: {detail}")
        }
    }
}
impl Drop for StderrCapture {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

struct Worker {
    child: Arc<StdMutex<Child>>,
    _stderr: StderrCapture,
    input: Input,
    reader: tokio::task::JoinHandle<()>,
    monitor: tokio::task::JoinHandle<()>,
    task: String,
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.reader.abort();
        self.monitor.abort();
        if let Ok(mut child) = self.child.lock() {
            let _ = child.start_kill();
        }
    }
}
struct Session {
    _child: Child,
    _stderr: StderrCapture,
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
async fn frame<R: AsyncRead + Unpin>(reader: &mut BufReader<R>) -> Result<Value, AppError> {
    let mut bytes = Vec::new();
    let count = reader
        .take(MAX_FRAME + 1)
        .read_until(b'\n', &mut bytes)
        .await
        .map_err(|e| {
            AppError::new(
                ErrorCode::RuntimeUnavailable,
                format!("Se perdió el canal TypeScript: {e}"),
            )
        })?;
    if count == 0 {
        return Err(AppError::new(
            ErrorCode::RuntimeUnavailable,
            "El motor TypeScript se detuvo",
        ));
    }
    if count as u64 > MAX_FRAME + 1 || bytes.last() != Some(&b'\n') {
        return Err("Mensaje TypeScript demasiado grande o incompleto".into());
    }
    serde_json::from_slice(&bytes).map_err(|_| "Mensaje TypeScript inválido".into())
}
async fn send(input: &Input, value: &Value) -> Result<(), AppError> {
    let mut data =
        serde_json::to_vec(value).map_err(|e| AppError::new(ErrorCode::Failed, e.to_string()))?;
    if data.len() as u64 > MAX_FRAME {
        return Err("Trama hacia TypeScript demasiado grande (límite 32 MiB)".into());
    }
    data.push(b'\n');
    let mut input = input.lock().await;
    input.write_all(&data).await.map_err(|e| {
        AppError::new(
            ErrorCode::RuntimeUnavailable,
            format!("No se pudo escribir al motor TypeScript: {e}"),
        )
    })?;
    input
        .flush()
        .await
        .map_err(|e| AppError::new(ErrorCode::RuntimeUnavailable, e.to_string()))
}
fn spawn(path: &Path, worker: bool) -> Result<(Child, StderrCapture), String> {
    let executable = path
        .canonicalize()
        .map_err(|e| format!("No se pudo localizar el motor TypeScript: {e}"))?;
    if !executable.is_file() {
        return Err("El motor TypeScript no es un archivo".into());
    }
    let mut command = Command::new("/usr/bin/sandbox-exec");
    command
        .arg("-p")
        .arg(SANDBOX)
        .arg("-D")
        .arg(format!("EXECUTABLE={}", executable.display()))
        .arg(executable);
    if worker {
        command.arg("--worker");
    }
    let mut child = command
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("No se pudo iniciar TypeScript: {e}"))?;
    let stderr = child.stderr.take().ok_or("TypeScript sin canal de error")?;
    Ok((child, StderrCapture::new(stderr, !worker)))
}
fn resident_bytes(pid: i32) -> Option<u64> {
    let mut info = std::mem::MaybeUninit::<libc::proc_taskinfo>::uninit();
    let size = std::mem::size_of::<libc::proc_taskinfo>();
    let returned = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKINFO,
            0,
            info.as_mut_ptr().cast(),
            size as i32,
        )
    };
    if returned == size as i32 {
        Some(unsafe { info.assume_init().pti_resident_size })
    } else {
        None
    }
}
fn process_identity(pid: i32) -> Option<(u64, u64)> {
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
    let size = std::mem::size_of::<libc::proc_bsdinfo>();
    let returned = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            info.as_mut_ptr().cast(),
            size as i32,
        )
    };
    if returned == size as i32 {
        let info = unsafe { info.assume_init() };
        Some((info.pbi_start_tvsec, info.pbi_start_tvusec))
    } else {
        None
    }
}
fn terminate_locked(child: &mut Child, reason: &AtomicU8, code: u8) -> bool {
    if matches!(child.try_wait(), Ok(Some(_))) {
        return false;
    }
    reason.store(code, Ordering::SeqCst);
    child.start_kill().is_ok()
}
#[cfg(test)]
fn terminate_worker(child: &Arc<StdMutex<Child>>, reason: &AtomicU8, code: u8) -> bool {
    let Ok(mut child) = child.lock() else {
        return false;
    };
    terminate_locked(&mut child, reason, code)
}
fn inspect_worker(
    child: &Arc<StdMutex<Child>>,
    pid: i32,
    expected: Option<(u64, u64)>,
    reason: &AtomicU8,
) -> Option<(u64, u64)> {
    let Ok(mut child) = child.lock() else {
        return None;
    };
    match child.try_wait() {
        Ok(Some(_)) => return None,
        Err(_) => {
            terminate_locked(&mut child, reason, 2);
            return None;
        }
        Ok(None) => {}
    }
    let Some(identity) = process_identity(pid) else {
        terminate_locked(&mut child, reason, 2);
        return None;
    };
    if expected.is_some_and(|expected| expected != identity) {
        terminate_locked(&mut child, reason, 2);
        return None;
    }
    match resident_bytes(pid) {
        Some(bytes) if bytes <= MAX_WORKER_RSS => Some(identity),
        Some(_) => {
            terminate_locked(&mut child, reason, 1);
            None
        }
        None => {
            terminate_locked(&mut child, reason, 2);
            None
        }
    }
}
fn monitor_worker(
    child: Arc<StdMutex<Child>>,
    pid: u32,
    reason: Arc<AtomicU8>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticks = tokio::time::interval(Duration::from_millis(50));
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let Some(identity) = inspect_worker(&child, pid as i32, None, &reason) else {
            return;
        };
        loop {
            ticks.tick().await;
            if inspect_worker(&child, pid as i32, Some(identity), &reason).is_none() {
                break;
            }
        }
    })
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
    ) -> Result<Arc<Session>, AppError> {
        let mut slot = self.session.lock().await;
        if let Some(session) = slot.as_ref().filter(|s| s.alive.load(Ordering::SeqCst)) {
            return Ok(session.clone());
        }
        *slot = None;
        let (mut child, mut stderr) = spawn(&self.path, false)
            .map_err(|error| AppError::new(ErrorCode::RuntimeUnavailable, error))?;
        let input = Arc::new(Mutex::new(
            child.stdin.take().ok_or("TypeScript sin entrada")?,
        ));
        let mut output = BufReader::new(child.stdout.take().ok_or("TypeScript sin salida")?);
        let hello = match tokio::time::timeout(Duration::from_secs(30), frame(&mut output)).await {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                return Err(AppError::new(
                    error.code,
                    stderr.startup_error(error.message).await,
                ))
            }
            Err(_) => {
                return Err(AppError::new(
                    ErrorCode::RuntimeUnavailable,
                    stderr
                        .startup_error("TypeScript no arrancó a tiempo".into())
                        .await,
                ))
            }
        };
        if hello["type"] != "ready" || hello["protocolVersion"] != 1 {
            return Err("Versión de protocolo TypeScript incompatible".into());
        }
        stderr.stop_capture();
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
                                Err(AppError::from_frame(&value))
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
                        let input = reader_input.clone();
                        let callback = capability.clone();
                        let pending = reader_pending.clone();
                        let workers = reader_workers.clone();
                        let alive = reader_alive.clone();
                        tokio::spawn(async move {
                            let result = if let Some(lease) = lease {
                                callback(method, value["params"].clone(), task.clone(), lease).await
                            } else {
                                Err("Capacidad no autorizada o trabajo terminado".into())
                            };
                            if !pending.lock().await.contains_key(&task) {
                                return;
                            }
                            let response = match result {
                                Ok(v) => json!({"type":"resolve","id":value["id"],"value":v}),
                                Err(e) => {
                                    json!({"type":"reject","id":value["id"],"message":e.message,"code":e.code})
                                }
                            };
                            if let Err(error) = send(&input, &response).await {
                                let fallback = json!({"type":"reject","id":value["id"],"message":&error.message,"code":&error.code});
                                if send(&input, &fallback).await.is_err() {
                                    alive.store(false, Ordering::SeqCst);
                                    workers.lock().await.clear();
                                    for (_, task) in pending.lock().await.drain() {
                                        task.lease.revoke();
                                        let _ = task.reply.send(Err(AppError::new(
                                            ErrorCode::RuntimeUnavailable,
                                            format!("Se perdió el canal TypeScript: {error}"),
                                        )));
                                    }
                                }
                            }
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
                            let (mut child, stderr) = spawn(&path, true)?;
                            let pid = child.id().ok_or("Receta sin proceso")?;
                            let input = Arc::new(Mutex::new(
                                child.stdin.take().ok_or("Receta sin entrada")?,
                            ));
                            let output =
                                BufReader::new(child.stdout.take().ok_or("Receta sin salida")?);
                            Ok::<_, String>((child, stderr, input, output, pid))
                        })();
                        match result {
                            Ok((child, stderr, worker_input, mut worker_output, pid)) => {
                                let child = Arc::new(StdMutex::new(child));
                                let destination = reader_input.clone();
                                let worker_key = key.clone();
                                let monitor_reason = Arc::new(AtomicU8::new(0));
                                let reader_reason = monitor_reason.clone();
                                let reader = tokio::spawn(async move {
                                    loop {
                                        let response = match frame(&mut worker_output).await {
                                            Ok(value) => {
                                                json!({"type":"worker_message","id":worker_key,"value":value})
                                            }
                                            Err(message) => {
                                                let message = match reader_reason.load(Ordering::SeqCst) {
                                                    1 => "El worker de receta superó 512 MiB de memoria".into(),
                                                    2 => "No se pudo vigilar memoria del worker".into(),
                                                    _ => message,
                                                };
                                                let _ = send(&destination, &json!({"type":"worker_error","id":worker_key,"message":message.message})).await;
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
                                        child: child.clone(),
                                        _stderr: stderr,
                                        input: worker_input,
                                        reader,
                                        monitor: monitor_worker(child, pid, monitor_reason),
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
                                    &json!({"type":"worker_error","id":key,"message":message.message}),
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
            _stderr: stderr,
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
    ) -> Result<Value, AppError> {
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
            Ok(Err(_)) => Err(AppError::new(
                ErrorCode::RuntimeUnavailable,
                "El proceso TypeScript perdió el trabajo",
            )),
            Err(_) => {
                self.cancel(id).await;
                Err(AppError::new(
                    ErrorCode::Failed,
                    "El trabajo superó dos horas",
                ))
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

    #[tokio::test]
    async fn supervisor_no_envia_senal_a_proceso_terminado() {
        let mut process = Command::new("/usr/bin/true").spawn().unwrap();
        process.wait().await.unwrap();
        let child = Arc::new(StdMutex::new(process));
        let reason = Arc::new(AtomicU8::new(0));
        assert!(!terminate_worker(&child, &reason, 2));
        assert_eq!(reason.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn supervisor_termina_su_propio_proceso_si_falla_la_inspeccion() {
        let process = Command::new("/bin/sleep").arg("5").spawn().unwrap();
        let child = Arc::new(StdMutex::new(process));
        let reason = Arc::new(AtomicU8::new(0));
        assert!(terminate_worker(&child, &reason, 2));
        assert_eq!(reason.load(Ordering::SeqCst), 2);
        let status = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let finished = { child.lock().unwrap().try_wait().unwrap() };
                if let Some(status) = finished {
                    return status;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(status.code().is_none());
    }

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
                    "runtime_context" => {
                        let mut context = snapshot.clone();
                        context["recordings"] = json!(snapshot["recordings"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .filter(|recording| params["recordingId"].as_str()
                                == recording["id"].as_str())
                            .cloned()
                            .collect::<Vec<_>>());
                        Ok(context)
                    }
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
                .map_err(Into::into)
            })
        })
    }

    fn store_host(
        store: crate::library::Library,
        native: Option<Arc<crate::native::Native>>,
    ) -> Capability {
        Arc::new({
            let store = store.clone();
            move |method, params, _task, lease| {
                let store = store.clone();
                let native = native.clone();
                Box::pin(async move {
                    lease.ensure_active()?;
                    if let Some(native) = native {
                        if method == "transcribe" {
                            let index = store.index();
                            let audio = index.audio(crate::store::text(&params, "recordingId")?)?;
                            let model = json!(index.settings.whisper_model.as_ref());
                            return native.transcribe(&audio, model, params).await;
                        }
                        if method == "summarize" || method == "ask" {
                            return native.call(&method, params).await;
                        }
                    }
                    let text = |key: &str| crate::store::text(&params, key).map(str::to_owned);
                    match method.as_str() {
                        "runtime_context" => {
                            store
                                .runtime_context(params["recordingId"].as_str().map(str::to_owned))
                                .await
                        }
                        "transcribe" => Ok(json!({"text":"Audio sintético","segments":[]})),
                        "recording_update" | "version_save" | "version_select"
                        | "version_update" | "log" => {
                            store.mutate(method.clone(), params.clone()).await
                        }
                        "memory_recall" => Ok(store
                            .memory_recall(
                                text("recordingId")?,
                                text("versionId")?,
                                text("fingerprint")?,
                            )
                            .await?
                            .unwrap_or(Value::Null)),
                        "memory_keep" => {
                            store
                                .memory_keep(
                                    text("recordingId")?,
                                    text("versionId")?,
                                    text("fingerprint")?,
                                    params["value"].clone(),
                                )
                                .await?;
                            Ok(Value::Null)
                        }
                        "trace_save" => {
                            store.trace_save(params.clone()).await?;
                            Ok(Value::Null)
                        }
                        _ => Err(format!("Capacidad inesperada: {method}")),
                    }
                    .map_err(Into::into)
                })
            }
        })
    }

    #[tokio::test]
    #[ignore = "Requiere Whisper y Apple Intelligence ya instalados; solo audio sintético"]
    async fn receta_predeterminada_transcribe_y_resume_con_motores_locales() {
        let directory = tempfile::tempdir().unwrap();
        let audio = directory.path().join("synthetic.aiff");
        let status = Command::new("/usr/bin/say")
            .args(["-v", "Mónica", "-o"])
            .arg(&audio)
            .arg("Esta es una prueba de transcripción de Escriba. El equipo ha decidido revisar el diseño mañana. Después guardaremos un resumen y comprobaremos que no se pierde la grabación.")
            .status().await.unwrap();
        assert!(status.success());
        let native = Arc::new(crate::native::Native::new(
            crate::native::binary("EscribaNativeHost").unwrap(),
        ));
        let available = native.call("status", json!({})).await.unwrap();
        assert_eq!(
            available["whisper"]["available"], true,
            "Whisper no está instalado"
        );
        assert_eq!(
            available["llm"]["available"], true,
            "Apple Intelligence no está disponible"
        );
        let library = directory.path().join("library");
        let mut store = crate::store::Store::open(library.clone()).await.unwrap();
        let recording = store.import(&audio, None).await.unwrap();
        let recording_id = recording["id"].as_str().unwrap().to_owned();
        let store = crate::library::Library::new(store).await.unwrap();
        let capability = store_host(store.clone(), Some(native));
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        tokio::time::timeout(
            Duration::from_secs(180),
            scripts.call(
                "real-local",
                "processRecording",
                json!({"recordingId":recording_id}),
                capability.clone(),
                Arc::new(|_| {}),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        drop(scripts);
        drop(capability);
        drop(store);
        tokio::task::yield_now().await;
        let reopened = crate::store::Store::open(library).await.unwrap();
        let saved = reopened.recording(&recording_id).await.unwrap();
        assert_eq!(saved["status"], "done");
        let version = &saved["versions"][0];
        assert!(version["transcript"]["text"].as_str().unwrap().len() > 20);
        assert!(version["transcript"]["duration"].as_f64().unwrap() > 1.0);
        assert!(!version["transcript"]["segments"]
            .as_array()
            .unwrap()
            .is_empty());
        assert!(!version["digest"]["summary"].as_str().unwrap().is_empty());
        assert!(!version["digest"]["title"].as_str().unwrap().is_empty());
        assert!(version["inputs"]["speakers"].is_null());
        assert!(saved["publications"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn error_nativo_cruza_bun_y_la_cola_con_codigo_de_reintento() {
        let directory = tempfile::tempdir().unwrap();
        let audio = directory.path().join("synthetic.wav");
        std::fs::write(&audio, b"synthetic audio").unwrap();
        let store = crate::library::Library::new(
            crate::store::Store::open(directory.path().join("library"))
                .await
                .unwrap(),
        )
        .await
        .unwrap();
        let recording = store.import(&audio).await.unwrap();
        let recording_id = recording["id"].as_str().unwrap().to_owned();
        let queue = crate::jobs::Queue::new(store).await.unwrap();
        let id = queue
            .enqueue("processRecording", json!({"recordingId":recording_id}))
            .await
            .unwrap();
        queue
            .claim(crate::jobs::Lane::Inference)
            .await
            .unwrap()
            .unwrap();
        let native = Arc::new(crate::native::Native::new(
            crate::native::binary("EscribaNativeHost").unwrap(),
        ));
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        let mut state = fixture();
        state["recordings"][0]["id"] = json!(recording_id);
        let fake = fake_host(Arc::new(StdMutex::new(state)));
        let capability: Capability = Arc::new(move |method, params, task, lease| {
            if method == "transcribe" {
                let native = native.clone();
                let audio = audio.clone();
                Box::pin(async move {
                    lease.ensure_active()?;
                    native
                        .transcribe(&audio, json!("escriba_test_model_not_installed"), params)
                        .await
                })
            } else {
                fake(method, params, task, lease)
            }
        });
        let error = tokio::time::timeout(
            Duration::from_secs(20),
            scripts.call(
                &id,
                "processRecording",
                json!({"recordingId":recording_id}),
                capability,
                Arc::new(|_| {}),
            ),
        )
        .await
        .unwrap()
        .unwrap_err();
        assert_eq!(error.code, ErrorCode::BackendUnavailable);
        assert!(!error.message.contains("speakers"), "{error}");
        queue.finish(&id, Err(error)).await.unwrap();
        let saved = queue
            .jobs()
            .await
            .unwrap()
            .into_iter()
            .find(|job| job["id"] == id)
            .unwrap();
        assert_eq!(saved["state"], "retry");
        assert_eq!(saved["errorCode"], "backend_unavailable");
    }

    #[tokio::test]
    async fn procesa_nota_con_biblioteca_mayor_que_el_canal() {
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        let mut data = fixture();
        let mut historical = data["recordings"][0].clone();
        historical["id"] = json!("other-recording");
        historical["versions"] = json!([{"id":"historical-version","transcript":{"text":"x".repeat(33 * 1024 * 1024),"segments":[]}}]);
        data["recordings"].as_array_mut().unwrap().push(historical);
        let directory = tempfile::tempdir().unwrap();
        let mut store = crate::store::Store::open(directory.path().join("library"))
            .await
            .unwrap();
        data["schemaVersion"] = json!(1);
        store.replace(data.clone()).await.unwrap();
        assert!(store.snapshot().await.unwrap().to_string().len() > MAX_FRAME as usize);
        let library = store.root.clone();
        let store = crate::library::Library::new(store).await.unwrap();
        let capability = store_host(store.clone(), None);
        tokio::time::timeout(
            Duration::from_secs(20),
            scripts.call(
                "large-library",
                "processRecording",
                json!({"recordingId":"r"}),
                capability.clone(),
                Arc::new(|_| {}),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(store.recording("r".into()).await.unwrap()["status"], "done");
        drop(scripts);
        drop(capability);
        drop(store);
        tokio::task::yield_now().await;
        let reopened = crate::store::Store::open(library).await.unwrap();
        let processed = reopened.recording("r").await.unwrap();
        assert_eq!(processed["status"], "done");
        assert_eq!(processed["versions"].as_array().unwrap().len(), 1);
        assert_eq!(
            processed["versions"][0]["transcript"]["text"],
            "Audio sintético"
        );
        assert_eq!(
            processed["currentVersionId"],
            processed["versions"][0]["id"]
        );
        let preserved = reopened.recording("other-recording").await.unwrap();
        assert_eq!(preserved["versions"][0]["id"], "historical-version");
        assert_eq!(
            preserved["versions"][0]["transcript"]["text"]
                .as_str()
                .unwrap()
                .len(),
            33 * 1024 * 1024
        );
    }

    #[tokio::test]
    async fn respuesta_demasiado_grande_falla_y_permite_otro_trabajo() {
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        let state = Arc::new(StdMutex::new(fixture()));
        let fake = fake_host(state);
        let capability: Capability = Arc::new(move |method, params, task, lease| {
            if method == "runtime_context" && params["recordingId"] == "r" {
                Box::pin(async move {
                    lease.ensure_active()?;
                    Ok(json!({"large":"x".repeat(MAX_FRAME as usize)}))
                })
            } else {
                fake(method, params, task, lease)
            }
        });
        let events: Events = Arc::new(|_| {});
        let error = tokio::time::timeout(
            Duration::from_secs(10),
            scripts.call(
                "oversized",
                "processRecording",
                json!({"recordingId":"r"}),
                capability.clone(),
                events.clone(),
            ),
        )
        .await
        .unwrap()
        .unwrap_err();
        assert!(error.message.contains("32 MiB"), "{error}");
        let schema = tokio::time::timeout(
            Duration::from_secs(10),
            scripts.call(
                "next",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                capability,
                events,
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(schema["properties"]["idioma"].is_object());
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
    async fn receta_compilada_con_paquete_local_se_ejecuta_en_bun() {
        let directory = tempfile::tempdir().unwrap();
        let recipe = directory.path().join("recetas/paquete");
        let dependency = directory.path().join("node_modules/demo-package");
        std::fs::create_dir_all(&recipe).unwrap();
        std::fs::create_dir_all(&dependency).unwrap();
        std::fs::write(
            dependency.join("package.json"),
            r#"{"name":"demo-package","version":"1.0.0","main":"index.js"}"#,
        )
        .unwrap();
        std::fs::write(
            dependency.join("index.js"),
            "export const marker = 'paquete-del-usuario';",
        )
        .unwrap();
        std::fs::write(
            recipe.join("receta.ts"),
            "import { marker } from 'demo-package'; export const receta={nombre:marker}; export async function flujo(audio,api){if(marker!=='paquete-del-usuario')throw Error('Paquete incorrecto');await(await api.transcribir(audio)).guardar()}",
        )
        .unwrap();
        let vendor = Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor");
        let runtime = crate::native::binary("escriba-runtime").unwrap();
        let catalog = crate::project::build(directory.path(), &runtime, &vendor).unwrap();
        let mut data = fixture();
        data["recipes"] = catalog["recipes"].clone();
        data["settings"]["defaultRecipeId"] = json!("paquete");
        let state = Arc::new(StdMutex::new(data));
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        scripts
            .call(
                "external-package",
                "processRecording",
                json!({"recordingId":"r"}),
                fake_host(state.clone()),
                Arc::new(|_| {}),
            )
            .await
            .unwrap();
        assert_eq!(state.lock().unwrap()["recordings"][0]["status"], "done");
    }

    #[tokio::test]
    async fn receta_no_puede_leer_un_archivo_fuera_del_runtime() {
        let directory = tempfile::tempdir().unwrap();
        let canary = directory.path().join("canary");
        std::fs::write(&canary, b"synthetic").unwrap();
        let path = serde_json::to_string(&canary.to_string_lossy()).unwrap();
        let program = format!(
            "var __recipe={{async flujo(audio,api){{let denied=false;try{{await(await import('node:fs/promises')).readFile({path})}}catch(error){{denied=error.code==='EPERM'||error.code==='EACCES'}}if(!denied)throw Error('La receta leyó un archivo');await(await api.transcribir(audio)).guardar()}}}}"
        );
        let mut data = fixture();
        data["recipes"][0] =
            json!({"id":"default","name":"Prueba","kind":"code","values":{},"bundle":program});
        let state = Arc::new(StdMutex::new(data));
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        tokio::time::timeout(
            Duration::from_secs(20),
            scripts.call(
                "sandbox-file",
                "processRecording",
                json!({"recordingId":"r"}),
                fake_host(state.clone()),
                Arc::new(|_| {}),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(state.lock().unwrap()["recordings"][0]["status"], "done");
    }

    #[tokio::test]
    async fn fuga_de_memoria_termina_worker_y_conserva_controlador() {
        let scripts = Scripts::new(crate::native::binary("escriba-runtime").unwrap());
        let mut data = fixture();
        data["recipes"][0] = json!({
            "id":"default","name":"Fuga","kind":"code","values":{},
            "bundle":"var __recipe={async flujo(){globalThis.leak=[];for(let i=0;i<600;i++)globalThis.leak.push(new Array(131072).fill(i));await new Promise(()=>{})}}"
        });
        let state = Arc::new(StdMutex::new(data));
        let capability = fake_host(state.clone());
        let events: Events = Arc::new(|_| {});
        let error = tokio::time::timeout(
            Duration::from_secs(8),
            scripts.call(
                "memory",
                "processRecording",
                json!({"recordingId":"r"}),
                capability.clone(),
                events.clone(),
            ),
        )
        .await
        .expect("La fuga no terminó a tiempo")
        .unwrap_err();
        assert!(error.message.contains("512 MiB"), "{error}");
        state.lock().unwrap()["recipes"][0] =
            json!({"id":"default","name":"Por defecto","kind":"form","values":{"resumir":false}});
        scripts
            .call(
                "schema-after-memory",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                capability,
                events,
            )
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn fallo_al_arrancar_muestra_diagnostico_del_sandbox() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("runtime-no-ejecutable");
        std::fs::write(&executable, b"synthetic").unwrap();
        let scripts = Scripts::new(executable);
        let error = scripts
            .call(
                "startup-error",
                "getRecipeSchema",
                json!({"recipeId":"default"}),
                fake_host(Arc::new(StdMutex::new(fixture()))),
                Arc::new(|_| {}),
            )
            .await
            .unwrap_err();
        assert!(error.message.contains("sandbox-exec"), "{error}");
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
        assert!(error.message.contains("cancelado"), "{error}");
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
                    if method != "runtime_context" {
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
        assert!(error.message.contains("cancelado"), "{error}");
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(!wrote.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn rejects_incomplete_frames() {
        let mut input = BufReader::new(b"{\"type\":\"result\"}".as_slice());
        assert!(frame(&mut input)
            .await
            .unwrap_err()
            .message
            .contains("incompleto"));
    }

    async fn protocol_error_reaches_running_job(invalid: &[u8], expected: &str) {
        let path = crate::native::binary("escriba-runtime").unwrap();
        let (mut child, _stderr) = spawn(&path, false).unwrap();
        let mut input = child.stdin.take().unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        assert_eq!(frame(&mut output).await.unwrap()["type"], "ready");
        input.write_all(b"{\"type\":\"run\",\"id\":\"broken\",\"operation\":\"processRecording\",\"args\":{\"recordingId\":\"r\"}}\n").await.unwrap();
        loop {
            if frame(&mut output).await.unwrap()["type"] == "call" {
                break;
            }
        }
        input.write_all(invalid).await.unwrap();
        input.flush().await.unwrap();
        let result = tokio::time::timeout(Duration::from_secs(5), frame(&mut output))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result["type"], "error");
        assert_eq!(result["id"], "broken");
        assert!(
            result["message"].as_str().unwrap().contains(expected),
            "{result}"
        );
    }

    #[tokio::test]
    async fn protocolo_invalido_informa_al_trabajo_activo() {
        protocol_error_reaches_running_job(b"not-json\n", "JSON").await;
    }

    #[tokio::test]
    async fn trama_entrante_grande_informa_al_trabajo_activo() {
        let mut oversized = vec![b' '; MAX_FRAME as usize + 1];
        oversized.push(b'\n');
        protocol_error_reaches_running_job(&oversized, "32 MiB").await;
    }
}
