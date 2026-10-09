//! Mechanical conversions between the core's DTOs and the bridge's types.

use rbl_app::dto::{
    DeviceDto, EditHistoryDto, ExplorerChildrenDto, ExplorerRootDto, FilterValuesDto, LibraryProblemDto, LibrarySummaryDto, RowDto, TrackSourceDto, TreeNodeDto,
    ViewHandleDto, ViewSpecDto,
};
use rbl_app::startup::LoadOutcome as CoreOutcome;
use rbl_app::AppEvent;

use crate::events::LibraryEvent;
use crate::types::{
    BpmFilter, CountedBpm, CountedKey, Device, DeviceExport, EditHistory, ExplorerChildren, ExplorerRoot, FilterValues,
    TagCategory, TrackFilter, ExtraColumn, ExtraFields, HotCue, LibraryProblem, LibrarySummary, LoadOutcome, NodeKind, Row, SearchField, SortKey,
    TrackSource, TreeNode, ViewHandle, ViewSpec, TrackDetails, TrackLookups, MyTag, MyTagCategory,
    ImportProgress, SmartCondition, SmartLogic, SmartRule, DuplicateGroup, DuplicateTrack, Duplicates, ImportReport,
    ImportedTrack, MissingTrack, MissingTracks, RelocateReport, XmlImportReport,
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

impl From<SearchField> for rbl_index::SearchField {
    fn from(field: SearchField) -> Self {
        match field {
            SearchField::All => Self::All,
            SearchField::Title => Self::Title,
            SearchField::Artist => Self::Artist,
            SearchField::Album => Self::Album,
            SearchField::Genre => Self::Genre,
            SearchField::Year => Self::Year,
            SearchField::Bpm => Self::Bpm,
            SearchField::Composer => Self::Composer,
            SearchField::AlbumArtist => Self::AlbumArtist,
            SearchField::Remixer => Self::Remixer,
            SearchField::Label => Self::Label,
            SearchField::Comment => Self::Comment,
            SearchField::OriginalArtist => Self::OriginalArtist,
            SearchField::MixName => Self::MixName,
        }
    }
}

impl ExtraColumn {
    /// The name the core's `enrich_rows` accepts.
    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::Size => "size",
            Self::DiscNo => "discNo",
            Self::AlbumArtist => "albumArtist",
            Self::Composer => "composer",
            Self::Lyricist => "lyricist",
            Self::FileType => "fileType",
            Self::Year => "year",
            Self::MixName => "mixName",
            Self::Remixer => "remixer",
            Self::OriginalArtist => "originalArtist",
            Self::SampleRate => "sampleRate",
            Self::Bitrate => "bitrate",
            Self::BitDepth => "bitDepth",
            Self::Location => "location",
            Self::DateCreated => "dateCreated",
            Self::PublishTrackInfo => "publishTrackInfo",
            Self::Message => "message",
            Self::Color => "color",
            Self::DjPlayCount => "djPlayCount",
            Self::MyTag => "myTag",
            Self::TrackNumber => "trackNumber",
            Self::Cloud => "cloud",
        }
    }
}

/// The core's JSON map of extra values, as typed fields.
fn extra_fields(map: Option<serde_json::Map<String, serde_json::Value>>) -> ExtraFields {
    let Some(map) = map else { return ExtraFields::default() };
    let text = |key: &str| map.get(key).and_then(|v| v.as_str()).map(str::to_owned);
    let number = |key: &str| map.get(key).and_then(serde_json::Value::as_u64);
    let small = |key: &str| number(key).map(|n| u32::try_from(n).unwrap_or(u32::MAX));
    let flag = |key: &str| map.get(key).and_then(serde_json::Value::as_bool);
    ExtraFields {
        size: number("size"),
        disc_no: small("discNo"),
        album_artist: text("albumArtist"),
        composer: text("composer"),
        lyricist: text("lyricist"),
        file_type: small("fileType"),
        year: small("year"),
        mix_name: text("mixName"),
        remixer: text("remixer"),
        original_artist: text("originalArtist"),
        sample_rate: small("sampleRate"),
        bitrate: small("bitrate"),
        bit_depth: small("bitDepth"),
        location: text("location"),
        date_created: text("dateCreated"),
        publish_track_info: flag("publishTrackInfo"),
        message: text("message"),
        color: number("color").map(|n| u8::try_from(n).unwrap_or(0)),
        dj_play_count: small("djPlayCount"),
        my_tag: text("myTag"),
        track_number: small("trackNumber"),
        cloud: flag("cloud"),
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
            search_field: spec.search_field.into(),
            filter: spec.filter.into(),
        }
    }
}

