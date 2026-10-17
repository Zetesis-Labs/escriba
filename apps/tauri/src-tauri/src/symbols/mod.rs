//! Tray and menu bar icons, drawn the way each system can.

#[cfg(any(target_os = "linux", target_os = "windows"))]
mod linux;
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub use linux::image;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::image;
