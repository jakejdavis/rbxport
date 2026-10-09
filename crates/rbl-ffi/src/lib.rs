//! The bridge between the Rust application core and the native macOS front end.
//!
//! A thin `UniFFI` layer over `rbl-app`: it holds an `Arc<AppState>`, calls the
//! core's browse and startup functions, and converts their DTOs into records
//! and enums Swift can use (no JSON, no stringly kinds). All logic lives in
//! `rbl-app`; the only code here is conversion.
//!
//! The installed library is only ever opened read-only, and so are fixtures.

// UniFFI's generated scaffolding is `unsafe` (extern "C" entry points); the
// workspace denies it, and `lints.workspace = true` cannot be partly overridden
// in the manifest. Every line of hand-written code here stays safe.
#![allow(unsafe_code)]

mod convert;
mod core;
mod error;
mod events;
mod types;

pub use crate::core::Core;
pub use error::FfiError;
pub use events::{EventListener, LibraryEvent};
pub use types::{
    BpmFilter, CountedBpm, CountedKey, Device, DeviceExport, EditHistory, ExplorerChildren, ExplorerRoot, ExtraColumn,
    FilterValues, PlaylistFileFormat, TagCategory, TrackFilter, ExtraFields, HotCue, LibraryProblem, LibrarySummary, LoadOutcome, NodeKind, Row,
    SearchField, SortKey,
    TrackSource, TreeNode, ViewHandle, ViewSpec,
};

uniffi::setup_scaffolding!();

/// The most rows one `fetch_rows` call returns (the core's cap).
pub const MAX_ROWS: u32 = rbl_app::browse::MAX_ROWS;
