use crate::protocol::{required_string, Failure, Params};
use serde_json::{json, Value};
use std::{fs::File, path::Path};
use symphonia::core::{
    codecs::CODEC_TYPE_MP3, formats::FormatOptions, io::MediaSourceStream, meta::MetadataOptions,
    probe::Hint, units::TimeBase,
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

fn duration(path: &Path) -> Result<f64, Failure> {
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
