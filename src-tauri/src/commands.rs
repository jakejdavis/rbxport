//! Tauri commands.
//!
//! Each is a thin adapter. Anything that touches the index runs on a blocking
//! thread via [`blocking`], which serves two rules at once: the async runtime
//! is never blocked, and a panic inside a command surfaces as an `AppError`
//! instead of taking the process down.

use std::sync::Arc;

use tauri::State;
use tauri_plugin_opener::OpenerExt;

use crate::link::LinkStatusDto;
use rbl_app::media::waveform_bytes;
use crate::dto::{
    AudioDevicesDto, CueDto, DeviceDto, ExportReportDto,
    EditHistoryDto, ImportReportDto, LibrarySummaryDto, LimiterDto, MissingTracksDto, PhraseDto, RowDto,
    TreeNodeDto, ViewHandleDto, ViewSpecDto,
    BackupDto, DeviceSyncStateDto, DuplicatesDto,
    ExportProgressDto, FilterValuesDto, ItunesLibraryDto, MissingExportFileDto, SmartRuleDto, SyncDeviceReportDto,
    XmlImportReportDto,
};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::{AppState, LibraryEdit};

pub use rbl_app::browse::MAX_ROWS;
pub(crate) use rbl_app::edits::Touched;

/// Runs `f` on a blocking thread and converts a panic there into an `AppError`.
pub(crate) async fn blocking<T, F>(name: &'static str, f: F) -> AppResult<T>
where
    F: FnOnce() -> AppResult<T> + Send + 'static,
    T: Send + 'static,
{
    // `run_command` catches an unwind inside the worker so the message names the
    // command; the JoinError arm is the backstop if the thread dies some other way.
    match tauri::async_runtime::spawn_blocking(move || {
        crate::error::run_command(name, std::panic::AssertUnwindSafe(f))
    })
    .await
    {
        Ok(result) => result,
        Err(e) => {
            tracing::error!(command = name, error = %e, "command panicked");
            Err(AppError::internal(format!("{name} panicked: {e}")))
        }
    }
}

#[tauri::command]
pub async fn library_summary(state: State<'_, Arc<AppState>>) -> AppResult<LibrarySummaryDto> {
    let state = Arc::clone(&state);
    blocking("library_summary", move || rbl_app::browse::library_summary(&state)).await
}

/// Removes the rekordbox-running write gate for this process. This deliberately
/// requires both an environment opt-in and an explicit gesture in the UI.
#[tauri::command]
pub fn disable_read_only() -> AppResult<()> {
    if rbl_db::enable_unsafe_writes() {
        Ok(())
    } else {
        Err(AppError::internal(format!(
            "Set {} before launching rbxport to enable this override.",
            rbl_db::UNSAFE_WRITES_ENV
        )))
    }
}

#[tauri::command]
pub async fn playlist_tree(state: State<'_, Arc<AppState>>) -> AppResult<Vec<TreeNodeDto>> {
    let state = Arc::clone(&state);
    blocking("playlist_tree", move || rbl_app::browse::playlist_tree(&state)).await
}

#[tauri::command]
pub async fn open_view(state: State<'_, Arc<AppState>>, spec: ViewSpecDto) -> AppResult<ViewHandleDto> {
    // Sorting and filtering (and a folder's directory read) happen here, so
    // this is the one that must not run on the async thread.
    let state = Arc::clone(&state);
    blocking("open_view", move || rbl_app::browse::open_view(&state, &spec)).await
}

#[tauri::command]
pub async fn fetch_rows(
    state: State<'_, Arc<AppState>>,
    view_id: u32,
    offset: u32,
    len: u32,
    extra_columns: Option<Vec<String>>,
) -> AppResult<Vec<RowDto>> {
    let extra_columns = extra_columns.unwrap_or_default();
    let handle = Arc::clone(&state);
    blocking("fetch_rows", move || rbl_app::browse::fetch_rows(&handle, view_id, offset, len, &extra_columns)).await
}

#[tauri::command]
pub async fn view_ids_in_range(
    state: State<'_, Arc<AppState>>,
    view_id: u32,
    from: u32,
    to: u32,
) -> AppResult<Vec<String>> {
    let state = Arc::clone(&state);
    blocking("view_ids_in_range", move || rbl_app::browse::view_ids_in_range(&state, view_id, from, to)).await
}

/// Waveform bytes for a track, as raw bytes rather than JSON.
///
/// A colour waveform is a few kilobytes of numbers; sending it as a JSON array
/// would be several times larger and cost a parse on the UI thread. `tauri`
/// hands `Vec<u8>` to the webview as a binary response.
///
/// Returns an empty vector when the track has no analysis, which the UI draws
/// as a blank preview rather than an error.
#[tauri::command]
/// Waveform bytes for a track, as raw bytes rather than a JSON number array.
///
/// `from` and `len` window the tag, counted in entries. Absent means the whole
/// thing, which is only safe for the small tags: `PWV7` is 158 KB on a
/// five-minute track, far past the 64 KB response cap, so the detail view asks
/// for the span it is about to draw.
pub async fn track_waveform(
    state: State<'_, Arc<AppState>>,
    track_id: String,
    kind: String,
    from: Option<u32>,
    len: Option<u32>,
) -> AppResult<tauri::ipc::Response> {
    let library = match state.library() {
        Ok(library) => library,
        Err(error) => return crate::screen_cache::cached_waveform(&track_id, &kind)
            .map(tauri::ipc::Response::new)
            .ok_or(error),
    };
    let share = state.share_root();
    blocking("track_waveform", move || waveform_bytes(&library, &share, &track_id, &kind, from, len))
        .await
        .map(tauri::ipc::Response::new)
}

/// A short, true stereo PCM waveform window. The response is decimated to
/// per-channel min/max pairs, which preserves attacks at display resolution
/// the way a DAW waveform view does without creating another analysis file.
#[tauri::command]
pub async fn track_pcm_waveform(
    state: State<'_, Arc<AppState>>,
    track_id: String,
    from_ms: f64,
    to_ms: f64,
    columns: u32,
) -> AppResult<tauri::ipc::Response> {
    // The deck's streamer gives us the same frame-accurate seek path that
    // playback uses, without sharing or disturbing the live deck decoder.
    const RATE: u32 = 44_100;
    let library = state.library()?;
    // Eight bytes per point stays below Tauri's 64 KB IPC response cap while
    // still leaving thousands of peak buckets in the closest view, even after
    // its two-second guard on both sides.
    let columns = columns.clamp(1, 7_500) as usize;
    let from_ms = from_ms.max(0.0);
    let to_ms = to_ms.max(from_ms);
    blocking("track_pcm_waveform", move || {
        let Some(path) = library.audio_path_of(&track_id).map(std::path::PathBuf::from) else {
            return Ok(Vec::new());
        };
        if !path.exists() || to_ms <= from_ms {
            return Ok(Vec::new());
        }
        let mut stream = rbl_deck::decode::Streamer::open(&path, RATE)
            .map_err(|e| AppError::new(ErrorKind::Malformed, "That file could not be decoded.").with_detail(e.to_string()))?;
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "a waveform span in frames, already clamped non-negative")]
        let first = (from_ms * f64::from(RATE) / 1000.0).round().max(0.0) as u64;
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "a waveform span in frames, already clamped non-negative")]
        let frames = ((to_ms - from_ms) * f64::from(RATE) / 1000.0).ceil().max(1.0) as usize;
        stream.seek(first).map_err(|e| AppError::new(ErrorKind::Malformed, "That file could not be decoded.").with_detail(e.to_string()))?;
        let mut pcm = vec![0.0_f32; frames * 2];
        let read = stream.fill(&mut pcm)
            .map_err(|e| AppError::new(ErrorKind::Malformed, "That file could not be decoded.").with_detail(e.to_string()))?;
        let mut out = Vec::with_capacity(columns * 8);
        for column in 0..columns {
            let start = column * frames / columns;
            let end = ((column + 1) * frames / columns).max(start + 1).min(read);
            let mut left = (f32::INFINITY, f32::NEG_INFINITY);
            let mut right = (f32::INFINITY, f32::NEG_INFINITY);
            for frame in start..end {
                let at = frame * 2;
                left.0 = left.0.min(pcm[at]);
                left.1 = left.1.max(pcm[at]);
                right.0 = right.0.min(pcm[at + 1]);
                right.1 = right.1.max(pcm[at + 1]);
            }
            if !left.0.is_finite() { left = (0.0, 0.0); }
            if !right.0.is_finite() { right = (0.0, 0.0); }
            for sample in [left.0, left.1, right.0, right.1] {
                #[allow(clippy::cast_possible_truncation, reason = "clamped to [-1.0, 1.0] * i16::MAX, so it always fits")]
                let pcm16 = (sample.clamp(-1.0, 1.0) * 32767.0) as i16;
                out.extend_from_slice(&pcm16.to_le_bytes());
            }
        }
        Ok(out)
    }).await.map(tauri::ipc::Response::new)
}

