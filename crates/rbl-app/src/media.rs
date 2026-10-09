//! Bulk media reads as plain functions: waveform tags out of the ANLZ files
//! and artwork out of the share tree.
//!
//! Artwork takes a **track id**, never a path: the path is looked up in the
//! index and checked to still sit under the share root, because `ImagePath`
//! comes from the database rather than from us.

use std::path::{Path, PathBuf};

use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::AppState;

/// Refuses artwork larger than this. Real artwork is tens of kilobytes; a file
/// this big is not album art and should not be read into memory to find out.
pub const MAX_ARTWORK_BYTES: u64 = 8 * 1024 * 1024;

/// Why artwork could not be served, so the webview protocol can keep its codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtworkError {
    /// No library, no artwork recorded, or the file is gone.
    NotFound,
    /// The recorded path climbs out of the share root.
    Refused,
    /// Bigger than [`MAX_ARTWORK_BYTES`].
    TooLarge,
}

/// The artwork file of a track, or why there is none.
pub fn artwork_file(state: &AppState, track_id: &str) -> Result<Vec<u8>, ArtworkError> {
    let library = state.library().map_err(|_| ArtworkError::NotFound)?;
    let relative = library.artwork_path_of(track_id).filter(|r| !r.is_empty()).ok_or(ArtworkError::NotFound)?;
    let share = state.share_root();
    let Some(path) = resolve_under(&share, relative) else {
        tracing::warn!(%relative, "artwork path escapes the share root; refused");
        return Err(ArtworkError::Refused);
    };
    match std::fs::metadata(&path) {
        Ok(meta) if meta.len() > MAX_ARTWORK_BYTES => return Err(ArtworkError::TooLarge),
        Ok(_) => {}
        Err(_) => return Err(ArtworkError::NotFound),
    }
    std::fs::read(&path).map_err(|_| ArtworkError::NotFound)
}

/// The artwork bytes of a track, or `None` when it has none or the path is refused.
pub fn artwork_bytes(state: &AppState, track_id: &str) -> Option<Vec<u8>> {
    artwork_file(state, track_id).ok()
}

/// Waveform bytes for a track by wire kind (`bands`, `colour`, `mono`, …).
/// Empty when the track has no analysis. Blocking.
pub fn track_waveform(state: &AppState, track_id: &str, kind: &str, from: Option<u32>, len: Option<u32>) -> AppResult<Vec<u8>> {
    let library = state.library()?;
    let share = state.share_root();
    waveform_bytes(&library, &share, track_id, kind, from, len)
}

/// Joins a share-relative path onto the root, refusing anything that climbs out.
///
/// `ImagePath` comes from the database, so it is not ours to trust: a value
/// with `..` in it would otherwise read outside the library.
pub fn resolve_under(root: &Path, relative: &str) -> Option<PathBuf> {
    let mut out = root.to_path_buf();
    for part in relative.split(['/', '\\']) {
        match part {
            "" | "." => {}
            ".." => return None,
            _ => out.push(part),
        }
    }
    // Resolving symlinks too: a link inside the share tree could still point
    // out of it.
    let canonical = out.canonicalize().ok()?;
    let root = root.canonicalize().ok()?;
    canonical.starts_with(&root).then_some(canonical)
}

pub fn waveform_bytes(
    library: &rbl_index::Library,
    share: &Path,
    track_id: &str,
    kind: &str,
    from: Option<u32>,
    len: Option<u32>,
) -> AppResult<Vec<u8>> {
    let Ok(numeric) = track_id.parse::<u64>() else {
        return Err(AppError::new(ErrorKind::Malformed, "That track id is not valid.")
            .with_detail(format!("track_id {track_id:?}")));
    };
    // Through the id map, not a scan. `ids` is 38,681 long and a screenful
    // of rows asks once each, which is the reason `artwork_path_of` was
    // given the map in the first place; this call was still walking the
    // whole column for every row a scroll went past.
    let Some(row) = library.row_of_id(numeric).map(|row| row as usize) else {
        return Ok(Vec::new());
    };
    let analysis_path = library.analysis_path.get(row);
    if analysis_path.is_empty() {
        return Ok(Vec::new());
    }

        // The stored path names the .DAT; the colour waveforms live in the
        // .EXT sibling and the three-band ones in .2EX.
    let dat = rbl_anlz::resolve(share, analysis_path);
        // rekordbox 7 draws the three-band waveforms, and every one of the
        // first 300 tracks checked in the reference library has them. `PWV6`
        // is the 1,200-column overview and `PWV7` the full-resolution detail,
        // both three bytes per column: low, mid, high.
    let (file, tag, stride): (PathBuf, [u8; 4], usize) = match kind {
            "bands" => (rbl_anlz::sibling(&dat, "2EX"), *b"PWV6", 3),
            "bandsDetail" => (rbl_anlz::sibling(&dat, "2EX"), *b"PWV7", 3),
            // The RGB palette's pair, six and two bytes a column.
            "colourDetail" | "detail" => (rbl_anlz::sibling(&dat, "EXT"), *b"PWV5", 2),
            "colour" | "color" => (rbl_anlz::sibling(&dat, "EXT"), *b"PWV4", 6),
            // The BLUE palette's pair, one byte a column.
            "monoDetail" => (rbl_anlz::sibling(&dat, "EXT"), *b"PWV3", 1),
            _ => (dat, *b"PWAV", 1),
    };

    let Ok(anlz) = rbl_anlz::Anlz::read(&file) else {
        // Analysis missing on disk: draw nothing rather than fail the view.
        return Ok(Vec::new());
    };
    let whole = anlz.waveform(&tag).map(|(_, data)| data).unwrap_or_default();
    Ok(window_of(whole, stride, from, len))
}

/// The requested span of a waveform tag, clamped to what is there.
///
/// Entries rather than bytes, so a caller never has to know a tag's stride,
/// and so a window can never land mid-entry and shear the bands apart.
pub fn window_of(data: &[u8], stride: usize, from: Option<u32>, len: Option<u32>) -> Vec<u8> {
    let stride = stride.max(1);
    let entries = data.len() / stride;
    let first = from.map_or(0, |f| f as usize).min(entries);
    let count = len.map_or(entries - first, |l| (l as usize).min(entries - first));
    data.get(first * stride..(first + count) * stride).unwrap_or(&[]).to_vec()
}

