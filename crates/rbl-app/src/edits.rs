//! What an edit changed and how the index follows it. The emit wrappers that
//! drive these live in the shell; nothing here knows about a window.

use crate::dto::{EditHistoryDto, SmartConditionDto, SmartRuleDto};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::{AppEvent, EventSink};
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
        LibraryEdit::Many(edits) => {
            if edits.iter().any(|e| touched_by(e) == Touched::Tracks) { Touched::Tracks } else { Touched::Playlists }
        }
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
        LibraryEdit::Many(edits) => {
            let ordered: Box<dyn Iterator<Item = _>> = if undo { Box::new(edits.iter().rev()) } else { Box::new(edits.iter()) };
            for edit in ordered {
                apply_history(writer, edit, undo)?;
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

// ------------------------------------------------------------ the write gate

/// Shown when Library Protection is on.
pub const PROTECTED_MESSAGE: &str = "Editing is locked by Library Protection. Turn it off in Preferences to edit.";
/// Shown when rekordbox is running against the installed library.
pub const RUNNING_MESSAGE: &str = "Editing is locked while rekordbox is running. Quit rekordbox to enable editing.";

/// Why the native app may not edit right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateRefusal {
    Protected,
    RekordboxRunning,
}

impl GateRefusal {
    pub fn message(self) -> &'static str {
        match self {
            Self::Protected => PROTECTED_MESSAGE,
            Self::RekordboxRunning => RUNNING_MESSAGE,
        }
    }
}

/// The rule, free of any state so it can be tested directly. Protection wins
/// when both apply. A fixture is a file rekordbox has never heard of, so a
/// running rekordbox does not lock it (the same rule `rbl_db` applies).
pub fn gate_refusal(protect_library: bool, is_real_install: bool, rekordbox_running: bool) -> Option<GateRefusal> {
    if protect_library {
        Some(GateRefusal::Protected)
    } else if is_real_install && rekordbox_running {
        Some(GateRefusal::RekordboxRunning)
    } else {
        None
    }
}

impl AppState {
    /// Turns the native write gate on. The native app ignores
    /// `RBX_DISABLE_READ_ONLY`; the Tauri shell never calls this.
    pub fn enable_native_gate(&self) {
        self.native_gate.store(true, std::sync::atomic::Ordering::Release);
    }

    /// Sets Library Protection. Only has an effect once the gate is enabled.
    pub fn set_protect_library(&self, protect: bool) {
        self.protect_library.store(protect, std::sync::atomic::Ordering::Release);
    }

