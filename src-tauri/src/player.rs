//! The playback engine for the webview: `rbl-app`'s player with Tauri events
//! as its sink.
//!
//! Everything that is not about Tauri lives in `rbl_app::player`; this file
//! only attaches the sink that turns ticks, meters and deck events into
//! `deck:*` events, and keeps the old `engine(&app)` / `start_ticker(&app)`
//! call shape the commands use.

use std::ops::Deref;
use std::sync::Arc;

use rbl_app::player::{DeckEventDto, MeterDto, PlaybackSink};
pub use rbl_app::player::{band_of, deck_of, tick_of, DeckTickDto, SinkOpener, TickDto};
use rbl_app::AppResult;
use rbl_deck::Engine;
use tauri::{AppHandle, Emitter, Manager, Runtime};

/// Emits what the player reports as Tauri events.
struct TauriSink<R: Runtime>(AppHandle<R>);

impl<R: Runtime> PlaybackSink for TauriSink<R> {
    fn tick(&self, tick: &TickDto) {
        if let Err(e) = self.0.emit("deck:tick", tick) {
            tracing::warn!(error = %e, "a deck tick did not reach the interface");
        }
    }

    fn meters(&self, meters: &MeterDto) {
        if let Err(e) = self.0.emit("deck:meters", meters) {
            tracing::warn!(error = %e, "a meter tick did not reach the interface");
        }
    }

    fn deck_event(&self, event: &DeckEventDto) {
        if let Err(e) = self.0.emit(event.name(), event) {
            tracing::warn!(error = %e, "a deck event did not reach the interface");
        }
    }

    fn reset(&self) {
        let _ = self.0.emit("deck:reset", ());
    }
}

/// The shared player, with the Tauri-flavoured way in.
pub struct Player(Arc<rbl_app::player::Player>);

impl Default for Player {
    fn default() -> Self {
        Self(Arc::new(rbl_app::player::Player::default()))
    }
}

impl Deref for Player {
    type Target = rbl_app::player::Player;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl Player {
    /// A player whose engine renders into whatever `open_sink` opens.
    pub fn with_sink(open_sink: SinkOpener) -> Self {
        Self(Arc::new(rbl_app::player::Player::with_sink(open_sink)))
    }

    /// The core player, shared.
    pub fn core(&self) -> &Arc<rbl_app::player::Player> {
        &self.0
    }

    /// Routes the player's reports to this app's webview, once.
    pub fn attach<R: Runtime>(&self, app: &AppHandle<R>) {
        self.0.attach_sink_if_absent(|| Arc::new(TauriSink(app.clone())));
    }

    /// The engine, opening the audio device on first use.
    pub fn engine<R: Runtime>(&self, app: &AppHandle<R>) -> AppResult<Arc<Engine>> {
        self.attach(app);
        self.0.engine()
    }
}

/// Starts the ticker if one is not already running.
pub fn start_ticker<R: Runtime>(app: &AppHandle<R>) {
    let player = app.state::<Arc<Player>>();
    player.attach(app);
    player.0.start_ticker();
}
