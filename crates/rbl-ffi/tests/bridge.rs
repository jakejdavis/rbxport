#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::assert_is_empty, clippy::similar_names)]

use std::sync::{Arc, Mutex};

use rbl_db::fixture::playlist_id;
use rbl_ffi::{
    Core, EventListener, ExtraColumn, FfiError, LibraryEvent, LoadOutcome, NodeKind, SearchField, SortKey,
    BpmFilter, PlaylistFileFormat, TrackFilter, TrackSource, ViewSpec, MAX_ROWS,
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
    ViewSpec {
        source,
        sort,
        descending,
        query: query.into(),
        search_field: SearchField::All,
        filter: TrackFilter::default(),
    }
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
    let first = core.fetch_rows(view.view_id, 0, 10, vec![]).unwrap();
    let second = core.fetch_rows(view.view_id, 10, 10, vec![]).unwrap();
    assert_eq!((first.len(), second.len()), (10, 10));
    assert_eq!(first[0].title, "Track 000");
    assert_eq!(second[0].title, "Track 010");
    assert_eq!(second[0].track_no, 11);
    assert_eq!(core.fetch_rows(view.view_id, 35, 20, vec![]).unwrap().len(), 5);
    assert!(core.fetch_rows(view.view_id, 99, 20, vec![]).unwrap().is_empty());

    let desc = core.open_view(spec(TrackSource::Collection, SortKey::Title, true, "")).unwrap();
    assert_eq!(core.fetch_rows(desc.view_id, 0, 1, vec![]).unwrap()[0].title, "Track 039");

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
    // The section heading of the Explorer lists nothing, and is not an error.
    let heading = core.open_view(spec(TrackSource::Folder { path: String::new() }, SortKey::TrackNo, false, "")).unwrap();
    assert_eq!(heading.len, 0);
}

#[test]
fn len_is_capped() {
    let (_dir, core, _) = core();
    let view = core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    assert!(core.fetch_rows(view.view_id, 0, MAX_ROWS, vec![]).is_ok());
    assert!(matches!(core.fetch_rows(view.view_id, 0, MAX_ROWS + 1, vec![]), Err(FfiError::Malformed { .. })));
}

#[test]
fn old_views_are_evicted() {
    let (_dir, core, _) = core();
    let first = core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    for _ in 0..16 {
        core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    }
    assert!(matches!(core.fetch_rows(first.view_id, 0, 1, vec![]), Err(FfiError::NotFound { .. })));
}

#[test]
fn rows_carry_extra_columns_only_when_asked() {
    let (_dir, core, _) = core();
    let view = core.open_view(spec(TrackSource::Collection, SortKey::TrackNo, false, "")).unwrap();
    let plain = core.fetch_rows(view.view_id, 0, 3, vec![]).unwrap();
    assert!(plain.iter().all(|r| r.extra == rbl_ffi::ExtraFields::default()));

    let rows = core
        .fetch_rows(view.view_id, 0, 3, vec![ExtraColumn::Size, ExtraColumn::Location, ExtraColumn::Cloud, ExtraColumn::Color])
        .unwrap();
    assert_eq!(rows.len(), 3);
    for row in &rows {
        assert!(row.extra.size.is_some());
        assert!(row.extra.location.is_some());
        assert!(row.extra.cloud.is_some());
        assert!(row.extra.color.is_some());
        // Not requested: stays empty.
        assert!(row.extra.composer.is_none());
        assert!(row.extra.bitrate.is_none());
    }
}

#[test]
fn search_field_scopes_the_query() {
    let (_dir, core, _) = core();
    let by = |field: SearchField, query: &str| {
        let spec = ViewSpec { search_field: field, ..spec(TrackSource::Collection, SortKey::Title, false, query) };
        core.open_view(spec).unwrap().len
    };
    assert_eq!(by(SearchField::Title, "Track 039"), 1);
    assert_eq!(by(SearchField::Title, "Track"), 40);
    assert_eq!(by(SearchField::Artist, "Track"), 0);
    assert_eq!(by(SearchField::All, "Track"), 40);
}

fn collection() -> ViewSpec {
    spec(TrackSource::Collection, SortKey::Title, false, "")
}

#[test]
fn filter_values_count_the_unfiltered_list() {
    let (_dir, core, _) = core();
    let values = core.filter_values(collection()).unwrap();
    // The fixture's tempos are 128.00 to 128.39, and it has no keys.
    assert_eq!(values.bpms.iter().map(|c| (c.value, c.count)).collect::<Vec<_>>(), [(128, 40)]);
    assert!(values.keys.is_empty());

    // A pick in the spec's own filter does not narrow what the bar offers.
    let picked = ViewSpec {
        filter: TrackFilter { bpm: Some(BpmFilter { values: vec![values.bpms[0].value], ..Default::default() }), ..Default::default() },
        ..collection()
    };
    assert_eq!(core.filter_values(picked).unwrap(), values);
}