impl From<TrackFilter> for rbl_app::dto::TrackFilterDto {
    fn from(f: TrackFilter) -> Self {
        Self {
            bpm: f.bpm.map(|b: BpmFilter| rbl_app::dto::BpmFilterDto {
                values: b.values,
                tolerance_pct: b.tolerance_pct,
                master_bpm_x100: b.master_bpm_x100,
            }),
            keys: f.keys,
            ratings: f.ratings,
            colors: f.colors,
        }
    }
}

impl From<FilterValuesDto> for FilterValues {
    fn from(v: FilterValuesDto) -> Self {
        Self {
            bpms: v.bpms.into_iter().map(|c| CountedBpm { value: c.value, count: c.count }).collect(),
            keys: v.keys.into_iter().map(|c| CountedKey { value: c.value, count: c.count }).collect(),
            tags: v.tags.into_iter().map(|c| TagCategory { name: c.name, tags: c.tags }).collect(),
        }
    }
}

impl From<ExplorerRootDto> for ExplorerRoot {
    fn from(r: ExplorerRootDto) -> Self {
        Self { name: r.name, path: r.path }
    }
}

impl From<ExplorerChildrenDto> for ExplorerChildren {
    fn from(c: ExplorerChildrenDto) -> Self {
        Self { names: c.names, total: c.total }
    }
}

