//! Events pushed to the front end, and the adapter from the core's sink.

use std::sync::Arc;

use rbl_app::{AppEvent, EventSink};

use crate::devices::{ExportProgress, ExportReport, SyncProgress};
use crate::link::{LinkPeer, LinkStatus};
use crate::types::{EditHistory, ImportProgress, LibraryProblem};

/// Something that happened which the UI may want to redraw for.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum LibraryEvent {
    LibraryReady,
    LibraryProblem { problem: LibraryProblem },
    LibraryChanged { generation: u32 },
    TagListChanged { generation: u32 },
    EditHistoryChanged { history: EditHistory },
    CuesChanged { track_id: String },
    GridChanged { track_id: String },
    AnalysisChanged { track_id: String },
    DevicesChanged,
    ImportProgress { progress: ImportProgress },
    ExportProgress { progress: ExportProgress },
    ExportDone { report: ExportReport },
    SyncProgress { progress: SyncProgress },
    LinkStatus { status: LinkStatus },
    LinkPeers { peers: Vec<LinkPeer> },
}

/// Implemented in Swift. Called from whichever thread raised the event, so
/// implementations must be thread-safe and quick (hand off, do not block).
#[uniffi::export(with_foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, event: LibraryEvent);
}

/// Adapts a foreign listener to the core's sink.
pub(crate) struct ListenerSink(pub Arc<dyn EventListener>);

impl EventSink for ListenerSink {
    fn emit(&self, event: AppEvent) {
        self.0.on_event(event.into());
    }
}
