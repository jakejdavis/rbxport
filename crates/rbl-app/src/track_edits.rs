//! Track metadata, Tag List, history and collection edits. Every function goes
//! through the one pipeline in [`crate::edits`], so each passes the write gate,
//! refreshes the index and emits the same events.

use crate::dto::EditHistoryDto;
use crate::edits::{check_gate, commit, commit_permanent, commit_recorded, commit_value, history_dto, Touched};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::{AppEvent, EventSink};
use crate::state::{AppState, LibraryEdit};

/// Shown for an edit aimed at a file the Explorer lists but the library lacks.
pub const LOOSE_MESSAGE: &str = "That file is not in the collection. Import it first.";

/// The history label every metadata edit carries.
const LABEL: &str = "Track Edit";

fn require_collection(tracks: &[String]) -> AppResult<()> {
    if tracks.iter().any(|t| t.starts_with("file:")) {
        return Err(AppError::new(ErrorKind::Malformed, LOOSE_MESSAGE));
    }
    Ok(())
}

/// Runs `edit` over every track and records the non-empty tokens as one undo entry.
fn track_edit(
    state: &AppState,
    sink: &dyn EventSink,
    touched: Touched,
    tracks: &[String],
    mut edit: impl FnMut(&mut rbl_db::write::Writer, &str) -> Result<rbl_db::write::TrackEdit, rbl_db::DbError>,
) -> AppResult<EditHistoryDto> {
    require_collection(tracks)?;
    commit_recorded(state, sink, touched, LABEL, |w| {
        let mut edits = Vec::with_capacity(tracks.len());
        for track in tracks {
            let token = edit(w, track)?;
            if !token.is_empty() {
                edits.push(token);
            }
        }
        Ok(LibraryEdit::Track(edits))
    })
}

/// Stars 0 to 5. Anything else is refused as `Malformed`.
pub fn set_rating(state: &AppState, sink: &dyn EventSink, tracks: &[String], stars: u8) -> AppResult<EditHistoryDto> {
    track_edit(state, sink, Touched::Metadata(tracks.to_vec()), tracks, |w, t| {
        w.set_rating_with_undo(t, stars).map(|(_, token)| token)
    })
}

pub fn set_comment(state: &AppState, sink: &dyn EventSink, tracks: &[String], comment: &str) -> AppResult<EditHistoryDto> {
    track_edit(state, sink, Touched::Metadata(tracks.to_vec()), tracks, |w, t| {
        w.set_comment_with_undo(t, comment).map(|(_, token)| token)
    })
}

/// The colour as the database stores it, unchecked: `None` clears it.
pub fn set_color(state: &AppState, sink: &dyn EventSink, tracks: &[String], color: Option<&str>) -> AppResult<EditHistoryDto> {
    track_edit(state, sink, Touched::Metadata(tracks.to_vec()), tracks, |w, t| {
        w.set_color_with_undo(t, color).map(|(_, token)| token)
    })
}

/// The palette's colour 1 to 8, or 0 for none (stored as NULL). Anything else is `Malformed`.
pub fn set_color_id(state: &AppState, sink: &dyn EventSink, tracks: &[String], id: u8) -> AppResult<EditHistoryDto> {
    check_gate(state)?;
    if id > 8 {
        return Err(AppError::new(ErrorKind::Malformed, format!("{id} is not a colour from 0 to 8.")));
    }
    let text = id.to_string();
    set_color(state, sink, tracks, (id > 0).then_some(text.as_str()))
}

/// One of the Info tab's text or number fields, by its wire name (`title`, `year`, ...).
/// `bpm` is not one of them: see [`set_bpm`].
pub fn set_field(state: &AppState, sink: &dyn EventSink, tracks: &[String], field: &str, value: &str) -> AppResult<EditHistoryDto> {
    check_gate(state)?;
    let Some(which) = rbl_db::write::TrackField::parse(field).filter(|_| field != "bpm") else {
        return Err(AppError::new(ErrorKind::Malformed, format!("{field} cannot be edited here.")));
    };
    // A reference field can intern a lookup row, a key can be missing: all become Malformed.
    track_edit(state, sink, Touched::Tracks, tracks, |w, t| w.set_field_with_undo(t, which, value).map(|(_, token)| token))
}