    pub fn protect_library(&self) -> bool {
        self.protect_library.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Replaces the "is rekordbox running" check, so a test can simulate it.
    pub fn set_running_probe(&self, probe: fn() -> bool) {
        *self.running_probe.lock() = probe;
    }

    pub fn native_gate_enabled(&self) -> bool {
        self.native_gate.load(std::sync::atomic::Ordering::Acquire)
    }

    /// The one answer to "may this process edit?" for the native app. `None`
    /// when it may, and always `None` while the gate is off (the Tauri shell).
    pub fn write_gate(&self) -> Option<GateRefusal> {
        if !self.native_gate_enabled() {
            return None;
        }
        let protect = self.protect_library();
        let real = self.location().map_or(true, |l| l.is_real_install);
        // Only scan processes when the answer can depend on it.
        let running = !protect && real && (*self.running_probe.lock())();
        gate_refusal(protect, real, running)
    }
}

/// Refuses with `ReadOnly` and the gate's message when the native gate is closed.
pub fn check_gate(state: &AppState) -> AppResult<()> {
    match state.write_gate() {
        Some(refusal) => Err(AppError::new(ErrorKind::ReadOnly, refusal.message())),
        None => Ok(()),
    }
}

/// True for a refusal that is about the environment (rekordbox, a pending
/// restore, test mode) rather than about what the caller asked for.
fn is_environment_refusal(reason: &str) -> bool {
    ["rekordbox is running", "A library restore", "RBXPORT_TEST"].iter().any(|p| reason.starts_with(p))
}

/// The native mapping: environment refusals are `ReadOnly`, a refusal of the
/// request itself ("no playlist 9", "a rating between 0 and 5") is `Malformed`.
pub fn native_write_error(error: rbl_db::DbError) -> AppError {
    match error {
        rbl_db::DbError::WriteRefused(reason) if is_environment_refusal(&reason) => AppError::new(ErrorKind::ReadOnly, reason),
        rbl_db::DbError::WriteRefused(reason) => AppError::new(ErrorKind::Malformed, reason),
        // A with-undo edit reads the row first; a missing row is the caller's mistake.
        rbl_db::DbError::Sqlite(e) if e.to_string() == "Query returned no rows" => {
            AppError::new(ErrorKind::Malformed, "That item is no longer in the library.")
        }
        other => AppError::new(ErrorKind::Internal, other.to_string()),
    }
}

fn map_error(state: &AppState, error: rbl_db::DbError) -> AppError {
    if state.native_gate_enabled() { native_write_error(error) } else { write_error(error) }
}

// ------------------------------------------------------------- the pipeline

/// What an edit leaves in the undo history.
pub enum Record {
    /// Not undoable; any redo branch is dropped.
    Nothing,
    /// Not undoable, and every older entry may now point at removed rows.
    Permanent,
    /// Undoable. An empty edit is not recorded.
    Entry(LibraryEdit, &'static str),
}

/// What a committed edit hands back.
pub struct Committed<T> {
    pub value: T,
    pub history: EditHistoryDto,
}

/// The single choke point. Checks the gate, runs `action` in a writer, refreshes
/// the index on the same connection, updates the history, and only then (outside
/// the edit gate) emits `LibraryChanged` (or `TagListChanged`) and `EditHistoryChanged`.
pub fn commit_full<T, F>(state: &AppState, sink: &dyn EventSink, touched: Touched, action: F) -> AppResult<Committed<T>>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<(T, Record), rbl_db::DbError>,
{
    check_gate(state)?;
    let announce = touched.clone();
    let (value, history) = {
        let _gate = state.edit_gate.lock();
        let (generation, (value, record)) = state
            .write_then(action, |db, out| refresh_after_edit(state, db, touched).map(|g| (g, out)))
            .map_err(|e| map_error(state, e))?;
        let mut history = state.edit_history.lock();
        match record {
            Record::Nothing => history.clear_redo(),
            Record::Permanent => history.clear(),
            Record::Entry(edit, label) => {
                if !edit.is_empty() {
                    history.record(edit, label);
                }
            }
        }
        (value, (generation, history_dto(generation, &history)))
    };
    let (generation, dto) = history;
    sink.emit(announce.changed(generation));
    sink.emit(AppEvent::EditHistoryChanged(dto.clone()));
    Ok(Committed { value, history: dto })
}

/// A plain (not undoable) edit that yields a value, such as a new id.
pub fn commit_value<T, F>(state: &AppState, sink: &dyn EventSink, touched: Touched, action: F) -> AppResult<(u32, T)>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<T, rbl_db::DbError>,
{
    let done = commit_full(state, sink, touched, |w| action(w).map(|v| (v, Record::Nothing)))?;
    Ok((done.history.generation, done.value))
}

/// A plain (not undoable) edit. Returns the new generation.
pub fn commit<F>(state: &AppState, sink: &dyn EventSink, touched: Touched, action: F) -> AppResult<u32>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<(), rbl_db::DbError>,
{
    commit_value(state, sink, touched, action).map(|(generation, ())| generation)
}

/// An edit that also wipes the undo history.
pub fn commit_permanent<F>(state: &AppState, sink: &dyn EventSink, touched: Touched, action: F) -> AppResult<u32>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<(), rbl_db::DbError>,
{
    commit_full(state, sink, touched, |w| action(w).map(|()| ((), Record::Permanent))).map(|done| done.history.generation)
}

/// An undoable edit: `action` returns the token that reverses it.
pub fn commit_recorded<F>(
    state: &AppState,
    sink: &dyn EventSink,
    touched: Touched,
    label: &'static str,
    action: F,
) -> AppResult<EditHistoryDto>
where
    F: FnOnce(&mut rbl_db::write::Writer) -> Result<LibraryEdit, rbl_db::DbError>,
{
    commit_full(state, sink, touched, |w| action(w).map(|edit| ((), Record::Entry(edit, label)))).map(|done| done.history)
}

/// Re-reads the library and returns the new generation.
pub fn reload(state: &AppState, sink: &dyn EventSink) -> AppResult<u32> {
    let generation = {
        let _gate = state.edit_gate.lock();
        let db = state.open_read_only().map_err(write_error)?;
        let db_version = db.schema().db_version;
        let location = db.location().clone();
        let started = std::time::Instant::now();
        let (library, _) = rbl_index::load(&db).map_err(|e| AppError::new(ErrorKind::Internal, e.to_string()))?;
        let load_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        state.set_library(library, rbl_db::is_rekordbox_running(), db_version, load_ms, location);
        state.summary().3
    };
    sink.emit(AppEvent::LibraryChanged(generation));
    Ok(generation)
}

fn step(state: &AppState, sink: &dyn EventSink, undo: bool) -> AppResult<EditHistoryDto> {
    check_gate(state)?;
    let dto = {
        let _gate = state.edit_gate.lock();
        let entry = {
            let history = state.edit_history.lock();
            let stack = if undo { &history.undo } else { &history.redo };
            stack.last().cloned()
        }
        .ok_or_else(|| {
            AppError::new(ErrorKind::NotFound, if undo { "There is no library edit to undo." } else { "There is no library edit to redo." })
        })?;
        let touched = touched_by(&entry.edit);
        let generation = state
            .write_then(|w| apply_history(w, &entry.edit, undo), |db, ()| refresh_after_edit(state, db, touched))
            .map_err(|e| map_error(state, e))?;
        let mut history = state.edit_history.lock();
        if undo {
            history.undo.pop();
            history.redo.push(entry);
        } else {
            history.redo.pop();
            history.undo.push(entry);
        }
        history_dto(generation, &history)
    };
    sink.emit(AppEvent::LibraryChanged(dto.generation));
    sink.emit(AppEvent::EditHistoryChanged(dto.clone()));
    Ok(dto)
}

pub fn undo(state: &AppState, sink: &dyn EventSink) -> AppResult<EditHistoryDto> {
    step(state, sink, true)
}

pub fn redo(state: &AppState, sink: &dyn EventSink) -> AppResult<EditHistoryDto> {
    step(state, sink, false)
}

/// The current history, without changing anything.
pub fn edit_history(state: &AppState) -> EditHistoryDto {
    let generation = state.summary().3;
    history_dto(generation, &state.edit_history.lock())
}

// ------------------------------------------------- playlists and folders

pub fn create_playlist(state: &AppState, sink: &dyn EventSink, name: &str, parent: &str) -> AppResult<String> {
    commit_value(state, sink, Touched::Playlists, |w| w.create_playlist(name, parent)).map(|(_, id)| id)
}

pub fn create_folder(state: &AppState, sink: &dyn EventSink, name: &str, parent: &str) -> AppResult<String> {
    commit_value(state, sink, Touched::Playlists, |w| w.create_folder(name, parent)).map(|(_, id)| id)
}

pub fn create_smart_playlist(state: &AppState, sink: &dyn EventSink, name: &str, parent: &str, rule: &SmartRuleDto) -> AppResult<String> {
    let rule = rule_from_dto(rule)?;
    commit_value(state, sink, Touched::Playlists, |w| {
        w.create_smart_playlist(name, parent, |id| rule.to_xml(id.parse().unwrap_or(0)))
    })
    .map(|(_, id)| id)
}

pub fn set_smart_rule(state: &AppState, sink: &dyn EventSink, playlist: &str, rule: &SmartRuleDto) -> AppResult<u32> {
    let rule = rule_from_dto(rule)?;
    let xml = rule.to_xml(playlist.parse().unwrap_or(0));
    commit(state, sink, Touched::Playlists, |w| w.set_smart_list(playlist, &xml).map(|_| ()))
}

/// Saves an edited intelligent playlist in one transaction-sized step: the rule,
/// and the name when it changed. One refresh, one event. The rename is the only
/// part undo can reverse (the rule has no history token), as in the React app.
pub fn save_smart_playlist(
    state: &AppState,
    sink: &dyn EventSink,
    playlist: &str,
    name: &str,
    rule: &SmartRuleDto,
) -> AppResult<EditHistoryDto> {
    let rule = rule_from_dto(rule)?;
    let xml = rule.to_xml(playlist.parse().unwrap_or(0));
    commit_full(state, sink, Touched::Playlists, |w| {
        let current = w.library().connection().query_row(
            "SELECT Name FROM djmdPlaylist WHERE ID = ?1 AND rb_local_deleted = 0",
            [playlist],
            |row| row.get::<_, String>(0),
        );
        let renamed = matches!(&current, Ok(before) if before != name);
        // Rule first: it refuses a non-smart id before anything else changes.
        w.set_smart_list(playlist, &xml)?;
        if renamed {
            let (_, edit) = w.rename_with_undo(playlist, name)?;
            Ok(((), Record::Entry(LibraryEdit::RenamePlaylist(edit), "Rename Playlist")))
        } else {
            Ok(((), Record::Nothing))
        }
    })
    .map(|done| done.history)
}

pub fn rename_playlist(state: &AppState, sink: &dyn EventSink, id: &str, name: &str) -> AppResult<EditHistoryDto> {
    commit_recorded(state, sink, Touched::Playlists, "Rename Playlist", |w| {
        w.rename_with_undo(id, name).map(|(_, edit)| LibraryEdit::RenamePlaylist(edit))
    })
}

pub fn move_playlist(state: &AppState, sink: &dyn EventSink, id: &str, parent: &str, index: Option<usize>) -> AppResult<EditHistoryDto> {
    commit_recorded(state, sink, Touched::Playlists, "Move Playlist", |w| {
        w.move_with_undo(id, parent, index).map(|(_, edit)| LibraryEdit::MovePlaylist(edit))
    })
}

pub fn delete_playlist(state: &AppState, sink: &dyn EventSink, id: &str) -> AppResult<EditHistoryDto> {
    commit_recorded(state, sink, Touched::Playlists, "Delete Playlist", |w| {
        w.delete_playlist_with_undo(id).map(|(_, edit)| LibraryEdit::DeletePlaylist(edit))
    })
}

/// Sort Items: a folder's children (or the top level, for `"root"`) in name
/// order, as a single undo entry.
pub fn sort_children(state: &AppState, sink: &dyn EventSink, parent: &str) -> AppResult<EditHistoryDto> {
    let tree = crate::browse::playlist_tree(state)?;
    let heading = if parent == "root" { "playlists" } else { parent };
    let Some(at) = tree.iter().position(|n| n.id == heading) else {
        return Err(AppError::new(ErrorKind::Malformed, format!("no playlist or folder {parent}")));
    };
    let depth = tree[at].depth;
    let mut children: Vec<(&str, &str)> = tree[at + 1..]
        .iter()
        .take_while(|n| n.depth > depth)
        .filter(|n| n.depth == depth + 1)
        .map(|n| (n.id.as_str(), n.name.as_str()))
        .collect();
    children.sort_by_key(|(_, name)| name.to_lowercase());
    let ids: Vec<String> = children.iter().map(|(id, _)| (*id).to_owned()).collect();
    let parent = parent.to_owned();
    commit_recorded(state, sink, Touched::Playlists, "Sort Items", move |w| {
        let mut moves = Vec::with_capacity(ids.len());
        for (index, id) in ids.iter().enumerate() {
            let (_, edit) = w.move_with_undo(id, &parent, Some(index))?;
            moves.push(LibraryEdit::MovePlaylist(edit));
        }
        Ok(LibraryEdit::Many(moves))
    })
}

// -------------------------------------------------- tracks in playlists

/// Appends tracks, skipping ones already there. Returns how many were added.
pub fn add_tracks_to_playlist(state: &AppState, sink: &dyn EventSink, playlist: &str, tracks: &[String]) -> AppResult<u32> {
    let (_, rows) = commit_value(state, sink, Touched::Playlists, |w| w.add_tracks(playlist, tracks).map(|c| c.rows))?;
    Ok(u32::try_from(rows).unwrap_or(u32::MAX))
}

pub fn remove_tracks_from_playlist(state: &AppState, sink: &dyn EventSink, playlist: &str, tracks: &[String]) -> AppResult<EditHistoryDto> {
    commit_recorded(state, sink, Touched::Playlists, "Remove Tracks from Playlist", |w| {
        w.remove_tracks_with_undo(playlist, tracks).map(|(_, edit)| LibraryEdit::RemovePlaylistTracks(edit))
    })
}

pub fn reorder_playlist(state: &AppState, sink: &dyn EventSink, playlist: &str, tracks: &[String]) -> AppResult<u32> {
    commit(state, sink, Touched::Playlists, |w| w.reorder(playlist, tracks).map(|_| ()))
}

// ------------------------------------------------------------ smart rules

/// An intelligent playlist's rule, for the editor. Refused when the rule
/// nests groups, which the editor cannot show without losing them.
pub fn smart_rule(state: &AppState, playlist: &str) -> AppResult<SmartRuleDto> {
    let library = state.library()?;
    let playlists = library.playlists();
    let Some(index) = playlist.parse::<u64>().ok().and_then(|id| playlists.index_of(id)) else {
        return Err(AppError::new(ErrorKind::NotFound, "That playlist is not in the library."));
    };
    let Some(rule) = playlists.smart_rule(index) else {
        // A new intelligent playlist, or one whose rule does not parse,
        // starts from an empty "all of the following".
        return Ok(SmartRuleDto { logic: "all".to_owned(), conditions: Vec::new() });
    };
    rule_to_dto(&rule)
}

pub fn rule_to_dto(rule: &rbl_index::SmartRule) -> AppResult<SmartRuleDto> {
    use rbl_index::smart::{Item, Logic};
    let mut conditions = Vec::with_capacity(rule.root.items.len());
    for item in &rule.root.items {
        match item {
            Item::Condition(c) => conditions.push(SmartConditionDto {
                property: c.property.name().to_owned(),
                operator: c.operator.code().to_owned(),
                left: c.left.clone(),
                right: c.right.clone(),
                unit: c.unit.clone(),
            }),
            Item::Group(_) => {
                return Err(AppError::new(
                    ErrorKind::Malformed,
                    "This intelligent playlist nests groups of conditions, which this editor cannot show.",
                ))
            }
        }
    }
    Ok(SmartRuleDto {
        logic: match rule.root.logic {
            Logic::All => "all",
            Logic::Any => "any",
        }
        .to_owned(),
        conditions,
    })
}

pub fn rule_from_dto(dto: &SmartRuleDto) -> AppResult<rbl_index::SmartRule> {
    use rbl_index::smart::{Condition, Group, Item, Logic, Operator, Property};
    let mut items = Vec::with_capacity(dto.conditions.len());
    for c in &dto.conditions {
        let property = Property::from_name(&c.property);
        if property == Property::Unsupported {
            return Err(AppError::new(ErrorKind::Malformed, format!("{:?} is not a property a rule can use here.", c.property)));
        }
        let Some(operator) = Operator::from_code(&c.operator) else {
            return Err(AppError::new(ErrorKind::Malformed, format!("{:?} is not an operator.", c.operator)));
        };
        items.push(Item::Condition(Condition { property, operator, left: c.left.clone(), right: c.right.clone(), unit: c.unit.clone() }));
    }
    Ok(rbl_index::SmartRule { root: Group { logic: if dto.logic == "any" { Logic::Any } else { Logic::All }, items } })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic, clippy::assert_is_empty)]
mod tests {
    use super::*;
    use crate::browse;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Recorder(Mutex<Vec<AppEvent>>);

