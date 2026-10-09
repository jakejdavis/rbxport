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
use rbl_app::dto::LimiterDto;
use rbl_app::player::{DeckEventDto, DeckTickDto, MeterDto, MixerState, PlaybackSink, Player, TickDto};
use rbl_app::preview::{Preview, PreviewStateDto};
use rbl_app::state::AppState;
use rbl_app::track_data;
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

/// How loud the metronome clicks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MetronomeVolume {
    Small,
    Middle,
    Large,
}

/// One of the channel strip's three bands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EqBand {
    Low,
    Mid,
    High,
}

impl From<EqBand> for rbl_deck::Band {
    fn from(band: EqBand) -> Self {
        match band {
            EqBand::Low => Self::Low,
            EqBand::Mid => Self::Mid,
            EqBand::High => Self::High,
        }
    }
}

/// One deck's channel strip.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
#[allow(clippy::struct_excessive_bools, reason = "the three kill buttons")]
pub struct ChannelState {
    /// 0 to 2, 1 is unity.
    pub trim: f32,
    /// Knob positions, 0.5 at centre.
    pub low: f32,
    pub mid: f32,
    pub high: f32,
    pub kill_low: bool,
    pub kill_mid: bool,
    pub kill_high: bool,
}

/// The mixer as the engine holds it (or will, when it opens).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct MixerSnapshot {
    pub a: ChannelState,
    pub b: ChannelState,
    /// 0 is deck A alone, 1 is deck B alone, 0.5 is both.
    pub crossfade: f32,
    /// ISOLATOR rather than EQ: the bottom of each band is silence.
    pub isolator: bool,
}

fn channel_of(state: &MixerState, index: usize) -> ChannelState {
    let bands = state.bands[index];
    let kills = state.kills[index];
    ChannelState {
        trim: state.trim[index],
        low: bands[0],
        mid: bands[1],
        high: bands[2],
        kill_low: kills[0],
        kill_mid: kills[1],
        kill_high: kills[2],
    }
}

impl From<MixerState> for MixerSnapshot {
    fn from(state: MixerState) -> Self {
        Self { a: channel_of(&state, 0), b: channel_of(&state, 1), crossfade: state.crossfade, isolator: state.isolator }
    }
}

/// The master limiter. The engine clamps; what comes back is what is set.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Limiter {
    pub enabled: bool,
    /// -24 to +24 dB.
    pub input_gain_db: f32,
    /// -12 to 0 dBFS.
    pub ceiling_db: f32,
    /// 10 to 1000 ms.
    pub release_ms: f32,
}

impl From<LimiterDto> for Limiter {
    fn from(l: LimiterDto) -> Self {
        Self { enabled: l.enabled, input_gain_db: l.input_gain_db, ceiling_db: l.ceiling_db, release_ms: l.release_ms }
    }
}

impl From<Limiter> for LimiterDto {
    fn from(l: Limiter) -> Self {
        Self { enabled: l.enabled, input_gain_db: l.input_gain_db, ceiling_db: l.ceiling_db, release_ms: l.release_ms }
    }
}

/// One output the audio can go to.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
}

