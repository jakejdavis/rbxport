//! The object Swift holds: the app core's state plus where to load it from.

use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use rbl_app::dto::LibraryProblemDto;
use rbl_app::error::run_command;
use rbl_app::state::AppState;
use rbl_app::{analysis, browse, cues, itunes, usb_import, details, device_settings, devices, edits, explorer, export, grid, import, maintenance, media, startup, track_data, track_edits, AppError, AppEvent, AppResult, EventSink};
use rbl_db::{Library as Db, LibraryLocation, OpenMode};

use crate::error::FfiError;
use crate::devices::{ItunesLibrary, ItunesTrack, UsbImportReport, DeviceSettings, DeviceSyncState, ExportOptions, ExportProgress, ExportReport, MissingExportFile, SyncDeviceReport, VerifyReport};
use crate::events::{EventListener, ListenerSink};
use crate::playback::{Playback, PlaybackListener};
use crate::types::{
    AnalysisResult, AnalysisSettings, Beat, Cue, CueSlot, GridEdit, GridState, Phrase, EditHistory, SmartRule, TrackField, ImportReport, XmlImportReport, MissingTracks, Duplicates, RelocateReport, Device, ExplorerChildren, ExplorerRoot, ExtraColumn, FilterValues, LibraryProblem, PlaylistFileFormat, LibrarySummary, LoadOutcome, Row, TrackDetails, TrackLookups, TreeNode, ViewHandle, ViewSpec, WaveformKind,
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
    /// Grid histories and analysis backups, beside the library backups.
    editor: Arc<grid::GridEditor>,
    sink: ListenerSink,
    listener: Arc<dyn EventListener>,
    /// Raises `DevicesChanged` while it lives; started by `start_device_watcher`.
    watcher: std::sync::Mutex<Option<rbl_app::devices::MountWatcher>>,
    source: Source,
}

fn ffi<T>(name: &str, f: impl FnOnce() -> AppResult<T>) -> Result<T, FfiError> {
    run_command(name, AssertUnwindSafe(f)).map_err(FfiError::from)
}

