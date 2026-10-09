//! Where the application log lives and how it is read back, for the bug report and "Reveal log".
//!
//! The writer (a daily file, the last five kept) is installed by whichever shell runs: the Tauri
//! shell's `logging` module, or the native app's `rbl_ffi::install_logging`. Both write
//! `rbxport.YYYY-MM-DD.log` into [`log_dir`].

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use crate::error::{AppError, AppResult};

/// Where the log files go: `<data dir>/rbxport/logs`, beside the backups.
pub const LOG_DIR: &str = "rbxport/logs";
/// Names the log directory, for a test or a support case.
pub const LOG_DIR_ENV: &str = "RBXPORT_LOG_DIR";

/// The directory the log files are written to.
pub fn log_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os(LOG_DIR_ENV).filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    dirs::data_dir().unwrap_or_else(std::env::temp_dir).join(LOG_DIR)
}

/// The newest daily log, which is the file this process is currently writing. Daily filenames put
/// their ISO date between the fixed prefix and suffix, so filename order is date order and does
/// not depend on buffered writes having updated filesystem timestamps yet.
pub fn latest_log_file() -> std::io::Result<Option<PathBuf>> {
    latest_log_file_in(&log_dir())
}

pub fn latest_log_file_in(dir: &Path) -> std::io::Result<Option<PathBuf>> {
    let mut newest: Option<(String, PathBuf)> = None;
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("rbxport.") || Path::new(&name).extension().is_none_or(|ext| ext != "log") {
            continue;
        }
        if newest.as_ref().is_none_or(|(current, _)| name > *current) {
            newest = Some((name, entry.path()));
        }
    }
    Ok(newest.map(|(_, path)| path))
}

/// The whole newest log in `dir`, verbatim (no redaction: the person sees it before sending it).
pub fn read_latest(dir: &Path) -> AppResult<String> {
    const NONE: &str = "No application log available.\n";
    let path = match latest_log_file_in(dir) {
        Ok(Some(path)) => path,
        Ok(None) => return Ok(NONE.into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(NONE.into()),
        Err(e) => return Err(AppError::internal(format!("The log directory could not be read: {e}"))),
    };
    let bytes = std::fs::read(path).map_err(|e| AppError::internal(e.to_string()))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// The last `max_bytes` of `path`, starting at a line boundary when it had to cut.
pub fn tail(path: &Path, max_bytes: u64) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let len = file.metadata()?.len();
    let cut = len > max_bytes;
    file.seek(SeekFrom::Start(len.saturating_sub(max_bytes)))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    if cut {
        // The first line is probably half of one.
        return Ok(text.split_once('\n').map_or(String::new(), |(_, rest)| rest.to_owned()));
    }
    Ok(text)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn latest_log_is_the_newest_daily_file() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["rbxport.2026-09-22.log", "rbxport.2026-09-24.log", "rbxport.2026-09-23.log", "notes.log"] {
            std::fs::write(dir.path().join(name), name).unwrap();
        }
        std::fs::create_dir(dir.path().join("rbxport.2099-01-01.log")).unwrap();
        assert_eq!(latest_log_file_in(dir.path()).unwrap(), Some(dir.path().join("rbxport.2026-09-24.log")));
    }

    #[test]
    fn report_log_preserves_the_entire_file_verbatim() {
        let directory = tempfile::tempdir().unwrap();
        let log = format!(
            "email=dj@example.com path=/Users/dj/Music title=Unreleased Track custom-field=visible\n{}\nend of log\n",
            "x".repeat(1_048_576),
        );
        std::fs::write(directory.path().join("rbxport.2026-10-06.log"), &log).unwrap();
        assert_eq!(read_latest(directory.path()).unwrap(), log);
    }

    #[test]
    fn no_log_reads_as_a_sentence_not_an_error() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_latest(dir.path()).unwrap(), "No application log available.\n");
        assert_eq!(read_latest(&dir.path().join("missing")).unwrap(), "No application log available.\n");
    }

    #[test]
    fn a_tail_starts_on_a_line_boundary() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rbxport.2026-10-09.log");
        std::fs::write(&path, "first line\nsecond line\nthird line\n").unwrap();
        assert_eq!(tail(&path, 1000).unwrap(), "first line\nsecond line\nthird line\n");
        assert_eq!(tail(&path, 20).unwrap(), "third line\n");
    }
}
