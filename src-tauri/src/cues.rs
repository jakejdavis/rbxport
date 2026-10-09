//! Cue editing commands. The cue kinds, the writer calls and their tests live
//! in `rbl_app::cues`, shared with the native app; these adapt them for the
//! webview.

use std::sync::Arc;

use tauri::State;

pub use rbl_app::cues::{apply, CueChange, CueEdit, CueKind};

use crate::commands::{blocking, RtSink};
use crate::error::AppResult;
use crate::state::AppState;

async fn run<R: tauri::Runtime, T: Send + 'static>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    name: &'static str,
    f: impl FnOnce(&AppState, &RtSink<R>) -> AppResult<T> + Send + 'static,
) -> AppResult<T> {
    let state = Arc::clone(&state);
    blocking(name, move || f(&state, &RtSink(app))).await
}

#[tauri::command]
pub async fn add_cue<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    kind: CueKind,
    position_ms: u32,
) -> AppResult<String> {
    run(app, state, "add_cue", move |s, k| rbl_app::cues::add_cue(s, k, &track, kind, position_ms)).await
}

/// Adds a loop: a cue with an out point. `beats` is the loop's length in
/// beats when the caller knows it, and left out when In and Out are all
/// there is — which is what most of the library's loops record.
#[tauri::command]
pub async fn add_loop<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    kind: CueKind,
    in_ms: u32,
    out_ms: u32,
    beats: Option<u16>,
) -> AppResult<String> {
    run(app, state, "add_loop", move |s, k| {
        rbl_app::cues::add_loop(s, k, &track, kind, in_ms, out_ms, beats.unwrap_or(0))
    })
    .await
}

#[tauri::command]
pub async fn move_cue<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    cue: String,
    position_ms: u32,
) -> AppResult<()> {
    run(app, state, "move_cue", move |s, k| rbl_app::cues::move_cue(s, k, &cue, position_ms)).await
}

#[tauri::command]
pub async fn set_cue_colour<R: tauri::Runtime>(
    app: tauri::AppHandle<R>, state: State<'_, Arc<AppState>>, cue: String, colour: Option<u8>,
) -> AppResult<()> {
    run(app, state, "set_cue_colour", move |s, k| rbl_app::cues::set_cue_colour(s, k, &cue, colour)).await
}

#[tauri::command]
pub async fn delete_cue<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    cue: String,
) -> AppResult<()> {
    run(app, state, "delete_cue", move |s, k| rbl_app::cues::delete_cue(s, k, &cue)).await
}

/// Convert Memory Cues to Hot Cues. See `rbl_app::cues::convert_memory_cues_to_hot`.
#[tauri::command]
pub async fn convert_memory_cues_to_hot<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<u32> {
    run(app, state, "convert_memory_cues_to_hot", move |s, k| {
        rbl_app::cues::convert_memory_cues_to_hot(s, k, &track)
    })
    .await
}