    impl EventSink for Recorder {
        fn emit(&self, event: AppEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    impl Recorder {
        fn names(&self) -> Vec<&'static str> {
            self.0.lock().unwrap().iter().map(AppEvent::name).collect()
        }
        fn clear(&self) {
            self.0.lock().unwrap().clear();
        }
    }

    /// A fixture-backed state with the native gate on. Nothing here can reach
    /// the installed library: the location is a temp-dir fixture.
    fn fixture(protect: bool) -> (tempfile::TempDir, Arc<AppState>, Recorder) {
        let dir = tempfile::tempdir().unwrap();
        let location = rbl_db::fixture::build(dir.path(), rbl_db::fixture::Shape::default()).unwrap();
        assert!(!location.is_real_install);
        let db = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).unwrap();
        let (library, _) = rbl_index::load(&db).unwrap();
        let state = Arc::new(AppState::with_backups(dir.path().join("backups")));
        state.set_library(library, false, db.schema().db_version, 0, location);
        state.enable_native_gate();
        state.set_protect_library(protect);
        (dir, state, Recorder::default())
    }

    fn names(state: &AppState) -> Vec<String> {
        browse::playlist_tree(state).unwrap().into_iter().filter(|n| matches!(n.kind, "playlist" | "folder" | "smartPlaylist")).map(|n| n.name).collect()
    }

