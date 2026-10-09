//! The iTunes / Music library as a read-only source: its playlist tree, the tracks of a
//! playlist, and a selective import into the collection through the write gate.
//!
//! Nothing here reads a library the caller did not name, except [`default_library`], which looks
//! under the music folder it is given.

use std::collections::BTreeSet;
use std::path::Path;

use serde::Serialize;

use crate::dto::{ItunesLibraryDto, TreeNodeDto, XmlImportReportDto};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::EventSink;
use crate::state::AppState;

const NOT_ITUNES: &str = "That is not an iTunes or Music library file.";

/// One track of an iTunes playlist, for the read-only browser.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItunesTrackDto {
    pub id: String,
    pub title: String,
    pub artist: String,
    /// The file, when the library names one that is a file URL.
    pub path: Option<String>,
    /// Stars, 0 to 5.
    pub rating: u8,
    pub comment: String,
}

/// The playlist tree: folders and playlists only, flattened with a 1-based depth, ids
/// `itunes:<index>` so a selective import can name the chosen ones.
pub fn tree_dto(library: &rbl_db::xml::XmlLibrary) -> Vec<TreeNodeDto> {
    library
        .nodes
        .iter()
        .enumerate()
        .map(|(index, node)| TreeNodeDto {
            id: format!("itunes:{index}"),
            name: node.name.clone(),
            kind: if node.folder { "folder" } else { "playlist" },
            depth: u32::try_from(node.depth + 1).unwrap_or(1),
            expanded: None,
            child_count: if node.folder { None } else { u32::try_from(node.track_ids.len()).ok() },
        })
        .collect()
}

fn parse(path: &str) -> AppResult<rbl_db::xml::XmlLibrary> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| AppError::new(ErrorKind::NotFound, "That file could not be read.").with_detail(e.to_string()))?;
    rbl_db::itunes::parse(&text).ok_or_else(|| AppError::new(ErrorKind::Malformed, NOT_ITUNES))
}

/// The library at its usual place under `music_dir`; `None` when no shared `Library.xml` is there.
pub fn default_library(music_dir: &Path) -> AppResult<Option<ItunesLibraryDto>> {
    for path in rbl_db::itunes::candidate_library_paths(music_dir) {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        if let Some(library) = rbl_db::itunes::parse(&text) {
            return Ok(Some(ItunesLibraryDto { path: path.to_string_lossy().into_owned(), tree: tree_dto(&library) }));
        }
    }
    Ok(None)
}

/// The library at a file the DJ chose.
pub fn library_at(path: &str) -> AppResult<ItunesLibraryDto> {
    let library = parse(path)?;
    Ok(ItunesLibraryDto { path: path.to_owned(), tree: tree_dto(&library) })
}

/// The tracks of one playlist (`itunes:<index>`), in playlist order. A folder holds none.
pub fn playlist_tracks(path: &str, node: &str) -> AppResult<Vec<ItunesTrackDto>> {
    let index: usize = node
        .strip_prefix("itunes:")
        .and_then(|n| n.parse().ok())
        .ok_or_else(|| AppError::new(ErrorKind::Malformed, "That is not an iTunes playlist."))?;
    let library = parse(path)?;
    let node = library
        .nodes
        .get(index)
        .ok_or_else(|| AppError::new(ErrorKind::NotFound, "That playlist is no longer in the iTunes library."))?;
    let by_id: std::collections::HashMap<&str, &rbl_db::xml::XmlTrack> =
        library.tracks.iter().map(|t| (t.id.as_str(), t)).collect();
    Ok(node
        .track_ids
        .iter()
        .filter_map(|id| by_id.get(id.as_str()))
        .map(|t| ItunesTrackDto {
            id: t.id.clone(),
            title: t.title.clone(),
            artist: t.artist.clone(),
            path: t.path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            rating: t.rating,
            comment: t.comment.clone(),
        })
        .collect())
}

/// Imports the ticked playlists: their tracks, the folders above them, and each track's rating
/// and comment. Behind the write gate; raises `ImportProgress` per track.
pub fn import_selected(state: &AppState, sink: &dyn EventSink, path: &str, ids: &[String]) -> AppResult<XmlImportReportDto> {
    let keep: BTreeSet<usize> = ids.iter().filter_map(|id| id.strip_prefix("itunes:").and_then(|n| n.parse().ok())).collect();
    if keep.is_empty() {
        return Err(AppError::new(ErrorKind::Malformed, "Select at least one iTunes playlist to import."));
    }
    crate::import::import_collection(state, sink, path, move |text| {
        let full = rbl_db::itunes::parse(text).ok_or_else(|| AppError::new(ErrorKind::Malformed, NOT_ITUNES))?;
        Ok(rbl_db::xml::subset(&full, &keep))
    })
}

