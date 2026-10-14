use std::{ffi::OsStr, path::PathBuf};

pub const DEFAULT_MODEL: &str = "large-v3-turbo";
pub const LLM_UNAVAILABLE: &str =
    "Escriba no incluye un LLM en Linux: añade uno en LLMs y elígelo en la receta";

pub fn models_root() -> Option<PathBuf> {
    models_root_from(
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}

// XDG asks to ignore a relative XDG_DATA_HOME.
fn models_root_from(data_home: Option<&OsStr>, home: Option<&OsStr>) -> Option<PathBuf> {
    let data = data_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join(".local/share"))
        })?;
    Some(data.join("escriba/models"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn la_carpeta_de_modelos_sigue_xdg_como_la_app() {
        assert_eq!(
            models_root_from(Some(OsStr::new("/datos")), Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/datos/escriba/models"))
        );
        assert_eq!(
            models_root_from(Some(OsStr::new("rel")), Some(OsStr::new("/home/ana"))),
            Some(PathBuf::from("/home/ana/.local/share/escriba/models"))
        );
        assert_eq!(models_root_from(None, None), None);
    }
}
