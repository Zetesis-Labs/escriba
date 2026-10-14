//! Where the recorder gets audio: the default microphone, or the source that
//! ESCRIBA_AUDIO_SOURCE injects for tests (a WAV played in real time, or
//! `none` to behave as a computer without a microphone).

use super::opus_ogg::RATES;
use crate::protocol::Failure;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::{
    path::Path,
    sync::mpsc::{sync_channel, Receiver, SyncSender},
    time::Duration,
};

/// Mono chunks at `rate`. The stream must stay alive while recording.
pub struct Capture {
    pub rate: u32,
    pub chunks: Receiver<Vec<f32>>,
    _stream: Option<cpal::Stream>,
}

const NO_MICROPHONE: &str = "no hay ningún micrófono disponible";

pub fn open() -> Result<Capture, Failure> {
    match std::env::var_os("ESCRIBA_AUDIO_SOURCE") {
        Some(source) if source == "none" => Err(Failure::new("recording_failed", NO_MICROPHONE)),
        Some(source) => file(Path::new(&source)),
        None => microphone(),
    }
}

fn mono(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

fn file(path: &Path) -> Result<Capture, Failure> {
    let (from, samples) = crate::audio::decode_mono(path)?;
    let rate = 48_000;
    let samples = crate::audio::resample(samples, from, rate)?;
    let (sender, chunks) = sync_channel(64);
    std::thread::spawn(move || {
        let step = rate as usize / 50;
        let mut position = 0;
        loop {
            let end = (position + step).min(samples.len());
            let mut chunk = samples[position.min(end)..end].to_vec();
            chunk.resize(step, 0.0);
            position = end;
            if sender.send(chunk).is_err() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    });
    Ok(Capture {
        rate,
        chunks,
        _stream: None,
    })
}

fn denied(message: &str) -> bool {
    message.contains("Permission denied") || message.contains("EACCES")
}

fn microphone() -> Result<Capture, Failure> {
    let device = cpal::default_host()
        .default_input_device()
        .ok_or_else(|| Failure::new("recording_failed", NO_MICROPHONE))?;
    let unusable = |error: &dyn std::fmt::Display| {
        let message = error.to_string();
        if denied(&message) {
            Failure::new("microphone_denied", "sin permiso para usar el micrófono")
        } else {
            Failure::new(
                "recording_failed",
                format!("el micrófono no empezó a grabar: {message}"),
            )
        }
    };
    let configs: Vec<_> = device
        .supported_input_configs()
        .map_err(|error| unusable(&error))?
        .collect();
    let (range, rate) = RATES
        .iter()
        .rev()
        .find_map(|&rate| {
            configs
                .iter()
                .find(|range| {
                    range.min_sample_rate().0 <= rate
                        && rate <= range.max_sample_rate().0
                        && matches!(
                            range.sample_format(),
                            cpal::SampleFormat::F32 | cpal::SampleFormat::I16
                        )
                })
                .map(|range| (*range, rate))
        })
        .ok_or_else(|| {
            Failure::new(
                "recording_failed",
                "el micrófono no admite ninguna frecuencia de Opus",
            )
        })?;
    let config = range.with_sample_rate(cpal::SampleRate(rate));
    let channels = config.channels() as usize;
    let format = config.sample_format();
    let (sender, chunks) = sync_channel::<Vec<f32>>(256);
    let report =
        |error: cpal::StreamError| eprintln!("EscribaNativeHost: el micrófono falló: {error}");
    let stream = match format {
        cpal::SampleFormat::I16 => {
            let sender: SyncSender<Vec<f32>> = sender;
            device.build_input_stream(
                &config.config(),
                move |data: &[i16], _: &cpal::InputCallbackInfo| {
                    let floats: Vec<f32> =
                        data.iter().map(|&s| s as f32 / i16::MAX as f32).collect();
                    let _ = sender.try_send(mono(&floats, channels));
                },
                report,
                None,
            )
        }
        _ => device.build_input_stream(
            &config.config(),
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                let _ = sender.try_send(mono(data, channels));
            },
            report,
            None,
        ),
    }
    .map_err(|error| unusable(&error))?;
    stream.play().map_err(|error| unusable(&error))?;
    Ok(Capture {
        rate,
        chunks,
        _stream: Some(stream),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn el_estereo_se_mezcla_a_mono() {
        assert_eq!(mono(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
        assert_eq!(mono(&[0.25, 0.75], 1), vec![0.25, 0.75]);
    }

    #[test]
    fn un_permiso_denegado_se_reconoce_en_el_error_del_sistema() {
        assert!(denied(
            "ALSA function 'snd_pcm_open' failed with error 'Permission denied (13)'"
        ));
        assert!(!denied("Device or resource busy"));
    }
}
