use crate::protocol::{required_string, Failure, Params};
use serde_json::{json, Value};
use std::{fs::File, path::Path};
use symphonia::core::{
    audio::SampleBuffer,
    codecs::{DecoderOptions, CODEC_TYPE_MP3},
    formats::FormatOptions,
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
    units::TimeBase,
};

pub fn info(params: &Params) -> Result<Value, Failure> {
    let path = Path::new(required_string(params, "audioPath")?);
    if !path.is_file() {
        return Err(Failure::new(
            "audio_missing",
            format!("no existe el fichero de audio: {}", path.display()),
        ));
    }
    Ok(json!({"duration": duration(path)?}))
}

fn invalid(error: impl std::fmt::Display) -> Failure {
    Failure::new(
        "invalid_audio",
        format!("no se pudo leer el audio: {error}"),
    )
}

pub(crate) fn duration(path: &Path) -> Result<f64, Failure> {
    let file = File::open(path).map_err(invalid)?;
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(extension);
    }
    let probed = symphonia::default::get_probe()
        .format(
            &hint,
            MediaSourceStream::new(Box::new(file), Default::default()),
            &FormatOptions {
                enable_gapless: true,
                ..Default::default()
            },
            &MetadataOptions::default(),
        )
        .map_err(invalid)?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| invalid("no tiene pistas"))?;
    let track_id = track.id;
    let params = track.codec_params.clone();
    let time_base = params
        .time_base
        .or_else(|| params.sample_rate.map(|rate| TimeBase::new(1, rate)))
        .ok_or_else(|| invalid("sin frecuencia válida"))?;
    // An mp3 without a Xing header only has a bitrate estimate; others may not know.
    let declared = params.n_frames.filter(|_| params.codec != CODEC_TYPE_MP3);
    let frames = match declared {
        Some(frames) => frames,
        None => {
            let mut end = 0;
            while let Ok(packet) = format.next_packet() {
                if packet.track_id() == track_id {
                    end = end.max(packet.ts() + packet.dur());
                }
            }
            end
        }
    };
    let time = time_base.calc_time(frames);
    let seconds = time.seconds as f64 + time.frac;
    if seconds > 0.0 {
        Ok(seconds)
    } else {
        Err(invalid("duración nula"))
    }
}

/// Decodes a whole file to mono samples; the recorder plays it as a test microphone.
pub(crate) fn decode_mono(path: &Path) -> Result<(u32, Vec<f32>), Failure> {
    let file = File::open(path).map_err(invalid)?;
    let probed = symphonia::default::get_probe()
        .format(
            &Hint::new(),
            MediaSourceStream::new(Box::new(file), Default::default()),
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .map_err(invalid)?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| invalid("no tiene pistas"))?;
    let track_id = track.id;
    let rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| invalid("sin frecuencia válida"))?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(invalid)?;
    let mut samples = Vec::new();
    while let Ok(packet) = format.next_packet() {
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = decoder.decode(&packet).map_err(invalid)?;
        let channels = decoded.spec().channels.count().max(1);
        let mut buffer = SampleBuffer::<f32>::new(decoded.capacity() as u64, *decoded.spec());
        buffer.copy_interleaved_ref(decoded);
        samples.extend(
            buffer
                .samples()
                .chunks(channels)
                .map(|frame| frame.iter().sum::<f32>() / channels as f32),
        );
    }
    Ok((rate, samples))
}

/// Ogg Opus, as Escriba records on Linux; symphonia has no Opus decoder.
fn decode_opus(path: &Path) -> Result<(u32, Vec<f32>), Failure> {
    let mut packets = ogg::reading::PacketReader::new(File::open(path).map_err(invalid)?);
    let head = packets
        .read_packet()
        .map_err(invalid)?
        .filter(|packet| packet.data.starts_with(b"OpusHead") && packet.data.len() >= 19)
        .ok_or_else(|| invalid("no es Ogg Opus"))?;
    let pre_skip = u16::from_le_bytes([head.data[10], head.data[11]]) as usize;
    let mut decoder = opus::Decoder::new(48_000, opus::Channels::Mono).map_err(invalid)?;
    let mut samples = Vec::new();
    let mut frame = vec![0f32; 5760];
    let mut last_granule = 0;
    while let Some(packet) = packets.read_packet().map_err(invalid)? {
        if packet.data.starts_with(b"OpusTags") {
            continue;
        }
        let decoded = decoder
            .decode_float(&packet.data, &mut frame, false)
            .map_err(invalid)?;
        samples.extend_from_slice(&frame[..decoded]);
        last_granule = packet.absgp_page();
    }
    let real = (last_granule as usize).saturating_sub(pre_skip);
    let mut samples = samples.split_off(pre_skip.min(samples.len()));
    samples.truncate(real);
    Ok((48_000, samples))
}

pub(crate) fn resample(samples: Vec<f32>, from: u32, to: u32) -> Result<Vec<f32>, Failure> {
    use rubato::{FftFixedIn, Resampler};
    if from == to || samples.is_empty() {
        return Ok(samples);
    }
    let chunk = 1024;
    let mut resampler =
        FftFixedIn::<f32>::new(from as usize, to as usize, chunk, 2, 1).map_err(invalid)?;
    let expected = (samples.len() as u64 * to as u64 / from as u64) as usize;
    let delay = resampler.output_delay();
    // Silence after the end flushes the filter; whole chunks keep the API simple.
    let mut padded = samples;
    let needed = padded.len() + (delay + 1) * from as usize / to as usize + chunk;
    padded.resize(needed.div_ceil(chunk) * chunk, 0.0);
    let mut output = Vec::with_capacity(padded.len() * to as usize / from as usize + chunk);
    for block in padded.chunks_exact(chunk) {
        output.extend_from_slice(&resampler.process(&[block], None).map_err(invalid)?[0]);
    }
    Ok(output[delay..delay + expected].to_vec())
}

/// Mono samples at 16 kHz, the input whisper.cpp expects.
pub(crate) fn decode_16k(path: &Path) -> Result<Vec<f32>, Failure> {
    let (rate, samples) = match decode_mono(path) {
        Ok(decoded) => decoded,
        Err(failure) => decode_opus(path).map_err(|_| failure)?,
    };
    resample(samples, rate, 16_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    #[test]
    fn cada_formato_se_decodifica_a_16_khz_con_su_duracion() {
        for name in ["tono.wav", "tono.flac", "tono.m4a", "tono.mp3", "tono.ogg"] {
            let samples = decode_16k(&fixture(name)).unwrap();
            let seconds = samples.len() as f64 / 16_000.0;
            assert!((0.9..1.1).contains(&seconds), "{name}: {seconds}");
            let peak = samples
                .iter()
                .fold(0f32, |peak, sample| peak.max(sample.abs()));
            assert!(peak > 0.2, "{name}: {peak}");
        }
    }

    #[test]
    fn remuestrear_conserva_la_duracion() {
        let tone: Vec<f32> = (0..48_000).map(|i| (i as f32 * 0.05).sin()).collect();
        assert_eq!(resample(tone, 48_000, 16_000).unwrap().len(), 16_000);
    }
}
