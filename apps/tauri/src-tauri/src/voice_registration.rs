use crate::{
    native::Native,
    store::Store,
    voices::{self, SpeakerSpan, SpeakerVoice},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

#[derive(Clone)]
struct Sample {
    person: String,
    path: PathBuf,
    started_at: String,
    cancelled: Arc<tokio::sync::Notify>,
}

#[derive(Default, PartialEq)]
enum Phase {
    #[default]
    Idle,
    Requesting,
    Recording,
    Analyzing,
    Failed,
}

#[derive(Default)]
struct State {
    phase: Phase,
    sample: Option<Sample>,
    message: Option<String>,
}

impl State {
    fn view(&self) -> Value {
        let phase = match self.phase {
            Phase::Idle => "idle",
            Phase::Requesting => "requesting",
            Phase::Recording => "recording",
            Phase::Analyzing => "analyzing",
            Phase::Failed => "failed",
        };
        let mut value = json!({"state":phase});
        if let Some(sample) = &self.sample {
            value["person"] = json!(sample.person);
            value["startedAt"] = json!(sample.started_at);
        }
        if let Some(message) = &self.message {
            value["message"] = json!(message);
        }
        value
    }
}

pub struct Registration {
    recorder: Native,
    directory: PathBuf,
    state: Mutex<State>,
}

impl Registration {
    pub fn new(directory: PathBuf, executable: PathBuf) -> Result<Self, String> {
        fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        for entry in fs::read_dir(&directory).map_err(|error| error.to_string())? {
            let path = entry.map_err(|error| error.to_string())?.path();
            if path.is_file() {
                discard(&path);
            }
        }
        Ok(Self {
            recorder: Native::new(executable),
            directory,
            state: Mutex::new(State::default()),
        })
    }

    pub fn view(&self) -> Result<Value, String> {
        Ok(self
            .state
            .lock()
            .map_err(|_| "No se pudo consultar la muestra de voz")?
            .view())
    }

    pub fn cancel(&self) -> Result<Value, String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "No se pudo cancelar la muestra de voz")?;
        if matches!(state.phase, Phase::Requesting | Phase::Recording) {
            if let Some(sample) = &state.sample {
                sample.cancelled.notify_one();
            }
            self.recorder.cancel();
            if let Some(sample) = &state.sample {
                discard(&sample.path);
            }
            *state = State::default();
        }
        Ok(state.view())
    }

    pub fn dismiss(&self) -> Result<Value, String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "No se pudo cerrar el aviso de la muestra de voz")?;
        if state.phase == Phase::Failed {
            *state = State::default();
        }
        Ok(state.view())
    }

    pub async fn start(&self, name: &str, changed: impl Fn(Value)) -> Result<Value, String> {
        let sample = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "No se pudo empezar la muestra de voz")?;
            let person = name.trim();
            if person.is_empty() || !matches!(state.phase, Phase::Idle | Phase::Failed) {
                return Ok(state.view());
            }
            let sample = Sample {
                person: person.into(),
                path: self.directory.join(format!("{}.m4a", crate::store::id())),
                started_at: chrono::Utc::now().to_rfc3339(),
                cancelled: Arc::new(tokio::sync::Notify::new()),
            };
            *state = State {
                phase: Phase::Requesting,
                sample: Some(sample.clone()),
                message: None,
            };
            sample
        };
        changed(self.view()?);
        let result = tokio::select! {
            biased;
            _ = sample.cancelled.notified() => Err("Muestra cancelada".into()),
            result = self.recorder.call("recordingStart", json!({"outputPath":sample.path})) => result,
        };
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "No se pudo empezar la muestra de voz")?;
            if state
                .sample
                .as_ref()
                .is_some_and(|current| current.path == sample.path)
                && state.phase == Phase::Requesting
            {
                match result {
                    Ok(_) => state.phase = Phase::Recording,
                    Err(error) => {
                        state.phase = Phase::Failed;
                        state.message = Some(starting_problem(&error));
                        discard(&sample.path);
                    }
                }
            } else {
                discard(&sample.path);
            }
        }
        let view = self.view()?;
        changed(view.clone());
        Ok(view)
    }

    pub async fn stop(
        &self,
        inference: &Native,
        store: &Arc<Mutex<Store>>,
        changed: impl Fn(Value),
    ) -> Result<Value, String> {
        let sample = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "No se pudo terminar la muestra de voz")?;
            if state.phase != Phase::Recording {
                return Ok(state.view());
            }
            let sample = state.sample.clone().ok_or("Falta la muestra de voz")?;
            state.phase = Phase::Analyzing;
            sample
        };
        changed(self.view()?);
        let result = self.analyze(&sample, inference, store).await;
        self.recorder.cancel();
        self.finish(sample, result, changed)
    }

    pub async fn import_audio(
        &self,
        name: &str,
        source: &Path,
        inference: &Native,
        store: &Arc<Mutex<Store>>,
        changed: impl Fn(Value),
    ) -> Result<Value, String> {
        let sample = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "No se pudo empezar la muestra de voz")?;
            let person = name.trim();
            if person.is_empty() || !matches!(state.phase, Phase::Idle | Phase::Failed) {
                return Ok(state.view());
            }
            let mut path = self.directory.join(crate::store::id());
            if let Some(extension) = source.extension() {
                path.set_extension(extension);
            }
            let sample = Sample {
                person: person.into(),
                path,
                started_at: chrono::Utc::now().to_rfc3339(),
                cancelled: Arc::new(tokio::sync::Notify::new()),
            };
            *state = State {
                phase: Phase::Analyzing,
                sample: Some(sample.clone()),
                message: None,
            };
            sample
        };
        changed(self.view()?);
        let from = source.to_path_buf();
        let to = sample.path.clone();
        let result = match tokio::task::spawn_blocking(move || copy_sample(&from, &to)).await {
            Ok(Ok(())) => self.analyze_audio(&sample, inference, store).await,
            Ok(Err(error)) => Err(error),
            Err(_) => Err("No se pudo copiar el audio elegido".into()),
        };
        self.finish(sample, result, changed)
    }

    fn finish(
        &self,
        sample: Sample,
        result: Result<(), String>,
        changed: impl Fn(Value),
    ) -> Result<Value, String> {
        discard(&sample.path);
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| "No se pudo terminar la muestra de voz")?;
            *state = match result {
                Ok(()) => State::default(),
                Err(message) => State {
                    phase: Phase::Failed,
                    sample: None,
                    message: Some(message),
                },
            };
        }
        let view = self.view()?;
        changed(view.clone());
        Ok(view)
    }

    async fn analyze(
        &self,
        sample: &Sample,
        inference: &Native,
        store: &Arc<Mutex<Store>>,
    ) -> Result<(), String> {
        self.recorder
            .call("recordingStop", json!({}))
            .await
            .map_err(analysis_problem)?;
        self.analyze_audio(sample, inference, store).await
    }

    async fn analyze_audio(
        &self,
        sample: &Sample,
        inference: &Native,
        store: &Arc<Mutex<Store>>,
    ) -> Result<(), String> {
        let reply = inference
            .call("diarizedVoices", json!({"audioPath":sample.path}))
            .await
            .map_err(analysis_problem)?;
        let voice = sample_voice(reply)?;
        store
            .lock()
            .map_err(|_| "No se pudo acceder a la biblioteca".to_owned())?
            .add_person_voice(&sample.person, &voice, "muestra de voz")
            .map_err(analysis_problem)
    }
}

