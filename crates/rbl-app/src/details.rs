//! The information panel's reads: one track's full record and the lists its
//! dropdowns offer. Writes stay in the shell until the editing phase.
//!
//! The record is a point read from `djmdContent` by id, not a widening of the
//! columnar index — see `rbl_db::details`.

use crate::dto::{MyTagCategoryDto, MyTagDto, TrackDetailsDto, TrackLookupsDto};
use crate::edits::write_error;
use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::AppState;

/// Names past this many are dropped, so a library with an absurd genre list
/// cannot push one response over the cap.
const MAX_NAMES: usize = 2000;

/// One track in full. Blocking: reads the database.
pub fn track_details(state: &AppState, track: &str) -> AppResult<TrackDetailsDto> {
    let library = state.library()?;
    let has_artwork = library.artwork_path_of(track).is_some_and(|p| !p.is_empty());
    let details = state
        .read_db(|db| rbl_db::details::track_details(db.connection(), track))
        .map_err(write_error)?;
    let Some(d) = details else {
        return Err(AppError::new(ErrorKind::NotFound, "That track is no longer in the library.")
            .with_detail(format!("track {track}")));
    };
    Ok(TrackDetailsDto {
        id: d.id,
        title: d.title,
        artist: d.artist,
        album: d.album,
        album_artist: d.album_artist,
        original_artist: d.original_artist,
        composer: d.composer,
        remixer: d.remixer,
        lyricist: d.lyricist,
        genre: d.genre,
        label: d.label,
        key: d.key,
        comment: d.comment,
        mix_name: d.mix_name,
        message: d.message,
        color: d.color,
        rating: d.rating,
        bpm_x100: d.bpm_x100,
        duration_sec: d.duration_sec,
        year: d.year,
        track_number: d.track_number,
        disc_number: d.disc_number,
        play_count: d.play_count,
        file_type: d.file_type,
        file_size: d.file_size,
        bitrate: d.bitrate,
        sample_rate: d.sample_rate,
        bit_depth: d.bit_depth,
        date_created: d.date_created,
        release_date: d.release_date,
        path: d.path,
        hot_cue_auto_load: d.hot_cue_auto_load,
        publish: d.publish,
        has_artwork,
        my_tags: d.my_tags,
    })
}

/// What the Info tab's dropdowns offer. Blocking: reads the database.
pub fn track_lookups(state: &AppState) -> AppResult<TrackLookupsDto> {
    let library = state.library()?;
    // Categories first in their order, then each one's tags in theirs.
    let rows = state
        .read_db(|db| rbl_db::export_info::my_tags(db.connection()))
        .map_err(write_error)?;
    let mut my_tag_categories: Vec<(String, MyTagCategoryDto)> = rows
        .iter()
        .filter(|t| t.attribute == 1)
        .map(|t| (t.id.clone(), MyTagCategoryDto { name: t.name.clone(), tags: Vec::new() }))
        .collect();
    for tag in rows.iter().filter(|t| t.attribute == 0) {
        if let Some((_, category)) = my_tag_categories.iter_mut().find(|(id, _)| *id == tag.parent) {
            category.tags.push(MyTagDto { id: tag.id.clone(), name: tag.name.clone() });
        }
    }
    let my_tag_categories = my_tag_categories.into_iter().map(|(_, c)| c).collect();
    let names = |interner: &rbl_index::strings::Interner| -> Vec<String> {
        let mut out: Vec<String> = (0..interner.len())
            .filter_map(|i| u32::try_from(i).ok())
            .map(|i| interner.name(i))
            .filter(|n| !n.is_empty())
            .take(MAX_NAMES)
            .map(str::to_owned)
            .collect();
        out.sort_unstable_by_key(|n| n.to_lowercase());
        out
    };
    Ok(TrackLookupsDto { keys: names(&library.keys), genres: names(&library.genres), my_tag_categories })
}
