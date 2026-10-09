//! The playback engine, and the tick the front end reads it through.
//!
//! The engine itself is `rbl-deck` and knows nothing about any shell. This is
//! the adapter: it opens the audio device the first time a deck is given
//! something to load or play, rather than at launch, and it remembers every
//! setting so that a setter never has to open one. A library manager that holds
//! an output device for a deck nobody has touched is a library manager that
//! shows up in the system's audio list for no reason.
//!
//! Position does not come through a command. The ticker thread pushes one tick
//! ten times a second carrying both decks, and meters thirty times a second, to
//! whatever [`PlaybackSink`] is attached; the front end extrapolates between
//! ticks from the frame counter.
//!
//! Setting `RBXPORT_NULL_AUDIO=1` builds the engine on a silent sink that is
//! pulled in real time, so a deck plays, ticks and seeks exactly as it would
//! and nothing is ever audible.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use rbl_deck::{Band, Curve, Deck, DeckEvent, Engine, NullSink, Render, Sink, StreamWish};
use serde::Serialize;

use crate::dto::LimiterDto;
use crate::error::{AppError, AppResult, ErrorKind};

/// How often the meters go out. A tenth of a second is a meter that steps
/// rather than moves, and the payload is three numbers.
const METER_TICK: Duration = Duration::from_millis(33);

/// Meter ticks to a deck tick, so both come off one thread.
const TICKS_PER_DECK_TICK: u32 = 3;

/// Where the player sends what it reports. Called from the ticker thread and
/// from the engine's own threads, so implementations must be quick.
pub trait PlaybackSink: Send + Sync {
    /// Both decks, about ten times a second while anything is sounding.
    fn tick(&self, tick: &TickDto);
    /// The master's meters, about thirty times a second.
    fn meters(&self, meters: &MeterDto);
    /// A deck finished loading (`message` is `None`) or failed to.
    fn deck_event(&self, event: &DeckEventDto);
    /// The engine was dropped for a device or rate change.
    fn reset(&self);
}

/// One deck in a tick.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_excessive_bools, reason = "the deck's flags, sent together")]
pub struct DeckTickDto {
    pub frames: i64,
    pub total_frames: u64,
    /// Bumped on every load and seek, so the interface snaps its playhead
    /// rather than easing it towards a position it did not expect.
    pub generation: u32,
    pub playing: bool,
    pub loaded: bool,
    /// Identifies the load whose audio is installed. Zero means no track.
    pub load_id: u64,
    /// How fast the deck is playing, as a multiple of the file's own speed.
    pub tempo: f32,
    /// Whether the pitch is held while that speed changes.
    pub master_tempo: bool,
    /// Semitones from the track's own key.
    pub key_shift: i8,
    /// Output frames until a started deck sounds: a play held for the beat.
    pub start_in_frames: u64,
    /// The loop's in and out points, device-rate frames; both 0 for none.
    pub loop_in_frames: u64,
    pub loop_out_frames: u64,
    /// Whether the deck is inside the loop.
    pub looping: bool,
}

impl DeckTickDto {
    const EMPTY: Self = Self {
        frames: 0,
        total_frames: 0,
        generation: 0,
        playing: false,
        loaded: false,
        load_id: 0,
        tempo: 1.0,
        master_tempo: false,
        key_shift: 0,
        start_in_frames: 0,
        loop_in_frames: 0,
        loop_out_frames: 0,
        looping: false,
    };
}

/// Both decks, which is what one tick carries: about 200 bytes, well inside
/// the 1 KB event cap.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TickDto {
    pub a: DeckTickDto,
    pub b: DeckTickDto,
    pub sample_rate: u32,
    /// The loudest sample the device was given last callback, per channel, so
    /// the meter reads what can be heard rather than what is in the file.
    pub peak_left: f32,
    pub peak_right: f32,
    /// The master level, 0 to +2 dB.
    pub master: f32,
    /// How far the limiter turned the sum down since the last tick, in dB.
    pub reduction: f32,
    /// Whether this build can shift a key: the Rubber Band backend is in.
    pub shifts_key: bool,
}

impl TickDto {
    /// What to report before the engine exists: two empty decks. A deck that
    /// has never been opened is stopped at zero, which is the truth.
    #[must_use]
    pub fn silent() -> Self {
        Self {
            a: DeckTickDto::EMPTY,
            b: DeckTickDto::EMPTY,
            sample_rate: 0,
            peak_left: 0.0,
            peak_right: 0.0,
            master: 1.0,
            reduction: 0.0,
            shifts_key: Engine::shifts_key(),
        }
    }
}

