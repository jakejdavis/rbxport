//! What an edit changed and how the index follows it. The emit wrappers that
//! drive these live in the shell; nothing here knows about a window.

use crate::dto::EditHistoryDto;
use crate::error::{AppError, ErrorKind};
use crate::events::AppEvent;
use crate::state::{AppState, EditHistory, LibraryEdit};

/// What an edit changed, and therefore how much has to be re-read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Touched {
    /// Only the playlist tree. Re-reading it costs 24 ms against 233 ms for
    /// the whole library, and it is by far the most common kind of edit.
    Playlists,
    /// A track column changed, so the ranks and the search arena are stale.
    Tracks,
    /// Only the Tag List.
    TagList,
    /// Existing tracks: rating, colour, comment, or play count.
    Metadata(Vec<String>),
    /// History membership, optionally with play counts to refresh.
    Histories(Vec<String>),
}

impl Touched {
    /// The event that tells the window. A Tag List edit leaves every other
    /// view as it was, so it has its own rather than `library:changed`,
    /// which makes every open list fetch its rows again.
    pub fn event(&self) -> &'static str {
        if matches!(self, Self::TagList) { "tag-list:changed" } else { "library:changed" }
    }
}


impl Touched {
    /// The event for `generation`, as [`Touched::event`] names it.
    pub fn changed(&self, generation: u32) -> AppEvent {
        if matches!(self, Self::TagList) { AppEvent::TagListChanged(generation) } else { AppEvent::LibraryChanged(generation) }
    }
}

pub fn history_dto(generation: u32, history: &EditHistory) -> EditHistoryDto {
    EditHistoryDto {
        generation,
        can_undo: !history.undo.is_empty(),
        can_redo: !history.redo.is_empty(),
        undo_label: history.undo.last().map(|entry| entry.label.to_owned()),
        redo_label: history.redo.last().map(|entry| entry.label.to_owned()),
    }
}

pub fn touched_by(edit: &LibraryEdit) -> Touched {
    match edit {
        LibraryEdit::DeletePlaylist(_) | LibraryEdit::RenamePlaylist(_) |
        LibraryEdit::MovePlaylist(_) | LibraryEdit::RemovePlaylistTracks(_) => Touched::Playlists,
        // Tokens keep their database row ids private; a full reload after an
        // undo is uncommon and guarantees every view and sort follows it.
        LibraryEdit::Track(_) | LibraryEdit::TrackTags(_) => Touched::Tracks,
    }
}

pub fn apply_history(writer: &mut rbl_db::write::Writer, edit: &LibraryEdit, undo: bool) -> Result<(), rbl_db::DbError> {
    match edit {
        LibraryEdit::DeletePlaylist(value) => if undo { writer.restore_playlist(value) } else { writer.redo_playlist_deletion(value) }.map(|_| ()),
        LibraryEdit::RenamePlaylist(value) => if undo { writer.undo_rename(value) } else { writer.redo_rename(value) }.map(|_| ()),
        LibraryEdit::MovePlaylist(value) => if undo { writer.undo_move(value) } else { writer.redo_move(value) }.map(|_| ()),
        LibraryEdit::RemovePlaylistTracks(value) => if undo { writer.undo_track_removal(value) } else { writer.redo_track_removal(value) }.map(|_| ()),
        LibraryEdit::Track(values) => {
            let ordered: Box<dyn Iterator<Item = _>> = if undo {
                Box::new(values.iter().rev())
            } else {
                Box::new(values.iter())
            };
            for value in ordered {
                if undo { writer.undo_track_edit(value)?; } else { writer.redo_track_edit(value)?; }
            }
            Ok(())
        }
        LibraryEdit::TrackTags(value) => if undo {
            writer.undo_tag_edit(value)
        } else {
            writer.redo_tag_edit(value)
        }.map(|_| ()),
    }
}

/// Shared by desktop and CDJ edits; the writer holds the edit gate until
/// both persistence and the new index are visible.
pub fn refresh_after_edit(state: &AppState, db: &rbl_db::Library, touched: Touched) -> Result<u32, rbl_db::DbError> {
    match touched {
        Touched::Metadata(ids) => state.refresh_metadata(db, &ids, false),
        Touched::Histories(ids) if !ids.is_empty() => state.refresh_metadata(db, &ids, true),
        Touched::Tracks => {
            let started = std::time::Instant::now();
            let (library, _) = rbl_index::load(db)?;
            let load_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            state.set_library(library, rbl_db::is_rekordbox_running(), db.schema().db_version, load_ms, db.location().clone());
            Ok(state.summary().3)
        }
        touched => {
            let library = state.library().map_err(|e| rbl_db::DbError::Open(e.to_string()))?;
            match touched {
                Touched::TagList => {
                    library.set_tag_list(rbl_index::reload_tag_list(db, &library)?);
                    return Ok(state.invalidate_tag_list_views());
                }
                Touched::Playlists => library.set_playlists(rbl_index::reload_playlists(db, &library)?),
                Touched::Histories(_) => library.set_histories(rbl_index::reload_histories(db, &library)?),
                _ => unreachable!("track changes handled above"),
            }
            Ok(state.invalidate_views())
        }
    }
}

/// Maps a database refusal onto the error kind the frontend distinguishes.
pub fn write_error(error: rbl_db::DbError) -> AppError {
    match error {
        rbl_db::DbError::WriteRefused(reason) => AppError::new(ErrorKind::ReadOnly, reason),
        other => AppError::new(ErrorKind::Internal, other.to_string()),
    }
}
