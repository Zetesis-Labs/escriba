use crate::store::{text, Store};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

pub fn install(store: &mut Store, package: &Value) -> Result<(), String> {
    let compiled = package["recipes"]
        .as_array()
        .ok_or("Recetas compiladas inválidas")?;
    let destinations = package["destinations"]
        .as_array()
        .ok_or("Destinos compilados inválidos")?;
    let empty_providers = Vec::new();
    let providers = match package.get("providers") {
        None => &empty_providers,
        Some(value) => value.as_array().ok_or("Proveedores compilados inválidos")?,
    };
    let mut next = store.index_json();
    let previous = next["recipes"]
        .as_array()
        .ok_or("Recetas inválidas")?
        .clone();
    let mut recipes: Vec<Value> = previous
        .iter()
        .filter(|r| r["kind"] != "code")
        .cloned()
        .collect();
    let mut aliases = HashMap::<String, String>::new();
    let mut installed = HashSet::new();
    for built in compiled {
        let id = text(built, "id")?;
        if built["kind"] != "code" || !built["bundle"].is_string() {
            return Err("Paquete de receta inválido".into());
        }
        let old = previous.iter().find(|r| {
            r["kind"] == "code"
                && (r["id"] == id || (built["entry"].is_string() && r["entry"] == built["entry"]))
        });
        let mut recipe = built.clone();
        if let Some(old) = old {
            aliases.insert(text(old, "id")?.to_owned(), id.to_owned());
            recipe["values"] = old["values"].clone();
            installed.insert(text(old, "id")?.to_owned());
        }
        installed.insert(id.to_owned());
        recipes.push(recipe);
    }
    for old in previous.into_iter().filter(|r| r["kind"] == "code") {
        if !installed.contains(text(&old, "id")?) {
            let mut missing = old;
            missing
                .as_object_mut()
                .ok_or("Receta inválida")?
                .remove("bundle");
            missing["error"] = json!("No se encontró la fuente al compilar el proyecto");
            recipes.push(missing);
        }
    }
    let remap = |value: &mut Value| {
        if let Some(replacement) = value.as_str().and_then(|key| aliases.get(key)) {
            *value = json!(replacement);
        }
    };
    for recipe in &mut recipes {
        if recipe["kind"] == "form" {
            remap(&mut recipe["base"]);
        }
    }
    remap(&mut next["settings"]["defaultRecipeId"]);
    for record in next["recordings"]
        .as_array_mut()
        .ok_or("Biblioteca inválida")?
        .iter_mut()
        .filter(|record| record["status"] != "discarded")
    {
        remap(&mut record["recipeId"]);
        for version in record["versions"]
            .as_array_mut()
            .ok_or("Versiones inválidas")?
        {
            remap(&mut version["recipeId"]);
        }
    }
    next["recipes"] = json!(recipes);
    let mut destinations = store
        .data
        .destinations
        .as_array()
        .ok_or("Destinos inválidos")?
        .iter()
        .filter(|destination| destination["managed"] == true || destination["program"].is_null())
        .cloned()
        .chain(destinations.iter().cloned().map(|mut destination| {
            if let Some(fields) = destination.as_object_mut() {
                fields.remove("managed");
            }
            destination
        }))
        .collect::<Vec<_>>();
    for destination in &mut destinations {
        if destination["managed"] == true {
            if let Some(provider) = providers
                .iter()
                .find(|provider| provider["id"] == destination["provider"])
            {
                destination["program"] = provider["program"].clone();
                destination["programFingerprint"] = provider["programFingerprint"].clone();
            }
        }
        if let Some(old) = store
            .data
            .destinations
            .as_array()
            .and_then(|items| items.iter().find(|r| r["id"] == destination["id"]))
        {
            destination["enabled"] = old["enabled"].clone();
        }
    }
    next["destinations"] = json!(destinations);
    let previous_providers = store
        .data
        .providers
        .as_array()
        .ok_or("Proveedores inválidos")?;
    let mut installed_providers = HashSet::new();
    let mut next_providers = Vec::new();
    for provider in providers {
        let id = text(provider, "id")?;
        crate::store::safe_id(id)?;
        if ["notion", "okf"].contains(&id)
            || provider["name"]
                .as_str()
                .is_none_or(|name| name.trim().is_empty())
            || !provider["defaultConfiguration"].is_object()
            || provider["program"].as_str().is_none_or(str::is_empty)
        {
            return Err("Proveedor compilado inválido".into());
        }
        crate::capabilities::validate_access(provider)?;
        installed_providers.insert(id.to_owned());
        let mut installed = provider.clone();
        installed["unavailable"] = json!(false);
        next_providers.push(installed);
    }
    for old in previous_providers {
        if !installed_providers.contains(text(old, "id")?) {
            let mut missing = old.clone();
            missing["unavailable"] = json!(true);
            next_providers.push(missing);
        }
    }
    next["providers"] = json!(next_providers);
    for collection in ["recipes", "destinations", "providers"] {
        let mut keys = HashSet::new();
        for item in next[collection].as_array().ok_or("Catálogo inválido")? {
            let key = text(item, "id")?;
            if !keys.insert(key) {
                return Err(format!("Identificador duplicado en {collection}: {key}"));
            }
        }
    }
    store.replace_catalog(next, aliases)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn proveedor_del_proyecto_sobrevive_reapertura_y_retirada_sin_perder_cuenta() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::open(temp.path().into()).unwrap();
        let provider = json!({"id":"example","name":"Example","capability":"http","origin":"https://example.org","allowedHeaders":["x-api-version"],"credential":{"label":"Token","header":"x-api-key"},"defaultConfiguration":{},"program":"compiled"});
        install(
            &mut store,
            &json!({"recipes":[],"destinations":[],"providers":[provider]}),
        )
        .unwrap();
        assert_eq!(
            store.item("providers", "example").unwrap()["program"],
            "compiled"
        );
        drop(store);
        let mut store = Store::open(temp.path().into()).unwrap();
        assert_eq!(
            store.runtime_context(None).unwrap()["providers"][0]["origin"],
            "https://example.org"
        );
        store.save_connector(&json!({"id":"draft","name":"Draft","provider":"example","enabled":false}), &json!({"id":"draft","name":"Draft","account":"draft","provider":"example","enabled":false,"configuration":{}})).unwrap();
        assert_eq!(store.item("accounts", "draft").unwrap()["enabled"], false);
        assert!(store.item("accounts", "draft").unwrap()["grant"].is_null());
        store.save_connector(&json!({"id":"a","name":"A","provider":"example","grant":{"capability":"http","origin":"https://example.org","allowedHeaders":["x-api-version"],"credential":{"label":"Token","header":"x-api-key"}}}), &json!({"id":"a","name":"A","account":"a","provider":"example","enabled":true,"configuration":{}})).unwrap();
        assert_eq!(store.item("destinations", "a").unwrap()["managed"], true);
        assert_eq!(
            store.item("destinations", "a").unwrap()["program"],
            "compiled"
        );
        store.save_credential("a", "synthetic-token").unwrap();
        assert!(store.mutate("config_save", &json!({"collection":"accounts","item":{"id":"a","name":"Notion","provider":"notion","enabled":true}})).is_err());
        assert_eq!(
            store.credential("a").unwrap().as_deref(),
            Some("synthetic-token")
        );
        let mut account = store.item("accounts", "a").unwrap();
        account["enabled"] = json!(false);
        let destination = store.item("destinations", "a").unwrap();
        store.save_connector(&account, &destination).unwrap();
        assert_eq!(store.item("accounts", "a").unwrap()["enabled"], false);
        let mut changed = store.item("providers", "example").unwrap();
        changed["program"] = json!("updated");
        install(
            &mut store,
            &json!({"recipes":[],"destinations":[],"providers":[changed]}),
        )
        .unwrap();
        assert_eq!(
            store.item("destinations", "a").unwrap()["program"],
            "updated"
        );
        assert_eq!(store.item("destinations", "a").unwrap()["enabled"], true);
        install(
            &mut store,
            &json!({"recipes":[],"destinations":[],"providers":[]}),
        )
        .unwrap();
        assert_eq!(
            store.item("providers", "example").unwrap()["unavailable"],
            true
        );
        assert_eq!(
            store.item("providers", "example").unwrap()["program"],
            "updated"
        );
        assert_eq!(
            store.item("destinations", "a").unwrap()["program"],
            "updated"
        );
        assert_eq!(store.item("accounts", "a").unwrap()["provider"], "example");
    }
    #[test]
    fn instalar_recetas_con_notas_descartadas_conserva_el_descarte() {
        let temp = tempfile::tempdir().unwrap();
        let audio = temp.path().join("prueba.wav");
        std::fs::write(&audio, b"audio sintetico").unwrap();
        let root = temp.path().join("library");
        let mut store = Store::open(root.clone()).unwrap();
        let record = store.import(&audio, None).unwrap();
        let discarded = store
            .mutate("recording_discard", &json!({"id":record["id"]}))
            .unwrap();
        install(
            &mut store,
            &json!({"recipes":[{"id":"ejemplo","kind":"code","name":"Ejemplo","values":{},"bundle":"compiled"}],"destinations":[]}),
        )
        .unwrap();
        assert_eq!(
            store.item("recipes", "ejemplo").unwrap()["bundle"],
            "compiled"
        );
        assert_eq!(
            store.recording(record["id"].as_str().unwrap()).unwrap(),
            discarded
        );
        drop(store);
        let mut restored = Store::open(root).unwrap();
        assert_eq!(
            restored.item("recipes", "ejemplo").unwrap()["bundle"],
            "compiled"
        );
        assert_eq!(restored.import(&audio, None).unwrap(), discarded);
    }

    #[test]
    fn compiling_legacy_layout_preserves_values_default_and_form_base() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::open(temp.path().into()).unwrap();
        store.mutate("config_save", &json!({"collection":"recipes","item":{"id":"code:recetas:meeting","kind":"code","entry":"recetas/meeting/receta.js","name":"Meeting","values":{"idioma":"en"},"bundle":"old"}})).unwrap();
        store.mutate("config_save", &json!({"collection":"recipes","item":{"id":"custom","kind":"form","name":"Custom","base":"code:recetas:meeting","values":{}}})).unwrap();
        store
            .mutate(
                "settings_save",
                &json!({"settings":{"defaultRecipeId":"code:recetas:meeting"}}),
            )
            .unwrap();
        let audio = temp.path().join("activa.wav");
        std::fs::write(&audio, b"audio activo sintetico").unwrap();
        let active = store.import(&audio, Some("code:recetas:meeting")).unwrap();
        let version = store.mutate("version_save", &json!({"recordingId":active["id"],"recipeId":"code:recetas:meeting","transcript":{"text":"contenido sintetico","segments":[]}})).unwrap();
        let discarded_audio = temp.path().join("descartada.wav");
        std::fs::write(&discarded_audio, b"audio descartado sintetico").unwrap();
        let discarded = store.import(&discarded_audio, None).unwrap();
        let tombstone = store
            .mutate("recording_discard", &json!({"id":discarded["id"]}))
            .unwrap();
        install(&mut store, &json!({"recipes":[{"id":"meeting","kind":"code","entry":"recetas/meeting/receta.js","name":"Meeting","values":{},"bundle":"new"}],"destinations":[]})).unwrap();
        assert_eq!(
            store.item("recipes", "meeting").unwrap()["values"]["idioma"],
            "en"
        );
        assert_eq!(store.item("recipes", "custom").unwrap()["base"], "meeting");
        assert_eq!(store.settings_json()["defaultRecipeId"], "meeting");
        assert!(store.item("recipes", "code:recetas:meeting").is_err());
        drop(store);
        let restored = Store::open(temp.path().into()).unwrap();
        let active = restored.recording(active["id"].as_str().unwrap()).unwrap();
        assert_eq!(active["recipeId"], "meeting");
        assert_eq!(active["currentVersionId"], version["id"]);
        assert_eq!(active["versions"][0]["recipeId"], "meeting");
        assert_eq!(active["versions"][0]["transcript"], version["transcript"]);
        assert_eq!(
            restored
                .recording(discarded["id"].as_str().unwrap())
                .unwrap(),
            tombstone
        );
    }
    #[test]
    fn missing_code_keeps_its_parameters_but_cannot_execute_a_stale_program() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::open(temp.path().into()).unwrap();
        store.mutate("config_save", &json!({"collection":"recipes","item":{"id":"missing","kind":"code","entry":"recetas/missing/receta.ts","name":"Missing","values":{"language":"en"},"bundle":"old"}})).unwrap();
        install(&mut store, &json!({"recipes":[],"destinations":[]})).unwrap();
        let missing = store.item("recipes", "missing").unwrap();
        assert_eq!(missing["values"]["language"], "en");
        assert!(missing["bundle"].is_null());
        assert!(missing["error"].is_string());
    }
    #[test]
    fn compilar_conserva_destinos_de_la_app_y_sustituye_los_del_proyecto() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::open(temp.path().into()).unwrap();
        store.mutate("config_save", &json!({"collection":"destinations","item":{"id":"app","name":"App","provider":"okf","account":"app","enabled":true,"configuration":{"folder":"/tmp"}}})).unwrap();
        store.mutate("config_save", &json!({"collection":"destinations","item":{"id":"code","name":"Old","provider":"notion","account":"code","enabled":true,"configuration":{},"program":"old"}})).unwrap();
        install(&mut store, &json!({"recipes":[],"destinations":[{"id":"code","name":"New","provider":"notion","account":"code","enabled":false,"configuration":{},"program":"new"}]})).unwrap();
        assert_eq!(
            store.item("destinations", "app").unwrap()["configuration"]["folder"],
            "/tmp"
        );
        assert_eq!(
            store.item("destinations", "code").unwrap()["program"],
            "new"
        );
        assert_eq!(store.data.destinations.as_array().unwrap().len(), 2);
    }

    #[test]
    fn compilar_rechaza_id_de_proyecto_que_pertenece_a_un_destino_de_la_app() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::open(temp.path().into()).unwrap();
        store.mutate("config_save", &json!({"collection":"destinations","item":{"id":"same","name":"App","provider":"okf","account":"same","enabled":true,"configuration":{}}})).unwrap();
        let error = install(&mut store, &json!({"recipes":[],"destinations":[{"id":"same","name":"Project","provider":"okf","account":"same","enabled":true,"configuration":{},"program":"new"}]})).unwrap_err();
        assert!(error.contains("Identificador duplicado"));
        assert_eq!(store.item("destinations", "same").unwrap()["name"], "App");
    }

    #[test]
    fn proyecto_no_puede_marcar_su_destino_como_gestionado_por_la_app() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = Store::open(temp.path().into()).unwrap();
        install(&mut store, &json!({"recipes":[],"destinations":[{"id":"external","name":"External","provider":"notion","account":"a","enabled":true,"configuration":{},"program":"compiled","managed":true}]})).unwrap();
        assert!(store.item("destinations", "external").unwrap()["managed"].is_null());
        install(&mut store, &json!({"recipes":[],"destinations":[]})).unwrap();
        assert!(store.item("destinations", "external").is_err());
    }

    #[test]
    fn proveedor_de_carpeta_autoriza_despues_de_guardar_borrador() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path().join("documents");
        std::fs::create_dir(&folder).unwrap();
        let mut store = Store::open(temp.path().join("library")).unwrap();
        install(&mut store, &json!({"recipes":[],"destinations":[],"providers":[{"id":"documents","name":"Documents","capability":"folder","allowedHeaders":[],"defaultConfiguration":{},"program":"compiled"}]})).unwrap();
        let mut account =
            json!({"id":"folder","name":"Folder","provider":"documents","enabled":false});
        let mut destination = json!({"id":"folder","name":"Folder","provider":"documents","account":"folder","enabled":false,"configuration":{}});
        store.save_connector(&account, &destination).unwrap();
        assert!(store.item("accounts", "folder").unwrap()["grant"].is_null());
        account["enabled"] = json!(true);
        account["grant"] = json!({"capability":"folder","allowedHeaders":[]});
        account["folder"] = json!(folder);
        destination["configuration"]["folder"] = json!(temp.path().join("alias"));
        std::os::unix::fs::symlink(&folder, temp.path().join("alias")).unwrap();
        destination["enabled"] = json!(true);
        store.save_connector(&account, &destination).unwrap();
        let saved = store.item("accounts", "folder").unwrap();
        assert_eq!(saved["folder"], json!(folder.canonicalize().unwrap()));
        assert_eq!(
            store.item("destinations", "folder").unwrap()["configuration"]["folder"],
            saved["folder"]
        );
        assert_eq!(saved["grant"], account["grant"]);
    }
}