/// The master's meters, on their own faster beat.
///
/// Separate from the deck tick because it is wanted three times as often and
/// is a twentieth of the size.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MeterDto {
    pub rms_left: f32,
    pub rms_right: f32,
    pub peak_left: f32,
    pub peak_right: f32,
    pub master: f32,
    /// How far the limiter turned the sum down since the last tick, in dB;
    /// 0 when it did nothing.
    pub reduction: f32,
}

/// What a deck reports outside the tick.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeckEventDto {
    pub deck: String,
    pub load_id: u64,
    pub total_frames: u64,
    pub sample_rate: u32,
    pub message: Option<String>,
}

impl DeckEventDto {
    /// The wire name a shell that names its events would use.
    #[must_use]
    pub fn name(&self) -> &'static str {
        if self.message.is_some() {
            "deck:error"
        } else {
            "deck:loaded"
        }
    }
}

/// Opens the output the engine renders into, given the render callback, the
/// device the interface chose (`None` is the system default), and the rate
/// and buffer size it asked for.
pub type SinkOpener =
    Box<dyn Fn(Render, Option<String>, StreamWish) -> rbl_deck::Result<Arc<dyn Sink>> + Send + Sync>;

/// A sink that renders in real time and throws the audio away.
///
/// `NullSink` only renders when something pulls it; the app needs the decks to
/// advance on their own, without a device.
struct SilentSink {
    inner: Arc<NullSink>,
    quit: Arc<AtomicBool>,
}

impl SilentSink {
    fn open(render: Render, rate: u32) -> Self {
        let inner = Arc::new(NullSink::new(rate, render));
        let quit = Arc::new(AtomicBool::new(false));
        let pulled = Arc::clone(&inner);
        let stop = Arc::clone(&quit);
        let spawned = std::thread::Builder::new().name("rbl-silent-audio".to_owned()).spawn(move || {
            let started = Instant::now();
            let mut done = 0_u64;
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(4));
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                let due = (started.elapsed().as_secs_f64() * f64::from(rate)) as u64;
                // Never more than a callback's worth at once, as a device
                // would not, and never a backlog after a stall.
                if due.saturating_sub(done) > u64::from(rate) {
                    done = due;
                }
                while due.saturating_sub(done) >= 256 {
                    pulled.pull(256);
                    done += 256;
                }
            }
        });
        if let Err(e) = spawned {
            tracing::error!(error = %e, "the silent audio thread could not be started");
        }
        Self { inner, quit }
    }
}

impl Drop for SilentSink {
    fn drop(&mut self) {
        self.quit.store(true, Ordering::Relaxed);
    }
}

impl Sink for SilentSink {
    fn sample_rate(&self) -> u32 {
        self.inner.sample_rate()
    }

    fn start(&self) -> rbl_deck::Result<()> {
        self.inner.start()
    }

    fn stop(&self) -> rbl_deck::Result<()> {
        self.inner.stop()
    }
}

/// An opener whose output is silent and real-time paced, for `RBXPORT_NULL_AUDIO`.
pub fn silent_opener() -> SinkOpener {
    Box::new(|render, _device, wish| {
        Ok(Arc::new(SilentSink::open(render, wish.sample_rate.unwrap_or(48_000))) as Arc<dyn Sink>)
    })
}

/// Whether the environment asks for no audio device at all.
#[must_use]
pub fn null_audio_requested() -> bool {
    std::env::var_os("RBXPORT_NULL_AUDIO").is_some_and(|v| !v.is_empty() && v != "0")
}

/// Every setting the interface has given the player, kept so that setting one
/// does not open the device, and so a rebuilt engine gets them all back.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Remembered {
    trim: [f32; 2],
    bands: [[f32; 3]; 2],
    kills: [[bool; 3]; 2],
    crossfade: f32,
    isolator: bool,
    tempo: [f32; 2],
    master_tempo: [bool; 2],
    key_shift: [i8; 2],
}

impl Default for Remembered {
    fn default() -> Self {
        Self {
            trim: [1.0; 2],
            bands: [[0.5; 3]; 2],
            kills: [[false; 3]; 2],
            crossfade: 0.5,
            isolator: false,
            tempo: [1.0; 2],
            master_tempo: [false; 2],
            key_shift: [0; 2],
        }
    }
}

const BANDS: [Band; 3] = [Band::Low, Band::Mid, Band::High];

fn band_index(band: Band) -> usize {
    BANDS.iter().position(|b| *b == band).unwrap_or(2)
}

