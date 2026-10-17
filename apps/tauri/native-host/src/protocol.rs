use serde_json::{json, Map, Value};

#[derive(Debug)]
pub struct Failure {
    code: &'static str,
    message: String,
}

impl Failure {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub type Params = Map<String, Value>;

#[derive(Default)]
pub struct Host {
    recorder: crate::recording::Recorder,
    inference: crate::platform::Inference,
}

impl Host {
    pub fn handle(&mut self, line: &str) -> String {
        self.handle_with_progress(line, &mut |_| {})
    }

    /// `progress` receives the lines a download emits before its reply.
    pub fn handle_with_progress(&mut self, line: &str, progress: &mut dyn FnMut(String)) -> String {
        let request = match serde_json::from_str::<Value>(line) {
            Ok(request) => request,
            Err(error) => {
                return reply(
                    &Value::Null,
                    Err(Failure::new(
                        "invalid_json",
                        format!("JSON inválido: {error}"),
                    )),
                )
            }
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let mut fraction =
            |value: f64| progress(json!({"id": id, "progress": {"fraction": value}}).to_string());
        let outcome = parse(&request)
            .and_then(|(method, params)| self.perform(method, params, &mut fraction));
        reply(&id, outcome)
    }

    fn status(&self, params: &Params) -> Result<Value, Failure> {
        let mut status = self.inference.status(&model_name(params)?);
        status["protocolVersion"] = json!(1);
        Ok(status)
    }

    fn perform(
        &mut self,
        method: &str,
        params: &Params,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Value, Failure> {
        match method {
            "status" => self.status(params),
            "audioInfo" => crate::audio::info(params),
            "combineAudio" => Err(Failure::new(
                "unavailable",
                "combinar audio no está disponible en Linux todavía",
            )),
            "fileStatus" => crate::files::status(params),
            "materialize" => crate::files::materialize(params),
            "summarize" | "ask" => self.inference.generate(params),
            "transcribe" => self.inference.transcribe(params, &model_name(params)?),
            "downloadModel" => self.inference.download(&model_name(params)?, progress),
            "models" => Ok(self.inference.models()),
            "deleteModel" => self.inference.delete_model(&model_name(params)?),
            "diarizedVoices" => self.inference.diarized_voices(params),
            "recordingStatus" => Ok(self.recorder.status()),
            "recordingStart" => self.recorder.start(params),
            "recordingPause" => self.recorder.pause(true),
            "recordingResume" => self.recorder.pause(false),
            "recordingStop" => self.recorder.stop(),
            "recordingCancel" => self.recorder.cancel(),
            _ => Err(Failure::new(
                "unknown_method",
                format!("método desconocido: {method}"),
            )),
        }
    }
}

fn parse(request: &Value) -> Result<(&str, &Params), Failure> {
    let request = request
        .as_object()
        .ok_or_else(|| Failure::new("invalid_request", "la petición debe ser un objeto"))?;
    if !request
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|id| !id.is_empty())
    {
        return Err(Failure::new(
            "invalid_request",
            "id debe ser un texto no vacío",
        ));
    }
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::new("invalid_request", "method debe ser un texto"))?;
    let params = request
        .get("params")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::new("invalid_request", "params debe ser un objeto"))?;
    Ok((method, params))
}

fn reply(id: &Value, outcome: Result<Value, Failure>) -> String {
    match outcome {
        Ok(result) => json!({"id": id, "result": result}),
        Err(failure) => {
            json!({"id": id, "error": {"code": failure.code, "message": failure.message}})
        }
    }
    .to_string()
}

fn model_name(params: &Params) -> Result<String, Failure> {
    let Some(value) = params.get("model").filter(|value| !value.is_null()) else {
        return Ok(crate::platform::DEFAULT_MODEL.to_owned());
    };
    let name = value
        .as_str()
        .ok_or_else(|| Failure::new("invalid_params", "model debe ser un texto"))?;
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
        || name.contains("..")
    {
        return Err(Failure::new(
            "invalid_params",
            "model debe ser un nombre de variante, sin rutas",
        ));
    }
    Ok(crate::platform::normalized_model(name).to_owned())
}

pub fn required_string<'a>(params: &'a Params, key: &str) -> Result<&'a str, Failure> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            Failure::new(
                "invalid_params",
                format!("{key} debe ser un texto no vacío"),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(value: Value) -> Params {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn el_modelo_es_un_nombre_sin_rutas() {
        assert_eq!(
            model_name(&params(json!({}))).ok().unwrap(),
            "large-v3-turbo"
        );
        assert_eq!(
            model_name(&params(json!({"model": null}))).ok().unwrap(),
            "large-v3-turbo"
        );
        assert_eq!(
            model_name(&params(json!({"model": "base.en"})))
                .ok()
                .unwrap(),
            "base.en"
        );
        for bad in [json!(""), json!("a/b"), json!(".."), json!(3)] {
            assert_eq!(
                model_name(&params(json!({"model": bad})))
                    .err()
                    .unwrap()
                    .code,
                "invalid_params"
            );
        }
    }
}
