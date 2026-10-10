use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::path::{Component, Path, PathBuf};

const IGNORED: [&str; 4] = ["node_modules", ".escriba", ".git", "dist"];
const SOURCES: [&str; 6] = ["ts", "tsx", "js", "mjs", "cjs", "json"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    Build,
    Load,
}

#[cfg(test)]
pub fn relevant(path: &Path, root: &Path) -> bool {
    change(path, root) == Some(Change::Build)
}

pub fn change(path: &Path, root: &Path) -> Option<Change> {
    let Ok(relative) = path.strip_prefix(root) else {
        return None;
    };
    if relative
        .components()
        .next()
        .is_some_and(|component| matches!(component, Component::Normal(name) if name == "dist"))
    {
        return Some(Change::Load);
    }
    let ignored = relative.components().any(|component| match component {
        Component::Normal(name) => IGNORED.iter().any(|skip| name == *skip),
        _ => false,
    });
    let source = path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| SOURCES.contains(&extension));
    (!ignored && source).then_some(Change::Build)
}

pub fn watch(
    root: &str,
    changed: tokio::sync::mpsc::UnboundedSender<Change>,
) -> Result<RecommendedWatcher, String> {
    let base = PathBuf::from(root);
    let filter = base.clone();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if let Ok(event) = event {
            let action = event
                .paths
                .iter()
                .filter_map(|path| change(path, &filter))
                .find(|action| *action == Change::Build)
                .or_else(|| event.paths.iter().find_map(|path| change(path, &filter)));
            if let Some(action) = action {
                let _ = changed.send(action);
            }
        }
    })
    .map_err(|e| e.to_string())?;
    watcher
        .watch(&base, RecursiveMode::Recursive)
        .map_err(|e| e.to_string())?;
    Ok(watcher)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solo_recompila_al_cambiar_fuentes_del_proyecto() {
        let root = Path::new("/p");
        assert!(relevant(Path::new("/p/recetas/resumen/receta.ts"), root));
        assert!(relevant(Path::new("/p/package.json"), root));
        assert!(!relevant(Path::new("/p/node_modules/zod/index.js"), root));
        assert!(!relevant(Path::new("/p/.escriba/estado.json"), root));
        assert!(!relevant(Path::new("/p/.git/HEAD"), root));
        assert!(!relevant(Path::new("/p/recetas/notas.md"), root));
        assert!(!relevant(Path::new("/otra/receta.ts"), root));
    }

    #[test]
    fn distingue_fuentes_y_artefactos_sin_recompilar_por_staging() {
        let root = Path::new("/p");
        assert_eq!(
            change(Path::new("/p/src/recetas/uno/receta.ts"), root),
            Some(Change::Build)
        );
        assert_eq!(
            change(Path::new("/p/dist/escriba.json"), root),
            Some(Change::Load)
        );
        assert_eq!(
            change(Path::new("/p/dist/receta-0.js"), root),
            Some(Change::Load)
        );
        assert_eq!(change(Path::new("/p/dist"), root), Some(Change::Load));
        assert_eq!(
            change(Path::new("/p/.escriba/build-123/receta.js"), root),
            None
        );
        assert_eq!(change(Path::new("/p/node_modules/a/index.js"), root), None);
    }
}