fn deck_index(deck: Deck) -> usize {
    usize::from(deck == Deck::B)
}

/// Holds the engine, which is not built until something is loaded or played.
pub struct Player {
    pub loaded_tracks: Mutex<HashMap<Deck, String>>,
    engine: Mutex<Option<Arc<Engine>>>,
    /// How the engine's output is opened: the audio device in the app, and a
    /// sink the test pulls by hand in its tests.
    open_sink: SinkOpener,
    /// Whether a ticker is already running, so play does not start a second.
    ticking: AtomicBool,
    /// Where ticks and deck events go. Nothing is reported until one is attached.
    sink: Mutex<Option<Arc<dyn PlaybackSink>>>,
    /// The output the engine should open, as an id from `rbl_deck`.
    ///
    /// `None` is the system default. Changing it drops the engine so the next
    /// thing played opens the new device: a stream cannot be moved between
    /// devices, and rebuilding costs nothing anyone hears — the decks are
    /// reloaded from where they were.
    device: Mutex<Option<String>>,
    /// The sample rate and buffer size the interface asked for. Like the
    /// device, a change drops the engine and the next play opens with it.
    wish: Mutex<StreamWish>,
    /// The metronome's click and volume as the interface last set them.
    metronome: Mutex<(rbl_deck::ClickSound, rbl_deck::ClickVolume)>,
    /// The master limiter as the interface last set it.
    limiter: Mutex<LimiterDto>,
    master_level: Mutex<f32>,
    remembered: Mutex<Remembered>,
    /// Whether the engine's load events go to the sink. The browser's preview
    /// player is a second engine and keeps quiet: its deck A is not the
    /// player's deck A.
    emits_deck_events: bool,
}

impl Default for Player {
    /// A player on the system's audio output, or on silence when
    /// `RBXPORT_NULL_AUDIO` is set.
    fn default() -> Self {
        if null_audio_requested() {
            return Self::with_sink(silent_opener());
        }
        Self::with_sink(Box::new(|render, device, wish| {
            Ok(Arc::new(rbl_deck::CpalSink::open_with(render, device, wish)?) as Arc<dyn Sink>)
        }))
    }
}

impl Player {
    /// A player whose engine renders into whatever `open_sink` opens.
    pub fn with_sink(open_sink: SinkOpener) -> Self {
        Self {
            engine: Mutex::new(None),
            master_level: Mutex::new(1.0),
            open_sink,
            ticking: AtomicBool::new(false),
            sink: Mutex::new(None),
            loaded_tracks: Mutex::new(HashMap::new()),
            device: Mutex::new(None),
            wish: Mutex::new(StreamWish::default()),
            metronome: Mutex::new((rbl_deck::ClickSound::Two, rbl_deck::ClickVolume::Large)),
            limiter: Mutex::new(LimiterDto {
                input_gain_db: rbl_deck::DEFAULT_INPUT_GAIN_DB,
                enabled: false,
                ceiling_db: rbl_deck::DEFAULT_CEILING_DB,
                release_ms: rbl_deck::DEFAULT_RELEASE_MS,
            }),
            remembered: Mutex::new(Remembered::default()),
            emits_deck_events: true,
        }
    }

    /// The same player, with its load events kept to itself.
    #[must_use]
    pub fn quiet(mut self) -> Self {
        self.emits_deck_events = false;
        self
    }

    /// Sends ticks, meters and deck events to `sink` from now on. Applies to
    /// an engine built later; a deck event already routed keeps the old one.
    pub fn attach_sink(&self, sink: Arc<dyn PlaybackSink>) {
        *self.sink.lock() = Some(sink);
    }

    /// Attaches the sink `make` builds, unless one is attached already.
    pub fn attach_sink_if_absent(&self, make: impl FnOnce() -> Arc<dyn PlaybackSink>) {
        let mut held = self.sink.lock();
        if held.is_none() {
            *held = Some(make());
        }
    }

    fn current_sink(&self) -> Option<Arc<dyn PlaybackSink>> {
        self.sink.lock().clone()
    }

    /// Tells the sink the engine was dropped.
    pub fn notify_reset(&self) {
        if let Some(sink) = self.current_sink() {
            sink.reset();
        }
    }
}

/// The engine's limiter as the interface sees it, read back after the engine
/// clamped it.
fn limiter_of(settings: &rbl_deck::LimiterSettings) -> LimiterDto {
    LimiterDto {
        input_gain_db: settings.input_gain_db(),
        enabled: settings.enabled(),
        ceiling_db: settings.ceiling_db(),
        release_ms: settings.release_ms(),
    }
}

