//! The information panel's commands: one track's full record, the lists its
//! dropdowns offer, and the fields it may write.
//!
//! The record is a point read from `djmdContent` by id, not a widening of the
//! columnar index — see `rbl_db::details`. The deck's INFO tab reads the same
//! record, which is why the DTO carries everything a panel could show rather
//! than only what the row DTO lacks.

use std::sync::Arc;

use tauri::{Manager, State};

use crate::commands::{blocking, edit, recorded_edit, Touched};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::{AppState, LibraryEdit};

pub use crate::dto::{MyTagCategoryDto, MyTagDto, TrackDetailsDto, TrackLookupsDto};

#[tauri::command]
pub async fn track_details(
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<TrackDetailsDto> {
    let state = Arc::clone(&state);
    blocking("track_details", move || rbl_app::details::track_details(&state, &track)).await
}

#[tauri::command]
pub async fn track_lookups(state: State<'_, Arc<AppState>>) -> AppResult<TrackLookupsDto> {
    let state = Arc::clone(&state);
    blocking("track_lookups", move || rbl_app::details::track_lookups(&state)).await
}

/// Sets the My Tags on a track to exactly the ids given.
#[tauri::command]
pub async fn set_my_tags<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    tags: Vec<String>,
) -> AppResult<crate::dto::EditHistoryDto> {
    recorded_edit(app, state, "set_my_tags", Touched::Tracks, "Track Edit", move |w| {
        w.set_my_tags_with_undo(&track, &tags).map(|(_, edit)| LibraryEdit::TrackTags(edit))
    }).await
}

/// Add Artwork: the image at `image` is filed in the share tree and the
/// track points at it.
#[tauri::command]
pub async fn add_artwork<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    image: String,
) -> AppResult<crate::dto::EditHistoryDto> {
    recorded_edit(app, state, "add_artwork", Touched::Tracks, "Track Edit", move |w| {
        w.set_artwork_with_undo(&track, Some(std::path::Path::new(&image)))
            .map(|(_, edit)| LibraryEdit::Track(vec![edit]))
    }).await
}

/// Add Artwork on a playlist or folder: the tree menu's own.
#[tauri::command]
pub async fn add_playlist_artwork<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    playlist: String,
    image: String,
) -> AppResult<u32> {
    edit(app, state, "add_playlist_artwork", Touched::Playlists, move |w| {
        w.set_playlist_artwork(&playlist, Some(std::path::Path::new(&image))).map(|_| ())
    })
    .await
}

/// Delete Artwork: the track points at no image; the file stays.
#[tauri::command]
pub async fn clear_artwork<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
) -> AppResult<crate::dto::EditHistoryDto> {
    recorded_edit(app, state, "clear_artwork", Touched::Tracks, "Track Edit", move |w| {
        w.set_artwork_with_undo(&track, None).map(|(_, edit)| LibraryEdit::Track(vec![edit]))
    }).await
}

/// Writes one of the Info tab's editable fields.
///
/// `field` is the wire name — `title`, `artist`, `year`, … — and the set of
/// names the writer accepts is the whole list of what is safe to write; a
/// name it does not know is refused here rather than mapped to a guess.
#[tauri::command]
pub async fn set_track_field<R: tauri::Runtime>(
    app: tauri::AppHandle<R>,
    state: State<'_, Arc<AppState>>,
    track: String,
    field: String,
    value: String,
) -> AppResult<crate::dto::EditHistoryDto> {
    let Some(which) = rbl_db::write::TrackField::parse(&field) else {
        return Err(AppError::new(ErrorKind::ReadOnly, format!("{field} cannot be edited here.")));
    };
    if field == "bpm" {
        let state = Arc::clone(&state);
        let writing = Arc::clone(&state);
        let reported = track.clone();
        if let Some(editor) = app.try_state::<Arc<crate::grid::GridEditor>>() {
            if editor.is_locked(&track) { return Err(AppError::new(ErrorKind::ReadOnly, "The beat grid is locked. Unlock it to edit.")); }
        }
        blocking("set_track_bpm", move || crate::grid::set_tempo(&writing, &track, &value)).await?;
        if let Some(editor) = app.try_state::<Arc<crate::grid::GridEditor>>() { editor.forget_history(&reported); }
        let _ = tauri::Emitter::emit(&app, "grid:changed", reported);
        let generation = crate::commands::reload(app.clone(), state.clone()).await?;
        let dto = {
            let mut history = state.edit_history.lock();
            history.clear_redo();
            crate::dto::EditHistoryDto {
                generation,
                can_undo: !history.undo.is_empty(),
                can_redo: !history.redo.is_empty(),
                undo_label: history.undo.last().map(|entry| entry.label.to_owned()),
                redo_label: history.redo.last().map(|entry| entry.label.to_owned()),
            }
        };
        let _ = tauri::Emitter::emit(&app, "edit-history:changed", dto.clone());
        return Ok(dto);
    }
    recorded_edit(app, state, "set_track_field", Touched::Tracks, "Track Edit", move |w| {
        w.set_field_with_undo(&track, which, &value).map(|(_, edit)| LibraryEdit::Track(vec![edit]))
    })
    .await
}
