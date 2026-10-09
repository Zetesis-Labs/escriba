use chrono::{DateTime, Datelike, Local, Timelike, Utc};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::path::PathBuf;

pub const LEVEL_HISTORY: usize = 48;
pub const MICROPHONE_DENIED: &str = "Escriba no tiene permiso para usar el micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono.";

pub struct Session {
    pub path: PathBuf,
    pub recipe_id: Option<String>,
    pub recipe_name: Option<String>,
    pub started_at: DateTime<Utc>,
    pub elapsed: f64,
    pub levels: VecDeque<f64>,
}

impl Session {
    pub fn new(path: PathBuf, recipe_id: Option<String>, recipe_name: Option<String>) -> Self {
        Self {
            path,
            recipe_id,
            recipe_name,
            started_at: Utc::now(),
            elapsed: 0.0,
            levels: VecDeque::with_capacity(LEVEL_HISTORY),
        }
    }

    pub fn sample(&mut self, elapsed: f64, level: f64) {
        self.elapsed = elapsed;
        if self.levels.len() == LEVEL_HISTORY {
            self.levels.pop_front();
        }
        self.levels.push_back(level.clamp(0.0, 1.0));
    }

    pub fn clock(&self) -> String {
        duration_clock(self.elapsed)
    }
}

pub fn view(session: Option<&Session>, problem: Option<&Problem>) -> Value {
    let problem = problem.map(|p| json!({"message":p.message,"denied":p.denied}));
    match session {
        Some(session) => json!({
            "active": true,
            "clock": session.clock(),
            "recipeName": session.recipe_name,
            "levels": session.levels,
            "problem": problem,
        }),
        None => {
            json!({"active": false, "clock": duration_clock(0.0), "recipeName": null, "levels": [], "problem": problem})
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Problem {
    pub message: String,
    pub denied: bool,
}

impl Problem {
    pub fn starting(error: &str) -> Self {
        if error.starts_with("MICROPHONE_DENIED:") {
            Self {
                message: MICROPHONE_DENIED.into(),
                denied: true,
            }
        } else {
            Self {
                message: format!("No se pudo empezar a grabar: {error}"),
                denied: false,
            }
        }
    }

    pub fn saving(error: &str) -> Self {
        Self {
            message: format!("No se pudo guardar la grabación: {error}"),
            denied: false,
        }
    }
}

pub fn duration_clock(seconds: f64) -> String {
    let total = if seconds.is_finite() {
        seconds.max(0.0).floor() as u64
    } else {
        0
    };
    let body = format!("{:02}:{:02}", (total % 3600) / 60, total % 60);
    if total >= 3600 {
        format!("{}:{body}", total / 3600)
    } else {
        body
    }
}

pub fn recording_name(started: DateTime<Local>) -> String {
    format!(
        "Grabación {:04}-{:02}-{:02} {:02}.{:02}.{:02}.m4a",
        started.year(),
        started.month(),
        started.day(),
        started.hour(),
        started.minute(),
        started.second()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn el_reloj_cuenta_minutos_y_horas_como_en_swift() {
        assert_eq!(duration_clock(0.0), "00:00");
        assert_eq!(duration_clock(59.9), "00:59");
        assert_eq!(duration_clock(61.0), "01:01");
        assert_eq!(duration_clock(3600.0), "1:00:00");
        assert_eq!(duration_clock(3725.0), "1:02:05");
        assert_eq!(duration_clock(-5.0), "00:00");
        assert_eq!(duration_clock(f64::NAN), "00:00");
    }

    #[test]
    fn la_grabacion_se_llama_por_su_hora_de_inicio() {
        let started = Local.with_ymd_and_hms(2026, 10, 9, 7, 5, 3).unwrap();
        assert_eq!(recording_name(started), "Grabación 2026-10-09 07.05.03.m4a");
    }

    #[test]
    fn la_forma_de_onda_guarda_los_ultimos_48_niveles() {
        let mut session = Session::new(PathBuf::from("/tmp/x.m4a"), None, None);
        for index in 0..60 {
            session.sample(index as f64, index as f64 / 100.0);
        }
        assert_eq!(session.levels.len(), LEVEL_HISTORY);
        assert_eq!(session.levels.front(), Some(&0.12));
        assert_eq!(session.levels.back(), Some(&0.59));
        session.sample(61.0, 7.0);
        assert_eq!(session.levels.back(), Some(&1.0));
        assert_eq!(session.clock(), "01:01");
    }

    #[test]
    fn sin_permiso_de_microfono_se_explica_como_en_swift() {
        let denied = Problem::starting("MICROPHONE_DENIED: sin permiso para usar el micrófono");
        assert!(denied.denied);
        assert_eq!(denied.message, MICROPHONE_DENIED);
        let failed = Problem::starting("el micrófono no empezó a grabar");
        assert!(!failed.denied);
        assert_eq!(
            failed.message,
            "No se pudo empezar a grabar: el micrófono no empezó a grabar"
        );
    }

    #[test]
    fn la_vista_dice_si_se_graba_con_que_receta_y_el_reloj() {
        let mut session = Session::new(
            PathBuf::from("/tmp/x.m4a"),
            Some("r1".into()),
            Some("Reuniones".into()),
        );
        session.sample(65.0, 0.5);
        let value = view(Some(&session), None);
        assert_eq!(value["active"], true);
        assert_eq!(value["clock"], "01:05");
        assert_eq!(value["recipeName"], "Reuniones");
        assert_eq!(value["levels"], json!([0.5]));
        assert_eq!(view(None, None)["active"], false);
    }
}
