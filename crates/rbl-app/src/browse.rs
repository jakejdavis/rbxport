//! Browse commands as plain functions of the app state: the summary, the
//! playlist tree, opening a view, and paging its rows.

use rbl_index::Library;

use crate::dto::{CountedDto, DeviceDto, DeviceExportDto, FilterValuesDto, TagCategoryDto, LibrarySummaryDto, RowDto, TrackSourceDto, TreeNodeDto, ViewHandleDto, ViewSpecDto};
use crate::edits::write_error;
use crate::error::{AppError, AppResult, ErrorKind};
use crate::state::{rows_to_dto, spec_from_wire, AppState};

/// Rows per request. The frontend asks a page at a time; this bound is what
/// keeps a response inside the 64 KB cap.
pub const MAX_ROWS: u32 = 128;

pub fn library_summary(state: &AppState) -> AppResult<LibrarySummaryDto> {
    let library = state.library()?;
    let (read_only, db_version, load_ms, _generation) = state.summary();
    let is_real_install = state.location()?.is_real_install;
    // The UI refreshes this while open; startup's process state is stale
    // as soon as rekordbox launches or exits. Fixtures keep their own gate.
    let read_only = if is_real_install {
        rbl_db::is_rekordbox_running() && !rbl_db::unsafe_writes_enabled()
    } else {
        read_only
    };
    let playlist_count = u32::try_from(library.playlists().len()).unwrap_or(u32::MAX);
    Ok(LibrarySummaryDto {
        track_count: u32::try_from(library.len()).unwrap_or(u32::MAX),
        playlist_count,
        read_only,
        db_version,
        load_ms,
    })
}

pub fn playlist_tree(state: &AppState) -> AppResult<Vec<TreeNodeDto>> {
    let library = state.library()?;
    Ok(build_tree(&library))
}

/// Opens a view: over the index, or, for a `Folder` source, over a directory
/// read from disk and matched against the library.
pub fn open_view(state: &AppState, spec: &ViewSpecDto) -> AppResult<ViewHandleDto> {
    if let TrackSourceDto::Folder { path } = &spec.source {
        return crate::explorer::open_folder(state, path, spec);
    }
    let library = state.library()?;
    let parsed = spec_from_wire(&library, spec);
    let (view_id, len, generation) = state.open_view_scoped(&parsed, spec.search_field)?;
    Ok(ViewHandleDto { view_id, len, gen: generation })
}

/// The BPMs and keys the track filter bar can offer for a list.
///
/// Counted over the source and query alone, never over the filter's own
/// result, or a picked value would hide the others.
pub fn filter_values(state: &AppState, spec: &ViewSpecDto) -> AppResult<FilterValuesDto> {
    let library = state.library()?;
    let parsed = spec_from_wire(&library, spec);
    let values = library.filter_values_scoped(&parsed, spec.search_field);
    Ok(FilterValuesDto {
        bpms: values.bpms.into_iter().map(|c| CountedDto { value: c.value, count: c.count }).collect(),
        keys: values.keys.into_iter().map(|c| CountedDto { value: c.value, count: c.count }).collect(),
        tags: values.tags.into_iter().map(|c| TagCategoryDto { name: c.name, tags: c.tags }).collect(),
    })
}

/// Lists the volumes an export could be written to, and what is on each.
/// Reading a stick to see what it holds is not cheap, so call this when the
/// list is shown, not on a timer.
pub fn list_devices() -> Vec<DeviceDto> {
    rbl_devices::list()
        .into_iter()
        .map(|device| {
            let found = rbl_devices::inspect(&device.mount_point);
            DeviceDto {
                name: device.name,
                path: device.mount_point.to_string_lossy().into_owned(),
                total_bytes: device.total_bytes,
                free_bytes: device.free_bytes,
                file_system: device.file_system,
                removable: device.removable,
                volume_id: device.volume_id,
                export: found.map(|export| DeviceExportDto {
                    tracks: u32::try_from(export.tracks).unwrap_or(u32::MAX),
                    playlists: u32::try_from(export.playlists).unwrap_or(u32::MAX),
                    ours: export.ours,
                    written: export.written,
                }),
            }
        })
        .collect()
}

/// Where a track's audio file is, for revealing it in the Finder.
pub fn track_path(state: &AppState, track: &str) -> AppResult<String> {
    let library = state.library()?;
    library
        .audio_path_of(track)
        .map(str::to_owned)
        .ok_or_else(|| AppError::new(ErrorKind::NotFound, "That track has no file."))
}

