use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    process::Stdio,
    sync::atomic::{AtomicU32, Ordering},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::Mutex,
};
const MAX_FRAME: u64 = 16 * 1024 * 1024;

async fn exchange(
    session: &mut Session,
    method: &str,
    params: Value,
) -> Result<Result<Value, String>, String> {
    let request_id = crate::store::id();
    let mut request = serde_json::to_vec(&json!({"id":request_id,"method":method,"params":params}))
        .map_err(|e| e.to_string())?;
    if request.len() as u64 > MAX_FRAME {
        return Err("Petición nativa demasiado grande".into());
    }
    request.push(b'\n');
    session
        .input
        .write_all(&request)
        .await
        .map_err(|e| format!("El motor perdió la conexión: {e}"))?;
    session.input.flush().await.map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    let count = (&mut session.output)
        .take(MAX_FRAME + 1)
        .read_until(b'\n', &mut bytes)
        .await
        .map_err(|e| format!("No se pudo leer el motor nativo: {e}"))?;
    if count == 0 {
        return Err("El motor nativo se detuvo o fue cancelado".into());
    }
    if count as u64 > MAX_FRAME || bytes.last() != Some(&b'\n') {
        return Err("Respuesta nativa demasiado grande o incompleta".into());
    }
    let response: Value = serde_json::from_slice(&bytes)
        .map_err(|_| "El motor devolvió una respuesta inválida".to_owned())?;
    if response["id"] != request_id {
        return Err("El motor respondió a otra petición".into());
    }
    if let Some(error) = response.get("error") {
        let message = error["message"]
            .as_str()
            .unwrap_or("Error del motor nativo");
        return Ok(Err(if error["code"] == "backend_unavailable" {
            format!("BACKEND_UNAVAILABLE: {message}")
        } else {
            message.to_owned()
        }));
    }
    Ok(Ok(response
        .get("result")
        .cloned()
        .ok_or("Respuesta incompleta del motor")?))
}

fn timeout_for(method: &str) -> Duration {
    match method {
        "status" => Duration::from_secs(10),
        "fileStatus" | "audioInfo" | "recordingStatus" => Duration::from_secs(20),
        "materialize" => Duration::from_secs(330),
        "transcribe" | "downloadModel" => Duration::from_secs(7200),
        _ => Duration::from_secs(600),
    }
}

