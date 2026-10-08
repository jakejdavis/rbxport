//! The bridge between the Rust library index and the native macOS front end.
//!
//! A small, self-contained mirror of the Tauri command layer's `library_summary`,
//! `playlist_tree`, `open_view` and `fetch_rows`, shaped so `UniFFI` can express
//! it: records instead of tuples, enums instead of `&'static str`, no JSON.
//!
//! The library is only ever opened read-only. Nothing here calls a write API.

// UniFFI's generated scaffolding is `unsafe` (extern "C" entry points); the
// workspace denies it, and `lints.workspace = true` cannot be partly overridden
// in the manifest. Every line of hand-written code here stays safe.
#![allow(unsafe_code)]

mod error;
mod handle;
mod tree;
mod types;
mod views;

pub use error::FfiError;
pub use handle::LibraryHandle;
pub use types::{
    HotCue, LibrarySummary, NodeKind, Row, TrackSource, TreeNode, ViewHandle, ViewSpec,
};

uniffi::setup_scaffolding!();

/// The most rows one `fetch_rows` call returns, as in the command layer.
pub const MAX_ROWS: u32 = 128;
/// How many views a handle keeps open before the least recently used goes.
pub const MAX_VIEWS: usize = 16;