impl Player {
    /// The engine, opening the audio device on first use.
    ///
    /// Opening it is what makes noise possible, so it happens when a deck is
    /// asked to load or play and not before. The stream itself stays paused
    /// until something plays.
    pub fn engine(&self) -> AppResult<Arc<Engine>> {
        let mut held = self.engine.lock();
        if let Some(engine) = held.as_ref() {
            return Ok(Arc::clone(engine));
        }
        let sink = self.current_sink();
        let emits = self.emits_deck_events;
        let events: rbl_deck::EventSink = Arc::new(move |event: DeckEvent| {
            if emits {
                if let Some(sink) = &sink {
                    sink.deck_event(&deck_event_dto(&event));
                }
            }
        });
        let device = self.device.lock().clone();
        let wish = *self.wish.lock();
        let engine = Engine::with_sink(|render| (self.open_sink)(render, device, wish), &events).map_err(|e| {
            AppError::new(ErrorKind::Internal, "The audio device could not be opened.").with_detail(e.to_string())
        })?;
        // What the interface asked for, before the first callback runs.
        Self::apply_limiter(engine.limiter(), *self.limiter.lock());
        engine.master().set_gain(*self.master_level.lock());
        let (sound, volume) = *self.metronome.lock();
        engine.metronome().set_sound(sound);
        engine.metronome().set_volume(volume);
        Self::apply_remembered(&engine, &self.remembered.lock());
        let engine = Arc::new(engine);
        *held = Some(Arc::clone(&engine));
        Ok(engine)
    }

    fn apply_remembered(engine: &Engine, saved: &Remembered) {
        for (index, deck) in [Deck::A, Deck::B].into_iter().enumerate() {
            engine.set_tempo(deck, saved.tempo[index]);
            engine.set_master_tempo(deck, saved.master_tempo[index]);
            engine.set_key_shift(deck, saved.key_shift[index]);
            if let Some(channel) = engine.mixer().channels.get(index) {
                channel.set_trim(saved.trim[index]);
                for (b, band) in BANDS.into_iter().enumerate() {
                    channel.set_band(band, saved.bands[index][b]);
                    channel.set_kill(band, saved.kills[index][b]);
                }
            }
        }
        engine.mixer().set_crossfade(saved.crossfade);
        engine.mixer().set_curve(if saved.isolator { Curve::Isolator } else { Curve::Eq });
    }

    /// Retain the level when an output-device change rebuilds the engine.
    /// Never opens the device.
    pub fn set_master_level(&self, level: f32) {
        let safe = if level.is_finite() { level.clamp(0.0, rbl_deck::MAX_MASTER_GAIN) } else { 1.0 };
        *self.master_level.lock() = safe;
        if let Some(engine) = self.opened() {
            engine.master().set_gain(safe);
        }
    }

    /// How fast a deck plays, as a multiple of the file's speed. Remembered,
    /// and applied now if the engine is up.
    pub fn set_tempo(&self, deck: Deck, tempo: f32) {
        self.remembered.lock().tempo[deck_index(deck)] = tempo;
        if let Some(engine) = self.opened() {
            engine.set_tempo(deck, tempo);
        }
    }

    pub fn set_master_tempo(&self, deck: Deck, on: bool) {
        self.remembered.lock().master_tempo[deck_index(deck)] = on;
        if let Some(engine) = self.opened() {
            engine.set_master_tempo(deck, on);
        }
    }

    pub fn set_key_shift(&self, deck: Deck, semitones: i8) {
        self.remembered.lock().key_shift[deck_index(deck)] = semitones;
        if let Some(engine) = self.opened() {
            engine.set_key_shift(deck, semitones);
        }
    }

    /// The tempo last set for a deck, whether or not an engine exists.
    pub fn tempo(&self, deck: Deck) -> f32 {
        self.remembered.lock().tempo[deck_index(deck)]
    }

    pub fn set_channel_trim(&self, deck: Deck, trim: f32) {
        self.remembered.lock().trim[deck_index(deck)] = trim;
        if let Some(engine) = self.opened() {
            if let Some(channel) = engine.mixer().channels.get(deck_index(deck)) {
                channel.set_trim(trim);
            }
        }
    }

    pub fn set_channel_band(&self, deck: Deck, band: Band, position: f32) {
        self.remembered.lock().bands[deck_index(deck)][band_index(band)] = position;
        if let Some(engine) = self.opened() {
            if let Some(channel) = engine.mixer().channels.get(deck_index(deck)) {
                channel.set_band(band, position);
            }
        }
    }