/// The whole library, as File > Import iTunes Library does.
pub fn import_all(state: &AppState, sink: &dyn EventSink, path: &str) -> AppResult<XmlImportReportDto> {
    crate::import::import_collection(state, sink, path, |text| {
        rbl_db::itunes::parse(text).ok_or_else(|| AppError::new(ErrorKind::Malformed, NOT_ITUNES))
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::test_support::{fixture, write_wav};

    /// A small Music library: two tracks (one real WAV, one that is missing), a folder holding
    /// a playlist, and a top-level playlist.
    fn write_library(dir: &Path) -> (String, std::path::PathBuf) {
        let wav = dir.join("Song One.wav");
        write_wav(&wav, 1);
        let url = format!("file://localhost{}", wav.to_string_lossy().replace(' ', "%20"));
        let xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Tracks</key><dict>
<key>1</key><dict><key>Track ID</key><integer>1</integer><key>Name</key><string>Song One</string><key>Artist</key><string>Ann</string><key>Rating</key><integer>80</integer><key>Comments</key><string>peak</string><key>Location</key><string>{url}</string></dict>
<key>2</key><dict><key>Track ID</key><integer>2</integer><key>Name</key><string>Gone</string><key>Artist</key><string>Bo</string><key>Location</key><string>file://localhost/nonexistent/Gone.wav</string></dict>
</dict>
<key>Playlists</key><array>
<dict><key>Name</key><string>Sets</string><key>Playlist Persistent ID</key><string>F1</string><key>Folder</key><true/></dict>
<dict><key>Name</key><string>Warmup</string><key>Playlist Persistent ID</key><string>P1</string><key>Parent Persistent ID</key><string>F1</string><key>Playlist Items</key><array><dict><key>Track ID</key><integer>1</integer></dict><dict><key>Track ID</key><integer>2</integer></dict></array></dict>
<dict><key>Name</key><string>Loose</string><key>Playlist Persistent ID</key><string>P2</string><key>Playlist Items</key><array><dict><key>Track ID</key><integer>2</integer></dict></array></dict>
</array></dict></plist>"#
        );
        let path = dir.join("Library.xml");
        std::fs::write(&path, xml).unwrap();
        (path.to_string_lossy().into_owned(), wav)
    }

    #[test]
    fn the_tree_and_a_playlists_tracks_are_read_without_writing() {
        let dir = tempfile::tempdir().unwrap();
        let (path, wav) = write_library(dir.path());
        let library = library_at(&path).unwrap();
        let names: Vec<_> = library.tree.iter().map(|n| (n.id.as_str(), n.name.as_str(), n.kind, n.depth)).collect();
        assert_eq!(names, vec![("itunes:0", "Sets", "folder", 1), ("itunes:1", "Warmup", "playlist", 2), ("itunes:2", "Loose", "playlist", 1)]);
        let tracks = playlist_tracks(&path, "itunes:1").unwrap();
        assert_eq!(tracks.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), vec!["Song One", "Gone"]);
        assert_eq!(tracks[0].rating, 4);
        assert_eq!(tracks[0].comment, "peak");
        assert_eq!(tracks[0].path.as_deref(), Some(wav.to_string_lossy().as_ref()));
        assert_eq!(playlist_tracks(&path, "itunes:0").unwrap().len(), 0);
        assert_eq!(playlist_tracks(&path, "itunes:9").unwrap_err().kind, ErrorKind::NotFound);
        assert_eq!(playlist_tracks(&path, "nope").unwrap_err().kind, ErrorKind::Malformed);
    }

    #[test]
    fn a_non_library_file_is_refused_and_the_default_search_stays_under_the_folder_given() {
        let dir = tempfile::tempdir().unwrap();
        let bad = dir.path().join("bad.xml");
        std::fs::write(&bad, "<html/>").unwrap();
        assert_eq!(library_at(&bad.to_string_lossy()).unwrap_err().kind, ErrorKind::Malformed);
        assert_eq!(library_at("/nonexistent-rbxport/x.xml").unwrap_err().kind, ErrorKind::NotFound);
        assert!(default_library(dir.path()).unwrap().is_none());
        std::fs::create_dir_all(dir.path().join("Music")).unwrap();
        let (path, _) = write_library(dir.path());
        std::fs::copy(&path, dir.path().join("Music/Library.xml")).unwrap();
        let found = default_library(dir.path()).unwrap().unwrap();
        assert!(found.path.ends_with("Music/Library.xml"));
        assert_eq!(found.tree.len(), 3);
    }

    #[test]
    fn import_goes_through_the_gate_and_dedupes_what_is_already_there() {
        let dir = tempfile::tempdir().unwrap();
        let (path, _) = write_library(dir.path());
        let ids = vec!["itunes:1".to_owned()];

        let (_keep, closed, sink) = fixture(true);
        let error = import_selected(&closed, &sink, &path, &ids).unwrap_err();
        assert_eq!(error.kind, ErrorKind::ReadOnly);
        assert_eq!(sink.names().len(), 0);

        let (_keep, state, sink) = fixture(false);
        assert_eq!(import_selected(&state, &sink, &path, &[]).unwrap_err().kind, ErrorKind::Malformed);
        let first = import_selected(&state, &sink, &path, &ids).unwrap();
        // The WAV is real and lands; the missing file is skipped. The folder and playlist are made (two).
        assert_eq!((first.imported, first.existing, first.skipped.len(), first.playlists), (1, 0, 1, 2));
        assert_eq!(first.tracks.len(), 1);
        assert!(sink.names().contains(&"import:progress"));
        assert!(sink.names().contains(&"library:changed"));
        assert!(sink.progress().iter().all(|&(done, total)| done <= total));

        sink.clear();
        let second = import_selected(&state, &sink, &path, &ids).unwrap();
        assert_eq!((second.imported, second.existing), (0, 1));
    }
}
