//! The Info panel's BPM field: one tempo for the whole beat grid, written to
//! the analysis files and the row in one durable step. Shared by the Tauri shell
//! (which adds its grid-lock bookkeeping around it) and the native app.

use std::path::Path;

use rbl_anlz::grid::{apply_with_duration, Edit};
use rbl_anlz::Beat;

use crate::edits::write_error;
use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::AppState;

/// The message for a BPM outside what the grid editor accepts.
pub const BPM_RANGE_MESSAGE: &str = "Enter a BPM from 40 to 499.";

/// Parses a typed BPM and checks it is 40 to 499. Returns hundredths of a BPM.
pub fn parse_bpm(value: &str) -> AppResult<u16> {
    let bpm: f64 = value.trim().parse().map_err(|_| AppError::new(ErrorKind::Malformed, BPM_RANGE_MESSAGE))?;
    if !bpm.is_finite() || !(40.0..=499.0).contains(&bpm) {
        return Err(AppError::new(ErrorKind::Malformed, BPM_RANGE_MESSAGE));
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "validated 40..=499 above")]
    Ok((bpm * 100.0).round() as u16)
}

/// Whether the track's grid is locked in the database (`Analysed` bit 128).
pub fn database_locked(location: &rbl_db::LibraryLocation, track: &str) -> AppResult<bool> {
    let db = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).map_err(write_error)?;
    db.connection()
        .query_row(
            "SELECT (COALESCE(Analysed, 0) & 128) != 0 FROM djmdContent WHERE ID=?1 AND rb_local_deleted=0",
            [track],
            |r| r.get(0),
        )
        .map_err(|e| AppError::internal(e.to_string()))
}

/// The analysis file and its beats, `PQTZ` offset applied.
pub fn read_dat(dat: &Path) -> AppResult<(rbl_anlz::Anlz, Vec<Beat>)> {
    let parsed = rbl_anlz::Anlz::read(dat).map_err(|e| {
        AppError::new(ErrorKind::NotFound, "That track's analysis file could not be read.")
            .with_detail(format!("{}: {e}", dat.display()))
    })?;
    let Some(beats) = parsed.beat_grid().filter(|beats| !beats.is_empty()) else {
        return Err(AppError::new(ErrorKind::NotFound, "That track has no beat grid to edit."));
    };
    let offset = i64::from(parsed.grid_offset().unwrap_or(0));
    let beats = beats
        .into_iter()
        .filter_map(|beat| u32::try_from(i64::from(beat.time_ms) + offset).ok().map(|time_ms| Beat { time_ms, ..beat }))
        .collect();
    Ok((parsed, beats))
}

/// Sets the track's tempo. Blocking.
pub fn set_tempo(state: &AppState, track: &str, value: &str) -> AppResult<()> {
    let _edit_guard = state.edit_gate.lock();
    set_tempo_inner(state, track, value)
}

fn set_tempo_inner(state: &AppState, track: &str, value: &str) -> AppResult<()> {
    let bpm_x100 = parse_bpm(value)?;
    let _files = state.analysis_write.lock();
    let location = state.location()?;
    if let Some(reason) =
        rbl_db::write_refusal_reason(location.is_real_install, rbl_db::test_mode(), rbl_db::is_rekordbox_running())
    {
        return Err(AppError::new(ErrorKind::ReadOnly, reason));
    }
    if database_locked(&location, track)? {
        return Err(AppError::new(ErrorKind::ReadOnly, "The beat grid is locked."));
    }
    crate::file_journal::recover(state.backup_dir(), &location)?;
    let library = state.library()?;
    let row = library
        .row_of(track)
        .ok_or_else(|| AppError::new(ErrorKind::NotFound, "That track is no longer in the library."))?;
    let relative = library.analysis_path.get(row as usize);
    if relative.is_empty() {
        return state.write(|w| w.save_grid_revision(track, u32::from(bpm_x100))).map_err(write_error);
    }
    let dat = rbl_anlz::resolve(&location.share_root, relative);
    let (parsed, beats) = read_dat(&dat)?;
    if rbl_anlz::grid::is_dynamic_from(&beats, None) {
        return Err(AppError::new(ErrorKind::Malformed, "Use the grid BPM field to confirm replacing tempo changes."));
    }
    let next = apply_with_duration(
        &beats,
        None,
        Edit::Tempo { bpm_x100, anchor_ms: 0 },
        library.length_sec[row as usize].saturating_mul(1000),
    );
    let mut files = vec![(dat.clone(), parsed.with_beat_grid(&next))];
    let ext = rbl_anlz::sibling(&dat, "EXT");
    if ext.exists() {
        let parsed = rbl_anlz::Anlz::read(&ext).map_err(|e| AppError::internal(e.to_string()))?;
        if let Some(bytes) = parsed.with_extended_grid_cleared() {
            files.push((ext, bytes));
        }
    }
    let journal = crate::file_journal::FileJournal::prepare(
        state.backup_dir(),
        &location,
        track,
        u32::from(bpm_x100),
        None,
        true,
        &files,
    )?;
    if let Err(e) = journal.publish() {
        journal.rollback()?;
        return Err(e);
    }
    if let Err(e) = state.write(|w| w.save_grid_revision(track, u32::from(bpm_x100))) {
        journal.reconcile(&location)?;
        return Err(write_error(e));
    }
    journal.commit()
}