// ---------------------------------------------------------------- editing

/// Forwards the core's events to the webview under their historical names.
pub(crate) struct RtSink<R: tauri::Runtime>(pub tauri::AppHandle<R>);

impl<R: tauri::Runtime> rbl_app::EventSink for RtSink<R> {
    fn emit(&self, event: rbl_app::AppEvent) {
        let _ = tauri::Emitter::emit(&self.0, event.name(), &event);
    }
}

/// Commits an edit and refreshes the affected index on the same connection.
pub(crate) async fn edit<R: tauri::Runtime, F>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    name: &'static str,
    touched: Touched,
    action: F,
) -> AppResult<u32>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<(), rbl_db::DbError> + Send + 'static,
{
    let state = Arc::clone(&state);
    blocking(name, move || rbl_app::edits::commit(&state, &RtSink(app), touched, action)).await
}

pub(crate) async fn recorded_edit<R: tauri::Runtime, F>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    name: &'static str,
    touched: Touched,
    label: &'static str,
    action: F,
) -> AppResult<EditHistoryDto>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<LibraryEdit, rbl_db::DbError> + Send + 'static,
{
    let state = Arc::clone(&state);
    blocking(name, move || rbl_app::edits::commit_recorded(&state, &RtSink(app), touched, label, action)).await
}

/// Re-reads the library on request: what the analysis queue asks for once
/// it has drained, so a run of a hundred tracks costs one reload, not a
/// hundred.
#[tauri::command]
pub async fn reload_library<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
) -> AppResult<u32> {
    reload(app, Arc::clone(&state)).await
}

/// Re-reads the library and returns the new generation.
pub(crate) async fn reload<R: tauri::Runtime>(app: tauri::AppHandle<R>, state: Arc<AppState>) -> AppResult<u32> {
    blocking("reload", move || rbl_app::edits::reload(&state, &RtSink(app))).await
}

/// LINK as it stands: on or off, on which interface, and who is listening.
///
/// When it is off, the status carries why it cannot come on right now (usually
/// rekordbox holding the ports), so the shell can warn before the button is
/// ever pressed.
#[tauri::command]
pub async fn link_status(state: State<'_, Arc<AppState>>) -> AppResult<LinkStatusDto> {
    Ok(state.link_status().unwrap_or_else(|| LinkStatusDto::off(crate::link::refusal())))
}

/// The players and mixers heard on the network, whether or not LINK is on.
/// The shell shows the LINK button once this is non-empty.
#[tauri::command]
pub async fn link_peers(state: State<'_, Arc<AppState>>) -> AppResult<Vec<crate::link::PeerDto>> {
    Ok(crate::link::peers(&state))
}

/// Turns LINK on: announces as `rekordbox` on `interface` (the first one
/// when none is named) and serves the library to every player that asks.
///
/// Refused while rekordbox runs — it holds the ports. Starting binds seven
/// sockets and walks every track's path, so it runs off the async thread.
#[tauri::command]
pub async fn start_link_export<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    interface: Option<String>,
    alphanumeric_keys: Option<bool>,
    alphabetical_keys: Option<bool>,
) -> AppResult<LinkStatusDto> {
    if let Some(status) = state.link_status() {
        tracing::debug!("LINK asked to start while running; the running session stands");
        return Ok(status);
    }
    if let Some(problem) = crate::link::refusal() {
        tracing::warn!(%problem, "LINK refused");
        return Ok(LinkStatusDto::off(Some(problem)));
    }
    tracing::info!(interface = interface.as_deref().unwrap_or("auto"), "LINK starting");
    let owner = Arc::clone(&state);
    let emitter = app.clone();
    let library_emitter = app.clone();
    let started = blocking("start_link_export", move || {
        let key_notation = if alphanumeric_keys.unwrap_or(false) {
            rbl_link::KeyNotation::Alphanumeric
        } else {
            rbl_link::KeyNotation::Classic
        };
        let key_order = if alphabetical_keys.unwrap_or(false) {
            rbl_link::KeyOrder::Alphabetical
        } else {
            rbl_link::KeyOrder::Musical
        };
        Ok(crate::link::Session::start(
            &owner,
            interface.as_deref(),
            key_notation,
            key_order,
            move |status| {
                let _ = tauri::Emitter::emit(&emitter, "link:status", status);
            },
            Arc::new(move |event, generation| {
                let _ = tauri::Emitter::emit(&library_emitter, event, generation);
            }),
        ))
    })
    .await?;
    match started {
        Ok(session) => {
            let status = session.status(state.library().ok().as_deref());
            // A session started twice at once: the second is dropped
            // outside the lock, which unbinds it.
            drop(state.set_link(Some(session)));
            let _ = tauri::Emitter::emit(&app, "link:status", status.clone());
            Ok(status)
        }
        Err(problem) => {
            tracing::warn!(%problem, "LINK could not start");
            Ok(LinkStatusDto::off(Some(problem)))
        }
    }
}

/// Turns LINK off: the players lose the source.
#[tauri::command]
pub async fn stop_link_export<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
) -> AppResult<LinkStatusDto> {
    // Dropped outside the lock, and off the async thread: stopping joins
    // the servers' threads.
    let session = state.set_link(None);
    if session.is_some() {
        tracing::info!("LINK stopping");
    } else {
        tracing::debug!("LINK asked to stop while off");
    }
    blocking("stop_link_export", move || {
        drop(session);
        Ok(())
    })
    .await?;
    let status = LinkStatusDto::off(None);
    let _ = tauri::Emitter::emit(&app, "link:status", status.clone());
    Ok(status)
}

