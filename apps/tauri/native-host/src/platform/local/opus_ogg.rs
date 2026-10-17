//! Mono Opus in an Ogg container (RFC 7845), written as it is recorded.

use ogg::writing::{PacketWriteEndInfo, PacketWriter};
use std::{fs::File, io, path::Path};

/// Granule positions are always counted at 48 kHz, whatever the encoder rate.
const GRANULE_RATE: u64 = 48_000;
const PACKETS_PER_PAGE: u32 = 50;
const SERIAL: u32 = 0x4573_6372;

pub const RATES: [u32; 5] = [8_000, 12_000, 16_000, 24_000, 48_000];

pub struct OpusOgg {
    writer: PacketWriter<'static, File>,
    encoder: opus::Encoder,
    rate: u32,
    frame: usize,
    pending: Vec<f32>,
    pre_skip: u64,
    encoded: u64,
    pushed: u64,
    packets: u32,
}

fn failure(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}

impl OpusOgg {
    pub fn create(path: &Path, rate: u32) -> io::Result<Self> {
        if !RATES.contains(&rate) {
            return Err(failure(format!("Opus no admite {rate} Hz")));
        }
        let mut encoder = opus::Encoder::new(rate, opus::Channels::Mono, opus::Application::Voip)
            .map_err(failure)?;
        let lookahead = encoder.get_lookahead().map_err(failure)?.max(0) as u64;
        let pre_skip = lookahead * GRANULE_RATE / rate as u64;
        let file = File::options().write(true).create_new(true).open(path)?;
        let mut writer = PacketWriter::new(file);
        let mut head = b"OpusHead".to_vec();
        head.push(1);
        head.push(1);
        head.extend_from_slice(&(pre_skip as u16).to_le_bytes());
        head.extend_from_slice(&rate.to_le_bytes());
        head.extend_from_slice(&0i16.to_le_bytes());
        head.push(0);
        writer.write_packet(head, SERIAL, PacketWriteEndInfo::EndPage, 0)?;
        let vendor = b"Escriba";
        let mut tags = b"OpusTags".to_vec();
        tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
        tags.extend_from_slice(vendor);
        tags.extend_from_slice(&0u32.to_le_bytes());
        writer.write_packet(tags, SERIAL, PacketWriteEndInfo::EndPage, 0)?;
        Ok(Self {
            writer,
            encoder,
            rate,
            frame: rate as usize / 50,
            pending: Vec::new(),
            pre_skip,
            encoded: 0,
            pushed: 0,
            packets: 0,
        })
    }

    /// Seconds of audio received, encoded or still waiting for a full frame.
    pub fn duration(&self) -> f64 {
        self.pushed as f64 / self.rate as f64
    }

    pub fn push(&mut self, samples: &[f32]) -> io::Result<()> {
        self.pushed += samples.len() as u64;
        self.pending.extend_from_slice(samples);
        while self.pending.len() >= self.frame {
            let frame: Vec<f32> = self.pending.drain(..self.frame).collect();
            self.encoded += self.frame as u64;
            self.packets += 1;
            let end = if self.packets.is_multiple_of(PACKETS_PER_PAGE) {
                PacketWriteEndInfo::EndPage
            } else {
                PacketWriteEndInfo::NormalPacket
            };
            self.write(&frame, self.granule(self.encoded), end)?;
        }
        Ok(())
    }

    /// Pads the last frame with silence and ends the stream at the real length.
    pub fn finish(mut self) -> io::Result<f64> {
        let mut last = std::mem::take(&mut self.pending);
        last.resize(self.frame, 0.0);
        let granule = self.granule(self.pushed);
        self.write(&last, granule, PacketWriteEndInfo::EndStream)?;
        let duration = self.duration();
        self.writer.into_inner().sync_all()?;
        Ok(duration)
    }

    fn granule(&self, samples: u64) -> u64 {
        self.pre_skip + samples * GRANULE_RATE / self.rate as u64
    }

    fn write(&mut self, frame: &[f32], granule: u64, end: PacketWriteEndInfo) -> io::Result<()> {
        let mut packet = vec![0; 1500];
        let size = self
            .encoder
            .encode_float(frame, &mut packet)
            .map_err(failure)?;
        packet.truncate(size);
        self.writer.write_packet(packet, SERIAL, end, granule)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(rate: u32, seconds: f64) -> Vec<f32> {
        (0..(rate as f64 * seconds) as usize)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.5)
            .collect()
    }

    #[test]
    fn un_segundo_se_lee_como_un_segundo_a_cualquier_frecuencia_de_opus() {
        let folder = tempfile::tempdir().unwrap();
        for rate in [16_000, 48_000] {
            let path = folder.path().join(format!("tono-{rate}.ogg"));
            let mut writer = OpusOgg::create(&path, rate).unwrap();
            for chunk in tone(rate, 1.0).chunks(rate as usize / 100 + 7) {
                writer.push(chunk).unwrap();
            }
            assert!((writer.finish().unwrap() - 1.0).abs() < 1e-9);
            let read = crate::audio::duration(&path).unwrap_or_default();
            assert!((read - 1.0).abs() < 0.03, "{rate}: {read}");
        }
    }

    #[test]
    fn parar_enseguida_deja_un_fichero_valido() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("vacia.ogg");
        assert_eq!(
            OpusOgg::create(&path, 48_000).unwrap().finish().unwrap(),
            0.0
        );
        assert_eq!(&std::fs::read(&path).unwrap()[..4], b"OggS");
    }

    #[test]
    fn nunca_sobrescribe_ni_acepta_frecuencias_que_opus_no_tiene() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("existe.ogg");
        std::fs::write(&path, b"x").unwrap();
        assert!(OpusOgg::create(&path, 48_000).is_err());
        assert!(OpusOgg::create(&folder.path().join("raro.ogg"), 44_100).is_err());
    }
}
