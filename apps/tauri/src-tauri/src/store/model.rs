use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

#[derive(Clone, Debug, Default, PartialEq, Hash)]
pub enum Field<T> {
    #[default]
    Missing,
    Present(Option<T>),
}

impl<T> Field<T> {
    pub fn is_missing(&self) -> bool {
        matches!(self, Self::Missing)
    }
    pub fn as_ref(&self) -> Option<&T> {
        match self {
            Self::Present(value) => value.as_ref(),
            Self::Missing => None,
        }
    }
    pub fn as_mut(&mut self) -> Option<&mut T> {
        match self {
            Self::Present(value) => value.as_mut(),
            Self::Missing => None,
        }
    }
}
impl<T> From<T> for Field<T> {
    fn from(value: T) -> Self {
        Self::Present(Some(value))
    }
}
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Field<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self::Present(Option::deserialize(deserializer)?))
    }
}
impl<T: Serialize> Serialize for Field<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Present(value) => value.serialize(serializer),
            Self::Missing => serializer.serialize_none(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RecordingStatus {
    #[default]
    Pending,
    Processing,
    Done,
    Failed,
    Discarded,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recording {
    pub id: String,
    pub status: RecordingStatus,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub title: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub created_at: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub source: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub source_key: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub legacy_key: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub audio_path: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub audio_hash: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub duration: Field<serde_json::Number>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub error: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub recipe_id: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub current_version_id: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub versions: Field<Vec<Version>>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub publications: Field<Vec<Value>>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Hash)]
#[serde(rename_all = "camelCase")]
pub struct Version {
    pub id: String,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub created_at: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub backend: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub transcript: Field<Transcript>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub has_voices: Field<bool>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub recipe_id: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub digest: Field<Value>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub data: Field<Value>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub inputs: Field<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Hash)]
pub struct Transcript {
    pub text: String,
    pub segments: Vec<Segment>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub duration: Field<serde_json::Number>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub language: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub recognitions: Field<Vec<Recognition>>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub project_ontologies: Field<Vec<crate::knowledge::Ontology>>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub default_recipe_id: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub project_path: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub watched_folders: Field<Vec<WatchedFolder>>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub whisper_model: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub launch_at_login: Field<bool>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub notify_every_note: Field<bool>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub language: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub recipe_selection_migrated: Field<bool>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub voice_memos_seeded: Field<bool>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub legacy_watch_adopted: Field<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WatchedFolder {
    pub id: String,
    pub path: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub style: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub enabled: Field<bool>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub access_bookmark: Field<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryData {
    pub schema_version: u32,
    pub recordings: Vec<Recording>,
    pub settings: Settings,
    pub accounts: Value,
    pub resolvers: Value,
    pub recipes: Value,
    pub destinations: Value,
    #[serde(default = "empty_catalog")]
    pub providers: Value,
    pub logs: Value,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

fn empty_catalog() -> Value {
    Value::Array(Vec::new())
}

#[derive(Clone, Debug)]
pub struct LibraryIndex(LibraryData);

impl std::ops::Deref for LibraryIndex {
    type Target = LibraryData;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl LibraryIndex {
    pub(super) fn from_index(data: LibraryData) -> Self {
        Self(data)
    }
    pub(super) fn new(data: LibraryData) -> Result<Self, String> {
        let ids = data
            .recordings
            .iter()
            .map(|record| record.id.clone())
            .collect();
        Self::from_edit(data, &ids)
    }
    pub(super) fn from_edit(
        mut data: LibraryData,
        full_recordings: &std::collections::HashSet<String>,
    ) -> Result<Self, String> {
        for record in data
            .recordings
            .iter_mut()
            .filter(|record| full_recordings.contains(&record.id))
        {
            if let Some(versions) = record.versions.as_mut() {
                for version in versions {
                    *version = version.preview();
                }
            }
            if let Some(publications) = record.publications.as_mut() {
                for publication in publications {
                    *publication = crate::library_view::light_publication(publication);
                }
            }
        }
        Ok(Self(data))
    }

    pub(super) fn edit(&self) -> LibraryData {
        self.0.clone()
    }
    pub(super) fn json(&self) -> Value {
        serde_json::json!(&self.0)
    }
}

impl LibraryData {
    pub fn read(value: &Value) -> Result<Self, String> {
        <Self as Deserialize>::deserialize(value)
            .map_err(|_| "Biblioteca inválida: los datos guardados no cumplen su formato".into())
    }
}

#[cfg(test)]
mod watched_folder_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn carpeta_guardada_conserva_nulos_ausentes_y_extensiones() {
        let original = json!({"id":"folder-1","path":"/tmp/synthetic","name":"Sintética","style":null,"accessBookmark":null,"futureSetting":{"enabled":true}});
        let folder: WatchedFolder = serde_json::from_value(original.clone()).unwrap();
        assert_eq!(serde_json::to_value(folder).unwrap(), original);
        let without_optionals = json!({"id":"folder-2","path":"/tmp/other","name":"Otra"});
        let folder: WatchedFolder = serde_json::from_value(without_optionals.clone()).unwrap();
        assert_eq!(serde_json::to_value(folder).unwrap(), without_optionals);
        let damaged_bookmark =
            json!({"id":"folder-3","path":"/tmp/old","name":"Antigua","accessBookmark":"damaged"});
        let folder: WatchedFolder = serde_json::from_value(damaged_bookmark.clone()).unwrap();
        assert_eq!(serde_json::to_value(&folder).unwrap(), damaged_bookmark);
        assert!(
            super::super::settings::bookmark_bytes(folder.access_bookmark.as_ref().unwrap())
                .is_err()
        );
    }

    #[test]
    fn carpeta_guardada_rechaza_identidad_o_ruta_de_tipo_incorrecto() {
        for invalid in [
            json!({"id":7,"path":"/tmp/synthetic","name":"Sintética"}),
            json!({"id":"folder-1","path":false,"name":"Sintética"}),
        ] {
            assert!(serde_json::from_value::<WatchedFolder>(invalid).is_err());
        }
    }
}

impl LibraryData {
    pub fn catalog(&self, name: &str) -> Result<&Value, String> {
        match name {
            "accounts" => Ok(&self.accounts),
            "resolvers" => Ok(&self.resolvers),
            "recipes" => Ok(&self.recipes),
            "destinations" => Ok(&self.destinations),
            "providers" => Ok(&self.providers),
            _ => Err("Colección desconocida".into()),
        }
    }
    pub fn catalog_mut(&mut self, name: &str) -> Result<&mut Value, String> {
        match name {
            "accounts" => Ok(&mut self.accounts),
            "resolvers" => Ok(&mut self.resolvers),
            "recipes" => Ok(&mut self.recipes),
            "destinations" => Ok(&mut self.destinations),
            "providers" => Ok(&mut self.providers),
            _ => Err("Colección desconocida".into()),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, Hash)]
pub struct Segment {
    pub start: serde_json::Number,
    pub end: serde_json::Number,
    pub text: String,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub speaker: Field<String>,
    #[serde(default, skip_serializing_if = "Field::is_missing")]
    pub words: Field<Vec<Word>>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Hash)]
pub struct Word {
    pub start: serde_json::Number,
    pub end: serde_json::Number,
    pub text: String,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, Hash)]
pub struct Recognition {
    pub speaker: String,
    pub person: String,
    pub distance: serde_json::Number,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