/// Tells a CDJ on the link to load a specific track from our library.
#[tauri::command]
pub async fn link_load_track(
    state: State<'_, Arc<AppState>>,
    player_number: u8,
    track_id: String,
) -> AppResult<()> {
    let id: u32 = track_id.parse().map_err(|_| AppError::internal(format!("bad track id: {track_id}")))?;
    tracing::info!(player_number, track_id = id, "asking a player to load a track");
    state.link_load_track(player_number, id).map_err(|reason| {
        tracing::warn!(player_number, track_id = id, %reason, "the player could not be asked");
        AppError::internal(reason)
    })
}

/// Becomes the network's tempo master, or resigns, and returns LINK's fresh
/// status.
#[tauri::command]
pub async fn link_set_master(state: State<'_, Arc<AppState>>, on: bool) -> AppResult<LinkStatusDto> {
    state.link_set_master(on);
    Ok(state.link_status().unwrap_or_else(|| LinkStatusDto::off(crate::link::refusal())))
}

/// Nudges the master tempo by `delta_bpm` (rekordbox's −/+ is ±1), and
/// returns LINK's fresh status.
#[tauri::command]
pub async fn link_nudge_master(state: State<'_, Arc<AppState>>, delta_bpm: f64) -> AppResult<LinkStatusDto> {
    state.link_nudge_master(delta_bpm);
    Ok(state.link_status().unwrap_or_else(|| LinkStatusDto::off(crate::link::refusal())))
}

/// Takes the current master player's tempo as the master tempo (rekordbox's
/// ⟳), and returns LINK's fresh status.
#[tauri::command]
pub async fn link_take_master_tempo(state: State<'_, Arc<AppState>>) -> AppResult<LinkStatusDto> {
    state.link_take_master_tempo();
    Ok(state.link_status().unwrap_or_else(|| LinkStatusDto::off(crate::link::refusal())))
}

/// Writes a playlist to a stick. See `rbl_app::export::export_playlist`.
#[tauri::command]
pub async fn export_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlist: String,
    destination: String,
    // What a stick with no settings of its own is given; see the DJ System
    // pane. A stick that has settings keeps them.
    defaults: Option<crate::device_settings::StickDefaultsDto>,
    delete_unlisted_music: Option<bool>,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
) -> AppResult<ExportReportDto> {
    state.library()?;
    let state = Arc::clone(&state);
    blocking("export_playlist", move || {
        rbl_app::export::export_playlist(
            &state, &RtSink(app), &playlist, &destination, defaults.as_ref(),
            delete_unlisted_music.unwrap_or(false), compatibility_format,
        )
    })
    .await
}

/// Writes the same playlists to every destination, and says how each fared.
/// See `rbl_app::export::sync_devices`.
#[tauri::command]
#[allow(clippy::too_many_arguments, reason = "the Sync Manager's own settings, one per IPC field the frontend already sends")]
pub async fn sync_devices<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlists: Vec<String>,
    destinations: Vec<String>,
    defaults: Option<crate::device_settings::StickDefaultsDto>,
    automatic: Option<bool>,
    eject_after_sync: Option<bool>,
    delete_unlisted_music: Option<bool>,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
) -> AppResult<Vec<SyncDeviceReportDto>> {
    state.library()?;
    let state = Arc::clone(&state);
    blocking("sync_devices", move || {
        let options = rbl_app::export::SyncOptions {
            automatic: automatic.unwrap_or(false),
            eject_after_sync: eject_after_sync.unwrap_or(false),
            delete_unlisted_music: delete_unlisted_music.unwrap_or(false),
            compatibility_format,
        };
        rbl_app::export::sync_devices(&state, &RtSink(app), &playlists, destinations, defaults.as_ref(), &options)
    })
    .await
}

/// Checks the exact playlist selection before any USB is touched.
#[tauri::command]
pub async fn validate_export_files(
    state: State<'_, Arc<AppState>>,
    playlists: Vec<String>,
) -> AppResult<Vec<MissingExportFileDto>> {
    state.library()?;
    let state = Arc::clone(&state);
    blocking("validate_export_files", move || rbl_app::export::validate_export_files(&state, &playlists)).await
}

/// Export Track: puts tracks on a stick on their own, in no playlist.
#[tauri::command]
pub async fn export_tracks_to_device<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    tracks: Vec<String>,
    destination: String,
    defaults: Option<crate::device_settings::StickDefaultsDto>,
    compatibility_format: Option<rbl_export::CompatibilityFormat>,
) -> AppResult<ExportReportDto> {
    state.library()?;
    let state = Arc::clone(&state);
    blocking("export_tracks_to_device", move || {
        rbl_app::export::export_tracks_to_device(&state, &RtSink(app), &tracks, &destination, defaults.as_ref(), compatibility_format)
    })
    .await
}

/// What a stick was last synced with, and what it holds.
#[tauri::command]
pub async fn device_sync_state(state: State<'_, Arc<AppState>>, path: String) -> AppResult<DeviceSyncStateDto> {
    let state = Arc::clone(&state);
    blocking("device_sync_state", move || rbl_app::export::device_sync_state(&state, &path)).await
}

#[tauri::command]
pub fn cancel_export(path: &str) {
    rbl_app::export::cancel_export(path);
}

#[tauri::command]
pub fn export_progress() -> Vec<ExportProgressDto> {
    rbl_app::export::export_progress()
}

#[tauri::command]
pub async fn eject_device(path: String) -> AppResult<()> {
    blocking("eject_device", move || rbl_app::export::eject_device(&path)).await
}

/// Lists the volumes an export could be written to, and what is on each.
///
/// Enumeration is cheap; reading a stick to see what it holds is not, so that
/// happens once per device here rather than on any timer. There is no polling
/// behind this — the panel asks when it is opened.
#[tauri::command]
pub async fn list_devices() -> AppResult<Vec<DeviceDto>> {
    blocking("list_devices", || Ok(rbl_app::browse::list_devices())).await
}

