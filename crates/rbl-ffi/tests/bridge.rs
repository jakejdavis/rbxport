#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

use std::sync::{Arc, Mutex};

use rbl_db::fixture::playlist_id;
use rbl_ffi::{
    Core, EventListener, FfiError, LibraryEvent, LoadOutcome, NodeKind, SortKey, TrackSource, ViewSpec,
    MAX_ROWS,
};

#[derive(Default)]
struct Recorder(Mutex<Vec<LibraryEvent>>);

impl EventListener for Recorder {
    fn on_event(&self, event: LibraryEvent) {
        self.0.lock().unwrap().push(event);
    }
}

fn core() -> (tempfile::TempDir, Arc<Core>, Arc<Recorder>) {
    let dir = tempfile::tempdir().unwrap();
    let events = Arc::new(Recorder::default());
    let core = Core::with_fixture(events.clone(), dir.path().to_string_lossy().into_owned());
    assert_eq!(core.load_library(), LoadOutcome::Ready);
    (dir, core, events)
}

fn spec(source: TrackSource, sort: SortKey, descending: bool, query: &str) -> ViewSpec {
    ViewSpec { source, sort, descending, query: query.into() }
}

#[test]
fn loading_announces_ready() {
    let (_dir, _core, events) = core();
    assert_eq!(events.0.lock().unwrap().as_slice(), [LibraryEvent::LibraryReady]);
}

#[test]
fn nothing_is_served_before_the_load() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::with_fixture(Arc::new(Recorder::default()), dir.path().to_string_lossy().into_owned());
    assert!(matches!(core.summary(), Err(FfiError::NotFound { .. })));
}

#[test]
fn summary_counts_the_fixture() {
    let (_dir, core, _) = core();
    let s = core.summary().unwrap();
    assert_eq!(s.track_count, 40);
    assert!(s.playlist_count >= 3);
}

#[test]
fn tree_has_sections_and_playlists() {
    let (_dir, core, _) = core();
    let tree = core.playlist_tree().unwrap();
    assert_eq!(tree[0].kind, NodeKind::AllTracks);
    assert_eq!(tree[0].child_count, Some(40));
    assert_eq!(tree[1].kind, NodeKind::Collection);
    let lists: Vec<_> = tree.iter().filter(|n| n.kind == NodeKind::Playlist).collect();
    assert_eq!(lists.len(), 3);
    assert!(lists.iter().all(|n| n.depth == 1 && n.child_count == Some(5)));
    assert!(tree.iter().any(|n| n.kind == NodeKind::Histories));
    assert!(tree.iter().any(|n| n.kind == NodeKind::History));
}

#[test]
fn collection_pages_sorts_and_searches() {
    let (_dir, core, _) = core();
    let view = core.open_view(spec(TrackSource::Collection, SortKey::Title, false, "")).unwrap();
    assert_eq!(view.len, 40);
    let first = core.fetch_rows(view.view_id, 0, 10).unwrap();
    let second = core.fetch_rows(view.view_id, 10, 10).unwrap();
    assert_eq!((first.len(), second.len()), (10, 10));
    assert_eq!(first[0].title, "Track 000");
    assert_eq!(second[0].title, "Track 010");
    assert_eq!(second[0].track_no, 11);
    assert_eq!(core.fetch_rows(view.view_id, 35, 20).unwrap().len(), 5);
    assert!(core.fetch_rows(view.view_id, 99, 20).unwrap().is_empty());

    let desc = core.open_view(spec(TrackSource::Collection, SortKey::Title, true, "")).unwrap();
    assert_eq!(core.fetch_rows(desc.view_id, 0, 1).unwrap()[0].title, "Track 039");

    let found = core.open_view(spec(TrackSource::Collection, SortKey::Title, false, "039")).unwrap();
    assert_eq!(found.len, 1);
    assert_eq!(core.view_ids_in_range(found.view_id, 0, 0).unwrap().len(), 1);
}

#[test]
fn every_sort_key_opens() {
    let (_dir, core, _) = core();
    for key in [SortKey::TrackNo, SortKey::Bpm, SortKey::PlayCount, SortKey::DateAdded, SortKey::KeyCamelot] {
        assert_eq!(core.open_view(spec(TrackSource::Collection, key, false, "")).unwrap().len, 40);
    }
}

#[test]
fn playlist_and_history_sources_open() {
    let (_dir, core, _) = core();
    let playlist =
        core.open_view(spec(TrackSource::Playlist { id: playlist_id(0) }, SortKey::TrackNo, false, "")).unwrap();
    assert_eq!(playlist.len, 5);
    let node = core.playlist_tree().unwrap().into_iter().find(|n| n.kind == NodeKind::History).unwrap();
    assert!(core.open_view(spec(TrackSource::History { id: node.id }, SortKey::TrackNo, false, "")).is_ok());
    assert!(matches!(
        core.open_view(spec(TrackSource::Folder { path: String::new() }, SortKey::TrackNo, false, "")),
        Err(FfiError::Malformed { .. })
    ));
}

#[test]
fn len_is_capped() {
    let (_dir, core, _) = core();
    let view = core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    assert!(core.fetch_rows(view.view_id, 0, MAX_ROWS).is_ok());
    assert!(matches!(core.fetch_rows(view.view_id, 0, MAX_ROWS + 1), Err(FfiError::Malformed { .. })));
}

#[test]
fn old_views_are_evicted() {
    let (_dir, core, _) = core();
    let first = core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    for _ in 0..16 {
        core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    }
    assert!(matches!(core.fetch_rows(first.view_id, 0, 1), Err(FfiError::NotFound { .. })));
}