/// Writes a playlist to `path` as `m3u8` or (anything else is m3u8) the
/// tab-separated `txt`. An intelligent playlist is what its rule admits now.
/// Returns how many tracks were written.
pub fn export_playlist_file(state: &AppState, playlist: &str, path: &str, format: &str) -> AppResult<u32> {
    let library = state.library()?;
    let playlists = library.playlists();
    let Some(index) = playlist.parse::<u64>().ok().and_then(|numeric| playlists.index_of(numeric)) else {
        return Err(AppError::new(ErrorKind::NotFound, "That playlist is not in the library."));
    };
    let source = if playlists.is_smart(index) {
        rbl_index::TrackSource::SmartPlaylist(index)
    } else {
        rbl_index::TrackSource::Playlist(index)
    };
    let rows = library.source_rows_unlocked(&playlists, &source);
    drop(playlists);
    let text = match format {
        "txt" => playlist_txt(&library, &rows),
        _ => playlist_m3u8(&library, &rows),
    };
    std::fs::write(path, text).map_err(|e| {
        AppError::new(ErrorKind::Internal, "The playlist file could not be written.").with_detail(e.to_string())
    })?;
    Ok(u32::try_from(rows.len()).unwrap_or(u32::MAX))
}

/// One page of an index view's rows. Folder views are the shell's.
pub fn fetch_rows(
    state: &AppState,
    view_id: u32,
    offset: u32,
    len: u32,
    extra_columns: &[String],
) -> AppResult<Vec<RowDto>> {
    check_page(len)?;
    let library = state.library()?;
    if let Some(folder) = state.folder_view(view_id) {
        let mut rows = crate::explorer::fetch_rows(&library, &folder, offset, len);
        if !extra_columns.is_empty() { enrich_rows(state, &mut rows, extra_columns)?; }
        return Ok(rows);
    }
    let view = state.view(view_id)?;
    let offset = offset as usize;
    let window = view.window(offset, len as usize);
    let mut rows = rows_to_dto(&library, window, offset);
    for (position, row) in rows.iter_mut().enumerate() {
        row.track_no = view.track_no_at(offset.saturating_add(position));
    }
    if !extra_columns.is_empty() { enrich_rows(state, &mut rows, extra_columns)?; }
    Ok(rows)
}

/// Refuses a page larger than [`MAX_ROWS`].
pub fn check_page(len: u32) -> AppResult<()> {
    if len > MAX_ROWS {
        return Err(
            AppError::new(ErrorKind::Malformed, "Too many rows requested at once.")
                .with_detail(format!("len {len} exceeds the {MAX_ROWS}-row cap")),
        );
    }
    Ok(())
}

pub fn view_ids_in_range(state: &AppState, view_id: u32, from: u32, to: u32) -> AppResult<Vec<String>> {
    let library = state.library()?;
    if let Some(folder) = state.folder_view(view_id) {
        return Ok(crate::explorer::ids_in_range(&library, &folder, from, to));
    }
    let view = state.view(view_id)?;
    Ok(library
        .ids_in_range(&view, from as usize, to as usize)
        .into_iter()
        .map(|id| id.to_string())
        .collect())
}

fn build_tree(library: &Library) -> Vec<TreeNodeDto> {
    let playlists = library.playlists();
    let histories = library.histories();
    let mut nodes = vec![
        TreeNodeDto {
            id: "all".into(),
            name: "All Tracks".into(),
            kind: "allTracks",
            depth: 0,
            expanded: None,
            child_count: Some(u32::try_from(library.len()).unwrap_or(u32::MAX)),
        },
        TreeNodeDto {
            id: "playlists".into(),
            name: "Playlists".into(),
            kind: "collection",
            depth: 0,
            expanded: Some(true),
            child_count: Some(u32::try_from(playlists.len()).unwrap_or(u32::MAX)),
        },
    ];

    push_lists(&mut nodes, &playlists, ListStyle::PLAYLISTS, 2);

    // Histories only when there are some: an empty section is a heading that
    // leads nowhere, and the rail already dims what has nothing in it.
    if !histories.is_empty() {
        nodes.push(TreeNodeDto {
            id: "histories".into(),
            name: "Histories".into(),
            kind: "histories",
            depth: 0,
            // Open, with the years under it open and the months closed: the
            // rail shows one section at a time, so the sessions — 187 of them
            // in the reference library — open over nothing else.
            expanded: Some(true),
            child_count: Some(u32::try_from(histories.len()).unwrap_or(u32::MAX)),
        });
        // A year folder and a session are both "history": they are one
        // section, and what tells them apart in the tree is whether anything
        // sits under them.
        push_lists(&mut nodes, &histories, ListStyle::HISTORIES, 2);
    }
    nodes
}