/// A track's whole beat grid, as raw bytes.
///
/// Read from the `PQTZ` tag of the track's analysis file. Seven bytes a beat —
/// a little-endian `u32` of milliseconds, the beat's number in its bar, and a
/// little-endian `u16` of the tempo there x100 — so a four-minute track costs
/// about 3.5 KB and one fetch per track replaces a fetch per window. Windowing
/// it meant re-reading and re-parsing the whole analysis file every time the
/// playhead moved on, which is the expensive part whatever slice comes back.
///
/// The beat number rather than a downbeat flag: it is what the tag holds, and
/// bar-aligned sync needs the position in the bar rather than only whether the
/// bar started. The tempo is per beat rather than one for the track because a
/// grid can change tempo partway through, and a track that speeds up at bar
/// 135 has to read as its new tempo from there on.
#[tauri::command]
pub async fn track_beats(
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<tauri::ipc::Response> {
    let state = Arc::clone(&state);
    blocking("track_beats", move || {
        Ok(rbl_app::track_data::encode_beats(&rbl_app::track_data::track_beats(&state, &track)?))
    })
    .await
    .map(tauri::ipc::Response::new)
}

/// A track's beat grid from its `.DAT`: milliseconds, the beat's number in
/// the bar (1 is the downbeat) and the tempo there x100, at most `MAX_BEATS`
/// of them. Empty for a track without one.
pub(crate) fn read_beat_grid(share: &std::path::Path, relative: &str) -> Vec<(u32, u8, u16)> {
    // The PQTZ grid offset is applied, as the editor and the drawn grid do.
    rbl_app::track_data::read_beat_grid(share, relative)
        .into_iter()
        .map(|beat| (beat.time_ms, beat.number, beat.tempo_x100))
        .collect()
}

/// Points a deck at a track and starts loading it.
///
/// Returns as soon as the engine has been told; the deck reports itself ready
/// with a `deck:loaded` event, because opening a file means reading from a
/// disk that may be asleep.
#[tauri::command]
pub async fn deck_load<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    track: String,
    load_id: u64,
) -> AppResult<()> {
    let library = state.library()?;
    let Some(path) = library.audio_path_of(&track).map(std::path::PathBuf::from) else {
        return Err(AppError::new(ErrorKind::NotFound, "That track's file could not be found.")
            .with_detail(format!("track {track}")));
    };
    let engine = player.engine(&app)?;
    let which = crate::player::deck_of(&deck);
    // The engine's own thread does the opening; this only hands it the path.
    engine.load_as(which, &path, load_id);
    player.loaded_tracks.lock().insert(which, track.clone());
    // And the grid, for the metronome. Read off the async thread: it is a
    // file, and the deck is loading on its own thread anyway.
    let share = state.share_root();
    let relative = library.row_of(&track).map(|row| library.analysis_path.get(row as usize).to_owned());
    let grid = blocking("deck_load_grid", move || {
        Ok(relative
            .filter(|rel| !rel.is_empty())
            .map(|rel| read_beat_grid(&share, &rel))
            .unwrap_or_default())
    })
    .await?;
    // A newer track may have been selected while its predecessor's analysis
    // file was being read. Never put the older grid on the newer audio.
    if player.loaded_tracks.lock().get(&which) == Some(&track) {
        engine.set_metronome_grid(
            which,
            &grid.iter().map(|&(ms, number, _)| (ms, number == 1)).collect::<Vec<_>>(),
        );
    }
    Ok(())
}

/// The key, in semitones from the track's own — a CDJ's key shift.
#[tauri::command]
pub async fn deck_key_shift<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    semitones: i8,
) -> AppResult<()> {
    let _ = &app;
    player.set_key_shift(crate::player::deck_of(&deck), semitones);
    Ok(())
}

/// Switches a deck's metronome on or off: a click on every beat of the
/// grid while it plays.
#[tauri::command]
pub async fn deck_metronome<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    on: bool,
) -> AppResult<()> {
    let engine = player.engine(&app)?;
    engine.set_metronome(crate::player::deck_of(&deck), on);
    Ok(())
}

/// Preferences › Audio › Metronome: which click, and how loud.
#[tauri::command]
pub async fn set_metronome(
    player: State<'_, Arc<crate::player::Player>>,
    sound: u8,
    volume: String,
) -> AppResult<()> {
    let sound = match sound {
        1 => rbl_deck::ClickSound::One,
        3 => rbl_deck::ClickSound::Three,
        _ => rbl_deck::ClickSound::Two,
    };
    let volume = match volume.as_str() {
        "small" => rbl_deck::ClickVolume::Small,
        "middle" => rbl_deck::ClickVolume::Middle,
        _ => rbl_deck::ClickVolume::Large,
    };
    player.set_metronome(sound, volume);
    Ok(())
}

/// Preferences › Audio › Sample Rate and Buffer size. Takes effect the next
/// time a deck plays, as a device change does: a stream has the rate it was
/// opened at.
#[tauri::command]
pub async fn set_audio_config<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    sample_rate: Option<u32>,
    buffer_frames: Option<u32>,
) -> AppResult<()> {
    if player.set_wish(rbl_deck::StreamWish { sample_rate, buffer_frames }) {
        let _ = tauri::Emitter::emit(&app, "deck:reset", ());
    }
    Ok(())
}

#[tauri::command]
pub async fn deck_unload(
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
) -> AppResult<()> {
    player.loaded_tracks.lock().remove(&crate::player::deck_of(&deck));
    if let Some(engine) = player.opened() {
        engine.unload(crate::player::deck_of(&deck));
    }
    Ok(())
}

#[tauri::command]
pub async fn deck_play<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
) -> AppResult<()> {
    let engine = player.engine(&app)?;
    engine.play(crate::player::deck_of(&deck));
    // The tick only runs while something is playing, so play is what starts it.
    crate::player::start_ticker(&app);
    Ok(())
}

/// Starts a deck after `delay_ms` of silence, counted by the audio callback:
/// quantized play on a synced deck, held for the master's next beat.
#[tauri::command]
pub async fn deck_play_after<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    delay_ms: f64,
) -> AppResult<()> {
    let engine = player.engine(&app)?;
    // Clamped to a positive number first: a delay is at most a beat, and a
    // negative or absurd one is zero rather than a wrapped count.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let frames = if delay_ms.is_finite() && delay_ms > 0.0 {
        (delay_ms.min(60_000.0) * f64::from(engine.sample_rate()) / 1000.0).round() as u64
    } else {
        0
    };
    engine.play_after(crate::player::deck_of(&deck), frames);
    crate::player::start_ticker(&app);
    Ok(())
}

#[tauri::command]
pub async fn deck_pause(
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.pause(crate::player::deck_of(&deck));
    }
    Ok(())
}

/// Moves a deck's playhead. Frame-exact, whatever the file's packet size.
#[tauri::command]
pub async fn deck_seek<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    // Fractional: a cue point is a place in the music, and a whole
    // millisecond is 44 frames at 44.1 kHz.
    position_ms: f64,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.seek_ms(crate::player::deck_of(&deck), position_ms);
        // So the interface sees where it landed even while paused, when no
        // tick is running.
        crate::player::start_ticker(&app);
    }
    Ok(())
}

/// Sets a deck's loop between two points and turns it on; a head already
/// past the out point goes back to the in point.
#[tauri::command]
pub async fn deck_set_loop<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    in_ms: f64,
    out_ms: f64,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.set_loop_ms(crate::player::deck_of(&deck), in_ms, out_ms);
        crate::player::start_ticker(&app);
    }
    Ok(())
}

/// RELOOP (on) and EXIT (off): back into the loop from its in point, or out
/// of it with the range kept.
#[tauri::command]
pub async fn deck_loop_active<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    on: bool,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.set_looping(crate::player::deck_of(&deck), on);
        crate::player::start_ticker(&app);
    }
    Ok(())
}

/// Forgets a deck's loop.
#[tauri::command]
pub async fn deck_clear_loop<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.clear_loop(crate::player::deck_of(&deck));
        crate::player::start_ticker(&app);
    }
    Ok(())
}

