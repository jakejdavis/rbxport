//! Mechanical conversions between the core's DTOs and the bridge's types.

use rbl_app::dto::{
    EditHistoryDto, LibraryProblemDto, LibrarySummaryDto, RowDto, TrackSourceDto, TreeNodeDto,
    ViewHandleDto, ViewSpecDto,
};
use rbl_app::startup::LoadOutcome as CoreOutcome;
use rbl_app::AppEvent;

use crate::events::LibraryEvent;
use crate::types::{
    EditHistory, HotCue, LibraryProblem, LibrarySummary, LoadOutcome, NodeKind, Row, SortKey,
    TrackSource, TreeNode, ViewHandle, ViewSpec,
};

impl SortKey {
    /// The name the core's `sort_from_wire` accepts.
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::TrackNo => "trackNo",
            Self::Title => "title",
            Self::Artist => "artist",
            Self::Album => "album",
            Self::Genre => "genre",
            Self::Label => "label",
            Self::Comment => "comment",
            Self::Key => "key",
            Self::KeyCamelot => "keyCamelot",
            Self::Bpm => "bpm",
            Self::Duration => "duration",
            Self::Rating => "rating",
            Self::PlayCount => "djPlayCount",
            Self::DateAdded => "dateAdded",
            Self::ReleaseDate => "releaseDate",
            Self::Size => "size",
            Self::Year => "year",
            Self::SampleRate => "sampleRate",
            Self::Bitrate => "bitrate",
            Self::Color => "color",
            Self::FileName => "fileName",
            Self::Location => "location",
            Self::Composer => "composer",
            Self::AlbumArtist => "albumArtist",
            Self::Remixer => "remixer",
            Self::OriginalArtist => "originalArtist",
            Self::MixName => "mixName",
            Self::DiscNo => "discNo",
            Self::TrackNumber => "trackNumber",
            Self::FileType => "fileType",
            Self::BitDepth => "bitDepth",
            Self::Lyricist => "lyricist",
            Self::DateCreated => "dateCreated",
            Self::PublishTrackInfo => "publishTrackInfo",
            Self::Message => "message",
        }
    }
}

impl From<TrackSource> for TrackSourceDto {
    fn from(source: TrackSource) -> Self {
        match source {
            TrackSource::Collection => Self::Collection,
            TrackSource::Playlist { id } => Self::Playlist { id },
            TrackSource::PlaylistFolder { id } => Self::PlaylistFolder { id },
            TrackSource::History { id } => Self::History { id },
            TrackSource::Folder { path } => Self::Folder { path },
            TrackSource::TagList => Self::TagList,
        }
    }
}

impl From<ViewSpec> for ViewSpecDto {
    fn from(spec: ViewSpec) -> Self {
        Self {
            source: spec.source.into(),
            sort: spec.sort.wire().to_owned(),
            descending: spec.descending,
            query: spec.query,
            search_field: rbl_index::SearchField::default(),
            filter: rbl_app::dto::TrackFilterDto::default(),
        }
    }
}

impl From<LibrarySummaryDto> for LibrarySummary {
    fn from(s: LibrarySummaryDto) -> Self {
        Self {
            track_count: s.track_count,
            playlist_count: s.playlist_count,
            read_only: s.read_only,
            db_version: s.db_version,
            load_ms: s.load_ms,
        }
    }
}

fn node_kind(kind: &str) -> NodeKind {
    match kind {
        "allTracks" => NodeKind::AllTracks,
        "collection" => NodeKind::Collection,
        "histories" => NodeKind::Histories,
        "folder" => NodeKind::Folder,
        "smartPlaylist" => NodeKind::SmartPlaylist,
        "history" => NodeKind::History,
        _ => NodeKind::Playlist,
    }
}

impl From<TreeNodeDto> for TreeNode {
    fn from(n: TreeNodeDto) -> Self {
        Self {
            id: n.id,
            name: n.name,
            kind: node_kind(n.kind),
            depth: n.depth,
            expanded: n.expanded,
            child_count: n.child_count,
        }
    }
}

impl From<ViewHandleDto> for ViewHandle {
    fn from(h: ViewHandleDto) -> Self {
        Self { view_id: h.view_id, len: h.len, generation: h.gen }
    }
}

impl From<RowDto> for Row {
    fn from(r: RowDto) -> Self {
        Self {
            id: r.id,
            track_no: r.track_no,
            title: r.title,
            artist: r.artist,
            album: r.album,
            genre: r.genre,
            label: r.label,
            comment: r.comment,
            bpm_x100: r.bpm_x100,
            key: r.key,
            duration_sec: r.duration_sec,
            rating: r.rating,
            analysed: r.analysed,
            date_added: r.date_added,
            release_date: r.release_date,
            hot_cues: r
                .hot_cues
                .into_iter()
                .map(|cue| HotCue { slot: cue.0.to_string(), position_ms: cue.1, color: cue.2 })
                .collect(),
            memory_cues: r.memory_cues,
            artwork_hue: r.artwork_hue,
            has_artwork: r.has_artwork,
            file_name: r.file_name,
        }
    }
}

impl From<LibraryProblemDto> for LibraryProblem {
    fn from(p: LibraryProblemDto) -> Self {
        match p {
            LibraryProblemDto::Missing { master_db } => Self::Missing { master_db },
            LibraryProblemDto::Failed { message } => Self::Failed { message },
        }
    }
}

impl From<EditHistoryDto> for EditHistory {
    fn from(h: EditHistoryDto) -> Self {
        Self {
            generation: h.generation,
            can_undo: h.can_undo,
            can_redo: h.can_redo,
            undo_label: h.undo_label,
            redo_label: h.redo_label,
        }
    }
}

impl From<AppEvent> for LibraryEvent {
    fn from(event: AppEvent) -> Self {
        match event {
            AppEvent::LibraryReady => Self::LibraryReady,
            AppEvent::LibraryProblem(problem) => Self::LibraryProblem { problem: problem.into() },
            AppEvent::LibraryChanged(generation) => Self::LibraryChanged { generation },
            AppEvent::TagListChanged(generation) => Self::TagListChanged { generation },
            AppEvent::EditHistoryChanged(history) => Self::EditHistoryChanged { history: history.into() },
        }
    }
}

impl From<CoreOutcome> for LoadOutcome {
    fn from(outcome: CoreOutcome) -> Self {
        match outcome {
            CoreOutcome::Ready => Self::Ready,
            CoreOutcome::Problem => Self::Problem,
        }
    }
}
