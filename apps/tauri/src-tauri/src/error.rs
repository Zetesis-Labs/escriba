use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    BackendUnavailable,
    RecipeUnavailable,
    RuntimeUnavailable,
    MicrophoneDenied,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AppError {
    pub code: ErrorCode,
    pub message: String,
}

impl AppError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn retryable(&self) -> bool {
        matches!(
            self.code,
            ErrorCode::BackendUnavailable
                | ErrorCode::RecipeUnavailable
                | ErrorCode::RuntimeUnavailable
        )
    }

    pub fn from_frame(value: &serde_json::Value) -> Self {
        serde_json::from_value(value.clone()).unwrap_or_else(|_| {
            Self::new(
                ErrorCode::Failed,
                value["message"].as_str().unwrap_or("El trabajo falló"),
            )
        })
    }
}

impl From<String> for AppError {
    fn from(message: String) -> Self {
        Self::new(ErrorCode::Failed, message)
    }
}

impl From<&str> for AppError {
    fn from(message: &str) -> Self {
        Self::new(ErrorCode::Failed, message)
    }
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.message.fmt(f)
    }
}

impl std::error::Error for AppError {}

impl From<AppError> for String {
    fn from(error: AppError) -> Self {
        error.message
    }
}
