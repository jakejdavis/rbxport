//! Beat grid editing commands. The editor, the file/row transaction and its
//! tests live in `rbl_app::grid`, shared with the native app; this file only
//! adapts them for the webview and keeps the deck's metronome in step.

use std::sync::Arc;

use tauri::State;

pub use rbl_app::grid::{
    apply, database_locked, state_of, write_atomically, GridAction, GridEdit, GridEditor, GridOptions, GridOutcome,
    GridStateDto,
};

use crate::commands::{blocking, RtSink};
use crate::error::AppResult;
use crate::state::AppState;

/// The Info panel's BPM field shares the durable file/row transaction.
pub(crate) fn set_tempo(state: &AppState, track: &str, value: &str) -> AppResult<()> {
    rbl_app::tempo::set_tempo(state, track, value)
}

/// Runs one action on a worker thread, then tells the deck's metronome.
#[allow(clippy::too_many_arguments, reason = "three managed states, the app, and what the command was given")]
async fn run<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    player: State<'_, Arc<crate::player::Player>>,
    editor: State<'_, Arc<GridEditor>>,
    name: &'static str,
    track: String,
    action: GridAction,
    deck: Option<String>,
    options: GridOptions,
) -> AppResult<GridStateDto> {
    let state = Arc::clone(&state);
    let editor = Arc::clone(&editor);
    let outcome = {
        let track = track.clone();
        blocking(name, move || {
            rbl_app::grid::run(&state, &editor, &RtSink(app), &track, action, &options)
        })
        .await?
    };
    if !outcome.written {
        return Ok(outcome.state);
    }
    // The deck's metronome plays the grid it was given on load; give it this one.
    if let (Some(deck), Some(engine)) = (deck, player.opened()) {
        let grid: Vec<(u32, bool)> = outcome.beats.iter().map(|&(ms, number)| (ms, number == 1)).collect();
        engine.set_metronome_grid(crate::player::deck_of(&deck), &grid);
    }
    Ok(outcome.state)
}

/// The grid as the panel shows it: tempo, beat count, undo, redo, lock.
#[tauri::command]
pub async fn grid_state(
    state: State<'_, Arc<AppState>>,
    editor: State<'_, Arc<GridEditor>>,
    track: String,
) -> AppResult<GridStateDto> {
    let state = Arc::clone(&state);
    let editor = Arc::clone(&editor);
    blocking("grid_state", move || rbl_app::grid::grid_state(&state, &editor, &track)).await
}

/// One grid edit. `from_ms` names the beat from which it applies — the scope
/// point, or the playhead for the from-here buttons — and `deck` the deck
/// the track is loaded on, so its metronome follows.
#[tauri::command]
#[allow(clippy::too_many_arguments, reason = "a command takes its states and its arguments flat")]
pub async fn grid_edit<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    player: State<'_, Arc<crate::player::Player>>,
    editor: State<'_, Arc<GridEditor>>,
    track: String,
    edit: GridEdit,
    from_ms: Option<u32>,
    deck: Option<String>,
    options: Option<GridOptions>,
) -> AppResult<GridStateDto> {
    run(app, state, player, editor, "grid_edit", track, GridAction::Edit { edit, from_ms }, deck, options.unwrap_or_default()).await
}

#[tauri::command]
pub async fn grid_undo<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    player: State<'_, Arc<crate::player::Player>>,
    editor: State<'_, Arc<GridEditor>>,
    track: String,
    deck: Option<String>,
) -> AppResult<GridStateDto> {
    run(app, state, player, editor, "grid_undo", track, GridAction::Undo, deck, GridOptions::default()).await
}

#[tauri::command]
pub async fn grid_redo<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    player: State<'_, Arc<crate::player::Player>>,
    editor: State<'_, Arc<GridEditor>>,
    track: String,
    deck: Option<String>,
) -> AppResult<GridStateDto> {
    run(app, state, player, editor, "grid_redo", track, GridAction::Redo, deck, GridOptions::default()).await
}

/// Locks or unlocks a track's analysis (`Analysed` bit 0x80 in the library).
#[tauri::command]
pub async fn grid_lock<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    editor: State<'_, Arc<GridEditor>>,
    track: String,
    on: bool,
) -> AppResult<GridStateDto> {
    let state = Arc::clone(&state);
    let editor = Arc::clone(&editor);
    blocking("grid_lock", move || rbl_app::grid::lock(&state, &editor, &RtSink(app), &track, on)).await
}
