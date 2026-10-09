//! Missing files, relocating them, and finding duplicate tracks.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::browse::MAX_ROWS;
use crate::dto::{DuplicateGroupDto, DuplicateTrackDto, DuplicatesDto, MissingTrackDto, MissingTracksDto};
use crate::edits::{commit_maybe, Record, Touched};
use crate::error::AppResult;
use crate::events::EventSink;
use crate::state::AppState;

/// What an automatic relocate did.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelocateReportDto {
    pub relocated: u32,
    /// Missing tracks whose file name was found in none of the folders.
    pub unresolved: u32,
}

/// Tracks whose audio file is no longer where the library says it is.
///
/// Bounded rather than exhaustive: a library can have thousands missing after a
/// drive is unplugged. The count is exact; the list is the first `limit`. An
/// empty path is a track that never had a file, not a missing one. Blocking.
pub fn missing_tracks(state: &AppState, limit: u32) -> AppResult<MissingTracksDto> {
    let library = state.library()?;
    let wanted = (limit as usize).min(MAX_ROWS as usize);
    let mut missing = Vec::with_capacity(wanted);
    let mut total = 0_u32;
    for index in 0..library.len() {
        let path = library.folder_path.get(index);
        if path.is_empty() || Path::new(path).exists() {
            continue;
        }
        total = total.saturating_add(1);
        if missing.len() < wanted {
            missing.push(MissingTrackDto {
                id: library.ids.get(index).copied().unwrap_or(0).to_string(),
                title: library.title.get(index).to_owned(),
                artist: library.artist_name(u32::try_from(index).unwrap_or(0)).to_owned(),
                path: path.to_owned(),
            });
        }
    }
    Ok(MissingTracksDto { total, tracks: missing })
}

/// Tracks that share a title and an artist, case and accents aside. Blocking.
pub fn find_duplicates(state: &AppState, limit: u32) -> AppResult<DuplicatesDto> {
    let library = state.library()?;
    let wanted = (limit as usize).min(MAX_ROWS as usize);
    let mut groups: HashMap<(&str, &str), Vec<usize>> = HashMap::new();
    for index in 0..library.len() {
        let title = library.title_folded.get(index);
        if title.trim().is_empty() {
            continue;
        }
        let artist = library.artists.folded(library.artist.get(index).copied().unwrap_or(rbl_index::NO_ID));
        groups.entry((title, artist)).or_default().push(index);
    }
    let mut found: Vec<Vec<usize>> = groups.into_values().filter(|rows| rows.len() > 1).collect();
    // By title, so the list reads the same from one look to the next.
    found.sort_by(|a, b| {
        let name = |rows: &Vec<usize>| rows.first().map_or("", |&i| library.title_folded.get(i)).to_owned();
        name(a).cmp(&name(b))
    });
    let extra = found.iter().map(|rows| u32::try_from(rows.len() - 1).unwrap_or(u32::MAX)).fold(0_u32, u32::saturating_add);
    let shown = found
        .iter()
        .take(wanted)
        .map(|rows| {
            let first = rows.first().copied().unwrap_or(0);
            DuplicateGroupDto {
                title: library.title.get(first).to_owned(),
                artist: library.artist_name(u32::try_from(first).unwrap_or(0)).to_owned(),
                tracks: rows
                    .iter()
                    .map(|&i| {
                        let path = library.folder_path.get(i);
                        DuplicateTrackDto {
                            id: library.ids.get(i).copied().unwrap_or(0).to_string(),
                            path: path.to_owned(),
                            duration_sec: library.length_sec.get(i).copied().unwrap_or(0),
                            present: !path.is_empty() && Path::new(path).is_file(),
                        }
                    })
                    .collect(),
            }
        })
        .collect();
    Ok(DuplicatesDto { groups: u32::try_from(found.len()).unwrap_or(u32::MAX), extra, shown })
}

/// How deep under a search folder the walk goes.
const MAX_DEPTH: usize = 16;
/// How many entries are looked at in all.
const MAX_ENTRIES: usize = 500_000;

