#![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::assert_is_empty)]

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

fn loose_deck(seconds: u32) -> (Arc<rbl_ffi::Core>, Arc<rbl_ffi::Playback>, Arc<Recorder>, String, tempfile::TempDir, tempfile::TempDir) {
    std::env::set_var("RBXPORT_NULL_AUDIO", "1");
    let lib = tempfile::tempdir().unwrap();
    let core = Core::with_fixture(Arc::new(Quiet), lib.path().to_string_lossy().into_owned());
    assert_eq!(core.load_library(), LoadOutcome::Ready);
    let music = tempfile::tempdir().unwrap();
    write_wav(&music.path().join("a.wav"), seconds);
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
    let id = core.fetch_rows(view.view_id, 0, 10, vec![]).unwrap()[0].id.clone();
    let recorder = Arc::new(Recorder::default());
    let playback = core.playback(recorder.clone());
    playback.load(Deck::A, id.clone(), 1).unwrap();
    wait("the load", || recorder.events.lock().unwrap().iter().any(|e| e.load_id == 1 && e.message.is_none()));
    (core, playback, recorder, id, lib, music)
}

#[test]
fn analysis_reads_are_empty_not_errors_for_tracks_without_any() {
    let (core, _playback, _recorder, id, _lib, _music) = loose_deck(2);
    // A loose file has no library row, no analysis, no cues.
    assert!(core.track_beats(id.clone()).unwrap().is_empty());
    assert!(core.track_cues(id.clone()).unwrap().is_empty());
    assert!(core.track_phrases(id.clone()).unwrap().is_empty());
    assert!(core.track_vocals(id).unwrap().is_empty());
    // And an id that names nothing is not an error either.
    assert!(core.track_beats("999999999".into()).unwrap().is_empty());
    assert!(core.track_cues("999999999".into()).unwrap().is_empty());
}

#[test]
fn a_loop_is_set_reported_exited_reentered_and_cleared() {
    let (_core, playback, _recorder, _id, _lib, _music) = loose_deck(6);
    playback.set_loop(Deck::A, 1_000.0, 2_000.0);
    wait("the loop to show", || playback.state().a.looping);
    // The output's rate, whatever the silent sink chose.
    let rate = u64::from(playback.state().sample_rate);
    let tick = playback.state().a;
    assert_eq!((tick.loop_in_frames, tick.loop_out_frames), (rate, 2 * rate));
    // A head past the loop's end is sent back to its start.
    assert!(tick.frames >= i64::try_from(rate).unwrap());

    playback.set_looping(Deck::A, false);
    wait("exit", || !playback.state().a.looping);
    // The range is kept for RELOOP.
    assert_eq!(playback.state().a.loop_out_frames, 2 * rate);
    playback.set_looping(Deck::A, true);
    wait("reloop", || playback.state().a.looping);

    playback.clear_loop(Deck::A);
    wait("the loop to clear", || playback.state().a.loop_out_frames == 0);
    assert!(!playback.state().a.looping);
}

#[test]
fn a_loop_holds_a_playing_deck_inside_it() {
    let (_core, playback, _recorder, _id, _lib, _music) = loose_deck(6);
    playback.seek_ms(Deck::A, 500.0);
    playback.set_loop(Deck::A, 500.0, 800.0);
    playback.play(Deck::A).unwrap();
    // Real time, so give it long enough to have run past 800 ms several times.
    std::thread::sleep(Duration::from_millis(1_400));
    let frames = playback.state().a.frames;
    let rate = i64::from(playback.state().sample_rate);
    assert!((rate / 2..=rate * 8 / 10 + rate / 10).contains(&frames), "the head escaped the loop: {frames}");
    playback.pause(Deck::A);
}

#[test]
fn scrubbing_moves_the_playhead_and_stays_where_it_lands() {
    let (_core, playback, _recorder, _id, _lib, _music) = loose_deck(6);
    playback.scrub_begin(Deck::A);
    for step in 0..20 {
        playback.scrub_to(Deck::A, 1_000.0 + f64::from(step) * 50.0);
        std::thread::sleep(Duration::from_millis(5));
    }
    playback.scrub_end(Deck::A);
    wait("the scrub to land", || {
        let frames = playback.state().a.frames;
        frames > 40_000 && !playback.state().a.playing
    });
}

#[test]
fn key_shift_and_the_metronome_are_remembered_and_applied() {
    let (_core, playback, _recorder, _id, _lib, _music) = loose_deck(3);
    playback.set_key_shift(Deck::A, 3);
    wait("the key shift", || playback.state().a.key_shift == 3 || !playback.state().shifts_key);
    playback.set_key_shift(Deck::A, 0);
    wait("the key shift to reset", || playback.state().a.key_shift == 0);

    playback.set_metronome_sound(3, rbl_ffi::MetronomeVolume::Middle);
    assert!(!playback.metronome_on(Deck::A));
    playback.set_metronome(Deck::A, true);
    assert!(playback.metronome_on(Deck::A));
    playback.set_metronome(Deck::A, false);
    assert!(!playback.metronome_on(Deck::A));
}