impl Core {
    fn grid_action(&self, track_id: &str, action: grid::GridAction, options: &grid::GridOptions) -> Result<GridState, FfiError> {
        ffi("grid_edit", || {
            grid::run(&self.state, &self.editor, &self.sink, track_id, action, options)
        })
        .map(|outcome| outcome.state.into())
    }

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
        // Reads are read-only; edits open a writer per edit, behind `rbl_app::edits`' gate.
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
        let state = Arc::new(AppState::new());
        state.enable_native_gate();
        let editor = Arc::new(grid::GridEditor::new());
        Arc::new(Self {
            state,
            editor,
            sink: ListenerSink(Arc::clone(&listener)),
            listener,
            watcher: std::sync::Mutex::new(None),
            source: Source::Installed { cache_dir: cache_dir.map(PathBuf::from) },
        })
    }

    /// A core over a fixture library in `dir`, for tests and previews.
    #[uniffi::constructor]
    pub fn with_fixture(listener: Arc<dyn EventListener>, dir: String) -> Arc<Self> {
        let dir = PathBuf::from(dir);
        let state = Arc::new(AppState::with_backups(dir.join("backups")));
        state.enable_native_gate();
        let editor = Arc::new(grid::GridEditor::at(&dir));
        Arc::new(Self {
            state,
            editor,
            sink: ListenerSink(Arc::clone(&listener)),
            listener,
            watcher: std::sync::Mutex::new(None),
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

    // ---- Phase 5a: devices, export, sync, device settings. Only ever write to a stick.

    /// Starts watching for volumes arriving and leaving; each change raises `DevicesChanged`.
    /// Safe to call again. Honours `RB_LITE_FAKE_VOLUMES` (the watcher reads the same list).
    pub fn start_device_watcher(&self) {
        let mut slot = self.watcher.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if slot.is_none() {
            *slot = Some(devices::start_mount_watcher(Arc::new(ListenerSink(Arc::clone(&self.listener)))));
        }
    }

    /// Ejects a volume. Refused while an export to it is running or finishing.
    pub fn eject_device(&self, path: String) -> Result<(), FfiError> {
        ffi("eject_device", || export::eject_device(&path))
    }

    /// Reads a stick's settings; a stick that holds nothing answers with defaults and no flags.
    pub fn device_settings(&self, path: String) -> Result<DeviceSettings, FfiError> {
        ffi("device_settings", || Ok(device_settings::device_settings(&path))).map(Into::into)
    }

    /// Writes a stick's settings and returns what it now holds.
    pub fn save_device_settings(&self, path: String, settings: DeviceSettings) -> Result<DeviceSettings, FfiError> {
        ffi("save_device_settings", || device_settings::save_device_settings(&path, &settings.into())).map(Into::into)
    }

    /// Writes a playlist to a stick. Blocking; raises `ExportProgress` then `ExportDone`.
    pub fn export_playlist_to_device(
        &self,
        playlist_id: String,
        destination: String,
        options: ExportOptions,
    ) -> Result<ExportReport, FfiError> {
        let defaults = options.defaults.into();
        ffi("export_playlist_to_device", || {
            export::export_playlist(
                &self.state, &self.sink, &playlist_id, &destination, Some(&defaults),
                options.delete_unlisted_music, options.compatibility.map(Into::into),
            )
        })
        .map(Into::into)
    }

    /// Export Track: puts tracks on a stick in no playlist. Blocking.
    pub fn export_tracks_to_device(
        &self,
        track_ids: Vec<String>,
        destination: String,
        options: ExportOptions,
    ) -> Result<ExportReport, FfiError> {
        let defaults = options.defaults.into();
        ffi("export_tracks_to_device", || {
            export::export_tracks_to_device(
                &self.state, &self.sink, &track_ids, &destination, Some(&defaults), options.compatibility.map(Into::into),
            )
        })
        .map(Into::into)
    }

    /// Writes the same playlists to every destination at once; one failing does not stop the rest.
    /// Blocking; raises `SyncProgress` and each stick's `ExportProgress`. Never turns on "automatic".
    pub fn sync_devices(
        &self,
        playlist_ids: Vec<String>,
        destinations: Vec<String>,
        options: ExportOptions,
    ) -> Result<Vec<SyncDeviceReport>, FfiError> {
        let defaults = options.defaults.into();
        let sync = export::SyncOptions {
            automatic: false,
            eject_after_sync: options.eject_after_sync,
            delete_unlisted_music: options.delete_unlisted_music,
            compatibility_format: options.compatibility.map(Into::into),
        };
        ffi("sync_devices", || export::sync_devices(&self.state, &self.sink, &playlist_ids, destinations, Some(&defaults), &sync))
            .map(|reports| reports.into_iter().map(Into::into).collect())
    }

    /// Tracks of these playlists whose audio file is gone; no stick is touched.
    pub fn validate_export_files(&self, playlist_ids: Vec<String>) -> Result<Vec<MissingExportFile>, FfiError> {
        ffi("validate_export_files", || export::validate_export_files(&self.state, &playlist_ids))
            .map(|files| files.into_iter().map(Into::into).collect())
    }

    /// What a stick was last synced with and what it holds. Blocking (reads the stick).
    pub fn device_sync_state(&self, path: String) -> Result<DeviceSyncState, FfiError> {
        ffi("device_sync_state", || export::device_sync_state(&self.state, &path)).map(Into::into)
    }

    /// Reads a stick back with the independent parser. Read-only; blocking.
    pub fn verify_device(&self, path: String) -> Result<VerifyReport, FfiError> {
        ffi("verify_device", || export::verify_device(&path)).map(Into::into)
    }

    /// Asks the export to a stick to stop (between tracks, before publishing).
    pub fn cancel_export(&self, path: String) {
        export::cancel_export(&path);
    }

    /// Every export's latest progress, for a UI that starts late.
    pub fn export_progress(&self) -> Vec<ExportProgress> {
        export::export_progress().into_iter().map(Into::into).collect()
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

    /// A track's beat grid, `PQTZ` offset applied. Empty without an analysis.
    pub fn track_beats(&self, track_id: String) -> Result<Vec<Beat>, FfiError> {
        ffi("track_beats", || track_data::track_beats(&self.state, &track_id))
            .map(|beats| beats.into_iter().map(Into::into).collect())
    }

    /// A track's hot cues, memory cues and loops, read fresh from the library.
    pub fn track_cues(&self, track_id: String) -> Result<Vec<Cue>, FfiError> {
        ffi("track_cues", || track_data::track_cues(&self.state, &track_id))
            .map(|cues| cues.into_iter().map(Into::into).collect())
    }

    /// A track's phrases, resolved to times.
    pub fn track_phrases(&self, track_id: String) -> Result<Vec<Phrase>, FfiError> {
        ffi("track_phrases", || track_data::track_phrases(&self.state, &track_id))
            .map(|phrases| phrases.into_iter().map(Into::into).collect())
    }

    /// Where a voice was heard: one intensity byte per 46.44 ms.
    pub fn track_vocals(&self, track_id: String) -> Result<Vec<u8>, FfiError> {
        ffi("track_vocals", || track_data::track_vocals(&self.state, &track_id, None, None))
    }

    /// The decks and the preview player, reporting to `listener`. Make one and
    /// keep it. Honours `RBXPORT_NULL_AUDIO=1` (silent output, no device).
    pub fn playback(&self, listener: Arc<dyn PlaybackListener>) -> Arc<Playback> {
        Arc::new(Playback::new(Arc::clone(&self.state), listener))
    }

    /// A track's artwork image file, or `None` (no artwork, missing file, refused path, over 8 MiB).
    pub fn artwork(&self, track_id: String) -> Option<Vec<u8>> {
        media::artwork_bytes(&self.state, &track_id)
    }

    // ---- the write gate and edits. Every one goes through `rbl_app::edits`.

    /// Library Protection, as the app's setting stands. On by default (as in the
    /// React app); turning it off is the only way the gate opens for a fixture.
    pub fn set_protect_library(&self, protect: bool) {
        self.state.set_protect_library(protect);
    }

    /// True when the loaded library is a generated fixture (never the installed one).
    /// Developer hooks that write refuse to run unless this holds.
    pub fn is_fixture_library(&self) -> bool {
        self.state.location().is_ok_and(|l| !l.is_real_install)
    }

    /// Why editing is locked right now (the message to show), or `None` when it is not.
    pub fn write_refusal(&self) -> Option<String> {
        self.state.write_gate().map(|r| r.message().to_owned())
    }

    /// The undo/redo state and labels as they stand.
    pub fn edit_history(&self) -> EditHistory {
        edits::edit_history(&self.state).into()
    }

    pub fn undo(&self) -> Result<EditHistory, FfiError> {
        ffi("undo", || edits::undo(&self.state, &self.sink)).map(Into::into)
    }

    pub fn redo(&self) -> Result<EditHistory, FfiError> {
        ffi("redo", || edits::redo(&self.state, &self.sink)).map(Into::into)
    }

    /// Makes a playlist under `parent` (`"root"` for the top level); returns its id.
    pub fn create_playlist(&self, name: String, parent: String) -> Result<String, FfiError> {
        ffi("create_playlist", || edits::create_playlist(&self.state, &self.sink, &name, &parent))
    }

    pub fn create_folder(&self, name: String, parent: String) -> Result<String, FfiError> {
        ffi("create_folder", || edits::create_folder(&self.state, &self.sink, &name, &parent))
    }

    pub fn create_smart_playlist(&self, name: String, parent: String, rule: SmartRule) -> Result<String, FfiError> {
        ffi("create_smart_playlist", || edits::create_smart_playlist(&self.state, &self.sink, &name, &parent, &rule.into()))
    }

    /// A smart playlist's rule, for the editor.
    pub fn smart_rule(&self, playlist_id: String) -> Result<SmartRule, FfiError> {
        ffi("smart_rule", || edits::smart_rule(&self.state, &playlist_id)).map(Into::into)
    }

    /// Saves a smart playlist's rule and name in one step.
    pub fn save_smart_playlist(&self, playlist_id: String, name: String, rule: SmartRule) -> Result<EditHistory, FfiError> {
        ffi("save_smart_playlist", || edits::save_smart_playlist(&self.state, &self.sink, &playlist_id, &name, &rule.into()))
            .map(Into::into)
    }

    pub fn rename_playlist(&self, id: String, name: String) -> Result<EditHistory, FfiError> {
        ffi("rename_playlist", || edits::rename_playlist(&self.state, &self.sink, &id, &name)).map(Into::into)
    }

    /// Moves under `parent` at `index` among its children (`None`: the end).
    pub fn move_playlist(&self, id: String, parent: String, index: Option<u32>) -> Result<EditHistory, FfiError> {
        ffi("move_playlist", || edits::move_playlist(&self.state, &self.sink, &id, &parent, index.map(|i| i as usize)))
            .map(Into::into)
    }

    pub fn delete_playlist(&self, id: String) -> Result<EditHistory, FfiError> {
        ffi("delete_playlist", || edits::delete_playlist(&self.state, &self.sink, &id)).map(Into::into)
    }

    /// Sort Items: a folder's children by name, as one undo step.
    pub fn sort_children(&self, parent: String) -> Result<EditHistory, FfiError> {
        ffi("sort_children", || edits::sort_children(&self.state, &self.sink, &parent)).map(Into::into)
    }

    /// Appends tracks; returns how many were new to the playlist.
    pub fn add_tracks_to_playlist(&self, playlist_id: String, track_ids: Vec<String>) -> Result<u32, FfiError> {
        ffi("add_tracks_to_playlist", || edits::add_tracks_to_playlist(&self.state, &self.sink, &playlist_id, &track_ids))
    }

    pub fn remove_tracks_from_playlist(&self, playlist_id: String, track_ids: Vec<String>) -> Result<EditHistory, FfiError> {
        ffi("remove_tracks_from_playlist", || {
            edits::remove_tracks_from_playlist(&self.state, &self.sink, &playlist_id, &track_ids)
        })
        .map(Into::into)
    }

    /// Sets the playlist's full track order.
    pub fn reorder_playlist(&self, playlist_id: String, track_ids: Vec<String>) -> Result<(), FfiError> {
        ffi("reorder_playlist", || edits::reorder_playlist(&self.state, &self.sink, &playlist_id, &track_ids)).map(|_| ())
    }

    // ---- Phase 4b: track metadata, Tag List, history, collection, import, missing files.

    /// Stars 0 to 5 on every track, as one undo step. More than 5 is `Malformed`.
    pub fn set_track_rating(&self, track_ids: Vec<String>, stars: u8) -> Result<EditHistory, FfiError> {
        ffi("set_track_rating", || track_edits::set_rating(&self.state, &self.sink, &track_ids, stars)).map(Into::into)
    }

    pub fn set_track_comment(&self, track_ids: Vec<String>, comment: String) -> Result<EditHistory, FfiError> {
        ffi("set_track_comment", || track_edits::set_comment(&self.state, &self.sink, &track_ids, &comment)).map(Into::into)
    }

    /// Colour 1 to 8, or 0 for none. Anything else is `Malformed`.
    pub fn set_track_color(&self, track_ids: Vec<String>, color: u8) -> Result<EditHistory, FfiError> {
        ffi("set_track_color", || track_edits::set_color_id(&self.state, &self.sink, &track_ids, color)).map(Into::into)
    }

    /// Writes an Info-tab field on every track. `Bpm` takes exactly one track and is not undoable.
    pub fn set_track_field(&self, track_ids: Vec<String>, field: TrackField, value: String) -> Result<EditHistory, FfiError> {
        ffi("set_track_field", || {
            if field == TrackField::Bpm {
                return match track_ids.as_slice() {
                    [one] => track_edits::set_bpm(&self.state, &self.sink, one, &value),
                    _ => Err(AppError::new(rbl_app::ErrorKind::Malformed, "Select a single track to change its BPM.")),
                };
            }
            track_edits::set_field(&self.state, &self.sink, &track_ids, field.wire(), &value)
        })
        .map(Into::into)
    }

    /// Returns the new generation.
    pub fn add_to_tag_list(&self, track_ids: Vec<String>) -> Result<u32, FfiError> {
        ffi("add_to_tag_list", || track_edits::add_to_tag_list(&self.state, &self.sink, &track_ids))
    }

    pub fn remove_from_tag_list(&self, track_ids: Vec<String>) -> Result<u32, FfiError> {
        ffi("remove_from_tag_list", || track_edits::remove_from_tag_list(&self.state, &self.sink, &track_ids))
    }

    /// Reload Tag: the file's tags read again over each track's row.
    pub fn reload_tags(&self, track_ids: Vec<String>) -> Result<u32, FfiError> {
        ffi("reload_tags", || track_edits::reload_tags(&self.state, &self.sink, &track_ids))
    }

    pub fn reset_play_count(&self, track_ids: Vec<String>) -> Result<EditHistory, FfiError> {
        ffi("reset_play_count", || track_edits::reset_play_count(&self.state, &self.sink, &track_ids)).map(Into::into)
    }

    pub fn remove_from_history(&self, history_id: String, track_ids: Vec<String>) -> Result<u32, FfiError> {
        ffi("remove_from_history", || track_edits::remove_from_history(&self.state, &self.sink, &history_id, &track_ids))
    }

    /// Permanent: the undo history is cleared. The files stay on disk.
    pub fn remove_from_collection(&self, track_ids: Vec<String>) -> Result<u32, FfiError> {
        ffi("remove_from_collection", || track_edits::remove_from_collection(&self.state, &self.sink, &track_ids))
    }

    /// Imports files and folders. Blocking; raises `ImportProgress` per file.
    pub fn import_files(&self, paths: Vec<String>) -> Result<ImportReport, FfiError> {
        ffi("import_files", || import::import_files(&self.state, &self.sink, &paths)).map(Into::into)
    }

    /// Imports a rekordbox XML collection. Blocking; raises `ImportProgress` per track.
    pub fn import_xml(&self, path: String) -> Result<XmlImportReport, FfiError> {
        ffi("import_xml", || import::import_xml(&self.state, &self.sink, &path)).map(Into::into)
    }

    // ---- Phase 5b: import from a stick, and the iTunes / Music library. Behind the write gate.

    /// Brings cues and beat grids, play history and/or CDJ/mixer settings from a stick into the
    /// library. Blocking; raises `ImportProgress`, then `LibraryChanged`, `GridChanged`, `CuesChanged`.
    pub fn import_usb(&self, path: String, cues: bool, history: bool, settings: bool) -> Result<UsbImportReport, FfiError> {
        ffi("import_usb", || usb_import::import_usb(&self.state, &self.editor, &self.sink, &path, cues, history, settings)).map(Into::into)
    }

    /// The iTunes / Music library at its usual place under the Music folder, or `None`.
    /// Never looks while a fixture library is loaded.
    pub fn itunes_default_library(&self) -> Result<Option<ItunesLibrary>, FfiError> {
        if self.is_fixture_library() {
            return Ok(None);
        }
        ffi("itunes_default_library", || match dirs::audio_dir() {
            Some(music) => itunes::default_library(&music),
            None => Ok(None),
        })
        .map(|l| l.map(Into::into))
    }

    /// Reads the iTunes / Music library XML at `path`. Read-only.
    pub fn itunes_library_at(&self, path: String) -> Result<ItunesLibrary, FfiError> {
        ffi("itunes_library_at", || itunes::library_at(&path)).map(Into::into)
    }

    /// The tracks of one iTunes playlist (`itunes:<index>`), in order.
    pub fn itunes_playlist_tracks(&self, path: String, node_id: String) -> Result<Vec<ItunesTrack>, FfiError> {
        ffi("itunes_playlist_tracks", || itunes::playlist_tracks(&path, &node_id)).map(|t| t.into_iter().map(Into::into).collect())
    }

    /// Imports the chosen playlists (`itunes:<index>`), the folders above them and their tracks.
    /// Blocking; raises `ImportProgress` per track.
    pub fn import_itunes_selected(&self, path: String, ids: Vec<String>) -> Result<XmlImportReport, FfiError> {
        ffi("import_itunes_selected", || itunes::import_selected(&self.state, &self.sink, &path, &ids)).map(Into::into)
    }

    /// Tracks whose file is gone, bounded to `limit` (the count is exact).
    pub fn missing_tracks(&self, limit: u32) -> Result<MissingTracks, FfiError> {
        ffi("missing_tracks", || maintenance::missing_tracks(&self.state, limit)).map(Into::into)
    }

    pub fn find_duplicates(&self, limit: u32) -> Result<Duplicates, FfiError> {
        ffi("find_duplicates", || maintenance::find_duplicates(&self.state, limit)).map(Into::into)
    }

    /// Points a track at another file.
    pub fn relocate_track(&self, track_id: String, path: String) -> Result<u32, FfiError> {
        ffi("relocate_track", || track_edits::relocate_track(&self.state, &self.sink, &track_id, &path))
    }

    /// Points every missing track at a same-named file under the folders. Blocking.
    pub fn auto_relocate(&self, folders: Vec<String>) -> Result<RelocateReport, FfiError> {
        ffi("auto_relocate", || maintenance::auto_relocate(&self.state, &self.sink, &folders)).map(Into::into)
    }

    // ---- Phase 4c: cues, beat grid, analysis, play history. All behind the write gate.

    /// Adds a cue at a position; returns its id.
    pub fn add_cue(&self, track_id: String, slot: CueSlot, position_ms: u32) -> Result<String, FfiError> {
        ffi("add_cue", || cues::add_cue(&self.state, &self.sink, &track_id, slot.into(), position_ms))
    }

    /// Adds a loop (a cue with an out point); `beats` is 0 when unknown.
    pub fn add_loop(&self, track_id: String, slot: CueSlot, in_ms: u32, out_ms: u32, beats: u16) -> Result<String, FfiError> {
        ffi("add_loop", || cues::add_loop(&self.state, &self.sink, &track_id, slot.into(), in_ms, out_ms, beats))
    }

    pub fn move_cue(&self, cue_id: String, position_ms: u32) -> Result<(), FfiError> {
        ffi("move_cue", || cues::move_cue(&self.state, &self.sink, &cue_id, position_ms))
    }

    /// A hot cue takes a colour-table index; a memory cue its named index 0 to 7; `None` resets.
    pub fn set_cue_colour(&self, cue_id: String, colour: Option<u8>) -> Result<(), FfiError> {
        ffi("set_cue_colour", || cues::set_cue_colour(&self.state, &self.sink, &cue_id, colour))
    }

    pub fn delete_cue(&self, cue_id: String) -> Result<(), FfiError> {
        ffi("delete_cue", || cues::delete_cue(&self.state, &self.sink, &cue_id))
    }

    /// Memory cues become hot cues in the free slots; returns how many.
    pub fn convert_memory_cues_to_hot(&self, track_id: String) -> Result<u32, FfiError> {
        ffi("convert_memory_cues_to_hot", || cues::convert_memory_cues_to_hot(&self.state, &self.sink, &track_id))
    }

    /// The track's grid tempo, beat count, session undo state and lock.
    pub fn grid_state(&self, track_id: String) -> Result<GridState, FfiError> {
        ffi("grid_state", || grid::grid_state(&self.state, &self.editor, &track_id)).map(Into::into)
    }

    /// One grid edit; `from_ms` limits it to the beats from there on. Blocking.
    pub fn grid_edit(&self, track_id: String, edit: GridEdit, from_ms: Option<u32>, transaction: Option<String>) -> Result<GridState, FfiError> {
        let options = grid::GridOptions { transaction, ..grid::GridOptions::default() };
        self.grid_action(&track_id, grid::GridAction::Edit { edit: edit.into(), from_ms }, &options)
    }

    pub fn grid_undo(&self, track_id: String) -> Result<GridState, FfiError> {
        self.grid_action(&track_id, grid::GridAction::Undo, &grid::GridOptions::default())
    }

    pub fn grid_redo(&self, track_id: String) -> Result<GridState, FfiError> {
        self.grid_action(&track_id, grid::GridAction::Redo, &grid::GridOptions::default())
    }

    /// Analysis lock on or off (a library write).
    pub fn grid_lock(&self, track_id: String, on: bool) -> Result<GridState, FfiError> {
        ffi("grid_lock", || grid::lock(&self.state, &self.editor, &self.sink, &track_id, on)).map(Into::into)
    }

    /// Analyses one track and keeps the result. Blocking (seconds): call off the main thread.
    /// `rekordbox_mode` selects the rekordbox preset instead of rbxport's.
    pub fn analyse_track(&self, track_id: String, settings: AnalysisSettings, rekordbox_mode: bool) -> Result<AnalysisResult, FfiError> {
        let mode = if rekordbox_mode { "rekordbox" } else { "rbxport" };
        ffi("analyse_track", || {
            analysis::analyse_track(&self.state, &self.editor, &self.sink, &track_id, Some(mode), &settings.into())
        })
        .map(Into::into)
    }

    /// Re-reads the whole library once, after a run of analyses. Returns the generation.
    pub fn reload_library(&self) -> Result<u32, FfiError> {
        ffi("reload_library", || edits::reload(&self.state, &self.sink))
    }

    /// Records a play: today's history session and the play count. Returns the generation.
    pub fn record_play(&self, track_id: String) -> Result<u32, FfiError> {
        ffi("record_play", || track_edits::record_play(&self.state, &self.sink, &track_id))
    }
}
