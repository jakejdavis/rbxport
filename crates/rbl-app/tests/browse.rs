//! The browse functions, headless: a fixture library, no window, a recording sink.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Mutex;

use rbl_app::dto::{LibraryProblemDto, ViewSpecDto};
use rbl_app::state::AppState;
use rbl_app::{browse, startup, AppEvent, ErrorKind, EventSink};
use rbl_db::fixture::{self, Shape};
use rbl_db::{Library as Db, OpenMode};

#[derive(Default)]
struct Recorder(Mutex<Vec<(&'static str, String)>>);

impl EventSink for Recorder {
    fn emit(&self, event: AppEvent) {
        self.0.lock().unwrap().push((event.name(), serde_json::to_string(&event).unwrap()));
    }
}

fn loaded() -> (tempfile::TempDir, AppState) {
    let dir = tempfile::tempdir().unwrap();
    let location = fixture::build(dir.path(), Shape::default()).expect("build the fixture");
    let state = AppState::with_backups(dir.path().join("backups"));
    let db = Db::open(location.clone(), OpenMode::ReadOnly).expect("open the fixture");
    let (library, _) = rbl_index::load(&db).expect("index the fixture");
    state.set_library(library, false, db.schema().db_version, 0, location);
    (dir, state)
}

fn collection() -> ViewSpecDto {
    serde_json::from_str(r#"{"source":{"kind":"collection"},"sort":"title","descending":false,"query":""}"#).unwrap()
}

#[test]
fn summary_tree_view_and_rows() {
    let (_dir, state) = loaded();

    let summary = browse::library_summary(&state).unwrap();
    assert_eq!(summary.track_count, 40);
    assert_eq!(summary.playlist_count, 3);

    let tree = browse::playlist_tree(&state).unwrap();
    assert_eq!(tree[0].id, "all");
    assert!(tree.len() > 3);

    let handle = browse::open_view(&state, &collection()).unwrap();
    assert_eq!(handle.len, 40);

    let rows = browse::fetch_rows(&state, handle.view_id, 0, 10, &[]).unwrap();
    assert_eq!(rows.len(), 10);
    let ids = browse::view_ids_in_range(&state, handle.view_id, 0, 9).unwrap();
    assert_eq!(ids, rows.iter().map(|r| r.id.clone()).collect::<Vec<_>>());

    let too_many = browse::fetch_rows(&state, handle.view_id, 0, browse::MAX_ROWS + 1, &[]).unwrap_err();
    assert_eq!(too_many.kind, ErrorKind::Malformed);
}

#[test]
fn nothing_loaded_is_an_error_not_a_panic() {
    let state = AppState::new();
    assert!(browse::library_summary(&state).is_err());
    assert!(browse::playlist_tree(&state).is_err());
}

#[test]
fn a_problem_is_kept_and_announced() {
    let state = AppState::new();
    let sink = Recorder::default();
    startup::report_problem(&state, &sink, LibraryProblemDto::Failed { message: "no".into() });
    assert_eq!(state.library_problem(), Some(LibraryProblemDto::Failed { message: "no".into() }));
    let seen = sink.0.lock().unwrap();
    assert_eq!(seen.as_slice(), [("library:problem", r#"{"kind":"failed","message":"no"}"#.to_owned())]);
}
