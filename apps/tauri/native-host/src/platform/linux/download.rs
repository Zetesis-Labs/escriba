//! Model downloads: a temporary file that only becomes the model once complete.

use crate::protocol::Failure;
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::Path,
};

pub fn failed(error: impl std::fmt::Display) -> Failure {
    Failure::new(
        "download_failed",
        format!("no se pudo descargar el modelo: {error}"),
    )
}

pub fn fetch(url: &str, path: &Path, progress: &mut dyn FnMut(f64)) -> Result<(), Failure> {
    let mut partial = path.as_os_str().to_owned();
    partial.push(".part");
    let partial = Path::new(&partial);
    let fetched = (|| -> Result<(), Failure> {
        fs::create_dir_all(path.parent().ok_or_else(|| failed("ruta sin carpeta"))?)
            .map_err(failed)?;
        let response = ureq::get(url).call().map_err(failed)?;
        let body = response.into_body();
        let total = body.content_length();
        let mut reader = body.into_reader();
        let mut file = File::create(partial).map_err(failed)?;
        let mut buffer = vec![0; 1 << 16];
        let (mut received, mut reported) = (0u64, -1.0);
        loop {
            let read = reader.read(&mut buffer).map_err(failed)?;
            if read == 0 {
                break;
            }
            file.write_all(&buffer[..read]).map_err(failed)?;
            received += read as u64;
            if let Some(total) = total.filter(|total| *total > 0) {
                let fraction = (received as f64 / total as f64).min(1.0);
                if fraction - reported >= 0.01 {
                    progress(fraction);
                    reported = fraction;
                }
            }
        }
        if received == 0 || total.is_some_and(|total| total != received) {
            return Err(failed("la descarga se cortó"));
        }
        file.sync_all().map_err(failed)?;
        fs::rename(partial, path).map_err(failed)
    })();
    if fetched.is_err() {
        let _ = fs::remove_file(partial);
    }
    fetched
}
