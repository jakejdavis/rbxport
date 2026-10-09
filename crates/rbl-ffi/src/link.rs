//! Pro DJ Link: the bridge's types and their conversions.
//!
//! `master_bpm` is an `f64`, so the status is a record without `Eq`.

use rbl_app::link::{InterfaceDto, LinkStatusDto, LoadedDto, PeerDto, PlayerDto};

/// Where the join is. `Off` while LINK is off.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LinkState {
    Off,
    /// Nothing is announced until a player or mixer is heard.
    Waiting,
    Joining,
    Up,
    /// The interface lost its address; `problem` says so.
    Down,
}

impl LinkState {
    fn from_wire(state: &str) -> Self {
        match state {
            "waiting" => Self::Waiting,
            "joining" => Self::Joining,
            "up" => Self::Up,
            "down" => Self::Down,
            _ => Self::Off,
        }
    }
}

/// What a device on the link is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LinkDeviceKind {
    Player,
    Mixer,
    Rekordbox,
    Device,
}

impl LinkDeviceKind {
    fn from_wire(kind: &str) -> Self {
        match kind {
            "player" => Self::Player,
            "mixer" => Self::Mixer,
            "rekordbox" => Self::Rekordbox,
            _ => Self::Device,
        }
    }
}

/// How an interface connects, as the OS reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum LinkConnection {
    Wired,
    Wireless,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkInterface {
    pub name: String,
    pub address: String,
    pub adapter: Option<String>,
    /// `None` when the OS does not say.
    pub connection: Option<LinkConnection>,
}

impl From<InterfaceDto> for LinkInterface {
    fn from(i: InterfaceDto) -> Self {
        let connection = match i.connection.as_deref() {
            Some("wired") => Some(LinkConnection::Wired),
            Some("wireless") => Some(LinkConnection::Wireless),
            _ => None,
        };
        Self { name: i.name, address: i.address, adapter: i.adapter, connection }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkLoaded {
    pub id: String,
    pub title: String,
    pub artist: String,
}

impl From<LoadedDto> for LinkLoaded {
    fn from(l: LoadedDto) -> Self {
        Self { id: l.id, title: l.title, artist: l.artist }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[allow(clippy::struct_excessive_bools, reason = "the player's lamps, sent together")]
pub struct LinkPlayer {
    pub number: u8,
    pub name: String,
    pub kind: LinkDeviceKind,
    pub address: String,
    pub loaded: Option<LinkLoaded>,
    pub playing: bool,
    pub master: bool,
    pub sync: bool,
    pub cued: bool,
    /// The player has mounted the library: a track can be sent to it.
    pub mounted: bool,
}

impl From<PlayerDto> for LinkPlayer {
    fn from(p: PlayerDto) -> Self {
        Self {
            number: p.number,
            name: p.name,
            kind: LinkDeviceKind::from_wire(&p.kind),
            address: p.address,
            loaded: p.loaded.map(Into::into),
            playing: p.playing,
            master: p.master,
            sync: p.sync,
            cued: p.cued,
            mounted: p.mounted,
        }
    }
}

/// A device heard before LINK is on.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkPeer {
    pub number: u8,
    pub name: String,
    pub kind: LinkDeviceKind,
    pub address: String,
}

impl From<PeerDto> for LinkPeer {
    fn from(p: PeerDto) -> Self {
        Self { number: p.number, name: p.name, kind: LinkDeviceKind::from_wire(&p.kind), address: p.address }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LinkStatus {
    pub on: bool,
    /// Why LINK is off and cannot be turned on, or why it went down.
    pub problem: Option<String>,
    pub interface: Option<LinkInterface>,
    pub players: Vec<LinkPlayer>,
    /// What LINK could run on, for the picker.
    pub interfaces: Vec<LinkInterface>,
    /// We are the network's tempo master.
    pub master: bool,
    pub master_bpm: f64,
    pub state: LinkState,
    pub number: Option<u8>,
}

impl From<LinkStatusDto> for LinkStatus {
    fn from(s: LinkStatusDto) -> Self {
        Self {
            on: s.on,
            problem: s.problem,
            interface: s.interface.map(Into::into),
            players: s.players.into_iter().map(Into::into).collect(),
            interfaces: s.interfaces.into_iter().map(Into::into).collect(),
            master: s.master,
            master_bpm: s.master_bpm,
            state: LinkState::from_wire(&s.state),
            number: s.number,
        }
    }
}
