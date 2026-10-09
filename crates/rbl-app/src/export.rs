//! Exporting to a stick, syncing several, and ejecting one.
//!
//! The export itself is `rbl-export`'s; this builds the selection from the
//! library, writes it to each destination with progress events, and reads the
//! result back. None of it writes the library: only the destination.

use std::sync::Arc;

use crate::device_settings::StickDefaultsDto;
use crate::dto::{
    DeviceSyncStateDto, ExportProgressDto, ExportReportDto, MissingExportFileDto, SyncDeviceReportDto, SyncPlaylistDto,
    SyncProgressDto, VerifyReportDto,
};
use crate::edits::write_error;
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::{AppEvent, EventSink};
use crate::state::AppState;

/// The states of an export in flight. A device in any of them must not be ejected.
const ACTIVE_STATES: [&str; 8] =
    ["preparing", "checking", "copying", "database", "verifying", "publishing", "ejecting", "writing"];

/// Whether an export state means the device is being written to or ejected.
#[must_use]
pub fn is_active_state(state: &str) -> bool {
    ACTIVE_STATES.contains(&state)
}

/// The playlist names in a stick's `export.pdb`, in tree order, folders
/// left out. Empty when there is no export or it does not parse: a stick
/// that cannot be read holds nothing the window can name.
pub fn playlists_on_device(mount: &std::path::Path) -> Vec<String> {
    let pdb = rbl_devices::settings::export_root(mount).join("rekordbox/export.pdb");
    let Ok(bytes) = std::fs::read(&pdb) else { return Vec::new() };
    let Ok(parsed) = rbl_pdb::Pdb::parse(&bytes) else { return Vec::new() };
    let Some(table) = parsed.table(rbl_pdb::PageType::PlaylistTree) else { return Vec::new() };
    let mut nodes = parsed.playlist_nodes(table);
    nodes.sort_by_key(|node| (node.parent_id, node.sort_order));
    nodes.into_iter().filter(|node| !node.is_folder).map(|node| node.name).collect()
}

/// A My Tag row as the export takes it.
pub fn source_my_tag(tag: &rbl_db::export_info::MyTagRow) -> rbl_export::SourceMyTag {
    rbl_export::SourceMyTag {
        id: tag.id.parse().unwrap_or(0),
        seq: u32::try_from(tag.seq.max(0)).unwrap_or(u32::MAX),
        name: tag.name.clone(),
        attribute: u8::try_from(tag.attribute.clamp(0, 255)).unwrap_or(0),
        parent: tag.parent.parse().unwrap_or(0),
    }
}

/// What an export is asked to write: the tracks, the playlists that name
/// them by index, and the library's My Tags. Built once and written to as
/// many sticks as asked.
#[derive(Clone)]
pub struct ExportSelection {
    pub tracks: Vec<rbl_export::SourceTrack>,
    pub playlists: Vec<rbl_export::SourcePlaylist>,
    /// Every My Tag of the library, listed on the stick whole as rekordbox
    /// lists them.
    pub my_tags: Vec<rbl_export::SourceMyTag>,
    /// What the stick's sync record names: the library and its tree.
    pub sync: rbl_export::SyncSource,
    /// The library is a fixture, not the installed one: rekordbox cannot be
    /// holding it, so a running rekordbox is no reason to refuse the write.
    pub fixture: bool,
}

impl ExportSelection {
    /// The union of these playlists, each track read once however many of
    /// them hold it. Ids are the tree's numeric playlist ids. An intelligent
    /// playlist is exported as what its rule admits now, which is what
    /// rekordbox writes to a stick for one too.
    pub fn from_playlists(
        state: &AppState,
        library: &rbl_index::Library,
        share: &std::path::Path,
        playlist_ids: &[String],
        // Written into the stick's sync record: whether it is to be synced
        // again, on its own, when it is next plugged in.
        automatic: bool,
    ) -> AppResult<Self> {
        Self::from_playlists_and_tracks(state, library, share, playlist_ids, &[], automatic)
    }

