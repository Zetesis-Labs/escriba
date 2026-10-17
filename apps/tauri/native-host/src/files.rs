use crate::protocol::{required_string, Failure, Params};
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::{fs, io, path::Path, time::Duration};

fn blocks(metadata: &fs::Metadata) -> u64 {
    #[cfg(unix)]
    {
        metadata.blocks()
    }
    #[cfg(windows)]
    {
        metadata.len().div_ceil(512)
    }
}

pub fn status(params: &Params) -> Result<Value, Failure> {
    let path = required_string(params, "path")?;
    let metadata = fs::symlink_metadata(path).map_err(|error| match error.kind() {
        io::ErrorKind::NotFound => Failure::new(
            "audio_missing",
            format!("no existe el fichero de audio: {path}"),
        ),
        _ => Failure::new("invalid_audio", format!("no se puede leer {path}: {error}")),
    })?;
    if !metadata.is_file() {
        return Err(Failure::new(
            "invalid_audio",
            "la ruta no es un archivo de audio regular",
        ));
    }
    let modified = metadata
        .modified()
        .map(chrono::DateTime::<chrono::Utc>::from)
        .map_err(|error| Failure::new("invalid_audio", error.to_string()))?;
    let flags = crate::platform::file_flags(&metadata);
    Ok(json!({
        "size": metadata.len(),
        "blocks": blocks(&metadata),
        "flags": flags,
        "dataless": crate::platform::dataless(flags),
        "modifiedAt": modified.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    }))
}

pub fn materialize(params: &Params) -> Result<Value, Failure> {
    let timeout = match params
        .get("timeoutSeconds")
        .filter(|value| !value.is_null())
    {
        None => 300,
        Some(value) => value
            .as_u64()
            .filter(|seconds| (1..=300).contains(seconds))
            .ok_or_else(|| {
                Failure::new("invalid_params", "timeoutSeconds debe estar entre 1 y 300")
            })?,
    };
    status(params)?;
    let completed = crate::platform::materialize(
        Path::new(required_string(params, "path")?),
        Duration::from_secs(timeout),
    );
    let state = status(params)?;
    let size = state["size"].as_u64().unwrap_or(0);
    let dataless = state["dataless"].as_bool().unwrap_or(false);
    Ok(json!({"ready": completed && !dataless && size > 0, "dataless": dataless, "size": size}))
}