/// The master output level, 0 to +2 dB.
///
/// It reaches the meters on the next tick rather than coming back from here:
/// the level is the audio callback's to apply, and the interface reads what it
/// actually did rather than what it was asked for.
#[tauri::command]
pub async fn set_master_level<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    level: f32,
) -> AppResult<()> {
    // Remembered, and applied when the engine opens: setting a level is not a
    // reason to open the audio device.
    let _ = &app;
    player.set_master_level(level);
    Ok(())
}

/// One deck's channel strip: the trim, the three bands, and the kill buttons.
///
/// Every one of these is a knob position rather than a gain in dB — what a
/// position means is the mixer's to decide, and it changes with the EQ /
/// ISOLATOR switch. The interface should not have to know the curve.
#[tauri::command]
pub async fn set_channel_band<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    band: String,
    position: f32,
) -> AppResult<()> {
    let _ = &app;
    player.set_channel_band(crate::player::deck_of(&deck), band_of(&band), position);
    Ok(())
}

#[tauri::command]
pub async fn set_channel_kill<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    band: String,
    killed: bool,
) -> AppResult<()> {
    let _ = &app;
    player.set_channel_kill(crate::player::deck_of(&deck), band_of(&band), killed);
    Ok(())
}

/// The deck's gain, 0 to 2 — up to +6 dB, as a mixer's trim gives.
#[tauri::command]
pub async fn set_channel_trim<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    trim: f32,
) -> AppResult<()> {
    let _ = &app;
    player.set_channel_trim(crate::player::deck_of(&deck), trim);
    Ok(())
}

/// The crossfader: 0 is deck A alone, 1 is deck B alone, 0.5 is both.
#[tauri::command]
pub async fn set_crossfade<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    position: f32,
) -> AppResult<()> {
    let _ = &app;
    player.set_crossfade(position);
    Ok(())
}

/// EQ or ISOLATOR, which is what the bottom of each band's travel means.
#[tauri::command]
pub async fn set_eq_curve<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    isolator: bool,
) -> AppResult<()> {
    let _ = &app;
    player.set_eq_curve(isolator);
    Ok(())
}

use crate::player::band_of;

/// How fast a deck plays, as a multiple of the file's own speed.
///
/// A ratio rather than a BPM: what BPM that comes to depends on the track, and
/// the deck does not need to know the track's to play it faster.
#[tauri::command]
pub async fn deck_tempo<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    tempo: f32,
) -> AppResult<()> {
    let _ = &app;
    player.set_tempo(crate::player::deck_of(&deck), tempo);
    Ok(())
}

/// Master Tempo: whether the pitch is held while the speed changes.
#[tauri::command]
pub async fn deck_master_tempo<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    on: bool,
) -> AppResult<()> {
    let _ = &app;
    player.set_master_tempo(crate::player::deck_of(&deck), on);
    Ok(())
}

/// The outputs the audio could go to, and which one is in use.
///
/// Read every time rather than cached: an interface is plugged in while the
/// app is open more often than not, and a list that was right at launch is a
/// list that does not have the thing somebody just connected.
#[tauri::command]
pub async fn audio_devices(
    player: State<'_, Arc<crate::player::Player>>,
) -> AppResult<AudioDevicesDto> {
    Ok(player.audio_devices())
}

/// Chooses an output. `None` — an absent id — is the system default.
///
/// It takes effect on the next thing played: a running stream belongs to the
/// device it was opened on, so the engine is dropped and rebuilt rather than
/// moved.
#[tauri::command]
pub async fn set_audio_device<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    device: Option<String>,
) -> AppResult<()> {
    if player.set_device(device) {
        let _ = tauri::Emitter::emit(&app, "deck:reset", ());
    }
    Ok(())
}

/// The master limiter as it stands.
#[tauri::command]
pub async fn master_limiter(
    player: State<'_, Arc<crate::player::Player>>,
) -> AppResult<LimiterDto> {
    Ok(player.limiter())
}

/// Sets the master limiter and returns what was actually set.
///
/// Takes effect at once if the engine is up, and is remembered for its build
/// if not — or its rebuild, after a device change. What comes back is the
/// engine's clamping of what was sent, so the interface shows the truth.
#[tauri::command]
pub async fn set_master_limiter(
    player: State<'_, Arc<crate::player::Player>>,
    limiter: LimiterDto,
) -> AppResult<LimiterDto> {
    Ok(player.set_limiter(limiter))
}

/// Shows a track's file in the Finder.
///
/// The OS does the revealing; this only resolves the id to the path the
/// library holds for it, and says so plainly when that file is not there —
/// about one track in thirty of the reference library sits on a volume that
/// is not mounted.
#[tauri::command]
pub async fn reveal_track<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<()> {
    let library = state.library()?;
    let Some(path) = library.audio_path_of(&track).map(std::path::PathBuf::from) else {
        return Err(AppError::new(ErrorKind::NotFound, "That track's file could not be found.")
            .with_detail(format!("track {track}")));
    };
    if !path.exists() {
        return Err(AppError::new(ErrorKind::NotFound, "That track's file could not be found.")
            .with_detail(path.display().to_string()));
    }
    app.opener().reveal_item_in_dir(&path).map_err(|e| {
        AppError::new(ErrorKind::Internal, "The Finder would not open.").with_detail(e.to_string())
    })
}

/// What the app is costing right now, for the title bar's readout.
///
/// Sampled on demand: nothing keeps this up to date in the background, so a
/// window with the readout hidden pays nothing for it.
/// The version this build carries — the tag it was built from, or 0.1.0
/// for a development build — for the About pane. Nothing is asked over the
/// network; that is the Update Manager's job.
#[tauri::command]
pub async fn app_version<R: tauri::Runtime>(app: tauri::AppHandle<R>) -> AppResult<String> {
    Ok(app.package_info().version.to_string())
}

/// Opens the active daily log in the application associated with `.log` files
/// on this computer (Console on a stock macOS installation, for example).
#[tauri::command]
pub async fn open_log<R: tauri::Runtime>(app: tauri::AppHandle<R>) -> AppResult<()> {
    blocking("open_log", move || {
        let path = crate::logging::latest_log_file()
            .map_err(|e| {
                AppError::internal("The log folder could not be read.").with_detail(e.to_string())
            })?
            .ok_or_else(|| AppError::new(ErrorKind::NotFound, "No application log was found."))?;
        app.opener()
            .open_path(path.to_string_lossy().into_owned(), None::<&str>)
            .map_err(|e| {
                AppError::internal("The application log could not be opened.")
                    .with_detail(e.to_string())
            })
    })
    .await
}

#[tauri::command]
pub async fn app_diagnostics(player: State<'_, std::sync::Arc<crate::player::Player>>) -> AppResult<crate::diagnostics::Diagnostics> {
    // The sampler is kept between calls: CPU is a difference between two
    // readings, and a fresh `System` every second would always report zero.
    let health = player.opened().map(|engine| engine.audio_health()).unwrap_or_default();
    blocking("app_diagnostics", move || {
        let mut sample = crate::diagnostics::sample_shared();
        sample.audio_load = health.load;
        sample.audio_xruns = health.xruns;
        Ok(sample)
    }).await
}

