use crate::protocol::{required_string, Failure, Params};
use serde_json::{json, Value};
use std::{fs, io, os::unix::fs::MetadataExt};

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
    Ok(json!({
        "size": metadata.len(),
        "blocks": metadata.blocks(),
        "flags": 0,
        "dataless": false,
        "modifiedAt": modified.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    }))
}

/// Linux has no on-demand files to download: a file is ready once it has data.
pub fn materialize(params: &Params) -> Result<Value, Failure> {
    if let Some(timeout) = params
        .get("timeoutSeconds")
        .filter(|value| !value.is_null())
    {
        if !timeout
            .as_u64()
            .is_some_and(|seconds| (1..=300).contains(&seconds))
        {
            return Err(Failure::new(
                "invalid_params",
                "timeoutSeconds debe estar entre 1 y 300",
            ));
        }
    }
    let state = status(params)?;
    let size = state["size"].as_u64().unwrap_or(0);
    Ok(json!({"ready": size > 0, "dataless": false, "size": size}))
}
