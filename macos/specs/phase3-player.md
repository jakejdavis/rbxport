# Phase 3 — player spec

## Orchestrator decisions (override the findings below where they conflict)
- **Architecture:** plan D+E from §10 — move Player/Preview/ticker/DTOs into `rbl-app` (new `player`/`preview`
  modules, rbl-deck dependency with default features) behind a playback sink trait; src-tauri keeps thin wrappers
  and must keep working. Expose a `Playback` UniFFI object + `PlaybackListener` callback interface from rbl-ffi.
  Keep the Rust ticker (10 Hz ticks, 30 Hz meters) pushing to Swift; Swift interpolates the playhead per display
  frame (CADisplayLink / TimelineView(.animation)) from the last tick + tempo, like src/lib/clock.ts.
- **Silent verification:** the app honours `RBXPORT_NULL_AUDIO=1` by building the engine on rbl_deck's NullSink.
  Agents verifying playback MUST launch with it set. Never play audible sound.
- **Slices:** 3a = backend move + FFI + deck model + single-deck transport (play/pause/CDJ cue), track info,
  time, tempo slider/range/master tempo, overview waveform, load from table (double-click/Return/menu),
  click-to-preview in the browser's Preview column. 3b = detail waveform (zoom, beat grid, cue markers, scrub),
  hot cues A–H & memory cues (jump only), loops (in/out/auto sizes, toggle), beat jump, key shift, quantize,
  metronome, VU meters, player keyboard shortcuts. 3c = layouts (one/two/simple/browser, ⌘7–⌘0), dual decks,
  DUAL control, mixer strip, master level/limiter, audio device & buffer settings.
- **Writes (cue/grid editing, grid_lock, record_play) are Phase 4**, through the Phase 4 write gate.
- **Fix rather than replicate:** §12 #3 (draw the beat grid with the PQTZ offset applied consistently),
  #4 (read mixer state back instead of resetting crossfade), #5 (setting mixer/tempo values must not open the
  audio device; store them and apply when the engine opens), #9 (tempo ranges are 6/10/16/wide as coded).
  Replicate the rest unless trivially wrong.

RBXPORT PLAYER (PHASE 3) FUNCTIONAL SPEC. Read-only exploration of /Users/jakedavis/Projects/rbxport. Nothing was written or run.

SCOPE AND GAPS
- Read in full: Player.tsx, DualDeck.tsx, MixerStrip.tsx, WaveformDetail.tsx, VocalStrip.tsx, lib/player.ts, lib/clock.ts, lib/sync.ts, lib/layout.ts, store/usePlayback.ts, store/usePreview.ts, store/useMaster.ts, store/useLimiter.ts, canvas/waveform.ts, the hooks useHotCues/useMemoryCues/useCueWriter/useGridEditor/useTrackGrid/useTrackCues/useHoldRepeat, src-tauri player.rs, preview.rs, grid.rs (app half), cues.rs, the deck block of commands.rs, and rbl-app media.rs.
- Only skimmed: DeckInfo, JumpMenu, SimplePlayer, lib/cues.ts, lib/gridEdit.ts, the rbl-deck DSP files (limiter, scrub, metronome, mixer internals, stretch).
- TempoField.tsx (231 LOC) is dead code: nothing imports it. Only its CSS module is used.
- Absolute root: /Users/jakedavis/Projects/rbxport. Bullet refs below are basename:line.

=====================================================================
1. LAYOUTS
Files: /Users/jakedavis/Projects/rbxport/src/lib/layout.ts (44), src/views/topbar/LayoutMenu.tsx (99), src/app/App.tsx (2646; render 2240-2360, state 205-345), src/lib/session.ts (KEY line 216)
- Dropdown labels and ids (layout.ts:11-16): "1 PLAYER" one, "2 PLAYER" two, "SIMPLE PLAYER" simple, "FULL BROWSER" browser. Menu commands layout-* (App.tsx:1760). Shortcuts Cmd+7/8/9/0.
- deckCount: browser=0, two=2, else 1 (layout.ts:19-23). isFullDeck is false only for simple (layout.ts:32-34).
- one: deck A only, full Player (transport column, overview, phrase bar, detail, 8-pad row, side panel). No mixer. Zoom +/- cluster is drawn by the deck. Deck B is unmounted, but the engine keeps playing.
- two: two Player instances, A and B. One shared transport rail (App.tsx:2251-2300): A's transport is portalled into the top slot, B's into the bottom slot. Centre DUAL CONTROL button (aria "Dual control") between them. MixerStrip. Shell-level DualZoom over the seam. Deck B is flipped (bottom-up).
- simple: SimplePlayer for deck A only (PLAY ring, sleeve, readouts over an overview with cue badges, rating). No detail, no transport rail, no cue list. The engine and keys are still owned by Player.tsx.
- browser: no deck drawn, no gutter. Decks stay alive in the engine.
- Layout is not a zoom. The browser is the same in all layouts.
- Loading deck B in one-deck layouts is refused (App.tsx:2039).
- Persisted in localStorage "rbl.session" (session.ts): layout (default "one"), waveformZoom {a,b} (default 12 bars each), dualControl (default false), trafficLight. Track loads are never persisted.
- DUAL CONTROL (App.tsx:312-335): on, the shell holds one bars value and one jump size, handed to both decks via setLinkedZoom (sets a and b). Off, each deck keeps its own zoom. The wheel on either waveform moves both when linked.
- Dual deck body (Player.tsx dual branch, DualDeck.tsx): no 8-pad row (Player.tsx:2116 hides pads when dual). Instead a title row (sleeve, title, artist, time readouts, BPM toggle, KEY SYNC (disabled), BEAT SYNC, key shift, MASTER). Then an overview across the full width, a phrase bar, a control row (grid shift ◂ / MARK / ▸, MEMORY store, AU|MA chips, loop-length stub, loop IN/OUT stubs (disabled, "Loops are not built yet"), Q), then the detail. The side cue list stays (grid column 2). So hot cues and memory calls are only reachable via the side list and keys. Loop controls are not reachable by mouse in dual.
- Deck B's dual rows are reordered by CSS (Player.module.css:222-234). Its detail is "overlaid" from the seam (half="overlaid", Player.tsx:2082).
- DualDeck.tsx comments are stale: they say key shift and loops are not built. Key shift is wired (KeyShift is passed in dual head, Player.tsx:1940-1941). Only KEY SYNC is disabled.

=====================================================================
2. DECK UI (Player.tsx 2582; Player.module.css 1298)
Files also: DualDeck.tsx 243, DualDeck.module.css 358, SimplePlayer.tsx 218, DeckInfo.tsx 62, KeyShift.tsx 25, TempoSlider.tsx 73, TempoToggle.tsx 77, TimeReadouts.tsx 30, JumpMenu.tsx 92, CueColorMenu.tsx 56, useHotCues.ts 87, useMemoryCues.ts 128, useCueWriter.ts 59, useGridEditor.ts 145, useTrackGrid.ts 86, useTrackCues.ts 80, useHoldRepeat.ts 70.

TRANSPORT / CDJ CUE (lib/player.ts:591-647; Player.tsx:1100-1127, 1761-1764)
- PLAY button and Space toggle play/pause. Button label "Play"/"Pause".
- CUE is held, not clicked. pointerdown runs holdCue; pointerup, pointercancel, leave, or window blur runs dropCue. Key "c" runs holdCue on non-repeat keydown and dropCue on keyup.
- pressCue rules:
  - Playing: seek to cue, then pause.
  - Paused and within 0.02 s of cue (CUE_TOLERANCE): play while held. Release seeks back and pauses (releaseCue).
  - Paused elsewhere: set cue point at position. With Q on, snap to nearest beat of quantizeGrid, and move the head there too.
- Cue point starts at the first memory cue (or 0). Settled once per track load (useTrackCues onLoaded; Player.tsx:816-819).
- Click on waveform (only if View > Click on the waveform, default true): stopped deck plays; playing deck sets cue point at head and pauses (Player.tsx:1347-1353). A drag that moves more than 3 px is a drag, not a click (CLICK_SLOP_PX).
- BEAT SYNC lit plus Q on: a stopped deck first puts its playhead on its own nearest beat, then calls playAfter(beatWait) so it lands on the master's next beat (Player.tsx:1272-1289).
- Loading a track while PLAY is engaged starts it when ready. Loading while stopped cues it (usePlayback.ts:497-503).

