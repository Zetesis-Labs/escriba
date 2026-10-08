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
    let mut next = store.data.clone();
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
    let mut destinations = destinations.clone();
    for destination in &mut destinations {
        if let Some(old) = store.data["destinations"]
            .as_array()
            .and_then(|items| items.iter().find(|r| r["id"] == destination["id"]))
        {
            destination["enabled"] = old["enabled"].clone();
        }
    }
    next["destinations"] = json!(destinations);
    for collection in ["recipes", "destinations"] {
        let mut keys = HashSet::new();
        for item in next[collection].as_array().ok_or("Catálogo inválido")? {
            let key = text(item, "id")?;
            if !keys.insert(key) {
                return Err(format!("Identificador duplicado en {collection}: {key}"));
            }
        }
    }
    store.replace(next)
}

#[cfg(test)]
mod tests {
    use super::*;
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
        install(&mut store, &json!({"recipes":[{"id":"meeting","kind":"code","entry":"recetas/meeting/receta.js","name":"Meeting","values":{},"bundle":"new"}],"destinations":[]})).unwrap();
        assert_eq!(
            store.item("recipes", "meeting").unwrap()["values"]["idioma"],
            "en"
        );
        assert_eq!(store.item("recipes", "custom").unwrap()["base"], "meeting");
        assert_eq!(store.data["settings"]["defaultRecipeId"], "meeting");
        assert!(store.item("recipes", "code:recetas:meeting").is_err());
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
}
