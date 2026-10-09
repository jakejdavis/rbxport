//! Backups, the bug report's diagnostics, the log and making a new library: the app-chrome
//! surface of the core, as records Swift can use.

use std::path::Path;
use std::sync::OnceLock;

use rbl_app::dto::BackupDto;

/// Where a backup has got to. The same news arrives as `LibraryEvent::BackupProgress`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BackupPhase {
    /// No backup has run since launch.
    Idle,
    Preparing,
    Copying,
    Compressing,
    Validating,
    /// A stop was asked for and the job has not yet noticed.
    Stopping,
    Complete,
    Cancelled,
    Failed,
}

impl BackupPhase {
    fn parse(phase: &str) -> Self {
        match phase {
            "preparing" => Self::Preparing,
            "copying" => Self::Copying,
            "compressing" => Self::Compressing,
            "validating" => Self::Validating,
            "stopping" => Self::Stopping,
            "complete" => Self::Complete,
            "cancelled" => Self::Cancelled,
            "failed" => Self::Failed,
            _ => Self::Idle,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BackupProgress {
    pub running: bool,
    pub phase: BackupPhase,
    pub copied_bytes: u64,
    pub total_bytes: u64,
    pub error: Option<String>,
    /// The archive, once complete.
    pub path: Option<String>,
    pub current_item: Option<String>,
}

impl From<rbl_app::backups::BackupProgress> for BackupProgress {
    fn from(p: rbl_app::backups::BackupProgress) -> Self {
        Self {
            running: p.running,
            phase: BackupPhase::parse(&p.phase),
            copied_bytes: p.copied_bytes,
            total_bytes: p.total_bytes,
            error: p.error,
            path: p.path,
            current_item: p.current_item,
        }
    }
}

/// One archive in the backup folder.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BackupInfo {
    pub name: String,
    pub path: String,
    pub bytes: u64,
    /// Milliseconds since the epoch.
    pub created_at: u64,
    pub includes_analysis: bool,
    pub includes_artwork: bool,
}

impl From<BackupDto> for BackupInfo {
    fn from(b: BackupDto) -> Self {
        Self {
            name: b.name,
            path: b.path,
            bytes: b.bytes,
            created_at: b.created_at,
            includes_analysis: b.includes_analysis,
            includes_artwork: b.includes_artwork,
        }
    }
}

/// Where a new library would go.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NewLibraryPlan {
    pub master_db: String,
    /// False when rekordbox's own options file already names the database.
    pub can_choose_location: bool,
}

impl From<rbl_app::new_library::NewLibraryPlan> for NewLibraryPlan {
    fn from(p: rbl_app::new_library::NewLibraryPlan) -> Self {
        Self { master_db: p.master_db.display().to_string(), can_choose_location: p.can_choose_location }
    }
}

/// The audio engine's health, or zeros while it has not opened.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct AudioHealth {
    pub load: f32,
    pub xruns: u64,
}

/// What a bug report says about the build, the machine, this process and the log.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SystemReport {
    pub app_version: String,
    pub os: String,
    pub os_version: String,
    pub arch: String,
    /// Percent of one core.
    pub cpu: f32,
    pub memory_mb: f64,
    pub threads: Option<u32>,
    pub open_files: Option<u32>,
    pub log_dir: String,
    /// The newest log file, when there is one.
    pub log_path: Option<String>,
    /// The end of that file, from a line boundary. Verbatim: it may name paths and titles.
    pub log_tail: String,
}

/// How much of the log a report carries.
const LOG_TAIL_BYTES: u64 = 64 * 1024;

