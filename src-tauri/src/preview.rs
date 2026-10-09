//! The browser's preview player. The behaviour, and how it was established,
//! is in `rbl_app::preview`; this is the Tauri-facing shell around it.

use std::ops::Deref;
use std::path::Path;
use std::sync::Arc;

pub use rbl_app::preview::PreviewStateDto;
use rbl_app::AppResult;
use tauri::{AppHandle, Runtime};

use crate::player::{Player, SinkOpener};

#[derive(Default)]
pub struct Preview(rbl_app::preview::Preview);

impl Deref for Preview {
    type Target = rbl_app::preview::Preview;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl Preview {
    /// A preview whose engine renders into whatever `open_sink` opens.
    pub fn with_sink(open_sink: SinkOpener) -> Self {
        Self(rbl_app::preview::Preview::with_sink(open_sink))
    }

    /// Plays `track` from `position_ms`, pausing the decks first.
    pub fn play<R: Runtime>(
        &self,
        app: &AppHandle<R>,
        decks: &Arc<Player>,
        track: &str,
        path: &Path,
        position_ms: f64,
    ) -> AppResult<()> {
        decks.attach(app);
        self.0.play(decks.core(), track, path, position_ms)
    }
}