/// The BPM field: one tempo for the whole grid, written to the analysis files and
/// the row together. Validated 40 to 499 (`Malformed`). Not undoable: the files
/// change with the row, and undo tokens carry rows only, so the redo branch is
/// dropped and the undo history left as it was.
pub fn set_bpm(state: &AppState, sink: &dyn EventSink, track: &str, value: &str) -> AppResult<EditHistoryDto> {
    check_gate(state)?;
    require_collection(&[track.to_owned()])?;
    crate::tempo::parse_bpm(value)?;
    let dto = {
        let _gate = state.edit_gate.lock();
        crate::tempo::set_tempo(state, track, value)?;
        sink.emit(AppEvent::GridChanged(track.to_owned()));
        let generation = crate::edits::reload(state, sink)?;
        let mut history = state.edit_history.lock();
        history.clear_redo();
        history_dto(generation, &history)
    };
    sink.emit(AppEvent::EditHistoryChanged(dto.clone()));
    Ok(dto)
}

// -------------------------------------------------------------- Tag List

/// Puts tracks on the Tag List, on the end, skipping ones already there.
pub fn add_to_tag_list(state: &AppState, sink: &dyn EventSink, tracks: &[String]) -> AppResult<u32> {
    require_collection(tracks)?;
    commit(state, sink, Touched::TagList, |w| w.tag_list_add(tracks).map(|_| ()))
}

pub fn remove_from_tag_list(state: &AppState, sink: &dyn EventSink, tracks: &[String]) -> AppResult<u32> {
    commit(state, sink, Touched::TagList, |w| w.tag_list_remove(tracks).map(|_| ()))
}

pub fn clear_tag_list(state: &AppState, sink: &dyn EventSink) -> AppResult<u32> {
    commit(state, sink, Touched::TagList, |w| w.tag_list_clear().map(|_| ()))
}

// ------------------------------------------------- history and collection

/// Reload Tag: the file's tags read again over each track's row. Not undoable.
pub fn reload_tags(state: &AppState, sink: &dyn EventSink, tracks: &[String]) -> AppResult<u32> {
    require_collection(tracks)?;
    commit(state, sink, Touched::Tracks, |w| {
        for track in tracks {
            w.reload_tags(track)?;
        }
        Ok(())
    })
}

/// Reset DJ Play Count: back to zero, one undo step.
pub fn reset_play_count(state: &AppState, sink: &dyn EventSink, tracks: &[String]) -> AppResult<EditHistoryDto> {
    track_edit(state, sink, Touched::Metadata(tracks.to_vec()), tracks, |w, t| {
        w.set_field_with_undo(t, rbl_db::write::TrackField::PlayCount, "0").map(|(_, token)| token)
    })
}

/// Remove from History: the plays leave the session. Not undoable; counts stay.
pub fn remove_from_history(state: &AppState, sink: &dyn EventSink, history: &str, tracks: &[String]) -> AppResult<u32> {
    commit(state, sink, Touched::Histories(Vec::new()), |w| w.remove_from_history(history, tracks).map(|_| ()))
}

/// A play: the track goes on today's history session and its play count goes
/// up. Not undoable (it drops any redo branch). Returns the new generation.
pub fn record_play(state: &AppState, sink: &dyn EventSink, track: &str) -> AppResult<u32> {
    require_collection(std::slice::from_ref(&track.to_owned()))?;
    commit(state, sink, Touched::Histories(vec![track.to_owned()]), |w| w.record_play(track).map(|_| ()))
}

/// Remove from Collection: the tracks leave the library and every playlist. The
/// files stay. Permanent: the undo history is cleared.
pub fn remove_from_collection(state: &AppState, sink: &dyn EventSink, tracks: &[String]) -> AppResult<u32> {
    require_collection(tracks)?;
    commit_permanent(state, sink, Touched::Tracks, |w| {
        for track in tracks {
            w.delete_track(track)?;
        }
        Ok(())
    })
}

