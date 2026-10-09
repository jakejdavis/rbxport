//! The application core, free of any windowing shell.
//!
//! State, errors, DTOs, backups, journals, the link session, startup loading
//! and the browse commands live here as plain functions. `src-tauri` adapts
//! them for the webview; the native front end adapts them over FFI.

pub mod backup_copy;
pub mod backup_restore_scripts;
pub mod backup_sizes;
pub mod backup_zip;
pub mod backups;
pub mod browse;
pub mod dto;
pub mod durable;
pub mod edits;
pub mod error;
pub mod events;
pub mod explorer;
pub mod file_journal;
pub mod link;
pub mod network_labels;
pub mod rx3_link;
pub mod startup;
pub mod state;

pub use error::{set_internal_error_hook, AppError, AppResult, ErrorKind};
pub use events::{AppEvent, EventSink, NullSink};