/// Starts a drag on a deck.
///
/// Audio follows the pointer from here until `deck_scrub_end`: the deck reads
/// a decoded window at whatever rate the drag asks for, forwards or backwards,
/// which is what a hand on a record does and what a seek per pointer move
/// cannot do.
#[tauri::command]
pub async fn deck_scrub_begin<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
) -> AppResult<()> {
    let engine = player.engine(&app)?;
    engine.scrub_begin(crate::player::deck_of(&deck));
    crate::player::start_ticker(&app);
    Ok(())
}

/// Where the pointer is now, mid-drag.
#[tauri::command]
pub async fn deck_scrub_to(
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
    // Fractional: the head's speed comes from how far this moved since the
    // last one, so rounding it to a millisecond quantises the speed.
    position_ms: f64,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.scrub_to_ms(crate::player::deck_of(&deck), position_ms);
    }
    Ok(())
}

/// Ends a drag. The playhead stays where the head came to rest.
#[tauri::command]
pub async fn deck_scrub_end<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    player: State<'_, Arc<crate::player::Player>>,
    deck: String,
) -> AppResult<()> {
    if let Some(engine) = player.opened() {
        engine.scrub_end(crate::player::deck_of(&deck));
        crate::player::start_ticker(&app);
    }
    Ok(())
}

/// Both decks now, for the interface to anchor itself when it starts up or
/// comes back from a reload.
#[tauri::command]
pub async fn deck_state(
    player: State<'_, Arc<crate::player::Player>>,
) -> AppResult<crate::player::TickDto> {
    Ok(player.opened().map_or_else(crate::player::TickDto::silent, |engine| {
        crate::player::tick_of(&engine.snapshot(), engine.master())
    }))
}

/// Previews a track from `position_ms` without loading it onto a deck: a
/// click on the waveform in the browser's Preview column. See `preview.rs`
/// for what rekordbox does and how that was established.
#[tauri::command]
pub async fn preview_play<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    player: State<'_, Arc<crate::player::Player>>,
    preview: State<'_, Arc<crate::preview::Preview>>,
    track: String,
    position_ms: f64,
) -> AppResult<()> {
    let library = state.library()?;
    let Some(path) = library.audio_path_of(&track).map(std::path::PathBuf::from) else {
        return Err(AppError::new(ErrorKind::NotFound, "That track's file could not be found.")
            .with_detail(format!("track {track}")));
    };
    let decks = Arc::clone(&player);
    let preview = Arc::clone(&preview);
    // Waits on the file opening, which may be a disk waking up: off the
    // async runtime.
    blocking("preview_play", move || preview.play(&app, &decks, &track, &path, position_ms)).await
}

/// Stops the preview where it is.
#[tauri::command]
pub async fn preview_stop(preview: State<'_, Arc<crate::preview::Preview>>) -> AppResult<()> {
    preview.stop();
    Ok(())
}

/// The preview's track, whether it is playing, and where.
#[tauri::command]
pub async fn preview_state(
    preview: State<'_, Arc<crate::preview::Preview>>,
) -> AppResult<crate::preview::PreviewStateDto> {
    Ok(preview.state())
}

/// A track's cue points.
///
/// A hot cue's colour is what rekordbox paints for its `ColorTableIndex`,
/// from the complete `rbl_anlz::DRAWN_CUE_COLOURS` table extracted from
/// rekordbox. An invalid index is reported without a colour. A memory cue
/// never carries one.
#[tauri::command]
pub async fn track_cues(
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<Vec<CueDto>> {
    let state = Arc::clone(&state);
    blocking("track_cues", move || rbl_app::track_data::track_cues(&state, &track))
    .await
}

/// A track's phrases: the `INTRO` / `UP` / `CHORUS` strip rekordbox draws
/// above the waveform.
///
/// From `PSSI` in the `.EXT` file, with each phrase's beat resolved against
/// the `PQTZ` grid in the `.DAT` so the strip can be drawn on a time axis
/// without the caller fetching the grid as well.
#[tauri::command]
pub async fn track_phrases(
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<Vec<PhraseDto>> {
    let state = Arc::clone(&state);
    blocking("track_phrases", move || rbl_app::track_data::track_phrases(&state, &track))
    .await
}

/// Where rekordbox heard a voice, one intensity byte per 46.44 ms.
///
/// From `PVDI` in the `.2EX` file. Raw bytes rather than JSON: a long track
/// has tens of thousands of them, and `from` / `len` window the strip the same
/// way [`track_waveform`] windows a waveform, which is what keeps a response
/// inside the IPC cap.
#[tauri::command]
pub async fn track_vocals(
    state: State<'_, Arc<AppState>>,
    track: String,
    from: Option<u32>,
    len: Option<u32>,
) -> AppResult<tauri::ipc::Response> {
    let state = Arc::clone(&state);
    blocking("track_vocals", move || rbl_app::track_data::track_vocals(&state, &track, from, len))
    .await
    .map(tauri::ipc::Response::new)
}

/// Tracks whose audio file is no longer where the library says it is.
///
/// Bounded rather than exhaustive: a library can have thousands missing after
/// a drive is unplugged, and a list that long is neither useful nor small
/// enough for the IPC cap. The count is exact; the list is the first page.
#[tauri::command]
pub async fn missing_tracks(
    state: State<'_, Arc<AppState>>,
    limit: u32,
) -> AppResult<MissingTracksDto> {
    let state = Arc::clone(&state);
    blocking("missing_tracks", move || rbl_app::maintenance::missing_tracks(&state, limit)).await
}

/// Adds files to the library.
///
/// A chosen path may be a single file or a folder: a folder is walked
/// recursively for the audio files rekordbox plays (see
/// `rbl_app::import::expand_import_paths`). Reports what happened per file
/// rather than failing the whole batch.
#[tauri::command]
pub async fn import_files<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    paths: Vec<String>,
) -> AppResult<ImportReportDto> {
    let state = Arc::clone(&state);
    blocking("import_files", move || rbl_app::import::import_files(&state, &RtSink(app), &paths)).await
}

#[tauri::command]
pub async fn relocate_track<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    path: String,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("relocate_track", move || rbl_app::track_edits::relocate_track(&state, &RtSink(app), &track, &path)).await
}

#[tauri::command]
pub async fn create_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    name: String,
    parent: String,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("create_playlist", move || {
        let sink = RtSink(app);
        rbl_app::edits::create_playlist(&state, &sink, &name, &parent).map(|_| state.summary().3)
    })
    .await
}

/// An intelligent playlist's rule, for the editor. Refused when the rule
/// nests groups, which the editor cannot show without losing them.
#[tauri::command]
pub async fn smart_rule(state: State<'_, Arc<AppState>>, playlist: String) -> AppResult<SmartRuleDto> {
    let state = Arc::clone(&state);
    blocking("smart_rule", move || rbl_app::edits::smart_rule(&state, &playlist)).await
}

/// Create New Intelligent Playlist: a rule under `parent`, named as given.
#[tauri::command]
pub async fn create_smart_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    name: String,
    parent: String,
    rule: SmartRuleDto,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("create_smart_playlist", move || {
        let sink = RtSink(app);
        rbl_app::edits::create_smart_playlist(&state, &sink, &name, &parent, &rule).map(|_| state.summary().3)
    })
    .await
}

