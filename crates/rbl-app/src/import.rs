//! Importing audio files, folders and rekordbox XML collections into the library.

use std::path::{Path, PathBuf};

use crate::dto::{ExportProgressDto, ImportReportDto, ImportedTrackDto, XmlImportReportDto};
use crate::edits::{commit_maybe, Record, Touched};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::{AppEvent, EventSink};
use crate::state::AppState;

/// How deep a chosen folder is walked. A music library is a handful of levels
/// deep; a folder that turns out to be a whole drive is not walked to the bottom.
const IMPORT_MAX_DEPTH: usize = 16;
/// How many entries the walk looks at in all, so a folder pointed at the root of
/// a disk ends rather than running for minutes. Shared across every chosen path.
const IMPORT_MAX_ENTRIES: usize = 500_000;

/// Expands the chosen paths into the audio files to import.
///
/// A file the user picked is kept as chosen, even a non-audio one, so the writer
/// still reports it as skipped rather than dropping it silently. A directory is
/// walked breadth-first, keeping only the audio files rekordbox plays. Hidden
/// directories (`.Trashes`, `.Spotlight-V100` and the like) are left alone.
pub fn expand_import_paths(paths: &[String]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    let mut seen = 0_usize;
    for path in paths {
        let path = Path::new(path);
        // Anything that is not a directory is imported exactly as chosen.
        if !path.is_dir() {
            files.push(path.to_path_buf());
            continue;
        }
        let mut level = vec![path.to_path_buf()];
        for _ in 0..IMPORT_MAX_DEPTH {
            let mut next = Vec::new();
            for dir in &level {
                // perf-ok: a plain function, run on a blocking thread by its callers.
                let Ok(entries) = std::fs::read_dir(dir) else { continue };
                for entry in entries.flatten() {
                    seen += 1;
                    if seen > IMPORT_MAX_ENTRIES {
                        return files;
                    }
                    let child = entry.path();
                    let Ok(kind) = entry.file_type() else { continue };
                    if kind.is_dir() {
                        if entry.file_name().to_string_lossy().starts_with('.') {
                            continue;
                        }
                        next.push(child);
                    } else if kind.is_file() && rbl_db::import::is_audio(&child) {
                        files.push(child);
                    }
                }
            }
            if next.is_empty() {
                break;
            }
            level = next;
        }
    }
    files
}

fn file_title(file: &Path) -> String {
    file.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
}

