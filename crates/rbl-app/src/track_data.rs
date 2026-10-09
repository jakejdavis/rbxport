//! Per-track analysis reads the player draws from: the beat grid, cues,
//! phrases and vocal strip. Plain blocking functions, shared by the webview
//! shell and the native front end.

use std::path::Path;

use crate::dto::{cue_colour_css, CueDto, PhraseDto};
use crate::error::{AppError, AppResult};
use crate::media::window_of;
use crate::state::AppState;

/// More beats than a real track has; bounds the response.
pub const MAX_BEATS: usize = 65_536;
/// More phrases than a real track has (under fifty).
pub const MAX_PHRASES: usize = 512;

/// Rekordbox's memory-cue colours, indexed by the stored 0-7.
const MEMORY_CSS: [&str; 8] =
    ["#E778F1", "#E33122", "#EBA44A", "#F4E458", "#66DD42", "#56BDF3", "#204FEF", "#8B1EEF"];

/// One beat of the grid: milliseconds, the beat's number in its bar (1 is the
/// downbeat) and the tempo there x100.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BeatDto {
    pub time_ms: u32,
    pub number: u8,
    pub tempo_x100: u16,
}

/// The beats of a parsed analysis file with the `PQTZ` grid offset applied.
///
/// Rekordbox's `MstSaveQtzOffset` shifts the whole grid by rewriting one
/// field, not the records. The editor already reads the grid this way; the
/// drawn grid and the metronome must too, or they disagree by the offset
/// until the first edit rewrites the file. A beat shifted before zero is
/// dropped.
#[must_use]
pub fn beats_of(file: &rbl_anlz::Anlz) -> Vec<BeatDto> {
    let offset = i64::from(file.grid_offset().unwrap_or(0));
    file.beat_grid()
        .unwrap_or_default()
        .into_iter()
        .take(MAX_BEATS)
        .filter_map(|beat| {
            let time_ms = u32::try_from(i64::from(beat.time_ms) + offset).ok()?;
            Some(BeatDto { time_ms, number: u8::try_from(beat.beat_number).unwrap_or(0), tempo_x100: beat.tempo_x100 })
        })
        .collect()
}

/// A track's beat grid from its `.DAT`. Empty for a track without one.
#[must_use]
pub fn read_beat_grid(share: &Path, relative: &str) -> Vec<BeatDto> {
    let path = share.join(relative.trim_start_matches(['/', '\\']));
    let Ok(bytes) = std::fs::read(&path) else { return Vec::new() };
    let Ok(file) = rbl_anlz::parse(&bytes) else { return Vec::new() };
    beats_of(&file)
}

/// Bytes one beat takes on the wire.
pub const BEAT_BYTES: usize = 7;

/// The wire form: a `u32` LE of milliseconds, the number, a `u16` LE of tempo x100.
#[must_use]
pub fn encode_beats(beats: &[BeatDto]) -> Vec<u8> {
    let mut out = Vec::with_capacity(beats.len() * BEAT_BYTES);
    for beat in beats {
        out.extend_from_slice(&beat.time_ms.to_le_bytes());
        out.push(beat.number);
        out.extend_from_slice(&beat.tempo_x100.to_le_bytes());
    }
    out
}

fn analysis_of(state: &AppState, track_id: &str) -> AppResult<Option<(std::path::PathBuf, String)>> {
    let library = state.library()?;
    let share = state.share_root();
    let Some(row) = library.row_of(track_id) else { return Ok(None) };
    let relative = library.analysis_path.get(row as usize);
    if relative.is_empty() {
        return Ok(None);
    }
    Ok(Some((share, relative.to_owned())))
}

/// A track's beat grid, offset applied. Empty without an analysis. Blocking.
pub fn track_beats(state: &AppState, track_id: &str) -> AppResult<Vec<BeatDto>> {
    Ok(analysis_of(state, track_id)?.map(|(share, relative)| read_beat_grid(&share, &relative)).unwrap_or_default())
}

