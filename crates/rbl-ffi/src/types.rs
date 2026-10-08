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
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TrackSource {
    Collection,
    Playlist { id: String },
    PlaylistFolder { id: String },
    History { id: String },
    /// Not supported by this bridge yet; opening it is an error.
    Folder { path: String },
    TagList,
}

/// The columns a view sorts by. `TrackNo` is the view's own order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SortKey {
    TrackNo,
    Title,
    Artist,
    Album,
    Genre,
    Label,
    Comment,
    Key,
    KeyCamelot,
    Bpm,
    Duration,
    Rating,
    PlayCount,
    DateAdded,
    ReleaseDate,
    Size,
    Year,
    SampleRate,
    Bitrate,
    Color,
    FileName,
    Location,
    Composer,
    AlbumArtist,
    Remixer,
    OriginalArtist,
    MixName,
    DiscNo,
    TrackNumber,
    FileType,
    BitDepth,
    Lyricist,
    DateCreated,
    PublishTrackInfo,
    Message,
}

/// Which field a search query matches. `All` searches every field.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SearchField {
    #[default]
    All,
    Title,
    Artist,
    Album,
    Genre,
    Year,
    Bpm,
    Composer,
    AlbumArtist,
    Remixer,
    Label,
    Comment,
    OriginalArtist,
    MixName,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ViewSpec {
    pub source: TrackSource,
    pub sort: SortKey,
    pub descending: bool,
    pub query: String,
    pub search_field: SearchField,
}

/// The columns `fetch_rows` fills in only when asked: each costs a database
/// read per row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ExtraColumn {
    Size,
    DiscNo,
    AlbumArtist,
    Composer,
    Lyricist,
    FileType,
    Year,
    MixName,
    Remixer,
    OriginalArtist,
    SampleRate,
    Bitrate,
    BitDepth,
    Location,
    DateCreated,
    PublishTrackInfo,
    Message,
    Color,
    DjPlayCount,
    MyTag,
    TrackNumber,
    Cloud,
}

/// The values of the requested [`ExtraColumn`]s; the rest stay `None`.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ExtraFields {
    pub size: Option<u64>,
    pub disc_no: Option<u32>,
    pub album_artist: Option<String>,
    pub composer: Option<String>,
    pub lyricist: Option<String>,
    /// rekordbox's file type code.
    pub file_type: Option<u32>,
    pub year: Option<u32>,
    pub mix_name: Option<String>,
    pub remixer: Option<String>,
    pub original_artist: Option<String>,
    pub sample_rate: Option<u32>,
    pub bitrate: Option<u32>,
    pub bit_depth: Option<u32>,
    pub location: Option<String>,
    pub date_created: Option<String>,
    pub publish_track_info: Option<bool>,
    pub message: Option<String>,
    /// 1 to 8, 0 for none.
    pub color: Option<u8>,
    pub dj_play_count: Option<u32>,
    pub my_tag: Option<String>,
    pub track_number: Option<u32>,
    pub cloud: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ViewHandle {
    pub view_id: u32,
    pub len: u32,
    /// The library generation the view was opened against.
    pub generation: u32,
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
    /// Filled for the columns asked of `fetch_rows`.
    pub extra: ExtraFields,
}

/// Why the library did not load.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LibraryProblem {
    /// No library here at all, and one could be made at `master_db`.
    Missing { master_db: String },
    /// There is a library, or something in its place, and it would not open.
    Failed { message: String },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EditHistory {
    pub generation: u32,
    pub can_undo: bool,
    pub can_redo: bool,
    pub undo_label: Option<String>,
    pub redo_label: Option<String>,
}

/// How a load ended; the same news also arrives as an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoadOutcome {
    Ready,
    Problem,
}
