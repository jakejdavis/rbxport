//! The device tabs' Tauri commands. The wire shape, the reading and the
//! writing live in `rbl_app::device_settings`.

use std::sync::Arc;

use rbl_app::device_settings as core;
pub use core::{DeviceSettingsDto, ReferenceStickSettingsDto, StickDefaultsDto};

use crate::commands::blocking;
use crate::error::AppResult;
use crate::state::AppState;

/// rekordbox's reference browse categories and sort options.
#[tauri::command]
pub fn reference_stick_settings() -> ReferenceStickSettingsDto {
    core::reference_stick_settings()
}

/// Gives a stick that holds an export but no `DEVSETTING.DAT` the defaults.
#[tauri::command]
pub async fn write_device_defaults(path: String, defaults: StickDefaultsDto) -> AppResult<DeviceSettingsDto> {
    blocking("write_device_defaults", move || core::write_device_defaults(&path, &defaults)).await
}

/// Gives a stick that holds no database the folders rekordbox creates.
#[tauri::command]
pub async fn ensure_device_library(
    state: tauri::State<'_, Arc<AppState>>,
    path: String,
    defaults: Option<StickDefaultsDto>,
) -> AppResult<DeviceSettingsDto> {
    let state = Arc::clone(&state);
    blocking("ensure_device_library", move || core::ensure_device_library(&state, &path, defaults.as_ref())).await
}

/// Reads a stick's settings. Never fails on a stick that holds nothing.
#[tauri::command]
pub async fn device_settings(path: String) -> AppResult<DeviceSettingsDto> {
    blocking("device_settings", move || Ok(core::device_settings(&path))).await
}

/// Writes a stick's settings back, and returns what the stick now holds.
#[tauri::command]
pub async fn save_device_settings(path: String, settings: DeviceSettingsDto) -> AppResult<DeviceSettingsDto> {
    blocking("save_device_settings", move || core::save_device_settings(&path, &settings)).await
}
