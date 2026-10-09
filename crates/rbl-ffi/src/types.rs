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
    /// A directory on disk (the Explorer); an empty path lists nothing.
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
    /// The filter bar's picks; the default filters nothing.
    pub filter: TrackFilter,
}

/// BPM picks: whole-BPM values, a tolerance, and the master tempo to follow.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct BpmFilter {
    /// Whole BPMs (rounded) the bar has picked.
    pub values: Vec<u32>,
    /// 0 to 6; clamped by the core.
    pub tolerance_pct: u8,
    /// Master BPM x100 to match around instead of `values` (Phase 3).
    pub master_bpm_x100: Option<u32>,
}

/// One entry per filter-bar column; `None` is an unticked column. Keys and
/// colours travel as the names the bar shows.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct TrackFilter {
    pub bpm: Option<BpmFilter>,
    pub keys: Option<Vec<String>>,
    pub ratings: Option<Vec<u8>>,
    pub colors: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CountedBpm {
    pub value: u32,
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CountedKey {
    pub value: String,
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TagCategory {
    pub name: String,
    pub tags: Vec<String>,
}

/// What the filter bar offers for a source and query.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FilterValues {
    pub bpms: Vec<CountedBpm>,
    pub keys: Vec<CountedKey>,
    pub tags: Vec<TagCategory>,
}

/// One of the folders the Explorer starts from.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExplorerRoot {
    pub name: String,
    pub path: String,
}

/// The folders directly under one folder.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExplorerChildren {
    /// The first of them by name, up to the core's cap.
    pub names: Vec<String>,
    /// How many there were; more than `names` holds when the cap cut it.
    pub total: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceExport {
    pub tracks: u32,
    pub playlists: u32,
    pub ours: bool,
    pub written: String,
}

/// A mounted volume an export could be written to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Device {
    pub name: String,
    pub path: String,
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub file_system: String,
    pub removable: bool,
    pub volume_id: String,
    pub export: Option<DeviceExport>,
}

/// The file formats a playlist can be exported as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PlaylistFileFormat {
    M3u8,
    Txt,
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

/// Which of rekordbox's waveform palettes to read the preview tag for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WaveformKind {
    /// Three bytes a column (low, mid, high): `PWV6`.
    Bands,
    /// One byte a column (5 bits height, 3 whiteness): `PWAV`.
    Mono,
    /// Six bytes a column (height, two unread, r, g, b): `PWV4`.
    Colour,
    /// Three bytes a column at 150 columns a second: `PWV7`.
    BandsDetail,
    /// One byte a column, detail: `PWV3`.
    MonoDetail,
    /// Two bytes a column, detail: `PWV5`.
    ColourDetail,
}

impl WaveformKind {
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Bands => "bands",
            Self::Mono => "mono",
            Self::Colour => "colour",
            Self::BandsDetail => "bandsDetail",
            Self::MonoDetail => "monoDetail",
            Self::ColourDetail => "colourDetail",
        }
    }
}

/// One track in full, for the information panel.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TrackDetails {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub original_artist: String,
    pub composer: String,
    pub remixer: String,
    pub lyricist: String,
    pub genre: String,
    pub label: String,
    pub key: String,
    pub comment: String,
    pub mix_name: String,
    pub message: String,
    /// `"0"` or empty for none, `"1"` to `"8"` for rekordbox's eight colours.
    pub color: String,
    pub rating: u8,
    pub bpm_x100: u32,
    pub duration_sec: u32,
    pub year: u32,
    pub track_number: u32,
    pub disc_number: u32,
    pub play_count: u32,
    pub file_type: u32,
    pub file_size: u64,
    pub bitrate: u32,
    pub sample_rate: u32,
    pub bit_depth: u32,
    pub date_created: String,
    pub release_date: String,
    pub path: String,
    pub hot_cue_auto_load: bool,
    pub publish: bool,
    pub has_artwork: bool,
    pub my_tags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MyTag {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MyTagCategory {
    pub name: String,
    pub tags: Vec<MyTag>,
}

/// What the Info tab's dropdowns offer.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TrackLookups {
    pub keys: Vec<String>,
    pub genres: Vec<String>,
    pub my_tag_categories: Vec<MyTagCategory>,
}

/// One beat of a track's grid, the `PQTZ` offset already applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Beat {
    pub time_ms: u32,
    /// 1 to 4 in its bar; 1 is the downbeat.
    pub number: u8,
    pub tempo_x100: u16,
}

impl From<rbl_app::track_data::BeatDto> for Beat {
    fn from(b: rbl_app::track_data::BeatDto) -> Self {
        Self { time_ms: b.time_ms, number: b.number, tempo_x100: b.tempo_x100 }
    }
}

/// A cue point: a hot cue (with a letter), a memory cue, or a loop of either.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Cue {
    /// Empty when the id is not editable.
    pub id: String,
    pub position_ms: u32,
    /// Where a loop ends; 0 for a plain cue.
    pub out_ms: u32,
    /// `A` to `P` for a hot cue, empty for a memory cue.
    pub letter: String,
    pub memory: bool,
    /// `#RRGGBB`, or none for the default.
    pub colour: Option<String>,
    pub comment: String,
}

impl From<rbl_app::dto::CueDto> for Cue {
    fn from(c: rbl_app::dto::CueDto) -> Self {
        Self {
            id: c.id,
            position_ms: c.position_ms,
            out_ms: c.out_ms,
            letter: c.letter,
            memory: c.memory,
            colour: c.colour,
            comment: c.comment,
        }
    }
}

/// One phrase of the song structure.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Phrase {
    /// The 1-based beat it starts on.
    pub beat: u32,
    pub label: String,
    pub kind: u16,
    /// Where that beat falls, when the grid reaches it.
    pub time_ms: Option<u32>,
}

impl From<rbl_app::dto::PhraseDto> for Phrase {
    fn from(p: rbl_app::dto::PhraseDto) -> Self {
        Self { beat: p.beat, label: p.label, kind: p.kind, time_ms: p.time_ms }
    }
}
