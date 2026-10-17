//! Copias privadas de audios del usuario para que el controlador no lea rutas ajenas a sus datos.
use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub fn copy_file(source: &Path, destination: &Path) -> Result<(), String> {
    let mut input = crate::file_security::open_regular(source)
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
    let modified = metadata
        .modified()
        .map_err(|_| "No se pudo leer el audio elegido")?;
    let mut output = crate::file_security::create_private(destination, false)
        .map_err(|_| "No se pudo preparar la copia del audio")?;
    let copied = (|| {
        let bytes =
            io::copy(&mut input, &mut output).map_err(|_| "No se pudo copiar el audio elegido")?;
        output
            .sync_all()
            .map_err(|_| "No se pudo guardar la copia del audio")?;
        let after = input
            .metadata()
            .map_err(|_| "No se pudo leer el audio elegido")?;
        if bytes != metadata.len()
            || after.len() != metadata.len()
            || after.modified().ok() != Some(modified)
        {
            return Err("El audio cambió durante la copia; inténtalo de nuevo");
        }
        Ok(())
    })();
    if copied.is_err() {
        drop(output);
        let _ = fs::remove_file(destination);
    }
    copied.map_err(str::to_owned)
}

pub fn receive(root: &Path, source: &Path) -> Result<PathBuf, String> {
    let directory = root.join("inbox");
    fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    crate::file_security::protect_directory(&directory).map_err(|e| e.to_string())?;
    let mut destination = directory.join(crate::util::id());
    if let Some(extension) = source.extension() {
        destination.set_extension(extension);
    }
    copy_file(source, &destination)?;
    Ok(destination)
}

pub fn cleanup(root: &Path) -> Result<(), String> {
    let directory = root.join("inbox");
    let metadata = match fs::symlink_metadata(&directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("No se pudo inspeccionar la bandeja: {error}")),
    };
    if !metadata.file_type().is_dir() {
        return Err("La bandeja de audio no es una carpeta normal".into());
    }
    let entries = fs::read_dir(&directory)
        .map_err(|error| format!("No se pudo leer la bandeja de audio: {error}"))?;
    for entry in entries {
        let entry =
            entry.map_err(|error| format!("No se pudo leer la bandeja de audio: {error}"))?;
        let kind = entry
            .file_type()
            .map_err(|error| format!("No se pudo inspeccionar una copia de audio: {error}"))?;
        if !kind.is_file() && !kind.is_symlink() {
            return Err("La bandeja contiene una entrada que no es una copia de audio".into());
        }
        fs::remove_file(entry.path())
            .map_err(|error| format!("No se pudo limpiar una copia de audio: {error}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    #[cfg(unix)]
    fn la_copia_conserva_el_contenido_y_rechaza_enlaces_vacios_y_tuberias() {
        let temp = tempfile::tempdir().unwrap();
        let original = temp.path().join("nota.wav");
        fs::write(&original, b"audio sintetico").unwrap();
        let copied = receive(temp.path(), &original).unwrap();
        assert!(copied.starts_with(temp.path().join("inbox")));
        assert_eq!(copied.extension().unwrap(), "wav");
        assert_eq!(fs::read(&copied).unwrap(), b"audio sintetico");
        assert_eq!(
            fs::metadata(&copied).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let empty = temp.path().join("vacio.wav");
        fs::write(&empty, b"").unwrap();
        assert_eq!(
            receive(temp.path(), &empty).unwrap_err(),
            "El audio elegido está vacío"
        );
        let link = temp.path().join("enlace.wav");
        std::os::unix::fs::symlink(&original, &link).unwrap();
        assert!(receive(temp.path(), &link).is_err());
        assert!(receive(temp.path(), &temp.path().join("no-existe.wav")).is_err());
        assert_eq!(fs::read_dir(temp.path().join("inbox")).unwrap().count(), 1);
    }

    #[test]
    fn la_copia_no_sobrescribe_un_archivo_existente() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("origen.wav");
        let destination = temp.path().join("destino.wav");
        fs::write(&source, b"audio sintetico").unwrap();
        fs::write(&destination, b"contenido anterior").unwrap();
        assert!(copy_file(&source, &destination).is_err());
        assert_eq!(fs::read(destination).unwrap(), b"contenido anterior");
    }

    #[test]
    #[cfg(unix)]
    fn limpiar_bandeja_elimina_copias_y_enlaces_sin_tocar_originales() {
        let temp = tempfile::tempdir().unwrap();
        let original = temp.path().join("original.wav");
        fs::write(&original, b"audio sintetico original").unwrap();
        let copied = receive(temp.path(), &original).unwrap();
        let link = temp.path().join("inbox/enlace.wav");
        std::os::unix::fs::symlink(&original, &link).unwrap();

        cleanup(temp.path()).unwrap();

        assert!(!copied.exists());
        assert!(fs::symlink_metadata(&link).is_err());
        assert_eq!(fs::read(&original).unwrap(), b"audio sintetico original");
        assert_eq!(fs::read_dir(temp.path().join("inbox")).unwrap().count(), 0);
    }

    #[test]
    fn limpiar_bandeja_informa_si_hay_una_carpeta_inesperada() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("inbox/inesperada")).unwrap();
        assert!(cleanup(temp.path()).is_err());
        assert!(temp.path().join("inbox/inesperada").is_dir());
    }
}
