//! Playback over the bridge: the decks, the preview player, and the listener
//! the ticker pushes into.
//!
//! The Rust ticker thread owns the beat (ten deck ticks and thirty meter
//! updates a second); Swift interpolates between ticks. Nothing here is polled
//! per display frame.

use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::Arc;

use rbl_app::error::run_command;
use rbl_app::player::{DeckEventDto, DeckTickDto, MeterDto, PlaybackSink, Player, TickDto};
use rbl_app::preview::{Preview, PreviewStateDto};
use rbl_app::state::AppState;
use rbl_app::{AppError, AppResult, ErrorKind};

use crate::error::FfiError;

/// A deck. The player has two.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Deck {
    A,
    B,
}

impl From<Deck> for rbl_deck::Deck {
    fn from(deck: Deck) -> Self {
        match deck {
            Deck::A => Self::A,
            Deck::B => Self::B,
        }
    }
}

/// One deck in a tick. Frames are at the tick's `sample_rate`.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
#[allow(clippy::struct_excessive_bools, reason = "the deck's flags, sent together")]
pub struct DeckTick {
    /// Negative during pre-roll.
    pub frames: i64,
    pub total_frames: u64,
    /// Bumped on every load and seek, so the front end snaps rather than eases.
    pub generation: u32,
    pub playing: bool,
    pub loaded: bool,
    /// The load whose audio is installed; zero for none.
    pub load_id: u64,
    /// Speed as a multiple of the file's own.
    pub tempo: f32,
    pub master_tempo: bool,
    pub key_shift: i8,
    pub start_in_frames: u64,
    pub loop_in_frames: u64,
    pub loop_out_frames: u64,
    pub looping: bool,
}

impl From<DeckTickDto> for DeckTick {
    fn from(d: DeckTickDto) -> Self {
        Self {
            frames: d.frames,
            total_frames: d.total_frames,
            generation: d.generation,
            playing: d.playing,
            loaded: d.loaded,
            load_id: d.load_id,
            tempo: d.tempo,
            master_tempo: d.master_tempo,
            key_shift: d.key_shift,
            start_in_frames: d.start_in_frames,
            loop_in_frames: d.loop_in_frames,
            loop_out_frames: d.loop_out_frames,
            looping: d.looping,
        }
    }
}

/// Both decks and the master, as of one moment.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct PlaybackTick {
    pub a: DeckTick,
    pub b: DeckTick,
    pub sample_rate: u32,
    pub peak_left: f32,
    pub peak_right: f32,
    pub master: f32,
    pub reduction: f32,
    /// Whether this build can shift a key (the Rubber Band backend is in).
    pub shifts_key: bool,
}

impl From<TickDto> for PlaybackTick {
    fn from(t: TickDto) -> Self {
        Self {
            a: t.a.into(),
            b: t.b.into(),
            sample_rate: t.sample_rate,
            peak_left: t.peak_left,
            peak_right: t.peak_right,
            master: t.master,
            reduction: t.reduction,
            shifts_key: t.shifts_key,
        }
    }
}

/// The master's meters, at 30 Hz.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Meters {
    pub rms_left: f32,
    pub rms_right: f32,
    pub peak_left: f32,
    pub peak_right: f32,
    pub master: f32,
    pub reduction: f32,
}

impl From<MeterDto> for Meters {
    fn from(m: MeterDto) -> Self {
        Self {
            rms_left: m.rms_left,
            rms_right: m.rms_right,
            peak_left: m.peak_left,
            peak_right: m.peak_right,
            master: m.master,
            reduction: m.reduction,
        }
    }
}

/// A deck finished loading, or failed to.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeckEvent {
    pub deck: Deck,
    pub load_id: u64,
    pub total_frames: u64,
    pub sample_rate: u32,
    /// `None` on success.
    pub message: Option<String>,
}

impl From<&DeckEventDto> for DeckEvent {
    fn from(e: &DeckEventDto) -> Self {
        Self {
            deck: if e.deck == "b" { Deck::B } else { Deck::A },
            load_id: e.load_id,
            total_frames: e.total_frames,
            sample_rate: e.sample_rate,
            message: e.message.clone(),
        }
    }
}

/// The preview player: its track, whether it is playing, and where.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PreviewState {
    pub track_id: Option<String>,
    pub playing: bool,
    pub position_ms: f64,
    pub duration_ms: f64,
}

impl From<PreviewStateDto> for PreviewState {
    fn from(p: PreviewStateDto) -> Self {
        Self { track_id: p.track, playing: p.playing, position_ms: p.position_ms, duration_ms: p.duration_ms }
    }
}

/// Implemented in Swift. Called from the ticker thread (ticks, meters) and the
/// engine's own threads (deck events): hand off, do not block.
#[uniffi::export(with_foreign)]
pub trait PlaybackListener: Send + Sync {
    /// Both decks, about ten times a second while anything is sounding, plus
    /// once after it stops.
    fn on_tick(&self, tick: PlaybackTick);
    /// The master meters, about thirty times a second.
    fn on_meters(&self, meters: Meters);
    fn on_deck_event(&self, event: DeckEvent);
    /// The engine was dropped (device or rate change). Re-read `state()`.
    fn on_reset(&self);
}

