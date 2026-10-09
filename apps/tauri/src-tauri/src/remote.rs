use crate::store::text;
use reqwest::{multipart, Client, Url};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};
use tokio_util::io::ReaderStream;

fn endpoint(resolver: &Value, route: &str) -> Result<Url, String> {
    let base = text(resolver, "url")?;
    let mut url = Url::parse(base).map_err(|_| "URL del resolutor inválida")?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("La URL no puede llevar usuario ni contraseña".into());
    }
    if !(url.scheme() == "https"
        || (url.scheme() == "http" && private_host(url.host_str().unwrap_or(""))))
    {
        return Err("Usa https:// para un servicio fuera de tu red".into());
    }
    let path = format!("{}/{}", url.path().trim_end_matches('/'), route);
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}
pub fn private_host(raw: &str) -> bool {
    let host = raw.trim_matches(|c| c == '[' || c == ']').to_lowercase();
    if host == "localhost" || host.ends_with(".local") || host == "::1" {
        return true;
    }
    if host.starts_with("fc") || host.starts_with("fd") {
        return host.contains(':');
    }
    let octets: Vec<u8> = host.split('.').filter_map(|part| part.parse().ok()).collect();
    if octets.len() != 4 || host.split('.').count() != 4 {
        return false;
    }
    matches!(
        (octets[0], octets[1]),
        (127, _) | (10, _) | (192, 168) | (172, 16..=31) | (100, 64..=127)
    )
}

pub fn silent_wav() -> Vec<u8> {
    let rate: u32 = 16_000;
    let samples = rate as usize;
    let data = (samples * 2) as u32;
    let mut wav = Vec::with_capacity(44 + data as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&rate.to_le_bytes());
    wav.extend_from_slice(&(rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data.to_le_bytes());
    wav.resize(44 + data as usize, 0);
    wav
}

pub async fn models(resolver: &Value, secret: Option<String>) -> Result<Vec<String>, String> {
    let mut req = client()?.get(endpoint(resolver, "models")?);
    if let Some(token) = secret.as_ref() {
        req = req.bearer_auth(token);
    }
    let value = response(
        req.send()
            .await
            .map_err(|_| "No se pudo conectar con el servicio")?,
        secret.as_deref(),
    )
    .await?;
    let mut ids: Vec<String> = value["data"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| model["id"].as_str().map(str::to_owned))
        .collect();
    ids.sort();
    ids.dedup();
    Ok(ids)
}

pub async fn probe_transcription(resolver: &Value, secret: Option<String>) -> Result<String, String> {
    let part = multipart::Part::bytes(silent_wav())
        .file_name("prueba.wav")
        .mime_str("audio/wav")
        .map_err(|e| e.to_string())?;
    let form = multipart::Form::new()
        .part("file", part)
        .text("model", text(resolver, "model")?.to_owned())
        .text("response_format", "json");
    let mut req = client()?
        .post(endpoint(resolver, "audio/transcriptions")?)
        .multipart(form);
    if let Some(token) = secret.as_ref() {
        req = req.bearer_auth(token);
    }
    let value = response(
        req.send()
            .await
            .map_err(|_| "No se pudo conectar con el servicio")?,
        secret.as_deref(),
    )
    .await?;
    Ok(value["text"].as_str().unwrap_or("").trim().to_owned())
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

#[cfg(test)]
mod network_tests {
    use super::*;

    #[test]
    fn http_solo_vale_dentro_de_tu_red_como_en_swift() {
        for host in ["localhost", "mac.local", "127.0.0.1", "10.0.0.4", "192.168.1.20", "172.20.0.1", "100.101.102.103", "::1", "fd7a:115c::1"] {
            assert!(private_host(host), "{host}");
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "fdroid.org"] {
            assert!(!private_host(host), "{host}");
        }
        assert!(endpoint(&json!({"url": "http://192.168.1.20:1234/v1"}), "models").is_ok());
        assert!(endpoint(&json!({"url": "http://api.example.com/v1"}), "models").is_err());
        assert_eq!(
            endpoint(&json!({"url": "https://api.openai.com/v1/"}), "models").unwrap().as_str(),
            "https://api.openai.com/v1/models"
        );
    }

    #[test]
    fn el_audio_de_prueba_es_un_segundo_de_silencio_en_wav() {
        let wav = silent_wav();
        assert_eq!(wav.len(), 44 + 32_000);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert!(wav[44..].iter().all(|byte| *byte == 0));
    }
}
