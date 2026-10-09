//! Cue editing: adding, moving and deleting memory cues, hot cues and loops.
//!
//! The four commands here are the only way a cue reaches the writer. They are
//! shaped like the `set_track_*` edits in `commands.rs` — opened per action,
//! refused while rekordbox holds the database, backed up before the first
//! write — with one difference in what happens after: a cue edit changes one
//! track's cues and nothing else, so only that track's rows are re-read
//! (0.6 ms on the reference library [OBS]) and `cues:changed` names the
//! track, rather than reloading the library and dropping every cached page.
//!
//! What the writer does with each column is settled in `rbl-db/src/write.rs`;
//! nothing here chooses a value.

use rbl_index::Cue;
use serde::Deserialize;

use crate::edits::{check_gate, native_write_error, write_error};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::{AppEvent, EventSink};
use crate::state::AppState;

/// Which slot a new cue goes in: `"memory"`, or `{ "hot": "A" }`.
///
/// Read from the wire as one or the other rather than a tagged enum, so the
/// frontend spells a memory cue as the one word rekordbox uses for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CueKind {
    Memory,
    /// A hot cue, by its letter `A` to `P`.
    Hot(char),
}

impl CueKind {
    /// The `djmdCue.Kind` this is stored as, or a refusal naming the letter.
    pub fn number(&self) -> AppResult<u8> {
        match self {
            Self::Memory => Ok(Cue::MEMORY),
            Self::Hot(letter) => Cue::kind_of_letter(*letter).ok_or_else(|| {
                AppError::new(ErrorKind::Malformed, format!("{letter:?} is not a hot cue slot rekordbox has"))
            }),
        }
    }
}

impl<'de> Deserialize<'de> for CueKind {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Wire {
            Word(String),
            Hot { hot: String },
        }
        match Wire::deserialize(deserializer)? {
            Wire::Word(word) if word == "memory" => Ok(Self::Memory),
            Wire::Word(word) => Err(serde::de::Error::custom(format!(
                "{word:?} is not a cue kind; use \"memory\" or {{ \"hot\": \"A\" }}"
            ))),
            Wire::Hot { hot } => {
                let mut letters = hot.chars();
                match (letters.next(), letters.next()) {
                    (Some(letter), None) => Ok(Self::Hot(letter)),
                    _ => Err(serde::de::Error::custom(format!("{hot:?} is not one hot cue letter"))),
                }
            }
        }
    }
}

/// One cue edit, as the writer applies it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CueEdit {
    Add { track: String, kind: CueKind, position_ms: u32 },
    AddLoop { track: String, kind: CueKind, in_ms: u32, out_ms: u32, beats: u16 },
    Move { cue: String, position_ms: u32 },
    Colour { cue: String, colour: Option<u8> },
    Delete { cue: String },
}

/// What an edit did: the cue it touched and the track whose cues to re-read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CueChange {
    pub track: String,
    pub cue: String,
}

/// Applies one edit through an open writer.
///
/// Apart from the commands so it can be tested against a fixture in a tempdir
/// without a Tauri app: everything the commands add around this is the
/// blocking thread and the reload.
pub fn apply(writer: &mut rbl_db::write::Writer, edit: CueEdit) -> AppResult<CueChange> {
    apply_with(writer, edit, write_error)
}

