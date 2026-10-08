//! Translating the bridge's view spec into the index's, and rows out of it.

use rbl_index::{Library, Row as IndexRow, SortColumn, TrackSource as Source, ViewSpec as IndexSpec};

use crate::error::FfiError;
use crate::types::{HotCue, Row, TrackSource, ViewSpec};

/// Translates a wire sort name. Unknown names fall back to track order.
pub(crate) fn sort_from_wire(name: &str) -> SortColumn {
    match name {
        "title" => SortColumn::Title,
        "artist" => SortColumn::Artist,
        "album" => SortColumn::Album,
        "genre" => SortColumn::Genre,
        "label" => SortColumn::Label,
        "comment" => SortColumn::Comment,
        "key" => SortColumn::Key,
        "keyCamelot" => SortColumn::KeyCamelot,
        "bpm" => SortColumn::Bpm,
        "duration" => SortColumn::Duration,
        "rating" => SortColumn::Rating,
        "djPlayCount" => SortColumn::PlayCount,
        "dateAdded" => SortColumn::DateAdded,
        "releaseDate" => SortColumn::ReleaseDate,
        "size" => SortColumn::Size,
        "year" => SortColumn::Year,
        "sampleRate" => SortColumn::SampleRate,
        "bitrate" => SortColumn::Bitrate,
        "color" => SortColumn::Color,
        "fileName" => SortColumn::FileName,
        "location" => SortColumn::Location,
        "composer" => SortColumn::Composer,
        "albumArtist" => SortColumn::AlbumArtist,
        "remixer" => SortColumn::Remixer,
        "originalArtist" => SortColumn::OriginalArtist,
        "mixName" => SortColumn::MixName,
        "discNo" => SortColumn::DiscNo,
        "trackNumber" => SortColumn::TrackNumber,
        "fileType" => SortColumn::FileType,
        "bitDepth" => SortColumn::BitDepth,
        "lyricist" => SortColumn::Lyricist,
        "dateCreated" => SortColumn::DateCreated,
        "publishTrackInfo" => SortColumn::PublishTrackInfo,
        "message" => SortColumn::Message,
        _ => SortColumn::TrackNo,
    }
}

fn numeric_id(id: &str) -> Result<u64, FfiError> {
    id.parse::<u64>().map_err(|_| FfiError::malformed(format!("`{id}` is not a list id")))
}

pub(crate) fn spec_from_wire(library: &Library, spec: &ViewSpec) -> Result<IndexSpec, FfiError> {
    let source = match &spec.source {
        TrackSource::Collection => Source::Collection,
        TrackSource::History { id } => {
            let numeric = numeric_id(id)?;
            let index = library
                .histories()
                .index_of(numeric)
                .ok_or_else(|| FfiError::not_found(format!("no history {id}")))?;
            Source::History(index)
        }
        TrackSource::Playlist { id } => {
            let numeric = numeric_id(id)?;
            let playlists = library.playlists();
            let index = playlists
                .index_of(numeric)
                .ok_or_else(|| FfiError::not_found(format!("no playlist {id}")))?;
            if playlists.is_smart(index) {
                Source::SmartPlaylist(index)
            } else {
                Source::Playlist(index)
            }
        }
        TrackSource::PlaylistFolder { id } => {
            let numeric = numeric_id(id)?;
            let playlists = library.playlists();
            let index = playlists
                .index_of(numeric)
                .filter(|&index| playlists.is_folder(index))
                .ok_or_else(|| FfiError::not_found(format!("no playlist folder {id}")))?;
            Source::PlaylistFolder(index)
        }
        TrackSource::Folder { .. } | TrackSource::TagList => {
            return Err(FfiError::malformed("that source is not supported by this bridge yet"));
        }
    };
    Ok(IndexSpec {
        source,
        sort: sort_from_wire(&spec.sort),
        descending: spec.descending,
        query: spec.query.clone(),
        filter: rbl_index::TrackFilter::default(),
    })
}

/// `#RRGGBB` for a cue's colour index; none for the unset sentinel at 0.
fn cue_colour_css(index: u8) -> Option<String> {
    if index == 0 {
        return None;
    }
    rbl_anlz::cue_colour_drawn(index).map(|[r, g, b]| format!("#{r:02X}{g:02X}{b:02X}"))
}

/// Hot cues in slot order, A to P.
fn hot_cues_in_slot_order(library: &Library, row: IndexRow) -> Vec<HotCue> {
    let mut hot: Vec<(u8, HotCue)> = library
        .cues_of(row)
        .iter()
        .filter_map(|cue| {
            let letter = cue.hot_letter()?;
            Some((
                cue.kind,
                HotCue {
                    slot: letter.to_string(),
                    position_ms: cue.position_ms,
                    color: cue_colour_css(cue.colour),
                },
            ))
        })
        .collect();
    hot.sort_by_key(|(kind, _)| *kind);
    hot.into_iter().map(|(_, cue)| cue).collect()
}

pub(crate) fn rows_to_records(
    library: &Library,
    rows: &[IndexRow],
    track_no: impl Fn(usize) -> u32,
    first_position: usize,
) -> Vec<Row> {
    rows.iter()
        .enumerate()
        .map(|(offset, &row)| {
            let index = row as usize;
            let id = library.ids.get(index).copied().unwrap_or(0);
            Row {
                id: id.to_string(),
                track_no: track_no(first_position.saturating_add(offset)),
                title: library.title.get(index).to_owned(),
                artist: library.artist_name(row).to_owned(),
                album: library.album_name(row).to_owned(),
                genre: library.genre_name(row).to_owned(),
                label: library.label_name(row).to_owned(),
                comment: library.comment.get(index).to_owned(),
                bpm_x100: library.bpm_x100.get(index).copied().unwrap_or(0),
                key: library.key_name(row).to_owned(),
                duration_sec: library.length_sec.get(index).copied().unwrap_or(0),
                rating: library.rating.get(index).copied().unwrap_or(0),
                analysed: library.analysed.get(index).copied().unwrap_or(0),
                date_added: library.date_added.get(index).to_owned(),
                release_date: library.release_date.get(index).to_owned(),
                hot_cues: hot_cues_in_slot_order(library, row),
                memory_cues: library
                    .cues_of(row)
                    .iter()
                    .filter(|cue| cue.is_memory())
                    .map(|cue| cue.position_ms)
                    .collect(),
                artwork_hue: u16::try_from(id % 360).unwrap_or(0),
                has_artwork: !library.artwork_path.get(index).is_empty(),
                file_name: library.file_name.get(index).to_owned(),
            }
        })
        .collect()
}
