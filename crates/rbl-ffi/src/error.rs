/// What went wrong, in the command layer's four kinds.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{message}")]
    ReadOnly { message: String },
    #[error("{message}")]
    NotFound { message: String },
    #[error("{message}")]
    Malformed { message: String },
    #[error("{message}")]
    Internal { message: String },
}

impl FfiError {
    pub(crate) fn not_found(message: impl Into<String>) -> Self {
        Self::NotFound { message: message.into() }
    }
    pub(crate) fn malformed(message: impl Into<String>) -> Self {
        Self::Malformed { message: message.into() }
    }
    pub(crate) fn internal(message: impl Into<String>) -> Self {
        Self::Internal { message: message.into() }
    }
}

impl From<rbl_db::DbError> for FfiError {
    fn from(error: rbl_db::DbError) -> Self {
        match error {
            rbl_db::DbError::WriteRefused(message) => Self::ReadOnly { message },
            rbl_db::DbError::NotInstalled(message) => Self::NotFound { message },
            other => Self::Internal { message: other.to_string() },
        }
    }
}
