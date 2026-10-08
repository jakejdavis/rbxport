//! Loading the library at launch.
//!
//! Read-only always: this application never opens the user's library for
//! writing during startup, and `rbl-db` refuses it while rekordbox runs.

use std::path::{Path, PathBuf};

use crate::dto::LibraryProblemDto;
use crate::events::{AppEvent, EventSink};
use crate::state::AppState;
use crate::{backups, file_journal};

/// How a load ended. The details have already reached the state and the sink.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadOutcome {
    /// The library is in the state and `library:ready` was emitted.
    Ready,
    /// It is not; `library:problem` was emitted and the state keeps why.
    Problem,
}

/// The schema version as a plain number, so a library whose schema changed
/// never reads a snapshot built against the old one.
fn schema_key(db_version: Option<i64>) -> u32 {
    db_version.and_then(|v| u32::try_from(v).ok()).unwrap_or(0)
}

/// Keeps why the library did not load, for a window that asks later, and
/// tells a window already listening.
pub fn report_problem(state: &AppState, sink: &dyn EventSink, problem: LibraryProblemDto) {
    state.set_library_problem(Some(problem.clone()));
    sink.emit(AppEvent::LibraryProblem(problem));
}

/// Recovers any interrupted backup or file journal, then loads the installed
/// library read-only into `state`. Blocking: call it off the UI thread.
///
/// `cache_dir` is where the library snapshot lives: under the app's own
/// directory, not the library's, because it is derived and ours. `None`
/// disables the snapshot.
pub fn load_library(state: &AppState, cache_dir: Option<&Path>, sink: &dyn EventSink) -> LoadOutcome {
    let started = std::time::Instant::now();
    if let Ok(location) = rbl_db::detect() {
        if let Err(e) = backups::recover(state.backup_dir(), &location) {
            report_problem(state, sink, LibraryProblemDto::Failed { message: e.to_string() });
            return LoadOutcome::Problem;
        }
    }
    let cache_path: Option<PathBuf> = cache_dir.map(|dir| dir.join("library.snapshot"));
    let snapshot = cache_path.clone().and_then(|path| {
        std::thread::Builder::new().name("startup-snapshot".into())
            .spawn(move || rbl_index::cache::prepare(&path)).ok()
    });
    match rbl_db::Library::open_installed_read_only() {
        Ok(db) => load_opened(state, &db, cache_path.as_deref(), snapshot, started, sink),
        Err(e) => {
            // Nothing to open, as against something that would not open:
            // offered as a new library rather than reported as a failure.
            if let Ok(Some(plan)) = rbl_db::new_library::plan() {
                tracing::info!(path = %plan.master_db.display(), error = %e, "no library here; offering to make one");
                report_problem(state, sink, LibraryProblemDto::Missing {
                    master_db: plan.master_db.display().to_string(),
                });
                return LoadOutcome::Problem;
            }
            tracing::error!(error = %e, "could not open the library");
            report_problem(state, sink, LibraryProblemDto::Failed { message: e.to_string() });
            LoadOutcome::Problem
        }
    }
}

fn load_opened(
    state: &AppState,
    db: &rbl_db::Library,
    cache_path: Option<&Path>,
    snapshot: Option<std::thread::JoinHandle<Option<rbl_index::cache::Prepared>>>,
    started: std::time::Instant,
    sink: &dyn EventSink,
) -> LoadOutcome {
    if let Err(e) = file_journal::recover(state.backup_dir(), db.location()) {
        tracing::error!(error = %e, "analysis recovery failed");
        report_problem(state, sink, LibraryProblemDto::Failed { message: e.to_string() });
        return LoadOutcome::Problem;
    }
    let db_version = db.schema().db_version;
    let location = db.location().clone();
    let master_db = db.location().master_db.clone();
    // Reading 38,681 rows out of SQLCipher is 543 ms of the 680 ms
    // a start costs, and none of it gets faster — the work is the
    // decryption. A snapshot of the built columns turns the same
    // start into a sequential read.
    // Content rather than file times: rekordbox rewrites the WAL
    // without changing a row, and keying on that refused the
    // snapshot on every start it was running for.
    let content = rbl_index::content_version(db).ok();
    let fingerprint = cache_path.and_then(|_| {
        rbl_index::cache::Fingerprint::of(&master_db, schema_key(db_version), content?)
    });
    let prepared = snapshot.and_then(|job| job.join().ok()).flatten();
    if let Some(fp) = fingerprint {
        if let Some(library) = prepared.and_then(|snapshot| snapshot.validated(fp)) {
            let load_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            tracing::debug!(tracks = library.len(), load_ms, "library from cache");
            let read_only = rbl_db::is_rekordbox_running();
            state.set_library(library, read_only, db_version, load_ms, location);
            sink.emit(AppEvent::LibraryReady);
            return LoadOutcome::Ready;
        }
    }
    // A second read-only handle allows cues to overlap metadata.
    // Failure falls back to the single-connection loader.
    let cue_reader = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).ok();
    match rbl_index::load_with_cue_reader(db, cue_reader) {
        Ok((library, counts)) => {
            let load_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            tracing::debug!(
                tracks = counts.tracks,
                playlists = counts.playlists,
                heap_mb = counts.heap_bytes / 1_048_576,
                load_ms,
                "library loaded"
            );
            // Writes are gated on rekordbox not running, which we
            // re-check per transaction; the banner reflects it now.
            let read_only = rbl_db::is_rekordbox_running();
            state.set_library(library, read_only, db_version, load_ms, location);
            sink.emit(AppEvent::LibraryReady);

            // Written after the interface is live, and only if the
            // database has not moved since the fingerprint was
            // taken — rekordbox may have written while we read,
            // and a snapshot of a half-read library keyed to bytes
            // that no longer exist would be served on a later
            // start as though it were current.
            if let (Some(path), Some(before)) = (cache_path, fingerprint) {
                let after = rbl_index::content_version(db).ok().and_then(|now| {
                    rbl_index::cache::Fingerprint::of(&master_db, schema_key(db_version), now)
                });
                if after == Some(before) {
                    if let Ok(library) = state.library() {
                        if let Err(e) = rbl_index::cache::save(path, &library, before) {
                            tracing::warn!(error = %e, "could not write the library cache");
                        }
                    }
                }
            }
            LoadOutcome::Ready
        }
        Err(e) => {
            tracing::error!(error = %e, "could not index the library");
            report_problem(state, sink, LibraryProblemDto::Failed { message: e.to_string() });
            LoadOutcome::Problem
        }
    }
}
