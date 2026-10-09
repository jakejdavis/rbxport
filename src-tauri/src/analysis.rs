//! Analysis commands. The analyser, its settings and the file/row transaction
//! live in `rbl_app::analysis`, shared with the native app; this file adapts
//! them for the webview and keeps phrase editing, which rewrites one file.

use std::sync::Arc;

use tauri::State;

pub use rbl_app::analysis::{AnalysisResultDto, AnalysisSettings};

use crate::commands::{blocking, RtSink};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::AppState;

/// Analyses one track and keeps the result. See `rbl_app::analysis::analyse_track`.
#[tauri::command]
#[allow(clippy::too_many_arguments, reason = "Tauri injects the application states alongside command arguments")]
pub async fn analyse_track<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    editor: State<'_, Arc<crate::grid::GridEditor>>,
    track_id: String,
    mode: Option<String>,
    settings: Option<AnalysisSettings>,
) -> AppResult<AnalysisResultDto> {
    let state = Arc::clone(&state);
    let editor = Arc::clone(&editor);
    let settings = settings.unwrap_or_default();
    blocking("analyse_track", move || {
        rbl_app::analysis::analyse_track(&state, &editor, &RtSink(app), &track_id, mode.as_deref(), &settings)
    })
    .await
}

/// PHRASE EDIT: CUT splits the phrase under `beat`, CLEAR takes it out.
/// The track's EXT file is rewritten in place with its other sections as
/// they were; nothing in the database changes. Resolves to whether anything
/// changed — a cut on a phrase's first beat, or no phrase under the beat,
/// is nothing.
#[tauri::command]
pub async fn edit_phrase<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track_id: String,
    beat: u16,
    action: String,
) -> AppResult<bool> {
    let library = state.library()?;
    let share = state.share_root();
    let state = Arc::clone(&state);
    let edit = match action.as_str() {
        "cut" => rbl_anlz::PhraseEdit::Cut { beat },
        "clear" => rbl_anlz::PhraseEdit::Clear { beat },
        other => return Err(AppError::new(ErrorKind::Malformed, format!("{other:?} is not a phrase edit."))),
    };
    let reported = track_id.clone();
    let changed = blocking("edit_phrase", move || {
        if library_locked(&state) {
            return Err(AppError::new(ErrorKind::ReadOnly, "rekordbox is running. Quit it before editing phrases."));
        }
        let Some(row) = library.row_of(&track_id) else {
            return Err(AppError::new(ErrorKind::NotFound, "That track is not in the library."));
        };
        let relative = library.analysis_path.get(row as usize);
        if relative.is_empty() {
            return Err(AppError::new(ErrorKind::NotFound, "That track has no analysis."));
        }
        let ext = rbl_anlz::sibling(&rbl_anlz::resolve(&share, relative), "EXT");
        let _edit_guard = state.edit_gate.lock();
        let _files = state.analysis_write.lock();
        let file = rbl_anlz::Anlz::read(&ext).map_err(|e| {
            AppError::new(ErrorKind::NotFound, "That track's analysis file could not be read.").with_detail(e.to_string())
        })?;
        let Some(bytes) = file.with_phrase_edit(edit) else { return Ok(false) };
        crate::durable::write(&ext, &bytes).map_err(|e| {
            AppError::new(ErrorKind::Internal, "The analysis file could not be written.").with_detail(e.to_string())
        })?;
        Ok(true)
    })
    .await?;
    if changed {
        let _ = tauri::Emitter::emit(&app, "analysis:changed", &reported);
    }
    Ok(changed)
}


/// Whether the library cannot be written right now: rekordbox holds the
/// installed library's file. A fixture is never held.
fn library_locked(state: &AppState) -> bool {
    state.location().is_ok_and(|location| location.is_real_install) && rbl_db::is_rekordbox_running()
}