/// [`apply`] with the caller's mapping of a writer refusal onto an error.
pub fn apply_with(
    writer: &mut rbl_db::write::Writer,
    edit: CueEdit,
    map: fn(rbl_db::DbError) -> AppError,
) -> AppResult<CueChange> {
    let write_error = map;
    match edit {
        CueEdit::Add { track, kind, position_ms } => {
            let cue = writer.add_cue(&track, kind.number()?, position_ms).map_err(write_error)?;
            Ok(CueChange { track, cue })
        }
        CueEdit::AddLoop { track, kind, in_ms, out_ms, beats } => {
            let cue = writer
                .add_loop(&track, kind.number()?, in_ms, out_ms, beats)
                .map_err(write_error)?;
            Ok(CueChange { track, cue })
        }
        CueEdit::Move { cue, position_ms } => {
            let track = owner_of(writer, &cue, map)?;
            let changed = writer.move_cue(&cue, position_ms).map_err(write_error)?;
            if changed.rows == 0 {
                return Err(AppError::new(ErrorKind::NotFound, format!("no cue {cue}")));
            }
            Ok(CueChange { track, cue })
        }
        CueEdit::Colour { cue, colour } => {
            let track = owner_of(writer, &cue, map)?;
            let changed = writer.set_cue_colour(&cue, colour).map_err(write_error)?;
            if changed.rows == 0 {
                return Err(AppError::new(ErrorKind::NotFound, format!("no cue {cue}")));
            }
            Ok(CueChange { track, cue })
        }
        CueEdit::Delete { cue } => {
            // Looked up before the delete: a deleted cue no longer reports an
            // owner, and the owner is whose cues the index has to re-read.
            let track = owner_of(writer, &cue, map)?;
            let changed = writer.delete_cue(&cue).map_err(write_error)?;
            if changed.rows == 0 {
                return Err(AppError::new(ErrorKind::NotFound, format!("no cue {cue}")));
            }
            Ok(CueChange { track, cue })
        }
    }
}

fn owner_of(writer: &rbl_db::write::Writer, cue: &str, map: fn(rbl_db::DbError) -> AppError) -> AppResult<String> {
    writer
        .cue_owner(cue)
        .map_err(map)?
        .ok_or_else(|| AppError::new(ErrorKind::NotFound, format!("no cue {cue}")))
}

/// Applies one edit through the write gate, re-reads that track's cues, and
/// tells the interface which track changed. Blocking.
///
/// Reads are not undoable: cue edits leave the undo history alone (the player
/// owns its own history), as in the Tauri shell.
pub fn edit_cues(state: &AppState, sink: &dyn EventSink, edit: CueEdit) -> AppResult<CueChange> {
    check_gate(state)?;
    let library = state.library()?;
    let map: fn(rbl_db::DbError) -> AppError = if state.native_gate_enabled() { native_write_error } else { write_error };
    let applied = state
        .write_then(
            |writer| Ok(apply_with(writer, edit, map)),
            |db, applied| match applied {
                Ok(change) => {
                    rbl_index::reload_cues_of(db, &library, &change.track)?;
                    Ok(Ok(change))
                }
                Err(e) => Ok(Err(e)),
            },
        )
        .map_err(map)??;
    // The track's id, well inside the 1 KB event cap. Every deck showing the
    // track refetches its cues; nothing else has anything to do.
    sink.emit(AppEvent::CuesChanged(applied.track.clone()));
    Ok(applied)
}

pub fn add_cue(state: &AppState, sink: &dyn EventSink, track: &str, kind: CueKind, position_ms: u32) -> AppResult<String> {
    edit_cues(state, sink, CueEdit::Add { track: track.to_owned(), kind, position_ms }).map(|c| c.cue)
}

/// Adds a loop: a cue with an out point. `beats` is 0 when unknown.
pub fn add_loop(state: &AppState, sink: &dyn EventSink, track: &str, kind: CueKind, in_ms: u32, out_ms: u32, beats: u16) -> AppResult<String> {
    edit_cues(state, sink, CueEdit::AddLoop { track: track.to_owned(), kind, in_ms, out_ms, beats }).map(|c| c.cue)
}

pub fn move_cue(state: &AppState, sink: &dyn EventSink, cue: &str, position_ms: u32) -> AppResult<()> {
    edit_cues(state, sink, CueEdit::Move { cue: cue.to_owned(), position_ms }).map(|_| ())
}

pub fn set_cue_colour(state: &AppState, sink: &dyn EventSink, cue: &str, colour: Option<u8>) -> AppResult<()> {
    edit_cues(state, sink, CueEdit::Colour { cue: cue.to_owned(), colour }).map(|_| ())
}

pub fn delete_cue(state: &AppState, sink: &dyn EventSink, cue: &str) -> AppResult<()> {
    edit_cues(state, sink, CueEdit::Delete { cue: cue.to_owned() }).map(|_| ())
}

