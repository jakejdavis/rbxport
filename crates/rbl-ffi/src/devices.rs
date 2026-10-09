//! Devices, export, sync and device settings: the bridge's types and their conversions.

use rbl_app::device_settings::{ColorNameDto, DeviceSettingsDto, MenuSlotDto, StickDefaultsDto};
use rbl_app::dto::{
    DeviceLibraryTreeDto, DevicePlaylistNodeDto, DeviceSyncStateDto, ExportProgressDto, ExportReportDto, MissingExportFileDto,
    SyncDeviceReportDto, SyncPlaylistDto, SyncProgressDto, VerifyReportDto,
};

/// Where an export to one stick has got to. The last three are final.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ExportState {
    Preparing,
    Checking,
    Copying,
    Database,
    Verifying,
    Publishing,
    Ejecting,
    Done,
    Cancelled,
    Failed,
}

impl ExportState {
    fn from_wire(state: &str) -> Self {
        match state {
            "checking" => Self::Checking,
            "copying" => Self::Copying,
            "database" => Self::Database,
            "verifying" => Self::Verifying,
            "publishing" => Self::Publishing,
            "ejecting" => Self::Ejecting,
            "done" => Self::Done,
            "cancelled" => Self::Cancelled,
            "failed" => Self::Failed,
            _ => Self::Preparing,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExportProgress {
    pub path: String,
    pub state: ExportState,
    pub done: u32,
    pub total: u32,
    /// The track being handled; on `Failed`, why.
    pub title: String,
}

impl From<ExportProgressDto> for ExportProgress {
    fn from(p: ExportProgressDto) -> Self {
        Self { path: p.path, state: ExportState::from_wire(p.state), done: p.done, total: p.total, title: p.title }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExportReport {
    pub tracks: u32,
    pub playlists: u32,
    pub bytes_copied: u64,
    pub analysis_files: u32,
    pub reused: u32,
    pub removed: u32,
    pub playlists_added: u32,
    pub playlists_removed: u32,
    pub skipped: Vec<String>,
    pub verified: bool,
}

impl From<ExportReportDto> for ExportReport {
    fn from(r: ExportReportDto) -> Self {
        Self {
            tracks: r.tracks,
            playlists: r.playlists,
            bytes_copied: r.bytes_copied,
            analysis_files: r.analysis_files,
            reused: r.reused,
            removed: r.removed,
            playlists_added: r.playlists_added,
            playlists_removed: r.playlists_removed,
            skipped: r.skipped,
            verified: r.verified,
        }
    }
}

/// One step of a sync to one stick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncState {
    Writing,
    Ejecting,
    Done,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncProgress {
    pub path: String,
    pub state: SyncState,
}

impl From<SyncProgressDto> for SyncProgress {
    fn from(p: SyncProgressDto) -> Self {
        let state = match p.state {
            "ejecting" => SyncState::Ejecting,
            "done" => SyncState::Done,
            "failed" => SyncState::Failed,
            _ => SyncState::Writing,
        };
        Self { path: p.path, state }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncDeviceReport {
    pub path: String,
    pub report: Option<ExportReport>,
    pub error: Option<String>,
    pub ejected: bool,
    pub eject_error: Option<String>,
}

impl From<SyncDeviceReportDto> for SyncDeviceReport {
    fn from(r: SyncDeviceReportDto) -> Self {
        Self { path: r.path, report: r.report.map(Into::into), error: r.error, ejected: r.ejected, eject_error: r.eject_error }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MissingExportFile {
    pub title: String,
    pub path: String,
}

impl From<MissingExportFileDto> for MissingExportFile {
    fn from(m: MissingExportFileDto) -> Self {
        Self { title: m.title, path: m.path }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncPlaylist {
    pub library_id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DevicePlaylistNode {
    pub id: String,
    pub parent_id: String,
    pub name: String,
    pub folder: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceLibraryTree {
    pub name: String,
    pub nodes: Vec<DevicePlaylistNode>,
}

/// What a stick was last synced with, and what it holds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceSyncState {
    pub selected: Vec<SyncPlaylist>,
    pub on_device: Vec<String>,
    pub libraries: Vec<DeviceLibraryTree>,
    pub automatic: bool,
}

impl From<DeviceSyncStateDto> for DeviceSyncState {
    fn from(s: DeviceSyncStateDto) -> Self {
        let selected = s.selected.into_iter().map(|SyncPlaylistDto { library_id, name }| SyncPlaylist { library_id, name }).collect();
        let libraries = s
            .libraries
            .into_iter()
            .map(|DeviceLibraryTreeDto { name, nodes }| DeviceLibraryTree {
                name,
                nodes: nodes
                    .into_iter()
                    .map(|DevicePlaylistNodeDto { id, parent_id, name, folder }| DevicePlaylistNode { id, parent_id, name, folder })
                    .collect(),
            })
            .collect();
        Self { selected, on_device: s.on_device, libraries, automatic: s.automatic }
    }
}

/// Converting non-CDJ formats on export (the Maximum CDJ compatibility pref).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CompatibilityFormat {
    Wav,
    Aiff,
    Mp3,
}

impl From<CompatibilityFormat> for rbl_export::CompatibilityFormat {
    fn from(f: CompatibilityFormat) -> Self {
        match f {
            CompatibilityFormat::Wav => Self::Wav,
            CompatibilityFormat::Aiff => Self::Aiff,
            CompatibilityFormat::Mp3 => Self::Mp3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WaveformColor {
    Blue,
    Rgb,
    ThreeBand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WaveformPosition {
    Center,
    Left,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StickOverview {
    Half,
    Full,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KeyDisplay {
    Classic,
    Alphanumeric,
}

impl WaveformColor {
    fn wire(self) -> &'static str {
        match self {
            Self::Blue => "blue",
            Self::Rgb => "rgb",
            Self::ThreeBand => "3band",
        }
    }
    fn parse(s: &str) -> Self {
        match s {
            "rgb" => Self::Rgb,
            "3band" => Self::ThreeBand,
            _ => Self::Blue,
        }
    }
}

impl WaveformPosition {
    fn wire(self) -> &'static str {
        match self {
            Self::Center => "center",
            Self::Left => "left",
        }
    }
    fn parse(s: &str) -> Self {
        if s == "left" { Self::Left } else { Self::Center }
    }
}

impl StickOverview {
    fn wire(self) -> &'static str {
        match self {
            Self::Half => "half",
            Self::Full => "full",
        }
    }
    fn parse(s: &str) -> Self {
        if s == "full" { Self::Full } else { Self::Half }
    }
}

impl KeyDisplay {
    fn wire(self) -> &'static str {
        match self {
            Self::Classic => "classic",
            Self::Alphanumeric => "alphanumeric",
        }
    }
    fn parse(s: &str) -> Self {
        if s == "alphanumeric" { Self::Alphanumeric } else { Self::Classic }
    }
}

/// What a stick with no settings of its own is given on export.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct StickDefaults {
    pub waveform_color: WaveformColor,
    pub waveform_position: WaveformPosition,
    pub overview_waveform: StickOverview,
    pub key_display: KeyDisplay,
}

impl From<StickDefaults> for StickDefaultsDto {
    fn from(d: StickDefaults) -> Self {
        Self {
            waveform_color: d.waveform_color.wire().to_owned(),
            waveform_position: d.waveform_position.wire().to_owned(),
            overview_waveform: d.overview_waveform.wire().to_owned(),
            key_display: d.key_display.wire().to_owned(),
            categories: None,
            sorts: None,
            sub_column: None,
        }
    }
}

/// How one export or sync is done.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ExportOptions {
    pub defaults: StickDefaults,
    pub delete_unlisted_music: bool,
    pub compatibility: Option<CompatibilityFormat>,
    /// Sync only: eject each stick once it has verified.
    pub eject_after_sync: bool,
}

/// One browse category or sort option on a stick.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MenuSlot {
    pub id: i64,
    pub menu_item: i64,
    pub name: String,
    pub seq: i64,
    pub visible: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ColorName {
    pub id: i64,
    pub name: String,
}

/// Everything the device panel's tabs show.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
// Presence flags for optional files, as in the wire shape.
#[allow(clippy::struct_excessive_bools)]
pub struct DeviceSettings {
    pub has_device_library: bool,
    pub has_one_library: bool,
    pub has_dev_setting: bool,
    pub waveform_color: WaveformColor,
    pub waveform_position: WaveformPosition,
    pub overview_waveform: StickOverview,
    pub key_display: KeyDisplay,
    pub has_library_settings: bool,
    pub device_name: String,
    pub background_color_type: i64,
    pub categories: Vec<MenuSlot>,
    pub sorts: Vec<MenuSlot>,
    pub sub_column: Option<i64>,
    pub colors: Vec<ColorName>,
}

fn slot(s: MenuSlotDto) -> MenuSlot {
    MenuSlot { id: s.id, menu_item: s.menu_item, name: s.name, seq: s.seq, visible: s.visible }
}

fn slot_dto(s: MenuSlot) -> MenuSlotDto {
    MenuSlotDto { id: s.id, menu_item: s.menu_item, name: s.name, seq: s.seq, visible: s.visible }
}

impl From<DeviceSettingsDto> for DeviceSettings {
    fn from(d: DeviceSettingsDto) -> Self {
        Self {
            has_device_library: d.has_device_library,
            has_one_library: d.has_one_library,
            has_dev_setting: d.has_dev_setting,
            waveform_color: WaveformColor::parse(&d.waveform_color),
            waveform_position: WaveformPosition::parse(&d.waveform_position),
            overview_waveform: StickOverview::parse(&d.overview_waveform),
            key_display: KeyDisplay::parse(&d.key_display),
            has_library_settings: d.has_library_settings,
            device_name: d.device_name,
            background_color_type: d.background_color_type,
            categories: d.categories.into_iter().map(slot).collect(),
            sorts: d.sorts.into_iter().map(slot).collect(),
            sub_column: d.sub_column,
            colors: d.colors.into_iter().map(|c| ColorName { id: c.id, name: c.name }).collect(),
        }
    }
}

impl From<DeviceSettings> for DeviceSettingsDto {
    fn from(d: DeviceSettings) -> Self {
        Self {
            has_device_library: d.has_device_library,
            has_one_library: d.has_one_library,
            has_dev_setting: d.has_dev_setting,
            waveform_color: d.waveform_color.wire().to_owned(),
            waveform_position: d.waveform_position.wire().to_owned(),
            overview_waveform: d.overview_waveform.wire().to_owned(),
            key_display: d.key_display.wire().to_owned(),
            has_library_settings: d.has_library_settings,
            device_name: d.device_name,
            background_color_type: d.background_color_type,
            categories: d.categories.into_iter().map(slot_dto).collect(),
            sorts: d.sorts.into_iter().map(slot_dto).collect(),
            sub_column: d.sub_column,
            colors: d.colors.into_iter().map(|c| ColorNameDto { id: c.id, name: c.name }).collect(),
        }
    }
}

/// What reading a stick back with the independent parser found.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VerifyReport {
    pub tracks: u32,
    pub playlists: u32,
    pub missing_audio: Vec<String>,
    pub errors: Vec<String>,
    pub ok: bool,
}

impl From<VerifyReportDto> for VerifyReport {
    fn from(v: VerifyReportDto) -> Self {
        Self { tracks: v.tracks, playlists: v.playlists, missing_audio: v.missing_audio, errors: v.errors, ok: v.ok }
    }
}
