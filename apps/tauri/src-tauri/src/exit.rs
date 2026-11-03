use std::future::Future;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

const RUNNING: u8 = 0;
const CLOSING: u8 = 1;
const CLOSED: u8 = 2;

#[derive(Debug, PartialEq, Eq)]
pub enum ExitStep {
    Allow,
    Hold,
    HoldAndClose,
}

#[derive(Default)]
pub struct ExitGate(AtomicU8);

impl ExitGate {
    pub fn request(&self) -> ExitStep {
        match self
            .0
            .compare_exchange(RUNNING, CLOSING, Ordering::SeqCst, Ordering::SeqCst)
        {
            Ok(_) => ExitStep::HoldAndClose,
            Err(CLOSED) => ExitStep::Allow,
            Err(_) => ExitStep::Hold,
        }
    }

    pub fn closed(&self) {
        self.0.store(CLOSED, Ordering::SeqCst);
    }
}

pub fn wait_at_most<F>(future: F, limit: Duration) -> bool
where
    F: Future<Output = ()> + Send + 'static,
{
    let (done, finished) = std::sync::mpsc::channel();
    tauri::async_runtime::spawn(async move {
        future.await;
        let _ = done.send(());
    });
    finished.recv_timeout(limit).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn la_primera_peticion_de_salida_retiene_y_cierra_y_las_demas_esperan() {
        let gate = ExitGate::default();
        assert_eq!(gate.request(), ExitStep::HoldAndClose);
        assert_eq!(gate.request(), ExitStep::Hold);
        assert_eq!(gate.request(), ExitStep::Hold);
    }

    #[test]
    fn tras_cerrar_el_controlador_la_salida_se_permite() {
        let gate = ExitGate::default();
        assert_eq!(gate.request(), ExitStep::HoldAndClose);
        gate.closed();
        assert_eq!(gate.request(), ExitStep::Allow);
    }

    #[test]
    fn un_cierre_que_nunca_termina_no_retiene_la_salida_mas_alla_del_limite() {
        let started = Instant::now();
        assert!(!wait_at_most(
            std::future::pending::<()>(),
            Duration::from_millis(100)
        ));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn un_cierre_que_termina_se_espera() {
        assert!(wait_at_most(
            async { tokio::time::sleep(Duration::from_millis(20)).await },
            Duration::from_secs(5)
        ));
    }
}