/// Every file under `folders`, by name, the first found winning: breadth-first
/// per folder in the order given, so a name that appears twice resolves to the
/// shallower one in the earlier folder. Hidden directories are skipped.
pub fn index_folders(folders: &[PathBuf]) -> HashMap<String, PathBuf> {
    let mut found: HashMap<String, PathBuf> = HashMap::new();
    let mut seen = 0_usize;
    for folder in folders {
        let mut level: Vec<PathBuf> = vec![folder.clone()];
        for _ in 0..MAX_DEPTH {
            let mut next = Vec::new();
            for dir in &level {
                // perf-ok: a plain function, run on a blocking thread by its callers.
                let Ok(entries) = std::fs::read_dir(dir) else { continue };
                for entry in entries.flatten() {
                    seen += 1;
                    if seen > MAX_ENTRIES {
                        return found;
                    }
                    let path = entry.path();
                    let Ok(kind) = entry.file_type() else { continue };
                    if kind.is_dir() {
                        if entry.file_name().to_string_lossy().starts_with('.') {
                            continue;
                        }
                        next.push(path);
                    } else if kind.is_file() {
                        let name = entry.file_name().to_string_lossy().into_owned();
                        found.entry(name).or_insert(path);
                    }
                }
            }
            if next.is_empty() {
                break;
            }
            level = next;
        }
    }
    found
}

/// The file name a library row's path ends in.
fn file_name(path: &str) -> Option<String> {
    Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned())
}

/// Points every missing track at a same-named file under the folders (by file
/// name alone, as rekordbox's own search is described). The folders are walked
/// before the writer opens; nothing is written, and no event raised, when nothing
/// was found. Blocking.
pub fn auto_relocate(state: &AppState, sink: &dyn EventSink, folders: &[String]) -> AppResult<RelocateReportDto> {
    crate::edits::check_gate(state)?;
    let library = state.library()?;
    let mut missing: Vec<(String, String)> = Vec::new();
    for index in 0..library.len() {
        let path = library.folder_path.get(index);
        if path.is_empty() || Path::new(path).exists() {
            continue;
        }
        if let Some(name) = file_name(path) {
            missing.push((library.ids.get(index).copied().unwrap_or(0).to_string(), name));
        }
    }
    if missing.is_empty() {
        return Ok(RelocateReportDto { relocated: 0, unresolved: 0 });
    }
    let roots: Vec<PathBuf> = folders.iter().map(PathBuf::from).collect();
    let found = index_folders(&roots);
    let plan: Vec<(&String, &PathBuf)> = missing.iter().filter_map(|(id, name)| found.get(name).map(|p| (id, p))).collect();
    let unresolved = u32::try_from(missing.len() - plan.len()).unwrap_or(u32::MAX);
    if plan.is_empty() {
        return Ok(RelocateReportDto { relocated: 0, unresolved });
    }
    let done = commit_maybe(state, sink, Touched::Tracks, |writer| {
        for (id, path) in &plan {
            writer.relocate(id, path)?;
        }
        Ok((u32::try_from(plan.len()).unwrap_or(u32::MAX), Record::Nothing, true))
    })?;
    Ok(RelocateReportDto { relocated: done.value, unresolved })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod walk_tests {
    use super::*;

    #[test]
    fn the_first_folder_and_the_shallower_file_win() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        // perf-ok: a test's fixture, not a command.
        std::fs::create_dir_all(a.join("deep")).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        std::fs::write(a.join("deep/song.mp3"), b"x").unwrap();
        std::fs::write(a.join("other.mp3"), b"x").unwrap();
        std::fs::write(b.join("song.mp3"), b"y").unwrap();

        let found = index_folders(&[a.clone(), b.clone()]);
        assert_eq!(found.get("song.mp3"), Some(&a.join("deep/song.mp3")));
        assert_eq!(found.get("other.mp3"), Some(&a.join("other.mp3")));

        let found = index_folders(&[b.clone(), a.clone()]);
        assert_eq!(found.get("song.mp3"), Some(&b.join("song.mp3")));
    }

    #[test]
    fn hidden_directories_and_missing_folders_are_passed_over() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".Trashes")).unwrap();
        std::fs::write(dir.path().join(".Trashes/song.mp3"), b"x").unwrap();
        let found = index_folders(&[dir.path().to_path_buf(), dir.path().join("nowhere")]);
        assert!(found.is_empty());
    }

    #[test]
    fn a_file_name_is_the_last_segment_of_a_row_path() {
        assert_eq!(file_name("/Users/x/Music/Track.aiff").as_deref(), Some("Track.aiff"));
        assert_eq!(file_name(""), None);
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic, clippy::assert_is_empty)]
mod tests {
    use super::*;
    use crate::edits::PROTECTED_MESSAGE;
    use crate::error::ErrorKind;
    use crate::test_support::fixture;
    use rbl_db::fixture::track_id;

    #[test]
    fn every_fixture_track_is_missing_and_the_list_is_bounded() {
        let (_dir, state, _sink) = fixture(true);
        let all = missing_tracks(&state, 1000).unwrap();
        assert_eq!(all.total, 40);
        assert_eq!(all.tracks.len(), 40);
        let few = missing_tracks(&state, 5).unwrap();
        assert_eq!((few.total, few.tracks.len()), (40, 5));
        assert_eq!(few.tracks[0].path, "/fixture/audio/track000.mp3");
        // Missing tracks are only read: the closed gate does not matter.
    }

