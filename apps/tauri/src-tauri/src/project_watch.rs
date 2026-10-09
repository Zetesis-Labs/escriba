use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::path::{Component, Path, PathBuf};

const IGNORED: [&str; 4] = ["node_modules", ".escriba", ".git", "dist"];
const SOURCES: [&str; 6] = ["ts", "tsx", "js", "mjs", "cjs", "json"];

pub fn relevant(path: &Path, root: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else {
        return false;
    };
    let ignored = relative.components().any(|component| match component {
        Component::Normal(name) => IGNORED.iter().any(|skip| name == *skip),
        _ => false,
    });
    let source = path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| SOURCES.contains(&extension));
    !ignored && source
}

pub fn watch(
    root: &str,
    changed: tokio::sync::mpsc::UnboundedSender<()>,
) -> Result<RecommendedWatcher, String> {
    let base = PathBuf::from(root);
    let filter = base.clone();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if let Ok(event) = event {
            if event.paths.iter().any(|path| relevant(path, &filter)) {
                let _ = changed.send(());
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
}
