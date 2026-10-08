#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

use rbl_db::fixture::{build, playlist_id, Shape};
use rbl_ffi::{FfiError, LibraryHandle, NodeKind, TrackSource, ViewSpec, MAX_VIEWS};

fn handle() -> (tempfile::TempDir, std::sync::Arc<LibraryHandle>) {
    let dir = tempfile::tempdir().unwrap();
    build(dir.path(), Shape::default()).unwrap();
    let handle = LibraryHandle::open_fixture(dir.path().to_string_lossy().into_owned()).unwrap();
    (dir, handle)
}

fn spec(source: TrackSource, sort: &str, descending: bool, query: &str) -> ViewSpec {
    ViewSpec { source, sort: sort.into(), descending, query: query.into() }
}

#[test]
fn summary_counts_the_fixture() {
    let (_dir, h) = handle();
    let s = h.summary();
    assert_eq!(s.track_count, 40);
    assert!(s.playlist_count >= 3);
    assert!(s.read_only);
}

#[test]
fn tree_has_sections_and_playlists() {
    let (_dir, h) = handle();
    let tree = h.playlist_tree();
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
    let (_dir, h) = handle();
    let view = h.open_view(spec(TrackSource::Collection, "title", false, "")).unwrap();
    assert_eq!(view.len, 40);
    let first = h.fetch_rows(view.view_id, 0, 10).unwrap();
    let second = h.fetch_rows(view.view_id, 10, 10).unwrap();
    assert_eq!((first.len(), second.len()), (10, 10));
    assert_eq!(first[0].title, "Track 000");
    assert_eq!(second[0].title, "Track 010");
    assert_eq!(second[0].track_no, 11);
    // A window past the end is clamped, not an error.
    assert_eq!(h.fetch_rows(view.view_id, 35, 20).unwrap().len(), 5);
    assert!(h.fetch_rows(view.view_id, 99, 20).unwrap().is_empty());

    let desc = h.open_view(spec(TrackSource::Collection, "title", true, "")).unwrap();
    assert_eq!(h.fetch_rows(desc.view_id, 0, 1).unwrap()[0].title, "Track 039");

    let found = h.open_view(spec(TrackSource::Collection, "title", false, "039")).unwrap();
    assert_eq!(found.len, 1);
    let rows = h.fetch_rows(found.view_id, 0, 128).unwrap();
    assert!(rows.iter().all(|r| r.title == "Track 039"));
}

#[test]
fn playlist_and_history_sources_open() {
    let (_dir, h) = handle();
    let playlist = h
        .open_view(spec(TrackSource::Playlist { id: playlist_id(0) }, "", false, ""))
        .unwrap();
    assert_eq!(playlist.len, 5);
    let history_node = h.playlist_tree().into_iter().find(|n| n.kind == NodeKind::History).unwrap();
    assert!(h.open_view(spec(TrackSource::History { id: history_node.id }, "", false, "")).is_ok());
    assert!(matches!(
        h.open_view(spec(TrackSource::Playlist { id: "999999".into() }, "", false, "")),
        Err(FfiError::NotFound { .. })
    ));
    assert!(matches!(
        h.open_view(spec(TrackSource::TagList, "", false, "")),
        Err(FfiError::Malformed { .. })
    ));
}

#[test]
fn len_is_capped() {
    let (_dir, h) = handle();
    let view = h.open_view(spec(TrackSource::Collection, "", false, "")).unwrap();
    assert!(h.fetch_rows(view.view_id, 0, 128).is_ok());
    assert!(matches!(h.fetch_rows(view.view_id, 0, 129), Err(FfiError::Malformed { .. })));
}

#[test]
fn old_views_are_evicted() {
    let (_dir, h) = handle();
    let first = h.open_view(spec(TrackSource::Collection, "", false, "")).unwrap();
    for _ in 0..MAX_VIEWS {
        h.open_view(spec(TrackSource::Collection, "", false, "")).unwrap();
    }
    assert!(matches!(h.fetch_rows(first.view_id, 0, 1), Err(FfiError::NotFound { .. })));
}
