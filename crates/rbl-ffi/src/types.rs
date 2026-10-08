//! Records and enums that cross the boundary.

/// What a tree node is, for choosing its icon.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NodeKind {
    AllTracks,
    Collection,
    Histories,
    Folder,
    Playlist,
    SmartPlaylist,
    /// A history year or month folder.
    HistoryFolder,
    /// A play session.
    History,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TreeNode {
    pub id: String,
    pub name: String,
    pub kind: NodeKind,
    pub depth: u32,
    pub expanded: Option<bool>,
    pub child_count: Option<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LibrarySummary {
    pub track_count: u32,
    pub playlist_count: u32,
    pub read_only: bool,
    pub db_version: Option<i64>,
    pub load_ms: u64,
}

/// Where a view's tracks come from. The ids are the tree nodes' ids.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum TrackSource {
    Collection,
    Playlist { id: String },
    PlaylistFolder { id: String },
    History { id: String },
    /// Not supported by this bridge yet; opening it is an error.
    Folder { path: String },
    /// Not supported by this bridge yet; opening it is an error.
    TagList,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ViewSpec {
    pub source: TrackSource,
    /// A wire sort name: `title`, `artist`, `bpm`, `dateAdded`, ... Unknown
    /// names sort in track order.
    pub sort: String,
    pub descending: bool,
    pub query: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ViewHandle {
    pub view_id: u32,
    pub len: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HotCue {
    /// `A` to `P`.
    pub slot: String,
    pub position_ms: u32,
    /// `#RRGGBB`, or none for the default green.
    pub color: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Row {
    pub id: String,
    pub track_no: u32,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    pub label: String,
    pub comment: String,
    pub bpm_x100: u32,
    pub key: String,
    pub duration_sec: u32,
    pub rating: u8,
    pub analysed: u8,
    pub date_added: String,
    pub release_date: String,
    pub hot_cues: Vec<HotCue>,
    pub memory_cues: Vec<u32>,
    pub artwork_hue: u16,
    pub has_artwork: bool,
    pub file_name: String,
}