struct Session {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    last_activity: Instant,
}
pub struct Native {
    path: PathBuf,
    session: Mutex<Option<Session>>,
    pid: AtomicU32,
}
impl Native {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            session: Mutex::new(None),
            pid: AtomicU32::new(0),
        }
    }
    pub async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let mut slot = self.session.lock().await;
        if let Some(session) = slot.as_mut() {
            if session
                .child
                .try_wait()
                .map_err(|e| e.to_string())?
                .is_some()
            {
                *slot = None;
                self.pid.store(0, Ordering::SeqCst);
            }
        }
        if slot.is_none() {
            let mut child = Command::new(&self.path)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .kill_on_drop(true)
                .spawn()
                .map_err(|e| {
                    format!(
                        "No se pudo abrir el motor nativo ({}): {e}",
                        self.path.display()
                    )
                })?;
            self.pid.store(child.id().unwrap_or(0), Ordering::SeqCst);
            let input = child.stdin.take().ok_or("Motor sin canal de entrada")?;
            let output = BufReader::new(child.stdout.take().ok_or("Motor sin canal de salida")?);
            let mut session = Session {
                child,
                input,
                output,
                last_activity: Instant::now(),
            };
            let hello = tokio::time::timeout(
                Duration::from_secs(10),
                exchange(&mut session, "status", json!({})),
            )
            .await;
            let compatible = match hello {
                Ok(Ok(Ok(status))) => status["protocolVersion"] == 1,
                _ => false,
            };
            if !compatible {
                let _ = session.child.kill().await;
                self.pid.store(0, Ordering::SeqCst);
                return Err(
                    "Versión de protocolo nativo incompatible o motor no disponible".into(),
                );
            }
            *slot = Some(session);
        }
        let result = {
            let session = slot.as_mut().ok_or("Motor no disponible")?;
            let result =
                tokio::time::timeout(timeout_for(method), exchange(session, method, params)).await;
            session.last_activity = Instant::now();
            result
        };
        match result {
            Ok(Ok(remote)) => remote,
            other => {
                if let Some(mut session) = slot.take() {
                    let _ = session.child.kill().await;
                }
                self.pid.store(0, Ordering::SeqCst);
                match other {
                    Ok(Err(error)) => Err(error),
                    Err(_) => Err(format!("El método nativo {method} superó su tiempo límite")),
                    _ => unreachable!(),
                }
            }
        }
    }
    pub fn cancel(&self) {
        let pid = self.pid.swap(0, Ordering::SeqCst);
        if let Ok(mut slot) = self.session.try_lock() {
            if let Some(mut session) = slot.take() {
                let _ = session.child.start_kill();
            }
        } else if pid > 0 {
            unsafe {
                libc::kill(pid as i32, libc::SIGTERM);
            }
        }
    }

    pub fn unload_if_idle(&self, idle: Duration) -> bool {
        let Ok(mut slot) = self.session.try_lock() else {
            return false;
        };
        if !slot
            .as_ref()
            .is_some_and(|session| session.last_activity.elapsed() >= idle)
        {
            return false;
        }
        if let Some(mut session) = slot.take() {
            let _ = session.child.start_kill();
            self.pid.store(0, Ordering::SeqCst);
            return true;
        }
        false
    }
}
impl Drop for Native {
    fn drop(&mut self) {
        self.cancel();
    }
}
pub fn binary(name: &str) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sibling = exe.parent().ok_or("Ejecutable sin carpeta")?.join(name);
    if sibling.is_file() {
        return Ok(sibling);
    }
    let triple = if cfg!(target_arch = "aarch64") {
        "aarch64-apple-darwin"
    } else {
        "x86_64-apple-darwin"
    };
    let development = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("binaries")
        .join(format!("{name}-{triple}"));
    if development.is_file() {
        return Ok(development);
    }
    Err(format!(
        "Falta {name}. Ejecuta scripts/build-tauri.sh para preparar los motores."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt};

    #[tokio::test]
    async fn rechaza_version_nativa_incompatible_antes_de_la_primera_operacion() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("fake-native");
        fs::write(&executable, "#!/bin/sh\nwhile IFS= read -r line; do\n  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p')\n  printf '{\"id\":\"%s\",\"result\":{\"protocolVersion\":2}}\\n' \"$id\"\ndone\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let native = Native::new(executable);
        let error = native.call("unknown", json!({})).await.unwrap_err();
        assert!(error.contains("protocolo nativo incompatible"), "{error}");
    }

    #[tokio::test]
    async fn packaged_native_protocol_recovers_after_invalid_request() {
        let native = Native::new(binary("EscribaNativeHost").unwrap());
        let status = native.call("status", json!({})).await.unwrap();
        assert_eq!(status["protocolVersion"], 1);
        assert!(native.call("unknown", json!({})).await.is_err());
        let again = native.call("status", json!({})).await.unwrap();
        assert_eq!(again["protocolVersion"], 1);
        assert!(again["whisper"]["modelsPath"].is_string());
        native.cancel();
        assert_eq!(
            native.call("status", json!({})).await.unwrap()["protocolVersion"],
            1
        );
    }

    #[tokio::test]
    async fn inactividad_descarga_motor_sin_cortar_peticion_en_curso() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("fake-native");
        let marker = directory.path().join("slow-started");
        let source = format!(
            "#!/bin/sh\nwhile IFS= read -r line; do\n  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p')\n  case \"$line\" in\n    *'\"method\":\"slow\"'*) touch '{}' ; sleep 0.2 ;;\n    *'\"method\":\"unavailable\"'*) printf '{{\"id\":\"%s\",\"error\":{{\"code\":\"backend_unavailable\",\"message\":\"modelo ausente\"}}}}\\n' \"$id\" ; continue ;;\n  esac\n  printf '{{\"id\":\"%s\",\"result\":{{\"protocolVersion\":1}}}}\\n' \"$id\"\ndone\n",
            marker.display()
        );
        fs::write(&executable, source).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let native = std::sync::Arc::new(Native::new(executable));
        let active = {
            let native = native.clone();
            tokio::spawn(async move { native.call("slow", json!({})).await })
        };
        tokio::time::timeout(Duration::from_secs(5), async {
            while !marker.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(!native.unload_if_idle(Duration::ZERO));
        assert_eq!(active.await.unwrap().unwrap()["protocolVersion"], 1);
        assert!(!native.unload_if_idle(Duration::from_secs(300)));
        assert!(native.unload_if_idle(Duration::ZERO));
        assert_eq!(native.pid.load(Ordering::SeqCst), 0);
        assert_eq!(
            native.call("status", json!({})).await.unwrap()["protocolVersion"],
            1
        );
        assert_eq!(
            native.call("unavailable", json!({})).await.unwrap_err(),
            "BACKEND_UNAVAILABLE: modelo ausente"
        );
    }

    #[tokio::test]
    async fn cancelacion_interrumpe_handshake_nativo() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("fake-native");
        let marker = directory.path().join("handshake-started");
        fs::write(
            &executable,
            format!(
                "#!/bin/sh\nIFS= read -r line\ntouch '{}'\nexec sleep 30\n",
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let native = std::sync::Arc::new(Native::new(executable));
        let call = {
            let native = native.clone();
            tokio::spawn(async move { native.call("status", json!({})).await })
        };
        tokio::time::timeout(Duration::from_secs(5), async {
            while !marker.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        native.cancel();
        assert!(tokio::time::timeout(Duration::from_secs(5), call)
            .await
            .unwrap()
            .unwrap()
            .is_err());
    }
}
