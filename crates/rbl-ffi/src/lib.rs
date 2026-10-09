//! The bridge between the Rust application core and the native macOS front end.
//!
//! A thin `UniFFI` layer over `rbl-app`: it holds an `Arc<AppState>`, calls the
//! core's browse and startup functions, and converts their DTOs into records
//! and enums Swift can use (no JSON, no stringly kinds). All logic lives in
//! `rbl-app`; the only code here is conversion.
//!
//! Reads open the library read-only; every edit passes the write gate in `rbl_app::edits`.

// UniFFI's generated scaffolding is `unsafe` (extern "C" entry points); the
// workspace denies it, and `lints.workspace = true` cannot be partly overridden
// in the manifest. Every line of hand-written code here stays safe.
#![allow(unsafe_code)]

mod convert;
mod core;
mod devices;
mod error;
mod events;
mod link;
mod playback;
mod support;
mod types;

pub use crate::core::Core;
pub use devices::{
    ColorName, CompatibilityFormat, DeviceLibraryTree, DevicePlaylistNode, DeviceSettings, DeviceSyncState, ExportOptions, ExportProgress,
    ExportReport, ExportState, ItunesLibrary, ItunesNode, ItunesTrack, KeyDisplay, MenuSlot, MissingExportFile, StickOverview, StickDefaults, SyncDeviceReport, SyncPlaylist,
    SyncProgress, SyncState, UsbImportReport, VerifyReport, WaveformColor, WaveformPosition,
};
pub use error::FfiError;
pub use support::{install_logging, AudioHealth, BackupInfo, BackupPhase, BackupProgress, NewLibraryPlan, SystemReport};
pub use link::{LinkConnection, LinkDeviceKind, LinkInterface, LinkLoaded, LinkPeer, LinkPlayer, LinkState, LinkStatus};
pub use events::{EventListener, LibraryEvent};
pub use playback::{
    AudioDevice, AudioDevices, ChannelState, Deck, DeckEvent, DeckTick, EqBand, Limiter, MetronomeVolume, Meters, MixerSnapshot,
    Playback, PlaybackListener, PlaybackTick, PreviewState,
};
pub use types::{
    Beat, BpmFilter, Cue, Phrase, CountedBpm, CountedKey, Device, DeviceExport, EditHistory, ExplorerChildren, ExplorerRoot, ExtraColumn,
    FilterValues, PlaylistFileFormat, TagCategory, TrackFilter, ExtraFields, HotCue, LibraryProblem, LibrarySummary, LoadOutcome, NodeKind, Row,
    SearchField, SortKey,
    TrackDetails, TrackLookups, MyTag, MyTagCategory, WaveformKind,
    TrackSource, TreeNode, ViewHandle, ViewSpec, ImportProgress, SmartCondition, SmartLogic, SmartRule, TrackField, ImportReport, XmlImportReport, MissingTracks, Duplicates,
    RelocateReport, AnalysisResult, AnalysisSettings, CueSlot, GridEdit, GridState,
};

uniffi::setup_scaffolding!();

/// The most rows one `fetch_rows` call returns (the core's cap).
pub const MAX_ROWS: u32 = rbl_app::browse::MAX_ROWS;