/// Replaces an intelligent playlist's rule.
#[tauri::command]
pub async fn set_smart_rule<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlist: String,
    rule: SmartRuleDto,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("set_smart_rule", move || rbl_app::edits::set_smart_rule(&state, &RtSink(app), &playlist, &rule)).await
}

#[tauri::command]
pub async fn create_folder<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    name: String,
    parent: String,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("create_folder", move || {
        let sink = RtSink(app);
        rbl_app::edits::create_folder(&state, &sink, &name, &parent).map(|_| state.summary().3)
    })
    .await
}

#[tauri::command]
pub async fn rename_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    id: String,
    name: String,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("rename_playlist", move || rbl_app::edits::rename_playlist(&state, &RtSink(app), &id, &name)).await
}

#[tauri::command]
pub async fn move_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    id: String,
    parent: String,
    index: Option<usize>,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("move_playlist", move || rbl_app::edits::move_playlist(&state, &RtSink(app), &id, &parent, index)).await
}

#[tauri::command]
pub async fn delete_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    id: String,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("delete_playlist", move || rbl_app::edits::delete_playlist(&state, &RtSink(app), &id)).await
}

#[tauri::command]
pub async fn undo_edit<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("undo_edit", move || rbl_app::edits::undo(&state, &RtSink(app))).await
}

#[tauri::command]
pub async fn redo_edit<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("redo_edit", move || rbl_app::edits::redo(&state, &RtSink(app))).await
}

#[tauri::command]
pub async fn add_tracks_to_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlist: String,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("add_tracks_to_playlist", move || {
        let sink = RtSink(app);
        rbl_app::edits::add_tracks_to_playlist(&state, &sink, &playlist, &tracks).map(|_| state.summary().3)
    })
    .await
}

/// Reload Tag: the file's tags read again over each track's row.
#[tauri::command]
pub async fn reload_tags<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("reload_tags", move || rbl_app::track_edits::reload_tags(&state, &RtSink(app), &tracks)).await
}

/// Puts tracks on the Tag List, rekordbox's temporary list, on the end.
#[tauri::command]
pub async fn add_to_tag_list<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("add_to_tag_list", move || rbl_app::track_edits::add_to_tag_list(&state, &RtSink(app), &tracks)).await
}

#[tauri::command]
pub async fn remove_from_tag_list<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("remove_from_tag_list", move || rbl_app::track_edits::remove_from_tag_list(&state, &RtSink(app), &tracks)).await
}

#[tauri::command]
pub async fn clear_tag_list<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("clear_tag_list", move || rbl_app::track_edits::clear_tag_list(&state, &RtSink(app))).await
}

#[tauri::command]
pub async fn remove_tracks_from_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlist: String,
    tracks: Vec<String>,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("remove_tracks_from_playlist", move || rbl_app::edits::remove_tracks_from_playlist(&state, &RtSink(app), &playlist, &tracks)).await
}

/// Tracks that share a title and an artist, case and accents aside.
///
/// One pass over the folded title column and the artists' folded names —
/// both already in memory for search and sort — into a map of groups, so
/// 38,681 tracks cost a few milliseconds. Same file size or same audio is
/// not tried: a re-encode of the same track has neither, and the same
/// title under the same artist is what a person calls a duplicate.
#[tauri::command]
pub async fn find_duplicates(state: State<'_, Arc<AppState>>, limit: u32) -> AppResult<DuplicatesDto> {
    let state = Arc::clone(&state);
    blocking("find_duplicates", move || rbl_app::maintenance::find_duplicates(&state, limit)).await
}

/// Imports a rekordbox XML collection: the files it names into the
/// library, the playlist tree, and the cues of each track that landed.
#[tauri::command]
pub async fn import_xml<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    path: String,
) -> AppResult<XmlImportReportDto> {
    let state = Arc::clone(&state);
    blocking("import_xml", move || rbl_app::import::import_xml(&state, &RtSink(app), &path)).await
}

/// File › Import iTunes Library…: Music.app's `Library.xml`, its tracks
/// and its playlist tree, through the same importer as a rekordbox XML
/// collection.
#[tauri::command]
pub async fn import_itunes<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    path: String,
) -> AppResult<XmlImportReportDto> {
    let state = Arc::clone(&state);
    blocking("import_itunes", move || rbl_app::itunes::import_all(&state, &RtSink(app), &path)).await
}

/// The iTunes / Music library at its usual place, for the Sync Manager's iTunes
/// column. `None` when no shared `Library.xml` is found — Music.app writes one
/// only when "Share Library XML with other applications" is on — so the column
/// can offer a file picker instead.
#[tauri::command]
pub async fn itunes_default_library() -> AppResult<Option<ItunesLibraryDto>> {
    blocking("itunes_default_library", move || {
        let Some(music) = dirs::audio_dir() else { return Ok(None) };
        rbl_app::itunes::default_library(&music)
    })
    .await
}

/// The iTunes / Music library at a file the DJ chose, for the iTunes column.
#[tauri::command]
pub async fn itunes_library_at(path: String) -> AppResult<ItunesLibraryDto> {
    blocking("itunes_library_at", move || rbl_app::itunes::library_at(&path)).await
}

/// Imports the ticked iTunes playlists — `itunes:<index>` ids from the tree
/// [`itunes_library_at`] or [`itunes_default_library`] returned — into the
/// library: their tracks, the folders above them, and each track's rating and
/// comment, through the same importer a whole file goes through.
#[tauri::command]
pub async fn import_itunes_selected<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    path: String,
    ids: Vec<String>,
) -> AppResult<XmlImportReportDto> {
    let state = Arc::clone(&state);
    blocking("import_itunes_selected", move || rbl_app::itunes::import_selected(&state, &RtSink(app), &path, &ids)).await
}

/// Export Loop As WAV: the loop's stretch of the track, `in_ms` to
/// `out_ms`, as a 16-bit WAV at `path`. Resolves to the frames written.
#[tauri::command]
pub async fn export_loop_wav(
    state: State<'_, Arc<AppState>>,
    track: String,
    in_ms: f64,
    out_ms: f64,
    path: String,
) -> AppResult<u64> {
    let library = state.library()?;
    blocking("export_loop_wav", move || {
        let Some(source) = library.audio_path_of(&track).map(std::path::PathBuf::from) else {
            return Err(AppError::new(ErrorKind::NotFound, "That track has no file to read."));
        };
        rbl_audio::write_range_wav(&source, in_ms / 1000.0, out_ms / 1000.0, std::path::Path::new(&path))
            .map_err(|e| AppError::new(ErrorKind::Malformed, format!("The loop could not be written: {e}")))
    })
    .await
}

/// Export a playlist to a file: `m3u8`, which any player reads, or the
/// tab-separated `txt` rekordbox writes. An intelligent playlist is what
/// its rule admits now. Resolves to how many tracks were written.
#[tauri::command]
pub async fn export_playlist_file(
    state: State<'_, Arc<AppState>>,
    playlist: String,
    path: String,
    format: String,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("export_playlist_file", move || {
        rbl_app::browse::export_playlist_file(&state, &playlist, &path, &format)
    })
    .await
}

