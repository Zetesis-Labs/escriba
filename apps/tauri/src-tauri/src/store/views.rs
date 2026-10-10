use super::*;

impl Store {
    pub fn library(&self) -> Value {
        let mut value = crate::library_view::typed_library(&self.data);
        value["settings"] = redacted_settings(&value["settings"]);
        value["dataPath"] = json!(self.root);
        self.mark_credentials(&mut value);
        value
    }

    pub fn snapshot(&self) -> Value {
        let mut value = self.data_json();
        value["settings"] = redacted_settings(&value["settings"]);
        value["dataPath"] = json!(self.root);
        self.mark_credentials(&mut value);
        value
    }

    pub fn runtime_context(&self, recording_id: Option<&str>) -> Result<Value, String> {
        let recordings = match recording_id {
            Some(id) => {
                let original = self
                    .data
                    .recordings
                    .iter()
                    .find(|record| record.id == id)
                    .ok_or("Grabación no encontrada")?;
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
                });
                vec![recording]
            }
            None => Vec::new(),
        };
        let mut accounts = self.data.accounts.clone();
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
        let settings = &self.data.settings;
        let mut value = json!({
            "recordings": recordings,
            "settings": {
                "defaultRecipeId": settings.default_recipe_id,
                "language": settings.language,
                "whisperModel": settings.whisper_model,
            },
            "resolvers": self.data.resolvers,
            "recipes": self.data.recipes,
            "accounts": accounts,
            "destinations": self.data.destinations,
        });
        self.mark_credentials(&mut value);
        Ok(value)
    }

    pub(super) fn mark_credentials(&self, value: &mut Value) {
        for key in ["accounts", "resolvers"] {
            if let Some(items) = value[key].as_array_mut() {
                for item in items {
                    item["hasCredential"] = json!(self
                        .credential_path(item["id"].as_str().unwrap_or(""))
                        .is_ok_and(|p| p.is_file()));
                }
            }
        }
    }
}
