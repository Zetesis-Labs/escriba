use crate::store::text;
use reqwest::{multipart, Client, Url};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};
use tokio_util::io::ReaderStream;

fn endpoint(resolver: &Value, route: &str) -> Result<Url, String> {
    let base = text(resolver, "url")?;
    let mut url = Url::parse(base).map_err(|_| "URL del resolutor inválida")?;
    if !url.username().is_empty()
        || url.password().is_some()
        || !(url.scheme() == "https"
            || (url.scheme() == "http"
                && ["localhost", "127.0.0.1", "[::1]"].contains(&url.host_str().unwrap_or(""))))
    {
        return Err("Usa HTTPS o un servidor local".into());
    }
    let path = format!("{}/{}", url.path().trim_end_matches('/'), route);
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}
fn client() -> Result<Client, String> {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(1800))
        .build()
        .map_err(|e| e.to_string())
}
async fn response(r: reqwest::Response, secret: Option<&str>) -> Result<Value, String> {
    let status = r.status();
    let mut r = r;
    let mut bytes = Vec::new();
    while let Some(chunk) = r
        .chunk()
        .await
        .map_err(|_| "BACKEND_UNAVAILABLE: Se cortó la respuesta del resolutor")?
    {
        if bytes.len() + chunk.len() > 32 * 1024 * 1024 {
            return Err("Respuesta del resolutor demasiado grande".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let mut body = String::from_utf8_lossy(&bytes).into_owned();
    if let Some(secret) = secret.filter(|s| !s.is_empty()) {
        body = body.replace(secret, "[credencial]");
    }
    if !status.is_success() {
        let unavailable =
            status.is_server_error() || [401, 403, 408, 429].contains(&status.as_u16());
        return Err(format!(
            "{}El resolutor respondió {status}: {}",
            if unavailable {
                "BACKEND_UNAVAILABLE: "
            } else {
                ""
            },
            body.chars().take(1000).collect::<String>()
        ));
    }
    serde_json::from_str(&body).map_err(|_| "Respuesta JSON inválida del resolutor".into())
}
pub async fn transcribe(
    resolver: &Value,
    secret: Option<String>,
    path: &Path,
    p: &Value,
) -> Result<Value, String> {
    if p["diarize"] == true {
        return Err("La detección de hablantes requiere Whisper local".into());
    }
    let file = tokio::fs::File::open(path)
        .await
        .map_err(|e| e.to_string())?;
    let size = file.metadata().await.map_err(|e| e.to_string())?.len();
    let part = multipart::Part::stream_with_length(
        reqwest::Body::wrap_stream(ReaderStream::new(file)),
        size,
    )
    .file_name(
        path.file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
    );
    let mut form = multipart::Form::new()
        .part("file", part)
        .text("model", text(resolver, "model")?.to_owned())
        .text("response_format", "verbose_json");
    if let Some(lang) = p["language"].as_str().filter(|s| !s.is_empty()) {
        form = form.text("language", lang.to_owned());
    }
    let mut req = client()?
        .post(endpoint(resolver, "audio/transcriptions")?)
        .multipart(form);
    if let Some(token) = secret.as_ref() {
        req = req.bearer_auth(token);
    }
    let value = response(
        req.send()
            .await
            .map_err(|_| "BACKEND_UNAVAILABLE: No se pudo conectar con el resolutor STT")?,
        secret.as_deref(),
    )
    .await?;
    let text = value["text"]
        .as_str()
        .ok_or("La respuesta no contiene transcripción")?;
    if text.trim().is_empty() {
        return Err("El resolutor devolvió una transcripción vacía".into());
    }
    Ok(
        json!({"text":text,"segments":value["segments"].as_array().cloned().unwrap_or_default(),"language":value["language"].as_str().unwrap_or(""),"duration":value["duration"].as_f64().unwrap_or(0.0)}),
    )
}
pub async fn ask(resolver: &Value, secret: Option<String>, p: &Value) -> Result<Value, String> {
    let mut body = json!({"model":text(resolver,"model")?,"messages":[{"role":"system","content":text(p,"instructions")?},{"role":"user","content":text(p,"prompt")?}],"temperature":0.2});
    if let Some(schema) = p.get("schema").filter(|v| !v.is_null()) {
        body["response_format"] = json!({"type":"json_schema","json_schema":{"name":"escriba","strict":true,"schema":schema}});
    }
    let mut req = client()?
        .post(endpoint(resolver, "chat/completions")?)
        .json(&body);
    if let Some(token) = secret.as_ref() {
        req = req.bearer_auth(token);
    }
    let value = response(
        req.send()
            .await
            .map_err(|_| "BACKEND_UNAVAILABLE: No se pudo conectar con el resolutor LLM")?,
        secret.as_deref(),
    )
    .await?;
    let content = value["choices"][0]["message"]["content"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or("El resolutor no devolvió contenido")?;
    if p.get("schema").is_some_and(|v| !v.is_null()) {
        serde_json::from_str(content).map_err(|_| "El resolutor no respetó el esquema JSON".into())
    } else {
        Ok(json!(content))
    }
}
pub fn digest_schema() -> Value {
    json!({"type":"object","properties":{"title":{"type":"string"},"summary":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}}},"required":["title","summary","tags"],"additionalProperties":false})
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    async fn fake_http(status: &str, body: &str, declared_length: usize) -> reqwest::Response {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let body = body.to_owned();
        let status = status.to_owned();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buffer = [0u8; 1024];
            let _ = socket.read(&mut buffer).await.unwrap();
            socket.write_all(format!("HTTP/1.1 {status}\r\nContent-Length: {declared_length}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{body}").as_bytes()).await.unwrap();
        });
        Client::new()
            .get(format!("http://{address}/test"))
            .send()
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn respuesta_cortada_se_reintenta_y_errores_400_no() {
        let interrupted = fake_http("200 OK", "{\"partial\":", 100).await;
        let error = response(interrupted, None).await.unwrap_err();
        assert!(error.starts_with("BACKEND_UNAVAILABLE:"), "{error}");
        for status in ["401 Unauthorized", "429 Too Many Requests"] {
            let unavailable = fake_http(status, "{}", 2).await;
            let error = response(unavailable, None).await.unwrap_err();
            assert!(error.starts_with("BACKEND_UNAVAILABLE:"), "{error}");
        }
        let invalid = fake_http("400 Bad Request", "{}", 2).await;
        let error = response(invalid, None).await.unwrap_err();
        assert!(!error.starts_with("BACKEND_UNAVAILABLE:"), "{error}");
    }
}