    pub fn set_channel_kill(&self, deck: Deck, band: Band, killed: bool) {
        self.remembered.lock().kills[deck_index(deck)][band_index(band)] = killed;
        if let Some(engine) = self.opened() {
            if let Some(channel) = engine.mixer().channels.get(deck_index(deck)) {
                channel.set_kill(band, killed);
            }
        }
    }

    pub fn set_crossfade(&self, position: f32) {
        self.remembered.lock().crossfade = position;
        if let Some(engine) = self.opened() {
            engine.mixer().set_crossfade(position);
        }
    }

    pub fn set_eq_curve(&self, isolator: bool) {
        self.remembered.lock().isolator = isolator;
        if let Some(engine) = self.opened() {
            engine.mixer().set_curve(if isolator { Curve::Isolator } else { Curve::Eq });
        }
    }

    fn apply_limiter(settings: &rbl_deck::LimiterSettings, wanted: LimiterDto) {
        settings.set_input_gain_db(wanted.input_gain_db);
        settings.set_enabled(wanted.enabled);
        settings.set_ceiling_db(wanted.ceiling_db);
        settings.set_release_ms(wanted.release_ms);
    }

    /// Sets the master limiter, now if the engine is up and at its build if
    /// not, and returns what was actually set — the engine clamps.
    pub fn set_limiter(&self, wanted: LimiterDto) -> LimiterDto {
        // Through a throwaway settings so the clamping is the engine's own,
        // whether or not there is an engine yet.
        let clamped = rbl_deck::LimiterSettings::default();
        Self::apply_limiter(&clamped, wanted);
        let safe = limiter_of(&clamped);
        *self.limiter.lock() = safe;
        if let Some(engine) = self.opened() {
            Self::apply_limiter(engine.limiter(), safe);
        }
        safe
    }

    pub fn limiter(&self) -> LimiterDto {
        *self.limiter.lock()
    }

    /// Which output to open. `None` is the system default.
    ///
    /// Takes effect on the next thing played: the engine is dropped here and
    /// rebuilt then, because a running stream belongs to the device it was
    /// opened on.
    pub fn set_device(&self, device: Option<String>) -> bool {
        let mut current = self.device.lock();
        if *current == device {
            return false;
        }
        *current = device;
        drop(current);
        // Dropped rather than replaced: whatever is playing is on the old
        // device, and the next play opens the new one.
        self.engine.lock().take().is_some()
    }

    pub fn device(&self) -> Option<String> {
        self.device.lock().clone()
    }

    /// The rate and buffer size to open the device with. A change drops the
    /// engine, as a device change does: a stream has the rate it was opened at.
    pub fn set_wish(&self, wish: StreamWish) -> bool {
        let mut current = self.wish.lock();
        if *current == wish {
            return false;
        }
        *current = wish;
        drop(current);
        self.engine.lock().take().is_some()
    }

    pub fn wish(&self) -> StreamWish {
        *self.wish.lock()
    }

    /// The metronome's click and volume, now if the engine is up and at its
    /// build if not.
    pub fn set_metronome(&self, sound: rbl_deck::ClickSound, volume: rbl_deck::ClickVolume) {
        *self.metronome.lock() = (sound, volume);
        if let Some(engine) = self.opened() {
            engine.metronome().set_sound(sound);
            engine.metronome().set_volume(volume);
        }
    }

    /// Already-built engine only — for a tick, which must not open a device.
    pub fn opened(&self) -> Option<Arc<Engine>> {
        self.engine.lock().clone()
    }

    pub fn ticking(&self) -> &AtomicBool {
        &self.ticking
    }

    /// Both decks now, for a front end that is starting up or has reset.
    pub fn state(&self) -> TickDto {
        self.opened().map_or_else(TickDto::silent, |engine| tick_of(&engine.snapshot(), engine.master()))
    }

    /// Starts the ticker if one is not already running.
    ///
    /// It stops after a short tail when neither deck is playing nor scrubbing.
    /// Playing or beginning a drag starts it again.
    pub fn start_ticker(self: &Arc<Self>) {
        if self.ticking.swap(true, Ordering::SeqCst) {
            return;
        }
        let player = Arc::clone(self);
        // Its own thread rather than an async runtime: this is a fixed beat
        // that ends when playback does, and it must not share a worker with a
        // call that is reading the database.
        let spawned = std::thread::Builder::new().name("rbl-deck-tick".to_owned()).spawn(move || {
            player.run_ticker();
        });
        if let Err(e) = spawned {
            tracing::error!(error = %e, "the deck ticker could not be started");
            self.ticking.store(false, Ordering::SeqCst);
        }
    }

