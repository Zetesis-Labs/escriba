use crate::knowledge_commands::{self, KnowledgeCommand};
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};
use ts_rs::TS;

#[derive(Debug, Deserialize, TS)]
pub struct Untyped(#[ts(type = "Record<string, unknown>")] pub Value);

#[derive(Debug, Deserialize, TS)]
#[serde(tag = "method", content = "params", rename_all = "snake_case")]
pub enum AppCommand {
    Snapshot(Untyped),
    Library(Untyped),
    RecordingDetail(Untyped),
    RuntimeContext(Untyped),
    RuntimeRun(Untyped),
    RuntimeJobs(Untyped),
    RuntimeHistory(crate::jobs::HistoryQuery),
    RuntimeCancel(Untyped),
    RuntimeRelaunch(crate::jobs::JobParams),
    RuntimeJobSteps(crate::jobs::JobParams),
    Log(Untyped),
    LogList(Untyped),
    MemoryRecall(Untyped),
    MemoryKeep(Untyped),
    TraceSave(Untyped),
    TraceList(Untyped),
    AccountEffectBegin(Untyped),
    AccountEffectFinish(Untyped),
    ImportAudio(Untyped),
    RecordingUpdate(Untyped),
    RecordingDiscard(Untyped),
    RecordingRemoveAudio(Untyped),
    RecordingStatus(Untyped),
    RecordingStart(Untyped),
    RecordingStop(Untyped),
    RecordingDismiss(Untyped),
    RecordingCancel(Untyped),
    VersionSave(Untyped),
    VersionSelect(Untyped),
    VersionUpdate(Untyped),
    NoteDraftGet(Untyped),
    NoteDraftBegin(Untyped),
    NoteDraftSave(Untyped),
    NoteDraftDiscard(Untyped),
    NoteDraftCommit(Untyped),
    ConfigSave(Untyped),
    ConfigRemove(Untyped),
    SettingsSave(Untyped),
    PublicationSave(Untyped),
    PublicationRemove(Untyped),
    PeopleList(Untyped),
    PeopleSetColor(Untyped),
    PeopleRename(Untyped),
    PeopleRemove(Untyped),
    PeopleRemoveVoice(Untyped),
    VoiceRegistrationStatus(Untyped),
    VoiceRegistrationStart(Untyped),
    VoiceRegistrationImport(Untyped),
    VoiceRegistrationStop(Untyped),
    VoiceRegistrationCancel(Untyped),
    VoiceRegistrationDismiss(Untyped),
    ConnectorSave(Untyped),
    ConnectorRemove(Untyped),
    ConnectorFiles(Untyped),
    ConnectorAudio(Untyped),
    Native(Untyped),
    NativeCancel(Untyped),
    Transcribe(Untyped),
    Summarize(Untyped),
    Ask(Untyped),
    ProjectInit(Untyped),
    ProjectBuild(Untyped),
    ProjectLoad(Untyped),
    ProjectList(Untyped),
    ProjectOpenVscode(Untyped),
    ProjectTool(Untyped),
    ProjectRead(Untyped),
    ProjectWrite(Untyped),
    ProjectInstall(Untyped),
    ExportFile(Untyped),
    Reveal(Untyped),
    OkfFile(Untyped),
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
];

pub fn forwarded(method: &str) -> bool {
    CONTROLLER_METHODS.contains(&method)
}

#[derive(Debug)]
pub struct Request {
    pub method: String,
    pub command: Command,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Policy {
    pub refreshes: bool,
    pub recipes: bool,
}

const UI_READ: Policy = Policy {
    refreshes: false,
    recipes: false,
};
const UI_WRITE: Policy = Policy {
    refreshes: true,
    recipes: false,
};
const RECIPE_READ: Policy = Policy {
    refreshes: false,
    recipes: true,
};
const RECIPE_WRITE: Policy = Policy {
    refreshes: true,
    recipes: true,
};

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

    pub fn policy(&self) -> Policy {
        match &self.command {
            Command::Knowledge(command) => knowledge_policy(command),
            Command::App(command) => app_policy(command),
        }
    }

    pub fn event(&self, changes_library: bool) -> Option<&'static str> {
        match self.command {
            Command::App(AppCommand::Log(_)) => Some("escriba://log"),
            _ if changes_library => Some("escriba://changed"),
            _ => None,
        }
    }

    pub fn recipe_reads_only(&self) -> bool {
        matches!(
            self.command,
            Command::App(
                AppCommand::RuntimeContext(_)
                    | AppCommand::ConnectorAudio(_)
                    | AppCommand::MemoryRecall(_)
            )
        )
    }
}

fn knowledge_policy(command: &KnowledgeCommand) -> Policy {
    use KnowledgeCommand::*;
    match command {
        KnowledgeCandidates(_)
        | KnowledgeList(_)
        | KnowledgeRecords(_)
        | KnowledgeGraphRoots(_)
        | KnowledgeGraphExpand(_)
        | KnowledgeGraphDetail(_)
        | KnowledgeFilterNotes(_)
        | KnowledgeFiltersList(_) => UI_READ,
        KnowledgeInstall(_)
        | KnowledgeSave(_)
        | KnowledgeDelete(_)
        | KnowledgeUnlink(_)
        | KnowledgeAttach(_)
        | KnowledgeFilterSave(_)
        | KnowledgeFilterRemove(_) => UI_WRITE,
        KnowledgeOpen(_) | KnowledgeQuery(_) | KnowledgeLink(_) => RECIPE_READ,
    }
}

