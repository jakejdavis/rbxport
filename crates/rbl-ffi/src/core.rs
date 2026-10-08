//! The object Swift holds: the app core's state plus where to load it from.

use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use rbl_app::dto::LibraryProblemDto;
use rbl_app::error::run_command;
use rbl_app::state::AppState;
use rbl_app::{browse, startup, AppError, AppEvent, AppResult, EventSink};
use rbl_db::{Library as Db, LibraryLocation, OpenMode};

use crate::error::FfiError;
use crate::events::{EventListener, ListenerSink};
use crate::types::{
    LibraryProblem, LibrarySummary, LoadOutcome, Row, TreeNode, ViewHandle, ViewSpec,
};

/// Where `load_library` gets the library from.
enum Source {
    /// The installed rekordbox library, with the snapshot cache under this dir.
    Installed { cache_dir: Option<PathBuf> },
    /// A fixture library in this directory (built first if it has none).
    Fixture { dir: PathBuf },
}

#[derive(uniffi::Object)]
pub struct Core {
    state: Arc<AppState>,
    sink: ListenerSink,
    source: Source,
}

fn ffi<T>(name: &str, f: impl FnOnce() -> AppResult<T>) -> Result<T, FfiError> {
    run_command(name, AssertUnwindSafe(f)).map_err(FfiError::from)
}

impl Core {
    fn load_fixture(&self, dir: &Path) -> AppResult<()> {
        let started = Instant::now();
        let internal = |what: &str, e: &dyn std::fmt::Display| AppError::internal(format!("{what}: {e}"));
        let master_db = dir.join("master.db");
        let location = if master_db.is_file() {
            LibraryLocation {
                master_db,
                share_root: dir.join("share"),
                passphrase: rbl_db::fixture::FIXTURE_PASSPHRASE.to_owned(),
                is_real_install: false,
            }
        } else {
            std::fs::create_dir_all(dir).map_err(|e| internal("cannot create the fixture dir", &e))?;
            rbl_db::fixture::build(dir, rbl_db::fixture::Shape::default())
                .map_err(|e| internal("cannot build the fixture", &e))?
        };
        // Read-only, always: this crate has no path that opens read-write.
        let db = Db::open(location.clone(), OpenMode::ReadOnly).map_err(|e| internal("cannot open", &e))?;
        let (library, _) = rbl_index::load(&db).map_err(|e| internal("cannot index", &e))?;
        let load_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        self.state.set_library(library, false, db.schema().db_version, load_ms, location);
        Ok(())
    }
}

#[uniffi::export]
#[allow(clippy::needless_pass_by_value)]
impl Core {
    /// A core over the installed rekordbox library (opened read-only by
    /// `load_library`). `cache_dir` holds the snapshot cache; `None` disables it.
    #[uniffi::constructor]
    pub fn new(listener: Arc<dyn EventListener>, cache_dir: Option<String>) -> Arc<Self> {
        Arc::new(Self {
            state: Arc::new(AppState::new()),
            sink: ListenerSink(listener),
            source: Source::Installed { cache_dir: cache_dir.map(PathBuf::from) },
        })
    }

    /// A core over a fixture library in `dir`, for tests and previews.
    #[uniffi::constructor]
    pub fn with_fixture(listener: Arc<dyn EventListener>, dir: String) -> Arc<Self> {
        let dir = PathBuf::from(dir);
        Arc::new(Self {
            state: Arc::new(AppState::with_backups(dir.join("backups"))),
            sink: ListenerSink(listener),
            source: Source::Fixture { dir },
        })
    }

    /// Recovers interrupted backups and journals, then loads the library
    /// read-only. Blocking: call it off the main thread. The outcome is also
    /// sent to the listener as `LibraryReady` or `LibraryProblem`.
    pub fn load_library(&self) -> LoadOutcome {
        match &self.source {
            Source::Installed { cache_dir } => {
                startup::load_library(&self.state, cache_dir.as_deref(), &self.sink).into()
            }
            Source::Fixture { dir } => match self.load_fixture(dir) {
                Ok(()) => {
                    self.sink.emit(AppEvent::LibraryReady);
                    LoadOutcome::Ready
                }
                Err(e) => {
                    startup::report_problem(&self.state, &self.sink, LibraryProblemDto::Failed { message: e.message });
                    LoadOutcome::Problem
                }
            },
        }
    }

    /// Why the last load failed, if it did.
    pub fn library_problem(&self) -> Option<LibraryProblem> {
        self.state.library_problem().map(Into::into)
    }

    pub fn summary(&self) -> Result<LibrarySummary, FfiError> {
        ffi("summary", || browse::library_summary(&self.state)).map(Into::into)
    }

    pub fn playlist_tree(&self) -> Result<Vec<TreeNode>, FfiError> {
        ffi("playlist_tree", || browse::playlist_tree(&self.state))
            .map(|nodes| nodes.into_iter().map(Into::into).collect())
    }

    pub fn open_view(&self, spec: ViewSpec) -> Result<ViewHandle, FfiError> {
        ffi("open_view", || browse::open_view(&self.state, &spec.into())).map(Into::into)
    }

    pub fn fetch_rows(&self, view_id: u32, offset: u32, len: u32) -> Result<Vec<Row>, FfiError> {
        ffi("fetch_rows", || browse::fetch_rows(&self.state, view_id, offset, len, &[]))
            .map(|rows| rows.into_iter().map(Into::into).collect())
    }

    /// Track ids at positions `from..=to` of a view, in view order.
    pub fn view_ids_in_range(&self, view_id: u32, from: u32, to: u32) -> Result<Vec<String>, FfiError> {
        ffi("view_ids_in_range", || browse::view_ids_in_range(&self.state, view_id, from, to))
    }
}

