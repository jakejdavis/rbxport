#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::assert_is_empty, clippy::similar_names)]

use std::sync::{Arc, Mutex};

use rbl_db::fixture::playlist_id;
use rbl_ffi::{
    Core, EventListener, ExtraColumn, FfiError, LibraryEvent, LoadOutcome, NodeKind, SearchField, SortKey,
    AnalysisSettings, BpmFilter, CueSlot, ExportOptions, ExportState, GridEdit, KeyDisplay, StickOverview, PlaylistFileFormat, StickDefaults,
    SyncState, TrackFilter, TrackSource, ViewSpec, WaveformColor, WaveformPosition, MAX_ROWS,
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

#[test]
fn editing_is_locked_by_default_and_opens_with_the_protection_setting() {
    let (_dir, core, events) = core();
    assert!(core.summary().unwrap().read_only, "Library Protection is on by default");
    let refusal = core.write_refusal().unwrap();
    assert!(refusal.starts_with("Editing is locked by Library Protection"));
    let err = core.create_playlist("Nope".into(), "root".into()).unwrap_err();
    assert!(matches!(err, FfiError::ReadOnly { ref message, .. } if *message == refusal));
    assert_eq!(events.0.lock().unwrap().len(), 1, "a refusal emits nothing");

    core.set_protect_library(false);
    assert!(!core.summary().unwrap().read_only);
    assert!(core.write_refusal().is_none());
    let id = core.create_playlist("Fresh".into(), "root".into()).unwrap();
    let tree = core.playlist_tree().unwrap();
    assert!(tree.iter().any(|n| n.id == id && n.name == "Fresh"));
    let tracks = vec![rbl_db::fixture::track_id(1), rbl_db::fixture::track_id(2)];
    assert_eq!(core.add_tracks_to_playlist(id.clone(), tracks.clone()).unwrap(), 2);
    let history = core.rename_playlist(id.clone(), "Renamed".into()).unwrap();
    assert!(history.can_undo);
    assert_eq!(history.undo_label.as_deref(), Some("Rename Playlist"));
    let history = core.undo().unwrap();
    assert!(history.can_redo && !history.can_undo);
    assert!(core.playlist_tree().unwrap().iter().any(|n| n.name == "Fresh"));
    assert!(matches!(core.move_playlist("nope".into(), "root".into(), None), Err(FfiError::Malformed { .. })));
    let seen = events.0.lock().unwrap();
    assert!(seen.iter().any(|e| matches!(e, LibraryEvent::EditHistoryChanged { .. })));
    assert!(seen.iter().any(|e| matches!(e, LibraryEvent::LibraryChanged { .. })));
}

#[test]
fn metadata_edits_validate_emit_and_undo_over_the_bridge() {
    use rbl_ffi::TrackField;
    let (_dir, core, events) = core();
    let t = vec![rbl_db::fixture::track_id(1)];
    assert!(matches!(core.set_track_rating(t.clone(), 3), Err(FfiError::ReadOnly { .. })));
    core.set_protect_library(false);
    let history = core.set_track_rating(t.clone(), 3).unwrap();
    assert_eq!(history.undo_label.as_deref(), Some("Track Edit"));
    assert_eq!(core.track_details(t[0].clone()).unwrap().rating, 3);
    assert!(matches!(core.set_track_rating(t.clone(), 6), Err(FfiError::Malformed { .. })));
    assert!(matches!(core.set_track_color(t.clone(), 9), Err(FfiError::Malformed { .. })));
    core.set_track_color(t.clone(), 4).unwrap();
    core.set_track_comment(t.clone(), "hello".into()).unwrap();
    core.set_track_field(t.clone(), TrackField::Year, "2001".into()).unwrap();
    let d = core.track_details(t[0].clone()).unwrap();
    assert_eq!((d.color.as_str(), d.comment.as_str(), d.year), ("4", "hello", 2001));
    let err = core.set_track_field(t.clone(), TrackField::Bpm, "20".into()).unwrap_err();
    assert!(matches!(err, FfiError::Malformed { ref message, .. } if message == "Enter a BPM from 40 to 499."));
    assert!(matches!(
        core.set_track_field(vec![t[0].clone(), rbl_db::fixture::track_id(2)], TrackField::Bpm, "128".into()),
        Err(FfiError::Malformed { .. })
    ));
    core.undo().unwrap();
    assert_eq!(core.track_details(t[0].clone()).unwrap().year, 0);

    core.add_to_tag_list(t.clone()).unwrap();
    core.remove_from_tag_list(t).unwrap();
    let seen = events.0.lock().unwrap();
    assert_eq!(seen.iter().filter(|e| matches!(e, LibraryEvent::TagListChanged { .. })).count(), 2);
}

#[test]
fn files_import_with_progress_and_missing_files_relocate_over_the_bridge() {
    let (dir, core, events) = core();
    core.set_protect_library(false);
    let audio = dir.path().join("incoming");
    std::fs::create_dir_all(&audio).unwrap();
    // A small genuine WAV copied from nowhere real: generated here.
    let data_len = 44_100_u32 * 2;
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&44_100_u32.to_le_bytes());
    wav.extend_from_slice(&88_200_u32.to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.resize(44 + data_len as usize, 0);
    std::fs::write(audio.join("one.wav"), &wav).unwrap();

    let report = core.import_files(vec![audio.display().to_string()]).unwrap();
    assert_eq!((report.imported, report.tracks.len(), report.existing.len()), (1, 1, 0));
    assert_eq!(core.summary().unwrap().track_count, 41);
    let progress = events.0.lock().unwrap().iter().filter(|e| matches!(e, LibraryEvent::ImportProgress { .. })).count();
    assert_eq!(progress, 1);
    let again = core.import_files(vec![audio.display().to_string()]).unwrap();
    assert_eq!((again.imported, again.existing.len()), (0, 1));

    let missing = core.missing_tracks(10).unwrap();
    assert_eq!((missing.total, missing.tracks.len()), (40, 10));
    let found = audio.join("track000.mp3");
    std::fs::write(&found, b"x").unwrap();
    let relocated = core.auto_relocate(vec![audio.display().to_string()]).unwrap();
    assert_eq!((relocated.relocated, relocated.unresolved), (1, 39));
    core.relocate_track(rbl_db::fixture::track_id(1), found.display().to_string()).unwrap();
    assert_eq!(core.missing_tracks(1).unwrap().total, 38);
    assert_eq!(core.find_duplicates(5).unwrap().groups, 0);
    core.remove_from_collection(vec![rbl_db::fixture::track_id(2)]).unwrap();
    assert_eq!(core.summary().unwrap().track_count, 40);
}

/// A mono 16-bit WAV with a click every half second.
#[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
fn click_wav(path: &std::path::Path, seconds: u32) {
    let rate = 22_050_u32;
    let period = rate / 2;
    let mut data = Vec::new();
    for i in 0..rate * seconds {
        let since = i % period;
        let sample: i16 = if since < 400 { (20_000.0 * (1.0 - since as f32 / 400.0)) as i16 } else { 0 };
        data.extend_from_slice(&sample.to_le_bytes());
    }
    let len = data.len() as u32;
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&(36 + len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    for v in [16_u32.to_le_bytes().as_slice(), &1_u16.to_le_bytes(), &1_u16.to_le_bytes(), &rate.to_le_bytes(), &(rate * 2).to_le_bytes(), &2_u16.to_le_bytes(), &16_u16.to_le_bytes()] {
        out.extend_from_slice(v);
    }
    out.extend_from_slice(b"data");
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&data);
    std::fs::write(path, out).unwrap();
}

#[test]
fn analysis_cues_grid_and_plays_pass_the_gate_over_the_bridge() {
    let (dir, core, events) = core();
    let track = rbl_db::fixture::track_id(5);
    let wav = dir.path().join("click.wav");
    click_wav(&wav, 12);
    let location = rbl_db::LibraryLocation {
        master_db: dir.path().join("master.db"),
        share_root: dir.path().join("share"),
        passphrase: rbl_db::fixture::FIXTURE_PASSPHRASE.to_owned(),
        is_real_install: false,
    };
    rbl_db::fixture::point_at_audio(&location, 5, wav.to_str().unwrap(), 12).unwrap();
    assert_eq!(core.load_library(), LoadOutcome::Ready);
    assert!(core.is_fixture_library());
    let settings = AnalysisSettings { bpm_grid: true, key: true, high_precision: true, min_bpm: 70.0, max_bpm: 180.0 };

    // Every write is refused while Library Protection is on, and nothing is announced.
    let before = events.0.lock().unwrap().len();
    assert!(matches!(core.analyse_track(track.clone(), settings, false), Err(FfiError::ReadOnly { .. })));
    assert!(matches!(core.add_cue(track.clone(), CueSlot::Memory, 1_000), Err(FfiError::ReadOnly { .. })));
    assert!(matches!(core.grid_lock(track.clone(), true), Err(FfiError::ReadOnly { .. })));
    assert!(matches!(core.record_play(track.clone()), Err(FfiError::ReadOnly { .. })));
    assert_eq!(events.0.lock().unwrap().len(), before);

    core.set_protect_library(false);
    let result = core.analyse_track(track.clone(), settings, false).unwrap();
    assert!(result.bpm_x100 > 0 && result.beats > 0);
    assert!(events.0.lock().unwrap().iter().any(|e| matches!(e, LibraryEvent::AnalysisChanged { track_id } if *track_id == track)));
    core.load_library();
    assert!(!core.track_beats(track.clone()).unwrap().is_empty());

    let hot = core.add_cue(track.clone(), CueSlot::Hot { letter: "B".into() }, 2_000).unwrap();
    core.add_cue(track.clone(), CueSlot::Memory, 4_000).unwrap();
    core.set_cue_colour(hot.clone(), Some(49)).unwrap();
    assert!(matches!(core.add_cue(track.clone(), CueSlot::Hot { letter: "Z".into() }, 1), Err(FfiError::Malformed { .. })));
    assert_eq!(core.track_cues(track.clone()).unwrap().len(), 2);
    core.delete_cue(hot).unwrap();
    assert_eq!(core.track_cues(track.clone()).unwrap().len(), 1);
    assert!(events.0.lock().unwrap().iter().any(|e| matches!(e, LibraryEvent::CuesChanged { .. })));

    let first = core.track_beats(track.clone()).unwrap()[0].time_ms;
    let state = core.grid_edit(track.clone(), GridEdit::Nudge { ms: 5 }, None, None).unwrap();
    assert!(state.can_undo && !state.locked);
    assert_ne!(core.track_beats(track.clone()).unwrap()[0].time_ms, first);
    let state = core.grid_undo(track.clone()).unwrap();
    assert!(state.can_redo);
    assert_eq!(core.track_beats(track.clone()).unwrap()[0].time_ms, first);
    assert!(core.grid_lock(track.clone(), true).unwrap().locked);
    assert!(matches!(core.grid_edit(track.clone(), GridEdit::Double, None, None), Err(FfiError::ReadOnly { .. })));

    core.record_play(track.clone()).unwrap();
}

fn stick_options(eject: bool) -> ExportOptions {
    ExportOptions {
        defaults: StickDefaults {
            waveform_color: WaveformColor::ThreeBand,
            waveform_position: WaveformPosition::Center,
            overview_waveform: StickOverview::Half,
            key_display: KeyDisplay::Classic,
        },
        delete_unlisted_music: false,
        compatibility: None,
        eject_after_sync: eject,
    }
}

/// Sticks here are temp directories and fake volumes; nothing real is exported to or ejected.
#[test]
fn devices_export_sync_and_settings_work_over_the_bridge_on_fake_sticks() {
    let (dir, core, events) = core();
    core.set_protect_library(false);
    let audio = dir.path().join("incoming");
    std::fs::create_dir_all(&audio).unwrap();
    click_wav(&audio.join("one.wav"), 2);
    click_wav(&audio.join("two.wav"), 2);
    let imported = core.import_files(vec![audio.display().to_string()]).unwrap();
    let ids: Vec<String> = imported.tracks.iter().map(|t| t.id.clone()).collect();
    let playlist = core.create_playlist("Gig".into(), "root".into()).unwrap();
    core.add_tracks_to_playlist(playlist.clone(), ids.clone()).unwrap();

    let sticks = tempfile::tempdir().unwrap();
    let (one, two) = (sticks.path().join("ONE"), sticks.path().join("TWO"));
    std::fs::create_dir_all(&one).unwrap();
    std::fs::create_dir_all(&two).unwrap();
    std::env::set_var("RB_LITE_FAKE_VOLUMES", format!("{}:{}", one.display(), two.display()));
    let devices = core.list_devices().unwrap();
    assert_eq!(devices.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(), ["ONE", "TWO"]);
    assert!(devices.iter().all(|d| d.export.is_none()));

    assert!(core.validate_export_files(vec![playlist.clone()]).unwrap().is_empty());
    let (one_path, two_path) = (one.display().to_string(), two.display().to_string());
    let report = core.export_playlist_to_device(playlist.clone(), one_path.clone(), stick_options(false)).unwrap();
    assert_eq!((report.tracks, report.playlists, report.verified), (2, 1, true));
    let seen = events.0.lock().unwrap().clone();
    let states: Vec<ExportState> = seen.iter().filter_map(|e| match e {
        LibraryEvent::ExportProgress { progress } if progress.path == one_path => Some(progress.state),
        _ => None,
    }).collect();
    assert_eq!(states.first(), Some(&ExportState::Preparing));
    assert_eq!(states.last(), Some(&ExportState::Done));
    assert!(matches!(seen.last(), Some(LibraryEvent::ExportDone { report: r }) if r.tracks == 2));
    assert_eq!(core.export_progress().iter().find(|p| p.path == one_path).unwrap().state, ExportState::Done);

    // The listing now says the stick holds our export; the panel's settings read the stick.
    let listed = core.list_devices().unwrap();
    assert_eq!(listed[0].export.as_ref().map(|e| (e.tracks, e.ours)), Some((2, true)));
    let settings = core.device_settings(one_path.clone()).unwrap();
    assert!(settings.has_device_library && settings.has_dev_setting);
    assert_eq!(settings.waveform_color, WaveformColor::ThreeBand);
    let mut edited = settings.clone();
    edited.waveform_color = WaveformColor::Rgb;
    edited.device_name = "GIG STICK".into();
    let saved = core.save_device_settings(one_path.clone(), edited).unwrap();
    assert_eq!(saved.waveform_color, WaveformColor::Rgb);
    assert_eq!(saved.device_name, "GIG STICK");

    // A sync to both: SyncProgress goes writing -> done for each, and the selection comes back.
    events.0.lock().unwrap().clear();
    let reports = core.sync_devices(vec![playlist.clone()], vec![one_path.clone(), two_path.clone()], stick_options(true)).unwrap();
    assert!(reports.iter().all(|r| r.error.is_none() && r.report.as_ref().is_some_and(|x| x.verified)));
    assert!(reports.iter().all(|r| !r.ejected), "a temp dir is not a volume the OS will eject");
    let sync: Vec<(String, SyncState)> = events.0.lock().unwrap().iter().filter_map(|e| match e {
        LibraryEvent::SyncProgress { progress } => Some((progress.path.clone(), progress.state)),
        _ => None,
    }).collect();
    for path in [&one_path, &two_path] {
        let mine: Vec<SyncState> = sync.iter().filter(|(p, _)| p == path).map(|(_, s)| *s).collect();
        assert_eq!(mine.first(), Some(&SyncState::Writing));
        assert_eq!(mine.last(), Some(&SyncState::Done));
    }
    let verified = core.verify_device(two_path.clone()).unwrap();
    assert!(verified.ok && verified.tracks == 2);
    let state = core.device_sync_state(two_path.clone()).unwrap();
    assert_eq!(state.selected.len(), 1);
    assert_eq!(state.on_device, ["Gig"]);
    assert!(!state.automatic);

    // Import back from the stick: refused while Library Protection is on, counted when it is off.
    core.set_protect_library(true);
    assert!(matches!(core.import_usb(two_path.clone(), true, true, true), Err(FfiError::ReadOnly { .. })));
    core.set_protect_library(false);
    events.0.lock().unwrap().clear();
    let imported_back = core.import_usb(two_path.clone(), true, true, false).unwrap();
    assert_eq!(imported_back.tracks + imported_back.skipped, 2, "both tracks matched by identity; neither is analysed here");
    assert!(events.0.lock().unwrap().iter().any(|e| matches!(e, LibraryEvent::ImportProgress { .. })));
    assert!(core.import_usb("/nonexistent-rbxport-stick".into(), false, true, false).is_err());

    // Eject: refused while a job is in flight is covered in rbl-app; here, a non-volume is refused.
    assert!(core.eject_device(one_path).is_err());
    // The watcher starts once however often it is asked (its events are covered in rbl-app).
    core.start_device_watcher();
    core.start_device_watcher();
    std::env::remove_var("RB_LITE_FAKE_VOLUMES");
}

#[test]
fn itunes_libraries_are_browsed_read_only_and_imported_through_the_gate() {
    let (dir, core, events) = core();
    // A fixture library never looks in the real Music folder.
    assert!(core.itunes_default_library().unwrap().is_none());
    let wav = dir.path().join("Song.wav");
    click_wav(&wav, 2);
    let xml = dir.path().join("Library.xml");
    std::fs::write(&xml, format!(
        r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Tracks</key><dict>
<key>1</key><dict><key>Track ID</key><integer>1</integer><key>Name</key><string>Song</string><key>Artist</key><string>Ann</string><key>Location</key><string>file://localhost{}</string></dict>
</dict><key>Playlists</key><array>
<dict><key>Name</key><string>Sets</string><key>Playlist Persistent ID</key><string>F1</string><key>Folder</key><true/></dict>
<dict><key>Name</key><string>Warm</string><key>Playlist Persistent ID</key><string>P1</string><key>Parent Persistent ID</key><string>F1</string><key>Playlist Items</key><array><dict><key>Track ID</key><integer>1</integer></dict></array></dict>
</array></dict></plist>"#, wav.display())).unwrap();
    let path = xml.display().to_string();
    let library = core.itunes_library_at(path.clone()).unwrap();
    assert_eq!(library.tree.iter().map(|n| (n.name.as_str(), n.is_folder, n.depth)).collect::<Vec<_>>(), [("Sets", true, 0), ("Warm", false, 1)]);
    let tracks = core.itunes_playlist_tracks(path.clone(), "itunes:1".into()).unwrap();
    assert_eq!((tracks.len(), tracks[0].title.as_str()), (1, "Song"));
    assert_eq!(core.summary().unwrap().track_count, 40, "browsing writes nothing");

    core.set_protect_library(true);
    assert!(matches!(core.import_itunes_selected(path.clone(), vec!["itunes:1".into()]), Err(FfiError::ReadOnly { .. })));
    core.set_protect_library(false);
    let report = core.import_itunes_selected(path.clone(), vec!["itunes:1".into()]).unwrap();
    assert_eq!((report.imported, report.playlists, report.existing), (1, 2, 0));
    assert_eq!(core.summary().unwrap().track_count, 41);
    assert!(events.0.lock().unwrap().iter().any(|e| matches!(e, LibraryEvent::ImportProgress { .. })));
    let again = core.import_itunes_selected(path, vec!["itunes:1".into()]).unwrap();
    assert_eq!((again.imported, again.existing), (0, 1));
}

/// Prepares a fixture directory for the manual screenshot run: a 40 s click track on the first
/// track, ready to analyse. Run with `RBXPORT_PREP_DIR=<empty temp dir> cargo test -p rbl-ffi
/// --test bridge prepare_demo_fixture -- --ignored`. Refuses anything but a fixture.
#[test]
#[ignore = "manual fixture preparation"]
fn prepare_demo_fixture() {
    let dir = std::path::PathBuf::from(std::env::var("RBXPORT_PREP_DIR").expect("RBXPORT_PREP_DIR"));
    let location = rbl_db::fixture::build(&dir, rbl_db::fixture::Shape::default()).unwrap();
    assert!(!location.is_real_install);
    let wav = dir.join("demo-click.wav");
    click_wav(&wav, 40);
    rbl_db::fixture::point_at_audio(&location, 0, wav.to_str().unwrap(), 40).unwrap();
}

/// Prepares a fixture directory for the Phase 5a screenshot run: the first playlist's five
/// tracks point at short real WAVs, so an export has audio to copy. Run with
/// `RBXPORT_PREP_DIR=<empty temp dir> cargo test -p rbl-ffi --test bridge prepare_devices_fixture -- --ignored`.
#[test]
#[ignore = "manual fixture preparation"]
fn prepare_devices_fixture() {
    let dir = std::path::PathBuf::from(std::env::var("RBXPORT_PREP_DIR").expect("RBXPORT_PREP_DIR"));
    let location = rbl_db::fixture::build(&dir, rbl_db::fixture::Shape::default()).unwrap();
    assert!(!location.is_real_install);
    for index in 0..5 {
        let wav = dir.join(format!("demo-track-{index}.wav"));
        click_wav(&wav, 6);
        rbl_db::fixture::point_at_audio(&location, index, wav.to_str().unwrap(), 6).unwrap();
    }
}
