# Phase 6 — app chrome spec

## Orchestrator decisions (override the findings below where they conflict)
- **Preferences:** a SwiftUI `Settings` scene with one pane per React pane, backed by an `@Observable` preferences
  store in UserDefaults that keeps React's keys/defaults (src/lib/preferences.ts) and sanitises on read. Panes that
  belong to other phases (Audio, Link, USB export, DJ System) host the controls those phases built or will build.
  Existing ad-hoc View-menu prefs (key display, waveform colour, row size, playlist counts) move into the store.
- **Menus:** SwiftUI `Commands` mirroring menu.rs/nativeMenu.ts, with live enable state and undo/redo labels.
- **Keymap:** one dispatcher (local NSEvent monitor or `.onKeyPress`) driven by a binding table ported from
  shortcuts.ts, with `keyboard.overrides`, conflict detection, and the Keyboard pane UI.
- **Backups:** UI over rbl-app's existing backups (start/cancel/list/delete/set directory/progress). No Sentry anywhere.
- **Bug report:** native window showing diagnostics (app_diagnostics) + "Reveal log" + "Copy report"; no network upload.
- **AppleScript:** option (b) — Swift Cocoa Scripting against the existing `rbxport.sdef`; port model.rs mappings.
- **i18n:** a script converts public/locales/* to a String Catalog; English strings in the Swift UI use
  `String(localized:)` with matching keys where they exist. Do it last (6d) so new strings are included.
- **Startup:** library-problem view and the new-library flow (create_library). This machine has a library, so test the
  new-library path only against a temp dir via RBXPORT_OPTIONS / fixtures.
- **Slices:** 6a = Settings scene + preferences store + menu bar + keymap. 6b = backups pane + bug report window +
  startup/problem/new-library UI + window geometry. 6c = AppleScript. 6d = i18n.
- **Testing safety:** backups and restore are exercised against fixtures only; never restore over the real library.

Phase 6 (app chrome) functional spec for rbxport. Read-only exploration; no files written. Paths are absolute under /Users/jakedavis/Projects/rbxport. Tags: [OBS] = seen in code, [ASSUME] = inferred or from a comment, [GAP] = missing or inconsistent.

Context: macos/PLAN.md defines Phase 6 as Settings scene (all prefs panes), menu bar commands, keymap, backups, bug report window, AppleScript (.sdef + Rust Cocoa scripting or move to Swift), and String Catalogs from the 17 locales. The current macos/App/RbxportApp.swift is a spike: one WindowGroup (min 900x500) and a few CommandGroups (Find, Key Display, Waveform Color, Row Size, Show Track Filter, Show Information, Show Playlist Counts). It has no Settings scene.

=====================================================================
1. PREFERENCES WINDOW
=====================================================================
Files: src/views/settings/Preferences.tsx (sidebar, tab strip, search, reset), PreferencesWindow.tsx (the standalone window wrapper), controls.tsx (Section, Sub, Toggle, Checkbox, Radios, Select, Slider, Button, Note, Separator), one file per pane. Model and defaults: src/lib/preferences.ts (DEFAULT_PREFERENCES, sanitisePreferences). Store: src/store/usePreferences.ts.

Windowing: src-tauri/src/preferences.rs. Label "preferences". Content 798x800, min 798x480, resizable, macOS Overlay title bar with hidden title, menu hidden. Singleton: if the window exists it gets location.hash = '#preferences/<pane>?open=<now>' and is focused. Otherwise it is built at index.html with an init script that sets '#preferences/<pane>'. The pane name is stripped to alphanumerics. Escape closes. Windowed mode draws its own title bar ("Preferences"); the in-app modal has a backdrop. The main window's close also closes the preferences and sync windows, and closing the main window quits the app [OBS, src-tauri/src/lib.rs:328].

Storage: one JSON blob in localStorage key "rbl.preferences". Sanitised on load, so a missing or invalid value falls back to the default. Same-window updates dispatch a "rbl-preferences" event. Other windows get the browser "storage" event. reset(pane) writes DEFAULT_PREFERENCES[pane] back. Scripts see a backend mirror (see section 6).

Sidebar order [OBS, Preferences.tsx PANES]: View, Audio, Analysis, DJ System, Keyboard, Advanced, then an "RBXport" group heading above Rekordbox, Rekordbox, PRO DJ LINK, USB Export, Backups, About. PLAN and CLOUD are deliberately absent.
- A search box filters sections by case-insensitive text match on section text.
- "Report bug" button at the bottom of the sidebar opens the report window (section 5).
- "Reset to defaults" button applies to these panes only: view, audio, analysis, djSystem, advanced, usbExport, rekordbox. Keyboard has its own "Reset to the preset". [GAP] Resetting View also resets preferences.view.locale (language) and view.shortcuts (tree rail shortcuts), because they live in the same section.

Initial pane: View by default. The "Missing File Manager" menu item opens Advanced. Library Protection from the status bar opens Advanced > Browse.

--- View (view.*), three tabs ---
Display Type tab:
- Language: select of 18 choices with native labels (LANGUAGE_CHOICES in src/i18n/index.tsx). Key view.locale, default "en". Changes UI language live.
- Show Tooltips: toggle, view.tooltips, default off.
- Browse FontSize: 5-stop slider (scales 0.8,0.9,1,1.15,1.3), view.browseFontSize, default stop 2. Bold: toggle view.browseBold, default off. Line Space: 5-stop slider view.browseLineSpace, default 2. (Browser look; not specced here.)
- RBXport VU Meter: radio normal | fabulous, view.vuMeter, default normal.
- Key display format: radio classic | alphanumeric (view.keyDisplay, default classic). Sort keys: radio alphabetical | musical (view.keySort, default alphabetical). Sanitising forces musical when the display is alphanumeric and keySort is invalid.
- Full/Preview Waveform: radio half | full (view.overviewWaveform, default half).
- Beat Count Display: radio position | toMemoryBars | toMemoryBeats (view.beatCount, default position). Affects the count beside the playhead on the enlarged waveform.
- Click on waveform for PLAY and CUE: toggle "Enable", view.waveformClick, default on.
- Traffic Light: select same | related1 | related2 | related3 (view.trafficLight, default related3).
Layout tab:
- Media Browser > Explorer: checkbox view.explorer, default on.
- Browser panel: Display Cue Markers on Preview (previewCueMarkers, on); Display All Tracks in the Playlists (allTracks, on); Display the number of tracks in a playlist on the Tree View (playlistCounts, off).
- Waveform > Show BPM changes: view.showBpmChanges, default on.
- Phrases > Phrase (Full Waveform) view.phraseFull (on); Always show types of phrases view.phraseLabels (on, disabled when phraseFull is off).
- Vocal > Vocal (Full Waveform) view.vocalFull (on).
- Browser section: buttons "Reset columns" and "Reset panel sizes". Not stored in preferences. Main-window state; the standalone window sends requestPreferencesReset("columns"|"layout") over the backend.
Color tab:
- Appearance: Dark | Light radio. Light is greyed and non-functional (the light theme is not built).
- Waveform color: BLUE | RGB | 3Band, view.waveformColor, default 3band.
- HOT CUE color: COLORFUL | CDJ, view.hotCueColor, default colorful.

Related: the Layout > Media Player > "Display Tempo slider" menu item toggles view.tempoSlider (default off).

--- Audio (audio.*, limiter) ---
Single "Configuration" tab.
- Audio output device: select "System default — <name>" plus each device from backend.audioDevices() {devices, default, chosen}. Choosing calls setAudioDevice(id|null). Not a stored preference; the engine holds it. If there are no devices a note says this build has no audio engine.
- Sample Rate: select 44100 | 48000 | 88200 | 96000 Hz, audio.sampleRate, default 48000.
- Buffer size: slider over stops 64,128,256,512,1024,2048, audio.bufferSize, default 512.
- Both go to backend.setAudioConfig(sampleRate, bufferSize) at start and on change (App.tsx ~line 476).
- Metronome: select Click Sound 01 | 02 | 03, audio.metronomeSound, default 2. Volume: Small | Middle | Large, audio.metronomeVolume, default large. Both go to setMetronome(sound, volume).
- RBXport Master Limiter (not stored in preferences; engine state, store src/store/useLimiter.ts): Enable limiter (default off); Limiter input gain -24..+24 dB, step 0.1, default -4; Limiter ceiling -12..0 dBFS, step 0.1, default 0; Limiter release 10..1000 ms, step 10, default 250; "Reset settings" button. Read-only status line: Off | Ready | Limiting, with a gain-reduction meter and per-channel output meters (VU). Commands: master_limiter / set_master_limiter, set_master_level.

--- Analysis (analysis.*) ---
- Analysis mode: select "Rekordbox · Normal" | "RBXport (for Electronic Music)", analysis.mode, default rbxport. Explanatory text is shown per mode.
- Tracks analysed at once: select 1..4, analysis.concurrentTracks, default 3 (SLOTS).
- Automatic analysis: toggle analysis.auto, default off. Consumed in App.tsx on import: imported tracks are sent to analysis.add().

--- DJ System (djSystem.*) — stick defaults, brief ---
General: waveform color on CDJ (BLUE|RGB|3Band, default 3band); Waveform Current Position (LEFT|CENTER, default center); Overview (half|full, default half); Key display (classic|alphanumeric, default classic).
Category and Sort tabs edit record lists (djSystem.categories and sorts, null = rekordbox reference rows). Column tab: default right column (subColumn: null = "Not Specified" or a sort item).
These defaults are sent as one object (stickDefaults) with syncDevices and writeDeviceDefaults. createDatabaseFolders, linkInterface, autoJoinLink and linkKeySort are also djSystem fields.

--- Keyboard — see section 3.

--- Advanced (advanced.*, plus library facts), three tabs ---
Database tab:
- Library facts from librarySummary: Tracks, Playlists, Database version, Editing (Read-only — rekordbox is running | Protected — see Browse | Available).
- Duplicates: "Find duplicates" calls findDuplicates(20). Lists groups of tracks sharing title and artist, with per-copy "Remove". Remove asks confirm() ("This can't be undone. The file stays where it is.") then calls edits.removeFromCollection([id]). Disabled when read-only or protected.
- Auto Relocate Search Folders and Missing files: code exists but hidden by MISSING_FILES_ENABLED = false (AdvancedPane.tsx:32). The File menu item is gated by MISSING_FILE_MANAGER = false in menu.rs. Backing commands still exist: missing_tracks, relocate_track, auto_relocate. Stored key advanced.relocateFolders.
Browse tab:
- Library Protection: "Protect library edit." toggle, advanced.protectLibrary, default ON. Turning it off: if listBackups() returns any backup, it turns off. If there are none, a dialog appears: "It looks like you haven't made a backup yet. We strongly recommend creating one before using RBXport." with "Unlock anyway" / "Cancel".
- Edit Library: "Double-click to edit", advanced.doubleClickToEdit, default off (off = single click on a selected row).
Others tab:
- History: "Record play history", advanced.recordHistory, default on.
- QUANTIZE BEAT VALUE: select 1/1 | 1/2 | 1/4 | 1/8, advanced.quantizeBeat, default 1/1 (used by Player).
- BEAT/BPM SYNC: Sync Type radio BEAT SYNC | BPM SYNC (advanced.syncType, default beat); "Allow BEAT/BPM SYNC with double/half BPM." (advanced.syncDoubleHalf, default on). Both used by Player.
Update settings are in About, not here (checkUpdates, updateFrequency start|daily|weekly).

--- Rekordbox (rekordbox.syncBrowseSettings) ---
Single switch "Keep browse settings synchronized", default on. Imports column visibility, order and widths, plus browser pane widths, from rekordbox at start (rekordboxBrowse.ts reads the preference at startup; backend command rekordbox_browse_settings).

--- PRO DJ LINK (LinkPane.tsx) — brief ---
LINK on/off button (startLinkExport / stopLinkExport; status via linkStatus and onLinkStatus). Auto-join LINK when available (djSystem.autoJoinLink, default off). Key sort radio (djSystem.linkKeySort, default musical). Network interface table: Automatic (djSystem.linkInterface null) or each system interface; a saved interface that is absent shows "Not present". Devices table.

--- USB Export (UsbExportPane.tsx) — brief ---
- Setup PIONEER folder on USB drives: djSystem.createDatabaseFolders, default on.
- Automatically import CDJ/mixer settings when syncing: usbExport.importSettings, default off.
- Automatically import play history when syncing: usbExport.importHistory, default on.
- Import cues and beat grids / Import play history / Import CDJ/mixer settings (ticked when Sync Manager opens): usbExport.importButtonCues (on), importButtonHistory (on), importButtonSettings (off).
- Delete music not in any playlist: usbExport.deleteUnlistedMusic, default off.
- Maximum CDJ compatibility: usbExport.maximumCompatibility, default off. Convert to WAV | AIFF | MP3 (usbExport.conversionFormat, default wav), disabled unless compatibility is on.

--- Backups — see section 4. ---

--- About (AboutPane.tsx) ---
- Name "rbxport", version from appVersion (shows "—" on failure).
- "Check for updates" button. Toggle "Download updates" (advanced.checkUpdates, default on). Update frequency: After startup | Daily | Weekly (advanced.updateFrequency, default start), disabled when updates are off.
- Progress bar and text for update downloads. The whole updater is dropped in the port (see section 8).
- "Support rbxport" heading and a button that opens https://www.paypal.com/donate/?hosted_button_id=H6GGU8PHP8CJE.
- Two disclosures: Licence (GPL-2.0-or-later; Rubber Band Library under the same licence) and Disclaimer (not affiliated with AlphaTheta / Pioneer DJ; trademarks; back up before writing).
- Author links (icon buttons, all open via openUrl): Instagram, TikTok, Twitch, Discord, GitHub (github.com/chrisle), Web (triodeofficial.com).
- Footer "Made by TRIODE with ♥ in California".

Backend calls in these panes (summary): audioDevices, setAudioDevice, setAudioConfig, setMetronome, master_limiter, set_master_limiter, set_master_level, referenceStickSettings, linkStatus, onLinkStatus, startLinkExport, stopLinkExport, librarySummary, findDuplicates, missingTracks, relocateTrack, autoRelocate, pickFolder, listBackups, removeFromCollection, rekordboxBrowseSettings, appVersion, checkForUpdate, downloadUpdate, readyUpdate, onUpdateProgress, openUrl (https only), openBackupDirectory, backupSizes, backupProgress, startBackup, cancelBackup, deleteBackup, setBackupDirectory, confirm.

=====================================================================
2. MENU BAR
=====================================================================
Files: src-tauri/src/menu.rs (build, build_with_labels, set_menu_labels, set_history_menu, on_event). Frontend: src/lib/menu.ts (resolveMenu, menuCommand, refusal), src/lib/nativeMenu.ts (nativeMenuLabels). App wiring: src/app/App.tsx runMenu (~line 1699), label push (~line 127), listener (~line 1775). Undo/Redo labels: src/lib/editHistory.ts.

Structure (macOS):
- rbxport (app menu): About rbxport (predefined) | Check for Updates… (id "updates") | separator | Settings… ⌘, (id "settings") | separator | Hide rbxport ⌘H, Hide Others ⌥⌘H (predefined) | separator | Quit rbxport ⌘Q (predefined). [ASSUME: predefined accelerators are Tauri defaults.]
- File: Import ⌘O ("import") | Import Folder… ⇧⌘O ("import-folder") | Import rekordbox xml… ("import-xml") | Import iTunes Library xml… ("import-itunes") | Export Collection in xml format… ("export-xml") | [Missing File Manager ("missing"), compiled out] | separator | Close Window ⌘W (predefined).
- Edit: Undo ⌘Z ("undo") | Redo ⇧⌘Z ("redo") | separator | Cut ⌘X, Copy ⌘C, Paste ⌘V, Select All ⌘A (predefined, so macOS sends them to the webview fields).
- View: Layout ▸ [Media Player ▸ Display Tempo slider ("tempo-slider")] | Information Window ⌘I ("info") | Sub-Browser Window ⌘B ("sub") | separator | Full screen ⇧⌘F ("fullscreen") | separator | 1 Player ⌘7 ("layout-one") | 2 Players ⌘8 ("layout-two") | Simple Player ⌘9 ("layout-simple") | Full Browser ⌘0 ("layout-browser").
- Help: Report bug… ("report-bug") only.

Dispatch: on_menu_event sends every id to the frontend as one "menu" event carrying the id. Exception: "fullscreen" is handled in Rust. It toggles fullscreen on the "main" window and emits nothing. test_port also calls on_event.

Frontend rules (resolveMenu):
- Items marked writes=true: import, import-folder, import-xml, import-itunes, missing. When readOnly is true they are refused, and the refusal goes to the status bar as a red note. Text: "Editing is locked by Library Protection. Turn it off in Preferences to edit." when protection is on; otherwise "Editing is locked while rekordbox is running. Quit rekordbox to enable editing."
- Not writes: settings, export-xml, info, sub, layout-*, report-bug, tempo-slider, updates.
- Actions: settings → openPreferences("view"). info and sub toggle panels. layout-* → setLayout. tempo-slider toggles view.tempoSlider. report-bug → openReport. updates → checkForUpdates(true). missing → openPreferences("advanced") (unreachable).
- Undo/Redo: if focus is not in a text field, no deck or grid editor owns history, and the library stack can undo/redo, the library edit history runs. Otherwise runEditHistory (execCommand in text fields; otherwise a window event to the deck).
- Native items are never greyed out. Enablement is handled by refusal messages, not by the menu. [GAP] Undo/Redo are never disabled and do nothing when empty.

Labels (set_menu_labels): App.tsx calls setMenuLabels(nativeMenuLabels(t)) whenever the locale changes. It sends 36 keys (About rbxport, Settings…, Check for Updates…, Hide rbxport, Hide Others, Quit rbxport, File, Import, Import Folder…, Import rekordbox xml…, Import iTunes Library xml…, Export Collection in xml format…, Missing File Manager, Close Window, Edit, Undo, Redo, Cut, Copy, Paste, Select All, View, Layout, Media Player, Display Tempo slider, Information Window, Sub-Browser Window, Full screen, 1 Player, 2 Players, Simple Player, Full Browser, Help, Report bug…). The menu is rebuilt from scratch with app.set_menu. Empty or missing keys fall back to the English key.
[GAP, inferred, not run] A rebuild resets Undo/Redo titles to plain "Undo"/"Redo". They come back only when setHistoryMenu runs again on focus change.

History labels (set_history_menu): editHistory.ts calls setHistoryMenu(undo, redo) on focusin/focusout and when library history changes. Labels are null while typing, so the titles stay plain. Otherwise the title is "Undo <action label>" / "Redo <action label>", where the label comes from the focused editor or from the library edit history (undoLabel/redoLabel).

Native port: the spike has no Settings scene and no menu for these items. Note: macOS delivers ⌘ key equivalents from menus before the webview sees them. So a Keyboard-pane override of an accelerator (for example ⌘I, ⌘B, ⌘7-0, ⌘,, ⌘O) does nothing, because the menu takes the key first. The pane does not check for this (section 3).

=====================================================================
3. KEYBOARD MAP
=====================================================================
Files: src/lib/shortcuts.ts (BINDINGS, matchBinding, dispatch, chordFromEvent, describeChord, menuAccelerator, assignChord lives in the pane), src/lib/keymap.ts (KEYMAP display table), src/views/settings/KeyboardPane.tsx. Preferences: keyboard.overrides (Record<bindingId, KeyChord>); KeyChord = {key, metaKey?, shiftKey?, altKey?, ctrlKey?, code?}. Stored as {key:""} for an unbound key (sanitised: key string ≤32 chars, booleans only).

Two tables:
(a) BINDINGS in shortcuts.ts: the live map. About 151 rows by my count. Each has an id, a group (Browse, Player A, Player B, General, Menu), a label, a chord, and optionally an action (what the app does) and a command (rekordbox id). Rows without an action are display-only.
- Browse (17 rows, including aliases): Search ⌘F (focusSearch); Clear Search Esc; Select All ⌘A; Cursor Up/Down; Extend Selection ⇧↑/⇧↓; Page Up/Down; Home/End; ⌘↑/⌘↓ aliases; Analyze Track ⇧⌘A; Load on Player 1 Enter (plus ⇧Enter alias).
- Player A (49, PLAYER_A): Play/Pause Space; Quantize Q; Cue C; Memory Cue M; Loop In I; Loop Out O; Exit/Reloop R; Beat Loops 4-9 (1,2,4,8,16,32); Loop /2 "/", Loop x2 ⌥\; Set Hot Cue A/B/C 1/2/3; Clear Hot Cue A/B/C ⌘1/⌘2/⌘3; Call Next/Previous Memory Cue N/B; Delete Memory Cue X; Jump ←/→; Memory Cue 1-10 A S D F G H J K L ;; Show Memory/Hot Cues/Information F10/F11/F12; Metronome sound F9; Shift Beatgrid left/right ⌘←/⌘→; Shift Beatgrid to center ⌥⌘\; Adjust BPM/BeatGrid ⌘G; SYNC F1; Master Tempo F2; Tempo Reset F3; BPM+ F7; BPM- F6.
- Player B (44, derived): every Player A row except metronome sound, Adjust BPM/BeatGrid and the three Clear Hot Cue rows, shifted (⇧) with ids "b.<action>".
- Unbound app-own rows (empty chord, editable): Low/Mid/High Kill for each deck (6); Set Hot Cue D–H (5 per deck); Clear Hot Cue D–H (5 per deck); Player B also gets Clear Hot Cue A–C (3). That is 10 for Player A and 13 for Player B.
- General: Volume ⌘F12 (volumeUp), Volume Down ⌘F11, Mute ⌘F10.
- Menu rows (no action, not editable): Import File ⌘O, Preferences ⌘, , Information Window ⌘I, Sub Browser ⌘B, 1/2/Simple/Full Browser ⌘7/8/9/0, Full Screen ⇧⌘F.
Matching: matchBinding walks BINDINGS in order, and the first match wins. The chord is compared with overrides[id] ?? default. Primary modifier = ⌘ on macOS (⌃ elsewhere). The other platform's modifier must not be pressed. Shift and option must match exactly. Keys match by KeyboardEvent.code, so shift+1 still matches "1". Typing guard: when focus is in INPUT, TEXTAREA, SELECT or contentEditable, only focusSearch and clearSearch fire. Menu accelerators on macOS are not handled here. On Windows, menuAccelerator() maps ctrl-keys to the same menu ids, because the webview eats them there.

(b) KEYMAP in keymap.ts: the display table for the pane. Rekordbox's Export preset, 138 rows across 10 groups (Browse, Player A, Player B, General, File, View, Track, Playlist, Help, Link Export). 14 rows are unbound (key null, for example 1/64 to 1/2 beat loops and 64 beat loop). Playlist, Help and Link Export are empty. Track has Information Window ⌘I, Undo track load ⌘Z (not built as a key here), Locate track loaded ⌘L, Display in bold ⌘B. General has Quit rekordbox ⌘Q (not built). keyForPlatform swaps command/option for ctrl/alt on Windows.

KeyboardPane behaviour:
- Ten collapsible groups. Opening a group lists its rows. A group with no rows shows "Nothing is bound here in the Export preset."
- A row is "built" when a binding answers its command. Built rows are live; the others are dimmed with the tooltip "rekordbox has this; it is not built here".
- Click a key badge: it shows "…" and listens in capture phase on window. The next chord is stored. Escape cancels and keeps the old key. Backspace or Delete unbinds the row.
- assignChord: the target row gets the chord. Any other action binding with the same chord is set to {key:""} (unbound). It is not swapped. Setting a preset chord back deletes the override. Menu rows cannot be edited.
- "Reset to the preset" clears all overrides (disabled when there are none).
- Changed keys are shown with data-changed.
- Scripts cannot set keyboard.* (excluded in scripting.ts and cocoa model).
Conflict gaps: [GAP] the pane does not check menu accelerators, and macOS takes ⌘ key equivalents from the menu first. [GAP] an override that matches a menu chord is silently dead.

=====================================================================
4. BACKUPS
=====================================================================
Tauri-free core (in crates/rbl-app, whose Cargo description says "Tauri-free"): src/backups.rs (879 lines), backup_copy.rs, backup_zip.rs, backup_sizes.rs, backup_restore_scripts.rs, durable.rs, file_journal.rs. Archive, manifest, summary, sizes, journal and the restore engine are in crates/rbl-backup. Tauri wrappers: src-tauri/src/commands.rs ~2782–2852. Invoke registrations: src-tauri/src/lib.rs (list_backups, backup_directory, open_backup_directory, backup_sizes, backup_progress, start_backup, cancel_backup, back_up_library, delete_backup, set_backup_directory). UI: src/views/settings/BackupsPane.tsx, BackupSizeChart.tsx, src/store/useBackupProgress.ts.

Events: none. [OBS] backups.rs emits no events. Progress is pulled: useBackupProgress polls backup_progress every 500 ms (chained setTimeout). The app-wide event set is library:ready, library:problem, library:changed, tag-list:changed and edit-history:changed (crates/rbl-app/src/events.rs). Changing the pane's list refreshes when progress.path is set.

Progress struct BackupProgress {running, phase, copiedBytes, totalBytes, error, path, currentItem}.
Phases: preparing → copying → compressing → validating → complete (path set) | cancelled | failed(error). "stopping" during cancel.
Labels in the pane: "Backing up your library", "{copied} of {total}", "Removing the unfinished backup…", "Finishing your compressed ZIP backup.", "Checking the saved files before finishing.", "You can keep using RBXport while this runs.", "Stop backup" / "Stopping…".

Start (backups::start): reserves the job under a lock (refuses with "A backup is already running."). Runs on a plain thread inside catch_unwind. Cancel (backups::cancel) sets phase "stopping"; the progress callback then returns Cancelled. Partial .partial-<uuid> dir and archive are removed.

Creation pipeline (create_with_progress), in order:
1. Takes edit_gate and analysis_write. Every library edit is blocked for the whole backup. [OBS]
2. Runs the pending restore journal recovery (rbl_backup::journal) and file_journal recovery.
3. Validates the destination (must not be inside the analysis or artwork folders).
4. Target name rbexport-YYYYMMDD-HHMM.zip (local 24h time). Refuses if the same minute exists: "A backup for this minute already exists. Try again in the next minute."
5. Scans USBANLZ and Artwork trees (TreeCopyPlan), measures master.db, masterPlaylists6.xml, automixPlaylist6.xml.
6. VACUUM INTO partial/master.db; counts via rbl_backup::summary; fsync.
7. Copies analysis and artwork (compressed). Validates master.db with PRAGMA quick_check ("The backup database is damaged." on failure). Removes -shm. Compresses library XML files and master.db.
8. Writes summary.json (rbl_backup::summary v1; sizes, counts, app version) and manifest.json (version 2: library path, createdAt, bytes, includesArtwork, libraryFiles).
9. Writes restore-rekordbox.sh and restore-rekordbox.ps1 (standalone restore scripts with the DB path baked in).
10. Assembles the ZIP (max deflate, parallel), persists the archive under the target name, fsyncs the folder.
Contents: database (playlists, tags, ratings, cues, history, all via one snapshot); PIONEER/USBANLZ (analysis: cues, grids, waveforms, phrases, vocals); PIONEER/Artwork; Sync Manager selections and Automix XML; summary.json, manifest.json, restore scripts. Music files are not included. [OBS] the -wal size is counted in totals but the WAL is not copied separately, because VACUUM INTO folds it in.
Backup is allowed while the library is read-only (test backup_is_available_while_the_library_is_read_only). [GAP] the docs (docs/user/backups.md) say to quit rekordbox first.

List (backups::list): only regular rbexport-*.zip files. Each must have a manifest that belongs to this library. Sorted by createdAt desc, then name desc. Older names (rbxport-backup-*, library-*, master-*) are not listed, but can still be deleted through delete. List holds edit_gate.
Shape: BackupDto {name, path, bytes, createdAt, includesAnalysis, includesArtwork}. Rows show Date, Time, Size, Actions (Delete).

Delete (backups::delete): checked() — managed name, canonical parent equals the destination, not a symlink. Manifest must belong to this library. The pane asks confirm("Delete the backup from {date}? This cannot be undone.") first. Then deleteBackup(path) and an fsync of the folder.

Set directory: "Change folder…" → pickFolder("Choose default backup folder") → set_backup_directory. Refused while a backup runs ("Wait for the current backup to finish before changing its folder."). Canonicalises, rejects analysis/artwork subfolders, checks the folder is writable (probe file), persists to backup-destination.json in the state dir, then publishes. Existing archives stay where they are; only new backups go to the new folder. Failed changes keep the previous setting.

Locations: state dir = dirs::data_dir()/rbxport/backups (env RBXPORT_STATE_DIR overrides). It holds the recovery journals, backup-destination.json, .size-cache.json and the restore journal backup-restore.json. The default destination is the state dir itself until a folder is chosen.
Open folder: open_backup_directory creates the folder if needed and opens it with the opener plugin.

Rekordbox Data bar (BackupSizeChart): backupSizes(refresh) returns categories: Database, Waveform previews, Memory & hot cues, Beat grids, Phrase analysis, Artwork thumbnails, Vocal analysis, Other analysis, plus a total. Cached for 7 days (persisted). Refresh button forces. Label "Rekordbox data size not calculated yet" until computed.
Relative time labels: "just now", "{count} minute(s) ago", "hour(s) ago", "day(s) ago".

Restore: NOT in this repo. The pane tells the user "To restore, quit RBXport and open RBXport Restore…". That app is separate (not found in the tree). Its engine is rbl-backup::restore::restore(Request{archive, parts, location, state_dir, sizes}, guard, progress). Parts: database, analysis, artwork, library_files (Sync Manager selections and Automix). Phases: Preparing, Unpacking, Validating, Replacing. Restore unpacks beside the originals, checks checksums and PRAGMA quick_check, saves the journal, then renames parts into place. An interrupted restore rolls back on the next RBXport or RBXport Restore start (backups::recover runs at startup and before every backup). Each ZIP also carries restore-rekordbox.sh and .ps1 as a fallback.

=====================================================================
5. BUG REPORT AND DIAGNOSTICS
=====================================================================
Files: src-tauri/src/report.rs (window open, report_attachment, open_report_attachment, log_file), src-tauri/src/diagnostics.rs, src-tauri/src/logging.rs, src-tauri/src/sentry.rs, src/lib/sentry.ts, src/lib/bugReport.ts, src/views/report/ReportBug.tsx (+ ReportBug.module.css), src/store/useDiagnostics.ts, src/views/topbar/AppCost.tsx.

Report window: open_report_window → label "report", 660x650, min 480x440, Overlay title bar, menu hidden, opened hidden and shown when ready. Starts at #report. A singleton. Falls back to the in-app modal overlay (ReportBug without windowed) if the window cannot open. Entry points: Preferences sidebar "Report bug"; status bar "Report bug" button (StatusBar.tsx); Help > Report bug… menu.

Form:
- Your email (optional, max 320, type email).
- What happened? (required, max 30000, textarea).
- "Attach log and system information" (checkbox, default on). When on, report_attachment is fetched on open.
- "Show log": writes the attachment to <app cache>/report-attachment.txt and opens it in the default text editor (open_report_attachment). Hint: "The log may include library paths and track titles."
- Human verification: Cloudflare Turnstile in an iframe at https://report.rbxport.com/verify?origin=<app origin>. Turnstile fails on the app's tauri:// origin, so the widget lives on the Worker. Silence for 20 s counts as failure ("no response"). A token is required, and it is reset after each send.
- Footer: "Reports are sent to TRIODE…" plus Close and Send report (disabled until description, token and attachment are ready).
Submit: POST https://report.rbxport.com/ with JSON {email, description, attachment, turnstileToken}. The attachment is "Report details" JSON {email, preferences: loadPreferences()} followed by the base text. Response: {key, url?, attachmentAdded}. url must match github.com/chrisle/rbxport/issues/N. The success view says "Thank you for your report.", shows the URL to bookmark, and offers "Open in browser" (openUrl). Errors are shown inline.
Attachment base text (report_attachment): "System information": rbxport version, OS name and version, arch, audio deadline load %, audio callback overruns, process CPU % of one core, resident memory MiB. Then "Application log (latest file)" with the whole newest rbxport*.log verbatim. A unit test asserts no redaction.
Privacy notes [GAP]: the log is verbatim and may contain paths, track titles and emails. The preferences JSON includes relocateFolders paths, tree shortcut ids and keyboard overrides. The description is posted publicly on GitHub (the form hint says so); email and log are described as private. The Worker source (report-worker/) is not in this repo.

Logging (logging.rs): tracing to stdout and a daily file at <data dir>/rbxport/logs/rbxport.YYYY-MM-DD.log, keeping the last 5. RBXPORT_LOG_DIR overrides the directory. Default level debug for our crates in every build. LOG_LEVEL=error|warn|info|debug|trace overrides it. RUST_LOG, when set, replaces the filter. Dependencies are at warn. The writer is non-blocking. A panic hook logs panics as errors. open_log opens the newest file in the default app. The title bar's status-bar logo offers "Right-click to open the application log."

Diagnostics (diagnostics.rs, command app_diagnostics): the process's own CPU %, audio load, xruns, RSS MB, threads, open files, and gpu (always None on macOS). The title bar AppCost readout shows AUDIO % (deadline usage, tooltip with overruns), RAM, and FPS. FPS is timed in the webview with 2 frames every 5 s (useDiagnostics.ts). Process CPU appears only in the report. app_version returns the package version.

Sentry: used for crash and error reporting only, and off unless a DSN is injected at build time.
- Rust (src-tauri/src/sentry.rs): DSN from SENTRY_DSN at compile time. Release string rbxport@version; environment development|production; send_default_pii false; max_breadcrumbs 0; before_send removes user, request and breadcrumbs. It captures panics and native crashes. capture_internal_error sends the message "internal backend error" with no message text.
- Frontend (src/lib/sentry.ts, main.tsx): VITE_SENTRY_DSN. Off in dev. Only error handlers, no tracing, replay, user, cookies or headers. React onCaughtError and onUncaughtError capture to Sentry.
- Port: drop Sentry. Replacements are the bug report (user-initiated), the rolling log file, and macOS crash reports. The panic hook becomes a log line.

=====================================================================
6. APPLESCRIPT
=====================================================================
Files: src-tauri/rbxport.sdef (dictionary), src-tauri/src/scripting/mod.rs (bridge, requests, errors), src-tauri/src/scripting/cocoa.rs (1635 lines, Cocoa classes and commands, macOS only), src-tauri/src/scripting/model.rs (pure data model: TrackKey, track_value, track_edit, playlist helpers, settings flattening). Frontend: src/lib/scripting.ts (answer, withSetting, whenLoaded, setPlaying, registerDeck), App.tsx ~line 2033 (scriptHandlers). Info.plist: NSAppleScriptEnabled and OSAScriptingDefinition = rbxport.sdef. tauri.conf.json bundles Resources/rbxport.sdef. The macos/ project does not reference the sdef or an Info.plist yet [OBS].

Dictionary (rbxport.sdef, suite "rbxport Suite", code Rbxp):
- Enumerations: track color (no color, pink, red, orange, yellow, green, aqua, blue, purple); playlist kind (regular playlist, playlist folder, smart playlist).
- Application extension: elements track, playlist, deck, device, link player, setting (all read-only except the ones that allow writes). Properties: "link export" (boolean, read/write; turns LINK on or off), "rekordbox running" (boolean, read-only).
- Class track (id, name, artist, album, genre, label, key, bpm, duration, year, rating, color, comment, play count, date added, location, analysed, bit rate, sample rate). Writable: name, artist, album, genre, label, key, bpm, year, rating, color, comment, play count. Responds to load, add, remove.
- Class playlist (id, name, kind (set only at creation), parent). Elements: track (delete takes it out of the playlist), playlist (folder children). Responds to export.
- Class deck (index, current track, playing, player position, duration, tempo %). Responds to play, pause.
- Class device (name, location, removable, capacity, free space).
- Class link player (id = player number, name = model, address).
- Class setting (name "pane.field", value: any). Writes go through preferences.set.
- Commands: play [deck, default deck 1]; pause [deck]; load <track> into <deck|link player>; add <track or list> to <playlist>; remove <track or list> from <playlist>; export <playlist> to <device> (returns text; long export with a timeout block).

Implementation (cocoa.rs):
- Classes: RbxTrack, RbxPlaylist, RbxDeck, RbxDevice, RbxLinkPlayer, RbxSetting, all define_class! objc2 subclasses of NSObject with ivars. Six NSScriptCommand subclasses: RbxPlayCommand, RbxPauseCommand, RbxLoadCommand, RbxAddCommand, RbxRemoveCommand, RbxExportCommand. Each overrides performDefaultImplementation.
- Cocoa key-value: each class overrides valueForKey: and setValue:forKey: for the rbx* keys, and falls back to super. objectSpecifier builds uniqueID or name specifiers.
- The application object (NSApplication) is extended at runtime via objc2::ffi::class_addMethod: rbxTracks, rbxPlaylists, rbxDecks, rbxDevices, rbxLinkPlayers, rbxSettings, rbxLinkExport (get/set), rbxRekordboxRunning, and value-in/insert/remove methods (inserts and removes are refused).
- Reads answer on the main thread from in-memory state: state() (AppState library), library(), decks, devices, link. Writes:
  - write_now (KVC setters: rating, comment, color, fields): refuses under protection, then blocks the main thread on a channel until the backend write finishes. Safe because the backend never waits on the main thread.
  - write_later (commands add, remove, delete): refuses under protection, then defer(): suspendExecution on the command, run the work on Tauri's async runtime, then resume on main with the result. Multiple work items per command are counted.
  - Edits call the same Tauri commands the UI uses: set_track_rating, set_track_comment, set_track_color, details::set_track_field, add_tracks_to_playlist, remove_tracks_from_playlist, delete_playlist.
- Window requests (ask_window): play, pause, deck.load, link.set, preferences.set, export. These go through Bridge.ask (below).
Errors (ScriptError, Apple event codes): failed -10000; not modifiable -10003 (ReadOnly errors and protection); no such object -1728; wrong type -1703; missing parameter -1715. Messages are the backend messages.

Bridge (scripting/mod.rs):
- Bridge.ask emits "script:request" {id, action, args} to the window labelled "main", then blocks on an mpsc channel. Timeout: 30 s (ANSWER_TIMEOUT); export 6 h (EXPORT_TIMEOUT). Refused before the window says it is ready: "rbxport's window is still starting. Try again in a moment."
- Window side (App.tsx scriptHandlers): deck.load {deck,row} loads the track and waits up to 15 s (whenLoaded). deck.play and deck.pause. link.set {on}. preferences.set {path, value} runs withSetting (validates; rejects keyboard and unknown keys) and returns the full set. export {playlist, device} runs writeToDevice. The window replies with script_reply(id, value|error). It announces itself with script_ready.
- Preferences mirror: script_preferences is sent whenever preferences change. refuse_if_protected reads it. Missing mirror = refused as "still starting".
- Reads never reach the window; the backend answers them directly.
- Devices are cached off the main thread; devices:changed refreshes them.

Round trip today: a script that changes something the window owns (PLAY, load, LINK, a preference, export) goes script → cocoa.rs → Bridge.ask → emit → webview handler → script_reply → mpsc → resume on main.

Options for the native port:
(a) Keep the Rust Cocoa scripting registered from the Swift app. Rust's objc2 code stays. Swift calls an install entry point, and the Rust side keeps its request bridge. Problems: cocoa.rs is wired to Tauri throughout (AppHandle, State, run_on_main_thread, emit_to, and the crate::commands functions with Tauri State). Reimplementing the bridge is needed anyway, because the "window" becomes Swift state (AppModel) and a request/reply through Rust makes no sense in-process. It would mean two runtimes and unsafe glue in Rust for something Swift does natively, with the NSScriptCommand suspend/resume semantics crossing the FFI.
(b) Reimplement in Swift against the FFI. Use NSScriptCommand subclasses (@objc(RbxPlayCommand) etc.) and @objc NSObject classes with KVC overrides. Put the NSApplication keys in an NSApplication subclass (Info.plist NSPrincipalClass) or an @objc extension, as a [ASSUME] to verify. Reads come from rbl-ffi and writes from the Backend actor. Window actions (play, load, LINK, preferences, export) call AppModel directly on MainActor, so there is no request/reply hop. Keep rbxport.sdef as the contract; map ScriptError codes to scriptErrorNumber.
Recommendation: (b). The bridge exists only to reach the webview, and in the native port the state lives in Swift. Cocoa Scripting is Objective-C runtime work that Swift does directly, and the sdef is the stable contract either way. Keep the Rust model.rs logic only as a reference for the mappings and the settings flattening. Test with osascript against a fixture library.

=====================================================================
7. i18n
=====================================================================
Runtime (src/i18n/index.tsx): a catalog keyed by the English source string. translate(): exact match first, then template match. Placeholders are {name}; each becomes a regex group (.+?) in order. useTranslation() returns t(text, values) which replaces {name} with values. Localization also rewrites DOM text nodes and aria-label, placeholder and title attributes via MutationObserver. Elements with data-i18n-ignore or script/style/contenteditable are skipped. Catalogs are fetched from locales/<locale>.json. "en" uses no catalog. Locale is view.locale in preferences.

Locales (LOCALES in src/lib/preferences.ts): 18 values including en. Catalogs exist for 17: fr, de, es, it, nl, ru, pt, sv, da, tr, el, hu, cs, zh-CN, zh-TW, ko, ja. LANGUAGE_CHOICES gives native labels: English, Français, Deutsch, Español, Italiano, Nederlands, Русский, Português, Svenska, Dansk, Türkçe, Ελληνικά, Magyar, čeština, 简体中文, 繁體中文, 한국어, 日本語.

Files:
- src/i18n/en.json (9 KB, nested): $comment plus rekordbox's wording by category (action 24, column 39, menu 7, tree 20, rail 11, deck 10, filter 21, device 48, info 56; 237 leaves). Used by scripts/build-locales.mjs to decide which keys are wanted. Not loaded at runtime.
- src/i18n/ui.json (38 KB): a sorted flat array of 1,388 strings. It is generated by build-locales.mjs from TS string literals, JSX text and attributes, and Rust error strings. Noise is included: CSS variables ("--cols"), "#root missing…", "./backend-mock". src/i18n/index.test.ts asserts each ui.json key is present in every catalog.
- public/locales/<locale>.json (75–119 KB each): flat objects {English source: translation}. Each has 1,451 to 1,464 entries, including 28 keys with {placeholders}. Built by build-locales.mjs from rekordbox's installed *.lang files (in /Applications/rekordbox 7/...), with per-language overrides (for example de "Backups" → "Sicherungen"). The script throws unless --translate-missing is given (Google Translate). Existing translations are kept. fill-missing-locales.mjs fills gaps with English without network. Source for a rebuild is an installed rekordbox 7.

Pluralisation: none. There are no plural rules or CLDR categories. Plurals are separate English source keys chosen in code by count === 1: "{count} minute ago" / "{count} minutes ago", same for hour and day. Other plurals are inline English ternaries, for example AdvancedPane.tsx "{n} title{s}" / "cop{y|ies}" and "track{s}" for missing files. Those cannot be localised as they stand.

Count: 1,388 UI strings × 17 locales, plus the English keys. 1.5 MB JSON total.

Converting to .xcstrings (plan):
- Keep English source strings as keys. That is already the design, and it matches how SwiftUI LocalizedStringKey and String(localized:) look things up.
- Script (Node, reads only the repo): read src/i18n/ui.json as the key list. For each locale, read public/locales/<loc>.json. Emit Localizable.xcstrings: {sourceLanguage: "en", strings: {key: {localizations: {<loc>: {stringUnit: {state: "translated", value}}}}}}. Skip a locale value that equals its key (no real translation); leave it untranslated or mark needs_review.
- Placeholders: convert {name} to positional printf specifiers (%1$@, %2$lld, %3$.1f) using the order in the source key. Check that each translation keeps the same set of names, and fail on mismatch.
- Plurals: merge each "X"/"X s" pair (minute/hour/day ago, plus the {count} track pairs in the menu) into one entry with variations.plural (one, other). For ja, zh-CN and zh-TW use only other. Needs a hand-written mapping list.
- Filter noise from ui.json (CSS variables, paths, "#root", "./…", and error-like strings that are not user-facing).
- Keep the menu labels (36 keys) and Rust error strings (from rustErrorStrings) in the same catalog, because NSMenu titles and error messages are localised by catalog too.
- Runtime locale switching: SwiftUI uses .environment(\.locale) from view.locale. AppKit menu titles need a bundle or locale lookup and a menu rebuild on change. [ASSUME] verify String(localized:locale:) behaviour on macOS 15 before relying on it.

=====================================================================
8. STARTUP AND WINDOW CHROME
=====================================================================
Main window (src-tauri/tauri.conf.json): title "rbxport"; 1800x1130; min 1100x700; resizable; centred; titleBarStyle Overlay; hiddenTitle; acceptFirstMouse; visible false; dragDropEnabled false. CSP: default-src 'self'; img/media from rbl: asset: data: blob:. Swift spike: WindowGroup min 900x500.
Other windows, all created hidden (overlay title bar on macOS):
- Preferences (preferences.rs): 798x800, min 798x480.
- Sync Manager (sync_window.rs): 1440x620, min 720x420, title "Sync Manager".
- Report (report.rs): 660x650, min 480x440.

Geometry (lib.rs window_geometry, windowfit.rs):
- tauri-plugin-window-state saves all flags except VISIBLE (WINDOW_STATE). It skips initial restore for "main", which is restored by hand in on_window_ready.
- fit_window clamps the window to the monitor's work area (excludes menu bar and Dock), physical pixels: shrink first, then clamp the position. Runs once at ready and on every Moved or Resized during the first 2 s (SETTLE_WINDOW).
- After settle, Moved and Resized save the window state, throttled to 300 ms. Exit saves too.
- Non-main windows do not restore geometry (they take config defaults).

Reveal: each window calls show_window after React commits (useShowWindowWhenReady). Maximum wait 1000 ms (MAX_WAIT_MS), then shown regardless. Preferences waits for its first librarySummary read. Milestones: startup_milestone("shell-painted") and "first-rows-painted" (main window only), two animation frames after the commit. They only log elapsed ms.

Rust startup order (src-tauri/src/lib.rs run/setup):
logging::install → sentry::install → rbl_app error hook → generate_context → plugins (dialog, opener, updater, window-state, windowfit) → manage AppState, Player, Preview, GridEditor, Updates, TestPort → setup: screen_cache::initialize, test_port (debug only), scripting::install (macOS: registers the Cocoa classes before any Apple Event), spawn_library_load (blocking thread: backups::recover, open_installed_read_only, snapshot cache at app cache library.snapshot validated by fingerprint, else load_with_cue_reader, state.set_library, library:ready; or library:problem), LINK watcher (link:peers), MountWatcher (devices:changed), app menu (menu::build). Then updater clear_stale. On Exit: screen cache saved and update on_exit.

Frontend start (src/main.tsx): #preferences, #sync, #report pick secondary windows (lazily loaded chunk). Main loads syncRekordboxBrowseAtStartup, then mounts App. App (src/app/App.tsx): the session (localStorage "rbl.session") restores the tree and rows, so they show before the library is ready (seed, cleared once summary arrives or the library fails). Status bar shows "Loading the library…" until the summary arrives. It gets playlistTree and librarySummary, then library:ready or polls. library:problem or libraryProblem() sets the state. Devices load after and never block startup.

Library problem UI:
- Missing (LibraryProblemDto::Missing {masterDb}): NewLibraryDialog (modal <dialog>, section 9).
- Failed {message}: the message goes to the status bar error slot (red). No modal. Read-only states: "Read-only — rekordbox is running" in Advanced; status-bar refusals; the hidden override (env RBX_DISABLE_READ_ONLY plus the status-bar gesture) sets read-only false for the session and says "Read-only mode disabled for this session." It is not offered while protection is on.

Update notice (port drops the updater): status bar UpdateReadyNotice (role=status, auto-dismiss after 15 s, "Update ready. Restart to apply.", "What's new", "Restart now"). UpdateManager modal. About pane check/progress. Menu "Check for Updates…". Endpoint download.rbxport.com/latest.json, minisign pubkey, createUpdaterArtifacts. Drop all of this per PLAN.md.

Support rbxport: status bar button (SHOW_MAIN_SUPPORT = true, App.tsx:93) opens https://www.paypal.com/donate/?hosted_button_id=H6GGU8PHP8CJE. Same link in About. Both go through openUrl, which accepts https only.

Status bar pieces: logo right-click opens the log; LINK strip; activity text; error slot; Report bug and Support buttons; AppCost readout (AUDIO, RAM, FPS) in the title bar.

=====================================================================
9. NEW LIBRARY
=====================================================================
Detection (rbl-db, crates/rbl-db/src/new_library.rs): plan() and plan_at(options, default_dir).
- Options file: ~/Library/Application Support/Pioneer/rekordboxAgent/storage/options.json on macOS (overridable by env in rbl-db).
- Default library dir: ~/Library/Pioneer/rekordbox (master.db goes here).
- If options.json exists and its master.db is missing: plan with that path, and do not rewrite options.json. If options.json exists but cannot be read: no plan (a broken install, not a missing one). If there is no options.json and master.db is missing in the default dir: plan with options.json to be written. If master.db exists: no plan (an existing library that will not open is a Failed, never replaced).
- startup (rbl-app/src/startup.rs): on open failure, plan() is consulted. If a plan exists, it reports Missing; otherwise Failed.

UI (src/views/library/NewLibraryDialog.tsx): modal <dialog>, no close button, Escape blocked. Title "No rekordbox Library". Text: "rekordbox isn't installed and there is no rekordbox database. Would you like to create a new database?" Shows the master.db path. Buttons: Create (autofocus; becomes "Creating…" and disabled) and Quit (calls closeWindow). Errors show inline as role=alert. The window has no other way out, and nothing else works without a library.

Command create_library (src-tauri/src/new_library.rs, async blocking):
1. Re-plans. If the library now exists, it does not replace it. It only loads.
2. plan.create: creates share/PIONEER/Artwork and share/PIONEER/USBANLZ beside master.db. Builds the DB in a staging .master.db-* temp dir, then moves it into place with persist_noclobber, so it never overwrites an existing file.
3. Builds the SQLCipher DB with rekordbox's master_schema.sql verbatim and rekordbox's wrapped passphrase constant (REKORDBOX_DP) derived via key::derive_password. Seeds djmdProperty (DBVersion 6000, random numeric DBID, device UUID), 27 browser menu items, 21 categories, 17 sorts, 8 colours (Pink, Red, Orange, Yellow, Green, Aqua, Blue, Purple), My Tag columns (Genre, Components, Situation, Untitled Column) with their tags, a 3-row sampler, 4 related-track presets (year range from the current and previous year), and the "CUE Analysis Playlist" (id 200000).
4. Writes options.json if it was absent (with the DP and share path). Rekordbox then finds it on later starts.
5. Clears library_problem, then calls spawn_library_load, which emits library:ready. The new library is empty (0 tracks, 0 playlists).
Errors: "Could not find where the library should go." (NotFound), "Could not make the library: {e}". The dialog stays open and shows the message.
Native port: the same rbl-db plan and create can be called over the FFI or linked directly. The UI is one modal with Create and Quit.

Port risks and gaps (summary):
- [GAP] Backups hold the edit gate for the whole run, so edits stall during a backup.
- [GAP] Backup docs say quit rekordbox; the code allows it while read-only.
- [GAP] Menu rebuild resets Undo/Redo titles until the next focus change [inferred].
- [GAP] Keyboard overrides cannot touch menu accelerators, and macOS menus win the key.
- [GAP] Report attachment is unredacted and includes the full preferences JSON.
- [GAP] View > Reset to defaults also resets language and tree shortcuts.
- [GAP] English-only plural ternaries in JSX cannot be localised as-is.
- [GAP] Sentry is off by default. Logs are debug-level in release builds.
- [GAP] RBXport Restore source is not in this repo. The restore UI is not specced here.
- The Swift spike has no Settings scene and no Help or File menu items for these commands.