fn copy_sample(source: &Path, destination: &Path) -> Result<(), String> {
    let mut input = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(source)
        .map_err(|_| "No se pudo leer el audio elegido")?;
    let metadata = input
        .metadata()
        .map_err(|_| "No se pudo leer el audio elegido")?;
    if !metadata.file_type().is_file() {
        return Err("El audio elegido no es un archivo normal".into());
    }
    if metadata.len() == 0 {
        return Err("El audio elegido está vacío".into());
    }
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(destination)
        .map_err(|_| "No se pudo preparar la muestra de voz")?;
    if io::copy(&mut input, &mut output).map_err(|_| "No se pudo copiar el audio elegido")? == 0 {
        return Err("El audio elegido está vacío".into());
    }
    output
        .sync_all()
        .map_err(|_| "No se pudo guardar la muestra de voz")?;
    Ok(())
}

#[derive(Deserialize)]
struct Diarization {
    voices: Vec<SpeakerVoice>,
    spans: Vec<SpeakerSpan>,
}

fn sample_voice(reply: Value) -> Result<SpeakerVoice, String> {
    let heard: Diarization = serde_json::from_value(reply)
        .map_err(|_| analysis_problem("El motor devolvió una huella inválida".into()))?;
    let seconds = voices::speech_by_speaker(&heard.spans)
        .values()
        .copied()
        .fold(0.0_f64, f64::max);
    if seconds < 30.0 {
        return Err(format!(
            "Solo se oyen {} s de voz y hacen falta 30 s. Habla un rato más.",
            seconds as u64
        ));
    }
    voices::dominant_voice(&heard.voices, &heard.spans, 30.0)
        .ok_or_else(|| "El motor no ha dado la huella de esa voz. Prueba otra vez.".into())
}