    fn find(state: &AppState, name: &str) -> String {
        browse::playlist_tree(state).unwrap().into_iter().find(|n| n.name == name).unwrap().id
    }

    #[test]
    fn the_gate_rule_prefers_protection_and_spares_fixtures() {
        assert_eq!(gate_refusal(true, true, true), Some(GateRefusal::Protected));
        assert_eq!(gate_refusal(true, false, false), Some(GateRefusal::Protected));
        assert_eq!(gate_refusal(false, true, true), Some(GateRefusal::RekordboxRunning));
        assert_eq!(gate_refusal(false, true, false), None);
        assert_eq!(gate_refusal(false, false, true), None, "a fixture is not rekordbox's file");
        assert_eq!(GateRefusal::Protected.message(), PROTECTED_MESSAGE);
    }

    #[test]
    fn a_closed_gate_refuses_every_edit_without_a_trace() {
        let (_dir, state, sink) = fixture(true);
        let before = names(&state);
        let generation = state.summary().3;
        let err = create_playlist(&state, &sink, "New", "root").unwrap_err();
        assert_eq!(err.kind, ErrorKind::ReadOnly);
        assert_eq!(err.message, PROTECTED_MESSAGE);
        assert_eq!(undo(&state, &sink).unwrap_err().kind, ErrorKind::ReadOnly);
        assert_eq!(rename_playlist(&state, &sink, "1", "x").unwrap_err().message, PROTECTED_MESSAGE);
        assert!(sink.names().is_empty());
        assert_eq!(names(&state), before);
        assert_eq!(state.summary().3, generation);
        assert!(browse::library_summary(&state).unwrap().read_only);
    }

