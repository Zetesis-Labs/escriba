//! Escriba's native host for systems without the Swift one: protocol v1 of
//! docs/tauri-native-protocol.md over JSON lines on stdin and stdout.

mod audio;
mod files;
mod platform;
mod protocol;

pub use protocol::Host;
