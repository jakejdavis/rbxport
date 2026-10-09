//! Auto Relocate: pointing missing tracks at files of the same name found
//! under the search folders from the Preferences window. The search itself is
//! `rbl_app::maintenance`; this is the command.

use std::sync::Arc;

use tauri::State;

use crate::commands::{blocking, RtSink};
use crate::error::AppResult;
use crate::state::AppState;

pub use rbl_app::maintenance::RelocateReportDto;

/// Points every missing track at a same-named file under the folders.
#[tauri::command]
pub async fn auto_relocate<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    folders: Vec<String>,
) -> AppResult<RelocateReportDto> {
    let state = Arc::clone(&state);
    blocking("auto_relocate", move || rbl_app::maintenance::auto_relocate(&state, &RtSink(app), &folders)).await
}
