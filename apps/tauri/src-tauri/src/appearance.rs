pub fn hex(red: f64, green: f64, blue: f64) -> String {
    let channel = |value: f64| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
    format!("#{:02x}{:02x}{:02x}", channel(red), channel(green), channel(blue))
}

#[cfg(target_os = "macos")]
pub fn accent() -> Option<String> {
    use objc2_app_kit::{NSColor, NSColorSpace};
    let color =
        NSColor::controlAccentColor().colorUsingColorSpace(&NSColorSpace::sRGBColorSpace())?;
    Some(hex(
        color.redComponent(),
        color.greenComponent(),
        color.blueComponent(),
    ))
}

#[cfg(not(target_os = "macos"))]
pub fn accent() -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn el_color_se_escribe_en_hexadecimal_de_la_web() {
        assert_eq!(hex(1.0, 0.5, 0.0), "#ff8000");
        assert_eq!(hex(-0.2, 1.4, 0.0), "#00ff00");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_da_un_color_de_acento() {
        let accent = accent().expect("sin color de acento");
        assert_eq!(accent.len(), 7);
        assert!(accent.starts_with('#'));
    }
}
