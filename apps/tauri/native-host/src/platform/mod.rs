//! What differs per system, behind the same names for the common modules:
//! `Inference` (transcribe, speakers, LLM and models), `Encoder` and
//! `ENCODER_RATES` (recording format), `file_flags`, `dataless` and
//! `materialize` (files kept elsewhere), `DEFAULT_MODEL` and `normalized_model`.
//! The macOS pieces join here as their own module.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;