TRACK INFO
- Title and artist (one-deck: a head row; dual: DualHead).
- Elapsed and remaining: TimeReadouts (TimeReadouts.tsx). Remaining = floor(total*10) - tenths, printed "-MM:SS.t", elapsed "MM:SS.t". Both use file time, not tempo-adjusted. Minutes are padded to 2 digits (lib/player.ts splitTime, 292-302).
- Bar readout on the detail (beatCountText, lib/player.ts:742-780, mode from View > Beat Count Display):
  - position: "B.b Bars" from the grid (1.1, 12.3, ...). Before bar 1 it can be negative (e.g. -1.4).
  - toMemoryBars: "-x.y Bars" to the next memory cue at or after playhead.
  - toMemoryBeats: "-nBeats".
  - Nothing is shown with no cue ahead.
- Key: KeyShift (←, key label, →). Label is transposeKey(musicalKey, shift) from lib/camelot. Clamp is ±12 (usePlayback setKeyShift 758). Click the key to reset to 0. Disabled when !shiftsKey (a build without Rubber Band). A "+n" caption shows when shift ≠ 0.
- BPM readout: TempoToggle. Click (after a 250 ms double-click guard) toggles the tempo slider (pref view.tempoSlider, default false). Double-click opens an input. Input is valid only if it is within 0.5–2× the file BPM. Commit calls setDisplayedBpm, which sets tempo = bpm*100/bpmX100, and drops SYNC.

TEMPO
- Slider (TempoSlider.tsx): vertical fader. Range button cycles ±6 → ±10 → ±16 → WIDE (TEMPO_RANGES, lib/player.ts:816-817). WIDE is −50%/+100%. Note the doc comment at lib/player.ts:810 says ±20; code says 16. Stale or wrong.
- MASTER TEMPO button toggles deckMasterTempo.
- RESET: first press unlocks (resetLocked starts true), second press sets tempo 1 and drops SYNC. Disabled while synced.
- Fader: pointer maps Y to tempo via faderToTempo. Arrow keys step 0.001. Home resets to 1. A floating % readout follows the cursor.
- Keyboard F6 and F7 (bpmDown/bpmUp) step ±0.001, clamped to [MIN_TEMPO=0.5, MAX_TEMPO=2] (Player.tsx:1561-1567).
- Step size is TEMPO_STEP = 0.001 (usePlayback.ts:727). Clamp in setTempo is [0.5, 2] (usePlayback.ts:732).
- Displayed BPM = round(bpmX100 * tempo). Playing BPM reported to shell for sync (Player.tsx:1383-1386).

SYNC / MASTER (lib/sync.ts; Player.tsx 1389-1441; App.tsx 215-260)
- Only in two-deck layouts. App holds syncMaster ('a' default), per-deck synced flag, playingBpm per deck.
- MASTER (chip) picks the master. Only one.
- BEAT SYNC (per deck, toggles follow): pressing when not synced runs matchLeader (tempoFor + beatNudgeFor/nudgeFor), then flips the flag. While lit, a follower re-matches tempo on any change in master BPM (Player.tsx:1424-1432). Bar is matched once on press.
- tempoFor (sync.ts:58-72): ratio = leader.bpm*leader.tempo / follower.bpm. With doubleHalf (default on), the nearest of ratio, 2×, ½× wins. Clamped [0.5, 2]. Returns 1 when either BPM is missing.
- nudgeFor: bar-level offset, wrapped to half a bar. beatNudgeFor: beat-level. Syncs use grid bars via barAt (falls back to BPM).
- syncType 'bpm' sets nudge to 0 (tempo only). Prefs: advanced.syncType (default "beat"), advanced.syncDoubleHalf (default true).

