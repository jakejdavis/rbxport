//! Mounted volumes: noticing one arrive or leave, and reading a stick's
//! playlist trees.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::dto::{DeviceLibraryTreeDto, DevicePlaylistNodeDto};
use crate::error::{AppError, AppResult, ErrorKind};
use crate::events::{AppEvent, EventSink};

pub use rbl_devices::MountWatcher;

/// Starts watching for volumes being plugged in or pulled out, raising
/// `DevicesChanged` through `sink` on each change. Dropping the watcher stops it.
pub fn start_mount_watcher(sink: Arc<dyn EventSink>) -> rbl_devices::MountWatcher {
    start_mount_watcher_every(rbl_devices::mounts::INTERVAL, sink)
}

/// [`start_mount_watcher`] with its own looking interval, for tests.
pub fn start_mount_watcher_every(interval: std::time::Duration, sink: Arc<dyn EventSink>) -> rbl_devices::MountWatcher {
    rbl_devices::MountWatcher::start(interval, move || sink.emit(AppEvent::DevicesChanged))
}

fn err(e: impl std::fmt::Display) -> AppError {
    let detail = format!("USB import: {e}");
    AppError::new(ErrorKind::Internal, detail.clone()).with_detail(detail)
}

/// The playlist trees of a stick's Device Library and `OneLibrary`.
pub fn library_trees(root: &Path) -> AppResult<Vec<DeviceLibraryTreeDto>> {
    let export = rbl_devices::settings::export_root(root);
    let mut libraries = Vec::new();
    let pdb = export.join("rekordbox/export.pdb");
    if pdb.exists() {
        let bytes = std::fs::read(pdb).map_err(err)?;
        let parsed = rbl_pdb::Pdb::parse(&bytes).map_err(err)?;
        let mut nodes = parsed.table(rbl_pdb::PageType::PlaylistTree).map(|t| parsed.playlist_nodes(t)).unwrap_or_default();
        nodes.sort_by_key(|n| (n.parent_id, n.sort_order));
        libraries.push(DeviceLibraryTreeDto { name: "Device Library".into(), nodes: nodes.into_iter().map(|n| DevicePlaylistNodeDto {
            id: n.id.to_string(), parent_id: n.parent_id.to_string(), name: n.name, folder: n.is_folder,
        }).collect() });
    }
    let one = export.join("rekordbox/exportLibrary.db");
    if one.exists() {
        let db = rbl_onelibrary::ExportLibrary::open_read_only(&one).map_err(err)?;
        let mut q = db.connection().prepare("SELECT playlist_id, COALESCE(playlist_id_parent,0), name, attribute FROM playlist ORDER BY sequenceNo").map_err(err)?;
        let nodes = q.query_map([], |r| Ok(DevicePlaylistNodeDto { id: r.get::<_,i64>(0)?.to_string(), parent_id: r.get::<_,i64>(1)?.to_string(), name: r.get(2)?, folder: r.get::<_,i64>(3)? != 0 })).map_err(err)?.collect::<Result<Vec<_>,_>>().map_err(err)?;
        libraries.push(DeviceLibraryTreeDto { name: "OneLibrary".into(), nodes });
    }
    Ok(libraries)
}

/// The mount points of the volumes now offered, for a front end that wants
/// them without reading what each holds.
#[must_use]
pub fn mount_points() -> Vec<PathBuf> {
    rbl_devices::list().into_iter().map(|device| device.mount_point).collect()
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::test_support::Recorder;
    use std::time::{Duration, Instant};

    struct Shared(Arc<Recorder>);
    impl EventSink for Shared {
        fn emit(&self, event: AppEvent) {
            self.0.emit(event);
        }
    }

    /// The only test in this crate that sets `RB_LITE_FAKE_VOLUMES`.
    #[test]
    fn the_watcher_raises_devices_changed_when_a_fake_volume_appears_and_goes() {
        let volumes = tempfile::tempdir().unwrap();
        let (one, two) = (volumes.path().join("ONE"), volumes.path().join("TWO"));
        std::fs::create_dir_all(&one).unwrap();
        std::fs::create_dir_all(&two).unwrap();
        std::env::set_var(rbl_devices::FAKE_VOLUMES, &one);
        let recorder = Arc::new(Recorder::default());
        let watcher = start_mount_watcher_every(Duration::from_millis(40), Arc::new(Shared(Arc::clone(&recorder))));
        std::thread::sleep(Duration::from_millis(300));
        assert!(recorder.names().is_empty(), "the first look is a baseline, not a change");
        assert_eq!(mount_points(), std::slice::from_ref(&one));

        let wait_for = |count: usize| {
            let deadline = Instant::now() + Duration::from_secs(5);
            while recorder.names().len() < count && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            recorder.names().len()
        };
        std::env::set_var(rbl_devices::FAKE_VOLUMES, format!("{}:{}", one.display(), two.display()));
        assert_eq!(wait_for(1), 1);
        assert_eq!(recorder.names(), ["devices:changed"]);
        assert_eq!(mount_points().len(), 2);
        std::env::set_var(rbl_devices::FAKE_VOLUMES, &one);
        assert_eq!(wait_for(2), 2);
        watcher.stop();
        std::env::remove_var(rbl_devices::FAKE_VOLUMES);
    }
}