    /// [`from_playlists`](Self::from_playlists) with tracks that go on the
    /// stick in no playlist: what Export Track put there, and what a
    /// stick's record says was put there before.
    pub fn from_playlists_and_tracks(
        state: &AppState,
        library: &rbl_index::Library,
        share: &std::path::Path,
        playlist_ids: &[String],
        loose: &[u64],
        automatic: bool,
    ) -> AppResult<Self> {
        let _editing = state.edit_gate.lock();
        let _analysis = state.analysis_write.lock();
        // Named first and read after: `source_rows` takes the playlists
        // itself, so the guard is let go before it is asked.
        let mut named: Vec<(u64, String, rbl_index::TrackSource)> = Vec::with_capacity(playlist_ids.len());
        {
            let playlists = library.playlists();
            for id in playlist_ids {
                let Some(index) = id.parse::<u64>().ok().and_then(|numeric| playlists.index_of(numeric)) else {
                    return Err(AppError::new(ErrorKind::NotFound, "That playlist is not in the library."));
                };
                let source = if playlists.is_smart(index) {
                    rbl_index::TrackSource::SmartPlaylist(index)
                } else {
                    rbl_index::TrackSource::Playlist(index)
                };
                named.push((playlists.ids.get(index).copied().unwrap_or(0), playlists.name(index).to_owned(), source));
            }
        }
        let rows_of: Vec<Vec<u32>> = named.iter().map(|(_, _, source)| library.source_rows(source)).collect();
        // A loose track the library no longer has is left off without a
        // word: the stick's record outlives the track.
        let loose_rows: Vec<u32> = loose.iter().filter_map(|&id| library.row_of_id(id)).collect();

        // What the index does not hold: the My Tags, and the other places a
        // cloud-synced file may be. One read for the whole selection.
        let ids: Vec<String> = rows_of
            .iter()
            .flatten()
            .chain(loose_rows.iter())
            .map(|&row| library.ids.get(row as usize).copied().unwrap_or(0).to_string())
            .collect();
        let (my_tags, extras, db_id) = state
            .read_db(|db| {
                let conn = db.connection();
                Ok((
                    rbl_db::export_info::my_tags(conn)?,
                    rbl_db::export_info::track_extras(conn, &ids)?,
                    rbl_db::export_info::db_id(conn)?,
                ))
            })
            .map_err(write_error)?;
        // The whole tree goes along; the record keeps the ticked playlists
        // and the folders above them.
        let tree = {
            let playlists = library.playlists();
            (0..playlists.len())
                .map(|index| rbl_export::SyncNode {
                    id: playlists.ids.get(index).copied().unwrap_or(0),
                    parent: match playlists.parent.get(index).copied() {
                        Some(parent) if parent != rbl_index::NO_ID => {
                            playlists.ids.get(parent as usize).copied().unwrap_or(0)
                        }
                        _ => 0,
                    },
                    attribute: playlists.attribute.get(index).copied().unwrap_or(0),
                })
                .collect()
        };
        let sync = rbl_export::SyncSource { db_id, tree, automatic };
        let my_tags: Vec<rbl_export::SourceMyTag> = my_tags.iter().map(source_my_tag).collect();

        let mut tracks: Vec<rbl_export::SourceTrack> = Vec::new();
        let mut position: std::collections::HashMap<u32, usize> = std::collections::HashMap::new();
        let mut source_playlists = Vec::with_capacity(named.len());
        for ((id, name, _), rows) in named.into_iter().zip(rows_of) {
            let mut track_indices = Vec::with_capacity(rows.len());
            for row in rows {
                let at = if let Some(at)=position.get(&row) { *at } else {
                    let content = library.ids.get(row as usize).copied().unwrap_or(0).to_string();
                    let extra = extras.get(&content).cloned().unwrap_or_default();
                    tracks.push(source_track(library, share, row, &extra)?);
                    let at=tracks.len()-1; position.insert(row,at); at
                };
                track_indices.push(at);
            }
            source_playlists.push(rbl_export::SourcePlaylist { device_id: 0, device_only: false, parent_id: 0, folder: false, id, name, track_indices });
        }
        for row in loose_rows {
            if let std::collections::hash_map::Entry::Vacant(entry) = position.entry(row) {
                let content = library.ids.get(row as usize).copied().unwrap_or(0).to_string();
                let extra = extras.get(&content).cloned().unwrap_or_default();
                tracks.push(source_track(library, share, row, &extra)?);
                entry.insert(tracks.len() - 1);
            }
        }
        // Include ancestors as actual folder rows in both USB databases.
        let tree_view = library.playlists();
        let mut ancestors = std::collections::BTreeSet::new();
        for p in &mut source_playlists {
            p.parent_id = sync.tree.iter().find(|n| n.id == p.id).map_or(0, |n| n.parent);
            let mut parent = p.parent_id;
            while parent != 0 && ancestors.insert(parent) {
                parent = sync.tree.iter().find(|n| n.id == parent).map_or(0, |n| n.parent);
            }
        }
        let mut folders = Vec::new();
        for id in ancestors {
            let Some(index) = tree_view.index_of(id) else { return Err(AppError::internal("Missing playlist ancestor")); };
            folders.push(rbl_export::SourcePlaylist { device_id: 0, device_only: false, id, name: tree_view.name(index).to_owned(), parent_id: sync.tree.iter().find(|n| n.id == id).map_or(0, |n| n.parent), folder: true, track_indices: Vec::new() });
        }
        folders.append(&mut source_playlists);
        source_playlists = folders;
        let fixture = state.location().is_ok_and(|location| !location.is_real_install);
        Ok(Self { tracks, playlists: source_playlists, my_tags, sync, fixture })
    }

    /// This selection with the loose tracks a stick's record names added,
    /// so a sync keeps what Export Track put there unless cleanup is enabled.
    /// Cleanup uses the playlist selection alone; the exporter removes only
    /// stale manifest-owned files after publishing the new databases. The selection itself
    /// when the record names none it does not already hold.
    pub fn for_stick<'a>(
        &'a self,
        state: &AppState,
        library: &rbl_index::Library,
        share: &std::path::Path,
        destination: &std::path::Path,
        delete_unlisted_music: bool,
    ) -> AppResult<std::borrow::Cow<'a, Self>> {
        if delete_unlisted_music {
            return Ok(std::borrow::Cow::Borrowed(self));
        }
        rbl_export::recover(destination).map_err(|e| AppError::internal(e.to_string()))?;
        let recorded = rbl_export::Manifest::load(destination).filter(|m| m.db_id == self.sync.db_id).map(|m| m.loose).unwrap_or_default();
        let held: std::collections::HashSet<u64> = self.tracks.iter().map(|t| t.id).collect();
        let missing: Vec<u64> = recorded.into_iter().filter(|id| !held.contains(id)).collect();
        if missing.is_empty() {
            return Ok(std::borrow::Cow::Borrowed(self));
        }
        let playlist_ids: Vec<String> = self.playlists.iter().filter(|p| !p.folder).map(|p| p.id.to_string()).collect();
        let loose: Vec<u64> = self
            .tracks
            .iter()
            .enumerate()
            .filter(|(index, _)| !self.playlists.iter().any(|p| p.track_indices.contains(index)))
            .map(|(_, t)| t.id)
            .chain(missing)
            .collect();
        Ok(std::borrow::Cow::Owned(Self::from_playlists_and_tracks(
            state,
            library,
            share,
            &playlist_ids,
            &loose,
            self.sync.automatic,
        )?))
    }
}