/// Points a track at another file. Not undoable.
pub fn relocate_track(state: &AppState, sink: &dyn EventSink, track: &str, path: &str) -> AppResult<u32> {
    require_collection(&[track.to_owned()])?;
    commit_value(state, sink, Touched::Tracks, |w| w.relocate(track, std::path::Path::new(path)).map(|_| ())).map(|(g, ())| g)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic, clippy::assert_is_empty)]
mod tests {
    use super::*;
    use crate::browse;
    use crate::dto::{TrackFilterDto, TrackSourceDto, ViewSpecDto};
    use crate::edits::{self, PROTECTED_MESSAGE};
    use crate::test_support::fixture;
    use rbl_db::fixture::{history_id, track_id};

    fn ids(n: usize) -> Vec<String> {
        (0..n).map(track_id).collect()
    }

    fn details(state: &AppState, id: &str) -> crate::dto::TrackDetailsDto {
        crate::details::track_details(state, id).unwrap()
    }

    fn view_ids(state: &AppState, source: TrackSourceDto) -> Vec<String> {
        let spec = ViewSpecDto {
            source,
            sort: "trackNo".into(),
            descending: false,
            query: String::new(),
            search_field: rbl_index::SearchField::default(),
            filter: TrackFilterDto::default(),
        };
        let handle = browse::open_view(state, &spec).unwrap();
        if handle.len == 0 {
            return Vec::new();
        }
        browse::view_ids_in_range(state, handle.view_id, 0, handle.len - 1).unwrap()
    }

    #[test]
    fn a_closed_gate_refuses_metadata_edits_without_a_trace() {
        let (_dir, state, sink) = fixture(true);
        let generation = state.summary().3;
        let t = ids(1);
        for result in [
            set_rating(&state, &sink, &t, 3).map(|_| ()),
            set_comment(&state, &sink, &t, "x").map(|_| ()),
            set_color_id(&state, &sink, &t, 2).map(|_| ()),
            set_field(&state, &sink, &t, "title", "x").map(|_| ()),
            set_bpm(&state, &sink, &t[0], "128").map(|_| ()),
            add_to_tag_list(&state, &sink, &t).map(|_| ()),
            remove_from_collection(&state, &sink, &t).map(|_| ()),
            reset_play_count(&state, &sink, &t).map(|_| ()),
        ] {
            let err = result.unwrap_err();
            assert_eq!((err.kind, err.message.as_str()), (ErrorKind::ReadOnly, PROTECTED_MESSAGE));
        }
        assert!(sink.names().is_empty());
        assert_eq!(state.summary().3, generation);
        assert_eq!(details(&state, &t[0]).rating, 0);
    }

    #[test]
    fn a_rating_is_written_undone_and_a_bad_one_is_malformed() {
        let (_dir, state, sink) = fixture(false);
        let t = ids(2);
        let history = set_rating(&state, &sink, &t, 4).unwrap();
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"]);
        assert_eq!(history.undo_label.as_deref(), Some("Track Edit"));
        assert!(t.iter().all(|id| details(&state, id).rating == 4));
        // Two tracks, one undo step.
        edits::undo(&state, &sink).unwrap();
        assert!(t.iter().all(|id| details(&state, id).rating == 0));
        edits::redo(&state, &sink).unwrap();
        assert_eq!(details(&state, &t[1]).rating, 4);

        sink.clear();
        let err = set_rating(&state, &sink, &t, 6).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
        assert!(sink.names().is_empty());
        assert_eq!(details(&state, &t[0]).rating, 4, "a refused rating changes nothing");
        // The same stars again changes nothing, so the history gains no entry.
        let before = edits::edit_history(&state);
        set_rating(&state, &sink, &t, 4).unwrap();
        assert_eq!(edits::edit_history(&state).undo_label, before.undo_label);
    }

