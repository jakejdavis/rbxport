//! Starting with no rekordbox library: what the window asks at startup, and
//! making the library when it is told to.

use std::sync::Arc;

use tauri::{Manager, State};

use crate::commands::blocking;
use crate::dto::LibraryProblemDto;
use crate::error::AppResult;
use crate::state::AppState;

/// Why the library did not load, or nothing while it is loading or loaded.
#[tauri::command]
#[allow(clippy::needless_pass_by_value, reason = "Tauri's State extractor is injected by value")]
pub fn library_problem(state: State<'_, Arc<AppState>>) -> Option<LibraryProblemDto> {
    state.library_problem()
}

/// Makes a new, empty library where rekordbox keeps one, then loads it as
/// startup would. `library:ready` follows when it is up.
///
/// Planned again here rather than trusted from startup: a library that has
/// appeared since — rekordbox installed while the question was open — is
/// loaded, never replaced.
#[tauri::command]
pub async fn create_library(app: tauri::AppHandle) -> AppResult<()> {
    let handle = app.clone();
    blocking("create_library", move || {
        rbl_app::new_library::create(None)?;
        handle.state::<Arc<AppState>>().set_library_problem(None);
        crate::spawn_library_load(handle);
        Ok(())
    })
    .await
}
