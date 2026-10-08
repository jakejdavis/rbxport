use rbl_app::{AppError, ErrorKind};

/// What went wrong, in the core's error kinds. `detail` is developer text.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{message}")]
    ReadOnly { message: String, detail: Option<String> },
    #[error("{message}")]
    NotFound { message: String, detail: Option<String> },
    #[error("{message}")]
    Malformed { message: String, detail: Option<String> },
    #[error("{message}")]
    Cancelled { message: String, detail: Option<String> },
    #[error("{message}")]
    Internal { message: String, detail: Option<String> },
}

impl From<AppError> for FfiError {
    fn from(error: AppError) -> Self {
        let AppError { kind, message, detail } = error;
        match kind {
            ErrorKind::ReadOnly => Self::ReadOnly { message, detail },
            ErrorKind::NotFound => Self::NotFound { message, detail },
            ErrorKind::Malformed => Self::Malformed { message, detail },
            ErrorKind::Cancelled => Self::Cancelled { message, detail },
            ErrorKind::Internal => Self::Internal { message, detail },
        }
    }
}
