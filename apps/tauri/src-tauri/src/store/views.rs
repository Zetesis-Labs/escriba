use super::*;

impl Store {
    #[cfg(test)]
    pub fn library(&self) -> Value {
        library(&self.data, &self.root)
    }

    #[cfg(test)]
    pub async fn snapshot(&self) -> Result<Value, String> {
        snapshot(&self.database, &self.root).await
    }

    #[cfg(test)]
    pub async fn runtime_context(&self, recording_id: Option<&str>) -> Result<Value, String> {
        runtime_context(&self.data, &self.root, &self.database, recording_id).await
    }

    #[cfg(test)]
    pub(super) fn mark_credentials(&self, value: &mut Value) {
        mark_credentials(&self.root, value)
    }
}

pub(super) async fn recording(database: &Persistence, record_id: &str) -> Result<Value, String> {
    database
        .recording(record_id)
        .await?
        .ok_or_else(|| "Grabación no encontrada".into())
}

async fn snapshot(database: &Persistence, root: &Path) -> Result<Value, String> {
    let mut value = database.load().await?.ok_or("Biblioteca sin inicializar")?;
    value["settings"] = redacted_settings(&value["settings"]);
    value["dataPath"] = json!(root);
    mark_credentials(root, &mut value);
    Ok(value)
}

async fn runtime_context(
    data: &LibraryData,
    root: &Path,
    database: &Persistence,
    recording_id: Option<&str>,
) -> Result<Value, String> {
    let recordings = match recording_id {
        Some(id) => {
            let original = Recording::read(&recording(database, id).await?)?;
            let audio_path = original
                .audio_path
                .as_ref()
                .filter(|path| !path.is_empty())
                .map(|_| "available");
            let recording = json!({
                "id": original.id,
                "title": original.title,
                "createdAt": original.created_at,
                "source": format!("urn:escriba:recording:{id}"),
                "audioPath": audio_path,
                "audioHash": original.audio_hash,
                "duration": original.duration,
                "status": original.status,
                "error": original.error,
                "recipeId": original.recipe_id,
                "currentVersionId": original.current_version_id,
                "versions": original.versions,
                "publications": original.publications,
                "accountEffectPending": original.extra.get("accountEffectPending") == Some(&json!(true)),
            });
            vec![recording]
        }
        None => Vec::new(),
    };
    let mut accounts = data.accounts.clone();
    if let Some(items) = accounts.as_array_mut() {
        for account in items {
            if let Some(folder) = account["folder"].as_str() {
                account["folder"] = json!(format!(
                    "urn:escriba:folder:{:x}",
                    Sha256::digest(folder.as_bytes())
                ));
            }
        }
    }
    let settings = &data.settings;
    let mut value = json!({
        "recordings": recordings,
        "settings": {
            "defaultRecipeId": settings.default_recipe_id,
            "language": settings.language,
            "whisperModel": settings.whisper_model,
        },
        "resolvers": data.resolvers,
        "recipes": data.recipes,
        "accounts": accounts,
        "destinations": data.destinations,
        "providers": data.providers,
    });
    mark_credentials(root, &mut value);
    Ok(value)
}

pub(super) fn library(data: &LibraryIndex, root: &Path) -> Value {
    let mut value = crate::library_view::typed_library(data);
    value["settings"] = redacted_settings(&value["settings"]);
    if let Some(settings) = value["settings"].as_object_mut() {
        settings.remove("projectOntologies");
    }
    value["dataPath"] = json!(root);
    mark_credentials(root, &mut value);
    value
}

fn mark_credentials(root: &Path, value: &mut Value) {
    for key in ["accounts", "resolvers"] {
        if let Some(items) = value[key].as_array_mut() {
            for item in items {
                item["hasCredential"] = json!(super::configuration::credential_path(
                    root,
                    item["id"].as_str().unwrap_or("")
                )
                .is_ok_and(|p| p.is_file()));
            }
        }
    }
}

#[derive(Clone)]
pub struct IndexView {
    index: Arc<LibraryIndex>,
    root: Arc<Path>,
}

impl std::ops::Deref for IndexView {
    type Target = LibraryIndex;
    fn deref(&self) -> &Self::Target {
        &self.index
    }
}

impl IndexView {
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn item(&self, collection: &str, item_id: &str) -> Result<Value, String> {
        super::recordings::item(&self.index, collection, item_id)
    }
    pub fn audio(&self, record_id: &str) -> Result<PathBuf, String> {
        super::recordings::audio(&self.index, &self.root, record_id)
    }
    pub fn credential(&self, key: &str) -> Result<Option<String>, String> {
        super::configuration::credential(&self.root, key)
    }
    pub fn library(&self) -> Value {
        library(&self.index, &self.root)
    }
    pub fn watched_folder_bookmarks(&self) -> Result<Vec<(String, PathBuf, Vec<u8>)>, String> {
        super::settings::watched_folder_bookmarks(&self.index)
    }
    pub async fn snapshot(&self, database: &Persistence) -> Result<Value, String> {
        snapshot(database, &self.root).await
    }
    pub async fn runtime_context(
        &self,
        database: &Persistence,
        recording_id: Option<&str>,
    ) -> Result<Value, String> {
        runtime_context(&self.index, &self.root, database, recording_id).await
    }
    pub async fn memory_recall(
        &self,
        database: &Persistence,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
    ) -> Result<Option<Value>, String> {
        database
            .recall(&super::work::memory_key(
                &self.index,
                recording_id,
                version_id,
                fingerprint,
            )?)
            .await
    }
}

impl Store {
    pub(crate) fn index_view(&self) -> IndexView {
        IndexView {
            index: Arc::new(self.data.clone()),
            root: Arc::from(self.root.as_path()),
        }
    }
}