struct ListenerSink(Arc<dyn PlaybackListener>);

impl PlaybackSink for ListenerSink {
    fn tick(&self, tick: &TickDto) {
        self.0.on_tick((*tick).into());
    }

    fn meters(&self, meters: &MeterDto) {
        self.0.on_meters((*meters).into());
    }

    fn deck_event(&self, event: &DeckEventDto) {
        self.0.on_deck_event(event.into());
    }

    fn reset(&self) {
        self.0.on_reset();
    }
}

fn ffi<T>(name: &str, f: impl FnOnce() -> AppResult<T>) -> Result<T, FfiError> {
    run_command(name, AssertUnwindSafe(f)).map_err(FfiError::from)
}

/// The decks and the preview player. One per `Core`.
///
/// Honours `RBXPORT_NULL_AUDIO=1` (a silent, real-time sink) so playback can
/// be driven without a sound ever being made.
#[derive(uniffi::Object)]
pub struct Playback {
    state: Arc<AppState>,
    player: Arc<Player>,
    preview: Arc<Preview>,
}

impl Playback {
    pub(crate) fn new(state: Arc<AppState>, listener: Arc<dyn PlaybackListener>) -> Self {
        let player = Arc::new(Player::default());
        player.attach_sink(Arc::new(ListenerSink(listener)));
        Self { state, player, preview: Arc::new(Preview::default()) }
    }

    fn path_of(&self, track_id: &str) -> AppResult<PathBuf> {
        let library = self.state.library()?;
        library.audio_path_of(track_id).map(PathBuf::from).ok_or_else(|| {
            AppError::new(ErrorKind::NotFound, "That track's file could not be found.")
                .with_detail(format!("track {track_id}"))
        })
    }
}

#[uniffi::export]
#[allow(clippy::needless_pass_by_value)]
impl Playback {
    /// Points a deck at a track. Returns once the engine has been told; the
    /// deck reports itself ready with a `DeckEvent`. Opens the audio output on
    /// first use, which can take a moment: call it off the main thread.
    pub fn load(&self, deck: Deck, track_id: String, load_id: u64) -> Result<(), FfiError> {
        ffi("deck_load", || {
            let path = self.path_of(&track_id)?;
            let engine = self.player.engine()?;
            let which = rbl_deck::Deck::from(deck);
            engine.load_as(which, &path, load_id);
            self.player.loaded_tracks.lock().insert(which, track_id);
            Ok(())
        })
    }

    pub fn unload(&self, deck: Deck) {
        let which = rbl_deck::Deck::from(deck);
        self.player.loaded_tracks.lock().remove(&which);
        if let Some(engine) = self.player.opened() {
            engine.unload(which);
        }
    }

    /// The track on a deck, as last loaded.
    pub fn loaded_track(&self, deck: Deck) -> Option<String> {
        self.player.loaded_tracks.lock().get(&rbl_deck::Deck::from(deck)).cloned()
    }

    pub fn play(&self, deck: Deck) -> Result<(), FfiError> {
        ffi("deck_play", || {
            self.player.engine()?.play(deck.into());
            self.player.start_ticker();
            Ok(())
        })
    }

    pub fn pause(&self, deck: Deck) {
        if let Some(engine) = self.player.opened() {
            engine.pause(deck.into());
        }
    }

    /// Moves a deck's playhead, frame-exact. Negative is pre-roll.
    pub fn seek_ms(&self, deck: Deck, position_ms: f64) {
        if let Some(engine) = self.player.opened() {
            engine.seek_ms(deck.into(), position_ms);
            self.player.start_ticker();
        }
    }

    /// Speed as a multiple of the file's own (0.5 to 2). Remembered if no
    /// engine is open yet; never opens the output.
    pub fn set_tempo(&self, deck: Deck, tempo: f32) {
        self.player.set_tempo(deck.into(), tempo);
    }

    pub fn set_master_tempo(&self, deck: Deck, on: bool) {
        self.player.set_master_tempo(deck.into(), on);
    }

    pub fn set_key_shift(&self, deck: Deck, semitones: i8) {
        self.player.set_key_shift(deck.into(), semitones);
    }

    /// Both decks now, for a front end that is starting up or has reset.
    pub fn state(&self) -> PlaybackTick {
        self.player.state().into()
    }

    /// Plays a track from `position_ms` without loading it onto a deck, pausing
    /// the decks. Blocks until the file has opened (up to ten seconds).
    pub fn preview_play(&self, track_id: String, position_ms: f64) -> Result<(), FfiError> {
        ffi("preview_play", || {
            let path = self.path_of(&track_id)?;
            self.preview.play(&self.player, &track_id, &path, position_ms)
        })
    }

    pub fn preview_stop(&self) {
        self.preview.stop();
    }

    pub fn preview_state(&self) -> PreviewState {
        self.preview.state().into()
    }
}
