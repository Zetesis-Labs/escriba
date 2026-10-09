use unicode_segmentation::UnicodeSegmentation;

pub struct Notification {
    pub title: String,
    pub body: String,
    pub sound: bool,
}

pub enum Problem<'a> {
    Failed { key: &'a str, reason: &'a str },
    BackendUnavailable(&'a str),
    RecipeUnavailable(&'a str),
    ScanFailed(&'a str),
    FolderInaccessible(&'a str),
    TranscriberUnavailable { name: &'a str, reason: &'a str },
    SummarizerUnavailable { name: &'a str, reason: &'a str },
    RecipesUnavailable(&'a str),
    StartupFailed(&'a str),
    AlreadyOpen(&'a str),
}

pub fn transcribed(key: &str, text: &str, enabled: bool) -> Option<Notification> {
    if !enabled {
        return None;
    }
    let flat = text.replace('\n', " ");
    let preview = flat.trim();
    let body = if preview.is_empty() {
        key.to_owned()
    } else {
        let mut short = preview.graphemes(true).take(80).collect::<String>();
        if preview.graphemes(true).count() > 80 {
            short.push('…');
        }
        short
    };
    Some(Notification {
        title: "Nota transcrita".into(),
        body: limit_body(&body),
        sound: false,
    })
}

fn limit_body(body: &str) -> String {
    body.graphemes(true).take(240).collect()
}

pub fn notification(problem: Problem<'_>) -> Notification {
    let (title, body) = match problem {
        Problem::Failed { key, reason } => {
            (format!("Fallo al transcribir {key}"), reason.to_owned())
        }
        Problem::BackendUnavailable(reason) => (
            "El motor de transcripción no responde".into(),
            reason.into(),
        ),
        Problem::RecipeUnavailable(reason) => (
            "La receta por defecto no está disponible".into(),
            reason.into(),
        ),
        Problem::ScanFailed(reason) => ("No puedo leer las grabaciones".into(), reason.into()),
        Problem::FolderInaccessible(path) => ("Carpeta vigilada inaccesible".into(), path.into()),
        Problem::TranscriberUnavailable { name, reason } => {
            (format!("No se puede transcribir con {name}"), reason.into())
        }
        Problem::SummarizerUnavailable { name, reason } => (
            format!("No se puede resumir con {name}"),
            format!("{reason}. Las notas se transcribirán igual."),
        ),
        Problem::RecipesUnavailable(reason) => ("Las recetas no arrancan".into(), reason.into()),
        Problem::StartupFailed(reason) => ("No se pudo arrancar".into(), reason.into()),
        Problem::AlreadyOpen(holder) => (
            "Escriba ya está abierto".into(),
            format!("Hay {holder} vigilando. Esta copia no hará nada."),
        ),
    };
    Notification {
        title,
        body: limit_body(&body),
        sound: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcripcion_recorta_ochenta_grafemas_y_no_suena() {
        let prefix = "e\u{301}".repeat(80);
        let result = transcribed("clave", &format!("{prefix}Z"), true).unwrap();
        assert_eq!(result.title, "Nota transcrita");
        assert_eq!(result.body, format!("{prefix}…"));
        assert!(!result.sound);
    }

    #[test]
    fn fallo_al_transcribir_muestra_clave_y_motivo_con_sonido() {
        let result = notification(Problem::Failed {
            key: "nota-7",
            reason: "El audio no se pudo abrir",
        });
        assert_eq!(result.title, "Fallo al transcribir nota-7");
        assert_eq!(result.body, "El audio no se pudo abrir");
        assert!(result.sound);
    }

    #[test]
    fn problemas_usan_los_titulos_y_cuerpos_de_swift() {
        let cases = [
            (
                Problem::BackendUnavailable("Motor caído"),
                "El motor de transcripción no responde",
                "Motor caído",
            ),
            (
                Problem::RecipeUnavailable("Falta el paquete"),
                "La receta por defecto no está disponible",
                "Falta el paquete",
            ),
            (
                Problem::ScanFailed("Sin acceso"),
                "No puedo leer las grabaciones",
                "Sin acceso",
            ),
            (
                Problem::FolderInaccessible("/carpeta/prueba"),
                "Carpeta vigilada inaccesible",
                "/carpeta/prueba",
            ),
            (
                Problem::TranscriberUnavailable {
                    name: "Whisper",
                    reason: "Sin modelo",
                },
                "No se puede transcribir con Whisper",
                "Sin modelo",
            ),
            (
                Problem::SummarizerUnavailable {
                    name: "Apple",
                    reason: "Sin modelo",
                },
                "No se puede resumir con Apple",
                "Sin modelo. Las notas se transcribirán igual.",
            ),
            (
                Problem::RecipesUnavailable("Motor detenido"),
                "Las recetas no arrancan",
                "Motor detenido",
            ),
            (
                Problem::StartupFailed("Base ilegible"),
                "No se pudo arrancar",
                "Base ilegible",
            ),
            (
                Problem::AlreadyOpen("otra copia"),
                "Escriba ya está abierto",
                "Hay otra copia vigilando. Esta copia no hará nada.",
            ),
        ];
        for (problem, title, body) in cases {
            let result = notification(problem);
            assert_eq!(result.title, title);
            assert_eq!(result.body, body);
            assert!(result.sound);
        }
    }

    #[test]
    fn aviso_opcional_sin_texto_usa_clave_y_aplana_saltos() {
        assert!(transcribed("clave", "texto", false).is_none());
        let empty = transcribed("clave", " \n ", true).unwrap();
        assert_eq!(empty.body, "clave");
        let single_line = transcribed("clave", "  primera\nsegunda  ", true).unwrap();
        assert_eq!(single_line.body, "primera segunda");
        let exact = "a".repeat(80);
        assert_eq!(transcribed("clave", &exact, true).unwrap().body, exact);
    }

    #[test]
    fn el_cuerpo_de_todo_aviso_se_limita_a_doscientos_cuarenta_grafemas() {
        let prefix = "e\u{301}".repeat(240);
        let problem = notification(Problem::StartupFailed(&format!("{prefix}Z")));
        assert_eq!(problem.body, prefix);
        let success = transcribed(&format!("{prefix}Z"), "", true).unwrap();
        assert_eq!(success.body, prefix);
    }
}