    #[test]
    fn summary_read_only_equals_the_gate() {
        let (_dir, state, _sink) = fixture(true);
        assert!(browse::library_summary(&state).unwrap().read_only);
        state.set_protect_library(false);
        assert!(state.write_gate().is_none());
        assert!(!browse::library_summary(&state).unwrap().read_only);
        // The stored startup flag does not leak through while the gate is on.
        state.set_protect_library(true);
        assert_eq!(browse::library_summary(&state).unwrap().read_only, state.write_gate().is_some());
    }

    #[test]
    fn a_running_rekordbox_closes_the_gate_on_the_installed_library_only() {
        let (_dir, state, sink) = fixture(false);
        state.set_running_probe(|| true);
        assert!(state.write_gate().is_none(), "the fixture is unaffected");
        // Pretend this temp copy is the installed library. The gate answers before
        // any database is opened, so nothing is written either way.
        let mut location = state.location().unwrap();
        location.is_real_install = true;
        let library = state.library().unwrap();
        state.set_library((*library).clone(), false, None, 0, location);
        assert_eq!(state.write_gate(), Some(GateRefusal::RekordboxRunning));
        let err = create_folder(&state, &sink, "F", "root").unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::ReadOnly, RUNNING_MESSAGE));
        assert!(browse::library_summary(&state).unwrap().read_only);
        assert!(sink.names().is_empty());
        state.set_running_probe(|| false);
        assert!(state.write_gate().is_none());
    }

    #[test]
    fn environment_refusals_are_read_only_and_bad_requests_are_malformed() {
        use rbl_db::DbError::WriteRefused;
        assert_eq!(native_write_error(WriteRefused("rekordbox is running. Quit it before making changes.".into())).kind, ErrorKind::ReadOnly);
        assert_eq!(native_write_error(WriteRefused("A library restore is unfinished. Restart".into())).kind, ErrorKind::ReadOnly);
        assert_eq!(native_write_error(WriteRefused("9 is not a rating between 0 and 5".into())).kind, ErrorKind::Malformed);
        assert_eq!(write_error(WriteRefused("9 is not a rating between 0 and 5".into())).kind, ErrorKind::ReadOnly, "the Tauri mapping is unchanged");
    }

    #[test]
    fn create_returns_the_id_and_events_arrive_in_order() {
        let (_dir, state, sink) = fixture(false);
        let id = create_playlist(&state, &sink, "Warm Up", "root").unwrap();
        assert_eq!(find(&state, "Warm Up"), id);
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"]);
        let folder = create_folder(&state, &sink, "Sets", "root").unwrap();
        let nested = create_playlist(&state, &sink, "Peak", &folder).unwrap();
        assert_ne!(nested, folder);
        let tree = browse::playlist_tree(&state).unwrap();
        let depth = |id: &str| tree.iter().find(|n| n.id == id).unwrap().depth;
        assert_eq!(depth(&nested), depth(&folder) + 1);
    }

    #[test]
    fn rename_undo_redo_round_trip_through_the_history_labels() {
        let (_dir, state, sink) = fixture(false);
        let id = create_playlist(&state, &sink, "Before", "root").unwrap();
        sink.clear();
        let history = rename_playlist(&state, &sink, &id, "After").unwrap();
        assert_eq!(history.undo_label.as_deref(), Some("Rename Playlist"));
        assert!(history.can_undo && !history.can_redo);
        assert!(names(&state).contains(&"After".to_owned()));
        let history = undo(&state, &sink).unwrap();
        assert!(!history.can_undo && history.can_redo);
        assert_eq!(history.redo_label.as_deref(), Some("Rename Playlist"));
        assert!(names(&state).contains(&"Before".to_owned()));
        redo(&state, &sink).unwrap();
        assert!(names(&state).contains(&"After".to_owned()));
        assert_eq!(undo(&state, &sink).and_then(|_| undo(&state, &sink)).unwrap_err().kind, ErrorKind::NotFound);
        assert_eq!(sink.names().iter().filter(|n| **n == "edit-history:changed").count(), 4);
    }

    #[test]
    fn a_folder_cannot_move_into_itself_or_its_children() {
        let (_dir, state, sink) = fixture(false);
        let outer = create_folder(&state, &sink, "Outer", "root").unwrap();
        let inner = create_folder(&state, &sink, "Inner", &outer).unwrap();
        sink.clear();
        let generation = state.summary().3;
        for target in [&outer, &inner] {
            let err = move_playlist(&state, &sink, &outer, target, None).unwrap_err();
            assert_eq!(err.kind, ErrorKind::Malformed, "{}", err.message);
        }
        assert!(sink.names().is_empty());
        assert_eq!(state.summary().3, generation);
        assert_eq!(move_playlist(&state, &sink, "nope", "root", None).unwrap_err().kind, ErrorKind::Malformed);
    }

    #[test]
    fn deleting_a_playlist_undoes_exactly_and_sort_is_one_entry() {
        let (_dir, state, sink) = fixture(false);
        let folder = create_folder(&state, &sink, "Sorted", "root").unwrap();
        for name in ["charlie", "Alpha", "bravo"] {
            create_playlist(&state, &sink, name, &folder).unwrap();
        }
        let order = |state: &AppState| names(state).into_iter().filter(|n| ["charlie", "Alpha", "bravo"].contains(&n.as_str())).collect::<Vec<_>>();
        assert_eq!(order(&state), ["charlie", "Alpha", "bravo"]);
        let depth_before = state.edit_history.lock().undo.len();
        sort_children(&state, &sink, &folder).unwrap();
        assert_eq!(order(&state), ["Alpha", "bravo", "charlie"]);
        assert_eq!(state.edit_history.lock().undo.len(), depth_before + 1);
        let history = undo(&state, &sink).unwrap();
        assert_eq!(history.redo_label.as_deref(), Some("Sort Items"));
        assert_eq!(order(&state), ["charlie", "Alpha", "bravo"]);
        redo(&state, &sink).unwrap();
        assert_eq!(order(&state), ["Alpha", "bravo", "charlie"]);

        let id = find(&state, "bravo");
        delete_playlist(&state, &sink, &id).unwrap();
        assert!(!names(&state).contains(&"bravo".to_owned()));
        undo(&state, &sink).unwrap();
        assert_eq!(find(&state, "bravo"), id);
    }

    #[test]
    fn tracks_are_added_once_reordered_and_removed_with_undo() {
        let (_dir, state, sink) = fixture(false);
        let id = create_playlist(&state, &sink, "Mix", "root").unwrap();
        let tracks: Vec<String> = (1..=3).map(rbl_db::fixture::track_id).collect();
        assert_eq!(add_tracks_to_playlist(&state, &sink, &id, &tracks).unwrap(), 3);
        assert_eq!(add_tracks_to_playlist(&state, &sink, &id, &tracks[..2]).unwrap(), 0, "already there");
        let view = |state: &AppState| {
            let spec = crate::dto::ViewSpecDto {
                source: crate::dto::TrackSourceDto::Playlist { id: id.clone() },
                sort: "trackNo".into(),
                descending: false,
                query: String::new(),
                search_field: rbl_index::SearchField::default(),
                filter: crate::dto::TrackFilterDto::default(),
            };
            let handle = browse::open_view(state, &spec).unwrap();
            browse::view_ids_in_range(state, handle.view_id, 0, handle.len - 1).unwrap()
        };
        assert_eq!(view(&state), tracks);
        let reversed: Vec<String> = tracks.iter().rev().cloned().collect();
        reorder_playlist(&state, &sink, &id, &reversed).unwrap();
        assert_eq!(view(&state), reversed);
        remove_tracks_from_playlist(&state, &sink, &id, &tracks[..1]).unwrap();
        assert_eq!(view(&state).len(), 2);
        undo(&state, &sink).unwrap();
        assert_eq!(view(&state), reversed);
        assert_eq!(add_tracks_to_playlist(&state, &sink, "424242", &tracks).unwrap_err().kind, ErrorKind::Malformed);
    }

    #[test]
    fn a_smart_playlist_saves_its_rule_and_name_together() {
        let (_dir, state, sink) = fixture(false);
        let rule = SmartRuleDto {
            logic: "any".into(),
            conditions: vec![SmartConditionDto { property: "artist".into(), operator: "8".into(), left: "a".into(), right: String::new(), unit: String::new() }],
        };
        let id = create_smart_playlist(&state, &sink, "Smart", "root", &rule).unwrap();
        assert_eq!(smart_rule(&state, &id).unwrap().logic, "any");
        let mut edited = rule.clone();
        edited.logic = "all".into();
        edited.conditions.push(SmartConditionDto { property: "rating".into(), operator: "3".into(), left: "3".into(), right: String::new(), unit: String::new() });
        sink.clear();
        let history = save_smart_playlist(&state, &sink, &id, "Smarter", &edited).unwrap();
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"], "one refresh for rule and name");
        assert_eq!(history.undo_label.as_deref(), Some("Rename Playlist"));
        let stored = smart_rule(&state, &id).unwrap();
        assert_eq!((stored.logic.as_str(), stored.conditions.len()), ("all", 2));
        assert!(names(&state).contains(&"Smarter".to_owned()));
        // A rule naming a property that cannot be written is refused before anything changes.
        let mut bad = edited;
        bad.conditions[0].property = String::new();
        sink.clear();
        assert_eq!(save_smart_playlist(&state, &sink, &id, "Nope", &bad).unwrap_err().kind, ErrorKind::Malformed);
        assert!(sink.names().is_empty());
        assert!(!names(&state).contains(&"Nope".to_owned()));
        // A plain playlist is not a smart one.
        let plain = create_playlist(&state, &sink, "Plain", "root").unwrap();
        assert_eq!(set_smart_rule(&state, &sink, &plain, &rule).unwrap_err().kind, ErrorKind::Malformed);
    }
}
