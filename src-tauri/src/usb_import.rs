//! USB-to-library reads. The import itself lives in `rbl_app::usb_import`, shared with the native
//! app; this file only adapts it for the webview.

use std::sync::Arc;

use tauri::{Manager, State};

use crate::commands::{blocking, RtSink};
use crate::error::AppResult;
use crate::state::AppState;

pub use rbl_app::usb_import::UsbImportReport as ImportReport;

/// Explicit imports and Sync Manager imports share identity checks.
#[tauri::command]
pub async fn import_usb<R: tauri::Runtime>(app: tauri::AppHandle<R>, state: State<'_, Arc<AppState>>, path: String, cues: bool, history: bool, settings: bool) -> AppResult<ImportReport> {
    let state = Arc::clone(&state);
    let editor = Arc::clone(&app.state::<Arc<crate::grid::GridEditor>>());
    blocking("import_usb", move || rbl_app::usb_import::import_usb(&state, &editor, &RtSink(app), &path, cues, history, settings)).await
}