/// A track's cue points. A hot cue's colour is what rekordbox paints for its
/// `ColorTableIndex`; a memory cue's is its named colour. Blocking.
pub fn track_cues(state: &AppState, track_id: &str) -> AppResult<Vec<CueDto>> {
    let library = state.library()?;
    let Some(row) = library.row_of(track_id) else { return Ok(Vec::new()) };
    // Rekordbox may have added cues since the snapshot: refresh this track.
    let (comments, memory_colours) = state
        .read_db(|db| {
            rbl_index::reload_cues_of(db, &library, track_id)?;
            Ok((
                rbl_db::details::cue_comments(db.connection(), track_id)?,
                rbl_db::details::memory_cue_colours(db.connection(), track_id)?,
            ))
        })
        .map_err(|e| AppError::internal(e.to_string()))?;
    Ok(library
        .cues_of(row)
        .iter()
        .map(|cue| CueDto {
            comment: comments.get(&cue.id.to_string()).cloned().unwrap_or_default(),
            id: if cue.id == 0 { String::new() } else { cue.id.to_string() },
            position_ms: cue.position_ms,
            out_ms: cue.out_ms,
            letter: cue.hot_letter().map(String::from).unwrap_or_default(),
            memory: cue.is_memory(),
            colour: if cue.is_memory() {
                memory_colours
                    .get(&cue.id.to_string())
                    .and_then(|value| MEMORY_CSS.get(usize::from(*value)))
                    .map(|value| (*value).to_owned())
            } else {
                cue_colour_css(cue.colour)
            },
        })
        .collect())
}

/// A track's phrases, each resolved against the (offset) grid. Blocking.
pub fn track_phrases(state: &AppState, track_id: &str) -> AppResult<Vec<PhraseDto>> {
    let Some((share, relative)) = analysis_of(state, track_id)? else { return Ok(Vec::new()) };
    let dat = rbl_anlz::resolve(&share, &relative);
    let Ok(ext) = rbl_anlz::Anlz::read(&rbl_anlz::sibling(&dat, "EXT")) else { return Ok(Vec::new()) };
    let Some(phrases) = ext.phrases() else { return Ok(Vec::new()) };
    let grid = rbl_anlz::Anlz::read(&dat).ok().map(|d| beats_of(&d));
    Ok(phrases
        .into_iter()
        .take(MAX_PHRASES)
        .map(|phrase| PhraseDto {
            beat: u32::from(phrase.beat),
            label: phrase.label.to_owned(),
            kind: phrase.kind,
            // Beat numbers in `PSSI` are 1-based; the grid is a list.
            time_ms: grid
                .as_ref()
                .and_then(|g| g.get(usize::from(phrase.beat).checked_sub(1)?).map(|b| b.time_ms)),
        })
        .collect())
}

/// Where rekordbox heard a voice, one intensity byte per 46.44 ms (`PVDI`).
pub fn track_vocals(state: &AppState, track_id: &str, from: Option<u32>, len: Option<u32>) -> AppResult<Vec<u8>> {
    let Some((share, relative)) = analysis_of(state, track_id)? else { return Ok(Vec::new()) };
    let dat = rbl_anlz::resolve(&share, &relative);
    let Ok(two) = rbl_anlz::Anlz::read(&rbl_anlz::sibling(&dat, "2EX")) else { return Ok(Vec::new()) };
    Ok(window_of(two.vocals().unwrap_or_default(), 1, from, len))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]
    use super::*;
    use rbl_anlz::Beat;

    fn file(beats: &[Beat], offset: i16) -> rbl_anlz::Anlz {
        let base = rbl_anlz::Anlz::default().with_beat_grid(beats);
        let parsed = rbl_anlz::parse(&base).unwrap();
        rbl_anlz::parse(&parsed.with_grid_offset(offset).unwrap()).unwrap()
    }

    fn grid() -> Vec<Beat> {
        (0..8u16)
            .map(|i| Beat { beat_number: i % 4 + 1, tempo_x100: 12_800, time_ms: 100 + u32::from(i) * 469 })
            .collect()
    }

    #[test]
    fn the_grid_offset_is_applied() {
        let plain = beats_of(&file(&grid(), 0));
        let shifted = beats_of(&file(&grid(), 25));
        assert_eq!(plain.len(), 8);
        assert_eq!(plain[0].time_ms, 100);
        assert_eq!(shifted[0].time_ms, 125);
        assert_eq!(shifted[5].time_ms, plain[5].time_ms + 25);
        assert_eq!(plain[4].number, 1);
    }

    #[test]
    fn a_beat_pushed_before_zero_is_dropped() {
        let early = beats_of(&file(&grid(), -150));
        assert_eq!(early.len(), 7);
        assert_eq!(early[0].time_ms, 419);
    }

    #[test]
    fn beats_encode_seven_bytes_each() {
        let bytes = encode_beats(&[BeatDto { time_ms: 0x0102_0304, number: 3, tempo_x100: 0x1234 }]);
        assert_eq!(bytes, vec![4, 3, 2, 1, 3, 0x34, 0x12]);
    }
}
