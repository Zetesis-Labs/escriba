//! What differs per system, behind the same names for the common modules:
//! `Inference` (transcribe, speakers, LLM and models), `Encoder` and
//! `ENCODER_RATES` (recording format), `file_flags`, `dataless` and
//! `materialize` (files kept elsewhere), `DEFAULT_MODEL` and `normalized_model`.
//! The macOS pieces join here as their own module.

#[cfg(any(target_os = "linux", target_os = "windows"))]
mod local;
#[cfg(any(target_os = "linux", target_os = "windows"))]
pub use local::*;