/// What to call a list with children, and one without, and how to order them.
#[derive(Debug, Clone, Copy)]
struct ListStyle {
    folder: &'static str,
    leaf: &'static str,
    /// An intelligent playlist: a rule rather than a membership. Histories
    /// have none, so theirs is the leaf.
    smart: &'static str,
    /// Filed by date rather than by hand: folders are a year and a month,
    /// which rekordbox shows in calendar order under their month's name, not
    /// in the order they were made. Sessions keep their `Seq`, which is the
    /// order they were played in.
    calendar: bool,
}

impl ListStyle {
    const PLAYLISTS: Self =
        Self { folder: "folder", leaf: "playlist", smart: "smartPlaylist", calendar: false };
    const HISTORIES: Self =
        Self { folder: "history", leaf: "history", smart: "history", calendar: true };
}

/// A month folder's name as rekordbox shows it: `djmdHistory` stores the
/// month as its number.
fn month_name(number: &str) -> Option<&'static str> {
    const MONTHS: [&str; 12] = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ];
    let month = number.parse::<usize>().ok()?;
    MONTHS.get(month.checked_sub(1)?).copied()
}

/// Flattens one list tree onto `nodes`, depth-first, in `Seq` order — or, for
/// a calendar, with the year and month folders in date order.
///
/// `open_to` is the depth below which branches arrive expanded: the tree opens
/// on the playlists and on the years, and closed on the months.
fn push_lists(
    nodes: &mut Vec<TreeNodeDto>,
    lists: &rbl_index::Playlists,
    style: ListStyle,
    open_to: u32,
) {
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); lists.len()];
    let mut roots: Vec<usize> = Vec::new();
    for index in 0..lists.len() {
        match lists.parent.get(index).copied() {
            Some(parent) if parent != rbl_index::NO_ID && (parent as usize) < lists.len() => {
                if let Some(bucket) = children.get_mut(parent as usize) {
                    bucket.push(index);
                }
            }
            _ => roots.push(index),
        }
    }
    if style.calendar {
        // A year is "2026" and a month "9": the number is the date. A folder
        // named anything else sorts after the dated ones, in `Seq` order.
        let by_date = |index: &usize| -> (u64, u32) {
            if lists.is_folder(*index) {
                (lists.name(*index).parse::<u64>().unwrap_or(u64::MAX), 0)
            } else {
                (u64::MAX, lists.seq.get(*index).copied().unwrap_or(u32::MAX))
            }
        };
        roots.sort_by_key(by_date);
        for bucket in &mut children {
            bucket.sort_by_key(by_date);
        }
    }

    // Iterative, with a visited set: a corrupt parent cycle must not recurse
    // forever or blow the stack.
    let mut stack: Vec<(usize, u32)> = roots.iter().rev().map(|&i| (i, 1_u32)).collect();
    let mut visited = vec![false; lists.len()];
    while let Some((index, depth)) = stack.pop() {
        if visited.get(index).copied().unwrap_or(true) {
            continue;
        }
        if let Some(slot) = visited.get_mut(index) {
            *slot = true;
        }
        let under = children.get(index).map_or(0, Vec::len);
        let members = lists.members.get(index).map_or(0, Vec::len);
        // A folder by its attribute, or by what is under it: a history year
        // is a folder only in the second sense, an empty playlist folder only
        // in the first.
        let folder = lists.is_folder(index) || under > 0;
        let name = lists.name(index);
        // Depth 2 under the section's heading is the month, filed in a year.
        let name = match (style.calendar && folder && depth == 2, month_name(name)) {
            (true, Some(month)) => month.to_owned(),
            _ => name.to_owned(),
        };
        let smart = !folder && lists.is_smart(index);
        nodes.push(TreeNodeDto {
            id: lists.ids.get(index).copied().unwrap_or(0).to_string(),
            name,
            kind: if folder {
                style.folder
            } else if smart {
                style.smart
            } else {
                style.leaf
            },
            depth,
            expanded: if folder { Some(depth < open_to) } else { None },
            // An intelligent playlist's count is whatever its rule admits
            // today, which is not known until it is opened; the tree shows
            // none rather than evaluating every rule to draw itself.
            child_count: if smart {
                None
            } else {
                Some(u32::try_from(if folder { under } else { members }).unwrap_or(u32::MAX))
            },
        });
        if let Some(below) = children.get(index) {
            for &child in below.iter().rev() {
                stack.push((child, depth + 1));
            }
        }
    }
}