/// One library row as the export wants it, analysis read from the share
/// tree, and what the index does not hold from `extra`.
pub fn source_track(
    library: &rbl_index::Library,
    share: &std::path::Path,
    row: u32,
    extra: &rbl_db::export_info::TrackExtras,
) -> AppResult<rbl_export::SourceTrack> {
    let i = row as usize;
    // The library's own image, share-relative like the analysis.
    let artwork = Some(library.artwork_path.get(i))
        .filter(|p| !p.is_empty())
        .map(|p| share.join(p.trim_start_matches(['/', '\\'])));
    Ok(rbl_export::SourceTrack {
        cues: Some(extra.cues.clone()),
        metadata: extra.metadata.clone(),
        device: None,
        // The content id is how a second export to the same stick
        // recognises a track it has already written.
        id: library.ids.get(i).copied().unwrap_or(0),
        source_path: source_audio(library.folder_path.get(i), &extra.alternate_paths),
        artwork,
        my_tags: extra.my_tags.iter().filter_map(|t| t.parse().ok()).collect(),
        title: library.title.get(i).to_owned(),
        artist: library.artist_name(row).to_owned(),
        album: library.album_name(row).to_owned(),
        genre: library.genre_name(row).to_owned(),
        label: library.label_name(row).to_owned(),
        key: library.key_name(row).to_owned(),
        comment: library.comment.get(i).to_owned(),
        date_added: library.date_added.get(i).to_owned(),
        release_date: library.release_date.get(i).to_owned(),
        bpm_x100: library.bpm_x100.get(i).copied().unwrap_or(0),
        duration_sec: u16::try_from(library.length_sec.get(i).copied().unwrap_or(0)).unwrap_or(u16::MAX),
        rating: library.rating.get(i).copied().unwrap_or(0),
        color_id: library.color.get(i).copied().unwrap_or(0),
        bitrate: library.bitrate.get(i).copied().unwrap_or(0),
        sample_rate: library.sample_rate.get(i).copied().unwrap_or(0),
        file_size: library.file_size.get(i).copied().unwrap_or(0),
        year: library.year.get(i).copied().unwrap_or(0),
        analysis: read_analysis(share, library.analysis_path.get(i))?,
    })
}

/// Progress and cancel flags of the exports in flight, by destination.
static EXPORT_PROGRESS: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, ExportProgressDto>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));
static EXPORT_CANCEL: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, Arc<std::sync::atomic::AtomicBool>>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));

fn set_export_stage(sink: &dyn EventSink, destination: &std::path::Path, state: &'static str) {
    let path = destination.to_string_lossy().into_owned();
    let progress = if let Ok(mut jobs) = EXPORT_PROGRESS.lock() {
        if let Some(job) = jobs.get_mut(&path) {
            job.state = state;
            job.title.clear();
            Some(job.clone())
        } else {
            None
        }
    } else { None };
    if let Some(progress) = progress { sink.emit(AppEvent::ExportProgress(progress)); }
}

fn set_export_failure(
    sink: &dyn EventSink,
    destination: &std::path::Path,
    message: String,
) {
    let path = destination.to_string_lossy().into_owned();
    let progress = if let Ok(mut jobs) = EXPORT_PROGRESS.lock() {
        let job = jobs.entry(path.clone()).or_insert_with(|| ExportProgressDto {
            path,
            state: "failed",
            done: 0,
            total: 0,
            title: String::new(),
        });
        job.state = "failed";
        job.title = message;
        Some(job.clone())
    } else {
        None
    };
    if let Some(progress) = progress {
        sink.emit(AppEvent::ExportProgress(progress));
    }
}

fn write_export_with_progress(
    sink: &dyn EventSink,
    destination: &std::path::Path,
    selection: &ExportSelection,
    defaults: Option<&crate::device_settings::StickDefaultsDto>,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
) -> AppResult<ExportReportDto> {
    let total = u32::try_from(selection.tracks.len()).unwrap_or(u32::MAX);
    let path = destination.to_string_lossy().into_owned();
    let cancel = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let mut jobs = EXPORT_CANCEL.lock().map_err(|e| AppError::internal(e.to_string()))?;
        if jobs.contains_key(&path) {
            return Err(AppError::new(ErrorKind::Internal, "An export to this device is already running."));
        }
        // A new batch replaces terminal progress from the previous one. When
        // another job is active this export belongs to that same batch, so a
        // stick that finishes early remains in the aggregate denominator.
        if jobs.is_empty() {
            if let Ok(mut progress) = EXPORT_PROGRESS.lock() {
                progress.clear();
            }
        }
        jobs.insert(path.clone(), Arc::clone(&cancel));
    }
    let emit = |state, done, title: String| {
        let progress = ExportProgressDto {
            path: destination.to_string_lossy().into_owned(), state, done, total, title,
        };
        if let Ok(mut jobs) = EXPORT_PROGRESS.lock() {
            jobs.insert(progress.path.clone(), progress.clone());
        }
        sink.emit(AppEvent::ExportProgress(progress));
    };
    emit("preparing", 0, String::new());
    let done = std::cell::Cell::new(0);
    let result = write_export_with_phase(
        destination, selection, defaults, compatibility_format,
        &mut |p| {
            done.set(u32::try_from(p.done).unwrap_or(u32::MAX));
            emit(p.stage, done.get(), p.title.clone());
        },
        &mut |phase| emit(phase, if phase == "verifying" { total } else { done.get() }, String::new()),
        &|| cancel.load(std::sync::atomic::Ordering::Relaxed),
    );
    let cancelled = result.as_ref().err().is_some_and(|e| matches!(e.kind, ErrorKind::Cancelled));
    emit(if result.is_ok() { "done" } else if cancelled { "cancelled" } else { "failed" }, if result.is_ok() { total } else { done.get() },
        result.as_ref().err().map_or_else(String::new, |e| e.message.clone()));
    if let Ok(mut jobs) = EXPORT_CANCEL.lock() { jobs.remove(&path); }
    result
}

