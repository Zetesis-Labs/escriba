use unicode_segmentation::UnicodeSegmentation;

pub struct Notification {
    pub title: String,
    pub body: String,
    pub sound: bool,
}

pub enum Problem<'a> {
    Failed { key: &'a str, reason: &'a str },
    ScanFailed(&'a str),
    FolderInaccessible(&'a str),
    StartupFailed(&'a str),
    AlreadyOpen(&'a str),
}

pub fn notification(problem: Problem<'_>) -> Notification {
    let (title, body) = match problem {
        Problem::Failed { key, reason } => {
            (format!("Fallo al transcribir {key}"), reason.to_owned())
        }
        Problem::ScanFailed(reason) => ("No puedo leer las grabaciones".into(), reason.into()),
        Problem::FolderInaccessible(path) => ("Carpeta vigilada inaccesible".into(), path.into()),
        Problem::StartupFailed(reason) => ("No se pudo arrancar".into(), reason.into()),
        Problem::AlreadyOpen(holder) => (
            "Escriba ya está abierto".into(),
            format!("Hay {holder} vigilando. Esta copia no hará nada."),
        ),
    };
    Notification {
        title,
        body: body.graphemes(true).take(240).collect(),
        sound: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aviso_de_audio_abandonado_muestra_clave_y_motivo_con_sonido() {
        let result = notification(Problem::Failed {
            key: "nota-7",
            reason: "El audio está vacío",
        });
        assert_eq!(result.title, "Fallo al transcribir nota-7");
        assert_eq!(result.body, "El audio está vacío");
        assert!(result.sound);
    }

    #[test]
    fn avisos_de_la_cascara_conservan_sus_titulos_y_cuerpos() {
        let cases = [
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
    fn el_cuerpo_del_aviso_se_limita_a_doscientos_cuarenta_grafemas() {
        let prefix = "e\u{301}".repeat(240);
        let problem = notification(Problem::StartupFailed(&format!("{prefix}Z")));
        assert_eq!(problem.body, prefix);
    }
}