impl From<DeviceDto> for Device {
    fn from(d: DeviceDto) -> Self {
        Self {
            name: d.name,
            path: d.path,
            total_bytes: d.total_bytes,
            free_bytes: d.free_bytes,
            file_system: d.file_system,
            removable: d.removable,
            volume_id: d.volume_id,
            export: d.export.map(|e| DeviceExport {
                tracks: e.tracks,
                playlists: e.playlists,
                ours: e.ours,
                written: e.written,
            }),
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

fn node_kind(kind: &str, is_folder: bool) -> NodeKind {
    match kind {
        // A year or month folder and a session share the wire kind; only a
        // folder carries an expanded flag.
        "history" if is_folder => NodeKind::HistoryFolder,
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
            kind: node_kind(n.kind, n.expanded.is_some()),
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
            extra: extra_fields(r.extra),
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

impl From<rbl_app::dto::ImportedTrackDto> for ImportedTrack {
    fn from(t: rbl_app::dto::ImportedTrackDto) -> Self {
        Self { id: t.id, title: t.title }
    }
}

impl From<rbl_app::dto::ImportReportDto> for ImportReport {
    fn from(r: rbl_app::dto::ImportReportDto) -> Self {
        Self {
            imported: r.imported,
            skipped: r.skipped,
            tracks: r.tracks.into_iter().map(Into::into).collect(),
            existing: r.existing.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<rbl_app::dto::XmlImportReportDto> for XmlImportReport {
    fn from(r: rbl_app::dto::XmlImportReportDto) -> Self {
        Self {
            imported: r.imported,
            existing: r.existing,
            skipped: r.skipped,
            playlists: r.playlists,
            cues: r.cues,
            tracks: r.tracks.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<rbl_app::dto::MissingTracksDto> for MissingTracks {
    fn from(m: rbl_app::dto::MissingTracksDto) -> Self {
        Self {
            total: m.total,
            tracks: m.tracks.into_iter().map(|t| MissingTrack { id: t.id, title: t.title, artist: t.artist, path: t.path }).collect(),
        }
    }
}

impl From<rbl_app::dto::DuplicatesDto> for Duplicates {
    fn from(d: rbl_app::dto::DuplicatesDto) -> Self {
        Self {
            groups: d.groups,
            extra: d.extra,
            shown: d
                .shown
                .into_iter()
                .map(|g| DuplicateGroup {
                    title: g.title,
                    artist: g.artist,
                    tracks: g
                        .tracks
                        .into_iter()
                        .map(|t| DuplicateTrack { id: t.id, path: t.path, duration_sec: t.duration_sec, present: t.present })
                        .collect(),
                })
                .collect(),
        }
    }
}

impl From<rbl_app::maintenance::RelocateReportDto> for RelocateReport {
    fn from(r: rbl_app::maintenance::RelocateReportDto) -> Self {
        Self { relocated: r.relocated, unresolved: r.unresolved }
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
            AppEvent::CuesChanged(track_id) => Self::CuesChanged { track_id },
            AppEvent::GridChanged(track_id) => Self::GridChanged { track_id },
            AppEvent::AnalysisChanged(track_id) => Self::AnalysisChanged { track_id },
            AppEvent::DevicesChanged => Self::DevicesChanged,
            AppEvent::ImportProgress(p) => Self::ImportProgress {
                progress: ImportProgress { path: p.path, state: p.state.to_owned(), done: p.done, total: p.total, title: p.title },
            },
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

impl From<rbl_app::dto::TrackDetailsDto> for TrackDetails {
    fn from(d: rbl_app::dto::TrackDetailsDto) -> Self {
        Self {
            id: d.id,
            title: d.title,
            artist: d.artist,
            album: d.album,
            album_artist: d.album_artist,
            original_artist: d.original_artist,
            composer: d.composer,
            remixer: d.remixer,
            lyricist: d.lyricist,
            genre: d.genre,
            label: d.label,
            key: d.key,
            comment: d.comment,
            mix_name: d.mix_name,
            message: d.message,
            color: d.color,
            rating: d.rating,
            bpm_x100: d.bpm_x100,
            duration_sec: d.duration_sec,
            year: d.year,
            track_number: d.track_number,
            disc_number: d.disc_number,
            play_count: d.play_count,
            file_type: d.file_type,
            file_size: d.file_size,
            bitrate: d.bitrate,
            sample_rate: d.sample_rate,
            bit_depth: d.bit_depth,
            date_created: d.date_created,
            release_date: d.release_date,
            path: d.path,
            hot_cue_auto_load: d.hot_cue_auto_load,
            publish: d.publish,
            has_artwork: d.has_artwork,
            my_tags: d.my_tags,
        }
    }
}

impl From<rbl_app::dto::TrackLookupsDto> for TrackLookups {
    fn from(l: rbl_app::dto::TrackLookupsDto) -> Self {
        Self {
            keys: l.keys,
            genres: l.genres,
            my_tag_categories: l
                .my_tag_categories
                .into_iter()
                .map(|c| MyTagCategory {
                    name: c.name,
                    tags: c.tags.into_iter().map(|t| MyTag { id: t.id, name: t.name }).collect(),
                })
                .collect(),
        }
    }
}

impl From<rbl_app::dto::SmartRuleDto> for SmartRule {
    fn from(rule: rbl_app::dto::SmartRuleDto) -> Self {
        Self {
            logic: if rule.logic == "any" { SmartLogic::Any } else { SmartLogic::All },
            conditions: rule
                .conditions
                .into_iter()
                .map(|c| SmartCondition { property: c.property, operator: c.operator, left: c.left, right: c.right, unit: c.unit })
                .collect(),
        }
    }
}

impl From<SmartRule> for rbl_app::dto::SmartRuleDto {
    fn from(rule: SmartRule) -> Self {
        Self {
            logic: match rule.logic {
                SmartLogic::All => "all",
                SmartLogic::Any => "any",
            }
            .to_owned(),
            conditions: rule
                .conditions
                .into_iter()
                .map(|c| rbl_app::dto::SmartConditionDto { property: c.property, operator: c.operator, left: c.left, right: c.right, unit: c.unit })
                .collect(),
        }
    }
}