/// Convert Memory Cues to Hot Cues: each memory cue, in order of position,
/// becomes a hot cue in the next free slot from A, loops staying loops. The
/// memory cues are kept. Returns how many were made.
pub fn convert_memory_cues_to_hot(state: &AppState, sink: &dyn EventSink, track: &str) -> AppResult<u32> {
    let library = state.library()?;
    let Some(row) = library.row_of(track) else {
        return Err(AppError::new(ErrorKind::NotFound, "That track is not in the library."));
    };
    let plan = conversion_plan(&library.cues_of(row));
    let mut made = 0;
    for (letter, position_ms, out_ms) in plan {
        let kind = CueKind::Hot(letter);
        if out_ms > position_ms {
            add_loop(state, sink, track, kind, position_ms, out_ms, 0)?;
        } else {
            add_cue(state, sink, track, kind, position_ms)?;
        }
        made += 1;
    }
    Ok(made)
}

/// Which hot cue each memory cue becomes: `(letter, in, out)`, memory cues
/// by position into the free letters in order.
fn conversion_plan(cues: &[Cue]) -> Vec<(char, u32, u32)> {
    let taken: Vec<char> = cues.iter().filter_map(Cue::hot_letter).collect();
    let mut free = ('A'..='P').filter(|letter| !taken.contains(letter));
    let mut memory: Vec<&Cue> = cues.iter().filter(|c| c.is_memory()).collect();
    memory.sort_by_key(|c| c.position_ms);
    memory
        .into_iter()
        .filter_map(|cue| free.next().map(|letter| (letter, cue.position_ms, cue.out_ms)))
        .collect()
}