/// Adds only requested browser fields, keeping ordinary row pages small.
pub fn enrich_rows(state: &AppState, rows: &mut [RowDto], columns: &[String]) -> AppResult<()> {
    use serde_json::{json, Value};
    const FIELDS: &[&str] = &[
        "size", "discNo", "albumArtist", "composer", "lyricist", "fileType", "year",
        "mixName", "remixer", "originalArtist", "sampleRate", "bitrate", "bitDepth",
        "location", "dateCreated", "publishTrackInfo", "message", "color",
        "djPlayCount", "myTag", "trackNumber", "cloud",
    ];
    let wanted: Vec<&str> = columns.iter().map(String::as_str).filter(|column| FIELDS.contains(column)).collect();
    if wanted.is_empty() { return Ok(()); }
    state.read_db(|db| {
        for row in rows {
            if row.id.starts_with("file:") { continue; }
            let Some(details) = rbl_db::details::browser_details(db.connection(), &row.id)? else { continue };
            let mut values = serde_json::Map::new();
            for &column in &wanted {
                let value: Value = match column {
                    "size" => json!(details.file_size),
                    "discNo" => json!(details.disc_number),
                    "albumArtist" => json!(details.album_artist),
                    "composer" => json!(details.composer),
                    "lyricist" => json!(details.lyricist),
                    "fileType" => json!(details.file_type),
                    "year" => json!(details.year),
                    "mixName" => json!(details.mix_name),
                    "remixer" => json!(details.remixer),
                    "originalArtist" => json!(details.original_artist),
                    "sampleRate" => json!(details.sample_rate),
                    "bitrate" => json!(details.bitrate),
                    "bitDepth" => json!(details.bit_depth),
                    "location" => json!(details.path),
                    "dateCreated" => json!(details.date_created),
                    "publishTrackInfo" => json!(details.publish),
                    "message" => json!(details.message),
                    "color" => json!(details.color.parse::<u8>().unwrap_or(0)),
                    "djPlayCount" => json!(details.play_count),
                    "myTag" => json!(rbl_db::details::my_tag_names(db.connection(), &row.id).join(", ")),
                    "trackNumber" => json!(details.track_number),
                    "cloud" => json!(details.path.starts_with("/contents_")),
                    _ => continue,
                };
                values.insert(column.to_owned(), value);
            }
            row.extra = Some(values);
        }
        Ok(())
    }).map_err(write_error)
}

/// An extended M3U: a line of length and title, then the file, per track.
fn playlist_m3u8(library: &rbl_index::Library, rows: &[u32]) -> String {
    use std::fmt::Write as _;
    let mut out = String::from("#EXTM3U\n");
    for &row in rows {
        let i = row as usize;
        let artist = library.artist_name(row);
        let title = library.title.get(i);
        let name = if artist.is_empty() { title.to_owned() } else { format!("{artist} - {title}") };
        let _ = writeln!(out, "#EXTINF:{},{name}\n{}", library.length_sec.get(i).copied().unwrap_or(0), library.folder_path.get(i));
    }
    out
}

/// rekordbox's tab-separated listing: a header, then one line per track in
/// the playlist's order, times as `m:ss`.
fn playlist_txt(library: &rbl_index::Library, rows: &[u32]) -> String {
    use std::fmt::Write as _;
    let mut out = String::from("#\tTrack Title\tArtist\tAlbum\tGenre\tBPM\tRating\tTime\tKey\tDate Added\n");
    let clean = |text: &str| text.replace(['\t', '\n', '\r'], " ");
    for (n, &row) in rows.iter().enumerate() {
        let i = row as usize;
        let secs = library.length_sec.get(i).copied().unwrap_or(0);
        let bpm = f64::from(library.bpm_x100.get(i).copied().unwrap_or(0)) / 100.0;
        let _ = writeln!(
            out,
            "{}\t{}\t{}\t{}\t{}\t{bpm:.2}\t{}\t{}:{:02}\t{}\t{}",
            n + 1,
            clean(library.title.get(i)),
            clean(library.artist_name(row)),
            clean(library.album_name(row)),
            clean(library.genre_name(row)),
            library.rating.get(i).copied().unwrap_or(0),
            secs / 60,
            secs % 60,
            clean(library.key_name(row)),
            clean(library.date_added.get(i)),
        );
    }
    out
}
