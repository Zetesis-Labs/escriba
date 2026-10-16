use crate::knowledge_commands::{self, KnowledgeCommand};
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};
use ts_rs::TS;

#[derive(Debug, Deserialize, TS)]
pub struct Untyped(#[ts(type = "Record<string, unknown>")] pub Value);

#[derive(Debug, Deserialize, TS)]
#[serde(tag = "method", content = "params", rename_all = "snake_case")]
pub enum AppCommand {
    ImportAudio(Untyped),
    RecordingStatus(Untyped),
    RecordingStart(Untyped),
    RecordingStop(Untyped),
    RecordingDismiss(Untyped),
    RecordingCancel(Untyped),
    VoiceRegistrationStatus(Untyped),
    VoiceRegistrationStart(Untyped),
    VoiceRegistrationImport(Untyped),
    VoiceRegistrationStop(Untyped),
    VoiceRegistrationCancel(Untyped),
    VoiceRegistrationDismiss(Untyped),
    Native(Untyped),
    ProjectInit(Untyped),
    ProjectList(Untyped),
    ProjectOpenVscode(Untyped),
    ProjectTool(Untyped),
    ProjectRead(Untyped),
    ProjectWrite(Untyped),
    ExportFile(Untyped),
    Reveal(Untyped),
    OpenUrl(Untyped),
    OpenPrivacySettings(Untyped),
    SystemAppearance(Untyped),
    WhisperModel(Untyped),
    WatchScan(Untyped),
    WatchFolderAuthorize(Untyped),
}

#[derive(Debug)]
pub enum Command {
    Knowledge(KnowledgeCommand),
    App(AppCommand),
}

/// Métodos que atiende el controlador TypeScript; Rust los reenvía sin interpretarlos.
pub const CONTROLLER_METHODS: &[&str] = &[
    "controller_status",
    "credential_save",
    "connector_http",
    "resolver_models",
    "resolver_try",
    "snapshot",
    "library",
    "recording_detail",
    "runtime_context",
    "runtime_run",
    "runtime_jobs",
    "runtime_history",
    "runtime_cancel",
    "runtime_relaunch",
    "runtime_job_steps",
    "log",
    "log_list",
    "memory_recall",
    "memory_keep",
    "trace_save",
    "trace_list",
    "account_effect_begin",
    "account_effect_finish",
    "recording_update",
    "recording_discard",
    "recording_remove_audio",
    "version_save",
    "version_select",
    "version_update",
    "version_delete",
    "version_keep_only",
    "note_draft_get",
    "note_draft_begin",
    "note_draft_save",
    "note_draft_discard",
    "note_draft_commit",
    "config_save",
    "config_remove",
    "settings_save",
    "publication_save",
    "publication_remove",
    "people_list",
    "people_set_color",
    "people_rename",
    "people_remove",
    "people_remove_voice",
    "connector_save",
    "connector_remove",
    "connector_files",
    "connector_audio",
    "transcribe",
    "summarize",
    "ask",
    "native_cancel",
    "project_install",
    "okf_file",
];

pub fn forwarded(method: &str) -> bool {
    CONTROLLER_METHODS.contains(&method)
}

#[derive(Debug)]
pub struct Request {
    pub method: String,
    pub command: Command,
}

pub(crate) fn tagged<T: DeserializeOwned>(method: &str, params: Value) -> Result<T, String> {
    let params = if params.is_null() { json!({}) } else { params };
    serde_json::from_value(json!({"method": method, "params": params})).map_err(|error| {
        if error.to_string().starts_with("unknown variant") {
            format!("Método desconocido: {method}")
        } else {
            format!("Parámetros inválidos para {method}: {error}")
        }
    })
}

impl Request {
    pub fn parse_ui(method: &str, params: Value) -> Result<Self, String> {
        if matches!(
            method,
            "knowledge_open" | "knowledge_query" | "knowledge_link"
        ) {
            return Err(format!("Método reservado a recetas: {method}"));
        }
        Self::parse(method, params)
    }

    pub fn parse(method: &str, params: Value) -> Result<Self, String> {
        let command = if method.starts_with("knowledge_") {
            Command::Knowledge(knowledge_commands::parse(method, params)?)
        } else {
            Command::App(tagged(method, params)?)
        };
        Ok(Self {
            method: method.to_owned(),
            command,
        })
    }

    pub fn refreshes(&self) -> bool {
        matches!(
            self.command,
            Command::Knowledge(
                KnowledgeCommand::KnowledgeInstall(_)
                    | KnowledgeCommand::KnowledgeLink(_)
                    | KnowledgeCommand::KnowledgeSave(_)
                    | KnowledgeCommand::KnowledgeDelete(_)
                    | KnowledgeCommand::KnowledgeUnlink(_)
                    | KnowledgeCommand::KnowledgeAttach(_)
                    | KnowledgeCommand::KnowledgeFilterSave(_)
                    | KnowledgeCommand::KnowledgeFilterRemove(_)
            )
        )
    }
}

#[cfg(test)]
pub fn methods<T: TS>() -> Vec<String> {
    T::decl(&ts_rs::Config::new())
        .split("\"method\": \"")
        .skip(1)
        .filter_map(|part| part.split('"').next())
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::knowledge_commands::KnowledgeReply;

    fn parse(method: &str, params: Value) -> Result<Request, String> {
        Request::parse(method, params)
    }

    fn sample(method: &str) -> Value {
        let dependency = json!({"id":"o","minVersion":1,"maxVersion":1});
        let access =
            json!({"recipeId":"r","recordingId":"n","ontologyId":"o","dependency":dependency});
        let with = |extra: Value| {
            let mut params = access.clone();
            params
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            params
        };
        let filter = json!({"kind":"surrealql","ontologyId":"escriba","sql":"SELECT VALUE id FROM recording"});
        match method {
            "knowledge_install" => {
                json!({"definition":{"id":"o","name":"O","version":1,"migrations":[],"collections":[]}})
            }
            "knowledge_open" => access,
            "knowledge_query" => with(json!({"expectedVersion":1,"sql":"","bindings":""})),
            "knowledge_link" => with(json!({"expectedVersion":1,"versionId":"v","recordId":"t:a"})),
            "knowledge_records" => json!({"id":"o","table":"t"}),
            "knowledge_save" => json!({"id":"o","expectedVersion":1,"table":"t","values":{}}),
            "knowledge_delete" => {
                json!({"id":"o","expectedVersion":1,"table":"t","recordId":"t:a","expectedRev":"1"})
            }
            "knowledge_unlink" => {
                json!({"id":"o","expectedVersion":1,"recordId":"t:a","recordingId":"n"})
            }
            "knowledge_attach" => {
                json!({"id":"o","expectedVersion":1,"recordId":"t:a","recordingId":"n","versionId":"v"})
            }
            "knowledge_graph_roots" => json!({"ontologyId":"o","table":"t"}),
            "knowledge_graph_expand" | "knowledge_graph_detail" => {
                json!({"ontologyId":"o","recordId":"t:a"})
            }
            "knowledge_filter_notes" => json!({"filter":filter}),
            "knowledge_filter_save" => json!({"filter":{"name":"F","filter":filter}}),
            "knowledge_filter_remove" => json!({"id":"f"}),
            _ => json!({}),
        }
    }

    #[test]
    fn un_metodo_desconocido_falla_al_deserializar() {
        for method in [
            "knowledge_inventado",
            "recording_inventado",
            "recording_delete",
        ] {
            assert_eq!(
                parse(method, json!({})).unwrap_err(),
                format!("Método desconocido: {method}")
            );
        }
    }

    #[test]
    fn la_interfaz_no_puede_usar_las_capacidades_de_conocimiento_de_recetas() {
        for method in ["knowledge_open", "knowledge_query", "knowledge_link"] {
            assert_eq!(
                Request::parse_ui(method, sample(method)).unwrap_err(),
                format!("Método reservado a recetas: {method}")
            );
            assert!(Request::parse(method, sample(method)).is_ok());
        }
        assert!(Request::parse_ui("knowledge_list", Value::Null).is_ok());
    }

    #[test]
    fn un_parametro_de_mas_o_mal_tipado_falla_nombrando_el_campo() {
        let extra = parse(
            "knowledge_graph_detail",
            json!({"ontologyId":"escriba","recordId":"recording:a","intruso":1}),
        )
        .unwrap_err();
        assert!(
            extra.contains("knowledge_graph_detail") && extra.contains("intruso"),
            "{extra}"
        );
        let typed = parse(
            "knowledge_records",
            json!({"id":"escriba","table":"segment","page":"uno"}),
        )
        .unwrap_err();
        assert!(typed.contains("knowledge_records"), "{typed}");
        assert!(parse("knowledge_list", Value::Null).is_ok());
        assert!(parse("recording_status", Value::Null).is_ok());
    }

    #[test]
    fn solo_los_cambios_de_conocimiento_refrescan_la_biblioteca() {
        for method in [
            "knowledge_install",
            "knowledge_link",
            "knowledge_save",
            "knowledge_delete",
            "knowledge_unlink",
            "knowledge_attach",
            "knowledge_filter_save",
            "knowledge_filter_remove",
        ] {
            assert!(
                parse(method, sample(method)).unwrap().refreshes(),
                "{method}"
            );
        }
        for method in [
            "knowledge_list",
            "knowledge_graph_detail",
            "recording_status",
        ] {
            assert!(
                !parse(method, sample(method)).unwrap().refreshes(),
                "{method}"
            );
        }
    }

    #[test]
    fn un_metodo_del_controlador_no_es_tambien_un_comando_de_rust() {
        for method in CONTROLLER_METHODS {
            assert!(forwarded(method));
            assert_eq!(
                parse(method, json!({})).unwrap_err(),
                format!("Método desconocido: {method}")
            );
        }
        assert!(!forwarded("recording_status"));
        assert!(!forwarded("inventado"));
        assert!(parse("recording_status", Value::Null).is_ok());
    }

    #[test]
    fn cada_comando_de_conocimiento_tiene_su_respuesta() {
        assert_eq!(methods::<KnowledgeCommand>(), methods::<KnowledgeReply>());
    }

    #[test]
    fn cada_comando_figura_en_el_contrato() {
        let contract = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../CONTRACT.md"),
        )
        .unwrap();
        let mentioned = |method: &str| {
            contract.match_indices(method).any(|(at, _)| {
                let before = contract[..at].chars().next_back();
                let after = contract[at + method.len()..].chars().next();
                !before.is_some_and(|c| c.is_alphanumeric() || c == '_')
                    && !after.is_some_and(|c| c.is_alphanumeric() || c == '_')
            })
        };
        let missing: Vec<String> = methods::<AppCommand>()
            .into_iter()
            .chain(methods::<KnowledgeCommand>())
            .chain(CONTROLLER_METHODS.iter().map(|method| (*method).to_owned()))
            .filter(|method| !mentioned(method))
            .collect();
        assert!(
            missing.is_empty(),
            "Sin documentar en CONTRACT.md: {missing:?}"
        );
    }
}