fn write_export_with_phase(
    destination: &std::path::Path,
    selection: &ExportSelection,
    defaults: Option<&crate::device_settings::StickDefaultsDto>,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
    progress: &mut dyn FnMut(&rbl_export::ExportProgress),
    phase: &mut dyn FnMut(&'static str),
    cancelled: &dyn Fn() -> bool,
) -> AppResult<ExportReportDto> {
    if !destination.is_dir() {
        return Err(AppError::new(
            ErrorKind::NotFound,
            "That device is no longer connected. It may have been unplugged or renamed.",
        ));
    }
    if !selection.fixture && rbl_db::is_rekordbox_running() {
        return Err(AppError::new(ErrorKind::Internal, "Quit rekordbox before syncing this USB so only one application writes its libraries."));
    }
    let preferred_root = rbl_devices::list()
        .into_iter()
        .find(|device| device.mount_point == destination)
        .and_then(|device| rbl_export::ExportRoot::for_file_system(&device.file_system));
    let root_name = rbl_export::export_root_name_with(destination, preferred_root)
        .map_err(|e| AppError::new(ErrorKind::Internal, e.to_string()))?;
    let export_root = destination.join(root_name);
    let settings_root = dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("rbxport/usb-settings");
    let imported_settings: Vec<_> = ["MYSETTING.DAT", "MYSETTING2.DAT", "DJMMYSETTING.DAT"].into_iter()
        .filter(|name| !export_root.join(name).exists())
        .filter_map(|name| std::fs::read(settings_root.join(name)).ok().map(|bytes| (name, bytes))).collect();
    let library_defaults = defaults.map(crate::device_settings::library_defaults);
    let report = rbl_export::export_cancellable(
        destination,
        &selection.tracks,
        &selection.playlists,
        &selection.my_tags,
        &rbl_export::ExportOptions {
            defaults: library_defaults.as_ref(),
            sync: Some(&selection.sync),
            compatibility: compatibility_format,
            root: preferred_root,
        },
        progress,
        cancelled,
    )
    .map_err(|e| AppError::new(if matches!(e, rbl_export::ExportError::Cancelled) { ErrorKind::Cancelled } else { ErrorKind::Internal }, e.to_string()))?;
    if let Some(defaults) = defaults {
        crate::device_settings::write_dev_defaults(destination, defaults)?;
    }

    for (name, bytes) in imported_settings {
        crate::durable::write(&export_root.join(name), &bytes).map_err(|e| AppError::internal(e.to_string()))?;
    }
    // Re-read what was written with the independent parser: an export that
    // cannot be read back is not an export.
    phase("verifying");
    let check = rbl_export::verify_databases(destination)
        .map_err(|e| AppError::new(ErrorKind::Internal, e.to_string()))?;
    if !check.is_ok() || check.tracks != report.tracks {
        return Err(AppError::new(ErrorKind::Internal, format!("USB verification failed: missing audio {:?}; {}", check.missing_audio, check.errors.join("; "))));
    }

    Ok(ExportReportDto {
        tracks: u32::try_from(report.tracks).unwrap_or(0),
        playlists: u32::try_from(report.playlists).unwrap_or(0),
        bytes_copied: report.bytes_copied,
        analysis_files: u32::try_from(report.analysis_files).unwrap_or(0),
        reused: u32::try_from(report.reused).unwrap_or(0),
        removed: u32::try_from(report.removed).unwrap_or(0),
        playlists_added: u32::try_from(report.playlists_added).unwrap_or(0),
        playlists_removed: u32::try_from(report.playlists_removed).unwrap_or(0),
        skipped: report.skipped,
        verified: check.is_ok() && check.tracks == report.tracks,
    })
}

///
/// `FolderPath` when the file is there. A cloud-synced track's `FolderPath`
/// can name a copy that is not (the Dropbox one, on a machine where the
/// folder is not synced down), so the other paths the row names —
/// `rb_LocalFolderPath`, then `OrgFolderPath` — are tried in turn, and
/// the first that exists is the source. None existing leaves `FolderPath`,
/// so the export reports the track as skipped under the name the row gives.
fn source_audio(folder_path: &str, alternates: &[String]) -> std::path::PathBuf {
    let first = std::path::PathBuf::from(folder_path);
    if first.is_file() {
        return first;
    }
    alternates
        .iter()
        .map(std::path::PathBuf::from)
        .find(|p| p.is_file())
        .unwrap_or(first)
}

/// Reads a track's analysis files, so the export re-emits rather than
/// re-analysing.
fn read_analysis(share: &std::path::Path, relative: &str) -> AppResult<Vec<(String, Vec<u8>)>> {
    if relative.is_empty() {
        return Ok(Vec::new());
    }
    let base = share.join(relative.trim_start_matches(['/', '\\']));
    let mut out = Vec::new();
    // The three files rekordbox 7 copies to a stick [OBS 7.2.11]; a track
    // analysed by an older version has no .2EX, and none is written then.
    for extension in ["DAT", "EXT", "2EX"] {
        let path = base.with_extension(extension);
        match std::fs::read(&path) {
            Ok(bytes) => {
                rbl_anlz::parse(&bytes).map_err(|e|AppError::internal(format!("Invalid analysis {}: {e}",path.display())))?;
                out.push((extension.to_owned(), bytes));
            }
            Err(e) if e.kind()==std::io::ErrorKind::NotFound && extension!="DAT" => {},
            Err(e) => return Err(AppError::internal(format!("Cannot read analysis {}: {e}",path.display()))),
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------- the commands

/// Writes a playlist to a stick.
///
/// Copies the audio, re-emits the analysis, and writes `export.pdb` and
/// `exportLibrary.db`. Never re-analyses. Emits `ExportProgress` while it runs
/// and `ExportDone` with the report. Blocking.
pub fn export_playlist(
    state: &AppState,
    sink: &dyn EventSink,
    playlist: &str,
    destination: &str,
    defaults: Option<&StickDefaultsDto>,
    delete_unlisted_music: bool,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
) -> AppResult<ExportReportDto> {
    let library = state.library()?;
    let share = state.share_root();
    let selection = ExportSelection::from_playlists(state, &library, &share, std::slice::from_ref(&playlist.to_owned()), false)?;
    let destination = std::path::Path::new(destination);
    let selection = selection.for_stick(state, &library, &share, destination, delete_unlisted_music)?;
    let report = write_export_with_progress(sink, destination, &selection, defaults, compatibility_format)?;
    sink.emit(AppEvent::ExportDone(report.clone()));
    Ok(report)
}

/// Export Track: puts tracks on a stick on their own, in no playlist,
/// beside what the stick's record says it holds. Blocking.
pub fn export_tracks_to_device(
    state: &AppState,
    sink: &dyn EventSink,
    tracks: &[String],
    destination: &str,
    defaults: Option<&StickDefaultsDto>,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
) -> AppResult<ExportReportDto> {
    let library = state.library()?;
    let share = state.share_root();
    let stick = std::path::Path::new(destination);
    if !stick.is_dir() {
        return Err(AppError::new(ErrorKind::NotFound, "That device is no longer connected."));
    }
    let record = rbl_export::Manifest::load(stick);
    let (playlists, mut loose, automatic) = match record {
        Some(m) => {
            let ids: Vec<String> = m.playlists.iter().filter(|p| !p.folder).map(|p| p.library_id.to_string()).collect();
            (ids, m.loose, rbl_export::sync_record::read(stick).is_some_and(|r| r.automatic))
        }
        None => (Vec::new(), Vec::new(), false),
    };
    for id in tracks.iter().filter_map(|t| t.parse::<u64>().ok()) {
        if !loose.contains(&id) {
            loose.push(id);
        }
    }
    let selection = ExportSelection::from_playlists_and_tracks(state, &library, &share, &playlists, &loose, automatic)?;
    let report = write_export_with_progress(sink, stick, &selection, defaults, compatibility_format)?;
    sink.emit(AppEvent::ExportDone(report.clone()));
    Ok(report)
}

/// What a sync is asked to do; the Sync Manager's own settings.
#[derive(Debug, Clone, Default)]
pub struct SyncOptions {
    /// Recorded on each stick as "Automatic synchronization".
    pub automatic: bool,
    pub eject_after_sync: bool,
    pub delete_unlisted_music: bool,
    pub compatibility_format: Option<rbl_export::CompatibilityFormat>,
}

/// Writes the same playlists to every destination, and says how each fared.
///
/// The selection is built once and written to every stick concurrently. One
/// stick failing must not stop the rest: the outcome is per stick, and only
/// building the selection fails the whole run. Emits `SyncProgress` and the
/// per-stick `ExportProgress`. Blocking.
pub fn sync_devices(
    state: &AppState,
    sink: &dyn EventSink,
    playlists: &[String],
    destinations: Vec<String>,
    defaults: Option<&StickDefaultsDto>,
    options: &SyncOptions,
) -> AppResult<Vec<SyncDeviceReportDto>> {
    let library = state.library()?;
    let share = state.share_root();
    let selection = ExportSelection::from_playlists(state, &library, &share, playlists, options.automatic)?;
    // The selection owns its tracks and analysis; each worker borrows it.
    Ok(std::thread::scope(|scope| {
        let workers: Vec<_> = destinations
            .into_iter()
            .map(|destination| {
                let (library, share, selection) = (&library, &share, &selection);
                scope.spawn(move || sync_one_device(sink, state, library, share, selection, destination, defaults, options))
            })
            .collect();
        workers
            .into_iter()
            .map(|worker| {
                worker.join().unwrap_or_else(|_| SyncDeviceReportDto {
                    path: "Unknown device".to_owned(),
                    report: None,
                    error: Some("The sync worker stopped unexpectedly.".to_owned()),
                    ejected: false,
                    eject_error: None,
                })
            })
            .collect()
    }))
}

/// Checks the exact playlist selection before any USB is touched.
pub fn validate_export_files(state: &AppState, playlists: &[String]) -> AppResult<Vec<MissingExportFileDto>> {
    let library = state.library()?;
    let share = state.share_root();
    let selection = ExportSelection::from_playlists(state, &library, &share, playlists, false)?;
    Ok(selection
        .tracks
        .into_iter()
        .filter_map(|track| {
            if track.source_path.is_file() {
                return None;
            }
            Some(MissingExportFileDto {
                title: if track.title.is_empty() { "Untitled track".to_owned() } else { track.title },
                path: track.source_path.to_string_lossy().into_owned(),
            })
        })
        .collect())
}

#[allow(clippy::too_many_arguments, reason = "one independent USB sync worker")]
fn sync_one_device(
    sink: &dyn EventSink,
    state: &AppState,
    library: &rbl_index::Library,
    share: &std::path::Path,
    selection: &ExportSelection,
    destination: String,
    defaults: Option<&StickDefaultsDto>,
    options: &SyncOptions,
) -> SyncDeviceReportDto {
    let progress = |state: &'static str| {
        sink.emit(AppEvent::SyncProgress(SyncProgressDto { path: destination.clone(), state }));
    };
    progress("writing");
    let stick = std::path::Path::new(&destination);
    let written = selection
        .for_stick(state, library, share, stick, options.delete_unlisted_music)
        .and_then(|selection| write_export_with_progress(sink, stick, &selection, defaults, options.compatibility_format));
    match written {
        Ok(report) => {
            let mut result = SyncDeviceReportDto { path: destination.clone(), report: Some(report), error: None, ejected: false, eject_error: None };
            if options.eject_after_sync {
                if result.report.as_ref().is_some_and(|report| report.verified && report.skipped.is_empty()) {
                    progress("ejecting");
                    set_export_stage(sink, stick, "ejecting");
                    match rbl_devices::eject::eject(stick) {
                        Ok(()) => result.ejected = true,
                        Err(e) => result.eject_error = Some(e.to_string()),
                    }
                } else {
                    result.eject_error = Some("The sync was incomplete or could not be verified. Review it before ejecting.".to_owned());
                }
            }
            progress("done");
            if options.eject_after_sync {
                set_export_stage(sink, stick, "done");
            }
            result
        }
        Err(e) => {
            progress("failed");
            tracing::warn!(destination, error = %e, "sync to one device failed");
            set_export_failure(sink, stick, e.message.clone());
            SyncDeviceReportDto { path: destination, report: None, error: Some(e.message), ejected: false, eject_error: None }
        }
    }
}

/// What a stick was last synced with, and what it holds.
///
/// Comes from our manifest, or failing that from the sync record rekordbox
/// leaves (`playlists3.sync`), which names the playlists by their library ids.
/// What it holds comes from `export.pdb` itself, whoever wrote it. Blocking.
pub fn device_sync_state(state: &AppState, path: &str) -> AppResult<DeviceSyncStateDto> {
    let library = state.library().ok();
    let mount = std::path::Path::new(path);
    if !mount.is_dir() {
        return Err(AppError::new(ErrorKind::NotFound, "That device is no longer connected."));
    }
    let record = rbl_export::sync_record::read(mount);
    // Only read when there is a record to match it against.
    let db_id = if record.is_some() {
        state.read_db(|db| rbl_db::export_info::db_id(db.connection())).unwrap_or(0)
    } else {
        0
    };
    // rekordbox's record names another library's playlists by ids this
    // one does not have; only a record from this library is a selection.
    let ours = record.as_ref().filter(|r| db_id != 0 && r.db_id == db_id);
    let mut selected: Vec<SyncPlaylistDto> = rbl_export::Manifest::load(mount)
        .filter(|m| m.db_id == db_id && db_id != 0)
        .map(|manifest| {
            manifest
                .playlists
                .into_iter()
                .filter(|p| !p.folder)
                .map(|playlist| SyncPlaylistDto { library_id: playlist.library_id.to_string(), name: playlist.name })
                .collect()
        })
        .unwrap_or_default();
    if selected.is_empty() {
        if let (Some(record), Some(library)) = (ours, library.as_ref()) {
            let playlists = library.playlists();
            selected = record
                .ticked
                .iter()
                .filter_map(|&id| {
                    let index = playlists.index_of(id)?;
                    Some(SyncPlaylistDto { library_id: id.to_string(), name: playlists.name(index).to_owned() })
                })
                .collect();
        }
    }
    Ok(DeviceSyncStateDto {
        selected,
        on_device: playlists_on_device(mount),
        libraries: crate::devices::library_trees(mount)?,
        automatic: ours.is_some_and(|r| r.automatic),
    })
}

/// Reads a stick's databases back with the independent parser and says whether
/// they hold together. Read-only; refused while an export to the stick runs.
pub fn verify_device(path: &str) -> AppResult<VerifyReportDto> {
    let stick = std::path::Path::new(path);
    if !stick.is_dir() {
        return Err(AppError::new(ErrorKind::NotFound, "That device is no longer connected."));
    }
    if EXPORT_CANCEL.lock().is_ok_and(|jobs| jobs.contains_key(path)) {
        return Err(AppError::new(ErrorKind::Internal, "An export to this device is running. Wait for it to finish."));
    }
    let check = rbl_export::verify_databases(stick).map_err(|e| AppError::new(ErrorKind::Internal, e.to_string()))?;
    let count = |n: usize| u32::try_from(n).unwrap_or(u32::MAX);
    Ok(VerifyReportDto {
        tracks: count(check.tracks),
        playlists: count(check.playlists),
        ok: check.is_ok(),
        missing_audio: check.missing_audio,
        errors: check.errors,
    })
}

/// Asks the export to a destination to stop. A no-op when none is running.
pub fn cancel_export(path: &str) {
    if let Ok(jobs) = EXPORT_CANCEL.lock() {
        if let Some(cancel) = jobs.get(path) {
            cancel.store(true, std::sync::atomic::Ordering::Relaxed);
        }
    }
}

/// A snapshot of every export's progress, for a front end that starts late.
#[must_use]
pub fn export_progress() -> Vec<ExportProgressDto> {
    EXPORT_PROGRESS.lock().map(|jobs| jobs.values().cloned().collect()).unwrap_or_default()
}

/// Ejects a volume, unless an export to it is running or finishing.
///
/// The guard checks every state an export passes through, not just the last
/// one. The running-jobs lock is held across the eject so a new export to the
/// same volume cannot register while the OS unmounts it.
pub fn eject_device(path: &str) -> AppResult<()> {
    let running = EXPORT_CANCEL.lock().map_err(|e| AppError::internal(e.to_string()))?;
    let active = EXPORT_PROGRESS
        .lock()
        .map_err(|e| AppError::internal(e.to_string()))?
        .get(path)
        .is_some_and(|job| is_active_state(job.state));
    if active || running.contains_key(path) {
        return Err(AppError::new(ErrorKind::Internal, "This device is being exported to. Wait for the export to finish."));
    }
    let result = rbl_devices::eject::eject(std::path::Path::new(path)).map_err(|e| AppError::new(ErrorKind::Internal, e.to_string()));
    drop(running);
    result
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::device_settings::{device_settings as read_settings, ensure_device_library, save_device_settings as save_settings};
    use crate::test_support::{fixture, write_wav, Recorder};
    use std::sync::atomic::{AtomicBool, Ordering};

    /// A fixture library whose "Export Set" playlist holds `count` real WAVs.
    /// Everything lives in temp dirs; the destination is made by the caller.
    fn staged(count: usize) -> (tempfile::TempDir, Arc<AppState>, Recorder, tempfile::TempDir, String) {
        let (dir, state, sink) = fixture(false);
        let audio = tempfile::tempdir().unwrap();
        let paths: Vec<String> = (0..count)
            .map(|n| {
                let path = audio.path().join(format!("Track {n}.wav"));
                write_wav(&path, 1);
                path.display().to_string()
            })
            .collect();
        let report = crate::import::import_files(&state, &sink, &paths).unwrap();
        let playlist = crate::edits::create_playlist(&state, &sink, "Export Set", "root").unwrap();
        let ids: Vec<String> = report.tracks.iter().map(|t| t.id.clone()).collect();
        crate::edits::add_tracks_to_playlist(&state, &sink, &playlist, &ids).unwrap();
        sink.clear();
        (dir, state, sink, audio, playlist)
    }

    fn states_for(sink: &Recorder, path: &str) -> Vec<&'static str> {
        sink.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                AppEvent::ExportProgress(p) if p.path == path => Some(p.state),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn an_export_reports_progress_in_order_then_done_and_writes_only_the_stick() {
        let (library_dir, state, sink, _audio, playlist) = staged(2);
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        let master_before = std::fs::metadata(library_dir.path().join("master.db")).unwrap().modified().unwrap();

        let report = export_playlist(&state, &sink, &playlist, &path, None, false, None).unwrap();
        assert_eq!((report.tracks, report.playlists), (2, 1));
        assert!(report.verified);
        assert_eq!(report.skipped, Vec::<String>::new());

        let states = states_for(&sink, &path);
        assert_eq!(states.first(), Some(&"preparing"));
        assert_eq!(states.last(), Some(&"done"));
        for stage in ["checking", "copying", "database", "verifying"] {
            assert!(states.contains(&stage), "{stage} missing from {states:?}");
        }
        let position = |stage: &str| states.iter().position(|s| *s == stage).unwrap();
        assert!(position("checking") < position("copying"));
        assert!(position("copying") < position("database"));
        assert!(position("database") < position("verifying"));
        // `done` is announced before the report that carries it.
        let names = sink.names();
        assert_eq!(names.last(), Some(&"export:done"));
        assert_eq!(names.iter().filter(|n| **n == "export:done").count(), 1);
        // The snapshot a late front end asks for says the same.
        assert!(export_progress().iter().any(|p| p.path == path && p.state == "done" && p.done == p.total));

        let record = rbl_export::Manifest::load(stick.path()).expect("our record is on the stick");
        assert_eq!(record.playlists.iter().filter(|p| !p.folder).count(), 1);
        // The library file was only read.
        assert_eq!(std::fs::metadata(library_dir.path().join("master.db")).unwrap().modified().unwrap(), master_before);
        assert!(!is_job_running(&path));

        // Reading it back independently agrees, and a stick with nothing on it does not.
        let check = verify_device(&path).unwrap();
        assert!(check.ok && check.tracks == 2 && check.missing_audio.is_empty(), "{check:?}");
        assert_eq!(verify_device(&stick.path().join("gone").display().to_string()).unwrap_err().kind, ErrorKind::NotFound);
    }

    fn is_job_running(path: &str) -> bool {
        EXPORT_CANCEL.lock().unwrap().contains_key(path)
    }

    /// Cancels the export the moment its first file is being copied.
    struct CancelOnCopy {
        inner: Recorder,
        path: String,
        asked: AtomicBool,
    }

    impl EventSink for CancelOnCopy {
        fn emit(&self, event: AppEvent) {
            if let AppEvent::ExportProgress(p) = &event {
                if p.path == self.path && matches!(p.state, "checking" | "copying") && !self.asked.swap(true, Ordering::SeqCst) {
                    cancel_export(&self.path);
                }
            }
            self.inner.emit(event);
        }
    }

    #[test]
    fn a_cancelled_export_ends_cancelled_and_leaves_the_stick_unpublished() {
        let (_library, state, _sink, _audio, playlist) = staged(3);
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        let sink = CancelOnCopy { inner: Recorder::default(), path: path.clone(), asked: AtomicBool::new(false) };

        let err = export_playlist(&state, &sink, &playlist, &path, None, false, None).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Cancelled);
        let states = states_for(&sink.inner, &path);
        assert_eq!(states.last(), Some(&"cancelled"), "{states:?}");
        assert!(!states.contains(&"publishing"));
        assert!(!sink.inner.names().contains(&"export:done"));
        assert!(rbl_export::Manifest::load(stick.path()).is_none(), "nothing was published");
        assert!(!is_job_running(&path), "the job is released so a retry can start");

        // A retry on the same stick goes through.
        let report = export_playlist(&state, &Recorder::default(), &playlist, &path, None, false, None).unwrap();
        assert_eq!(report.tracks, 3);
    }

    #[test]
    fn a_sync_writes_every_stick_reports_each_and_survives_a_missing_one() {
        let (_library, state, sink, _audio, playlist) = staged(2);
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let gone = a.path().join("pulled");
        let paths = vec![a.path().display().to_string(), gone.display().to_string(), b.path().display().to_string()];

        let reports = sync_devices(&state, &sink, std::slice::from_ref(&playlist), paths.clone(), None, &SyncOptions::default()).unwrap();
        assert_eq!(reports.len(), 3);
        assert_eq!(reports[0].path, paths[0], "the caller's order is kept");
        assert!(reports[0].report.as_ref().unwrap().verified);
        assert!(reports[1].report.is_none());
        assert!(reports[1].error.as_deref().unwrap().contains("no longer connected"));
        assert_eq!(reports[2].report.as_ref().unwrap().tracks, 2);
        assert!(!reports.iter().any(|r| r.ejected));

        let sync_states = |path: &str| -> Vec<&'static str> {
            sink.0.lock().unwrap().iter().filter_map(|e| match e {
                AppEvent::SyncProgress(p) if p.path == path => Some(p.state),
                _ => None,
            }).collect()
        };
        assert_eq!(sync_states(&paths[0]), ["writing", "done"]);
        assert_eq!(sync_states(&paths[1]), ["writing", "failed"]);
        assert_eq!(sync_states(&paths[2]), ["writing", "done"]);
        // A sync does not announce `export:done`; the reports are its answer.
        assert!(!sink.names().contains(&"export:done"));
        assert_eq!(states_for(&sink, &paths[1]).last(), Some(&"failed"));

        // The stick's record now offers its selection back.
        let again = device_sync_state(&state, &paths[0]).unwrap();
        assert_eq!(again.selected.len(), 1);
        assert_eq!(again.selected[0].name, "Export Set");
        assert_eq!(again.on_device, ["Export Set"]);
        assert!(!again.automatic, "the Sync Manager always passes automatic=false");
    }

    #[test]
    fn eject_after_sync_is_refused_for_a_volume_the_os_does_not_list() {
        let (_library, state, sink, _audio, playlist) = staged(1);
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        let options = SyncOptions { eject_after_sync: true, ..SyncOptions::default() };
        let reports = sync_devices(&state, &sink, std::slice::from_ref(&playlist), vec![path.clone()], None, &options).unwrap();
        // The temp dir is not a real volume, so nothing is ejected and nothing real is touched.
        assert!(!reports[0].ejected);
        assert!(reports[0].eject_error.as_deref().unwrap().contains("no longer connected"));
        assert_eq!(states_for(&sink, &path).last(), Some(&"done"));
        assert!(stick.path().exists());
    }

    #[test]
    fn the_eject_guard_refuses_every_export_state_not_only_writing() {
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        for state in ["preparing", "checking", "copying", "database", "verifying", "publishing", "ejecting", "writing"] {
            EXPORT_PROGRESS.lock().unwrap().insert(
                path.clone(),
                ExportProgressDto { path: path.clone(), state, done: 1, total: 2, title: String::new() },
            );
            let err = eject_device(&path).unwrap_err();
            assert!(err.message.contains("being exported to"), "{state}: {}", err.message);
        }
        // A running job with no progress yet is refused too.
        EXPORT_PROGRESS.lock().unwrap().remove(&path);
        EXPORT_CANCEL.lock().unwrap().insert(path.clone(), Arc::new(AtomicBool::new(false)));
        assert!(eject_device(&path).unwrap_err().message.contains("being exported to"));
        EXPORT_CANCEL.lock().unwrap().remove(&path);

        // Finished states pass the guard; the directory is not a real volume, so the OS
        // layer refuses it and no eject is ever attempted on the disk beneath it.
        for state in ["done", "failed", "cancelled"] {
            EXPORT_PROGRESS.lock().unwrap().insert(
                path.clone(),
                ExportProgressDto { path: path.clone(), state, done: 2, total: 2, title: String::new() },
            );
            let err = eject_device(&path).unwrap_err();
            assert!(err.message.contains("no longer connected"), "{state}: {}", err.message);
        }
        EXPORT_PROGRESS.lock().unwrap().remove(&path);
        assert!(stick.path().exists());
    }

    #[test]
    fn a_second_export_to_a_busy_stick_is_refused() {
        let (_library, state, _sink, _audio, playlist) = staged(1);
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        EXPORT_CANCEL.lock().unwrap().insert(path.clone(), Arc::new(AtomicBool::new(false)));
        let err = export_playlist(&state, &Recorder::default(), &playlist, &path, None, false, None).unwrap_err();
        EXPORT_CANCEL.lock().unwrap().remove(&path);
        assert!(err.message.contains("already running"));
    }

    #[test]
    fn missing_source_audio_is_found_before_any_stick_is_touched() {
        let (_library, state, _sink, audio, playlist) = staged(2);
        std::fs::remove_file(audio.path().join("Track 1.wav")).unwrap();
        let missing = validate_export_files(&state, std::slice::from_ref(&playlist)).unwrap();
        assert_eq!(missing.len(), 1);
        assert!(missing[0].path.ends_with("Track 1.wav"));
    }

    #[test]
    fn export_track_puts_a_loose_track_on_a_stick_and_emits_done() {
        let (_library, state, sink, _audio, _playlist) = staged(2);
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        let ids: Vec<String> = (0..2).map(|n| state.library().unwrap().ids[state.library().unwrap().len() - 2 + n].to_string()).collect();
        let report = export_tracks_to_device(&state, &sink, &ids[..1], &path, None, None).unwrap();
        assert_eq!((report.tracks, report.playlists), (1, 0));
        assert_eq!(sink.names().last(), Some(&"export:done"));
        assert_eq!(rbl_export::Manifest::load(stick.path()).unwrap().loose.len(), 1);
        let err = export_tracks_to_device(&state, &sink, &ids, &stick.path().join("gone").display().to_string(), None, None).unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotFound);
    }

    #[test]
    fn device_settings_round_trip_on_a_temp_stick() {
        let (_library, state, _sink) = fixture(false);
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().display().to_string();
        let defaults = StickDefaultsDto {
            waveform_color: "rgb".to_owned(),
            waveform_position: "left".to_owned(),
            overview_waveform: "half".to_owned(),
            key_display: "classic".to_owned(),
            categories: None,
            sorts: None,
            sub_column: None,
        };
        // A blank stick shows rekordbox's defaults and nothing is writable.
        let blank = read_settings(&path);
        assert!(!blank.has_dev_setting && !blank.has_library_settings);

        let made = ensure_device_library(&state, &path, Some(&defaults)).unwrap();
        assert!(made.has_device_library && made.has_one_library && made.has_dev_setting && made.has_library_settings);
        assert_eq!(made.waveform_color, "rgb");

        let mut edited = made.clone();
        edited.waveform_color = "blue".to_owned();
        edited.key_display = "alphanumeric".to_owned();
        edited.device_name = "  FRIDAY  ".to_owned();
        edited.colors[0].name = "Vocal".to_owned();
        edited.sorts[2].visible = !edited.sorts[2].visible;
        let saved = save_settings(&path, &edited).unwrap();
        assert_eq!((saved.waveform_color.as_str(), saved.key_display.as_str()), ("blue", "alphanumeric"));
        assert_eq!(saved.device_name, "FRIDAY");
        assert_eq!(saved.colors[0].name, "Vocal");
        assert_eq!(saved.sorts[2].visible, edited.sorts[2].visible);

        // And it is what the stick holds, not what the call remembered.
        let reread = read_settings(&path);
        assert_eq!(reread.device_name, "FRIDAY");
        assert_eq!(reread.colors[0].name, "Vocal");
        assert_eq!(reread.waveform_position, "left", "untouched fields keep their value");

        let mut bad = reread;
        bad.waveform_color = "plaid".to_owned();
        assert_eq!(save_settings(&path, &bad).unwrap_err().kind, ErrorKind::Malformed);
        assert_eq!(save_settings(&stick.path().join("gone").display().to_string(), &edited).unwrap_err().kind, ErrorKind::NotFound);
    }
}