/// The outputs, the system's own choice among them, and the one this app was told to use.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AudioDevices {
    pub devices: Vec<AudioDevice>,
    pub default_id: Option<String>,
    pub chosen_id: Option<String>,
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
    /// Each deck's loudest sample after its channel strip, for the channel meters.
    pub deck_a_peak: f32,
    pub deck_b_peak: f32,
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
            deck_a_peak: m.deck_a_peak,
            deck_b_peak: m.deck_b_peak,
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
            self.player.loaded_tracks.lock().insert(which, track_id.clone());
            // And the grid, for the metronome. A newer load may have landed
            // while the analysis file was read; never put an old grid on new audio.
            let grid = track_data::track_beats(&self.state, &track_id).unwrap_or_default();
            if self.player.loaded_tracks.lock().get(&which) == Some(&track_id) {
                let beats: Vec<(u32, bool)> = grid.iter().map(|b| (b.time_ms, b.number == 1)).collect();
                engine.set_metronome_grid(which, &beats);
            }
            Ok(())
        })
    }

    /// Re-reads the loaded track's grid into the deck's metronome, after a grid edit
    /// or a re-analysis. A no-op when nothing is loaded or the device is not open.
    pub fn refresh_metronome_grid(&self, deck: Deck) {
        let which = rbl_deck::Deck::from(deck);
        let Some(track_id) = self.player.loaded_tracks.lock().get(&which).cloned() else { return };
        let Some(engine) = self.player.opened() else { return };
        let grid = track_data::track_beats(&self.state, &track_id).unwrap_or_default();
        if self.player.loaded_tracks.lock().get(&which) == Some(&track_id) {
            let beats: Vec<(u32, bool)> = grid.iter().map(|b| (b.time_ms, b.number == 1)).collect();
            engine.set_metronome_grid(which, &beats);
        }
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

    /// Sets a loop between two points and turns it on; a head past the out
    /// point goes back to the in point. Positions are file milliseconds.
    pub fn set_loop(&self, deck: Deck, in_ms: f64, out_ms: f64) {
        if let Some(engine) = self.player.opened() {
            engine.set_loop_ms(deck.into(), in_ms, out_ms);
            self.player.start_ticker();
        }
    }

    /// RELOOP (on: back into the loop from its in point) and EXIT (off, range kept).
    pub fn set_looping(&self, deck: Deck, on: bool) {
        if let Some(engine) = self.player.opened() {
            engine.set_looping(deck.into(), on);
            self.player.start_ticker();
        }
    }

    /// Forgets the deck's loop.
    pub fn clear_loop(&self, deck: Deck) {
        if let Some(engine) = self.player.opened() {
            engine.clear_loop(deck.into());
            self.player.start_ticker();
        }
    }

    /// Starts a drag: audio follows `scrub_to` until `scrub_end`.
    pub fn scrub_begin(&self, deck: Deck) {
        if let Some(engine) = self.player.opened() {
            engine.scrub_begin(deck.into());
            self.player.start_ticker();
        }
    }

    /// Where the pointer is now, mid-drag. Fractional milliseconds on purpose.
    pub fn scrub_to(&self, deck: Deck, position_ms: f64) {
        if let Some(engine) = self.player.opened() {
            engine.scrub_to_ms(deck.into(), position_ms);
        }
    }

    pub fn scrub_end(&self, deck: Deck) {
        if let Some(engine) = self.player.opened() {
            engine.scrub_end(deck.into());
            self.player.start_ticker();
        }
    }

    /// A click on every beat of the grid while the deck plays.
    pub fn set_metronome(&self, deck: Deck, on: bool) {
        if let Some(engine) = self.player.opened() {
            engine.set_metronome(deck.into(), on);
        }
    }

    /// Which click (1 to 3) and how loud, for both decks. Remembered if no engine is up.
    pub fn set_metronome_sound(&self, sound: u8, volume: MetronomeVolume) {
        let sound = match sound {
            1 => rbl_deck::ClickSound::One,
            3 => rbl_deck::ClickSound::Three,
            _ => rbl_deck::ClickSound::Two,
        };
        let volume = match volume {
            MetronomeVolume::Small => rbl_deck::ClickVolume::Small,
            MetronomeVolume::Middle => rbl_deck::ClickVolume::Middle,
            MetronomeVolume::Large => rbl_deck::ClickVolume::Large,
        };
        self.player.set_metronome(sound, volume);
    }

    /// Whether the deck's metronome is on.
    pub fn metronome_on(&self, deck: Deck) -> bool {
        self.player.opened().is_some_and(|engine| engine.metronome_on(deck.into()))
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

    /// Starts a deck after `delay_ms` of silence counted by the audio callback:
    /// quantized play on a synced deck, held for the master's next beat.
    pub fn play_after(&self, deck: Deck, delay_ms: f64) -> Result<(), FfiError> {
        ffi("deck_play_after", || {
            let engine = self.player.engine()?;
            // A delay is at most a beat; a negative or absurd one is zero.
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let frames = if delay_ms.is_finite() && delay_ms > 0.0 {
                (delay_ms.min(60_000.0) * f64::from(engine.sample_rate()) / 1000.0).round() as u64
            } else {
                0
            };
            engine.play_after(deck.into(), frames);
            self.player.start_ticker();
            Ok(())
        })
    }

    // MARK: Mixer, master and limiter. None of these opens the output: the values are
    // remembered and applied when the engine is built.

    /// The mixer as it stands: read from the engine when it is up, else as remembered.
    pub fn mixer(&self) -> MixerSnapshot {
        self.player.mixer().into()
    }

    /// The deck's gain, 0 to 2.
    pub fn set_channel_trim(&self, deck: Deck, trim: f32) {
        self.player.set_channel_trim(deck.into(), trim);
    }

    /// A band's knob position, 0 to 1 with 0.5 at centre.
    pub fn set_channel_band(&self, deck: Deck, band: EqBand, position: f32) {
        self.player.set_channel_band(deck.into(), band.into(), position);
    }

    pub fn set_channel_kill(&self, deck: Deck, band: EqBand, killed: bool) {
        self.player.set_channel_kill(deck.into(), band.into(), killed);
    }

    /// 0 is deck A alone, 1 is deck B alone, 0.5 is both.
    pub fn set_crossfade(&self, position: f32) {
        self.player.set_crossfade(position);
    }

    pub fn set_eq_curve(&self, isolator: bool) {
        self.player.set_eq_curve(isolator);
    }

    /// The master level as a linear gain, 0 to +2 dB.
    pub fn set_master_level(&self, level: f32) {
        self.player.set_master_level(level);
    }

    pub fn master_level(&self) -> f32 {
        self.player.master_level()
    }

    pub fn limiter(&self) -> Limiter {
        self.player.limiter().into()
    }

    /// Sets the limiter and returns what the engine's clamping made of it.
    pub fn set_limiter(&self, limiter: Limiter) -> Limiter {
        self.player.set_limiter(limiter.into()).into()
    }

    // MARK: Audio output

    /// The outputs now; read each time the settings pane opens. Opens nothing.
    pub fn audio_devices(&self) -> AudioDevices {
        let d = self.player.audio_devices();
        AudioDevices {
            devices: d.devices.into_iter().map(|x| AudioDevice { id: x.id, name: x.name }).collect(),
            default_id: d.default,
            chosen_id: d.chosen,
        }
    }

    /// Chooses an output (`None` is the system default). A live engine is dropped,
    /// and the listener hears `on_reset`: reload the decks. Returns whether it was.
    pub fn set_audio_device(&self, device: Option<String>) -> bool {
        let dropped = self.player.set_device(device);
        if dropped {
            self.player.notify_reset();
        }
        dropped
    }

    /// The sample rate and buffer size to open the output with (`None` leaves it to the
    /// device). Like a device change this drops a live engine and signals a reset.
    pub fn set_audio_config(&self, sample_rate: Option<u32>, buffer_frames: Option<u32>) -> bool {
        let dropped = self.player.set_wish(rbl_deck::StreamWish { sample_rate, buffer_frames });
        if dropped {
            self.player.notify_reset();
        }
        dropped
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