#[cfg(test)]
mod bindings {
    use super::*;
    use crate::knowledge_commands::KnowledgeReply;
    use std::{collections::BTreeMap, fs, path::Path};

    fn files(root: &Path) -> BTreeMap<String, String> {
        walkdir::WalkDir::new(root)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().is_file())
            .map(|entry| {
                (
                    entry
                        .path()
                        .strip_prefix(root)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                    fs::read_to_string(entry.path()).unwrap(),
                )
            })
            .collect()
    }

    fn export(out: &Path) {
        let config = ts_rs::Config::new().with_out_dir(out);
        AppCommand::export_all(&config).unwrap();
        KnowledgeCommand::export_all(&config).unwrap();
        KnowledgeReply::export_all(&config).unwrap();
        crate::platform::Platform::export_all(&config).unwrap();
        let platforms = serde_json::json!({
            "macos": crate::platform::MACOS,
            "linux": crate::platform::LINUX,
        });
        fs::write(
            out.join("platforms.json"),
            serde_json::to_string_pretty(&platforms).unwrap() + "\n",
        )
        .unwrap();
    }

    #[test]
    fn los_tipos_generados_coinciden_con_el_codigo() {
        let committed = Path::new(env!("CARGO_MANIFEST_DIR")).join("../src/generated");
        if std::env::var_os("ESCRIBA_WRITE_BINDINGS").is_some() {
            let _ = fs::remove_dir_all(&committed);
            export(&committed);
            return;
        }
        let fresh = tempfile::tempdir().unwrap();
        export(fresh.path());
        assert!(
            files(fresh.path()) == files(&committed),
            "Los tipos de apps/tauri/src/generated no coinciden con Rust: ESCRIBA_WRITE_BINDINGS=1 cargo test --lib los_tipos_generados"
        );
    }
}