    fn run_ticker(self: &Arc<Self>) {
        let mut since_deck_tick = 0_u32;
        let mut silent_ticks = 0_u32;
        loop {
            std::thread::sleep(METER_TICK);
            let Some(engine) = self.opened() else { break };
            let sink = self.current_sink();
            let master = engine.master();
            let (peak_left, peak_right) = master.peaks();
            let reduction = master.reduction_db();
            let (rms_left, rms_right) = master.rms();
            if let Some(sink) = &sink {
                sink.meters(&MeterDto {
                    peak_left,
                    peak_right,
                    rms_left,
                    rms_right,
                    master: master.gain(),
                    reduction,
                });
            }

            since_deck_tick += 1;
            if since_deck_tick < TICKS_PER_DECK_TICK {
                continue;
            }
            since_deck_tick = 0;
            let snapshot = engine.snapshot();
            // The peaks were taken and cleared above, so the deck tick carries
            // what this pass read rather than an empty meter.
            let mut tick = tick_of(&snapshot, master);
            tick.peak_left = peak_left;
            tick.peak_right = peak_right;
            tick.reduction = reduction;
            if let Some(sink) = &sink {
                sink.tick(&tick);
            }
            if engine.any_sounding() {
                silent_ticks = 0;
            } else {
                // Publish the ~500 ms tail after playback stops.
                silent_ticks += 1;
                if silent_ticks >= 5 {
                    break;
                }
            }
        }
        self.ticking.store(false, Ordering::SeqCst);
        // A play or scrub can start between the idle check and releasing the
        // ticker flag. Its start request saw us still running; hand it off now.
        if self.opened().is_some_and(|engine| engine.any_sounding()) {
            self.start_ticker();
        }
    }
}

fn deck_event_dto(event: &DeckEvent) -> DeckEventDto {
    match event {
        DeckEvent::Loaded { deck, load_id, total_frames, sample_rate } => DeckEventDto {
            deck: deck.name().to_owned(),
            load_id: *load_id,
            total_frames: *total_frames,
            sample_rate: *sample_rate,
            message: None,
        },
        DeckEvent::Error { deck, load_id, message } => DeckEventDto {
            deck: deck.name().to_owned(),
            load_id: *load_id,
            total_frames: 0,
            sample_rate: 0,
            message: Some(message.clone()),
        },
    }
}

pub fn tick_of(snapshot: &rbl_deck::Snapshot, master: &rbl_deck::Master) -> TickDto {
    let deck = |s: &rbl_deck::DeckSnapshot| DeckTickDto {
        frames: if s.pre_roll_frames > 0 {
            -i64::try_from(s.pre_roll_frames).unwrap_or(i64::MAX)
        } else {
            i64::try_from(s.position_frames).unwrap_or(i64::MAX)
        },
        total_frames: s.total_frames,
        generation: s.generation,
        playing: s.playing,
        loaded: s.loaded,
        load_id: s.load_id,
        tempo: s.tempo,
        master_tempo: s.master_tempo,
        key_shift: s.key_shift,
        start_in_frames: s.start_in_frames,
        loop_in_frames: s.loop_in_frames,
        loop_out_frames: s.loop_out_frames,
        looping: s.looping,
    };
    let (peak_left, peak_right) = master.peaks();
    TickDto {
        a: deck(&snapshot.a),
        b: deck(&snapshot.b),
        sample_rate: snapshot.sample_rate,
        peak_left,
        peak_right,
        master: master.gain(),
        reduction: master.reduction_db(),
        shifts_key: Engine::shifts_key(),
    }
}

/// Which deck a command names. Unknown names are deck A rather than an error:
/// the interface only ever sends what it was given in a tick.
pub fn deck_of(name: &str) -> Deck {
    match name {
        "b" | "B" => Deck::B,
        _ => Deck::A,
    }
}