/// Writes the collection as rekordbox's XML to `path`; resolves to how many
/// tracks it holds.
#[tauri::command]
pub async fn export_xml(state: State<'_, Arc<AppState>>, path: String) -> AppResult<u32> {
    let library = state.library()?;
    blocking("export_xml", move || {
        let text = rbl_index::export_xml(&library);
        std::fs::write(&path, text).map_err(|e| {
            AppError::new(ErrorKind::Internal, "The XML could not be written.").with_detail(e.to_string())
        })?;
        Ok(u32::try_from(library.len()).unwrap_or(u32::MAX))
    })
    .await
}

#[tauri::command]
pub async fn backup_sizes(state: State<'_, Arc<AppState>>, refresh: Option<bool>) -> AppResult<crate::backup_sizes::BackupSizes> {
    let state = Arc::clone(&state);
    blocking("backup_sizes", move || crate::backup_sizes::cached(&state, refresh.unwrap_or(false))).await
}

/// Open the configured folder, creating it if no backup has been taken yet.
#[tauri::command]
pub async fn open_backup_directory<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
) -> AppResult<()> {
    let path = state.backup_destination();
    blocking("open_backup_directory", move || {
        crate::durable::create_dir_all(&path).map_err(|e| {
            AppError::internal("The backup folder could not be created.").with_detail(e.to_string())
        })?;
        app.opener().open_path(path.to_string_lossy().into_owned(), None::<&str>).map_err(|e| {
            AppError::internal("The backup folder could not be opened.").with_detail(e.to_string())
        })
    }).await
}

/// The configured destination, whether or not any backups exist yet.
#[tauri::command]
#[allow(clippy::needless_pass_by_value, reason = "Tauri's State extractor is injected by value")]
pub fn backup_directory(state: State<'_, Arc<AppState>>) -> String {
    state.backup_destination().to_string_lossy().into_owned()
}

#[tauri::command]
#[allow(clippy::needless_pass_by_value, reason = "Tauri's State extractor is injected by value")]
pub fn backup_progress(state: State<'_, Arc<AppState>>) -> crate::backups::BackupProgress {
    state.backup_progress.lock().clone()
}

#[tauri::command]
#[allow(clippy::needless_pass_by_value, reason = "Tauri's State extractor is injected by value")]
pub fn cancel_backup(state: State<'_, Arc<AppState>>) {
    crate::backups::cancel(&state);
}

#[tauri::command]
#[allow(clippy::needless_pass_by_value, reason = "Tauri's State extractor is injected by value")]
pub fn start_backup(state: State<'_, Arc<AppState>>) -> AppResult<()> {
    crate::backups::start(Arc::clone(&state))
}

/// Explicit backups, newest first.
#[tauri::command]
pub async fn list_backups(state: State<'_, Arc<AppState>>) -> AppResult<Vec<BackupDto>> {
    let state = Arc::clone(&state);
    blocking("list_backups", move || crate::backups::list(&state)).await
}

#[tauri::command]
pub async fn back_up_library(state: State<'_, Arc<AppState>>) -> AppResult<String> {
    let state = Arc::clone(&state);
    blocking("back_up_library", move || crate::backups::create(&state)).await
}

#[tauri::command]
pub async fn delete_backup(state: State<'_, Arc<AppState>>, path: String) -> AppResult<()> {
    let state = Arc::clone(&state);
    blocking("delete_backup", move || crate::backups::delete(&state, std::path::Path::new(&path))).await
}

#[tauri::command]
pub async fn set_backup_directory(state: State<'_, Arc<AppState>>, directory: String) -> AppResult<String> {
    let state = Arc::clone(&state);
    blocking("set_backup_directory", move || state.set_backup_destination(std::path::Path::new(&directory))).await
}

/// A play: the track goes on today's history session and its play count
/// goes up. What the player asks for after a minute of a track.
#[tauri::command]
pub async fn record_play<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("record_play", move || rbl_app::track_edits::record_play(&state, &RtSink(app), &track)).await
}

/// Remove from History: the tracks' plays leave the session.
#[tauri::command]
pub async fn remove_from_history<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    history: String,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("remove_from_history", move || {
        rbl_app::track_edits::remove_from_history(&state, &RtSink(app), &history, &tracks)
    })
    .await
}

/// Opens a web address in the person's browser: the About pane's links.
/// Only `https://`, so nothing in the webview can hand the OS a file or a
/// scheme of its own.
#[tauri::command]
pub async fn open_url<R: tauri::Runtime>(app: tauri::AppHandle<R>, url: String) -> AppResult<()> {
    if !url.starts_with("https://") {
        return Err(AppError::new(ErrorKind::Malformed, "Only an https address can be opened."));
    }
    app.opener().open_url(&url, None::<&str>).map_err(|e| {
        AppError::new(ErrorKind::Internal, "That address could not be opened.").with_detail(e.to_string())
    })
}

/// Reset DJ Play Count: the tracks' counts go back to zero.
#[tauri::command]
pub async fn reset_play_count<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    tracks: Vec<String>,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("reset_play_count", move || rbl_app::track_edits::reset_play_count(&state, &RtSink(app), &tracks)).await
}

/// Remove from Collection: the tracks leave the library and every playlist
/// they were in. The files stay where they are, as rekordbox leaves them.
#[tauri::command]
pub async fn remove_from_collection<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("remove_from_collection", move || {
        rbl_app::track_edits::remove_from_collection(&state, &RtSink(app), &tracks)
    })
    .await
}

#[tauri::command]
pub async fn reorder_playlist<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlist: String,
    tracks: Vec<String>,
) -> AppResult<u32> {
    let state = Arc::clone(&state);
    blocking("reorder_playlist", move || rbl_app::edits::reorder_playlist(&state, &RtSink(app), &playlist, &tracks)).await
}

#[tauri::command]
pub async fn set_track_rating<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    stars: u8,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("set_track_rating", move || rbl_app::track_edits::set_rating(&state, &RtSink(app), &[track], stars)).await
}

#[tauri::command]
pub async fn set_track_comment<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    comment: String,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("set_track_comment", move || rbl_app::track_edits::set_comment(&state, &RtSink(app), &[track], &comment)).await
}

#[tauri::command]
pub async fn set_track_color<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    color: Option<String>,
) -> AppResult<EditHistoryDto> {
    let state = Arc::clone(&state);
    blocking("set_track_color", move || {
        rbl_app::track_edits::set_color(&state, &RtSink(app), &[track], color.as_deref())
    })
    .await
}

/// The BPMs and keys the track filter bar can offer for a list.
///
/// Counted over the source and query alone — never over the filter's own
/// result, or a picked value would hide the others. One pass over the rows
/// in Rust; the frontend never scans a row array for this.
#[tauri::command]
pub async fn filter_values(
    state: State<'_, Arc<AppState>>,
    spec: ViewSpecDto,
) -> AppResult<FilterValuesDto> {
    let state = Arc::clone(&state);
    blocking("filter_values", move || rbl_app::browse::filter_values(&state, &spec)).await
}
