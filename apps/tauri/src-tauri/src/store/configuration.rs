use super::*;

impl Store {
    pub(super) fn credential_path(&self, key: &str) -> Result<PathBuf, String> {
        Ok(self
            .root
            .join("secrets")
            .join(format!("{}.token", safe_id(key)?)))
    }
    pub fn credential(&self, key: &str) -> Result<Option<String>, String> {
        match fs::read_to_string(self.credential_path(key)?) {
            Ok(s) => Ok(Some(s)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("No se puede leer la credencial: {e}")),
        }
    }
    pub fn save_credential(&self, key: &str, value: &str) -> Result<(), String> {
        if self.item("accounts", key).is_err() && self.item("resolvers", key).is_err() {
            return Err("La cuenta no existe".into());
        }
        let path = self.credential_path(key)?;
        if value.trim().is_empty() {
            if path.exists() {
                fs::remove_file(path).map_err(|e| e.to_string())?;
            }
            Ok(())
        } else {
            atomic_write(&path, value.trim().as_bytes())
        }
    }
    pub fn save_connector(&mut self, account: &Value, destination: &Value) -> Result<(), String> {
        let key = text(account, "id")?;
        safe_id(key)?;
        let provider = text(account, "provider")?;
        if !["notion", "okf"].contains(&provider)
            || destination["id"] != key
            || destination["account"] != key
            || destination["provider"] != provider
            || destination.get("program").is_some()
            || destination["enabled"].as_bool().is_none()
        {
            return Err("Cuenta y destino del conector no coinciden".into());
        }
        if !account.is_object() || !destination["configuration"].is_object() {
            return Err("Configuración del conector inválida".into());
        }
        if self
            .item("accounts", key)
            .is_ok_and(|old| old["provider"] != provider)
            || self
                .item("destinations", key)
                .is_ok_and(|old| !old["program"].is_null())
        {
            return Err("El identificador pertenece a otro conector".into());
        }
        let mut account = account.clone();
        let mut destination = destination.clone();
        account["enabled"] = json!(true);
        if provider == "notion" {
            account["origin"] = json!("https://api.notion.com");
        } else {
            let folder = destination["configuration"]["folder"]
                .as_str()
                .ok_or("Carpeta OKF inválida")?;
            let folder = if folder.is_empty() {
                String::new()
            } else {
                canonical_folder(Path::new(folder))?
                    .to_string_lossy()
                    .into_owned()
            };
            account["folder"] = json!(folder);
            destination["configuration"]["folder"] = json!(folder);
        }
        for field in ["token", "secret", "credential", "hasCredential"] {
            account
                .as_object_mut()
                .ok_or("Cuenta inválida")?
                .remove(field);
        }
        let mut next = self.data.edit();
        for (collection, item) in [("accounts", account), ("destinations", destination)] {
            let items = next
                .catalog_mut(collection)?
                .as_array_mut()
                .ok_or("Colección inválida")?;
            if let Some(old) = items.iter_mut().find(|old| old["id"] == key) {
                *old = item;
            } else {
                items.push(item);
            }
        }
        self.commit(next)
    }
    pub fn remove_connector(&mut self, key: &str) -> Result<(), String> {
        let account = self.item("accounts", key)?;
        let destination = self.item("destinations", key)?;
        if !["notion", "okf"].contains(&account["provider"].as_str().unwrap_or(""))
            || destination["account"] != key
            || !destination["program"].is_null()
        {
            return Err("El conector de la app no coincide con su cuenta y destino".into());
        }
        let mut next = self.data.edit();
        for collection in ["accounts", "destinations"] {
            next.catalog_mut(collection)?
                .as_array_mut()
                .ok_or("Colección inválida")?
                .retain(|item| item["id"] != key);
        }
        for recipe in next.recipes.as_array_mut().ok_or("Recetas inválidas")? {
            if recipe["kind"] == "form" {
                prune(&mut recipe["values"], key);
            }
        }
        let credential = self.credential_path(key)?;
        self.commit(next)?;
        match fs::remove_file(credential) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!(
                "El conector se quitó, pero no se pudo borrar su token: {error}"
            )),
        }
    }
}

