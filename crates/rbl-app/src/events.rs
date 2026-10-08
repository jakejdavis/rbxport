//! Events the core raises for whatever front end is listening.
//!
//! The wire name and payload of each variant are exactly what the React
//! frontend has always received; [`AppEvent`] serializes as its payload alone.

use serde::{Serialize, Serializer};

use crate::dto::{EditHistoryDto, LibraryProblemDto};

/// Something that happened which a front end may want to redraw for.
#[derive(Debug, Clone)]
pub enum AppEvent {
    /// The library finished loading. Payload: none.
    LibraryReady,
    /// The library did not load; why.
    LibraryProblem(LibraryProblemDto),
    /// The library changed; the payload is the new generation.
    LibraryChanged(u32),
    /// Only the Tag List changed; the payload is the new generation.
    TagListChanged(u32),
    /// Undo or redo became (un)available.
    EditHistoryChanged(EditHistoryDto),
}

impl AppEvent {
    /// The event's name on the wire.
    pub fn name(&self) -> &'static str {
        match self {
            Self::LibraryReady => "library:ready",
            Self::LibraryProblem(_) => "library:problem",
            Self::LibraryChanged(_) => "library:changed",
            Self::TagListChanged(_) => "tag-list:changed",
            Self::EditHistoryChanged(_) => "edit-history:changed",
        }
    }
}

/// Serializes the payload only, so `emit(ev.name(), &ev)` matches the old
/// `emit("library:changed", generation)` byte for byte.
impl Serialize for AppEvent {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::LibraryReady => serializer.serialize_unit(),
            Self::LibraryProblem(problem) => problem.serialize(serializer),
            Self::LibraryChanged(generation) | Self::TagListChanged(generation) => generation.serialize(serializer),
            Self::EditHistoryChanged(history) => history.serialize(serializer),
        }
    }
}

/// Where the core sends its events. Called from any thread.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: AppEvent);
}

/// A sink that drops everything.
#[derive(Debug, Clone, Copy, Default)]
pub struct NullSink;

impl EventSink for NullSink {
    fn emit(&self, _event: AppEvent) {}
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn payloads_match_the_old_wire_format() {
        assert_eq!(serde_json::to_string(&AppEvent::LibraryReady).unwrap(), "null");
        assert_eq!(serde_json::to_string(&AppEvent::LibraryChanged(7)).unwrap(), "7");
        assert_eq!(AppEvent::TagListChanged(1).name(), "tag-list:changed");
        let problem = AppEvent::LibraryProblem(LibraryProblemDto::Failed { message: "x".into() });
        assert_eq!(serde_json::to_string(&problem).unwrap(), r#"{"kind":"failed","message":"x"}"#);
    }
}
