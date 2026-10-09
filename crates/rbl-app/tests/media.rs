//! Details, lookups, waveform bytes and artwork against a fixture library.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::assert_is_empty)]

use rbl_anlz::AnlzBuilder;
use rbl_app::media::{artwork_bytes, artwork_file, resolve_under, track_waveform, ArtworkError, MAX_ARTWORK_BYTES};
use rbl_app::state::AppState;
use rbl_app::{details, ErrorKind};
use rbl_db::fixture::{self, track_id, Shape};
use rbl_db::{Library as Db, LibraryLocation, OpenMode};

fn build() -> (tempfile::TempDir, LibraryLocation) {
    let dir = tempfile::tempdir().unwrap();
    let location = fixture::build(dir.path(), Shape::default()).expect("build the fixture");
    (dir, location)
}

fn load(location: &LibraryLocation, dir: &std::path::Path) -> AppState {
    let state = AppState::with_backups(dir.join("backups"));
    let db = Db::open(location.clone(), OpenMode::ReadOnly).expect("open the fixture");
    let (library, _) = rbl_index::load(&db).expect("index the fixture");
    state.set_library(library, false, db.schema().db_version, 0, location.clone());
    state
}

#[test]
fn details_and_lookups_read_the_fixture() {
    let (dir, location) = build();
    let state = load(&location, dir.path());
    let d = details::track_details(&state, &track_id(7)).unwrap();
    assert_eq!(d.id, track_id(7));
    assert_eq!(d.title, "Track 007");
    assert!(!d.has_artwork);

    let missing = details::track_details(&state, "999999").unwrap_err();
    assert_eq!(missing.kind, ErrorKind::NotFound);

    let lookups = details::track_lookups(&state).unwrap();
    // The fixture has no keys or genres; the lists are still well-formed.
    assert!(lookups.my_tag_categories.iter().all(|c| !c.name.is_empty()));
    let mut sorted = lookups.genres.clone();
    sorted.sort_by_key(|g| g.to_lowercase());
    assert_eq!(sorted, lookups.genres);
}

#[test]
fn waveform_is_empty_without_analysis_and_filled_with_it() {
    let (dir, location) = build();
    // No analysis path: the empty case.
    let state = load(&location, dir.path());
    assert!(track_waveform(&state, &track_id(1), "bands", None, None).unwrap().is_empty());
    assert_eq!(track_waveform(&state, "nope", "bands", None, None).unwrap_err().kind, ErrorKind::Malformed);

    // Author a .DAT (mono) and a .2EX (bands) and point track 1 at them.
    let anlz = location.share_root.join("PIONEER/USBANLZ/ab/ANLZ0000.DAT");
    std::fs::create_dir_all(anlz.parent().unwrap()).unwrap();
    let mono: Vec<u8> = (0..400u32).map(|i| u8::try_from(i % 32).unwrap() | 0xE0).collect();
    std::fs::write(&anlz, AnlzBuilder::new().waveform_preview(b"PWAV", &mono).finish()).unwrap();
    let bands: Vec<u8> = (0..1200u32 * 3).map(|i| u8::try_from(i % 100).unwrap()).collect();
    std::fs::write(anlz.with_extension("2EX"), AnlzBuilder::new().waveform_scroll(b"PWV6", 3, &bands).finish()).unwrap();
    fixture::set_analysis_path(&location, 1, "/PIONEER/USBANLZ/ab/ANLZ0000.DAT").unwrap();

    let state = load(&location, dir.path());
    assert_eq!(track_waveform(&state, &track_id(1), "mono", None, None).unwrap(), mono);
    assert_eq!(track_waveform(&state, &track_id(1), "bands", None, None).unwrap(), bands);
    // The colour sibling was not written: empty, not an error.
    assert!(track_waveform(&state, &track_id(1), "colour", None, None).unwrap().is_empty());
}

#[test]
fn artwork_present_absent_and_refused() {
    let (dir, location) = build();
    let art = location.share_root.join("PIONEER/Artwork/00001/a1.jpg");
    std::fs::create_dir_all(art.parent().unwrap()).unwrap();
    std::fs::write(&art, b"\xFF\xD8jpeg").unwrap();
    fixture::set_image_path(&location, 2, "/PIONEER/Artwork/00001/a1.jpg").unwrap();
    fixture::set_image_path(&location, 3, "/PIONEER/../../outside.jpg").unwrap();
    std::fs::write(dir.path().join("outside.jpg"), b"secret").unwrap();
    let big = location.share_root.join("PIONEER/Artwork/big.jpg");
    std::fs::File::create(&big).unwrap().set_len(MAX_ARTWORK_BYTES + 1).unwrap();
    fixture::set_image_path(&location, 4, "/PIONEER/Artwork/big.jpg").unwrap();
    fixture::set_image_path(&location, 5, "/PIONEER/Artwork/gone.jpg").unwrap();

    let state = load(&location, dir.path());
    assert_eq!(artwork_bytes(&state, &track_id(2)).unwrap(), b"\xFF\xD8jpeg");
    assert!(details::track_details(&state, &track_id(2)).unwrap().has_artwork);
    assert!(artwork_bytes(&state, &track_id(0)).is_none());
    assert_eq!(artwork_file(&state, &track_id(0)), Err(ArtworkError::NotFound));
    assert_eq!(artwork_file(&state, &track_id(3)), Err(ArtworkError::Refused));
    assert!(artwork_bytes(&state, &track_id(3)).is_none());
    assert_eq!(artwork_file(&state, &track_id(4)), Err(ArtworkError::TooLarge));
    // A file that is gone cannot be canonicalised, so it is refused like an escape (as the protocol always did).
    assert_eq!(artwork_file(&state, &track_id(5)), Err(ArtworkError::Refused));
}

#[test]
fn paths_that_climb_out_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("share")).unwrap();
    for attempt in ["../../../etc/passwd", "/PIONEER/../../etc/passwd", "..\\..\\Windows\\System32"] {
        assert!(resolve_under(&dir.path().join("share"), attempt).is_none(), "{attempt}");
    }
}

#[test]
fn a_relative_path_resolves_under_the_root() {
    let dir = tempfile::tempdir().unwrap();
    let nested = dir.path().join("PIONEER/Artwork/abc");
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::write(nested.join("artwork.jpg"), b"x").unwrap();
    let got = resolve_under(dir.path(), "/PIONEER/Artwork/abc/artwork.jpg").unwrap();
    assert!(got.ends_with("artwork.jpg"));
}

#[cfg(unix)]
#[test]
fn a_symlink_out_of_the_share_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let share = dir.path().join("share");
    std::fs::create_dir_all(&share).unwrap();
    std::fs::write(dir.path().join("secret.jpg"), b"s").unwrap();
    std::os::unix::fs::symlink(dir.path().join("secret.jpg"), share.join("link.jpg")).unwrap();
    assert!(resolve_under(&share, "/link.jpg").is_none());
}