impl Store {
    pub(super) fn mutate_configuration(
        &self,
        next: &mut LibraryData,
        method: &str,
        p: &Value,
        delete_after_commit: &mut Option<PathBuf>,
    ) -> Result<Value, String> {
        Ok(match method {
            "config_save" => {
                let collection = collection(p)?;
                let mut item = p["item"].clone();
                let key = text(&item, "id")?.to_owned();
                if collection == "accounts" || collection == "resolvers" {
                    safe_id(&key)?;
                }
                if !item.is_object() || item["name"].as_str().is_none_or(|s| s.trim().is_empty()) {
                    return Err("Escribe un nombre".into());
                }
                if collection == "resolvers" {
                    if !["stt", "llm"].contains(&item["role"].as_str().unwrap_or("")) {
                        return Err("Papel de resolutor inválido".into());
                    }
                    if !["local-stt", "local-llm"].contains(&key.as_str()) {
                        item["local"] = json!(false);
                    } else {
                        item["local"] = json!(true);
                        item["enabled"] = json!(true);
                    }
                }
                if collection == "accounts" {
                    if !["notion", "okf"].contains(&item["provider"].as_str().unwrap_or("")) {
                        return Err("Proveedor no válido".into());
                    }
                    if item["provider"] == "notion" {
                        item["origin"] = json!("https://api.notion.com");
                    }
                    if let Some(folder) = item["folder"].as_str().filter(|f| !f.is_empty()) {
                        let path = Path::new(folder)
                            .canonicalize()
                            .map_err(|e| format!("Carpeta inaccesible: {e}"))?;
                        if !path.is_dir() {
                            return Err("Elige una carpeta".into());
                        }
                        item["folder"] = json!(path);
                    }
                }
                for secret in ["token", "secret", "credential", "hasCredential"] {
                    item.as_object_mut()
                        .ok_or("Configuración inválida")?
                        .remove(secret);
                }
                for derived in ["bundleFingerprint", "programFingerprint"] {
                    item.as_object_mut()
                        .ok_or("Configuración inválida")?
                        .remove(derived);
                }
                let items = next
                    .catalog_mut(collection)?
                    .as_array_mut()
                    .ok_or("Colección inválida")?;
                if let Some(old) = items.iter_mut().find(|i| i["id"] == key) {
                    for program in ["bundle", "program"] {
                        if item.get(program).is_none() {
                            if let Some(kept) = old.get(program).cloned() {
                                item[program] = kept;
                            }
                        }
                    }
                    *old = item.clone();
                } else {
                    if collection == "accounts" || collection == "resolvers" {
                        let orphan = self.credential_path(&key)?;
                        if orphan.exists() {
                            fs::remove_file(orphan).map_err(|e| {
                                format!(
                                    "No se pudo retirar la credencial de una cuenta anterior: {e}"
                                )
                            })?;
                        }
                    }
                    items.push(item.clone());
                }
                item
            }
            "config_remove" => {
                let collection = collection(p)?;
                let key = text(p, "id")?;
                if ["local-stt", "local-llm", "default"].contains(&key) {
                    return Err("Esta opción viene de serie y no se puede quitar".into());
                }
                if collection == "accounts"
                    && next.recordings.iter().any(|record| {
                        record.publications.as_ref().is_some_and(|publications| {
                            publications
                                .iter()
                                .any(|publication| publication["accountId"] == key)
                        })
                    })
                {
                    return Err(
                        "Retira las publicaciones de esta cuenta antes de eliminarla".into(),
                    );
                }
                next.catalog_mut(collection)?
                    .as_array_mut()
                    .ok_or("Colección inválida")?
                    .retain(|i| i["id"] != key);
                if collection == "resolvers" || collection == "destinations" {
                    for recipe in next.recipes.as_array_mut().ok_or("Recetas inválidas")? {
                        if recipe["kind"] == "form" {
                            prune(&mut recipe["values"], key);
                        }
                    }
                }
                if next
                    .settings
                    .default_recipe_id
                    .as_ref()
                    .is_some_and(|id| id == key)
                {
                    next.settings.default_recipe_id = "default".to_owned().into();
                }
                if collection == "accounts" || collection == "resolvers" {
                    *delete_after_commit = Some(self.credential_path(key)?);
                }
                Value::Null
            }
            _ => return Err(format!("Operación desconocida: {method}")),
        })
    }
}