HOT CUES (useHotCues.ts)
- 8 pads A–H. Empty pad press: set at playhead (quantised to Q grid) with addCue(track, {hot: letter}, ms). Set pad press: jump only; does NOT change cue point.
- Clear: ✕ on side-list row (cue id must be non-empty). Keys cmd+1/2/3 clear A/B/C for deck A. Shift+1/2/3 set for B.
- Keys: 1,2,3 set A–C (deck A). Shift+1,2,3 set for deck B. D–H and their clears are unbound.
- Colour: right-click a set row in HOT CUE list opens CueColorMenu (HOT): 16 swatches, ColorTableIndex values [49,56,60,62,1,3,9,15,18,22,26,30,32,38,41,46] with CSS from the rbl-anlz DRAWN_CUE_COLOURS table (cross-checked: 49→#DE44CF, 56→#B432FF, 60→#AA72FF). "Reset" = null. Also "Add comments" (disabled).

MEMORY CUES (useMemoryCues.ts)
- M / MEMORY button: store cue point. No write if a memory cue already sits at that ms (memoryCueAt).
- B and N (◀ ▶): call previous/next relative to playhead. Calling sets the cue point to it and seeks. Calling a loop-type memory cue sets the deck loop.
- Keys A,S,D,F,G,H,J,K,L,; = memory cues 1–10 (callNumber).
- X (or ✕ button): delete memory cue exactly at playhead (memoryCueAt).
- Memory list: 10 rows minimum (MEMORY_ROWS=10, Player.tsx:726). Rows show memoryTime "MM:SS:mmm". Click calls it. ✕ deletes. Colour menu: 8 named colours (Pink #E778F1, Red #E33122, Orange #EBA44A, Yellow #F4E458, Green #66DD42, Aqua #56BDF3, Blue #204FEF, Purple #8B1EEF) stored as index 0–7. "No Color" = null.
- Read-only: store/delete/clear disabled; reason string READ_ONLY_REASON (useCueWriter.ts:15).
- useCueWriter: one write in flight at a time (a held key cannot stack writes).

LOOPS (Player.tsx:1171-1207)
- Not written to library ("Nothing is written to the library", comment 1172-1174). The engine owns them, read back from ticks (loopInFrames/OutFrames/looping). Desired loop is replayed after a load (usePlayback.ts:257-260).
- AU mode (default): beat-length page 0.25, 0.5, 1, 2, 4 (default), 8, 16, 32. ‹ › halve/double. Centre button: if active, EXIT; else loop of N beats from head (beatLoopRange, snap start to Q grid).
- MA mode: IN sets in at position; OUT sets loop (only if out > in); RELOOP/EXIT toggles active.
- Keys: I loopIn, O loopOut, R reloop, 4–9 = 1,2,4,8,16,32 beat loops (starts loop, sets length), "/" halve (min 0.25), Option+\ double (max 32).
- Loops show as bands over waveforms: memory loops alpha 0.18, live loop alpha 0.38 when active (Player.module.css:674-685).

METRONOME (Player.tsx:830-855, 1480-1486)
- Per-deck metronome on/off (deckMetronome). Volume cycle small→middle→large→small (cycleMetronomeVolume). Sound 1|2|3 chosen via right-click on the cut-grid button (ContextMenu) or F9 (cycles 2→3→1→2).
- Global engine setting: setMetronome(sound, volume). Stored under prefs.audio.metronomeSound (default 2) and metronomeVolume (default "large").
- Click is generated from the grid pushed by deck_load and by every grid edit (grid.rs run() / set_metronome_grid).

QUANTIZE (Player.tsx:828, 888-891)
- Q chip. Default ON on every mount (not persisted). Snaps cue set, hot cue set, loop start, and sync start to subdivideGrid(grid, 1/fraction) where fraction from prefs.advanced.quantizeBeat ("1/1","1/2","1/4","1/8").

BEAT JUMP (JumpMenu.tsx; lib/player.ts:62-109)
- Sizes in order: Fine (10 ms), 4Beats (default id "4beats"), 8Beats, 16Beats, 8Bars (32 beats), 16Bars (64), 32Bars (128).
- Jump distance is in FILE beats at the file BPM (bpmX100, not bpm*tempo). Player.tsx:1090-1097 uses file bpmX100. Keys ← and → (no modifier) jump deck A. Shift+← / Shift+→ for B.
- Size is chosen from the button next to the jump buttons. Click opens a menu beside the button. Keys do not change size; cycling helper nextJumpSize exists but is not wired.
- Note: the jump key path (onDeckKey, Player.tsx:1467-1470) does NOT check the armed state, but the comment at Player.tsx:1454-1457 says arrows wait for the deck to be clicked. Bug or stale comment.

QUANTIZE / GRID PAD MODE (GRID panel, Player.tsx:557-585, 2139-2178)
- Pad row toggles CUE/LOOP vs GRID.
- GRID EDIT buttons: MARK (downbeat at playhead, mark), TAP (tap tempo; grouped undo transaction), shift ◂▸ (±1 ms; held repeats at 10 ms per tick), widen/narrow (stretch first beat held, ±1 ms per press, held 10 ms), double, halve, adjust all (clear fromMs), adjust beats from here (sets fromMs boundary; earlier beats hidden in the overlay), undo, redo, metronome toggle, lock.
- Grid BPM field: type 40–499 → tempo edit (useGridEditor.ts:123-127).
- Disabled reasons: no grid, read-only library, locked grid.

KEYS in the Player group: see section 9.

ZOOM / WHEEL (lib/player.ts:112-170; Player.tsx:1052-1070, 2036-2038)
- ZOOM_STEPS in bars: 0.25, 0.5, 1, 2, 4, 8, 12 (default), 16, 32, 64.
- +/- buttons step one level. "RST" label is decorative (no action).
- Wheel: deltaY in px (lines*33, pages*400). WHEEL_STEP_PX=100. Mouse notch (≥100 px in one event) steps at once. Trackpad travel accumulates, 150 ms cooldown after each step, 250 ms idle reset, direction reversal discards travel.

OVERVIEW SCRUB AND DETAIL DRAG (Player.tsx:1310-1372; usePlayback.ts:659-717)
- Overview: pointer down captures and scrubBegin + scrubTo(absolute position). Move while captured scrubTo. Up/cancel scrubEnd.
- Detail: pointer down captures and scrubBegin, remember grab position. Drag: scrubTo(grabAt + dragSeconds(dx)). dragSeconds = −dx/width × span × duration (lib/player.ts:273-281). Dragging right moves the record, i.e. earlier music comes in.

PANELS: side tabs MEMORY, HOT CUE, INFO (Player.tsx:729-733, 2424-2558). INFO = DeckInfo (useTrackDetails, fetched only while tab is open).

PHRASE BAR (Player.tsx:475-502; lib/player.ts:317-390)
- Phrases from track_phrases. Each phrase runs to the start of the next, or to end. Unresolved time: placed from its beat x beatMs (beat number's time) if tempo is known, else dropped.
- Kind from the label text: UP / UP 2 / UP 3 / DOWN / CHORUS / INTRO / OUT (→outro) / VERSE / BRIDGE. Unknown → verse.
- Labels shown per prefs.view.phraseLabels; colour tokens per kind (Player.module.css:570-578).

DECK MENU (≡): contextMenus deckMenu. Waveform colour BLUE/RGB/3Band (prefs.view.waveformColor), Beat Count, Export Track (to devices), Export Loop As WAV (only when loop), Waveform click on/off, Analyze Track.

PLAY HISTORY (Player.tsx:1212-1231): see section 11.

INFO for DualDeck head: see section 1.

=====================================================================
3. WAVEFORMS
Files: canvas/waveform.ts 817; views/player/WaveformDetail.tsx 234; VocalStrip.tsx 107; lib/player.ts (above); rbl-app/src/media.rs (waveform_bytes, window_of); src-tauri/src/commands.rs 134 (track_waveform), 158 (track_pcm_waveform), 1280 (track_beats), 1308 (read_beat_grid), 1980 (track_phrases), 2029 (track_vocals).

KINDS AND TAGS (media.rs:78-130)
- "bands" → .2EX PWV6, stride 3. Overview, 1200 columns. Low/mid/high 0–127.
- "bandsDetail" → .2EX PWV7, stride 3. Detail, 150 columns/s. Low/mid/high.
- "colour" (or "color") → .EXT PWV4, stride 6. Overview RGB.
- "colourDetail" (or "detail") → .EXT PWV5, stride 2. Detail RGB.
- "mono" default → .DAT PWAV, stride 1 (5-bit height, 3-bit whiteness). Overview blue.
- "monoDetail" → .EXT PWV3, stride 1. Detail blue.
- Palette→kind map (canvas/waveform.ts:40-56): 3band→bands/bandsDetail; blue→mono/monoDetail; rgb→colour/colourDetail.
- Strides (strideOf): 3band 3; blue 1; rgb detail 2, overview 6.
- Byte formats:
  - PWAV/PWV3: byte = height(bits 0–4, 0–31) | whiteness(bits 5–7). Height = (byte&31)/31. Colour = blue ramp LOW→ALL at whiteness/7.
  - PWV4 (6 B/col): byte0 = height 0–127; bytes 3,4,5 = r,g,b. Bytes 1,2 not read (waveform.ts:341-346).
  - PWV5 (2 B/col, BE 16-bit): rrrgggbbhhhhh00. r=bits 15..13, g=12..10, b=9..7, h=(bits 6..2)/31 (waveform.ts:353-358).
  - PWV6 / PWV7 (3 B/col): low, mid, high each 0–127. Full scale 127 (BAND_FULL_SCALE).
- PCM (track_pcm_waveform, commands.rs:158-264): 8 bytes per column: four i16 LE = Lmin, Lmax, Rmin, Rmax, scaled from float ×32767. Columns clamped 1–7500. Decoded via rbl_deck::decode::Streamer at 44.1 kHz. Frontend reads it as drawPcmWave (waveform.ts:451-548).
- Beat grid (track_beats, commands.rs:1280-1330): 7 B per beat: u32 LE ms, u8 beat number (1–4), u16 LE tempo×100. Parsed by parseBeatGrid (lib/player.ts:490-503). Capped to 65,536 beats (MAX_BEATS, commands.rs:33).
- Phrases (track_phrases): JSON. PSSI from .EXT; beat resolved against PQTZ; max 512.
- Vocals (track_vocals): raw bytes, one per 46.44 ms, from PVDI in .2EX. Threshold PRESENT=128 is UNVERIFIED (VocalStrip.tsx:31-35). Drawn as full-height --c-vocal (#3FA9F5) ticks where column peak ≥128.
- Cues: JSON (track_cues) with colour from DRAWN_CUE_COLOURS, memory colours from named table.

WHAT EACH SURFACE FETCHES
- Overview: WaveformDetail with span 1, progress 0.5 (Player.tsx:1884-1893). Full-track bands (or whatever palette), stacked-from-baseline when overviewWaveform='half', centred when 'full'.
- Detail: WaveformDetail with detail, width = detail.width*2, full PWV7 (or PCM when bars ≤ 0.5). Fetches the whole tag (WaveformDetail.tsx:49), cached per track+kind, no window. Note backend comment (commands.rs:~125-133) claims detail should window the tag because PWV7 is 158 KB, past a "64 KB response cap". I found no cap enforced in code. Verify before relying on either claim.
- Row preview: out of scope but uses PWV6 with half-stacked drawing (WaveformPreview.tsx:104).
- PCM window: fromMs = window.from − 2000, toMs = window.to + 2000 (guard). Re-decoded when the window leaves the cached buffer (750 ms reserve; WaveformDetail.tsx:130-159).

DETAIL GEOMETRY (lib/player.ts 179-211, 251-254, 656-677, 702-728; Player.tsx 967-1043)
- Window in bars: detailSpan(bars, bpmX100, total) = (bars*4*60/bpm)/total, fraction of track, clamped to [1e-4, 1]. Falls back to 0.08 when no BPM.
- Drawn layer covers span*OVERDRAW (OVERDRAW=2). Head fixed at 50%. Layer slides by a transform: translateX = −(progress−anchor)/span × width (scrollOffset). Redraw only when |progress−anchor| > span/4 (needsRedraw: span*(OVERDRAW−1)/4). Anchor set via setState, applied in layout effect.
- Waveform clock remap (detailWaveWindow): waveform duration = columns / 150 s. progress' = (progress*audioDurationMs + originMs) / waveformDurationMs, span scaled likewise. Origin correction (detailWaveOriginMs): only when first beat ≤ 100 ms and a non-zero column appears in the first 16 columns; correction in (0, 50] ms, else 0.
- waveSlice: byte range of the tag for the window, plus integer device-pixel x0 and width. Partial columns outside the window are included so transients stay on the grid.
- Playhead: detail head fixed in middle. Overview head = translateX(pos/total × overview.width). Played region = scrubFill below overview with scaleX(pos/total) (Player.module.css:528-543). Overview waveform is NOT dimmed.

DRAW ALGORITHMS (canvas/waveform.ts)
- Band colours (combination bits low=1, mid=2, high=4; bandColour 86-91):
  - 1 low: #0055E1 (waveLow)
  - 2 mid: #FFA600 (waveMid)
  - 3 low+mid: #B4690A (waveLowMid)
  - 4 high: #FFFFFF (waveHigh)
  - 5 low+high: #D2DCFA (waveLowHigh)
  - 6 mid+high: #FFF0D7 (waveMidHigh)
  - 7 all: #F5EBD7 (waveAll)
  - 0 falls back to low.
- drawBands (155-280): per pixel, max over the columns that fall in it per band. Detail with step<1 (zoom-in) interpolates linearly, except sharp attacks: a=0 with b>0, or b−a ≥16 and b ≥ 2a, which stay stepped (206-222).
- Centred (default): segments() (289-308) from outermost reach inward. reach = max(0.5, value/127 × usable/2). Each segment fillRect(x, centre−reach, 1, 2·reach) in the colour of bands that reach that far.
- Half "overlaid" (dual deck): from baseline floor−reach, same colouring, reach = value/127 × usable.
- Half stacked (row preview): STACK_SCALE [128, 256, 128] for low/mid/high; blue then amber then near-white on top.
- Silence: 1-px line at centre (or floor when half) in colour LOW|HIGH (waveform.ts:241-244).
- Insets: top/bottom clear rows read from --s-wave-inset-top (default 20) and --s-wave-inset-bottom (default 16) (Player.tsx:523-533). Overview does not use them.
- drawColumns (blue/rgb): per pixel take the column with the largest height. Height (min 1 px) centred or from baseline.
- drawPcmWave (451-548):
  - Two lanes at 0.25·h and 0.75·h (+0.5).
  - Scale = max(1, h/4 − 2) / max(peak, 1), peak = max |sample| over visible window.
  - Fill between min and max edges at alpha 0.26, edge lines at alpha 1, linear interpolation.
  - Zero-amplitude line drawn at alpha 0.65.
  - PCM colours: blue #5BA0FF, 3band #FFA600, rgb #F266DC. Fixed hues because PCM has no bands.
- Overview 3-band in dual uses half='overlaid'. Single-deck overview uses 'half' or centred per prefs.

CUE AND GRID MARKERS (Player.tsx 283-441, Player.module.css 656-720)
- Hot cue: lettered badge (overview: 11pt square hung from top, left edge on cue; detail: centred on cue). Colour = cue.colour from ColorTableIndex; hot cue default green #3CEB50 (index 21). Text #000000. Hot cue colour can be turned off (View > HOT CUE color, "colorful" or fallback).
- Memory cue: overview small red head (cueHead #EA3323). Detail 16 pt down-triangle.
- Loops as bands (above).
- Beat grid (BeatGrid component, 404-441): each beat in window is a 1-px marker at (t−from)/span. Downbeats (number 1) get class "downbeat" (heavier and red-ish per CSS), others "beat" (#4C4C4C). When bars ≥ 64 only downbeats are drawn (showsEveryBeat, lib/player.ts:42-44). Beats before fromMs hidden in edit-from mode.
- Grid edit boundary: red mark (GridEditBoundary, 448-466).
- Tempo annotations (TempoMarkers 364-393, tempoAnnotations 904-933): equal-tempo beat runs of ≥4 collapse into a settled section label "xxx BPM" (detail) or overview label. Ramps drawn as a span with from→to labels. Gated by prefs.view.showBpmChanges (default true).
- Phrase bar and vocal strip as above.

=====================================================================
4. MIXER (MixerStrip.tsx 257; MixerStrip.module.css 137)
- Only in two-deck layout. Not persisted.
- Per channel (Channel, 51-189):
  - Trim: knob (role slider). Range 0–2 (up to +6 dB). Vertical drag: 120 px = full sweep, Δtrim = dy/120*2. Arrow keys ±0.05. Double-click resets to 1. Readout "-∞dB" at 0, else dB with one decimal (trimLabel 44-48). Caption "A-GAIN" is decorative; the knob is always trim.
  - Kill buttons HIGH, MID, LOW: toggle engine channel kill per band (setChannelKill). Keys eqKillLow/Mid/High (unbound by default; chord key "").
  - Deck B strip mirrors deck A (flipped).
- Crossfader (MixerStrip 198-257): vertical fader, 0 = A only, 1 = B only, 0.5 = both. Detent: within 3 px of centre snaps to 0.5. ArrowUp/Down ±0.05, double-click resets to 0.5. Sends setCrossfade on mount and on every change.
- Not implemented in UI: EQ bands (set_channel_band exists in client.ts and commands.rs:1588 but nothing calls it), EQ/ISOLATOR switch (set_eq_curve exists, nothing calls it). The HIGH/MID/LOW buttons are kill toggles, not EQ knobs.
- Mixer state is local React state (trim default 1, killed set empty) and is NOT read back from the engine on mount. After a remount, the UI can show 1.0 while the engine still has the last value (MixerStrip.tsx:58-59). Crossfade is re-sent (reset to 0.5) on every mount (202-208).
- Engine defaults (rbl-deck/src/mixer.rs:106-243): trim 1.0; bands 0.5 (centre); kills off; crossfade 0.5; curve Eq; fade Full.
- Crossfade law: Fade::Full (unity across the middle, silence only over far half). Constant-power option exists as Fade (not wired).

MASTER OUTPUT (store/useMaster.ts, store/MasterOutput.tsx, lib/volume.ts, views/topbar/VolumeKnob.tsx)
- Knob (topbar): 0..11 reading. 10 = −1 dB (engine default gain 0.891251). 11 = +2 dB (MAX gain 1.258925). Taper 40 dB across the last decade (volume.ts:31-41). Stored as linear gain in localStorage "rbl.master-level.v1".
- set_master_level(level) clamps to [0, 1.258925]. Non-finite → 1.0.
- Meters: deck:meters at ~30 Hz feed useMaster. Fast attack; fall 20 dB/s (FALL_DB_PER_SECOND, MAX_STEP 0.25 s). Silence threshold 0.001. Falls on its own if no reading in 100 ms (SILENT_AFTER_MS). VU modes via lib/vuMeter.ts (normal and fabulous, VuMeterMode pref).

LIMITER (store/useLimiter.ts; rbl-deck/src/limiter.rs; Settings AudioPane)
- localStorage "rbl.limiter.v1": {enabled:false, inputGainDb:−4, ceilingDb:0, releaseMs:250}. Ranges: input −24..+24 (step 0.1), ceiling −12..0 dBFS (0.1), release 10..1000 ms (10). Engine clamps; the UI shows what the engine returns.
- Pushed to backend on mount (App-level via useLimiter) and every change (set_master_limiter).
- Applies to the deck engine only. Preview engine is not limited (see section 6).
- Reduction meter uses Master.reduction_db(); deck tick and meters report it.

=====================================================================
5. TIMING LOOP
Files: src-tauri/src/player.rs 577; src/lib/clock.ts 98; src/lib/player.ts; src/store/usePlayback.ts 887.

RUST SIDE (player.rs)
- Position is never polled via command. One event, deck:tick, at ~10 Hz carries both decks (TickDto).
- start_ticker (394-455): dedicated OS thread "rbl-deck-tick". Loop sleeps METER_TICK = 33 ms (~30 Hz). Each pass emits deck:meters. Every 3rd pass (TICKS_PER_DECK_TICK=3) also emits deck:tick (~10 Hz). Thread exits after 5 consecutive deck-tick passes with nothing sounding (~500 ms tail; comment says 400 ms, player.rs:~416-420 vs 441). Restarts if a play or scrub began during shutdown.
- Ticker is started by deck_play, deck_play_after, deck_seek, deck_set_loop, deck_loop_active, deck_clear_loop, deck_scrub_begin, deck_scrub_end, and by preview_play when it paused a deck. Not started by deck_pause, which relies on the running ticker.
- Peaks and reduction are read and cleared per meter pass, and the tick carries that pass's values.
- Device opens lazily on first command (engine()). Doc says the device opens on first thing played, but set_master_level also calls engine() (commands.rs:1572-1578), and useMaster calls setMasterLevel on boot when a level was remembered (useMaster.ts:184-186). So the device opens at launch after the user has ever set the knob. Also set_crossfade and set_channel_* call engine() (MixerStrip mount does this).
- Pre-roll: frames is negative during pre-roll (seek to −5 s allowed).
- deck:loaded and deck:error (DeckEventDto) are emitted only from the engine's own events; both decks use these. Preview's player is quiet (no deck events).
- deck:reset emitted when a device or rate change drops the engine.

EVENT PAYLOADS (player.rs; TS in src/ipc/types.ts:926-983)
- deck:tick TickDto: a, b (DeckTickDto), sampleRate, peakLeft, peakRight, master, reduction, shiftsKey.
- DeckTickDto: frames(i64), totalFrames(u64), generation(u32), playing, loaded, loadId(u64), tempo(f32), masterTempo, keyShift(i8), startInFrames(u64), loopInFrames, loopOutFrames, looping. ~200 B, under the 1 KB cap.
- deck:meters MeterDto: rmsLeft, rmsRight, peakLeft, peakRight, master, reduction.
- deck:loaded / deck:error DeckEventDto: deck ("a"/"b"), loadId, totalFrames, sampleRate, message (null on success).
- deck:reset: no payload.
- grid:changed, cues:changed, analysis:changed: payload = track id string.
- edit-history:changed, library:changed: emitted by edit paths.

JS SIDE
- usePlayback (src/store/usePlayback.ts):
  - anchorOn(tick) (331-424) stores anchor {frames, at, sampleRate, playing, generation, rate=tempo}. Snaps position on load or seek (generation change) or when not playing. Otherwise drift is eased.
  - Startup: deckState() (1878) anchors; subscribes to tick, deck event, and deck:reset (427-486).
  - Frame loop (526-545): runs only while React state playing is true. Each rAF: target = extrapolate(anchor, now); advance = elapsed × rate (none if before startsAt); next = follow(positionRef, target, dt, advance); emit(next).
- clock.ts:
  - extrapolate(anchor, now) = frames/sampleRate + max(0, now−at)/1000 × rate (46-53). Not backwards. Stopped deck returns base.
  - follow(shown, target, sinceMs, advance): predicted = shown + advance; gap = target − predicted; if |gap| > SNAP_SECONDS (0.25 s) or first frame, snap; else predicted + gap × (1 − exp(−sinceMs/50 ms)) (71-78). Easing applies only to clock correction, not to motion.
  - pinned(anchor, seconds, now): freezes at a position (drag owns the head) (91-98).
  - clock.ts header comment (line ~26-29) says rate is 1 until tempo ships. Stale: tempo is live.
- Subscribers: subscribe(listener) gets every frame during playback, and once per anchor on pause or seek. Time readouts subscribe via useSyncExternalStore and only re-render when tenths change (TimeReadouts.tsx). Playhead, scroll, bars label, overview aria value are written straight to DOM (Player.tsx 996-1027).
- Detail layer redraw handled by needsRedraw, so the canvas redraws only every ~quarter span.
- LANDING_MS = 500 (usePlayback.ts:126): after a drag ends, ticks are ignored until one agrees with the drag's end position, or 500 ms passes.

WHAT A NATIVE PORT SHOULD POLL / SUBSCRIBE TO
- Subscribe (push), do not poll: deck tick at ~10 Hz and meters at ~30 Hz (or call deck_state() as a snapshot at launch and after reset).
- Per display frame, only while playing or dragging: compute playhead = extrapolate(anchor, now) with follow() easing, then update overview head, detail translation, bars label, and the time readouts (tenths).
- Redraw detail canvas only when needsRedraw. Do not redraw the waveform per frame.
- Stop the display-link when paused. Preview polls previewState at 10 Hz while playing (see 6).

=====================================================================
6. PREVIEW PLAYER
Files: src-tauri/src/preview.rs 210; src/store/usePreview.ts 143; src/views/browser/WaveformPreview.tsx 282 (previewFromClick 268-282; playhead and stop 225-260); src/canvas/waveform.ts previewClickMs 690-710, drawPreviewCues 658-679, drawPreviewMemoryCues 712-730.
- Click gesture (WaveformPreview.tsx:268-282): plain left click on the PREVIEW column waveform (not second of double-click, no Shift/Meta/Ctrl, not on a button). Time = click fraction × duration. If y<7 px and x hits a hot-cue badge, time = that cue's position (last drawn wins).
- preview_play(track, positionMs) (commands.rs:1890): looks up path via library; runs Preview::play on the blocking pool (waits up to 10 s for the file to open, LOAD_TIMEOUT preview.rs:44).
- Preview::play (preview.rs:96-161):
  - Refuses a missing file (NotFound).
  - Pauses deck A and B if playing; calls start_ticker so the tick reports the stop.
  - Copies device, wish (sample rate and buffer), and current master gain from the decks. Master gain is a snapshot at play time only. The preview does NOT copy the limiter, metronome, or key/tempo.
  - Holds the loaded track if same track is already loaded (fast re-click). Otherwise load_as(PREVIEW_DECK=A, path, request id).
  - Newer request wins: older waiters return early.
  - Seeks then plays deck A of its own engine.
- preview_stop: bumps request id (cancels pending waits) and pauses preview deck A. The track stays loaded, so a re-click resumes fast.
- preview_state (preview.rs:175-190): {track, playing, positionMs, durationMs}. Idle if never previewed. Position is from its own engine (not extrapolated in Rust).
- The preview is a second Engine with its own CpalSink (two output streams on the same device). Its output is not summed into the decks' master, not limited by the master limiter, and not reflected in deck:meters or deck:tick.
- Preview does not emit deck:loaded/deck:error (quiet).
- Front end (usePreview.ts): store with one current preview. startPreview publishes at once, calls preview_play, then polls preview_state every PREVIEW_POLL_MS = 100 ms while playing. Playhead extrapolated with previewPositionMs (positionMs + elapsed, clamped to duration). Stop button drawn on the row (WaveformPreview.tsx:226-251). Refusals reach App through onPreviewError (App.tsx:532).

=====================================================================
7. BEAT GRID AND CUE EDITING (WRITES)
Files: src-tauri/src/grid.rs 1029 (app half ~1-650), src-tauri/src/cues.rs 493, src-tauri/src/analysis.rs 573 (edit_phrase 326-), rbl-db/src/write.rs (set_analysis_lock 1828, save_grid_revision 1811, record_play 1909), rbl-anlz/src/write.rs (beat_grid_section 54-68).

GRID COMMANDS (grid.rs)
- grid_state(track) (570): GridStateDto {bpmX100, beats, canUndo, canRedo, undoLabel, redoLabel, locked}. Read-only. Errors NotFound if not analysed.
- grid_edit(track, edit, fromMs?, deck?, options?) (590). GridEdit kinds (serde camelCase, tag "kind"): nudge{ms}, double, halve, downbeat{timeMs}, tempo{bpmX100, anchorMs}, stretch{byMs, timeMs}, tap{bpm, anchorMs}, align{timeMs}.
- grid_undo(track, deck?) (605), grid_redo(track, deck?) (617). History per track in-memory, cap 100 (grid.rs HISTORY_CAP). Not persisted across launches.
- grid_lock(track, on) (631).
- Shared run() (~528-586): takes edit_gate and analysis_write locks, applies edit via apply_options. If the BPM changed, calls save_grid_revision (library write) and reload. On a written result: sets metronome grid on the deck (if deck given), emits grid:changed(track).
- apply_options (~ 400-500): refuses when write_refusal_reason says library is read-only or rekordbox is running. Locked if editor.is_locked OR database_locked (djmdContent.Analysed bit 0x80). Validates edit. Refuses changing tempo of a dynamic (variable-tempo) section without allow_dynamic. Writes .DAT (PQTZ replaced; beat_grid_section zeroes the grid offset field, write.rs:57-58) and clears the .EXT extended grid. Journal (file_journal) for crash recovery. History push with label (Shift Beat Grid Left/Right, Double Tempo, Halve Tempo, Set Downbeat, Set Tempo, Tap Tempo, Adjust Beat Grid, Align Beat Grid).
- TAP edits in the same run share one undo transaction (options.transaction).

GRID LOCK: NOT a pure app-local flag, despite the module doc.
- grid_lock calls state.write(set_analysis_lock(track, on)) (grid.rs ~631-646). That is a djmdContent.Analysed write: bit 0x80 set or cleared, plus USN bump (rbl-db write.rs:1828-1837). This is a library write that rekordbox also reads.
- Then editor.set_locked(track, false) clears the app's local grid-locks.json. Production code never sets it true (set_locked(true) only in tests, analysis.rs:554 and usb_import.rs:238). So the local file is effectively dead.
- Module doc and grid_lock doc claim "Nothing in the library changes". False.

CUE COMMANDS (cues.rs)
- add_cue(track, kind, positionMs u32) → id (173). kind is "memory" or {hot: "A"} (letter A–P; hot slot check via Cue::kind_of_letter).
- add_loop(track, kind, inMs, outMs, beats?) → id (189). beats optional (0 when unknown).
- move_cue(cue, positionMs) (203). Owner looked up before write.
- set_cue_colour(cue, colour: u8?) (213). Hot: ColorTableIndex. Memory: named index 0–7.
- delete_cue(cue) (220).
- convert_memory_cues_to_hot(track) → count (234). Plan: memory cues sorted by position, assigned next free hot letters A–P. Loops stay loops (out > in → AddLoop). Each assignment is a separate write, not atomic. Memory cues are kept [ASSUME].
- Every cue edit: one writer open, one write, read-only reload of that track's cues, then emit cues:changed(track). Fast (~0.6 ms per reference).
- All are library writes (djmdCue rows).
- Write gate: state.write → write_refusal_reason (refuses while rekordbox runs or read-only).

PHRASE EDIT (analysis.rs:326-): edit_phrase(trackId, beat, "cut"|"clear") → bool. Rewrites .EXT only, not database. Refuses while rekordbox is running. Emits analysis:changed. (Player's phrase bar does not expose editing yet.)

UI SIDE of writes
- useCueWriter: one write in flight; success clears error; failure reported to status bar.
- useTrackCues refetches on cues:changed(track), library:changed, and window focus. useTrackGrid refetches on grid:changed, analysis:changed, library:changed.
- Writes are never shown ahead of the backend: the list and markers come from the refetch.

=====================================================================
8. AUDIO SETTINGS
Files: src/views/settings/AudioPane.tsx 255; src-tauri/src/commands.rs 1705-1765 (audio_devices, set_audio_device, master_limiter, set_master_limiter), 1429-1440 (set_audio_config), 1406 (set_metronome); src-tauri/src/player.rs (set_device 310, set_wish, set_metronome); crates/rbl-deck/src/sink.rs (output_devices 215, default_output_device 228, StreamWish 237-240, configure 245+); lib/preferences.ts (SAMPLE_RATES line 35, BUFFER_SIZES line 38, audio defaults 285-288).
- Output device: select with "System default — <name>" plus each device. audio_devices() re-read every time the pane opens. Stored: prefs? No, chosen id held in the Player (not persisted in prefs). The UI keeps `chosen` only in pane state; on relaunch the app uses the system default until the user chooses again [verify: device id not in localStorage].
  - set_audio_device(device?): drops the engine if changed; next play opens the new device; emits deck:reset; the UI reloads the track at its current position and resumes if it was playing (usePlayback.ts:456-460, 290-311).
- Sample rate: 44100, 48000, 88200, 96000 Hz (Select). Default 48000.
- Buffer: 64, 128, 256, 512, 1024, 2048 frames (stepped slider). Default 512. Caption "N samples (x.y ms)".
- set_audio_config(sampleRate?, bufferFrames?): applied the next time a deck engine is built (drops engine on change, emits deck:reset). App.tsx:470-480 pushes prefs.audio on start and on every change, along with setMetronome.
- CpalSink::open_with (sink.rs:87+): uses the device default config, the wished rate if the device offers it, and the wished buffer if in range. Otherwise the device default.
- Metronome: sound 1|2|3 ("Click Sound 01/02/03") and volume small|middle|large (Radios). Pushed to engine via set_metronome.
- Master limiter section: see section 4.
- Pane readouts: output peak L/R from props, reduction meter.
- Preferences keys: localStorage "rbl.preferences" → audio {sampleRate, bufferSize, metronomeSound, metronomeVolume}.

=====================================================================
9. KEYBOARD (Player group)
Files: src/lib/shortcuts.ts 602 (PLAYER_A 403-453; playerB 456-468; BINDINGS 470-536; dispatchBinding 355-365; typing guard 325-365), src/views/player/Player.tsx (onDeckKey 1460-1614; onDeckKeyUp 1615-1618).
- Mac: Command is metaKey. Shift is Player B.
- Typing guard: no player keys while an input or textarea or select has focus (except focusSearch and clearSearch). CUE keyup is still honoured.
- Deck A (PLAYER_A rows):
  - Space: Play/Pause (preventDefault).
  - C: CUE (hold).
  - Q: Quantize toggle.
  - M: Set memory cue. B: previous memory cue. N: next memory cue. X: delete memory cue.
  - A, S, D, F, G, H, J, K, L, ;: memory cues 1–10 (call).
  - 1, 2, 3: set hot cue A, B, C. Cmd+1, Cmd+2, Cmd+3: clear hot cue A, B, C.
  - I: loop in. O: loop out. R: exit or reloop.
  - 4, 5, 6, 7, 8, 9: beat loop 1, 2, 4, 8, 16, 32 (sets length, starts loop).
  - /: halve loop length. Option+\: double loop length.
  - ← Jump Reverse (jumpBack). → Jump Forward.
  - F1: SYNC (beat sync). F2: Master Tempo toggle. F3: Tempo Reset. F6: BPM − (0.001). F7: BPM + (0.001).
  - F9: Change metronome sound (cycles 2→3→1→2). F10: show MEMORY list. F11: show HOT CUE list. F12: show INFO.
  - Cmd+G: Adjust BPM/BeatGrid (opens GRID pad mode).
  - Cmd+←: shift beat grid left (1 ms). Cmd+→: shift right (1 ms). Cmd+Option+\: align beat grid to nearest beat under playhead ("Shift Beatgrid to the center").
- Deck B: same keys with Shift (playerB 456-462). Excludes metronome sound (F9), adjust-grid (Cmd+G), and hot-cue clears (so no Shift+Cmd+1..3). Player B has Shift+1/2/3 to set hot cues A–C. Shift+M, Shift+B, etc. work for B.
- Hot cue D–H and clears D–H: unbound (own rows, chord key "").
- Mixer kill keys: eqKillLow/Mid/High per deck, unbound.
- Enter (browse, group Browse): loadPlayer1 — loads highlighted track onto deck A (App.tsx:2199-2240). Shift+Enter alias.
- Cmd+1/2/3 are also Player clear keys (Mac). On Windows, Ctrl+ accelerator via menuAccelerator.
- Menu accelerators: Cmd+7 one, Cmd+8 two, Cmd+9 simple, Cmd+0 browser; Cmd+B sub browser; Cmd+Shift+F full screen.
- Player keys respond only when the deck is "armed" (clicked) for the arrows? See bug note in section 2: arrows currently ignore armed.
- Player keydown listener on window (globalThis). Deck filters by hit.deck, so A's keys don't fire B. Idle decks ignore everything except showMemory, showHotCues, showInfo.

=====================================================================
10. TAURI COUPLING, rbl-deck API, PORT PLAN, BUILD
A. How player.rs uses AppHandle
- Player::engine(&self, app) (240-268): clones the AppHandle into an EventSink closure (deck:loaded/deck:error via emit_deck_event). Builds the Engine on first use via Engine::with_sink(|render| open_sink(render, device, wish), &events). Then applies remembered limiter, master gain, metronome sound and volume.
- emit_deck_event(app, event) (362-392): app.emit(name, DeckEventDto).
- start_ticker(app) (394-455): app.state::<Arc<Player>>() for the ticking flag; the spawned thread holds an AppHandle clone and calls handle.state::<Arc<Player>>() on every pass, handle.emit("deck:meters" / "deck:tick").
- preview.rs: Preview::play(app, decks, ...) uses app for engine() and start_ticker(app). The Preview holds its own Player::quiet() (no events).
- commands.rs: ~13 deck commands take AppHandle only to call engine() and start_ticker(). Others take State<Arc<Player>> only.
- Other emits in the deck path: set_audio_config and set_audio_device emit deck:reset. grid_* emit grid:changed. cue_* emit cues:changed. edit paths emit library:changed and edit-history:changed. analysis emits analysis:changed.
- Blocking: preview_play and deck_load block (file open, up to 10 s). Run on blocking pool.

B. rbl-deck public API (crates/rbl-deck, ~7.9 K lines total in src, Tauri-free; deps: cpal 0.18, rtrb, rubato, symphonia, thiserror, tracing, cc (optional, default feature rubberband))
- Types: DeckError{NoDevice, Device, Decode, Io}; Deck{A,B} with name(); DeckEvent{Loaded{deck,load_id,total_frames,sample_rate}, Error{deck,load_id,message}}; EventSink = Arc<dyn Fn(DeckEvent)+Send+Sync>; Snapshot{a,b,sample_rate} with any_playing(); DeckSnapshot {position_frames, pre_roll_frames, total_frames, generation, sample_rate, playing, loaded, load_id, tempo, master_tempo, key_shift, start_in_frames, loop_in_frames, loop_out_frames, looping}.
- Engine (lib.rs:276+):
  - Construction: Engine::new(&EventSink), Engine::on_device(&EventSink, Option<String>), Engine::with_sink(FnOnce(Render)->Result<Arc<dyn Sink>>, &EventSink).
  - Deck transport: load(deck, &Path), load_as(deck, &Path, request_u64), unload(deck), play(deck), play_after(deck, frames), pause(deck), seek_frames(deck, u64), seek_ms(deck, f64), set_loop_ms(deck, in, out), set_loop_frames, set_looping(deck, bool), clear_loop(deck).
  - Deck settings: set_tempo(deck, f32), set_master_tempo(deck, bool), set_key_shift(deck, i8), Engine::shifts_key() (= cfg rubberband), sample_rate().
  - Scrub: scrub_begin(deck), scrub_to_ms(deck, f64), scrub_end(deck).
  - Status: snapshot() → Snapshot, any_playing(), any_sounding(), audio_health().
  - Metronome: metronome() → &Arc<MetronomeSettings> (set_sound, set_volume), set_metronome(deck,bool), metronome_on(deck), set_metronome_grid(deck, &[(u32, bool)]).
  - Mixer: mixer() → &Arc<MixerSettings>: channels[0..2].set_trim, set_band(Band, f32), set_kill(Band, bool); set_crossfade(f32), set_curve(Curve{Eq,Isolator}), set_fade(Fade).
  - Master: master() → &Arc<Master>: gain()/set_gain() (0..1.258925; default 0.891251), peaks(), rms(), reduction_db(), rate.
  - Limiter: limiter() → &Arc<LimiterSettings>: set_input_gain_db, set_ceiling_db, set_release_ms, set_enabled; constants DEFAULT_* and MIN/MAX_*.
- Devices and sinks (sink.rs): Render = Box<dyn FnMut(&mut [f32])+Send>; trait Sink; CpalSink::open(render), open_named(render, Option<String>), open_with(render, Option<String>, StreamWish); NullSink for tests; output_devices() → Vec<AudioDevice{id,name}>; default_output_device(); StreamWish{sample_rate: Option<u32>, buffer_frames: Option<u32>}.
- Decode: rbl_deck::decode::Streamer::open(path, rate), seek(frame), fill(&mut [f32]), total_frames(), position(), finished().
- Stretch: Stretcher, Varispeed, Wsola, RubberBand (feature); MIN_RATIO 0.5, MAX_RATIO 2.0.
- Constants: FADE_FRAMES; DEFAULT_MASTER_GAIN; MAX_MASTER_GAIN; limiter DEFAULT_INPUT_GAIN_DB=−4, DEFAULT_CEILING_DB=0, DEFAULT_RELEASE_MS=250.
- ClickSound{One,Two,Three}, ClickVolume{Small,Middle,Large}, GridBeat, Metronome, MetronomeSettings.

C. Concern: Engine is not Tauri-free in its API design only through EventSink closures and &Arc getters. Those are fine for Rust consumers. What's missing is the persistence layer that Player provides: lazy open, remembered device/wish/limiter/metronome/master level across engine rebuilds, tick_of snapshot mapping, and the ticker thread.

D. Minimal plan (A): move the Tauri-free parts into rbl-app.
1. New module rbl-app/src/player.rs (and preview.rs) containing Player, Preview, TickDto/MeterDto/DeckEventDto/PreviewStateDto/LimiterDto (DTOs), tick_of, deck_of, and a ticker that takes Arc<Player> directly (drop the state::<> lookup inside the thread at player.rs:~405-443).
2. Replace AppHandle with a sink trait (rbl-app already has events::EventSink and AppEvent, events.rs:12-54). Add AppEvent variants: DeckTick(TickDto), DeckMeters(MeterDto), DeckEvent(DeckEventDto), DeckReset, or a separate PlaybackSink trait with four methods.
3. src-tauri implements it by app.emit(...). The Tauri commands become thin wrappers (~1–5 lines each).
4. rbl-app's Cargo.toml must gain rbl-deck (today only src-tauri depends on it). Check that rbl-app's own default features do not drag GPL in unexpectedly (rbl-deck default feature is rubberband = GPL-2.0-or-later).

E. Plan (B): UniFFI over rbl-ffi (crates/rbl-ffi, already a staticlib with UniFFI 0.32 and an EventListener adapter at rbl-ffi/src/events.rs:23-33). Recommend exposing Player, not raw rbl_deck::Engine.
- Add #[derive(uniffi::Object)] Player (or a PlaybackCore object) with methods mirroring the deck_* commands and a #[uniffi::export(with_foreign)] PlaybackListener trait (on_tick(TickDto), on_meters(MeterDto), on_deck_event(...), on_reset()) modelled on EventListener/ListenerSink.
- DTOs get uniffi::Record derives (feature-gated or in rbl-ffi/src/types.rs), so rbl-deck and rbl-app stay FFI-free.
- Raw rbl_deck exposure over UniFFI rejected: Engine's API leaks closures (Render, EventSink), &Arc getters and a lazy-open policy. You would need a wrapper object anyway, and the persistence rules live in Player.
- Swift must call preview_play-equivalent and deck_load off the main thread (both block on file open).
- Ticking: keep the Rust ticker thread (10 Hz deck, 30 Hz meters) and push via the listener. Do not poll via FFI per display frame.
- Waveform bytes: already available through rbl-app media.rs waveform_bytes(library, share, track_id, kind, from, len) and track_pcm_waveform decode path; expose as Vec<u8> over FFI.

F. Build and link (static lib into an Xcode app)
- rbl-deck build.rs (crates/rbl-deck/build.rs): when feature rubberband (default), compiles vendor/rubberband/single/RubberBandSingle.cpp with cc, C++17, warnings off. On macOS: println!("cargo:rustc-link-lib=framework=Accelerate") (vDSP). cc adds the C++ standard library (libc++) on Apple targets.
- cpal 0.18 on Apple: CoreAudio via coreaudio-rs 0.14.2 (default features audio_toolbox + core_audio) → objc2-audio-toolbox, objc2-core-audio, objc2-core-foundation. Those crates emit framework link attributes; for a staticlib these do NOT propagate to the Xcode link step.
- So the Xcode target must link: -lc++, -framework Accelerate, -framework AudioToolbox, -framework CoreAudio, -framework CoreFoundation (and anything else listed). Get the exact list with: cargo rustc -p rbl-ffi --crate-type staticlib -- --print native-static-libs. I could not run it (read-only), so treat the list above as expected, not confirmed.
- Universal (arm64 + x86_64) builds need both C++ objects built per target (cc handles this per target triple).
- Sandboxed macOS apps need the audio-output entitlement for CoreAudio output [verify against target's entitlements].
- Licence: rbl-deck default (rubberband) is GPL-2.0-or-later and the whole build inherits it. A --no-default-features build is WSOLA-only: key shift is not accurate and shiftsKey = false (rbl-deck/src/lib.rs shifts_key).
- Workspace lints: unsafe_code = "deny" (root Cargo.toml). rbl-ffi already compiles under it.

=====================================================================
11. LISTENING HISTORY (record_play)
Files: src/views/player/Player.tsx 538-539 (PLAY_RECORD_SECONDS=60), 1208-1231; src-tauri/src/commands.rs 2857-2862; rbl-db/src/write.rs 1909-1933, 2869-2894 (append_play); src-tauri/src/commands.rs ~219-242 (edit wrapper); rbl-app/src/edits.rs (Touched::Histories → library:changed).
- Trigger (frontend): a 1 s setInterval runs while playback.playing is true for the deck. It counts seconds of playing time per track load (not reset on pause). At 60 s, once per track load (recordedFor), calls backend.edits.recordPlay(id). Counter resets when track id changes. Gated by prefs.advanced.recordHistory (default true) and not readOnly.
- Preview does not count (it does not go through Player).
- Backend record_play(track) → u32 generation. Writes in one transaction:
  - Creates month folder and "HISTORY yyyy-mm-dd" session node in djmdHistory if missing.
  - Appends djmdSongHistory row (TrackNo = max+1 in that session, ContentID = track).
  - Increments djmdContent.DJPlayCount (COALESCE+1).
  - Bumps USN counter.
- Refused when the library is read-only or rekordbox is running (state.write gate). Refuses if track id unknown.
- Emits library:changed (whole library refresh) and edit-history:changed. Clears the app's undo redo branch (commands.rs:236 clear_redo) but is not itself undoable.
- The rekordbox threshold is not recorded; 60 s is an [ASSUME].

=====================================================================
12. DISCREPANCIES AND BUGS TO REPLICATE OR FIX (verify before porting)
1. Arrow-key jump is not gated by armed (Player.tsx:1454-1470 vs comment 1454-1457). Arrows jump deck A even when the deck was never clicked.
2. grid_lock writes djmdContent.Analysed (rbl-db write.rs:1828) but grid.rs docs say no library change. Local grid-locks.json is effectively never set true (grid.rs:200; only tests and usb_import.rs:238 call set_locked(true)).
3. PQTZ grid offset: grid.rs read_dat applies grid_offset (grid.rs:306-314). read_beat_grid (commands.rs:1308) used by track_beats (1280) and deck_load does not. So the drawn grid and the editor's view disagree by the offset until the first edit. The edit writes beat_grid_section (rbl-anlz write.rs:54-58), which zeroes the offset, so the grid visibly shifts by the old offset after the first edit. Test with a track whose PQTZ offset ≠ 0.
4. Mixer state is not read back on mount (MixerStrip.tsx:58-59). Crossfade is reset to 0.5 every mount (202-208).
5. set_crossfade, set_channel_*, set_master_level, deck_key_shift, deck_tempo, etc. call player.engine(), so they open the audio device (commands.rs 1572-1650 and onward). Contradicts player.rs:4-6 ("opens the device the first time a deck is given something to do"). Also useMaster calls setMasterLevel on boot when remembered (useMaster.ts:184-186).
6. Preview bypasses master limiter and metronome; master gain is a snapshot at play time (preview.rs:127-130).
7. Preview and decks each open their own CpalSink on the same device (two streams).
8. scrubEnd rounds the final seek with Math.round (usePlayback.ts:812), while scrubTo/seek comments say "not rounded" (usePlayback.ts:638, 704). Minor (≤1 ms).
9. TEMPO_RANGES = [6,10,16,"wide"] (lib/player.ts:817), comment says ±20 (lib/player.ts:810-811).
10. clock.ts header says rate is 1 until tempo ships (clock.ts:26-29). Stale: rate = deck.tempo (usePlayback.ts:412).
11. Ticker tail comment says 400 ms (player.rs:~416-420); code stops after 5 deck-tick passes ≈ 500 ms (player.rs:441).
12. Waveform detail fetches whole tag (WaveformDetail.tsx:49). Backend comment assumes windowed fetch and a 64 KB cap (commands.rs ~125-133). No cap found in code. Verify what limit Tauri enforces.
13. Dual layout: loops, AU/MA, beat-loop length, hot-cue pads and RELOOP are not reachable with the mouse; DualDeck comments say "not built" (DualDeck.tsx:191-207). KEY SYNC disabled with a stale reason (DualDeck.tsx:83-97).
14. EQ band knobs and ISOLATOR switch exist in the backend (set_channel_band, set_eq_curve) and in client.ts, but the UI has no controls for them. The HIGH/MID/LOW buttons are kill toggles.
15. TempoField.tsx (231 LOC) is dead code.
16. Jump size is not persisted, and cycleNext helper is unused.
17. Quantize, loop length, GRID mode and cue point reset on every mount. Only layout, zoom, dual control and traffic light persist.
18. "RST" in the zoom column is a label, not a button.
19. Overview "played" shading is a bar below the waveform (scrubFill), not a dimmed waveform.
20. Clicking the overview scrubs; clicking the detail toggles play only when the pref is on, and never seeks.

=====================================================================
PERSISTED SETTINGS SUMMARY
- localStorage "rbl.session": layout, waveformZoom{a,b}, dualControl, trafficLight, tree and columns (non-player).
- localStorage "rbl.preferences": view.{waveformColor (3band default), overviewWaveform ("half"), keyDisplay ("classic"), hotCueColor ("colorful"), beatCount ("position"), waveformClick (true), tempoSlider (false), showBpmChanges (true), phraseFull (true), phraseLabels (true), vocalFull (true)}; audio.{sampleRate 48000, bufferSize 512, metronomeSound 2, metronomeVolume "large"}; advanced.{syncType "beat", syncDoubleHalf true, quantizeBeat "1/1", recordHistory true}; keyboard.overrides.
- localStorage "rbl.master-level.v1": linear gain.
- localStorage "rbl.limiter.v1": {enabled false, inputGainDb −4, ceilingDb 0, releaseMs 250}.
- Not persisted: deck tracks, quantize, loop length/mode, GRID pad mode, cue point, jump size, mixer trim/kill/crossfade, audio output device choice (in the Rust Player only; no prefs key), preview.
- Grid locks: DB djmdContent.Analysed bit 0x80 (rekordbox-visible). Also app file grid-locks.json (effectively unused).
- Grid undo/redo: in memory only (cap 100).

FILE INDEX (absolute)
/Users/jakedavis/Projects/rbxport/src/views/player/Player.tsx (2582), DualDeck.tsx (243), MixerStrip.tsx (257), WaveformDetail.tsx (234), VocalStrip.tsx (107), SimplePlayer.tsx (218), useHotCues.ts (87), useMemoryCues.ts (128), useCueWriter.ts (59), useGridEditor.ts (145), useTrackGrid.ts (86), useTrackCues.ts (80), useHoldRepeat.ts (70), TempoSlider.tsx (73), TempoToggle.tsx (77), KeyShift.tsx (25), TimeReadouts.tsx (30), JumpMenu.tsx (92), CueColorMenu.tsx (56), DeckInfo.tsx (62).
/Users/jakedavis/Projects/rbxport/src/lib/player.ts (933), clock.ts (98), sync.ts (201), layout.ts (44), shortcuts.ts (602), gridEdit.ts (150), cues.ts (120), volume.ts (48), vuMeter.ts (87), session.ts (≈240).
/Users/jakedavis/Projects/rbxport/src/store/usePlayback.ts (887), usePreview.ts (143), useMaster.ts (262), MasterOutput.tsx (51), useLimiter.ts (116).
/Users/jakedavis/Projects/rbxport/src/canvas/waveform.ts (817).
/Users/jakedavis/Projects/rbxport/src/views/browser/WaveformPreview.tsx (282).
/Users/jakedavis/Projects/rbxport/src/views/settings/AudioPane.tsx (255).
/Users/jakedavis/Projects/rbxport/src/views/topbar/LayoutMenu.tsx (99), VolumeKnob.tsx (123).
/Users/jakedavis/Projects/rbxport/src/app/App.tsx (2646).
/Users/jakedavis/Projects/rbxport/src/ipc/client.ts (player commands 302-372; edits 530-552), types.ts (DTOs 823-1000, Tick 953, DeckTick 926, Meters 974, GridEdit 1477, Cue 1002, Phrase 1125).
/Users/jakedavis/Projects/rbxport/src-tauri/src/player.rs (577), preview.rs (210), grid.rs (1029), cues.rs (493), analysis.rs (573), commands.rs (3049; deck block 1280-1930; record_play 2857).
/Users/jakedavis/Projects/rbxport/crates/rbl-deck/src/* (lib.rs 1114, sink.rs 456, mixer.rs 595, limiter.rs 742, metronome.rs 301, scrub.rs 1448, deck.rs 738, clock.ts 352, stretch.rs 704, rubberband.rs 242), build.rs, Cargo.toml.
/Users/jakedavis/Projects/rbxport/crates/rbl-app/src/media.rs (waveform_bytes), events.rs (EventSink/AppEvent 12-54).
/Users/jakedavis/Projects/rbxport/crates/rbl-ffi/src/events.rs (33), core.rs (207), types.rs (416).
/Users/jakedavis/Projects/rbxport/crates/rbl-db/src/write.rs (record_play 1909; set_analysis_lock 1828; save_grid_revision 1811; append_play 2869).
/Users/jakedavis/Projects/rbxport/crates/rbl-anlz/src/write.rs (beat_grid_section 54-68), lib.rs (grid_offset 531, DRAWN_CUE_COLOURS 300).