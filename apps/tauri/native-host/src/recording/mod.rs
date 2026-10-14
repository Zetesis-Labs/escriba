//! One recording at a time, captured and encoded on its own thread because
//! audio streams cannot move between threads.

mod opus_ogg;
mod source;

use crate::protocol::{required_string, Failure, Params};
use opus_ogg::OpusOgg;
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{channel, RecvTimeoutError, Sender, TryRecvError},
        Arc,
    },
    thread::JoinHandle,
    time::Duration,
};

enum Control {
    Stop,
    Cancel,
}

#[derive(Default)]
struct Shared {
    paused: AtomicBool,
    ended: AtomicBool,
    duration: AtomicU64,
    level: AtomicU64,
}

impl Shared {
    fn load(value: &AtomicU64) -> f64 {
        f64::from_bits(value.load(Ordering::SeqCst))
    }
}

struct Recording {
    path: PathBuf,
    control: Sender<Control>,
    shared: Arc<Shared>,
    thread: Option<JoinHandle<Result<f64, String>>>,
}

#[derive(Default)]
pub struct Recorder {
    current: Option<Recording>,
}

/// Mean level in dB mapped like the macOS meter: -60 dB is 0 and 0 dB is 1.
fn meter(samples: &[f32]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let power = samples.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() / samples.len() as f64;
    let decibels = 10.0 * power.log10();
    if decibels.is_finite() {
        ((decibels + 60.0) / 60.0).clamp(0.0, 1.0)
    } else {
        0.0
    }
}

fn record(
    capture: source::Capture,
    mut writer: OpusOgg,
    path: &Path,
    control: std::sync::mpsc::Receiver<Control>,
    shared: &Shared,
) -> Result<f64, String> {
    loop {
        match control.try_recv() {
            Ok(Control::Stop) | Err(TryRecvError::Disconnected) => {
                return writer.finish().map_err(|error| error.to_string())
            }
            Ok(Control::Cancel) => {
                drop(writer);
                let _ = std::fs::remove_file(path);
                return Ok(0.0);
            }
            Err(TryRecvError::Empty) => {}
        }
        match capture.chunks.recv_timeout(Duration::from_millis(20)) {
            Ok(chunk) if shared.paused.load(Ordering::SeqCst) => drop(chunk),
            Ok(chunk) => {
                shared
                    .level
                    .store(meter(&chunk).to_bits(), Ordering::SeqCst);
                writer.push(&chunk).map_err(|error| error.to_string())?;
                shared
                    .duration
                    .store(writer.duration().to_bits(), Ordering::SeqCst);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                shared.ended.store(true, Ordering::SeqCst);
                return writer.finish().map_err(|error| error.to_string());
            }
        }
    }
}

impl Recorder {
    fn active(&mut self) -> Option<&Recording> {
        if self
            .current
            .as_ref()
            .is_some_and(|recording| recording.shared.ended.load(Ordering::SeqCst))
        {
            self.finish();
        }
        self.current.as_ref()
    }

    fn finish(&mut self) -> Option<(PathBuf, Result<f64, String>)> {
        let mut recording = self.current.take()?;
        let outcome = recording
            .thread
            .take()
            .map(|thread| {
                thread
                    .join()
                    .unwrap_or_else(|_| Err("la grabación se interrumpió".into()))
            })
            .unwrap_or(Ok(0.0));
        Some((recording.path.clone(), outcome))
    }

    pub fn start(&mut self, params: &Params) -> Result<Value, Failure> {
        if self.active().is_some() {
            return Err(Failure::new(
                "recording_active",
                "ya hay una grabación en curso",
            ));
        }
        let path = PathBuf::from(required_string(params, "outputPath")?);
        if path.exists() {
            return Err(Failure::new(
                "file_exists",
                "el fichero de salida ya existe",
            ));
        }
        let (ready, started) = channel();
        let (control, orders) = channel();
        let shared = Arc::new(Shared::default());
        let thread = {
            let (path, shared) = (path.clone(), shared.clone());
            std::thread::Builder::new()
                .name("grabación".into())
                .spawn(move || {
                    let opened = source::open().and_then(|capture| {
                        if let Some(parent) = path.parent() {
                            std::fs::create_dir_all(parent).map_err(|error| {
                                Failure::new("recording_failed", error.to_string())
                            })?;
                        }
                        let writer = OpusOgg::create(&path, capture.rate)
                            .map_err(|error| Failure::new("recording_failed", error.to_string()))?;
                        Ok((capture, writer))
                    });
                    match opened {
                        Ok((capture, writer)) => {
                            let _ = ready.send(Ok(()));
                            record(capture, writer, &path, orders, &shared)
                        }
                        Err(failure) => {
                            let _ = ready.send(Err(failure));
                            Ok(0.0)
                        }
                    }
                })
                .map_err(|error| Failure::new("recording_failed", error.to_string()))?
        };
        started
            .recv()
            .map_err(|_| Failure::new("recording_failed", "la grabación no arrancó"))??;
        self.current = Some(Recording {
            path: path.clone(),
            control,
            shared,
            thread: Some(thread),
        });
        Ok(json!({"audioPath": path}))
    }

    pub fn status(&mut self) -> Value {
        match self.active() {
            Some(recording) => {
                let paused = recording.shared.paused.load(Ordering::SeqCst);
                json!({
                    "active": true,
                    "paused": paused,
                    "audioPath": recording.path,
                    "duration": Shared::load(&recording.shared.duration),
                    "level": if paused { 0.0 } else { Shared::load(&recording.shared.level) },
                })
            }
            None => {
                json!({"active": false, "paused": false, "audioPath": null, "duration": 0, "level": 0})
            }
        }
    }

    fn required(&mut self) -> Result<&Recording, Failure> {
        self.active()
            .ok_or_else(|| Failure::new("recording_inactive", "no hay ninguna grabación activa"))
    }

    pub fn pause(&mut self, paused: bool) -> Result<Value, Failure> {
        let recording = self.required()?;
        if recording.shared.paused.swap(paused, Ordering::SeqCst) == paused {
            return Err(if paused {
                Failure::new("recording_paused", "la grabación ya está en pausa")
            } else {
                Failure::new("recording_active", "la grabación no está en pausa")
            });
        }
        Ok(json!({
            "audioPath": recording.path,
            "duration": Shared::load(&recording.shared.duration),
        }))
    }

    pub fn stop(&mut self) -> Result<Value, Failure> {
        self.required()?.control.send(Control::Stop).ok();
        let (path, outcome) = self.finish().expect("grabación activa");
        let duration = outcome.map_err(|error| Failure::new("recording_failed", error))?;
        Ok(json!({"audioPath": path, "duration": duration}))
    }

    pub fn cancel(&mut self) -> Result<Value, Failure> {
        self.required()?.control.send(Control::Cancel).ok();
        self.finish();
        Ok(json!({}))
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        if let Some(recording) = &self.current {
            let _ = recording.control.send(Control::Stop);
        }
        self.finish();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn el_nivel_va_de_menos_60_db_a_0_db_como_en_el_mac() {
        assert_eq!(meter(&[]), 0.0);
        assert_eq!(meter(&[0.0; 10]), 0.0);
        assert!((meter(&[1.0; 10]) - 1.0).abs() < 1e-9);
        assert!(meter(&[0.001; 10]) < 1e-6);
        assert!((meter(&[0.031_622_8; 10]) - 0.5).abs() < 1e-3);
    }
}
