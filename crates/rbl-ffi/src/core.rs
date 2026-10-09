//! The object Swift holds: the app core's state plus where to load it from.

use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use rbl_app::dto::LibraryProblemDto;
use rbl_app::error::run_command;
use rbl_app::state::AppState;
use rbl_app::{browse, details, explorer, media, startup, AppError, AppEvent, AppResult, EventSink};
use rbl_db::{Library as Db, LibraryLocation, OpenMode};

use crate::error::FfiError;
use crate::events::{EventListener, ListenerSink};
use crate::types::{
    Device, ExplorerChildren, ExplorerRoot, ExtraColumn, FilterValues, LibraryProblem, PlaylistFileFormat, LibrarySummary, LoadOutcome, Row, TrackDetails, TrackLookups, TreeNode, ViewHandle, ViewSpec, WaveformKind,
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

    /// One page of rows. `extra_columns` names the optional fields to fill in.
    pub fn fetch_rows(
        &self,
        view_id: u32,
        offset: u32,
        len: u32,
        extra_columns: Vec<ExtraColumn>,
    ) -> Result<Vec<Row>, FfiError> {
        let wanted: Vec<String> = extra_columns.iter().map(|c| c.wire().to_owned()).collect();
        ffi("fetch_rows", || browse::fetch_rows(&self.state, view_id, offset, len, &wanted))
            .map(|rows| rows.into_iter().map(Into::into).collect())
    }

    /// Track ids at positions `from..=to` of a view, in view order.
    pub fn view_ids_in_range(&self, view_id: u32, from: u32, to: u32) -> Result<Vec<String>, FfiError> {
        ffi("view_ids_in_range", || browse::view_ids_in_range(&self.state, view_id, from, to))
    }

    /// The BPMs and keys the filter bar offers for `spec`'s source and query.
    /// The spec's own filter is ignored: counts are over the unfiltered list.
    pub fn filter_values(&self, spec: ViewSpec) -> Result<FilterValues, FfiError> {
        ffi("filter_values", || browse::filter_values(&self.state, &spec.into())).map(Into::into)
    }

    /// Where the Explorer starts: music, home, the system volume, mounted volumes.
    pub fn explorer_roots(&self) -> Result<Vec<ExplorerRoot>, FfiError> {
        ffi("explorer_roots", || Ok(explorer::explorer_roots()))
            .map(|roots| roots.into_iter().map(Into::into).collect())
    }

    /// The folders directly under `path`, by name (capped); unreadable folders are empty.
    pub fn explorer_children(&self, path: String) -> Result<ExplorerChildren, FfiError> {
        ffi("explorer_children", || Ok(explorer::explorer_children(&path))).map(Into::into)
    }

    /// Mounted volumes an export could be written to. Reads each one; call when shown.
    pub fn list_devices(&self) -> Result<Vec<Device>, FfiError> {
        ffi("list_devices", || Ok(browse::list_devices())).map(|d| d.into_iter().map(Into::into).collect())
    }

    /// Writes a playlist to `path`; returns the track count written.
    pub fn export_playlist_file(
        &self,
        playlist_id: String,
        path: String,
        format: PlaylistFileFormat,
    ) -> Result<u32, FfiError> {
        let format = match format {
            PlaylistFileFormat::M3u8 => "m3u8",
            PlaylistFileFormat::Txt => "txt",
        };
        ffi("export_playlist_file", || browse::export_playlist_file(&self.state, &playlist_id, &path, format))
    }

    /// The audio file of a track (or a loose `file:` id), for Show in Finder.
    pub fn track_path(&self, track_id: String) -> Result<String, FfiError> {
        ffi("track_path", || browse::track_path(&self.state, &track_id))
    }

    /// One track in full. `NotFound` when the id is no longer in the library.
    pub fn track_details(&self, track_id: String) -> Result<TrackDetails, FfiError> {
        ffi("track_details", || details::track_details(&self.state, &track_id)).map(Into::into)
    }

    /// The lists the Info tab's dropdowns offer.
    pub fn track_lookups(&self) -> Result<TrackLookups, FfiError> {
        ffi("track_lookups", || details::track_lookups(&self.state)).map(Into::into)
    }

    /// A track's overview waveform for a palette; empty when it has no analysis.
    pub fn waveform(&self, track_id: String, kind: WaveformKind) -> Result<Vec<u8>, FfiError> {
        ffi("waveform", || media::track_waveform(&self.state, &track_id, kind.wire(), None, None))
    }

    /// A track's artwork image file, or `None` (no artwork, missing file, refused path, over 8 MiB).
    pub fn artwork(&self, track_id: String) -> Option<Vec<u8>> {
        media::artwork_bytes(&self.state, &track_id)
    }
}