/// Which band a name means, defaulting to the one a typo cannot silence.
pub fn band_of(name: &str) -> Band {
    match name {
        "low" => Band::Low,
        "mid" => Band::Mid,
        _ => Band::High,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
#[allow(clippy::float_cmp, reason = "the clamp's bounds are exact constants, and that is the assertion")]
mod tests {
    use super::*;
    use crate::preview::Preview;

    /// Records everything the player reports.
    #[derive(Default)]
    struct Recorder {
        ticks: Mutex<Vec<TickDto>>,
        meters: Mutex<u32>,
        events: Mutex<Vec<DeckEventDto>>,
        resets: Mutex<u32>,
    }

    impl PlaybackSink for Recorder {
        fn tick(&self, tick: &TickDto) {
            self.ticks.lock().push(*tick);
        }
        fn meters(&self, _meters: &MeterDto) {
            *self.meters.lock() += 1;
        }
        fn deck_event(&self, event: &DeckEventDto) {
            self.events.lock().push(event.clone());
        }
        fn reset(&self) {
            *self.resets.lock() += 1;
        }
    }

    /// A four second stereo tone, 44.1 kHz.
    pub(crate) fn write_wav(path: &std::path::Path, seconds: u32) {
        let rate = 44_100_u32;
        let frames = rate * seconds;
        let bytes = frames * 4;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + bytes).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&2_u16.to_le_bytes());
        wav.extend_from_slice(&rate.to_le_bytes());
        wav.extend_from_slice(&(rate * 4).to_le_bytes());
        wav.extend_from_slice(&4_u16.to_le_bytes());
        wav.extend_from_slice(&16_u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&bytes.to_le_bytes());
        for frame in 0..frames {
            #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
            let sample = ((frame as f32 * 330.0 * std::f32::consts::TAU / rate as f32).sin() * 8_000.0) as i16;
            for _ in 0..2 {
                wav.extend_from_slice(&sample.to_le_bytes());
            }
        }
        std::fs::write(path, wav).unwrap();
    }

    fn wait(what: &str, mut done: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(8);
        while !done() {
            assert!(Instant::now() < deadline, "gave up waiting for {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn silent_player() -> (Arc<Player>, Arc<Recorder>) {
        let player = Arc::new(Player::with_sink(silent_opener()));
        let recorder = Arc::new(Recorder::default());
        player.attach_sink(Arc::clone(&recorder) as Arc<dyn PlaybackSink>);
        (player, recorder)
    }

    fn load(player: &Arc<Player>, deck: Deck, path: &std::path::Path, id: u64) {
        let engine = player.engine().unwrap();
        engine.load_as(deck, path, id);
        wait("the load", || {
            let s = engine.snapshot();
            let d = if deck == Deck::A { s.a } else { s.b };
            d.loaded && d.load_id == id
        });
    }

    #[test]
    fn a_deck_name_maps_to_a_deck_and_never_fails() {
        assert_eq!(deck_of("a"), Deck::A);
        assert_eq!(deck_of("b"), Deck::B);
        assert_eq!(deck_of("B"), Deck::B);
        assert_eq!(deck_of("nonsense"), Deck::A);
    }

    #[test]
    fn a_tick_before_the_engine_exists_is_two_stopped_decks() {
        let tick = TickDto::silent();
        assert_eq!(tick.a.frames, 0);
        assert!(!tick.a.playing);
        assert!(!tick.b.loaded);
        assert_eq!(tick.sample_rate, 0);
    }

    #[test]
    fn a_tick_is_small_enough_for_the_event_cap() {
        let json = serde_json::to_string(&TickDto::silent()).unwrap();
        assert!(json.len() < 1_024, "a tick was {} bytes", json.len());
    }

    #[test]
    fn set_limiter_returns_what_the_engine_would_clamp_to() {
        let player = Player::with_sink(silent_opener());
        let set = player.set_limiter(LimiterDto { input_gain_db: 6.0, enabled: false, ceiling_db: 3.0, release_ms: 5.0 });
        assert_eq!(set.ceiling_db, 0.0);
        assert_eq!(set.release_ms, 10.0);
    }

    #[test]
    fn setting_mixer_and_tempo_values_does_not_open_the_device() {
        let opened = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&opened);
        let player = Player::with_sink(Box::new(move |render, _, _| {
            flag.store(true, Ordering::SeqCst);
            Ok(Arc::new(NullSink::new(44_100, render)) as Arc<dyn Sink>)
        }));
        player.set_master_level(0.5);
        player.set_tempo(Deck::A, 1.08);
        player.set_master_tempo(Deck::A, true);
        player.set_key_shift(Deck::B, 2);
        player.set_channel_trim(Deck::A, 0.7);
        player.set_channel_band(Deck::B, Band::Mid, 0.2);
        player.set_channel_kill(Deck::A, Band::Low, true);
        player.set_crossfade(0.9);
        player.set_eq_curve(true);
        assert!(!opened.load(Ordering::SeqCst), "a setter opened the audio device");
        assert!(player.opened().is_none());
        assert_eq!(player.tempo(Deck::A), 1.08);

        // They land when the engine is built.
        let engine = player.engine().unwrap();
        assert!(opened.load(Ordering::SeqCst));
        assert_eq!(engine.master().gain(), 0.5);
        assert_eq!(engine.mixer().crossfade(), 0.9);
        assert_eq!(engine.mixer().channels[0].trim(), 0.7);
        assert_eq!(engine.mixer().channels[1].band(Band::Mid), 0.2);
        wait("the remembered tempo to land", || (engine.snapshot().a.tempo - 1.08).abs() < 1e-6);
        assert!(engine.snapshot().a.master_tempo);
    }

    #[test]
    fn a_deck_loads_plays_pauses_and_seeks_on_the_silent_sink() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("tone.wav");
        write_wav(&wav, 4);
        let (player, recorder) = silent_player();
        load(&player, Deck::A, &wav, 7);
        assert_eq!(recorder.events.lock().last().map(|e| (e.deck.clone(), e.load_id)), Some(("a".to_owned(), 7)));
        let engine = player.engine().unwrap();
        let loaded = engine.snapshot().a;
        assert!(loaded.total_frames > 0);
        assert!(!loaded.playing);

        engine.play(Deck::A);
        player.start_ticker();
        wait("the deck to move", || engine.snapshot().a.position_frames > 4_410);
        assert!(engine.snapshot().a.playing);
        engine.pause(Deck::A);
        wait("the deck to stop", || !engine.snapshot().a.playing);

        engine.seek_ms(Deck::A, 2_000.0);
        wait("the seek", || {
            let p = engine.snapshot().a.position_frames;
            (96_000..97_000).contains(&p)
        });

        player.set_tempo(Deck::A, 1.1);
        player.set_master_tempo(Deck::A, true);
        wait("the tempo", || (engine.snapshot().a.tempo - 1.1).abs() < 1e-6);
        assert!(engine.snapshot().a.master_tempo);
    }

    #[test]
    fn the_ticker_reports_ticks_and_meters_then_stops() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("tone.wav");
        write_wav(&wav, 4);
        let (player, recorder) = silent_player();
        load(&player, Deck::A, &wav, 1);
        let engine = player.engine().unwrap();
        engine.play(Deck::A);
        player.start_ticker();
        wait("three ticks", || recorder.ticks.lock().len() >= 3);
        assert!(*recorder.meters.lock() >= 6, "meters come three times as often");
        {
            let ticks = recorder.ticks.lock();
            assert!(ticks.iter().any(|t| t.a.playing));
            assert!(ticks.last().unwrap().a.frames > ticks.first().unwrap().a.frames);
            assert_eq!(ticks.last().unwrap().sample_rate, 48_000);
        }
        engine.pause(Deck::A);
        // The ticker runs out its tail and lets go.
        wait("the ticker to stop", || !player.ticking().load(Ordering::SeqCst));
        assert!(!recorder.ticks.lock().last().unwrap().a.playing, "the last tick reports the stop");
    }

    #[test]
    fn a_preview_plays_pauses_the_decks_and_stops() {
        let dir = tempfile::tempdir().unwrap();
        let deck_wav = dir.path().join("deck.wav");
        let preview_wav = dir.path().join("preview.wav");
        write_wav(&deck_wav, 4);
        write_wav(&preview_wav, 4);
        let (player, _recorder) = silent_player();
        load(&player, Deck::A, &deck_wav, 1);
        let engine = player.engine().unwrap();
        engine.play(Deck::A);
        wait("deck A to play", || engine.snapshot().a.playing);

        let preview = Preview::with_sink(silent_opener());
        assert_eq!(preview.state().track, None);
        preview.play(&player, "42", &preview_wav, 1_000.0).unwrap();
        assert!(!engine.snapshot().a.playing, "a preview pauses the decks");
        let state = preview.state();
        assert_eq!(state.track.as_deref(), Some("42"));
        assert!(state.playing);
        wait("the preview to move past the click", || preview.state().position_ms > 1_100.0);
        assert!(preview.state().duration_ms > 3_900.0);

        preview.stop();
        wait("the preview to stop", || !preview.state().playing);

        let err = preview.play(&player, "43", &dir.path().join("missing.wav"), 0.0).unwrap_err();
        assert_eq!(err.kind, ErrorKind::NotFound);
    }
}
