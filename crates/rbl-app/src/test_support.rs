//! Shared by the unit tests of the editing modules: a fixture-backed state with
//! the native gate on, and a sink that records events. Nothing here can reach the
//! installed library: the location is a temp-dir fixture.

#![allow(clippy::unwrap_used)]

use std::sync::{Arc, Mutex};

use crate::events::{AppEvent, EventSink};
use crate::state::AppState;

#[derive(Default)]
pub struct Recorder(pub Mutex<Vec<AppEvent>>);

impl EventSink for Recorder {
    fn emit(&self, event: AppEvent) {
        self.0.lock().unwrap().push(event);
    }
}

impl Recorder {
    pub fn names(&self) -> Vec<&'static str> {
        self.0.lock().unwrap().iter().map(AppEvent::name).collect()
    }
    pub fn clear(&self) {
        self.0.lock().unwrap().clear();
    }
    pub fn progress(&self) -> Vec<(u32, u32)> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| if let AppEvent::ImportProgress(p) = e { Some((p.done, p.total)) } else { None })
            .collect()
    }
}

pub fn fixture(protect: bool) -> (tempfile::TempDir, Arc<AppState>, Recorder) {
    let dir = tempfile::tempdir().unwrap();
    let location = rbl_db::fixture::build(dir.path(), rbl_db::fixture::Shape::default()).unwrap();
    assert!(!location.is_real_install);
    let db = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).unwrap();
    let (library, _) = rbl_index::load(&db).unwrap();
    let state = Arc::new(AppState::with_backups(dir.path().join("backups")));
    state.set_library(library, false, db.schema().db_version, 0, location);
    state.enable_native_gate();
    state.set_protect_library(protect);
    (dir, state, Recorder::default())
}

/// A minimal but genuine mono WAV, so the tag reader has something real to open.
pub fn write_wav(path: &std::path::Path, seconds: u32) {
    let rate = 44_100_u32;
    let data_len = rate * seconds * 2;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16_u32.to_le_bytes());
    out.extend_from_slice(&1_u16.to_le_bytes());
    out.extend_from_slice(&1_u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2_u16.to_le_bytes());
    out.extend_from_slice(&16_u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    out.resize(44 + data_len as usize, 0);
    std::fs::write(path, out).unwrap();
}