fn clamp(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// Adds files and folders to the library. Reports what happened per file rather
/// than failing the whole batch. A file already in the library is reported as
/// `existing` (a drop onto a playlist still wants it there). Raises
/// `ImportProgress` after each file, and `LibraryChanged` only if something landed.
/// A closed write gate fails the call before anything is read or written.
pub fn import_files(state: &AppState, sink: &dyn EventSink, paths: &[String]) -> AppResult<ImportReportDto> {
    crate::edits::check_gate(state)?;
    let files = expand_import_paths(paths);
    let total = files.len();
    let label = paths.first().cloned().unwrap_or_default();
    let done = commit_maybe(state, sink, Touched::Tracks, |writer| {
        let mut report = ImportReportDto { imported: 0, skipped: Vec::new(), tracks: Vec::new(), existing: Vec::new() };
        for (index, file) in files.iter().enumerate() {
            if let Some(id) = writer.track_id_at(file)? {
                report.existing.push(ImportedTrackDto { id, title: file_title(file) });
            } else {
                match writer.import_file(file) {
                    Ok(id) => {
                        report.imported += 1;
                        report.tracks.push(ImportedTrackDto { id, title: file_title(file) });
                    }
                    Err(rbl_db::DbError::WriteRefused(reason)) => {
                        report.skipped.push(format!("{}: {reason}", file.display()));
                    }
                    Err(other) => return Err(other),
                }
            }
            sink.emit(AppEvent::ImportProgress(ExportProgressDto {
                path: label.clone(),
                state: "writing",
                done: clamp(index + 1),
                total: clamp(total),
                title: file_title(file),
            }));
        }
        let changed = report.imported > 0;
        Ok((report, Record::Nothing, changed))
    })?;
    Ok(done.value)
}

/// Reads a collection file with `parse` and imports what it holds in one writer
/// session, raising `ImportProgress` per track.
pub fn import_collection(
    state: &AppState,
    sink: &dyn EventSink,
    path: &str,
    parse: impl FnOnce(&str) -> AppResult<rbl_db::xml::XmlLibrary>,
) -> AppResult<XmlImportReportDto> {
    crate::edits::check_gate(state)?;
    let text = std::fs::read_to_string(path)
        .map_err(|e| AppError::new(ErrorKind::NotFound, "That file could not be read.").with_detail(e.to_string()))?;
    let document = parse(&text)?;
    let done = commit_maybe(state, sink, Touched::Tracks, |writer| {
        let mut on_progress = |done: usize, total: usize| {
            sink.emit(AppEvent::ImportProgress(ExportProgressDto {
                path: path.to_owned(),
                state: "writing",
                done: clamp(done),
                total: clamp(total),
                title: String::new(),
            }));
        };
        let report = rbl_db::xml::import(writer, &document, &mut on_progress)?;
        let changed = report.imported > 0 || report.playlists > 0;
        let dto = XmlImportReportDto {
            imported: clamp(report.imported),
            existing: clamp(report.existing),
            skipped: report.skipped,
            playlists: clamp(report.playlists),
            cues: clamp(report.cues),
            tracks: report.tracks.into_iter().map(|(id, title)| ImportedTrackDto { id, title }).collect(),
        };
        Ok((dto, Record::Nothing, changed))
    })?;
    Ok(done.value)
}

/// File > Import > rekordbox XML: the files it names, its playlists and cues.
pub fn import_xml(state: &AppState, sink: &dyn EventSink, path: &str) -> AppResult<XmlImportReportDto> {
    import_collection(state, sink, path, |text| {
        let document = rbl_db::xml::XmlLibrary::parse(text);
        if document.tracks.is_empty() && document.nodes.is_empty() {
            return Err(AppError::new(ErrorKind::Malformed, "That is not a rekordbox XML collection."));
        }
        Ok(document)
    })
}

/// The one-line summary both apps show after a file import.
pub fn import_message(report: &ImportReportDto) -> String {
    let total = report.imported as usize + report.skipped.len();
    let already = if report.existing.is_empty() { String::new() } else { format!("; {} already in the library", report.existing.len()) };
    if report.skipped.is_empty() {
        format!("Imported {} of {total} files{already}.", report.imported)
    } else {
        format!("Imported {} of {total} files; {} skipped{already}.", report.imported, report.skipped.len())
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::panic, clippy::assert_is_empty)]
mod tests {
    use super::*;
    use crate::edits::PROTECTED_MESSAGE;
    use crate::test_support::{fixture, write_wav};

    fn names(paths: &[PathBuf]) -> Vec<String> {
        let mut out: Vec<String> = paths.iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        out.sort();
        out
    }

    #[test]
    fn a_directory_is_walked_recursively_for_audio_only() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        // perf-ok: a test's fixture, not a command.
        std::fs::create_dir_all(root.join("subdir/deep")).unwrap();
        std::fs::write(root.join("top.mp3"), b"x").unwrap();
        std::fs::write(root.join("cover.jpg"), b"x").unwrap();
        std::fs::write(root.join("subdir/mid.flac"), b"x").unwrap();
        std::fs::write(root.join("subdir/deep/low.m4a"), b"x").unwrap();
        std::fs::write(root.join("subdir/notes.txt"), b"x").unwrap();
        let files = expand_import_paths(&[root.to_string_lossy().into_owned()]);
        assert_eq!(names(&files), ["low.m4a", "mid.flac", "top.mp3"]);
    }

    #[test]
    fn a_chosen_file_is_kept_even_when_it_is_not_audio() {
        let dir = tempfile::tempdir().unwrap();
        let song = dir.path().join("song.mp3");
        let sheet = dir.path().join("liner.txt");
        std::fs::write(&song, b"x").unwrap();
        std::fs::write(&sheet, b"x").unwrap();
        let files = expand_import_paths(&[song.to_string_lossy().into_owned(), sheet.to_string_lossy().into_owned()]);
        assert_eq!(names(&files), ["liner.txt", "song.mp3"]);
    }

    #[test]
    fn hidden_directories_are_passed_over() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".Trashes")).unwrap();
        std::fs::write(dir.path().join(".Trashes/ghost.mp3"), b"x").unwrap();
        std::fs::write(dir.path().join("real.mp3"), b"x").unwrap();
        let files = expand_import_paths(&[dir.path().to_string_lossy().into_owned()]);
        assert_eq!(names(&files), ["real.mp3"]);
    }

    #[test]
    fn files_and_folders_import_report_progress_and_a_repeat_changes_nothing() {
        let (_dir, state, sink) = fixture(false);
        let audio = tempfile::tempdir().unwrap();
        // perf-ok: a test's fixture, not a command.
        std::fs::create_dir_all(audio.path().join("set")).unwrap();
        write_wav(&audio.path().join("set/one.wav"), 1);
        write_wav(&audio.path().join("set/two.wav"), 1);
        let loose = audio.path().join("notes.txt");
        std::fs::write(&loose, b"x").unwrap();
        let before = state.library().unwrap().len();

        let folder = audio.path().join("set").display().to_string();
        let report = import_files(&state, &sink, &[folder.clone(), loose.display().to_string()]).unwrap();
        assert_eq!((report.imported, report.tracks.len(), report.skipped.len(), report.existing.len()), (2, 2, 1, 0));
        assert!(report.skipped[0].contains("notes.txt"));
        assert_eq!(state.library().unwrap().len(), before + 2);
        assert_eq!(sink.progress(), vec![(1, 3), (2, 3), (3, 3)]);
        let names = sink.names();
        assert_eq!(&names[names.len() - 2..], ["library:changed", "edit-history:changed"]);
        assert_eq!(import_message(&report), "Imported 2 of 3 files; 1 skipped.");

        // The same folder again: both are already there, nothing is read again or announced.
        sink.clear();
        let generation = state.summary().3;
        let again = import_files(&state, &sink, &[folder]).unwrap();
        assert_eq!((again.imported, again.existing.len(), again.skipped.len()), (0, 2, 0));
        let mut ids: Vec<&String> = again.existing.iter().map(|t| &t.id).collect();
        ids.sort();
        let mut landed: Vec<&String> = report.tracks.iter().map(|t| &t.id).collect();
        landed.sort();
        assert_eq!(ids, landed);
        assert_eq!(sink.names(), ["import:progress", "import:progress"]);
        assert_eq!(state.summary().3, generation);
        assert_eq!(import_message(&again), "Imported 0 of 0 files; 2 already in the library.");
    }

    #[test]
    fn a_closed_gate_refuses_an_import_before_touching_anything() {
        let (_dir, state, sink) = fixture(true);
        let audio = tempfile::tempdir().unwrap();
        write_wav(&audio.path().join("one.wav"), 1);
        let before = state.library().unwrap().len();
        let err = import_files(&state, &sink, &[audio.path().display().to_string()]).unwrap_err();
        assert_eq!((err.kind, err.message.as_str()), (ErrorKind::ReadOnly, PROTECTED_MESSAGE));
        let xml = audio.path().join("c.xml");
        std::fs::write(&xml, "<DJ_PLAYLISTS/>").unwrap();
        assert_eq!(import_xml(&state, &sink, &xml.display().to_string()).unwrap_err().kind, ErrorKind::ReadOnly);
        assert!(sink.names().is_empty());
        assert_eq!(state.library().unwrap().len(), before);
    }

    #[test]
    fn a_rekordbox_xml_collection_imports_with_its_playlist_and_progress() {
        let (_dir, state, sink) = fixture(false);
        let audio = tempfile::tempdir().unwrap();
        let one = audio.path().join("One.wav");
        write_wav(&one, 1);
        let doc = format!(
            r#"<?xml version="1.0"?><DJ_PLAYLISTS Version="1.0.0"><COLLECTION Entries="2">
            <TRACK TrackID="1" Name="One" Artist="A" Rating="153" Comments="hi" Location="file://localhost{}"/>
            <TRACK TrackID="2" Name="Gone" Artist="C" Rating="0" Location="file://localhost/nowhere/gone.wav"/>
            </COLLECTION><PLAYLISTS><NODE Type="0" Name="ROOT" Count="1">
            <NODE Name="Imported" Type="1" KeyType="0" Entries="1"><TRACK Key="1"/></NODE></NODE></PLAYLISTS></DJ_PLAYLISTS>"#,
            one.display()
        );
        let xml = audio.path().join("collection.xml");
        std::fs::write(&xml, doc).unwrap();
        let report = import_xml(&state, &sink, &xml.display().to_string()).unwrap();
        assert_eq!((report.imported, report.existing, report.skipped.len(), report.playlists), (1, 0, 1, 1));
        assert_eq!(sink.progress(), vec![(1, 2), (2, 2)]);
        let names = sink.names();
        assert_eq!(&names[names.len() - 2..], ["library:changed", "edit-history:changed"]);
        let tree = crate::browse::playlist_tree(&state).unwrap();
        assert!(tree.iter().any(|n| n.name == "Imported"));
        // A file that is not a collection is Malformed; one that is not there is NotFound.
        let junk = audio.path().join("junk.xml");
        std::fs::write(&junk, "hello").unwrap();
        assert_eq!(import_xml(&state, &sink, &junk.display().to_string()).unwrap_err().kind, ErrorKind::Malformed);
        assert_eq!(import_xml(&state, &sink, "/nowhere/x.xml").unwrap_err().kind, ErrorKind::NotFound);
    }
}
