const CANVAS: f64 = 36.0;
const POINT_SIZE: f64 = 26.0;

#[cfg(target_os = "macos")]
#[allow(deprecated)]
pub fn png(name: &str) -> Option<Vec<u8>> {
    use objc2::AllocAnyThread;
    use objc2_app_kit::{
        NSBitmapImageFileType, NSBitmapImageRep, NSImage, NSImageSymbolConfiguration,
    };
    use objc2_foundation::{NSDictionary, NSPoint, NSRect, NSSize, NSString};

    let symbol = NSImage::imageWithSystemSymbolName_accessibilityDescription(
        &NSString::from_str(name),
        None,
    )?
    .imageWithSymbolConfiguration(
        &NSImageSymbolConfiguration::configurationWithPointSize_weight(POINT_SIZE, 0.0),
    )?;
    let size = symbol.size();
    let canvas = NSImage::initWithSize(
        NSImage::alloc(),
        NSSize::new(size.width.max(CANVAS), CANVAS),
    );
    canvas.lockFocus();
    symbol.drawInRect(NSRect::new(
        NSPoint::new(
            (canvas.size().width - size.width) / 2.0,
            (CANVAS - size.height) / 2.0,
        ),
        size,
    ));
    canvas.unlockFocus();
    let bitmap = NSBitmapImageRep::imageRepWithData(&*canvas.TIFFRepresentation()?)?;
    let data = unsafe {
        bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
    }?;
    Some(data.to_vec())
}

#[cfg(not(target_os = "macos"))]
pub fn png(_name: &str) -> Option<Vec<u8>> {
    None
}

pub fn image(name: &str) -> Option<tauri::image::Image<'static>> {
    tauri::image::Image::from_bytes(&png(name)?).ok()
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn los_simbolos_de_la_barra_de_menus_se_pintan_a_la_altura_del_lienzo() {
        for name in [
            "waveform",
            "waveform.badge.mic",
            "waveform.badge.exclamationmark",
            "record.circle",
            "stop.circle.fill",
        ] {
            let image = image(name).unwrap_or_else(|| panic!("sin símbolo {name}"));
            assert!(image.height() >= CANVAS as u32, "{name}");
            assert!(image.width() >= image.height(), "{name}");
        }
        assert!(png("no.existe.este.simbolo").is_none());
    }
}
