use crate::error::{AppError, ErrorCode};
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
    on_progress: &mut impl FnMut(f64),
) -> Result<Result<Value, AppError>, String> {
    let request_id = crate::util::id();
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
    loop {
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
        if let Some(progress) = response.get("progress") {
            let fraction = progress["fraction"]
                .as_f64()
                .filter(|fraction| fraction.is_finite() && (0.0..=1.0).contains(fraction))
                .ok_or("El motor devolvió un progreso inválido")?;
            on_progress(fraction);
            continue;
        }
        if let Some(error) = response.get("error") {
            let message = error["message"]
                .as_str()
                .unwrap_or("Error del motor nativo");
            let code = match error["code"].as_str() {
                Some("backend_unavailable") => ErrorCode::BackendUnavailable,
                Some("microphone_denied") => ErrorCode::MicrophoneDenied,
                _ => ErrorCode::Failed,
            };
            return Ok(Err(AppError::new(code, message)));
        }
        return Ok(Ok(response
            .get("result")
            .cloned()
            .ok_or("Respuesta incompleta del motor")?));
    }
}

fn timeout_for(method: &str) -> Duration {
    match method {
        "status" => Duration::from_secs(10),
        "fileStatus" | "audioInfo" | "recordingStatus" => Duration::from_secs(20),
        "materialize" => Duration::from_secs(330),
        "transcribe" | "diarizedVoices" | "downloadModel" | "combineAudio" => {
            Duration::from_secs(7200)
        }
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
    pub async fn transcribe(
        &self,
        audio: &Path,
        model: Value,
        mut params: Value,
    ) -> Result<Value, AppError> {
        params["audioPath"] = json!(audio);
        params["model"] = model;
        self.call("transcribe", params).await
    }

    pub async fn call(&self, method: &str, params: Value) -> Result<Value, AppError> {
        self.call_with_progress(method, params, |_| {}).await
    }

    pub async fn call_with_progress(
        &self,
        method: &str,
        params: Value,
        mut on_progress: impl FnMut(f64) + Send,
    ) -> Result<Value, AppError> {
        let mut slot = self.session.lock().await;
        if let Some(session) = slot.as_mut() {
            if session
                .child
                .try_wait()
                .map_err(|e| AppError::new(ErrorCode::RuntimeUnavailable, e.to_string()))?
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
                    AppError::new(
                        ErrorCode::RuntimeUnavailable,
                        format!(
                            "No se pudo abrir el motor nativo ({}): {e}",
                            self.path.display()
                        ),
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
                exchange(&mut session, "status", json!({}), &mut |_| {}),
            )
            .await;
            let compatible = match hello {
                Ok(Ok(Ok(status))) => status["protocolVersion"] == 1,
                _ => false,
            };
            if !compatible {
                let _ = session.child.kill().await;
                self.pid.store(0, Ordering::SeqCst);
                return Err(AppError::new(
                    ErrorCode::RuntimeUnavailable,
                    "Versión de protocolo nativo incompatible o motor no disponible",
                ));
            }
            *slot = Some(session);
        }
        let result = {
            let session = slot.as_mut().ok_or("Motor no disponible")?;
            let result = tokio::time::timeout(
                timeout_for(method),
                exchange(session, method, params, &mut on_progress),
            )
            .await;
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
                    Ok(Err(error)) => Err(AppError::new(ErrorCode::RuntimeUnavailable, error)),
                    Err(_) => Err(AppError::new(
                        ErrorCode::RuntimeUnavailable,
                        format!("El método nativo {method} superó su tiempo límite"),
                    )),
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
fn development_triple() -> &'static str {
    env!("TAURI_ENV_TARGET_TRIPLE")
}

// A host without a method (the Swift one, for per-model calls) answers so.
pub fn unsupported(error: &AppError) -> bool {
    error.message.starts_with("método desconocido")
}

pub fn binary(name: &str) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let sibling = exe.parent().ok_or("Ejecutable sin carpeta")?.join(name);
    if sibling.is_file() {
        return Ok(sibling);
    }
    let development = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("binaries")
        .join(format!("{name}-{}", development_triple()));
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
    async fn descarga_recibe_progreso_jsonl_y_conserva_la_respuesta_final() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("fake-native");
        fs::write(
            &executable,
            r#"#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  case "$line" in
    *'"method":"downloadModel"'*)
      printf '{"id":"%s","progress":{"fraction":0.25}}\n' "$id"
      printf '{"id":"%s","progress":{"fraction":0.75}}\n' "$id"
      printf '{"id":"%s","result":{"model":"prueba"}}\n' "$id" ;;
    *) printf '{"id":"%s","result":{"protocolVersion":1}}\n' "$id" ;;
  esac
done
"#,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let native = Native::new(executable);
        let mut fractions = Vec::new();
        let result = native
            .call_with_progress("downloadModel", json!({"model":"prueba"}), |fraction| {
                fractions.push(fraction);
            })
            .await
            .unwrap();
        assert_eq!(fractions, vec![0.25, 0.75]);
        assert_eq!(result["model"], "prueba");
        assert_eq!(
            native.call("status", json!({})).await.unwrap()["protocolVersion"],
            1
        );
    }

    #[tokio::test]
    async fn rechaza_version_nativa_incompatible_antes_de_la_primera_operacion() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("fake-native");
        fs::write(&executable, "#!/bin/sh\nwhile IFS= read -r line; do\n  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\"\\([^\"]*\\)\".*/\\1/p')\n  printf '{\"id\":\"%s\",\"result\":{\"protocolVersion\":2}}\\n' \"$id\"\ndone\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let native = Native::new(executable);
        let error = native.call("unknown", json!({})).await.unwrap_err();
        assert!(
            error.message.contains("protocolo nativo incompatible"),
            "{error}"
        );
    }

    #[test]
    fn un_metodo_que_el_host_no_conoce_se_reconoce_para_volver_al_comportamiento_anterior() {
        assert!(unsupported(&AppError::new(
            ErrorCode::Failed,
            "método desconocido: models"
        )));
        assert!(!unsupported(&AppError::new(
            ErrorCode::Failed,
            "el modelo base no está descargado"
        )));
    }

    #[test]
    fn el_triple_de_desarrollo_es_el_del_objetivo_de_compilacion() {
        let expected = match (std::env::consts::OS, std::env::consts::ARCH) {
            ("macos", "aarch64") => "aarch64-apple-darwin",
            ("macos", "x86_64") => "x86_64-apple-darwin",
            ("linux", "aarch64") => "aarch64-unknown-linux-gnu",
            ("linux", "x86_64") => "x86_64-unknown-linux-gnu",
            other => panic!("plataforma no soportada: {other:?}"),
        };
        assert_eq!(development_triple(), expected);
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
            AppError::new(ErrorCode::BackendUnavailable, "modelo ausente")
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