#[cfg(test)]
mod tests {
    // Every test builds its own library in a tempdir, the way the writer's
    // own tests do. `RBXPORT_TEST` makes the writer refuse the real install
    // as well, and a fixture is never marked as one.
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::assert_is_empty)]

    use super::*;
    use rbl_db::fixture::{self, track_id, Shape};
    use rbl_db::write::Writer;
    use rbl_db::{Library as Db, OpenMode};

    struct Fixture {
        _dir: tempfile::TempDir,
        writer: Writer,
        library: rbl_index::Library,
    }

    fn open() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let location = fixture::build(dir.path(), Shape::default()).expect("build the fixture");
        let writer = Writer::open(location.clone(), dir.path().join("backups")).expect("writer");
        let db = Db::open(location, OpenMode::ReadOnly).expect("read-only");
        let (library, _) = rbl_index::load(&db).expect("index");
        Fixture { _dir: dir, writer, library }
    }

    impl Fixture {
        /// What `edit_cues` does after `apply`, without the Tauri app.
        fn reload(&self, track: &str) {
            let db = Db::open(self.writer.library().location().clone(), OpenMode::ReadOnly).unwrap();
            rbl_index::reload_cues_of(&db, &self.library, track).unwrap();
        }

        fn cues(&self, track: &str) -> Vec<Cue> {
            self.library.cues_of(self.library.row_of(track).unwrap())
        }
    }

    fn kind(json: &str) -> Result<CueKind, serde_json::Error> {
        serde_json::from_str(json)
    }

    #[test]
    fn the_kind_is_the_word_memory_or_a_hot_cue_letter() {
        assert_eq!(kind("\"memory\"").unwrap(), CueKind::Memory);
        assert_eq!(kind("{\"hot\":\"A\"}").unwrap(), CueKind::Hot('A'));
        assert_eq!(kind("{\"hot\":\"p\"}").unwrap(), CueKind::Hot('p'));
        assert!(kind("\"hot\"").is_err(), "a hot cue needs its letter");
        assert!(kind("{\"hot\":\"AB\"}").is_err());
        assert!(kind("{\"hot\":\"\"}").is_err());
        assert!(kind("3").is_err());
    }

    #[test]
    fn a_letter_past_p_is_refused_as_malformed_not_written() {
        let mut f = open();
        let track = track_id(0);
        let err = apply(
            &mut f.writer,
            CueEdit::Add { track: track.clone(), kind: CueKind::Hot('Q'), position_ms: 1 },
        )
        .unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
        f.reload(&track);
        assert_eq!(f.cues(&track), [] as [rbl_index::Cue; 0]);
    }

    #[test]
    fn a_memory_cue_is_added_moved_and_deleted_and_the_index_follows() {
        let mut f = open();
        let track = track_id(2);

        let added = apply(
            &mut f.writer,
            CueEdit::Add { track: track.clone(), kind: CueKind::Memory, position_ms: 30_000 },
        )
        .unwrap();
        assert_eq!(added.track, track);
        f.reload(&added.track);
        let cues = f.cues(&track);
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].id.to_string(), added.cue);
        assert!(cues[0].is_memory());

        let moved = apply(
            &mut f.writer,
            CueEdit::Move { cue: added.cue.clone(), position_ms: 45_000 },
        )
        .unwrap();
        assert_eq!(moved.track, track, "the track is found from the cue alone");
        f.reload(&moved.track);
        assert_eq!(f.cues(&track)[0].position_ms, 45_000);

        let deleted = apply(&mut f.writer, CueEdit::Delete { cue: added.cue.clone() }).unwrap();
        assert_eq!(deleted.track, track);
        f.reload(&deleted.track);
        assert_eq!(f.cues(&track), [] as [rbl_index::Cue; 0]);
    }

    #[test]
    fn a_hot_cue_lands_in_its_slot_and_a_loop_keeps_its_end() {
        let mut f = open();
        let track = track_id(1);
        apply(
            &mut f.writer,
            CueEdit::Add { track: track.clone(), kind: CueKind::Hot('D'), position_ms: 5_000 },
        )
        .unwrap();
        apply(
            &mut f.writer,
            CueEdit::AddLoop {
                track: track.clone(),
                kind: CueKind::Memory,
                in_ms: 8_000,
                out_ms: 12_000,
                beats: 8,
            },
        )
        .unwrap();
        f.reload(&track);
        let cues = f.cues(&track);
        assert_eq!(cues.len(), 2);
        assert_eq!(cues[0].hot_letter(), Some('D'));
        assert_eq!(cues[0].out_ms, 0);
        assert!(cues[1].is_memory());
        assert_eq!((cues[1].position_ms, cues[1].out_ms), (8_000, 12_000));
    }

    #[test]
    fn the_browser_row_s_letters_follow_a_hot_cue_edit_without_a_reload() {
        // What `fetch_rows` hands the browser after an edit: the same
        // `rows_to_dto` over the same index, with only the track re-read.
        use crate::state::rows_to_dto;
        let mut f = open();
        let track = track_id(1);
        let row = f.library.row_of(&track).unwrap();
        let letters = |f: &Fixture| {
            rows_to_dto(&f.library, &[row], 0).remove(0).hot_cues.iter().map(|c| c.0).collect::<String>()
        };
        assert_eq!(letters(&f), "");

        let d = apply(
            &mut f.writer,
            CueEdit::Add { track: track.clone(), kind: CueKind::Hot('D'), position_ms: 9_000 },
        )
        .unwrap();
        apply(
            &mut f.writer,
            CueEdit::Add { track: track.clone(), kind: CueKind::Hot('A'), position_ms: 20_000 },
        )
        .unwrap();
        apply(
            &mut f.writer,
            CueEdit::Add { track: track.clone(), kind: CueKind::Memory, position_ms: 1_000 },
        )
        .unwrap();
        f.reload(&track);
        assert_eq!(letters(&f), "AD", "letter order, and the memory cue is not a letter");

        apply(&mut f.writer, CueEdit::Delete { cue: d.cue }).unwrap();
        f.reload(&track);
        assert_eq!(letters(&f), "A");
    }

    #[test]
    fn a_loop_that_ends_before_it_starts_is_refused_as_read_only() {
        // The writer's refusals all map onto `ReadOnly`, which is what the
        // interface shows in the status bar; nothing is written.
        let mut f = open();
        let track = track_id(1);
        let err = apply(
            &mut f.writer,
            CueEdit::AddLoop { track: track.clone(), kind: CueKind::Memory, in_ms: 9_000, out_ms: 9_000, beats: 0 },
        )
        .unwrap_err();
        assert_eq!(err.kind, ErrorKind::ReadOnly);
        f.reload(&track);
        assert_eq!(f.cues(&track), [] as [rbl_index::Cue; 0]);
    }

    #[test]
    fn a_cue_that_is_not_there_is_not_found_rather_than_silently_done() {
        let mut f = open();
        let err = apply(&mut f.writer, CueEdit::Delete { cue: "404".to_owned() }).unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotFound);
        let err = apply(&mut f.writer, CueEdit::Move { cue: "404".to_owned(), position_ms: 1 }).unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotFound);
        // Deleting twice: the second time the cue has no owner to report.
        let track = track_id(0);
        let added = apply(
            &mut f.writer,
            CueEdit::Add { track, kind: CueKind::Memory, position_ms: 1 },
        )
        .unwrap();
        apply(&mut f.writer, CueEdit::Delete { cue: added.cue.clone() }).unwrap();
        let err = apply(&mut f.writer, CueEdit::Delete { cue: added.cue }).unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotFound);
    }

    #[test]
    fn a_track_that_is_not_there_is_refused() {
        let mut f = open();
        let err = apply(
            &mut f.writer,
            CueEdit::Add { track: "no-such-track".to_owned(), kind: CueKind::Memory, position_ms: 1 },
        )
        .unwrap_err();
        assert_eq!(err.kind, ErrorKind::ReadOnly);
    }

    #[test]
    fn memory_cues_take_the_free_hot_slots_in_order_of_position() {
        let cue = |id: u32, kind: u8, position_ms: u32, out_ms: u32| Cue { id, position_ms, out_ms, kind, colour: 0 };
        // B is taken; a loop and two plain memory cues, out of order.
        let cues = vec![cue(1, 2, 5_000, 0), cue(2, 0, 30_000, 0), cue(3, 0, 10_000, 14_000), cue(4, 0, 1_000, 0)];
        assert_eq!(conversion_plan(&cues), vec![('A', 1_000, 0), ('C', 10_000, 14_000), ('D', 30_000, 0)]);
        // Sixteen slots: the seventeenth memory cue has nowhere to go.
        let many: Vec<Cue> = (0..17).map(|i| cue(i, 0, i * 1000, 0)).collect();
        assert_eq!(conversion_plan(&many).len(), 16);
        assert_eq!(conversion_plan(&[cue(1, 1, 0, 0)]), [] as [(char, u32, u32); 0]);
    }

    #[test]
    fn the_gate_refuses_a_cue_write_and_an_open_gate_round_trips_one() {
        use crate::test_support::fixture as gated;
        let (_dir, state, sink) = gated(true);
        let track = track_id(2);
        let err = add_cue(&state, &sink, &track, CueKind::Hot('A'), 1_000).unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::ReadOnly, crate::edits::PROTECTED_MESSAGE));
        assert!(sink.names().is_empty());
        let cues_of = |state: &AppState| {
            let library = state.library().unwrap();
            library.cues_of(library.row_of(&track).unwrap())
        };
        assert!(cues_of(&state).is_empty());

        state.set_protect_library(false);
        let hot = add_cue(&state, &sink, &track, CueKind::Hot('A'), 1_000).unwrap();
        let memory = add_cue(&state, &sink, &track, CueKind::Memory, 5_000).unwrap();
        add_loop(&state, &sink, &track, CueKind::Memory, 8_000, 12_000, 8).unwrap();
        assert_eq!(sink.names(), ["cues:changed"; 3]);
        let cues = cues_of(&state);
        assert_eq!(cues.len(), 3);
        assert_eq!(cues.iter().filter_map(Cue::hot_letter).collect::<String>(), "A");

        set_cue_colour(&state, &sink, &hot, Some(49)).unwrap();
        assert_eq!(cues_of(&state).iter().find(|c| c.hot_letter() == Some('A')).unwrap().colour, 49);
        move_cue(&state, &sink, &memory, 6_000).unwrap();
        delete_cue(&state, &sink, &hot).unwrap();
        delete_cue(&state, &sink, &memory).unwrap();
        let left = cues_of(&state);
        assert_eq!(left.len(), 1);
        assert_eq!((left[0].position_ms, left[0].out_ms), (8_000, 12_000));
        assert_eq!(sink.names().len(), 7);

        // The request's own faults are Malformed natively, and write nothing.
        sink.clear();
        let err = add_loop(&state, &sink, &track, CueKind::Memory, 9_000, 9_000, 0).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed);
        let err = delete_cue(&state, &sink, "404").unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotFound);
        assert!(sink.names().is_empty());

        // Memory cues convert to hot cues through the same gate.
        assert_eq!(convert_memory_cues_to_hot(&state, &sink, &track).unwrap(), 1);
        assert_eq!(cues_of(&state).iter().filter_map(Cue::hot_letter).collect::<String>(), "A");
    }
}
