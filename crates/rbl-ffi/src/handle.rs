//! The object Swift holds: one open library and its open views.

use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use rbl_db::{Library as Db, LibraryLocation, OpenMode};
use rbl_index::{Library, View};

use crate::error::FfiError;
use crate::tree::build_tree;
use crate::types::{LibrarySummary, Row, TreeNode, ViewHandle, ViewSpec};
use crate::views::{rows_to_records, spec_from_wire};
use crate::{MAX_ROWS, MAX_VIEWS};

/// Open views, least recently used first in `order`.
#[derive(Default)]
struct Views {
    next_id: u32,
    open: HashMap<u32, Arc<View>>,
    order: VecDeque<u32>,
}

impl Views {
    fn register(&mut self, view: View) -> u32 {
        self.next_id = self.next_id.wrapping_add(1);
        let id = self.next_id;
        self.open.insert(id, Arc::new(view));
        self.order.push_back(id);
        while self.order.len() > MAX_VIEWS {
            if let Some(oldest) = self.order.pop_front() {
                self.open.remove(&oldest);
            }
        }
        id
    }

    fn touch(&mut self, id: u32) -> Option<Arc<View>> {
        let view = self.open.get(&id).map(Arc::clone)?;
        self.order.retain(|&other| other != id);
        self.order.push_back(id);
        Some(view)
    }
}

#[derive(uniffi::Object)]
pub struct LibraryHandle {
    library: Library,
    db_version: Option<i64>,
    load_ms: u64,
    views: Mutex<Views>,
}

impl LibraryHandle {
    fn from_location(location: LibraryLocation) -> Result<Arc<Self>, FfiError> {
        let started = Instant::now();
        // Read-only, always. This crate has no path that opens read-write.
        let db = Db::open(location, OpenMode::ReadOnly)?;
        let db_version = db.schema().db_version;
        let (library, _stats) = rbl_index::load(&db)
            .map_err(|e| FfiError::internal(format!("could not index the library: {e}")))?;
        Ok(Arc::new(Self {
            library,
            db_version,
            load_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            views: Mutex::new(Views::default()),
        }))
    }

    fn views(&self) -> MutexGuard<'_, Views> {
        // A poisoned lock only means another call panicked; the map is intact.
        self.views.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[uniffi::export]
#[allow(clippy::needless_pass_by_value)]
impl LibraryHandle {
    /// Opens the installed rekordbox library, read-only.
    #[uniffi::constructor]
    pub fn open_installed() -> Result<Arc<Self>, FfiError> {
        Self::from_location(rbl_db::detect()?)
    }

    /// Opens (building it first if `dir` has none) a fixture library, read-only.
    #[uniffi::constructor]
    pub fn open_fixture(dir: String) -> Result<Arc<Self>, FfiError> {
        let dir = Path::new(&dir);
        let master_db = dir.join("master.db");
        let location = if master_db.is_file() {
            LibraryLocation {
                master_db,
                share_root: dir.join("share"),
                passphrase: rbl_db::fixture::FIXTURE_PASSPHRASE.to_owned(),
                is_real_install: false,
            }
        } else {
            std::fs::create_dir_all(dir)
                .map_err(|e| FfiError::internal(format!("cannot create {}: {e}", dir.display())))?;
            rbl_db::fixture::build(dir, rbl_db::fixture::Shape::default())?
        };
        Self::from_location(location)
    }

    pub fn summary(&self) -> LibrarySummary {
        LibrarySummary {
            track_count: u32::try_from(self.library.len()).unwrap_or(u32::MAX),
            playlist_count: u32::try_from(self.library.playlists().len()).unwrap_or(u32::MAX),
            read_only: true,
            db_version: self.db_version,
            load_ms: self.load_ms,
        }
    }

    pub fn playlist_tree(&self) -> Vec<TreeNode> {
        build_tree(&self.library)
    }

    pub fn open_view(&self, spec: ViewSpec) -> Result<ViewHandle, FfiError> {
        let parsed = spec_from_wire(&self.library, &spec)?;
        let view = self.library.open_view(&parsed);
        let len = u32::try_from(view.len()).unwrap_or(u32::MAX);
        let view_id = self.views().register(view);
        Ok(ViewHandle { view_id, len })
    }

    pub fn fetch_rows(&self, view_id: u32, offset: u32, len: u32) -> Result<Vec<Row>, FfiError> {
        if len > MAX_ROWS {
            return Err(FfiError::malformed(format!(
                "Too many rows requested at once: len {len} exceeds the {MAX_ROWS}-row cap"
            )));
        }
        let view = self.views().touch(view_id).ok_or_else(|| {
            FfiError::not_found(format!("view {view_id} was evicted or never existed"))
        })?;
        let offset = offset as usize;
        let window = view.window(offset, len as usize);
        Ok(rows_to_records(&self.library, window, |position| view.track_no_at(position), offset))
    }

    /// Forgets a view early; unknown ids are ignored.
    pub fn close_view(&self, view_id: u32) {
        let mut views = self.views();
        views.open.remove(&view_id);
        views.order.retain(|&other| other != view_id);
    }
}