#[test]
fn a_filtered_view_opens_with_only_the_picks() {
    let (_dir, core, _) = core();
    let values = core.filter_values(collection()).unwrap();

    // A ticked key column naming a key the library lacks matches nothing.
    let by_key = ViewSpec {
        filter: TrackFilter { keys: Some(vec!["8A".into()]), ..Default::default() },
        ..collection()
    };
    assert_eq!(core.open_view(by_key).unwrap().len, 0);

    let bpm = &values.bpms[0];
    let by_bpm = ViewSpec {
        filter: TrackFilter { bpm: Some(BpmFilter { values: vec![bpm.value], ..Default::default() }), ..Default::default() },
        ..collection()
    };
    assert_eq!(core.open_view(by_bpm).unwrap().len, bpm.count);

    let off_bpm = ViewSpec {
        filter: TrackFilter { bpm: Some(BpmFilter { values: vec![90], ..Default::default() }), ..Default::default() },
        ..collection()
    };
    assert_eq!(core.open_view(off_bpm).unwrap().len, 0);
    let rated = |ratings: Vec<u8>| ViewSpec {
        filter: TrackFilter { ratings: Some(ratings), ..Default::default() },
        ..collection()
    };
    assert_eq!(core.open_view(rated(vec![0])).unwrap().len, 40);
    assert_eq!(core.open_view(rated(vec![4, 5])).unwrap().len, 0);

    // Ticked and empty matches nothing; unticked (None) matches everything.
    let none = ViewSpec { filter: TrackFilter { ratings: Some(vec![]), ..Default::default() }, ..collection() };
    assert_eq!(core.open_view(none).unwrap().len, 0);
    assert_eq!(core.open_view(collection()).unwrap().len, 40);

    let colour = ViewSpec { filter: TrackFilter { colors: Some(vec!["Nonexistent".into()]), ..Default::default() }, ..collection() };
    assert_eq!(core.open_view(colour).unwrap().len, 0);
}

#[test]
fn the_tag_list_source_opens_empty() {
    let (_dir, core, _) = core();
    let view = core.open_view(spec(TrackSource::TagList, SortKey::TrackNo, false, "")).unwrap();
    assert_eq!(view.len, 0);
}

fn explorer_tree() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for sub in ["b-dir", "a-dir", "a-dir/nested"] {
        std::fs::create_dir_all(dir.path().join(sub)).unwrap();
    }
    std::fs::write(dir.path().join("one.mp3"), b"not really audio").unwrap();
    std::fs::write(dir.path().join("two.flac"), b"not really audio").unwrap();
    std::fs::write(dir.path().join("cover.jpg"), b"x").unwrap();
    dir
}

#[test]
fn explorer_lists_roots_and_subfolders_by_name() {
    let (_dir, core, _) = core();
    assert!(!core.explorer_roots().unwrap().is_empty());
    let tree = explorer_tree();
    let children = core.explorer_children(tree.path().to_string_lossy().into_owned()).unwrap();
    assert_eq!(children.names, ["a-dir", "b-dir"]);
    assert_eq!(children.total, 2);
    let missing = core.explorer_children(tree.path().join("nope").to_string_lossy().into_owned()).unwrap();
    assert!(missing.names.is_empty());
}

#[test]
fn a_folder_view_opens_pages_and_selects_loose_files() {
    let (_dir, core, _) = core();
    let tree = explorer_tree();
    let path = tree.path().to_string_lossy().into_owned();
    let view = core.open_view(spec(TrackSource::Folder { path }, SortKey::FileName, false, "")).unwrap();
    assert_eq!(view.len, 2);
    let rows = core.fetch_rows(view.view_id, 0, 10, vec![]).unwrap();
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|r| r.id.starts_with("file:")));
    assert_eq!(rows[0].file_name, "one.mp3");
    assert_eq!(core.view_ids_in_range(view.view_id, 0, 1).unwrap().len(), 2);
    assert_eq!(core.track_path(rows[0].id.clone()).unwrap(), tree.path().join("one.mp3").to_string_lossy());

    let searched = core.open_view(spec(
        TrackSource::Folder { path: tree.path().to_string_lossy().into_owned() },
        SortKey::FileName,
        false,
        "two",
    ));
    assert_eq!(searched.unwrap().len, 1);
}

