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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    Ui,
    Shell,
}
impl Origin {
    fn label(self) -> &'static str {
        match self {
            Origin::Ui => "ui",
            Origin::Shell => "shell",
        }
    }
}
pub type Capability = Arc<
    dyn Fn(String, Value) -> Pin<Box<dyn Future<Output = Result<Value, AppError>> + Send>>
        + Send
        + Sync,
>;
pub type Events = Arc<dyn Fn(Value) + Send + Sync>;
struct PendingTask {
    reply: oneshot::Sender<Result<Value, AppError>>,
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
    child: Mutex<Child>,
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
    env: Vec<(String, String)>,
    session: Mutex<Option<Arc<Session>>>,
    closed: AtomicBool,
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
fn spawn(
    path: &Path,
    worker: bool,
    env: &[(String, String)],
) -> Result<(Child, StderrCapture), String> {
    let executable = path
        .canonicalize()
        .map_err(|e| format!("No se pudo localizar el motor TypeScript: {e}"))?;
    if !executable.is_file() {
        return Err("El motor TypeScript no es un archivo".into());
    }
    // Only recipe workers are isolated; the controller needs the library and the network.
    let mut command = if worker && crate::platform::recipes_isolated() {
        let mut command = Command::new("/usr/bin/sandbox-exec");
        command
            .arg("-p")
            .arg(SANDBOX)
            .arg("-D")
            .arg(format!("EXECUTABLE={}", executable.display()))
            .arg(executable)
            .arg("--worker");
        command
    } else {
        let mut command = Command::new(executable);
        if worker {
            command.arg("--worker");
        }
        command
    };
    let mut child = command
        .env_clear()
        .envs(
            env.iter()
                .map(|(key, value)| (key.as_str(), value.as_str())),
        )
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
#[cfg(target_os = "macos")]
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
#[cfg(target_os = "macos")]
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
#[cfg(target_os = "linux")]
fn resident_bytes(pid: i32) -> Option<u64> {
    let statm = std::fs::read_to_string(format!("/proc/{pid}/statm")).ok()?;
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    statm_resident_bytes(&statm, u64::try_from(page).ok()?)
}
#[cfg(target_os = "linux")]
fn process_identity(pid: i32) -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat_start_ticks(&stat).map(|ticks| (ticks, 0))
}
// Between fork and exec Linux shows a copy of this process, with its memory.
#[cfg(target_os = "linux")]
fn still_forking(pid: i32) -> bool {
    match (
        std::fs::read_link(format!("/proc/{pid}/exe")),
        std::env::current_exe(),
    ) {
        (Ok(child), Ok(own)) => child == own,
        _ => false,
    }
}
#[cfg(not(target_os = "linux"))]
fn still_forking(_: i32) -> bool {
    false
}
#[cfg(any(target_os = "linux", test))]
fn statm_resident_bytes(statm: &str, page: u64) -> Option<u64> {
    let pages: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
    pages.checked_mul(page)
}
// The command name in field 2 may contain spaces and parentheses.
#[cfg(any(target_os = "linux", test))]
fn stat_start_ticks(stat: &str) -> Option<u64> {
    let (_, fields) = stat.rsplit_once(") ")?;
    fields.split_whitespace().nth(19)?.parse().ok()
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
    if still_forking(pid) {
        return Some(identity);
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
fn command_timeout(method: &str) -> Duration {
    if method == "runtime_run" {
        Duration::from_secs(7200)
    } else {
        Duration::from_secs(1800)
    }
}
impl Scripts {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            env: Vec::new(),
            session: Mutex::new(None),
            closed: AtomicBool::new(false),
        }
    }
    pub fn with_env(mut self, env: Vec<(String, String)>) -> Self {
        self.env = env;
        self
    }
    pub async fn start(&self, capability: Capability, events: Events) -> Result<(), AppError> {
        self.session(capability, events).await.map(|_| ())
    }
    async fn session(
        &self,
        capability: Capability,
        events: Events,
    ) -> Result<Arc<Session>, AppError> {
        let mut slot = self.session.lock().await;
        if self.closed.load(Ordering::SeqCst) {
            return Err(AppError::new(
                ErrorCode::RuntimeUnavailable,
                "El motor TypeScript ya se cerró",
            ));
        }
        if let Some(session) = slot.as_ref().filter(|s| s.alive.load(Ordering::SeqCst)) {
            return Ok(session.clone());
        }
        if let Some(previous) = slot.take() {
            let mut child = previous.child.lock().await;
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
        let (mut child, mut stderr) = spawn(&self.path, false, &self.env)
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
                            let _ = task.reply.send(result);
                        }
                    }
                    "event" => events(value),
                    "call" => {
                        let method = value["method"].as_str().unwrap_or("").to_owned();
                        let input = reader_input.clone();
                        let callback = capability.clone();
                        let pending = reader_pending.clone();
                        let workers = reader_workers.clone();
                        let alive = reader_alive.clone();
                        tokio::spawn(async move {
                            let result = callback(method, value["params"].clone()).await;
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
                        if key.is_empty() || slots.contains_key(&key) || slots.len() >= 8 {
                            let _ = send(&reader_input, &json!({"type":"worker_error","id":key,"message":"No se puede abrir este proceso de receta"})).await;
                            continue;
                        }
                        let result = (|| {
                            let (mut child, stderr) = spawn(&path, true, &[])?;
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
                let _ = task.reply.send(Err(error.clone()));
            }
        });
        let session = Arc::new(Session {
            child: Mutex::new(child),
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
    pub async fn command(
        &self,
        method: &str,
        params: Value,
        origin: Origin,
        capability: Capability,
        events: Events,
    ) -> Result<Value, AppError> {
        let session = self.session(capability, events).await?;
        let id = format!("command-{}", uuid::Uuid::new_v4());
        let (tx, rx) = oneshot::channel();
        session
            .pending
            .lock()
            .await
            .insert(id.clone(), PendingTask { reply: tx });
        if let Err(error) = send(
            &session.input,
            &json!({"type":"command","id":id,"method":method,"params":params,"origin":origin.label()}),
        )
        .await
        {
            session.pending.lock().await.remove(&id);
            session.alive.store(false, Ordering::SeqCst);
            return Err(error);
        }
        let limit = command_timeout(method);
        match tokio::time::timeout(limit, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(AppError::new(
                ErrorCode::RuntimeUnavailable,
                "El proceso TypeScript perdió el comando",
            )),
            Err(_) => {
                self.cancel(&id).await;
                Err(AppError::new(
                    ErrorCode::Failed,
                    format!("El comando superó {} minutos", limit.as_secs() / 60),
                ))
            }
        }
    }
    pub async fn cancel(&self, id: &str) {
        let session = self.session.lock().await.clone();
        if let Some(session) = session {
            if let Some(task) = session.pending.lock().await.remove(id) {
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
    pub async fn shutdown(&self) {
        let mut slot = self.session.lock().await;
        self.closed.store(true, Ordering::SeqCst);
        let Some(session) = slot.take() else { return };
        session.alive.store(false, Ordering::SeqCst);
        let graceful =
            tokio::time::timeout(Duration::from_secs(5), async {
                send(&session.input, &json!({"type":"shutdown","id":"shutdown"})).await?;
                session.child.lock().await.wait().await.map_err(|error| {
                    AppError::new(ErrorCode::RuntimeUnavailable, error.to_string())
                })?;
                Ok::<(), AppError>(())
            })
            .await;
        if !matches!(graceful, Ok(Ok(()))) {
            let mut child = session.child.lock().await;
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
        session.workers.lock().await.clear();
        for (_, task) in session.pending.lock().await.drain() {
            let _ = task.reply.send(Err(AppError::new(
                ErrorCode::RuntimeUnavailable,
                "El motor TypeScript se cerró",
            )));
        }
    }
}

#[cfg(test)]
pub(crate) fn controller_env(data: &Path) -> Vec<(String, String)> {
    let (package, file) = crate::platform::surreal_native();
    let native = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../node_modules/@surrealdb")
        .join(package)
        .join(file);
    vec![
        ("ESCRIBA_DATA".into(), data.to_string_lossy().into_owned()),
        (
            "NAPI_RS_NATIVE_LIBRARY_PATH".into(),
            native.to_string_lossy().into_owned(),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    #[test]
    fn memoria_residente_sale_de_la_segunda_columna_de_statm() {
        assert_eq!(
            statm_resident_bytes("5000 1200 300 10 0 900 0\n", 4096),
            Some(1200 * 4096)
        );
        assert_eq!(statm_resident_bytes("5000\n", 4096), None);
        assert_eq!(statm_resident_bytes("", 4096), None);
    }

    #[test]
    fn inicio_del_proceso_ignora_parentesis_en_el_nombre() {
        let stat = "4242 (bun (worker) x) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 4 0 987654 1000 300";
        assert_eq!(stat_start_ticks(stat), Some(987654));
        assert_eq!(stat_start_ticks("4242 (bun) S 1"), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_el_propio_proceso_tiene_memoria_e_identidad_estable() {
        let pid = std::process::id() as i32;
        assert!(resident_bytes(pid).is_some_and(|bytes| bytes > 0));
        let identity = process_identity(pid).unwrap();
        assert_eq!(process_identity(pid), Some(identity));
        assert_eq!(resident_bytes(i32::MAX), None);
        assert_eq!(process_identity(i32::MAX), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn en_linux_no_se_mide_la_memoria_de_una_copia_previa_al_exec() {
        assert!(still_forking(std::process::id() as i32));
        let mut other = std::process::Command::new("sleep")
            .arg("5")
            .spawn()
            .unwrap();
        while std::fs::read_link(format!("/proc/{}/exe", other.id())).ok()
            == std::env::current_exe().ok()
        {
            std::thread::yield_now();
        }
        assert!(!still_forking(other.id() as i32));
        other.kill().unwrap();
        other.wait().unwrap();
        assert!(!still_forking(i32::MAX));
    }

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
        tokio::time::timeout(Duration::from_secs(10), async {
            while !condition().await {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("No llegó el estado esperado del sidecar");
    }

    /// Cáscara falsa: solo contesta a lo nativo que el controlador pide al arrancar y al trabajar.
    fn shell(calls: Arc<StdMutex<Vec<String>>>) -> Capability {
        Arc::new(move |method, params| {
            let calls = calls.clone();
            Box::pin(async move {
                calls.lock().unwrap().push(method.clone());
                match method.as_str() {
                    "shell.native" => match params["method"].as_str() {
                        Some("status") => Ok(
                            json!({"protocolVersion":1,"whisper":{"available":true},"llm":{"available":true}}),
                        ),
                        Some("transcribe") => Ok(json!({"text":"Audio sintético","segments":[]})),
                        Some(other) => Err(format!("Método nativo inesperado: {other}").into()),
                        None => Err("Método nativo ausente".into()),
                    },
                    "shell.notify" | "shell.native_cancel" | "shell.autolaunch" => Ok(Value::Null),
                    _ => Err(format!("Capacidad inesperada: {method}").into()),
                }
            })
        })
    }

    fn runtime(data: &Path) -> Scripts {
        Scripts::new(crate::native::binary("escriba-runtime").unwrap())
            .with_env(controller_env(data))
    }

    async fn command(
        scripts: &Scripts,
        method: &str,
        params: Value,
        origin: Origin,
        cap: &Capability,
    ) -> Result<Value, AppError> {
        scripts
            .command(method, params, origin, cap.clone(), Arc::new(|_| {}))
            .await
    }

    #[tokio::test]
    async fn fallo_al_arrancar_muestra_diagnostico() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("runtime-no-ejecutable");
        std::fs::write(&executable, b"synthetic").unwrap();
        let scripts = Scripts::new(executable);
        let cap = shell(Arc::new(StdMutex::new(Vec::new())));
        let error = command(&scripts, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::RuntimeUnavailable);
        assert!(
            error.message.contains("No se pudo iniciar TypeScript"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn una_biblioteca_ilegible_impide_arrancar_con_su_motivo() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("library.surrealkv"), b"legacy").unwrap();
        let scripts = runtime(directory.path());
        let cap = shell(Arc::new(StdMutex::new(Vec::new())));
        let error = command(&scripts, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::RuntimeUnavailable);
        assert!(error.message.contains("SurrealKV"), "{error}");
    }

    #[tokio::test]
    async fn el_controlador_abre_su_biblioteca_y_reinicia_tras_caerse() {
        let directory = tempfile::tempdir().unwrap();
        let scripts = runtime(directory.path());
        let calls = Arc::new(StdMutex::new(Vec::new()));
        let cap = shell(calls.clone());
        let status = command(&scripts, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap();
        assert_eq!(
            status["dataPath"],
            json!(directory.path().to_string_lossy())
        );
        assert!(directory.path().join("library.rocksdb").is_dir());
        assert_eq!(
            command(
                &scripts,
                "import_inbox",
                json!({"files":[]}),
                Origin::Ui,
                &cap
            )
            .await
            .unwrap_err()
            .message,
            "Origen no permitido para import_inbox"
        );
        wait_until(|| async { calls.lock().unwrap().contains(&"shell.native".to_owned()) }).await;
        let old = scripts.session.lock().await.clone().unwrap();
        let old_pid = old.child.lock().await.id().unwrap();
        unsafe {
            libc::kill(old_pid as i32, libc::SIGKILL);
        }
        wait_until(|| async { !old.alive.load(Ordering::SeqCst) }).await;
        let again = command(&scripts, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap();
        assert_eq!(again["protocolVersion"], 1);
        assert_ne!(
            scripts
                .session
                .lock()
                .await
                .as_ref()
                .unwrap()
                .child
                .lock()
                .await
                .id(),
            Some(old_pid)
        );
    }

    #[tokio::test]
    async fn cierre_ordenado_libera_la_biblioteca_para_otro_controlador() {
        let directory = tempfile::tempdir().unwrap();
        let scripts = runtime(directory.path());
        let cap = shell(Arc::new(StdMutex::new(Vec::new())));
        command(&scripts, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap();
        let session = scripts.session.lock().await.clone().unwrap();
        let pid = session.child.lock().await.id().unwrap();
        scripts.shutdown().await;
        assert!(scripts.session.lock().await.is_none());
        assert!(!session.alive.load(Ordering::SeqCst));
        assert!(session.child.lock().await.try_wait().unwrap().is_some());
        let closed = command(&scripts, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap_err();
        assert_eq!(closed.code, ErrorCode::RuntimeUnavailable);
        assert!(scripts.session.lock().await.is_none());
        let second = runtime(directory.path());
        let status = command(&second, "controller_status", json!({}), Origin::Ui, &cap)
            .await
            .unwrap();
        assert_eq!(status["protocolVersion"], 1);
        assert_ne!(
            second
                .session
                .lock()
                .await
                .as_ref()
                .unwrap()
                .child
                .lock()
                .await
                .id(),
            Some(pid)
        );
        second.shutdown().await;
    }

    #[tokio::test]
    async fn cancelar_una_nota_cierra_su_worker_y_deja_el_controlador_usable() {
        let directory = tempfile::tempdir().unwrap();
        let scripts = Arc::new(runtime(directory.path()));
        let cap = shell(Arc::new(StdMutex::new(Vec::new())));
        command(&scripts, "config_save", json!({"collection":"recipes","item":{"id":"default","name":"Bucle","kind":"code","values":{},"bundle":"var __recipe={flujo(){while(true){}}}"}}), Origin::Ui, &cap).await.unwrap();
        command(
            &scripts,
            "settings_save",
            json!({"settings":{"defaultRecipeId":"default"}}),
            Origin::Ui,
            &cap,
        )
        .await
        .unwrap();
        let inbox = directory.path().join("nota.wav");
        std::fs::write(&inbox, b"audio sintetico").unwrap();
        let imported = command(
            &scripts,
            "import_inbox",
            json!({"files":[{"inbox":inbox,"source":"/origen/nota.wav"}]}),
            Origin::Shell,
            &cap,
        )
        .await
        .unwrap();
        let recording = imported[0]["id"].as_str().unwrap().to_owned();
        wait_until(|| async {
            let session = scripts.session.lock().await.clone();
            if let Some(session) = session {
                !session.workers.lock().await.is_empty()
            } else {
                false
            }
        })
        .await;
        command(
            &scripts,
            "runtime_cancel",
            json!({"recordingId":recording}),
            Origin::Ui,
            &cap,
        )
        .await
        .unwrap();
        wait_until(|| async {
            let session = scripts.session.lock().await.clone().unwrap();
            let empty = session.workers.lock().await.is_empty();
            empty
        })
        .await;
        let jobs = command(&scripts, "runtime_jobs", json!({}), Origin::Ui, &cap)
            .await
            .unwrap();
        assert!(jobs.as_array().unwrap().is_empty(), "{jobs}");
        command(&scripts, "config_save", json!({"collection":"recipes","item":{"id":"default","name":"Por defecto","kind":"form","values":{"resumir":false}}}), Origin::Ui, &cap).await.unwrap();
        let schema = tokio::time::timeout(
            Duration::from_secs(10),
            command(
                &scripts,
                "runtime_run",
                json!({"operation":"getRecipeSchema","args":{"recipeId":"default"}}),
                Origin::Ui,
                &cap,
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(schema["properties"]["idioma"].is_object());
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

    async fn protocol_error_reaches_pending_command(invalid: &[u8], expected: &str) {
        let directory = tempfile::tempdir().unwrap();
        let path = crate::native::binary("escriba-runtime").unwrap();
        let (mut child, _stderr) = spawn(&path, false, &controller_env(directory.path())).unwrap();
        let mut input = child.stdin.take().unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        assert_eq!(frame(&mut output).await.unwrap()["type"], "ready");
        input.write_all(b"{\"type\":\"command\",\"id\":\"broken\",\"method\":\"runtime_run\",\"params\":{\"operation\":\"getRecipeSchema\",\"args\":{\"recipeId\":\"inexistente\"}},\"origin\":\"ui\"}\n").await.unwrap();
        input.write_all(invalid).await.unwrap();
        input.flush().await.unwrap();
        let result = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let value = frame(&mut output).await.unwrap();
                if value["type"] == "error" && value["id"] == "broken" {
                    return value;
                }
            }
        })
        .await
        .unwrap();
        assert!(
            result["message"].as_str().unwrap().contains(expected),
            "{result}"
        );
    }

    #[tokio::test]
    async fn protocolo_invalido_informa_al_comando_pendiente() {
        protocol_error_reaches_pending_command(b"not-json\n", "JSON").await;
    }

    #[tokio::test]
    async fn trama_entrante_grande_informa_al_comando_pendiente() {
        let directory = tempfile::tempdir().unwrap();
        let path = crate::native::binary("escriba-runtime").unwrap();
        let (mut child, mut stderr) =
            spawn(&path, false, &controller_env(directory.path())).unwrap();
        let mut input = child.stdin.take().unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        assert_eq!(frame(&mut output).await.unwrap()["type"], "ready");
        let mut oversized = vec![b' '; MAX_FRAME as usize + 1];
        oversized.push(b'\n');
        let _ = input.write_all(&oversized).await;
        drop(input);
        let status = tokio::time::timeout(Duration::from_secs(10), child.wait())
            .await
            .unwrap()
            .unwrap();
        assert!(!status.success());
        let error = stderr.startup_error(String::new()).await;
        assert!(error.contains("32 MiB"), "{error}");
    }
}