    #[test]
    fn a_colour_is_checked_stored_and_cleared() {
        let (_dir, state, sink) = fixture(false);
        let t = ids(1);
        let err = set_color_id(&state, &sink, &t, 9).unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::Malformed, "9 is not a colour from 0 to 8."));
        assert!(sink.names().is_empty());
        set_color_id(&state, &sink, &t, 3).unwrap();
        assert_eq!(details(&state, &t[0]).color, "3");
        set_color_id(&state, &sink, &t, 0).unwrap();
        assert_ne!(details(&state, &t[0]).color, "3", "0 clears the colour");
        edits::undo(&state, &sink).unwrap();
        assert_eq!(details(&state, &t[0]).color, "3");
    }

    #[test]
    fn a_comment_and_fields_are_written_and_validated() {
        let (_dir, state, sink) = fixture(false);
        let t = ids(3);
        set_comment(&state, &sink, &t, "warm").unwrap();
        assert!(t.iter().all(|id| details(&state, id).comment == "warm"));
        set_field(&state, &sink, &t[..1], "title", "Renamed").unwrap();
        set_field(&state, &sink, &t[..1], "year", "1999").unwrap();
        set_field(&state, &sink, &t[..1], "artist", "New Artist").unwrap();
        let d = details(&state, &t[0]);
        assert_eq!((d.title.as_str(), d.year, d.artist.as_str()), ("Renamed", 1999, "New Artist"));
        // The table shows the new title after the full reload.
        let library = state.library().unwrap();
        let row = library.row_of(&t[0]).unwrap() as usize;
        assert_eq!(library.title.get(row), "Renamed");

        sink.clear();
        for (field, value) in [("year", "soon"), ("year", "10000"), ("trackNumber", "-1"), ("key", "Zz#"), ("bogus", "x"), ("bpm", "128")] {
            let err = set_field(&state, &sink, &t[..1], field, value).unwrap_err();
            assert_eq!(err.kind, ErrorKind::Malformed, "{field}={value}");
        }
        assert!(sink.names().is_empty());
        assert_eq!(details(&state, &t[0]).year, 1999);
        edits::undo(&state, &sink).unwrap();
        assert_ne!(details(&state, &t[0]).artist, "New Artist");
    }

    #[test]
    fn a_loose_file_cannot_be_edited() {
        let (_dir, state, sink) = fixture(false);
        let loose = vec!["file:/tmp/x.mp3".to_owned()];
        for result in [
            set_rating(&state, &sink, &loose, 1).map(|_| ()),
            set_comment(&state, &sink, &loose, "x").map(|_| ()),
            set_field(&state, &sink, &loose, "title", "x").map(|_| ()),
            add_to_tag_list(&state, &sink, &loose).map(|_| ()),
            remove_from_collection(&state, &sink, &loose).map(|_| ()),
        ] {
            let err = result.unwrap_err();
            assert_eq!((err.kind, err.message.as_str()), (ErrorKind::Malformed, LOOSE_MESSAGE));
        }
        assert!(sink.names().is_empty());
    }

    #[test]
    fn the_bpm_is_checked_written_and_clears_redo() {
        let (_dir, state, sink) = fixture(false);
        let t = track_id(0);
        for bad in ["", "abc", "39.9", "500", "NaN", "inf"] {
            let err = set_bpm(&state, &sink, &t, bad).unwrap_err();
            assert_eq!((err.kind, err.message.as_str()), (ErrorKind::Malformed, "Enter a BPM from 40 to 499."), "{bad}");
        }
        assert!(sink.names().is_empty());
        // An earlier edit, undone, leaves a redo that the BPM edit drops.
        set_rating(&state, &sink, std::slice::from_ref(&t), 2).unwrap();
        edits::undo(&state, &sink).unwrap();
        assert!(edits::edit_history(&state).can_redo);
        sink.clear();
        let history = set_bpm(&state, &sink, &t, " 124.5 ").unwrap();
        assert_eq!(details(&state, &t).bpm_x100, 12_450);
        assert!(!history.can_redo);
        assert_eq!(sink.names(), ["grid:changed", "library:changed", "edit-history:changed"]);
    }

    #[test]
    fn the_tag_list_takes_tracks_once_in_order_and_gives_them_back() {
        let (_dir, state, sink) = fixture(false);
        let t = ids(3);
        add_to_tag_list(&state, &sink, &t[..2]).unwrap();
        assert_eq!(sink.names(), ["tag-list:changed", "edit-history:changed"]);
        add_to_tag_list(&state, &sink, &t).unwrap();
        assert_eq!(view_ids(&state, TrackSourceDto::TagList), t);
        remove_from_tag_list(&state, &sink, &t[..1]).unwrap();
        assert_eq!(view_ids(&state, TrackSourceDto::TagList), t[1..]);
        sink.clear();
        // One missing track refuses the whole batch.
        let err = add_to_tag_list(&state, &sink, &[track_id(5), "nope".to_owned()]).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
        assert!(sink.names().is_empty());
        assert_eq!(view_ids(&state, TrackSourceDto::TagList), t[1..]);
        clear_tag_list(&state, &sink).unwrap();
        assert!(view_ids(&state, TrackSourceDto::TagList).is_empty());
    }

    #[test]
    fn a_history_loses_plays_and_the_collection_loses_tracks_for_good() {
        let (_dir, state, sink) = fixture(false);
        let history = history_id(0);
        let before = view_ids(&state, TrackSourceDto::History { id: history.clone() });
        assert_eq!(before.len(), 5);
        remove_from_history(&state, &sink, &history, &before[..2]).unwrap();
        assert_eq!(view_ids(&state, TrackSourceDto::History { id: history }).len(), 3);

        // A play count resets, as one undoable step.
        let t = ids(1);
        set_field(&state, &sink, &t, "playCount", "7").unwrap();
        reset_play_count(&state, &sink, &t).unwrap();
        assert_eq!(details(&state, &t[0]).play_count, 0);
        edits::undo(&state, &sink).unwrap();
        assert_eq!(details(&state, &t[0]).play_count, 7);

        // Removing from the collection clears the undo history and the row is gone.
        assert!(edits::edit_history(&state).can_undo);
        sink.clear();
        let victim = track_id(3);
        remove_from_collection(&state, &sink, std::slice::from_ref(&victim)).unwrap();
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"]);
        assert!(!edits::edit_history(&state).can_undo);
        assert!(crate::details::track_details(&state, &victim).is_err());
        assert!(!view_ids(&state, TrackSourceDto::Collection).contains(&victim));
    }

    #[test]
    fn reloading_a_tag_from_a_file_that_is_not_there_is_malformed() {
        let (_dir, state, sink) = fixture(false);
        let err = reload_tags(&state, &sink, &ids(1)).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
        assert!(sink.names().is_empty());
    }

    #[test]
    fn a_play_is_refused_by_the_gate_and_otherwise_counted_and_listed() {
        let (_dir, state, sink) = fixture(true);
        let t = track_id(4);
        let before = details(&state, &t).play_count;
        let err = record_play(&state, &sink, &t).unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::ReadOnly, crate::edits::PROTECTED_MESSAGE));
        assert!(sink.names().is_empty());
        assert_eq!(details(&state, &t).play_count, before);

        state.set_protect_library(false);
        record_play(&state, &sink, &t).unwrap();
        assert_eq!(details(&state, &t).play_count, before + 1);
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"]);
        // Not undoable, but it does not wipe the undo entries behind it.
        set_rating(&state, &sink, std::slice::from_ref(&t), 3).unwrap();
        record_play(&state, &sink, &t).unwrap();
        assert!(edits::edit_history(&state).can_undo);
        assert_eq!(details(&state, &t).play_count, before + 2);

        let err = record_play(&state, &sink, "file:/tmp/x.wav").unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::Malformed, LOOSE_MESSAGE));
        let err = record_play(&state, &sink, "no-such-track").unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
    }
}
