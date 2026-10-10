use crate::error::{AppError, ErrorCode};
use crate::notifications::{self, Notification, Problem};
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Stt,
    Llm,
}

#[derive(Deserialize)]
pub struct ResolverProblem {
    role: Role,
    name: String,
    pub reason: String,
}

impl ResolverProblem {
    pub fn notification(&self) -> Notification {
        notifications::notification(match self.role {
            Role::Stt => Problem::TranscriberUnavailable {
                name: &self.name,
                reason: &self.reason,
            },
            Role::Llm => Problem::SummarizerUnavailable {
                name: &self.name,
                reason: &self.reason,
            },
        })
    }
}

pub fn settings_changed(method: &str, params: &Value) -> bool {
    match method {
        "config_save" | "config_remove" => params["collection"] == "resolvers",
        "connector_save" | "connector_remove" => true,
        "settings_save" => params["settings"].get("watchedFolders").is_some(),
        _ => false,
    }
}

pub fn finished(
    job: &Value,
    recording: &Value,
    result: Result<&Value, &AppError>,
    settings: &Value,
) -> Option<Notification> {
    if job["operation"] != "processRecording"
        || job["automatic"] != true
        || job["args"]["options"]["dryRun"] == true
        || result
            .as_ref()
            .is_err_and(|error| error.message == "Proceso cancelado")
    {
        return None;
    }
    let key = job["recordingId"].as_str().unwrap_or("");
    if let Err(error) = result {
        let problem = if error.code == ErrorCode::BackendUnavailable {
            Problem::BackendUnavailable(&error.message)
        } else if error.code == ErrorCode::RecipeUnavailable {
            Problem::RecipeUnavailable(&error.message)
        } else {
            Problem::Failed {
                key,
                reason: &error.message,
            }
        };
        return Some(notifications::notification(problem));
    }
    let version_id = result.ok()?["versionId"].as_str()?;
    let versions = recording["versions"].as_array()?;
    let version = versions
        .iter()
        .find(|version| version["id"] == version_id)?;
    notifications::transcribed(
        key,
        version["transcript"]["text"].as_str().unwrap_or(""),
        settings["notifyEveryNote"] != false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn revisa_resolutores_al_cambiar_los_ajustes_que_reconstruyen_el_pipeline_swift() {
        assert!(settings_changed(
            "config_save",
            &json!({"collection":"resolvers"})
        ));
        assert!(settings_changed(
            "config_remove",
            &json!({"collection":"resolvers"})
        ));
        assert!(settings_changed("connector_save", &json!({})));
        assert!(settings_changed("connector_remove", &json!({})));
        assert!(settings_changed(
            "settings_save",
            &json!({"settings":{"watchedFolders":[]}})
        ));
        assert!(!settings_changed(
            "config_save",
            &json!({"collection":"recipes"})
        ));
        assert!(!settings_changed(
            "settings_save",
            &json!({"settings":{"notifyEveryNote":false}})
        ));
    }

    #[test]
    fn los_problemas_automaticos_se_avisan_tambien_en_reintentos_con_el_exito_desactivado() {
        let job = json!({"operation":"processRecording","automatic":true,"recordingId":"nota","attempt":3});
        for (error, title, body) in [
            (
                AppError::new(ErrorCode::BackendUnavailable, "Sin conexión"),
                "El motor de transcripción no responde",
                "Sin conexión",
            ),
            (
                AppError::new(ErrorCode::RecipeUnavailable, "Falta el paquete"),
                "La receta por defecto no está disponible",
                "Falta el paquete",
            ),
            (
                AppError::new(ErrorCode::Failed, "Audio ilegible"),
                "Fallo al transcribir nota",
                "Audio ilegible",
            ),
        ] {
            let notice = finished(
                &job,
                &json!({}),
                Err(&error),
                &json!({"notifyEveryNote":false}),
            )
            .unwrap();
            assert_eq!(notice.title, title);
            assert_eq!(notice.body, body);
            assert!(notice.sound);
        }
    }

    #[test]
    fn no_avisa_de_operaciones_manuales_pruebas_cancelaciones_ni_esperas() {
        let recording = json!({"versions":[{"id":"v1","transcript":{"text":"Hola"}}]});
        for job in [
            json!({"operation":"processRecording","automatic":false,"attempt":2}),
            json!({"operation":"processRecording","automatic":true,"args":{"options":{"dryRun":true}}}),
            json!({"operation":"summarizeRecording","automatic":true}),
            json!({"operation":"publishRecording","automatic":true}),
        ] {
            assert!(finished(
                &job,
                &recording,
                Ok(&json!({"versionId":"v1"})),
                &json!({"notifyEveryNote":true})
            )
            .is_none());
            assert!(finished(
                &job,
                &recording,
                Err(&AppError::new(
                    ErrorCode::BackendUnavailable,
                    "Sin conexión"
                )),
                &json!({"notifyEveryNote":false})
            )
            .is_none());
        }
        let automatic = json!({"operation":"processRecording","automatic":true});
        assert!(finished(
            &automatic,
            &recording,
            Err(&AppError::new(ErrorCode::Failed, "Proceso cancelado")),
            &json!({"notifyEveryNote":true})
        )
        .is_none());
    }

    #[test]
    fn una_instalacion_nueva_notifica_igual_que_el_ajuste_activado_por_defecto() {
        let job = json!({"operation":"processRecording","automatic":true,"recordingId":"nota"});
        let recording = json!({"versions":[{"id":"v1","transcript":{"text":"Hola"}}]});
        let notice =
            finished(&job, &recording, Ok(&json!({"versionId":"v1"})), &json!({})).unwrap();
        assert_eq!(notice.body, "Hola");
        assert!(finished(
            &job,
            &recording,
            Ok(&json!({"versionId":"v1"})),
            &json!({"notifyEveryNote":false})
        )
        .is_none());
    }

    #[test]
    fn avisa_de_la_version_procesada_aunque_cambie_la_seleccion() {
        let job = json!({"operation":"processRecording","automatic":true,"recordingId":"nota"});
        let recording = json!({"id":"nota","currentVersionId":"v2","versions":[
            {"id":"v1","transcript":{"text":"Hola\nAna"}},
            {"id":"v2","transcript":{"text":"Otra versión"}}
        ]});
        let notice = finished(
            &job,
            &recording,
            Ok(&json!({"versionId":"v1"})),
            &json!({"notifyEveryNote":true}),
        )
        .unwrap();
        assert_eq!(notice.title, "Nota transcrita");
        assert_eq!(notice.body, "Hola Ana");
        assert!(!notice.sound);
    }
}
