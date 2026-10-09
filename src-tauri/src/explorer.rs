//! The Explorer's commands: thin wrappers over `rbl_app::explorer`.

use crate::commands::blocking;
use crate::dto::{ExplorerChildrenDto, ExplorerRootDto};
use crate::error::AppResult;

/// Where the Explorer starts: the music folder, the home folder, the system
/// volume, and every other mounted volume.
#[tauri::command]
pub async fn explorer_roots() -> AppResult<Vec<ExplorerRootDto>> {
    blocking("explorer_roots", || Ok(rbl_app::explorer::explorer_roots())).await
}

/// The folders directly under `path`, by name.
#[tauri::command]
pub async fn explorer_children(path: String) -> AppResult<ExplorerChildrenDto> {
    blocking("explorer_children", move || Ok(rbl_app::explorer::explorer_children(&path))).await
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    #[test]
    fn the_listing_and_the_importer_agree_on_what_counts_as_audio() {
        // `rbl-devices` lists files by extension and `rbl-db` imports them by
        // the same rule; this crate is the one that depends on both.
        assert_eq!(rbl_devices::explorer::AUDIO_EXTENSIONS, rbl_db::import::AUDIO_EXTENSIONS);
    }
}