    #[test]
    fn a_track_is_relocated_by_hand_and_a_bad_target_is_refused() {
        let (_dir, state, sink) = fixture(false);
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("moved.mp3");
        std::fs::write(&file, b"x").unwrap();
        crate::track_edits::relocate_track(&state, &sink, &track_id(2), &file.display().to_string()).unwrap();
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"]);
        let list = missing_tracks(&state, 1000).unwrap();
        assert_eq!(list.total, 39);
        assert!(list.tracks.iter().all(|t| t.id != track_id(2)));
        let details = crate::details::track_details(&state, &track_id(2)).unwrap();
        assert_eq!(details.path, file.display().to_string());

        sink.clear();
        let err = crate::track_edits::relocate_track(&state, &sink, &track_id(3), &dir.path().display().to_string()).unwrap_err();
        assert_eq!(err.kind, ErrorKind::Malformed, "a folder is not a file");
        assert!(sink.names().is_empty());
    }

    #[test]
    fn a_closed_gate_refuses_relocation() {
        let (_dir, state, sink) = fixture(true);
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("track000.mp3"), b"x").unwrap();
        let err = auto_relocate(&state, &sink, &[dir.path().display().to_string()]).unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::ReadOnly, PROTECTED_MESSAGE));
        let err = crate::track_edits::relocate_track(&state, &sink, &track_id(0), "/x").unwrap_err();
        assert_eq!(err.kind, ErrorKind::ReadOnly);
        assert!(sink.names().is_empty());
        assert_eq!(missing_tracks(&state, 1).unwrap().total, 40);
    }

    #[test]
    fn auto_relocate_finds_files_by_name_and_reports_the_rest() {
        let (_dir, state, sink) = fixture(false);
        let dir = tempfile::tempdir().unwrap();
        // perf-ok: a test's fixture, not a command.
        std::fs::create_dir_all(dir.path().join("sub")).unwrap();
        std::fs::write(dir.path().join("track000.mp3"), b"x").unwrap();
        std::fs::write(dir.path().join("sub/track001.mp3"), b"x").unwrap();
        std::fs::write(dir.path().join("unrelated.mp3"), b"x").unwrap();
        let report = auto_relocate(&state, &sink, &[dir.path().display().to_string()]).unwrap();
        assert_eq!((report.relocated, report.unresolved), (2, 38));
        assert_eq!(sink.names(), ["library:changed", "edit-history:changed"]);
        assert_eq!(missing_tracks(&state, 1).unwrap().total, 38);

        // Nothing left to find: no write, no event.
        sink.clear();
        let again = auto_relocate(&state, &sink, &[dir.path().display().to_string()]).unwrap();
        assert_eq!((again.relocated, again.unresolved), (0, 38));
        assert!(sink.names().is_empty());
        let nowhere = auto_relocate(&state, &sink, &["/nowhere".into()]).unwrap();
        assert_eq!(nowhere.relocated, 0);
    }

    #[test]
    fn titles_shared_under_one_artist_are_duplicates_and_can_be_removed() {
        let (_dir, state, sink) = fixture(false);
        assert_eq!(find_duplicates(&state, 20).unwrap().groups, 0);
        let (a, b, c) = (track_id(0), track_id(1), track_id(2));
        for id in [&b, &c] {
            crate::track_edits::set_field(&state, &sink, std::slice::from_ref(id), "title", "TRACK 000").unwrap();
        }
        let found = find_duplicates(&state, 20).unwrap();
        assert_eq!((found.groups, found.extra), (1, 2), "case is folded");
        let group = &found.shown[0];
        assert_eq!(group.tracks.len(), 3);
        assert!(group.tracks.iter().all(|t| !t.present));
        let mut listed: Vec<&str> = group.tracks.iter().map(|t| t.id.as_str()).collect();
        listed.sort_unstable();
        assert_eq!(listed, [a.as_str(), b.as_str(), c.as_str()]);
        // The listing is bounded by the limit, the counts are not.
        assert_eq!(find_duplicates(&state, 0).unwrap().shown.len(), 0);
        assert_eq!(find_duplicates(&state, 0).unwrap().groups, 1);

        crate::track_edits::remove_from_collection(&state, &sink, &[b]).unwrap();
        assert_eq!(find_duplicates(&state, 20).unwrap().extra, 1);
    }
}
