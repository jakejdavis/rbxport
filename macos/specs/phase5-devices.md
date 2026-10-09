# Phase 5 — devices, USB export, Sync Manager, Pro DJ Link spec

## Orchestrator decisions (override the findings below where they conflict)
- **Backend:** move the export/sync glue (commands.rs 483-1230), device_settings.rs, the MountWatcher wiring, eject and
  the link_* commands into rbl-app (e.g. `export.rs`, `devices.rs`) behind `EventSink`, adding AppEvent variants
  DevicesChanged, ExportProgress, ExportDone, SyncProgress, LinkStatus, LinkPeers (payload-only serialization, wire-name
  test). src-tauri keeps thin wrappers; React keeps working.
- **Fixes:** make the eject guard check the real export states (§12 #1). Drop the dead "Setup PIONEER folder" pref from
  the native UI. Keep passing automatic=false.
- **Library writes** (USB import, iTunes import, LINK player edits) must go through the Phase 4 write gate.
- **Slices:** 5a = device list/eject/watcher + Devices sidebar section with a device panel (General/Category/Sort/
  Color/Column tabs over device_settings) + export playlist/tracks to a stick + Sync Manager window (SwiftUI Window
  scene) with progress/cancel/verify/eject-after-sync. 5b = USB import (cues/history/settings) + iTunes column.
  5c = Pro DJ Link: status strip, LINK pane in Settings, master controls, drag-to-load onto players.
- **Testing safety (hard rules):** export/sync/device-settings are exercised only against temp directories (use
  `RB_LITE_FAKE_VOLUMES` for fake sticks). Never write to, format or eject a real mounted volume. Never start LINK on
  the real ports or LAN — use `Interface::loopback()` + `Ports::EPHEMERAL` in tests, and do not press LINK in the
  running app. Library-writing imports only against fixtures.

READ-ONLY spec: devices, USB export, Sync Manager, device settings, USB import, Pro DJ Link (rbxport @ /Users/jakedavis/Projects/rbxport). No files were written. LOC are `wc -l` unless marked approx.

=====================================================================
0. CORRECTIONS TO THE WORKING ASSUMPTIONS (read first)
=====================================================================
- USB export/sync DOES NOT write the library. Verified: rbl-export writes only under `destination` (crates/rbl-export/src/lib.rs:1-10 doc; `publication.stage()`/`under(destination, ..)`). The app side reads the library only through the in-memory index and `state.read_db` (read-only handle, crates/rbl-app/src/state.rs:298). It takes `state.edit_gate` and `state.analysis_write` only to keep reads consistent. The only files it reads outside the stick are the share-tree analysis files and the rekordbox6 My Settings dir (`rbl_core::paths::rekordbox_settings_dir()`, copied to the stick, read-only).
- THREE paths DO write the library and are NOT export:
  1. `import_usb` (cues/beat grids into analysis files + DB, play-history playlists, settings copy into app data). See section 5.
  2. PRO DJ LINK player edits: a player's tag/rating/hot-cue-bank/grid-offset/history edits go through `StateSource::edit` and `history_write` (crates/rbl-app/src/link.rs:194-330) into the library, with events. A player can write to your library while LINK is on.
  3. iTunes import (`import_itunes_selected`, `rbl_db::xml::import`), from the Sync Manager iTunes column.
- `devices:changed` comes from a 2-second poll in the Rust app (not OS notifications): `rbl_devices::MountWatcher` (crates/rbl-devices/src/mounts.rs), started in src-tauri/src/lib.rs:314 with `tauri::Emitter::emit(&emitter, "devices:changed", ())`.
- `src/views/devices/DevicePanel.tsx` does NOT call `ensure_device_library`. The "Setup PIONEER folder on USB drives" switch (`djSystem.createDatabaseFolders`, default true) is written to prefs and never read by any code path. Dead setting.
- Automatic sync: the Rust side stores and returns an `automatic` flag, but no frontend code reads `DeviceSyncState.automatic`, and SyncManager always calls `sync_devices(..., automatic=false, ...)`. The Sync Manager has no "Automatic synchronization" control.

=====================================================================
1. DEVICE DETECTION AND LISTING
=====================================================================
Files
- crates/rbl-devices/src/lib.rs 378 (list, devices_from, inspect, volume_id, is_offerable, display_name)
- crates/rbl-devices/src/mounts.rs 175 (MountWatcher, mounts(), INTERVAL=2s)
- crates/rbl-devices/src/eject.rs 154
- crates/rbl-devices/src/explorer.rs 313 (not reviewed in depth)
- crates/rbl-app/src/browse.rs 441 (list_devices() builds DeviceDto; line 71)
- src-tauri/src/commands.rs 1216-1228 (`list_devices`, wrapped in `blocking`), 1069-1082 (`eject_device`)
- src-tauri/src/lib.rs 314-318 (watcher wiring; `devices:changed` emit)
- crates/rbl-app/src/dto.rs 291-315 (DeviceDto, DeviceExportDto)
- React: src/app/App.tsx (listDevices at 592, 1880, 1918, 2008; devices:changed listener 1953-1975; selectedDevice 1988); src/views/sync/SyncManager.tsx (refreshDevices, devices:changed listener); src/lib/devices.ts (formatSpace, contentsText, deviceId, devicePath, renamedDevice)

Behaviour
- Offerable volumes (`is_offerable`): removable OR macOS /Volumes/* OR /media/*, /run/media/*, /mnt/* OR Windows drive roots other than C. Always excludes "/", /System*, /private*. Dedupe by mount point.
- Watcher: looks every 2 s (SLICE 250 ms). macOS = directory entries of /Volumes; Linux = sysinfo disk list; any change in the sorted mount set emits `devices:changed`. First look is a baseline and is not reported. Env `RB_LITE_FAKE_VOLUMES` (colon-separated dirs) replaces the real list (tests, `pnpm dev`).
- Renames: `volume_id` = `dev:<st_dev>` on unix so the app can match a stick across a rename. Not stable across unplug.
- Device info: name, path (mount point, used as the device identity everywhere), totalBytes, freeBytes, fileSystem (macOS: MS-DOS → FAT32/FAT16 via Disk Arbitration), removable, volumeId, export{tracks, playlists, ours, written} or null. `inspect` reads `<root>/rekordbox/export.pdb` (root = PIONEER or .PIONEER); if `PIONEER/rbxport/manifest.json` exists it is `ours=true` and tracks come from the manifest, otherwise from export.pdb (`ours=false`).
- list_devices is on-demand (panel open, after export, on devices:changed). It is NOT polled, but inspect does disk I/O per stick per call.
- Eject: `rbl_devices::eject::eject(path)` only accepts a path that is a currently-enumerated real volume. macOS `diskutil eject <mount>`; Linux `findmnt` + `udisksctl unmount --block-device`; Windows locks and dismounts via DeviceIoControl (FFI, unsafe block, eject.rs ~line 60-75). Other OS: unsupported stub.
- `eject_device` (commands.rs:1070) refuses when EXPORT_PROGRESS for the path has state "writing". BUG: export states are preparing/checking/copying/database/verifying/publishing; "writing" is only a sync:progress state and never stored in EXPORT_PROGRESS. The guard never fires. The UI disables Eject while `busy`, so only the UI protects it.
- Error strings: "The USB volume is no longer connected." (eject), "That device is no longer connected." (device_sync_state, save_device_settings, etc.).

Commands
- list_devices() -> DeviceDto[]
- eject_device({path: string}) -> void
Events
- devices:changed, payload null. Emitted by MountWatcher only. Consumed by App.tsx (refresh devices list), SyncManager (refreshDevices), and scripting/mod.rs:203 (`app.listen_any` → `bridge.refresh_devices()`).

Tauri coupling
- MountWatcher, list, eject: no Tauri. Only the emit in src-tauri/src/lib.rs:315 and the scripting listener.
- `eject_device` and `list_devices` wrap `commands::blocking` (tauri::async_runtime::spawn_blocking).
Moving to rbl-app: small. Start MountWatcher in rbl-app/startup.rs with an EventSink; add AppEvent::DevicesChanged (payload serializes as unit, i.e. null). Move eject_device and list_devices bodies into rbl-app; replace `blocking` with rbl-app's own blocking helper. The scripting bridge needs to subscribe through the sink fan-out instead of `listen_any`.

=====================================================================
2. EXPORT (playlist, folder, tracks to a stick)
=====================================================================
Files
- crates/rbl-export/src/lib.rs 1796 (export_cancellable line 651, pipeline body ~666-1200, create_library 1287, copy_my_settings 1680, verify/verify_databases/recover 1710-1722)
- crates/rbl-export/src/manifest.rs 235 (MANIFEST_PATH = PIONEER/rbxport/manifest.json)
- crates/rbl-export/src/sync_record.rs 302 (playlists3.sync, playlists3Plus.sync)
- crates/rbl-export/src/reconcile.rs 446 (device-only track reconciliation, preserve DeviceTrack)
- crates/rbl-export/src/snapshot.rs 630, verification.rs 247, ext_pdb.rs 218
- crates/rbl-audio (compatibility conversion; not read)
- src-tauri/src/commands.rs 483-1230 (≈750 lines): export_playlist 483, sync_devices 519, validate_export_files 570, sync_one_device 599, export_tracks_to_device 644, device_sync_state 693, playlists_on_device 752, ExportSelection 776-965 (from_playlists, from_playlists_and_tracks, for_stick), source_track 966, EXPORT_PROGRESS/EXPORT_CANCEL statics 1010, set_export_stage 1016, set_export_failure 1030, cancel_export 1055, export_progress 1064, write_export_with_progress 1084, write_export_with_phase 1136, source_audio 1229.
- src-tauri/src/device_settings.rs (write_dev_defaults called from the write path, see 4).
- React: src/views/sync/SyncManager.tsx; src/views/devices/GeneralTab.tsx (Sync/Export button); src/app/App.tsx writeToDevice 1998-2022, exportTrackTo 1497-1520, exportPlaylist 2095-2112 (folder export via dialog); src/store/useExportProgress.ts 44; src/components/StopExport.tsx.

Pipeline (rbl-export, per destination)
1. Preflight in app: destination is a dir; `rbl_db::is_rekordbox_running()` must be false (process-name check: rekordbox, rekordboxagent). Refuse text: "Quit rekordbox before syncing this USB so only one application writes its libraries."
2. Selection (in app, once per run, shared across sticks in sync_devices): playlists (+ folders as ancestors) and "loose" tracks (Export Track). Each track read once. Audio path: FolderPath, else rb_LocalFolderPath, else OrgFolderPath (cloud-synced fallbacks). Analysis read from the share tree. Intelligent playlists export the rule's current membership.
3. `for_stick`: unless delete-unlisted is on, adds loose tracks recorded in the stick's manifest (so Export Track items survive a sync). `rbl_export::recover(destination)` runs here (writes to stick).
4. export_cancellable stages, progress `checking` (done=i, per track), `copying` (only changed/new audio), `database` (once), `verifying` (before publish), `publishing` (atomic commit), then the app emits `done` / `cancelled` / `failed`.
   - Cancel is checked between tracks and once right before publish. After publish starts it completes.
   - Staleness guard: if a previously-exported track's source is now missing: Conflict "Source unavailable for '<title>'. Reconnect or relocate it before syncing; the USB has not been changed." A never-exported missing track is skipped (listed in `skipped`).
   - Concurrent write guard: snapshot compared before publish: "The device changed during sync. Close other writers and retry."
5. After publish, the app writes DEVSETTING.DAT defaults only if the stick has none (`write_dev_defaults`), restores MYSETTING* from app data if absent (see 4), then verifies by re-reading with the independent parser (`verify_databases`). Track count mismatch or missing audio => error "USB verification failed: ..." and report.verified=false.

Export formats written to the stick (root = PIONEER, or .PIONEER on HFS+/macOS Extended; existing root is preserved)
- Audio: `Contents/<Artist>/<Album>/<file>` (byte copy; or converted when the Maximum CDJ compatibility pref is on and the source needs it, WAV/AIFF 16-bit 44.1 kHz or MP3 320k, named `<stem>-rbx-cdj-<id>.<ext>`; originals never touched).
- Analysis (ANLZ): `PIONEER/USBANLZ/P###/<hash>/ANLZ0000.DAT`, `.EXT`, `.2EX` copied from the library analysis, PPTH rewritten to the stick path, cues replaced from the library, PVBR repaired, phrase mask applied. Stale extensions removed.
- Artwork: `PIONEER/Artwork/NNNNN/a<id>.jpg` plus the medium and other variants (4 files per image), one per distinct image.
- `PIONEER/rekordbox/export.pdb` (DeviceSQL, 4096-byte pages, 20 tables), `exportExt.pdb` (My Tags), `exportLibrary.db` (OneLibrary, plus -wal/-shm; carries colour names and categories/sorts).
- `PIONEER/rekordbox/playlists3.sync` and `playlists3Plus.sync`: rekordbox Sync Manager record (db id, ticked playlist ids, automatic flag, timestamps).
- `PIONEER/rbxport/manifest.json`: our record (db_id, baseline snapshot, tracks with hashes, playlists, loose track ids). Drives incremental sync.
- `PIONEER/DEVSETTING.DAT`: only written if absent (write_dev_defaults).
- `PIONEER/rekordbox/MYSETTING*.DAT`, `DJMMYSETTING.DAT`, `djprofile.nxs`: copied from the rekordbox6 settings dir if the stick lacks them (rbl-export lib.rs:1126, 1673). Also restored from `<data_dir>/rbxport/usb-settings/` when imported earlier.
- Publication journal: `.rbxport-publication/` on the stick during a write.

Commands (args -> return; camelCase on the wire)
- export_playlist({playlist: string, destination: string, defaults?: StickDefaults, deleteUnlistedMusic?: bool, compatibilityFormat?: "wav"|"aiff"|"mp3"}) -> ExportReportDto. Emits export:progress and then export:done. Folder export: client opens a directory dialog when destination is omitted (src/ipc/client.ts:265); null when cancelled.
- export_tracks_to_device({tracks: string[], destination, defaults?, compatibilityFormat?}) -> ExportReportDto. Refuses with "That device is no longer connected." if not a dir. Emits export:done.
- sync_devices({playlists: string[], destinations: string[], defaults?, automatic?: bool, ejectAfterSync?: bool, deleteUnlistedMusic?: bool, compatibilityFormat?}) -> SyncDeviceReportDto[]. Writes every destination in parallel (std::thread::scope) from one shared selection; one stick failing does not stop the others. Does NOT emit export:done. Emits sync:progress plus per-stick export:progress. Eject after sync only if report.verified and no skipped tracks; otherwise eject_error "The sync was incomplete or could not be verified. Review it before ejecting."
- validate_export_files({playlists: string[]}) -> MissingExportFileDto[] {title, path}. Read-only; no USB touched.
- device_sync_state({path}) -> DeviceSyncStateDto {selected: {libraryId,name}[], onDevice: string[], libraries: DeviceLibraryTreeDto[], automatic: bool}.
- cancel_export({path}) -> void. Sets an AtomicBool. Silent no-op if no job.
- export_progress() -> ExportProgressDto[] (snapshot; the React store asks at start).

Events
- export:progress, payload ExportProgressDto {path, state, done: u32, total: u32, title}. States: preparing (done 0), checking, copying, database, verifying, publishing, then done | cancelled | failed. Also ejecting (sync only). Progress percent = floor(done/total*100), capped at 99 until done. Terminal jobs remain in the map until the next batch starts (clear when the map is empty).
- export:done, payload ExportReportDto {tracks, playlists, bytesCopied, analysisFiles, reused, removed, playlistsAdded, playlistsRemoved, skipped: string[], verified}.
- sync:progress, payload SyncProgressDto {path, state}. States: writing, ejecting, done, failed. (Only the Sync Manager listens.)
- Error/UI messages: "An export to this device is already running."; failed job shows title or "The export failed before the device could be verified. Check that it is connected, writable, and has enough free space."; "Export stopped." when cancelled.

Behaviour to spec for the user
- Progress UI: per stick progress bar and label, a Stop button shown only in preparing/checking/copying/database (StopExport: "Stop after the current file operation finishes"). Stop in verifying/publishing is a no-op in effect.
- Missing audio: Sync Manager shows up to 10 titles and paths in a native confirm "Continue anyway?". Declining cancels with "Export cancelled because files are missing."
- Delete unlisted music OFF (default): loose tracks and their files are kept. ON: the stick is cut down to the selection and unlisted files are removed.
- Sync Manager always passes automatic=false (so a sync clears the automatic flag rekordbox might have set on the stick).

Tauri coupling
- rbl-export: none (pure). rbl-devices: none.
- src-tauri/src/commands.rs: export_playlist, export_tracks_to_device, sync_devices (AppHandle → emit export:progress, export:done (not sync), sync:progress), write_export_with_progress/phase, sync_one_device, set_export_stage/failure. State-only: validate, device_sync_state, cancel, progress. The statics EXPORT_PROGRESS/EXPORT_CANCEL are process-global.
- ExportSelection and source_track depend on AppState and rbl_index/rbl_db (rbl-app already has these).
Moving into rbl-app: ~750 lines (new module e.g. rbl-app/src/export.rs). rbl-app needs direct deps on rbl-export, rbl-pdb (playlists_on_device), dirs (usb-settings path), and rbl-onelibrary if used directly. Replace `AppHandle<R>` with `&dyn EventSink`. AppEvent additions: ExportProgress(ExportProgressDto), ExportDone(ExportReportDto), SyncProgress(SyncProgressDto), with names "export:progress", "export:done", "sync:progress" and payload-only serialization (keep existing events.rs pattern and add a wire-name test). The per-stick thread::scope is Tauri-free. rbl-app's `blocking` must replace tauri::async_runtime::spawn_blocking. DTOs already live in rbl-app/src/dto.rs.

=====================================================================
3. SYNC MANAGER (window)
=====================================================================
Files
- src/views/sync/SyncManager.tsx 907 (main UI, sync(), runUsbImport(), importItunes(), ejectDevice())
- src/views/sync/SyncWindow.tsx 30 (thin wrapper; calls useShowWindowWhenReady and onReady)
- src/views/sync/SyncManager.module.css 373; SyncManager.test.tsx 673
- src-tauri/src/sync_window.rs 79 (opens webview "sync", 1440x620, min 720x420, loads index.html with init script setting #sync, title "Sync Manager", hidden until ready; macOS overlay titlebar; stays Tauri-only)
- src-tauri/src/commands.rs 2580-2720 (iTunes: import_itunes, itunes_default_library, itunes_library_at, import_itunes_selected, import_collection)
- src/lib/tree.ts, src/lib/devices.ts (formatSpace), src/store/usePreferences.ts (usbExport, djSystem)

Layout (three columns plus footer)
- Left column "iTunes": reads `~/Music/Music/Library.xml` or `~/Music/iTunes/iTunes Music Library.xml` on open (itunes_default_library). If none, "Choose…" (file picker via chooseItunesLibrary). Ticks playlists (folders tri-state). SYNC (left) = `import_itunes_selected(path, ids)`, enabled only when rekordbox is not running, the library is loaded, and at least 1 playlist is ticked. Status: "Imported N playlists from iTunes (X tracks, Y new)." plus skipped count.
- Middle: SYNC button (right arrow; "Syncing…" while running; disabled while rekordbox is open or nothing selected). "Eject after syncing" checkbox. "Import from USB" group with 3 toggles (cues and beat grids; play history; CDJ/mixer settings), each greyed by reason (Library Protection on blocks cues and history; history needs rekordbox quit). Import button ("Import" / "Importing…", with Retry on failure).
- Right column: the rekordbox playlist tree (ticks) on the left side of the Device column? (The Device column is third.) Device column: rows per USB stick with tick (union of ticked sticks' last selections is restored on tick), eject button, capacity bar (aria "storage used"), FAT32 warning icon if fileSystem is not FAT32/VFAT ("Pioneer DJ recommends FAT32"), export progress bar and Stop, export report line, expandable device library tree (Device Library and OneLibrary trees). Refresh button "Refreshing…" while listing.
- Footer: status line (joined with " · ", details toggle when multiple lines) or selection summary "{n playlists} → {m USB devices}" and hint text (rekordbox running hint: "Quit rekordbox to enable synchronization."). Close button. Escape closes.
- The window polls `librarySummary().readOnly` every 2 s, which is how it knows rekordbox is running.

Flow of SYNC (sync function in SyncManager.tsx)
1. Re-list devices; drop ticked sticks no longer present. If none: "The selected USB device is no longer connected. Refresh and select it again."
2. Re-check rekordbox (librarySummary). If running: "Quit rekordbox to enable synchronization."
3. validate_export_files(playlists); if missing: confirm dialog (native) listing up to 10 missing tracks.
4. If Import toggles for history or settings are on in Preferences (usbExport.importHistory default on, importSettings default off): importUsb(path, cues=false, history, settings) per destination BEFORE export ("Couldn't import before syncing." aborts the sync).
5. sync:progress listener sets the status line ("Writing to {device}…", "Ejecting {device}…").
6. syncDevices(playlists, destinations, djSystem defaults, automatic=false, ejectAfterSync, deleteUnlistedMusic, compatibilityFormat).
7. Status per stick: error text, or "Safely ejected.", or "Not ejected: <reason>", else "Sync complete."
8. Refresh device list; re-read each non-ejected stick's state; onSynced() (shell re-reads devices).

Import flow (runUsbImport)
- For each ticked stick, for each ticked kind in order cues, history, settings: importUsb(path, cues?, history?, settings?). Cues asks a native confirm first: "Import cue and beat-grid changes from the selected USB devices? This replaces cues and grids for matching tracks in your library." Per-kind result text. Failures set the error state with Retry.

Eject (per device)
- eject_device(path) with busy state; removes the stick from ticks and states; "<name>: Safely ejected." or "<name>: Could not eject. <reason>".

Commands used
- library_summary (readOnly flag, polled), playlist_tree, list_devices, device_sync_state, sync_devices, validate_export_files, import_usb, eject_device, confirm (native), itunes_default_library, choose_itunes_library, import_itunes_selected, open_sync_window, close_window.
- Events: sync:progress, devices:changed, export:progress (via useExportProgress), import:progress (iTunes only; emitted by import_collection with ExportProgressDto shape, state "writing"; NO frontend listener exists, so it is dead).

Sync Manager state & persistence
- Ticks, collapsed folders, search are in-memory only. Nothing on disk except what the stick and the library hold.
- Shares Preferences via localStorage key `rbl.preferences` (both windows).

Tauri coupling
- SyncManager.tsx is React. Backend: sync_devices (emit), import_usb (AppHandle for GridEditor and reload + emit), import_itunes_selected (emit import:progress via import_collection and reload()), eject, device_sync_state. sync_window.rs is pure window management and stays in src-tauri.
Moving sync into rbl-app: the sync and export parts follow section 2. The iTunes parsing (rbl_db::itunes, rbl_db::xml) is already Tauri-free. import_collection needs `reload()` (src-tauri/src/commands.rs:312, uses AppHandle emit of library:changed) moved to rbl-app. Replace import:progress emit with an AppEvent variant, or drop it since nothing listens.

=====================================================================
4. DEVICE SETTINGS (stick's DEVSETTING.DAT and exportLibrary.db)
=====================================================================
Files
- src-tauri/src/device_settings.rs 490 (DTOs, to_dto, apply, library_defaults, dev_defaults, write_dev_defaults, Tauri commands)
- crates/rbl-devices/src/settings.rs 522 (DevSetting parse/encode 140 bytes, export_root, read, write, write_changes, recover)
- crates/rbl-onelibrary (StickSettings: categories, sorts, colors, sub_column, device_name, background_color_type; not read)
- React: src/views/devices/DevicePanel.tsx 170 (tabs; loads on device/export change; writes on every change, no Apply), GeneralTab.tsx 306, ListPairTab.tsx 139 (shared logic in src/lib/deviceSettings.ts 119), ColorTab.tsx 79, ColumnTab.tsx 52, MySettingsTab.tsx 19 (placeholder).

Fields
- DEVSETTING.DAT (on stick; `has_dev_setting`): waveformColor blue|rgb|3band; waveformPosition center|left; overviewWaveform half|full (read-only in UI); keyDisplay classic|alphanumeric. Unknown bytes are preserved from the file as read.
- exportLibrary.db (only if present; `has_library_settings`): deviceName (trimmed, UI maxLength 64, committed on blur/Enter), categories[] and sorts[] as MenuSlot {id, menuItem, name, seq, visible} (22 categories, 17 sorts in reference rows), subColumn (menuItem or null for "Not Specified"), colors[] {id 1..8, name ≤64}. backgroundColorType is preserved, not editable.
- Read-only flags: hasDeviceLibrary (export.pdb present), hasOneLibrary (exportLibrary.db present).
- Greyed/inert in UI: Waveform Divisions (byte unknown), Overview waveform (greyed), background colours, on-jog image (not written).

Commands
- device_settings({path}) -> DeviceSettingsDto (camelCase: hasDeviceLibrary, hasOneLibrary, hasDevSetting, waveformColor, waveformPosition, overviewWaveform, keyDisplay, hasLibrarySettings, deviceName, backgroundColorType, categories, sorts, subColumn, colors). Never fails on an empty stick: returns reference rows, disabled tabs.
- save_device_settings({path, settings}) -> DeviceSettingsDto. Rejects bad enums ("<Field>: \"x\" is not a choice."). Writes only changed groups (write_changes). DEVSETTING.DAT is rewritten whole (140 bytes) and created if absent. exportLibrary.db is updated in place only if it exists. colour names are also patched into export.pdb table 6. All via a publication journal `.rbxport-publication` on the stick.
- write_device_defaults({path, defaults: StickDefaults}) -> DeviceSettingsDto. Called by DevicePanel on open when the stick has an export but no DEVSETTING.DAT. Writes DEVSETTING.DAT from the defaults.
- ensure_device_library({path, defaults?}) -> DeviceSettingsDto. Creates the empty database folders (export.pdb with 20 tables, exportLibrary.db, USBANLZ, Contents), with the library's tags, then the DEVSETTING defaults. NO CALLER in the UI (client.ts:490 only). Dead wiring.
- reference_stick_settings() -> {categories, sorts} (reference rows; not a Tauri-state read).

Where writes happen
- Always onto the stick: DEVSETTING.DAT, exportLibrary.db (+wal/shm), export.pdb (colours). Never the library.
- Caveat: `device_settings` and `write_device_defaults` both call `rbl_devices::settings::read`, which calls `recover()` (completes or rolls back a publication journal on the stick). So a read can write to the stick. The comment at rbl-devices/src/lib.rs:198 says discovery is read-only, which is true for `inspect` and not for `settings::read`.

Preference defaults (Preferences → DJ System, localStorage `rbl.preferences`): djSystem.waveformColor "3band", waveformPosition "center", overviewWaveform "half", keyDisplay "classic", categories/sorts null (reference rows), subColumn null, createDatabaseFolders true (unused), linkInterface null, autoJoinLink false, linkKeySort "musical". These are passed to export and sync as `defaults` (StickDefaultsDto ignores extra fields).

Tauri coupling: device_settings.rs is Tauri-free except the #[tauri::command] attributes and ensure_device_library's `State<Arc<AppState>>`, plus `crate::commands::blocking`. Moving to rbl-app: small. Pass `&AppState`, use rbl-app's blocking. Tests (tempfile) move with it.

=====================================================================
5. USB IMPORT (import_usb): this WRITES THE LIBRARY
=====================================================================
Files
- src-tauri/src/usb_import.rs 289 (library_trees, import_usb, import, validate_settings; tests)
- src-tauri/src/grid.rs (GridEditor: is_locked, set_locked, forget_history, database_locked; not reviewed in depth)
- src-tauri/src/commands.rs:312 reload()

Command
- import_usb({path, cues: bool, history: bool, settings: bool}) -> ImportReport {tracks, histories, settings, skipped, warnings[]}. Refused: "Device is no longer connected" if not in rbl_devices::list(). Errors prefixed "USB import: ".
Behaviour
- Takes edit_gate and analysis_write; calls settings::recover (fails with "Could not recover an interrupted export before importing: …", naming the missing file if a journal cannot be recovered); takes a read lock on the device.
- Identity: track matching uses the USB export's content_id → masterContentId where masterDbId == this library's DB id (OneLibrary), plus the manifest's library_id, validated against djmdContent.FolderPath. Never matched by title or USB row id.
- cues: for each matched track not locked in GridEditor and with a PCO2 cue list: reads the DAT (beat grid PQTZ) and EXT (cues), rewrites the library's own DAT/EXT (cue sections replaced, grid replaced if the USB has one, EXT extended grid cleared), publishes via a FileJournal under backup_dir, then `import_usb_cues` in the library DB, and emits grid:changed and cues:changed per track. Local path and waveform preserved. Requires Library Protection off in UI. Throws "No tracks from this library were found on the device." if cues requested and nothing matched.
- history: per USB history session, all tracks must match or the session is left on the USB with warning "History '<name>' contains tracks that could not be matched to this library; it was left on the USB." Creates a library history playlist "<name> (USB xxxxxx)" with a deterministic UUID from volume_id + session id; appends to existing. Requires rekordbox not running (UI rule).
- settings: copies MYSETTING.DAT, MYSETTING2.DAT, DJMMYSETTING.DAT from the stick to `<backup_dir>/../usb-settings/` ( = <data_dir>/rbxport/usb-settings by default; mismatch only if the RBXPORT state-dir env override is set). Validated: length, header 0x60, CRC-16/XMODEM.
- Success with tracks>0 or histories>0 triggers reload() → library:changed.
Events: grid:changed and cues:changed (payload: track id string), library:changed (generation, via reload). Note reload() is also called on error.
Tauri coupling: `AppHandle` (for GridEditor via app.state, reload, emits); moving to rbl-app needs GridEditor moved or abstracted (locks, history, locked check) plus reload() and events. Medium effort.

=====================================================================
6. PRO DJ LINK
=====================================================================
Files
- crates/rbl-link/src/lib.rs 442 (Ports, LinkExport::start/stop/load_track/set_master/nudge/take_master_tempo, service_bind_address)
- crates/rbl-link/src/beacon.rs 2595 (announce/status/beat loops, master state, nudge clamp)
- crates/rbl-link/src/join.rs 749 (join state machine), watch.rs 143 (passive watcher), interface_mode.rs 256 (macOS only wired/wireless), catalog.rs 2537 (library → DB catalog), files.rs 222 (NFS exports), blobs.rs 238 (analysis blobs)
- crates/rbl-prolink/src/lib.rs 1272 (packet encode/decode only; "nothing in this crate opens a socket")
- crates/rbl-dbserver (query server; not reviewed), crates/rbl-nfs (portmap, mountd, NFS; not reviewed)
- crates/rbl-app/src/link.rs 916 (Session, LinkStatusDto, PlayerDto, PeerDto, Source impl, refusal, start_watcher)
- crates/rbl-app/src/rx3_link.rs 145 (XDJ-RX3 USB-MIDI activation lease, 0x50 every 200 ms, macOS/Windows only via midir)
- crates/rbl-app/src/network_labels.rs 72 (interface adapter/connection labels)
- crates/rbl-app/src/events.rs 77
- src-tauri/src/commands.rs 336-480 and 440-480 (link_* commands), 2753 export_playlist_file (not link)
- src-tauri/src/lib.rs 296-312 (peer watcher wiring, link:peers)
- React: src/views/statusbar/LinkDeckStrip.tsx 348 (strip), StatusBar.tsx (mounts it), src/views/settings/LinkPane.tsx 239, DjSystemPane.tsx 171 (header comment says it holds the LINK switch and interface; it does not, LinkPane does), UsbExportPane.tsx 115 (no link content), src/store/useAutoJoinLink.ts 42, src/app/App.tsx 655-700 (setLinkOn, auto-join, master controls), 1020-1040 (loadDroppedOnLink), 2586 (strip wiring), src/ipc/client.ts 396-412.

Ports and sockets (when LINK is ON; Ports::REKORDBOX; all constants)
- UDP 50000 announce (rbl_prolink::PORT_ANNOUNCE): keep-alives to the subnet broadcast (address | !netmask) every 2.0 s, only after the join has settled a number; join claims and probes are also broadcast. Discovery binds 0.0.0.0 with interface pinning (rbl-link lib.rs:150 doc).
- UDP 50001 beat clock (PORT_BEAT): broadcasts beats only while we are master (beacon.rs ~426, ~1309).
- UDP 50002 status (PORT_STATUS): broadcasts status every 200 ms, only after the number is settled (beacon.rs:1003); replies to players' media query and 46 handshake.
- TCP 12523 (PORT_QUERY, rbl_dbserver): port-query and database server, bound to the selected interface's IPv4 address (service_bind_address).
- TCP ephemeral: database server (per session).
- UDP 50111 portmap (REKORDBOX_PORTMAP_PORT) and ephemeral mountd, UDP 2049 NFS: bound to the interface address. The export host is restricted to `<address>/<netmask>`, so only the player subnet can mount.
- Also a passive watcher binds UDP 50000 (shared with SO_REUSEPORT on unix) from app startup (lib.rs:296-312) and transmits nothing. So the app listens on 50000 even with LINK off.
- Wi-Fi is not supported; the UI warns.
- Nothing is sent before a player or mixer keep-alive is heard (join stays in Waiting; join.rs:202-221). Then Discovery → probing six numbers → Assigning → Running with number 17 (wired) or 41 (wireless) or another free number (18 when 17 is taken). Interface loss drops the session to down.
- Interface choice (Session::start): explicit name; else the interface routed toward a seen peer; else an XDJ-RX3 link-local USB interface; else the first non-Wi-Fi interface (wired sorted first). Interface mode (wired/wireless) is only detected on macOS (interface_mode.rs). Elsewhere it is Unknown. That is a porting risk for the join's link-up test, not verified on Linux/Windows.
- Refusal: `rbl_db::is_rekordbox_running()` → start returns off with problem "rekordbox is running and holds the link ports. Quit it to turn LINK on." (no error thrown). A bind failure also returns off with the bind message.

Commands (args -> return; wire camelCase)
- link_status() -> LinkStatusDto. Off status carries `problem` (why it cannot start) and the interface list.
- link_peers() -> PeerDto[] (heard peers, LINK on or off).
- start_link_export({interface?: string|null, alphanumericKeys?: bool, alphabeticalKeys?: bool}) -> LinkStatusDto. If already on: returns current status. Blocking (binds sockets, walks track paths). Key notation comes from the Device pref keyDisplay (alphanumeric) and key order from djSystem.linkKeySort.
- stop_link_export() -> LinkStatusDto (off). Drops the session off the async thread.
- link_load_track({playerNumber: u8, trackId: string}) -> void. Errors: "LINK is not running.", "The player could not be told to load that track: …", "player N has not mounted the library yet" (NotConnected). Only works after the player has mounted our NFS export.
- link_set_master({on: bool}) -> LinkStatusDto.
- link_nudge_master({deltaBpm: f64}) -> LinkStatusDto. UI sends ±1; rounded ×100; clamped in beacon.rs (slowest/fastest master tempo constants, ~line 108).
- link_take_master_tempo() -> LinkStatusDto. No-op if no player is master (rekordbox ⟳).

LinkStatusDto (camelCase): on, problem?: string, interface?: {name, address, adapter?, connection?: "wired"|"wireless"|null}, players: PlayerDto[], interfaces: InterfaceDto[], master: bool, masterBpm: f64 (default 120), state: "off"|"waiting"|"joining"|"up"|"down", number?: u8.
PlayerDto: number, name, kind "player"|"mixer"|"rekordbox"|"device", address, loaded?: {id, title, artist}, playing, master, sync, cued, linkCue (always false; not implemented), mounted.
PeerDto: number, name, kind, address.

Events
- link:status, payload LinkStatusDto. Emitted on start (after successful start), on stop (off), on every reporter change (500 ms loop; only when state/number/players change), and when the link goes down (off with problem; the session is dropped on its own thread).
- link:peers, payload PeerDto[] (from the passive watcher, throttled to 500 ms, emitted only when the set changes).
- Library events from player edits: library:changed / tag-list:changed / edit-history:changed (generation or payload), sent through the same callback.

LinkDeckStrip (statusbar)
- Visible when LINK is on, or when at least one player or mixer is heard and LINK is not blocked. Otherwise hidden. Blocked = off with a problem (rekordbox running): the LINK button shows "unavailable" and a popover with the reason.
- Controls: LINK toggle (aria-pressed; disabled while busy); master clock: master on/off (setLinkMaster), tempo −1 / +1 BPM (nudge), ⟳ take master tempo (enabled only when a linked player is master). Players split half left, mixer(s) in the middle, rest right. Each PlayerDeck shows master, loaded (title/artist), playing. While a track is being dragged from the library a deck is a drop target; dropping calls link_load_track(playerNumber, trackId).
- The strip does not draw playhead, jog or waveform (status packets do not carry it).
- Auto-join: when djSystem.autoJoinLink is on, App's useAutoJoinLink starts LINK once when a player or mixer first appears. It does not retry the same device set after a failure or manual stop, and it resets when devices leave.

LinkPane (Preferences → PRO DJ LINK)
- Status labels: Checking connection… / Unavailable / Disconnected / Connected (state up) / Waiting for devices (waiting) / Connecting… (joining) / Connection lost (down). Button: Connect to PRO DJ LINK / Disconnect / Please wait….
- Auto-join toggle (djSystem.autoJoinLink, default off).
- Key sorting radio (alphabetical | musical; default musical). Disabled while LINK is on (applies at start).
- Network interface table: Automatic (null) plus each interface (name, Wi-Fi/Wired/Unknown with "Recommended" on wired, adapter, IP); "In use" badge; a missing saved interface shows as "Not present". Interface is locked while LINK is on. Selection stored as djSystem.linkInterface (name string or null).
- Wi-Fi warning: "PRO DJ LINK is not designed to work over Wi-Fi. Use a wired Ethernet connection for reliable playback."
- Devices table (Device, Role, IP, Status: Online/Loaded/Playing + Master badge). Status polls every 2 s and also listens for link:status.
- Preferences keys (localStorage rbl.preferences, djSystem): linkInterface, autoJoinLink, linkKeySort. No Rust-side persisted state for LINK.

Safe test mode (what exists)
- Tests bind EPHEMERAL ports on Interface::loopback() (rbl-link/tests/link.rs:75; rbl-link/tests/*). Loopback interface uses `interface: None` in BeaconConfig, so the beacon is not pinned to a device; the broadcast address is derived as 127.255.255.255 (derived from code, not run). rbl-fakecdj/tests/loopback.rs: "everything binds ephemeral loopback ports"; it notes rekordbox holds the real ports.
- rbl-fakecdj (405 lib, client only): RpcClient, mount, lookup, read_file, database_port, Database. Its examples probe real rekordbox (read-only in intent) and are NOT a test mode.
- rbl-link/examples/serve.rs (145): serves the installed library on a real interface with the fixed ports. Requires rekordbox closed. It broadcasts on the LAN. Not a safe mode.
- The app has no dry-run switch for LINK. The only safety levers: LinkExport::start takes Ports and Interface (so tests inject loopback and ephemeral ports), and the frontend browser build uses backend-mock (linkStatus mock).
- Recommended safe test: LinkExport::start(source, Interface::loopback(), Ports::EPHEMERAL) with rbl-fakecdj on the loopback address; keep real CDJs off the LAN. A port-free mode would need an explicit Ports/Interface config in rbl-app (currently start_link_export hardcodes Ports::REKORDBOX).

Tauri coupling
- rbl-link, rbl-prolink, rbl-devices, rbl-app/link.rs: no Tauri.
- Tauri: src-tauri/src/commands.rs link_* commands use State and AppHandle (start/stop) for emit; src-tauri/src/lib.rs:296-312 wires link:peers; the reporter and library callbacks are closures that call tauri::Emitter::emit.
Moving into rbl-app behind EventSink: link.rs is already in rbl-app. Session::start takes two closures (status reporter and library-changed) and should take Arc<dyn EventSink> instead. Add AppEvent::LinkStatus(LinkStatusDto), AppEvent::LinkPeers(Vec<PeerDto>). The library-changed callback already carries the event name string from Touched::event(); map it onto the existing AppEvent variants. Move the start_watcher call into rbl-app/startup.rs. The link_* command bodies are thin and can move as-is. The `blocking` in start/stop must not depend on tauri::async_runtime.

=====================================================================
7. SETTINGS PANES
=====================================================================
- UsbExportPane.tsx (115): switches (all persisted in localStorage usbExport / djSystem):
  - djSystem.createDatabaseFolders (default on) "Setup PIONEER folder on USB drives": NOT WIRED (dead, see section 0).
  - usbExport.importSettings (default off): auto-import CDJ/mixer settings on SYNC.
  - usbExport.importHistory (default on): auto-import play history on SYNC.
  - usbExport.importButtonCues (default on), importButtonHistory (default on), importButtonSettings (default off): initial ticks in Sync Manager's Import group.
  - usbExport.deleteUnlistedMusic (default off).
  - usbExport.maximumCompatibility (default off) + conversionFormat wav|aiff|mp3 (default wav; select disabled when compat is off): converts non-CDJ formats (FLAC, M4A) on export; originals untouched; WAV/AIFF 16-bit 44.1 kHz; MP3 320 kbps.
- DjSystemPane.tsx (171): tabs General (waveformColor blue|rgb|3band default 3band; waveformPosition left|center default center; overviewWaveform half|full default half; keyDisplay classic|alphanumeric default classic), Category and Sort (ListPairTab over reference rows when null; ALPHABET shown as "ALPHABET/TRACK NAME"), Column (subColumn: "Not Specified" or a sort's menuItem; DEFAULT/ALPHABET excluded). These are the defaults for a fresh stick (not live). The file's header comment wrongly says LINK lives here.
- LinkPane.tsx (239): see section 6.

=====================================================================
8. FRONTEND MODULES WITHOUT A BACKEND (for the port)
=====================================================================
- src/lib/sync.ts (201): in-app deck beat-sync math (tempoFor, barAt, nudgeFor, beatNudgeFor, beatWait, syncTo; MIN_TEMPO 0.5, MAX_TEMPO 2.0). Pure functions; no Tauri. Not USB or LINK sync.
- src/store/useExportProgress.ts (44): subscribes to export:progress and calls export_progress on start; computes percent. Jobs in preparing/checking/copying/database/verifying/publishing/ejecting count as active.
- src/lib/deviceSettings.ts (119): ListPairTab rules (activate/deactivate/shift/renumber; FIXED categories TRACK, PLAYLIST, HISTORY, SEARCH, FOLDER; FIXED sorts DEFAULT, ALPHABET).

=====================================================================
9. EVENT SUMMARY (wire name → payload)
=====================================================================
- devices:changed → null
- export:progress → {path, state, done, total, title}
- export:done → ExportReportDto
- sync:progress → {path, state: writing|ejecting|done|failed}
- import:progress → {path, state:"writing", done, total, title} (iTunes; no listener)
- link:status → LinkStatusDto
- link:peers → PeerDto[]
- library:changed → generation u32 (from reload(); usb import, iTunes import)
- tag-list:changed, edit-history:changed → generation / EditHistoryDto (LINK player edits)
- grid:changed, cues:changed → track id string (usb import)

=====================================================================
10. PERSISTED STATE (complete list)
=====================================================================
- localStorage `rbl.preferences`: djSystem.* (incl. linkInterface, autoJoinLink, linkKeySort, createDatabaseFolders), usbExport.*. Shared by main and Sync Manager windows.
- Disk, app data (`dirs::data_dir()/rbxport/`): usb-settings/{MYSETTING.DAT, MYSETTING2.DAT, DJMMYSETTING.DAT}; backups/ (usb-import file journal lives under backup_dir).
- On each stick: PIONEER/rbxport/manifest.json; PIONEER/rekordbox/{export.pdb, exportExt.pdb, exportLibrary.db(+wal,shm), playlists3.sync, playlists3Plus.sync}; PIONEER/DEVSETTING.DAT; PIONEER/USBANLZ/…; PIONEER/Artwork/…; Contents/…; MY SETTINGS files (if absent); .rbxport-publication/ during writes.
- In memory only: EXPORT_PROGRESS and EXPORT_CANCEL (src-tauri/src/commands.rs:1010-1014), AppState link session (`set_link`), Sync Manager ticks, LINK player status.

=====================================================================
11. TAURI COUPLING SUMMARY AND PORT EFFORT
=====================================================================
- Easy (no Tauri, or only the emit): MountWatcher, list_devices, eject, device settings, LINK core (rbl-link, rbl-prolink), export core (rbl-export), passive watcher, rx3_link.
- Export/sync glue (~750 lines in commands.rs 483-1230, plus device_settings.rs ~490): move to rbl-app/src/export.rs; add rbl-export (and rbl-pdb, dirs) as rbl-app deps; replace AppHandle<R> with &dyn EventSink; AppEvent gets ExportProgress, ExportDone, SyncProgress, DevicesChanged, LinkStatus, LinkPeers (payload-only Serialize; add a wire-name test in events.rs).
- Medium: import_usb (needs GridEditor from src-tauri/src/grid.rs, reload(), grid:changed, cues:changed, library:changed), iTunes import_collection (reload, import:progress).
- Stay in src-tauri: sync_window.rs (webview creation), scripting bridge listeners, menu, window_state, update and the tauri commands wrapper layer. `blocking()` (commands.rs:41) must be replaced by an rbl-app helper.
- EventSink (events.rs:37-41) is `Send + Sync`, `emit(&self, AppEvent)`, and `NullSink` already exists; this is compatible with the reporter threads in LINK and the thread::scope in sync_devices.

=====================================================================
12. OTHER FINDINGS / RISKS (verified in code)
=====================================================================
1. eject_device guard checks state "writing" which is never set in EXPORT_PROGRESS (commands.rs:1073 vs 1084-1120). Guard is dead.
2. createDatabaseFolders pref and ensure_device_library command have no effective caller (client.ts:490, UsbExportPane.tsx:22).
3. automatic sync flag: returned by device_sync_state and written by sync_devices, but never read by UI; SyncManager passes automatic=false, so each SYNC clears it.
4. device_settings read path calls recover(), which can mutate the stick (rbl-devices/settings.rs:272-276, 388). Contradicts the "read-only discovery" comment at rbl-devices/src/lib.rs:198.
5. Sync Manager "Eject after syncing" is only honoured when the sync is verified and has no skipped tracks, and the rest of the sticks still sync.
6. usb-settings path: export reads dirs::data_dir()/rbxport/usb-settings; import writes backup_dir().parent()/usb-settings. These match only while RBXPORT's state-dir env override is unset (rbl-backup/src/lib.rs:83-90).
7. import:progress emitted by iTunes import has no listener.
8. DjSystemPane.tsx header describes a LINK switch that lives in LinkPane.tsx.
9. Passive watcher binds UDP 50000 at app start, always, even with LINK off (shared bind). It transmits nothing.
10. Mode (wired/wireless) detection is macOS-only; join link-up on other OSes uses Unknown mode (join.rs:204-213). Verify before porting to Linux/Windows.
11. LINK player edits write the library (tags, ratings, hot-cue banks, grid offset, history). This is a library write path nobody outside LINK expects.

Not reviewed in depth (state if relied on): src-tauri/src/grid.rs, crates/rbl-nfs, crates/rbl-dbserver, crates/rbl-onelibrary internals, crates/rbl-audio conversion, crates/rbl-devices/src/explorer.rs, rbl-link/src/catalog.rs internals, src/views/statusbar/StatusBar.tsx wiring, the Windows eject FFI details.