#[test]
fn track_path_and_devices() {
    let (_dir, core, _) = core();
    let view = core.open_view(collection()).unwrap();
    let rows = core.fetch_rows(view.view_id, 0, 1, vec![]).unwrap();
    assert!(!core.track_path(rows[0].id.clone()).unwrap().is_empty());
    assert!(matches!(core.track_path("nope".into()), Err(FfiError::NotFound { .. })));
    // Listing must not fail, whatever is mounted.
    core.list_devices().unwrap();
}

#[test]
fn a_playlist_exports_to_m3u8_and_txt() {
    let (_dir, core, _) = core();
    let out = tempfile::tempdir().unwrap();
    let m3u8 = out.path().join("list.m3u8");
    let n = core
        .export_playlist_file(playlist_id(0), m3u8.to_string_lossy().into_owned(), PlaylistFileFormat::M3u8)
        .unwrap();
    assert_eq!(n, 5);
    let text = std::fs::read_to_string(&m3u8).unwrap();
    assert!(text.starts_with("#EXTM3U\n"));
    assert_eq!(text.matches("#EXTINF").count(), 5);

    let txt = out.path().join("list.txt");
    core.export_playlist_file(playlist_id(0), txt.to_string_lossy().into_owned(), PlaylistFileFormat::Txt).unwrap();
    let text = std::fs::read_to_string(&txt).unwrap();
    assert!(text.starts_with("#\tTrack Title"));
    assert_eq!(text.lines().count(), 6);

    assert!(matches!(
        core.export_playlist_file("999999".into(), txt.to_string_lossy().into_owned(), PlaylistFileFormat::Txt),
        Err(FfiError::NotFound { .. })
    ));
}

#[test]
fn details_lookups_waveform_and_artwork_cross_the_bridge() {
    use rbl_db::fixture::{self, track_id, Shape};
    let dir = tempfile::tempdir().unwrap();
    let location = fixture::build(dir.path(), Shape::default()).unwrap();
    let anlz = location.share_root.join("PIONEER/USBANLZ/ab/ANLZ0000.DAT");
    std::fs::create_dir_all(anlz.parent().unwrap()).unwrap();
    let bands: Vec<u8> = (0..300u32).map(|i| u8::try_from(i % 100).unwrap()).collect();
    std::fs::write(&anlz, rbl_anlz::AnlzBuilder::new().waveform_preview(b"PWAV", &[7; 400]).finish()).unwrap();
    std::fs::write(anlz.with_extension("2EX"), rbl_anlz::AnlzBuilder::new().waveform_scroll(b"PWV6", 3, &bands).finish()).unwrap();
    fixture::set_analysis_path(&location, 1, "/PIONEER/USBANLZ/ab/ANLZ0000.DAT").unwrap();
    let art = location.share_root.join("PIONEER/Artwork/1/a.jpg");
    std::fs::create_dir_all(art.parent().unwrap()).unwrap();
    std::fs::write(&art, b"\xFF\xD8x").unwrap();
    fixture::set_image_path(&location, 2, "/PIONEER/Artwork/1/a.jpg").unwrap();
    fixture::set_image_path(&location, 3, "/PIONEER/../../x.jpg").unwrap();

    let core = Core::with_fixture(Arc::new(Recorder::default()), dir.path().to_string_lossy().into_owned());
    assert_eq!(core.load_library(), LoadOutcome::Ready);

    let d = core.track_details(track_id(2)).unwrap();
    assert_eq!(d.title, "Track 002");
    assert!(d.has_artwork);
    assert!(matches!(core.track_details("0".into()), Err(FfiError::NotFound { .. })));
    let lookups = core.track_lookups().unwrap();
    assert!(lookups.genres.windows(2).all(|w| w[0].to_lowercase() <= w[1].to_lowercase()));

    assert_eq!(core.waveform(track_id(1), rbl_ffi::WaveformKind::Bands).unwrap(), bands);
    assert_eq!(core.waveform(track_id(1), rbl_ffi::WaveformKind::Mono).unwrap(), vec![7; 400]);
    assert!(core.waveform(track_id(1), rbl_ffi::WaveformKind::Colour).unwrap().is_empty());
    assert!(core.waveform(track_id(0), rbl_ffi::WaveformKind::Bands).unwrap().is_empty());

    assert_eq!(core.artwork(track_id(2)).unwrap(), b"\xFF\xD8x");
    assert!(core.artwork(track_id(0)).is_none());
    assert!(core.artwork(track_id(3)).is_none());
}