pub(crate) fn system_report() -> SystemReport {
    let info = rbl_app::diagnostics::system_info(env!("CARGO_PKG_VERSION"));
    let sample = rbl_app::diagnostics::sample_shared();
    let dir = rbl_app::logs::log_dir();
    let log = rbl_app::logs::latest_log_file_in(&dir).ok().flatten();
    let tail = log.as_deref().and_then(|p| rbl_app::logs::tail(p, LOG_TAIL_BYTES).ok());
    SystemReport {
        app_version: info.app_version,
        os: info.os,
        os_version: info.os_version,
        arch: info.arch,
        cpu: sample.cpu,
        memory_mb: sample.memory_mb,
        threads: sample.threads,
        open_files: sample.open_files,
        log_dir: dir.display().to_string(),
        log_path: log.map(|p| p.display().to_string()),
        log_tail: tail.unwrap_or_else(|| "No application log available.\n".into()),
    }
}

/// Writes the application log to a daily file under the log folder (see `SystemReport.log_dir`);
/// safe to call twice. Returns the folder, or why there is no log file.
#[uniffi::export]
pub fn install_logging() -> Result<String, crate::error::FfiError> {
    install_logging_impl().map_err(rbl_app::AppError::internal).map_err(crate::error::FfiError::from)
}

/// The crates the log level applies to: ours, and nothing pulled in.
const OUR_CRATES: [&str; 12] = [
    "rbl_ffi", "rbl_app", "rbl_core", "rbl_db", "rbl_index", "rbl_anlz", "rbl_analysis", "rbl_audio", "rbl_deck", "rbl_prolink", "rbl_link",
    "rbl_export",
];

static FILE_GUARD: OnceLock<tracing_appender::non_blocking::WorkerGuard> = OnceLock::new();

/// Writes the application log to a daily file under [`rbl_app::logs::log_dir`] (the last five
/// kept), our crates at `debug` (or `LOG_LEVEL`) and dependencies at `warn`, and makes a panic a
/// log line. Safe to call twice. Returns the directory, or why there is no log file.
fn install_logging_impl() -> Result<String, String> {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let dir = rbl_app::logs::log_dir();
    if FILE_GUARD.get().is_some() {
        return Ok(dir.display().to_string());
    }
    let level = std::env::var("LOG_LEVEL")
        .ok()
        .map(|l| l.trim().to_ascii_lowercase())
        .filter(|l| ["error", "warn", "info", "debug", "trace"].contains(&l.as_str()))
        .unwrap_or_else(|| "debug".into());
    let ours: Vec<String> = OUR_CRATES.iter().map(|c| format!("{c}={level}")).collect();
    let filter = tracing_subscriber::EnvFilter::new(format!("warn,{}", ours.join(",")));
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let appender = tracing_appender::rolling::Builder::new()
        .rotation(tracing_appender::rolling::Rotation::DAILY)
        .filename_prefix("rbxport")
        .filename_suffix("log")
        .max_log_files(5)
        .build(Path::new(&dir))
        .map_err(|e| e.to_string())?;
    let (writer, guard) = tracing_appender::non_blocking(appender);
    let _ = FILE_GUARD.set(guard);
    tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer().with_writer(writer).with_ansi(false))
        .try_init()
        .map_err(|e| e.to_string())?;
    std::panic::set_hook(Box::new(|info| tracing::error!(%info, "panic")));
    tracing::debug!(dir = %dir.display(), "logging to a daily file");
    Ok(dir.display().to_string())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    #[test]
    fn phases_map_from_the_core_s_words() {
        assert_eq!(BackupPhase::parse(""), BackupPhase::Idle);
        assert_eq!(BackupPhase::parse("copying"), BackupPhase::Copying);
        assert_eq!(BackupPhase::parse("stopping"), BackupPhase::Stopping);
        assert_eq!(BackupPhase::parse("failed"), BackupPhase::Failed);
    }

    #[test]
    fn a_report_names_the_build_and_the_machine() {
        let report = system_report();
        assert_eq!(report.app_version, env!("CARGO_PKG_VERSION"));
        assert!(!report.os.is_empty() && !report.arch.is_empty());
        assert!(report.memory_mb > 0.0);
        assert_ne!(report.log_tail, "");
    }
}
