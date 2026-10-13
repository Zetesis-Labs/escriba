//! Tray icons for desktops without SF Symbols, drawn as white glyphs with
//! signed distances so their edges stay smooth at any panel size.

pub const SIZE: u32 = 32;

type Shape = fn(f32, f32) -> f32;

fn capsule(x: f32, y: f32, cx: f32, top: f32, bottom: f32, radius: f32) -> f32 {
    let dy = y - y.clamp(top, bottom);
    ((x - cx).powi(2) + dy.powi(2)).sqrt() - radius
}

fn circle(x: f32, y: f32, cx: f32, cy: f32, radius: f32) -> f32 {
    ((x - cx).powi(2) + (y - cy).powi(2)).sqrt() - radius
}

fn square(x: f32, y: f32, cx: f32, cy: f32, half: f32) -> f32 {
    (x - cx).abs().max((y - cy).abs()) - half
}

fn waveform(x: f32, y: f32) -> f32 {
    [
        (6.0, 0.35),
        (11.0, 0.7),
        (16.0, 1.0),
        (21.0, 0.6),
        (26.0, 0.3),
    ]
    .iter()
    .map(|&(cx, height)| {
        let half = 11.0 * height;
        capsule(x, y, cx, 16.0 - half, 16.0 + half, 1.6)
    })
    .fold(f32::MAX, f32::min)
}

// The badge cuts a gap into the waveform so it reads at panel size.
fn badged(x: f32, y: f32, inside: Option<Shape>) -> f32 {
    let wave = waveform(x, y).max(-circle(x, y, 24.0, 24.0, 8.5));
    let badge = circle(x, y, 24.0, 24.0, 6.5);
    let badge = inside.map_or(badge, |hole| badge.max(-hole(x, y)));
    wave.min(badge)
}

fn working(x: f32, y: f32) -> f32 {
    badged(x, y, None)
}

fn problem(x: f32, y: f32) -> f32 {
    badged(
        x,
        y,
        Some(|x, y| capsule(x, y, 24.0, 20.5, 24.5, 1.1).min(circle(x, y, 24.0, 27.5, 1.1))),
    )
}

fn record(x: f32, y: f32) -> f32 {
    let ring = circle(x, y, 16.0, 16.0, 13.0).max(-circle(x, y, 16.0, 16.0, 10.5));
    ring.min(circle(x, y, 16.0, 16.0, 7.0))
}

fn stop(x: f32, y: f32) -> f32 {
    circle(x, y, 16.0, 16.0, 13.0).max(-square(x, y, 16.0, 16.0, 4.5))
}

fn shape(name: &str) -> Option<Shape> {
    Some(match name {
        "waveform" => waveform,
        "waveform.badge.mic" => working,
        "waveform.badge.exclamationmark" => problem,
        "record.circle" => record,
        "stop.circle.fill" => stop,
        _ => return None,
    })
}

/// RGBA pixels of SIZE×SIZE for the symbol the macOS tray would use.
pub fn draw(name: &str) -> Option<Vec<u8>> {
    let shape = shape(name)?;
    let mut pixels = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for row in 0..SIZE {
        for column in 0..SIZE {
            let distance = shape(column as f32 + 0.5, row as f32 + 0.5);
            let coverage = (0.5 - distance).clamp(0.0, 1.0);
            pixels.extend_from_slice(&[255, 255, 255, (coverage * 255.0).round() as u8]);
        }
    }
    Some(pixels)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAMES: [&str; 5] = [
        "waveform",
        "waveform.badge.mic",
        "waveform.badge.exclamationmark",
        "record.circle",
        "stop.circle.fill",
    ];

    fn alpha(pixels: &[u8], x: u32, y: u32) -> u8 {
        pixels[((y * SIZE + x) * 4 + 3) as usize]
    }

    #[test]
    fn cada_simbolo_de_la_bandeja_tiene_su_icono_distinto() {
        let icons: Vec<_> = NAMES.iter().map(|name| draw(name).unwrap()).collect();
        for (name, icon) in NAMES.iter().zip(&icons) {
            assert_eq!(icon.len(), (SIZE * SIZE * 4) as usize, "{name}");
            let painted = icon.chunks(4).filter(|pixel| pixel[3] > 128).count();
            assert!(painted > 40, "{name}: {painted}");
            assert_eq!(alpha(icon, 0, 0), 0, "{name}");
        }
        for (i, a) in icons.iter().enumerate() {
            for b in &icons[i + 1..] {
                assert_ne!(a, b);
            }
        }
        assert!(draw("desconocido").is_none());
    }

    #[test]
    fn grabar_tiene_punto_central_y_parar_un_hueco_cuadrado() {
        let record = draw("record.circle").unwrap();
        assert_eq!(alpha(&record, 16, 16), 255);
        assert_eq!(alpha(&record, 16, 7), 0);
        let stop = draw("stop.circle.fill").unwrap();
        assert_eq!(alpha(&stop, 16, 16), 0);
        assert_eq!(alpha(&stop, 16, 6), 255);
    }
}