fn app_policy(command: &AppCommand) -> Policy {
    use AppCommand::*;
    match command {
        RuntimeRun(Untyped(params)) => Policy {
            refreshes: params["operation"].as_str().is_some_and(|operation| {
                crate::jobs::durable(operation) || operation == "rebuildProject"
            }),
            recipes: false,
        },
        Snapshot(_)
        | Library(_)
        | RecordingDetail(_)
        | RuntimeJobs(_)
        | RuntimeHistory(_)
        | RuntimeJobSteps(_)
        | LogList(_)
        | TraceList(_)
        | RecordingStatus(_)
        | RecordingStart(_)
        | RecordingDismiss(_)
        | RecordingCancel(_)
        | NoteDraftGet(_)
        | NoteDraftBegin(_)
        | NoteDraftSave(_)
        | NoteDraftDiscard(_)
        | PeopleList(_)
        | VoiceRegistrationStatus(_)
        | VoiceRegistrationStart(_)
        | VoiceRegistrationImport(_)
        | VoiceRegistrationStop(_)
        | VoiceRegistrationCancel(_)
        | VoiceRegistrationDismiss(_)
        | Native(_)
        | ProjectList(_)
        | ProjectOpenVscode(_)
        | ProjectTool(_)
        | ProjectRead(_)
        | ExportFile(_)
        | Reveal(_)
        | OkfFile(_)
        | OpenUrl(_)
        | OpenPrivacySettings(_)
        | SystemAppearance(_)
        | WhisperModel(_) => UI_READ,
        RuntimeCancel(_)
        | RuntimeRelaunch(_)
        | ImportAudio(_)
        | RecordingDiscard(_)
        | RecordingRemoveAudio(_)
        | RecordingStop(_)
        | NoteDraftCommit(_)
        | ConfigSave(_)
        | ConfigRemove(_)
        | SettingsSave(_)
        | PeopleSetColor(_)
        | PeopleRename(_)
        | PeopleRemove(_)
        | PeopleRemoveVoice(_)
        | ConnectorSave(_)
        | ConnectorRemove(_)
        | ProjectInit(_)
        | ProjectWrite(_)
        | WatchScan(_)
        | WatchFolderAuthorize(_) => UI_WRITE,
        RuntimeContext(_)
        | Log(_)
        | MemoryRecall(_)
        | MemoryKeep(_)
        | AccountEffectBegin(_)
        | AccountEffectFinish(_)
        | ConnectorFiles(_)
        | ConnectorAudio(_)
        | NativeCancel(_)
        | Transcribe(_)
        | Summarize(_)
        | Ask(_)
        | ProjectBuild(_)
        | ProjectLoad(_) => RECIPE_READ,
        TraceSave(_) | RecordingUpdate(_) | VersionSave(_) | VersionSelect(_)
        | VersionUpdate(_) | PublicationSave(_) | PublicationRemove(_) | ProjectInstall(_) => {
            RECIPE_WRITE
        }
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
            "runtime_history" => json!({"limit":100}),
            "runtime_relaunch" | "runtime_job_steps" => json!({"id":"j"}),
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
        assert!(parse("snapshot", Value::Null).is_ok());
    }

    #[test]
    fn las_recetas_solo_alcanzan_sus_capacidades() {
        let recipe = |method: &str| parse(method, sample(method)).unwrap().policy().recipes;
        for allowed in [
            "runtime_context",
            "knowledge_open",
            "knowledge_query",
            "knowledge_link",
            "account_effect_begin",
            "account_effect_finish",
            "recording_update",
            "version_save",
            "version_select",
            "version_update",
            "log",
            "transcribe",
            "summarize",
            "ask",
            "native_cancel",
            "project_build",
            "project_load",
            "project_install",
            "connector_files",
            "connector_audio",
            "publication_save",
            "publication_remove",
            "memory_recall",
            "memory_keep",
            "trace_save",
        ] {
            assert!(recipe(allowed), "{allowed}");
        }
        let all: Vec<String> = methods::<AppCommand>()
            .into_iter()
            .chain(methods::<KnowledgeCommand>())
            .collect();
        assert_eq!(all.iter().filter(|method| recipe(method)).count(), 25);
        for forbidden in [
            "people_set_color",
            "settings_save",
            "export_file",
            "open_url",
            "open_privacy_settings",
            "watch_folder_authorize",
            "recording_start",
            "import_audio",
            "runtime_run",
            "note_draft_get",
            "note_draft_commit",
            "knowledge_filter_notes",
            "knowledge_filter_save",
            "knowledge_install",
        ] {
            assert!(!recipe(forbidden), "{forbidden}");
        }
    }

    #[test]
    fn el_registro_solo_avisa_al_registro_y_un_trabajo_refresca_si_es_duradero() {
        let log = parse("log", json!({"message":"x"})).unwrap();
        assert_eq!(log.event(log.policy().refreshes), Some("escriba://log"));
        let process = parse(
            "runtime_run",
            json!({"operation":"processRecording","args":{}}),
        )
        .unwrap();
        assert!(process.policy().refreshes);
        let schema = parse(
            "runtime_run",
            json!({"operation":"getRecipeSchema","args":{}}),
        )
        .unwrap();
        assert!(!schema.policy().refreshes);
        assert_eq!(schema.event(false), None);
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
        assert!(!forwarded("snapshot"));
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
        crate::jobs::HistoryPage::export_all(&config).unwrap();
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