fn starting_problem(error: &str) -> String {
    if error.starts_with("MICROPHONE_DENIED:") {
        "Escriba no tiene permiso para usar el micrófono.".into()
    } else {
        format!("No se pudo empezar a grabar: {error}")
    }
}

fn analysis_problem(error: String) -> String {
    format!("No se pudo sacar la huella de la muestra: {error}")
}

fn discard(path: &Path) {
    if let Err(error) = fs::remove_file(path) {
        if error.kind() != std::io::ErrorKind::NotFound {
            eprintln!("No se pudo borrar la muestra de voz: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn host(directory: &Path, seconds: f64, voices: bool) -> PathBuf {
        let executable = directory.join("native-fixture");
        let result = json!({
            "voices": if voices { json!([{"speaker":"Speaker 1","embedding":[1,0],"model":"test"}]) } else { json!([]) },
            "spans":[{"speaker":"Speaker 1","start":0,"end":seconds}]
        });
        let code = format!(
            r#"#!/usr/bin/python3
import json, pathlib, sys
path = None
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    result = {{'protocolVersion': 1}}
    if method == 'recordingStart':
        pathlib.Path({marker:?}).write_text('started')
        path = pathlib.Path(request['params']['outputPath'])
        path.write_bytes(b'synthetic audio')
    elif method == 'diarizedVoices':
        pathlib.Path({analysis_path:?}).write_text(request['params']['audioPath'])
        result = json.loads({result:?})
    print(json.dumps({{'id': request['id'], 'result': result}}), flush=True)
"#,
            result = result.to_string(),
            marker = directory.join("capture-started").to_string_lossy(),
            analysis_path = directory.join("analysis-path").to_string_lossy()
        );
        fs::write(&executable, code).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        executable
    }

    #[tokio::test]
    async fn importar_audio_registra_huella_sin_tocar_el_original_ni_abrir_microfono() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let original = directory.path().join("elegido.wav");
        fs::write(&original, b"audio sintetico original").unwrap();
        let samples = directory.path().join("samples");
        let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
        let store = Arc::new(Mutex::new(
            Store::open(directory.path().join("library")).unwrap(),
        ));

        let view = registration
            .import_audio(" Ana ", &original, &Native::new(executable), &store, |_| {})
            .await
            .unwrap();

        assert_eq!(view["state"], "idle");
        assert_eq!(fs::read(&original).unwrap(), b"audio sintetico original");
        assert!(!directory.path().join("capture-started").exists());
        let analyzed = fs::read_to_string(directory.path().join("analysis-path")).unwrap();
        assert_ne!(Path::new(&analyzed), original);
        assert!(Path::new(&analyzed).starts_with(&samples));
        assert_eq!(Path::new(&analyzed).extension().unwrap(), "wav");
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
        let store = store.lock().unwrap();
        assert_eq!(store.people().unwrap()[0]["name"], "Ana");
        assert_eq!(
            store.people().unwrap()[0]["voices"][0]["source"],
            "muestra de voz"
        );
        assert!(store.snapshot()["recordings"]
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn importar_audio_insuficiente_o_ilegible_conserva_original_y_limpia_copia() {
        for invalid_reply in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let executable = host(directory.path(), 12.0, true);
            if invalid_reply {
                let code = fs::read_to_string(&executable).unwrap().replace(
                    "elif method == 'diarizedVoices':",
                    "elif method == 'diarizedVoices':\n        print(json.dumps({'id': request['id'], 'error': {'code': 'invalid_audio', 'message': 'Audio sintético ilegible'}}), flush=True)\n        continue",
                );
                fs::write(&executable, code).unwrap();
            }
            let original = directory.path().join("elegido.wav");
            fs::write(&original, b"audio sintetico original").unwrap();
            let samples = directory.path().join("samples");
            let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
            let store = Arc::new(Mutex::new(
                Store::open(directory.path().join("library")).unwrap(),
            ));

            let view = registration
                .import_audio("Ana", &original, &Native::new(executable), &store, |_| {})
                .await
                .unwrap();

            assert_eq!(view["state"], "failed");
            assert_eq!(
                view["message"],
                if invalid_reply {
                    "No se pudo sacar la huella de la muestra: Audio sintético ilegible"
                } else {
                    "Solo se oyen 12 s de voz y hacen falta 30 s. Habla un rato más."
                }
            );
            assert_eq!(fs::read(&original).unwrap(), b"audio sintetico original");
            assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
            assert!(store
                .lock()
                .unwrap()
                .people()
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty());
        }
    }

    #[tokio::test]
    async fn importar_ruta_inexistente_o_estando_ocupado_no_altera_registro_activo() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let samples = directory.path().join("samples");
        let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
        let store = Arc::new(Mutex::new(
            Store::open(directory.path().join("library")).unwrap(),
        ));
        let active = registration.start("Ana", |_| {}).await.unwrap();
        let missing = directory.path().join("inexistente.wav");
        assert_eq!(
            registration
                .import_audio("Nuria", &missing, &Native::new(executable), &store, |_| {})
                .await
                .unwrap(),
            active
        );
        assert_eq!(registration.view().unwrap(), active);
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 1);
        registration.cancel().unwrap();
        assert!(!missing.exists());
    }

    #[tokio::test]
    async fn importar_audio_inexistente_o_vacio_no_guarda_persona_ni_deja_copia() {
        for exists in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let executable = host(directory.path(), 45.0, true);
            let original = directory.path().join("elegido.wav");
            if exists {
                fs::write(&original, b"").unwrap();
            }
            let samples = directory.path().join("samples");
            let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
            let store = Arc::new(Mutex::new(
                Store::open(directory.path().join("library")).unwrap(),
            ));

            let view = registration
                .import_audio("Ana", &original, &Native::new(executable), &store, |_| {})
                .await
                .unwrap();

            assert_eq!(view["state"], "failed");
            assert_eq!(original.exists(), exists);
            assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
            assert!(!directory.path().join("analysis-path").exists());
            assert!(store
                .lock()
                .unwrap()
                .people()
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty());
        }
    }

    #[tokio::test]
    async fn importar_fifo_o_enlace_no_abre_tuberia_ni_crea_persona() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let samples = directory.path().join("samples");
        let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
        let store = Arc::new(Mutex::new(
            Store::open(directory.path().join("library")).unwrap(),
        ));
        let fifo = directory.path().join("tuberia");
        let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        let result = registration
            .import_audio(
                "Ana",
                &fifo,
                &Native::new(executable.clone()),
                &store,
                |_| {},
            )
            .await
            .unwrap();
        assert_eq!(result["state"], "failed");
        assert_eq!(
            result["message"],
            "El audio elegido no es un archivo normal"
        );
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
        assert!(!directory.path().join("analysis-path").exists());

        registration.dismiss().unwrap();
        let original = directory.path().join("original.wav");
        fs::write(&original, b"audio sintetico original").unwrap();
        let link = directory.path().join("enlace.wav");
        std::os::unix::fs::symlink(&original, &link).unwrap();
        let result = registration
            .import_audio("Ana", &link, &Native::new(executable), &store, |_| {})
            .await
            .unwrap();
        assert_eq!(result["state"], "failed");
        assert_eq!(fs::read(&original).unwrap(), b"audio sintetico original");
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
        assert!(store
            .lock()
            .unwrap()
            .people()
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn registrar_guarda_la_huella_dominante_y_borra_la_muestra_sin_crear_nota() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let samples = directory.path().join("samples");
        let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
        let store = Arc::new(Mutex::new(
            Store::open(directory.path().join("library")).unwrap(),
        ));
        assert_eq!(
            registration.start(" Ana ", |_| {}).await.unwrap()["state"],
            "recording"
        );
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 1);
        let state = registration
            .stop(&Native::new(executable), &store, |_| {})
            .await
            .unwrap();
        assert_eq!(state["state"], "idle");
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
        let store = store.lock().unwrap();
        assert_eq!(store.people().unwrap()[0]["name"], "Ana");
        assert_eq!(
            store.people().unwrap()[0]["voices"][0]["source"],
            "muestra de voz"
        );
        assert!(store.snapshot()["recordings"]
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn cancelar_descarta_la_muestra_y_permite_empezar_otra() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let samples = directory.path().join("samples");
        let registration = Registration::new(samples.clone(), executable).unwrap();
        registration.start("Ana", |_| {}).await.unwrap();
        assert_eq!(registration.cancel().unwrap()["state"], "idle");
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
        assert_eq!(
            registration.start("Nuria", |_| {}).await.unwrap()["person"],
            "Nuria"
        );
        registration.cancel().unwrap();
    }

    #[tokio::test]
    async fn cancelar_mientras_pide_permiso_no_abre_el_microfono_despues() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let registration = Registration::new(directory.path().join("samples"), executable).unwrap();
        let result = registration
            .start("Ana", |view| {
                if view["state"] == "requesting" {
                    registration.cancel().unwrap();
                }
            })
            .await
            .unwrap();
        assert_eq!(result["state"], "idle");
        assert!(!directory.path().join("capture-started").exists());
    }

    #[tokio::test]
    async fn exige_treinta_segundos_de_voz_y_distingue_una_huella_ausente() {
        for (seconds, voices, message) in [
            (
                12.0,
                true,
                "Solo se oyen 12 s de voz y hacen falta 30 s. Habla un rato más.",
            ),
            (
                45.0,
                false,
                "El motor no ha dado la huella de esa voz. Prueba otra vez.",
            ),
        ] {
            let directory = tempfile::tempdir().unwrap();
            let executable = host(directory.path(), seconds, voices);
            let samples = directory.path().join("samples");
            let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
            let store = Arc::new(Mutex::new(
                Store::open(directory.path().join("library")).unwrap(),
            ));
            registration.start("Ana", |_| {}).await.unwrap();
            let result = registration
                .stop(&Native::new(executable), &store, |_| {})
                .await
                .unwrap();
            assert_eq!(result["state"], "failed");
            assert_eq!(result["message"], message);
            assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
            assert!(store
                .lock()
                .unwrap()
                .people()
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty());
            assert_eq!(registration.dismiss().unwrap()["state"], "idle");
        }
    }

    #[test]
    fn al_arrancar_se_retiran_las_muestras_de_cierres_interrumpidos() {
        let directory = tempfile::tempdir().unwrap();
        let samples = directory.path().join("samples");
        fs::create_dir(&samples).unwrap();
        fs::write(samples.join("stale.m4a"), b"synthetic audio").unwrap();
        Registration::new(samples.clone(), directory.path().join("not-started")).unwrap();
        assert_eq!(fs::read_dir(samples).unwrap().count(), 0);
    }

    #[tokio::test]
    async fn sin_nombre_o_sin_permiso_no_se_graba_ni_se_crea_una_persona() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let source = fs::read_to_string(&executable).unwrap().replace(
            "if method == 'recordingStart':",
            "if method == 'recordingStart':\n        print(json.dumps({'id': request['id'], 'error': {'code': 'microphone_denied', 'message': 'sin permiso'}}), flush=True)\n        continue"
        );
        fs::write(&executable, source).unwrap();
        let registration = Registration::new(directory.path().join("samples"), executable).unwrap();
        assert_eq!(
            registration.start("  ", |_| {}).await.unwrap()["state"],
            "idle"
        );
        assert_eq!(
            registration.start("Ana", |_| {}).await.unwrap()["message"],
            "Escriba no tiene permiso para usar el micrófono."
        );
        assert!(!directory.path().join("capture-started").exists());
    }

    #[tokio::test]
    async fn si_falla_el_analisis_lo_dice_y_borra_el_audio_sin_guardar_huellas() {
        let directory = tempfile::tempdir().unwrap();
        let executable = host(directory.path(), 45.0, true);
        let source = fs::read_to_string(&executable).unwrap().replace(
            "elif method == 'diarizedVoices':",
            "elif method == 'diarizedVoices':\n        print(json.dumps({'id': request['id'], 'error': {'code': 'invalid_audio', 'message': 'Audio sintético ilegible'}}), flush=True)\n        continue",
        );
        fs::write(&executable, source).unwrap();
        let samples = directory.path().join("samples");
        let registration = Registration::new(samples.clone(), executable.clone()).unwrap();
        let store = Arc::new(Mutex::new(
            Store::open(directory.path().join("library")).unwrap(),
        ));
        registration.start("Ana", |_| {}).await.unwrap();
        let result = registration
            .stop(&Native::new(executable), &store, |_| {})
            .await
            .unwrap();
        assert_eq!(result["state"], "failed");
        assert_eq!(
            result["message"],
            "No se pudo sacar la huella de la muestra: Audio sintético ilegible"
        );
        assert_eq!(fs::read_dir(&samples).unwrap().count(), 0);
        assert!(store
            .lock()
            .unwrap()
            .people()
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
    }
}
