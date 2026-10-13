use crate::{inbox, watcher};
use serde_json::{json, Value};
use std::{
    fs,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    sync::Arc,
};

pub type ControllerPort = Arc<
    dyn Fn(String, Value) -> Pin<Box<dyn Future<Output = Result<Value, String>> + Send>>
        + Send
        + Sync,
>;

pub async fn watched(
    root: &Path,
    candidate: &watcher::Candidate,
    call: &ControllerPort,
) -> Result<Value, String> {
    let root = root.to_owned();
    let source = candidate.path.clone();
    let inbox = tokio::task::spawn_blocking(move || inbox::receive(&root, &source))
        .await
        .map_err(|error| error.to_string())??;
    let result = call(
        "watch_incorporate".into(),
        json!({
            "inbox": inbox,
            "source": candidate.path,
            "title": candidate.title,
            "startedAt": chrono::DateTime::<chrono::Utc>::from(candidate.started_at).to_rfc3339(),
            "sourceKey": candidate.source_key,
        }),
    )
    .await;
    if result.is_err() {
        let _ = fs::remove_file(&inbox);
    }
    result
}

pub async fn recorded(
    call: &ControllerPort,
    path: PathBuf,
    recipe: Option<String>,
    duration: Value,
    created_at: String,
) -> Result<Value, String> {
    call(
        "recording_recorded".into(),
        json!({"path":path,"recipeId":recipe,"duration":duration,"createdAt":created_at}),
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::Mutex,
        time::{Duration, SystemTime},
    };

    fn candidate(path: PathBuf) -> watcher::Candidate {
        watcher::Candidate {
            path,
            folder_id: "carpeta".into(),
            stamp: watcher::Stamp {
                size: 15,
                modified: SystemTime::UNIX_EPOCH,
            },
            title: "Nota sintética".into(),
            started_at: SystemTime::UNIX_EPOCH + Duration::from_secs(1),
            source_key: "carpeta:nota".into(),
        }
    }

    #[tokio::test]
    async fn vigilancia_entrega_copia_privada_y_deja_intacto_el_origen() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("origen/nota.wav");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, b"audio sintetico").unwrap();
        let copied = Arc::new(Mutex::new(None::<PathBuf>));
        let seen = copied.clone();
        let source_for_port = source.clone();
        let root = temp.path().to_owned();
        let port: ControllerPort = Arc::new(move |method, params| {
            let seen = seen.clone();
            let source = source_for_port.clone();
            let root = root.clone();
            Box::pin(async move {
                assert_eq!(method, "watch_incorporate");
                assert_eq!(params["source"], json!(source));
                assert_eq!(params["title"], "Nota sintética");
                assert_eq!(params["sourceKey"], "carpeta:nota");
                assert_eq!(params["startedAt"], "1970-01-01T00:00:01+00:00");
                let inbox = PathBuf::from(params["inbox"].as_str().unwrap());
                assert!(inbox.starts_with(root.join("inbox")));
                assert_eq!(fs::read(&inbox).unwrap(), b"audio sintetico");
                *seen.lock().unwrap() = Some(inbox.clone());
                fs::remove_file(inbox).unwrap();
                Ok(json!({"id":"nota"}))
            })
        });
        assert_eq!(
            watched(temp.path(), &candidate(source.clone()), &port)
                .await
                .unwrap(),
            json!({"id":"nota"})
        );
        assert_eq!(fs::read(source).unwrap(), b"audio sintetico");
        assert!(!copied.lock().unwrap().as_ref().unwrap().exists());
    }

    #[tokio::test]
    async fn fallo_del_controlador_retira_la_copia_y_conserva_el_audio_vigilado() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("origen.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        let copied = Arc::new(Mutex::new(None::<PathBuf>));
        let seen = copied.clone();
        let port: ControllerPort = Arc::new(move |method, params| {
            let seen = seen.clone();
            Box::pin(async move {
                assert_eq!(method, "watch_incorporate");
                *seen.lock().unwrap() = Some(PathBuf::from(params["inbox"].as_str().unwrap()));
                Err("El controlador no confirmó la nota".into())
            })
        });
        assert_eq!(
            watched(temp.path(), &candidate(source.clone()), &port)
                .await
                .unwrap_err(),
            "El controlador no confirmó la nota"
        );
        assert_eq!(fs::read(source).unwrap(), b"audio sintetico");
        assert!(!copied.lock().unwrap().as_ref().unwrap().exists());
    }

    #[tokio::test]
    async fn grabadora_propaga_el_resultado_y_conserva_la_captura_si_falla() {
        let temp = tempfile::tempdir().unwrap();
        let capture = temp.path().join("captures/grabacion.m4a");
        fs::create_dir_all(capture.parent().unwrap()).unwrap();
        fs::write(&capture, b"captura sintetica").unwrap();
        let expected = capture.clone();
        let port: ControllerPort = Arc::new(move |method, params| {
            let expected = expected.clone();
            Box::pin(async move {
                assert_eq!(method, "recording_recorded");
                assert_eq!(
                    params,
                    json!({
                        "path": expected,
                        "recipeId": "receta",
                        "duration": 3.5,
                        "createdAt": "2026-10-13T10:00:00+00:00",
                    })
                );
                Err("No se pudo guardar".into())
            })
        });
        assert_eq!(
            recorded(
                &port,
                capture.clone(),
                Some("receta".into()),
                json!(3.5),
                "2026-10-13T10:00:00+00:00".into()
            )
            .await
            .unwrap_err(),
            "No se pudo guardar"
        );
        assert_eq!(fs::read(&capture).unwrap(), b"captura sintetica");

        let port: ControllerPort = Arc::new(|method, _| {
            Box::pin(async move {
                assert_eq!(method, "recording_recorded");
                Ok(json!({"id":"grabacion"}))
            })
        });
        assert_eq!(
            recorded(
                &port,
                capture.clone(),
                None,
                json!(3.5),
                "2026-10-13T10:00:00+00:00".into()
            )
            .await
            .unwrap(),
            json!({"id":"grabacion"})
        );
        assert!(
            capture.exists(),
            "El controlador retira la captura después de confirmar el commit"
        );
    }
}
