#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing)]

//! Playback over the bridge, on the silent sink: nothing here makes a sound.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rbl_ffi::{
    Core, Deck, DeckEvent, EventListener, FfiError, LibraryEvent, LoadOutcome, Meters, PlaybackListener, PlaybackTick,
    SearchField, SortKey, TrackFilter, TrackSource, ViewSpec,
};

struct Quiet;
impl EventListener for Quiet {
    fn on_event(&self, _event: LibraryEvent) {}
}

#[derive(Default)]
struct Recorder {
    ticks: Mutex<Vec<PlaybackTick>>,
    meters: Mutex<u32>,
    events: Mutex<Vec<DeckEvent>>,
}

impl PlaybackListener for Recorder {
    fn on_tick(&self, tick: PlaybackTick) {
        self.ticks.lock().unwrap().push(tick);
    }
    fn on_meters(&self, _meters: Meters) {
        *self.meters.lock().unwrap() += 1;
    }
    fn on_deck_event(&self, event: DeckEvent) {
        self.events.lock().unwrap().push(event);
    }
    fn on_reset(&self) {}
}

fn write_wav(path: &std::path::Path, seconds: u32) {
    let rate = 44_100_u32;
    let bytes = rate * seconds * 4;
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
    for frame in 0..rate * seconds {
        #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
        let s = ((frame as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 6_000.0) as i16;
        for _ in 0..2 {
            wav.extend_from_slice(&s.to_le_bytes());
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

#[test]
fn a_loose_file_loads_plays_ticks_and_previews_without_a_sound() {
    std::env::set_var("RBXPORT_NULL_AUDIO", "1");
    let lib = tempfile::tempdir().unwrap();
    let core = Core::with_fixture(Arc::new(Quiet), lib.path().to_string_lossy().into_owned());
    assert_eq!(core.load_library(), LoadOutcome::Ready);
    let music = tempfile::tempdir().unwrap();
    write_wav(&music.path().join("a.wav"), 4);
    write_wav(&music.path().join("b.wav"), 4);
    let view = core
        .open_view(ViewSpec {
            source: TrackSource::Folder { path: music.path().to_string_lossy().into_owned() },
            sort: SortKey::FileName,
            descending: false,
            query: String::new(),
            search_field: SearchField::All,
            filter: TrackFilter::default(),
        })
        .unwrap();
    let rows = core.fetch_rows(view.view_id, 0, 10, vec![]).unwrap();
    assert_eq!(rows.len(), 2);

    let recorder = Arc::new(Recorder::default());
    let playback = core.playback(recorder.clone());
    // Settings never open the output.
    playback.set_tempo(Deck::A, 1.04);
    playback.set_master_tempo(Deck::A, true);
    assert_eq!(playback.state().sample_rate, 0);
    assert!(matches!(playback.load(Deck::A, "nope".into(), 1), Err(FfiError::NotFound { .. })));

    playback.load(Deck::A, rows[0].id.clone(), 5).unwrap();
    wait("the load event", || recorder.events.lock().unwrap().iter().any(|e| e.load_id == 5 && e.message.is_none()));
    assert_eq!(playback.loaded_track(Deck::A), Some(rows[0].id.clone()));
    wait("the stored tempo", || (playback.state().a.tempo - 1.04).abs() < 1e-3);

    playback.play(Deck::A).unwrap();
    wait("three ticks", || recorder.ticks.lock().unwrap().len() >= 3);
    wait("the deck to advance", || playback.state().a.frames > 4_800);
    assert!(*recorder.meters.lock().unwrap() > 3);

    playback.pause(Deck::A);
    wait("the pause", || !playback.state().a.playing);
    playback.seek_ms(Deck::A, 2_000.0);
    wait("the seek", || playback.state().a.frames >= 96_000);

    playback.preview_play(rows[1].id.clone(), 1_000.0).unwrap();
    let state = playback.preview_state();
    assert_eq!(state.track_id.as_deref(), Some(rows[1].id.as_str()));
    assert!(state.playing);
    wait("the preview to move", || playback.preview_state().position_ms > 1_100.0);
    playback.preview_stop();
    wait("the preview to stop", || !playback.preview_state().playing);
}
