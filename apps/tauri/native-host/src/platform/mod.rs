//! What differs per system. The macOS pieces join here as their own module.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;
