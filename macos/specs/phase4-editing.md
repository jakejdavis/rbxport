# Phase 4 — library editing spec

## Orchestrator decisions (override the findings below where they conflict)
- **One write gate, in rbl-app.** Every native edit goes through a single rbl-app choke point that refuses when
  rekordbox/rekordboxAgent is running (ignore RBX_DISABLE_READ_ONLY in the native app) or when Library Protection
  (a setting the Swift app passes to Core, default on? → match React's default in src/lib/preferences.ts) is on.
  Undo/redo, grid/cue edits, analysis lock and imports all pass through it. `summary.read_only` must equal that gate.
- **Validation:** BPM 40–499 (grid::set_tempo's range) in UI and backend; colour 0–8 with 0 = none stored as NULL
  only if rbl-db supports it, otherwise keep React's behaviour; ratings 0–5 refused with a Malformed (not ReadOnly) error.
  Map validation refusals to Malformed where rbl-app can distinguish them; keep messages verbatim.
- **Don't change rbl-db write semantics** (delete_track tombstoning, smart-rule Unsupported) — note them, don't fix.
  Exception: if a smart playlist has an unsupported property, the native editor shows the rule read-only rather than
  letting a save fail.
- **Sort Items** records one undo entry if rbl-app can batch the moves cheaply; otherwise N entries is acceptable.
- **Create commands** may return the new id from rbl-app so the native UI can select/rename it.
- **Import progress** is shown natively (status bar) using the import:progress payload.
- **Testing safety:** edits are only ever exercised against fixtures/temp copies (rbl_db::fixture). Never run an edit
  against ~/Library/Pioneer/rekordbox. Manual UI verification of edits uses RBXPORT_FIXTURE_DIR.

Library editing (Phase 4) functional spec for /Users/jakedavis/Projects/rbxport. Read-only exploration; no files were written. Line numbers are from the current working tree, which has uncommitted changes (M: src-tauri/src/commands.rs, details.rs, crates/rbl-app/src/dto.rs, lib.rs, crates/rbl-ffi/*, screen_cache.rs; untracked: crates/rbl-app/src/details.rs, media.rs).

## 0. Context
- The native Swift app (macos/App) is read-only. rbl-ffi/src/core.rs exposes only read methods (summary, tree, open_view, fetch_rows, track_details, track_lookups, waveform, artwork, list_devices, export_playlist_file). MockBackend.swift sets readOnly: true. Phase 4 on the native side is greenfield, so the Tauri/React contract below is the spec.
- Nothing in the app edits the rekordbox library unless the write gate passes (see 1.4).

## 1. Top findings: gaps and inconsistencies to decide on before porting
1. **RBX_DISABLE_READ_ONLY is ineffective for Writer edits.** Writer::prepare (/Users/jakedavis/Projects/rbxport/crates/rbl-db/src/write.rs:2501) refuses whenever rekordbox runs, with no unsafe_writes_enabled() check. Meanwhile browse.rs:22 reports readOnly = running && !unsafe, so the UI shows editable and every write then fails with "rekordbox is running…". Grid edits do honour the override (grid.rs:481 uses write_refusal_reason). Reload and refresh (commands.rs:322, rbl-app/src/edits.rs:97, startup.rs:105/126) compute read_only = running and ignore the override. Four different answers.
2. **Library Protection is not enforced in the backend, and not in the app's write() helper.** App.tsx:1079 `write()` has no protectLibrary check. Gating is UI-only: runEdit (App.tsx:822) and addDraggedTo (893) and importDroppedPathsTo (933) check the flag; the context menus check via contextMenus.ts WRITES (382-401) and resolveMenu (lib/menu.ts:68-78).
   - Undo/Redo bypasses resolveMenu entirely: runMenu (App.tsx:1703-1711) calls runLibraryHistory directly, so Cmd+Z and the native Edit menu write under protection.
   - analysisLock and analysisUnlock are not in WRITES, so they stay enabled under protection (grid_lock writes analysis files).
   - SyncManager iTunes import (SyncManager.tsx:405-445) gates only on rekordbox-open, not protectLibrary.
3. **BPM ranges conflict.** set_track_field "bpm" goes to grid::set_tempo (grid.rs:467-476): 40 to 499, message "Enter a BPM from 40 to 499.". Writer::set_bpm (write.rs:2174-2177) and fields.ts acceptable() say 20 to 400. The table BPM cell (TrackTable EDITABLE_FIELDS bpm, line 150-157) has no client validation. The InfoPanel BPM is Locked.
4. **BPM edits are not undoable.** details.rs:115-124 only clears redo. Undo history is unchanged, and the change is not recorded.
5. **Smart-rule round trip loses unknown properties.** Property::Unsupported.name() is "" (rbl-index/src/smart.rs:167). rule_to_dto (commands.rs:2261) therefore sends property "". Saving that rule fails in rule_from_dto (commands.rs:2291-2300) with "\"\" is not a property a rule can use here." Separately, smart.rs:383-385 `condition()` drops any condition with an unknown Operator silently.
6. **delete_track is not complete.** write.rs:2317-2360 tombstones only djmdSongPlaylist and djmdContent. It does not touch djmdSongTagList, djmdSongHistory, djmdSongMyTag, or djmdCue, so these may point at a tombstoned ContentID. Verify whether rbl-index filters them.
7. **import_files reports success when a mid-batch write is refused.** Each file's WriteRefused becomes a "skipped" string (commands.rs:2196-2199), so a batch that hits "rekordbox is running" mid-way returns Ok with skips. By contrast, xml.rs:299-300 `set_rating(...)?` aborts the whole XML import.
8. **import:progress is emitted but never listened to.** commands.rs:2699 emits it. No subscription exists in src/ipc/client.ts, and there is no progress UI.
9. **set_track_color does no validation** (write.rs:1574-1581). It stores any text, and the UI writes "0" for none (InfoPanel setColor), not NULL.
10. **Sort Items creates N undo entries.** App.tsx:1201-1215 calls movePlaylist once per child, and move_playlist is recorded (commands.rs:2366-2377).
11. **Smart-playlist save is two non-atomic commands** (App.tsx:1164-1180): setSmartRule (non-recorded) then renamePlaylist (recorded).
12. **Create commands return the generation, not the new id** (commands.rs:2231-2243, 2344-2352). The frontend re-reads the tree instead.
13. **clear_tag_list exists but has no UI caller** (client.ts:524; App.tsx has no call).
14. **Auto-backup is off for app edits.** state.rs:280 calls disable_automatic_backups() in write_then. Backups are only explicit (Preferences > Advanced, backups.rs). The automatic backup in Writer::prepare (write.rs:2506) applies only to a bare Writer. Tests: commands.rs:624 (library_backups_are_manual_only), writes.rs:810 (automatic, bare Writer).
15. **Error kind collapse.** write_error (edits.rs:117-121) maps every WriteRefused to ErrorKind::ReadOnly, including validation refusals such as "9 is not a rating between 0 and 5" and "no playlist or folder X". Status-bar text comes verbatim from rbl-db strings.
16. **Import wire shapes differ.** ImportReportDto.existing is Vec<ImportedTrackDto> (dto.rs:268-276). XmlImportReportDto.existing is u32 (dto.rs:400-407).

## 2. Files and LOC (absolute)
Rust, shell (/Users/jakedavis/Projects/rbxport/src-tauri/src/):
- commands.rs 3048 (edit helpers 219-335; undo/redo 2390-2439; playlist/tag/history/collection commands 2216-2530; import 2058-2220 and 2567-2730; record_play 2856; remove_from_collection 2912; set_track_* 2937-2976)
- details.rs 133; relocate.rs 185; usb_import.rs 289; file_drag.rs 111; file_drop.rs 111; analysis.rs 573; grid.rs 1029; cues.rs 493; lib.rs 551 (invoke_handler ~line 351+)
- tests/commands.rs (src-tauri/tests) 1502

Core (/Users/jakedavis/Projects/rbxport/crates/):
- rbl-app/src/edits.rs 122; events.rs 77; state.rs 902; backups.rs 879; error.rs (run_command at 80); details.rs 96; media.rs 139; file_journal.rs 220
- rbl-db/src/write.rs 3038; lib.rs 416; import.rs 206; xml.rs 498; itunes.rs 393; details.rs 745; fixture.rs 370; tests/writes.rs 2278
- rbl-index/src/smart.rs 1114; rbl-ffi/src/events.rs (LibraryEvent), convert.rs 404, core.rs

React (/Users/jakedavis/Projects/rbxport/src/):
- app/App.tsx 2646; lib/contextMenus.ts 487; lib/menu.ts 85; lib/editHistory.ts 62; lib/tree.ts 329; lib/queue.ts 126
- views/browser/TrackTable.tsx 1596; views/tree/TreeView.tsx 654; views/tree/SmartPlaylistEditor.tsx 333; views/info/InfoPanel.tsx 783; views/info/fields.ts 157
- views/settings/AdvancedPane.tsx 435; views/statusbar/StatusBar.tsx 158; views/player/Player.tsx 2582 (record play at 539, 1205-1229); store/useAnalysis.ts 101; ipc/client.ts 577; ipc/types.ts 1714; ipc/backend-mock.ts 2689
- Shortcuts: lib/shortcuts.ts:483 (Cmd+Shift+A = analyseSelection)

## 3. Area 1: the edit pipeline

### 3.1 Helpers (commands.rs)
- **edit()** (219-244): args (app, state, name, touched, action: Writer -> Result<(), DbError>) returns u32 generation.
  - Takes state.edit_gate (ReentrantMutex) and calls state.write_then(action, refresh_after_edit). WriteRefused becomes ReadOnly via write_error.
  - Inside the gate: clear_redo only (undo kept). Build history_dto.
  - After blocking returns, outside the gate, emit touched.event() (library:changed, or tag-list:changed for TagList) with the generation, then edit-history:changed with the DTO.
- **permanent_edit()** (246-269): same, but history.clear() (undo and redo gone). Used only by remove_from_collection.
- **recorded_edit()** (271-301): action returns LibraryEdit. Records only if !reversible.is_empty() (no-op edits are not recorded). record() pushes and clears redo. Emits library:changed (always) and edit-history:changed. Returns EditHistoryDto.
- **reload()** (312-335): takes edit_gate, open_read_only, rbl_index::load, set_library(read_only = is_rekordbox_running()), emits library:changed(generation). Called by import_collection (if imported or playlists > 0), import_files (if imported > 0), auto_relocate (if relocated > 0), import_usb, and set_track_field bpm.
- **undo_edit / redo_edit** (commands.rs 2391-2439): under gate, clone the top entry, touched_by(entry), write_then(apply_history reversed or forward, refresh_after_edit), then move the entry between stacks. Emit library:changed and edit-history:changed. No entry gives NotFound "There is no library edit to undo." / "...to redo.".

### 3.2 Undo/redo model (rbl-app/src/state.rs:44-100; edits.rs)
- LibraryEdit variants: DeletePlaylist(PlaylistDeletion), RenamePlaylist, MovePlaylist, RemovePlaylistTracks, Track(Vec<TrackEdit>), TrackTags(TrackTagEdit).
- Stack limit 50 (state.rs:81). record() evicts oldest and clears redo.
- Payloads store exact values or row ids, not reconstructed state. Deletion keeps membership ids, so undo does not resurrect old tombstones (write.rs:284-290).
- Track(vec) undo runs in reverse (edits.rs:69-75).
- Labels: "Rename Playlist", "Move Playlist", "Delete Playlist", "Remove Tracks from Playlist", "Track Edit" (rating, comment, colour, field, My Tags, artwork, reset play count).
- Undoable (recorded): rename, move, delete playlist/folder, remove tracks from playlist, set_track_rating/comment/color/field (except BPM), set_my_tags, add_artwork/clear_artwork, reset_play_count.
- NOT undoable (edit(), redo cleared): create_playlist, create_folder, create_smart_playlist, set_smart_rule, add_tracks_to_playlist, reorder_playlist, reload_tags, add_to_tag_list, remove_from_tag_list, clear_tag_list, relocate_track, add_playlist_artwork, record_play, remove_from_history, set_track_field bpm.
- Not undoable and history-wiping: remove_from_collection (permanent_edit).
- Rule: a non-recorded edit after an undo clears redo only. Undo entries survive.
- Frontend: runMenu (App.tsx:1703-1711) sends undo/redo to runLibraryHistory unless typing or a deck/grid editor owns history (hasEditHistory in lib/editHistory.ts). Labels reach the native menu through setLibraryEditHistory and setHistoryMenu. edit-history:changed is consumed at App.tsx:421.

### 3.3 Write gate (rbl-db)
- is_rekordbox_running (rbl-db/src/lib.rs:193-206): process names rekordbox, rekordbox.exe, rekordboxagent, rekordboxagent.exe.
- write_refusal_reason (lib.rs:211-232): not a real install = allowed. RBXPORT_TEST set on real install = refused. Running and not unsafe = "rekordbox is running. Quit it before making changes."
- Library::open(ReadWrite) (lib.rs:243-290) applies it. Recovery of a hot journal goes through the writable opener.
- Writer::prepare (write.rs:2498-2511) runs before every transaction. It refuses running (real install only, no override check) and then takes the automatic backup if one is enabled and not yet taken.
- AppState::write_then (state.rs:258-296): checks location, refuses while a restore is pending ("A library restore is unfinished. Restart the app to recover it before editing."), takes analysis_write.try_lock() and runs file_journal::recover, opens a fresh Writer per edit (drops it after; rekordbox must be able to take the file back), disables automatic backups, runs the action, then runs the refresh on the same connection.
- The read-only summary: browse.rs:15-30 library_summary, read_only = running && !unsafe for real installs. App.tsx polls every 2 s (App.tsx ~392-410).

### 3.4 Read-only UI and override
- App.tsx:388: readOnly = summary.readOnly || advancedPrefs.protectLibrary.
- protectLibrary defaults to true (lib/preferences.ts:311). Turning it off (AdvancedPane.tsx:61-76) needs at least one backup (listBackups non-empty). With none, a warning dialog appears: "It looks like you haven't made a backup yet…", with "Unlock anyway" and "Cancel" (AdvancedPane.tsx ~110-125).
- Refusal text (lib/menu.ts:81-84): protected = "Editing is locked by Library Protection. Turn it off in Preferences to edit."; running = "Editing is locked while rekordbox is running. Quit rekordbox to enable editing."
- Status bar: "Library read-only" button (single click explains, double-click calls disable, StatusBar.tsx ~95-101).
- disable_read_only (commands.rs:70-79): succeeds only if RBX_DISABLE_READ_ONLY was set at launch (rbl-db/lib.rs:33, 43-49). Session-only. Error: "Set RBX_DISABLE_READ_ONLY before launching rbxport to enable this override." App.tsx:2633-2640: if protected, explain instead; else invoke, set summary.readOnly = false, note "Read-only mode disabled for this session."

### 3.5 Events (what each command emits)
- library:changed (u32 generation): edit() for Playlists and Tracks; recorded_edit(); reload(); undo/redo; import_collection and import_files after reload; auto_relocate after reload; relocate_track; reload_tags; set_track_field bpm (after grid:changed).
- tag-list:changed (u32): edit() with Touched::TagList (add/remove/clear tag list).
- edit-history:changed (EditHistoryDto {generation, canUndo, canRedo, undoLabel, redoLabel}): every edit path.
- grid:changed (String track id): grid_edit, grid_lock (grid.rs:561, 651), set_track_field bpm (details.rs:113), import_usb per changed id (usb_import.rs:61).
- cues:changed (String): cues.rs:168, import_usb (usb_import.rs:62).
- analysis:changed (String): analysis.rs:120, 367.
- devices:changed (unit): lib.rs:315 mount watcher.
- import:progress (ExportProgressDto {path, state:"writing", done, total, title:""}): commands.rs:2699, XML/iTunes only, unlistened.
- Touched::Metadata and Histories go through refresh_metadata (state.rs:384-400), which bumps the generation and drops views.

### 3.6 Refresh strategy (edits.rs:89-114; state.rs:361-400)
- Playlists: invalidate_views (state.rs:361). Drops all open views and bumps the generation. Tree reread is ~24 ms.
- TagList: invalidate_tag_list_views (state.rs:374). Drops only views that show the Tag List. Generation is unchanged. Other views keep their pages.
- Metadata(ids): reload_metadata for those ids, clone-then-publish (state.rs:384-400). Generation bump.
- Histories(ids): as Metadata, plus reload_histories. Empty ids falls through to the Playlists-style full invalidate (edits.rs:92, 100-111).
- Tracks: full rbl_index::load (~233 ms on the reference library, edits.rs:12 comment). Used for rename-like column changes, relocate, reload_tags, artwork, remove_from_collection, and undo of track edits.

### 3.7 Port steps (move helpers to rbl-app, &dyn EventSink)
1. events.rs:12-23 AppEvent currently has only LibraryReady, LibraryProblem, LibraryChanged(u32), TagListChanged(u32), EditHistoryChanged(EditHistoryDto). Add: CuesChanged(String), GridChanged(String), AnalysisChanged(String), DevicesChanged (unit), ImportProgress(struct {path, state, done, total, title}). Extend name() (27-35) and Serialize (40-48). Serialize writes payload only, so `emit(ev.name(), &ev)` matches the wire. Add a payload test in the style of events.rs:69-76.
2. Mirror in rbl-ffi/src/events.rs:10-17 (LibraryEvent, uniffi::Enum) and convert.rs:325-335. Regenerate macos/Generated/swift/rbl_ffi.swift (currently 4495 lines).
3. Consolidate Touched::event() (edits.rs:29-31) and Touched::changed() (37-39). Keep the event names unchanged.
4. Move into rbl-app/src/edits.rs as synchronous functions:
   - commit(state, sink, touched, action) -> AppResult<u32>   (from edit)
   - commit_permanent(...)                                    (from permanent_edit)
   - commit_recorded(state, sink, touched, label, action) -> AppResult<EditHistoryDto>  (from recorded_edit; always emits LibraryChanged)
   - reload(state, sink) -> AppResult<u32>                    (from commands.rs:312)
   - undo(state, sink), redo(state, sink)                     (from commands.rs:2391-2439)
   Emit after the edit_gate guard is dropped, in the same order as today (library:changed then edit-history:changed). EventSink is Send + Sync (events.rs:52), so &dyn EventSink can cross the blocking boundary.
5. Keep the spawn_blocking wrapper in the shell (commands.rs:41-58). run_command already lives in rbl-app (error.rs:80).
6. Shell adapter: struct TauriSink<R>(AppHandle<R>) implementing EventSink via tauri::Emitter::emit(&self.0, ev.name(), &ev). Commands become thin: blocking(name, move || rbl_app::edits::commit(&state, &sink, ...)).
7. Unify read-only: one function used by reload, set_library, refresh, and browse, honouring the override. Decide whether Writer::prepare honours the override too (finding 1).
8. Movable now: relocate.rs (depends only on blocking, reload, write_error and AppState), most of details.rs, the import helpers (expand_import_paths, commands.rs:2110-2157), import_collection.
9. Blocked until grid/analysis/cues are ported: details.rs BPM path (grid::set_tempo, grid.rs:467-500, which also uses GridEditor, file_journal, and the analysis_write lock), usb_import.rs (grid::GridEditor, database_locked), analysis.rs, cues.rs.

## 4. Area 2: playlists and folders

### Commands (args -> returns)
- create_playlist(name, parent) -> u32 generation (commands.rs:2231). create_folder(name, parent) -> u32 (2344).
- create_smart_playlist(name, parent, rule: SmartRuleDto) -> u32 (2317). set_smart_rule(playlist, rule) -> u32 (2333). smart_rule(playlist) -> SmartRuleDto (2244).
- rename_playlist(id, name) -> EditHistoryDto (2355). move_playlist(id, parent, index?: usize) -> EditHistoryDto (2367). delete_playlist(id) -> EditHistoryDto (2380).
- add_playlist_artwork(playlist, image) -> u32 (details.rs:64).
- undo_edit / redo_edit -> EditHistoryDto.
- ROOT id is "root" (rbl-db write.rs:136; TREE_ROOT = "root" in ipc/types.ts:1535).

### Behaviour
- New items: "New playlist" / "New folder" under parentFor(node) (App.tsx:1094-1113; tree.ts:21-30: folder -> itself; playlist -> nearest folder above at lower depth, else root). No auto-rename.
- Rename: tree menu "Rename Playlist" / "Rename Folder", F2 (TreeView:156), double-click (Preferences doubleClickToEdit) or click on selected. RenameField (TreeView:33-66): Enter commits if non-empty and changed; Escape restores; blur commits. Smart playlists can be renamed. Message "Renamed to X.".
- Drag to move (TreeView:150-235, 415-441):
  - Only playlist, smartPlaylist and folder rows are movable (TreeView:578-580).
  - Edge test: folder middle third = "into" (appended at end, TreeView:430-433). Otherwise top half = above, bottom half = below (TreeView:176-181). Playlists have no "into".
  - Index is computed with the moved node lifted out (TreeView:434-440).
  - Own subtree is not a target (carriedIds, TreeView:415-422). Backend rejects folder-into-itself (write.rs:541-549, "that would put a folder inside itself").
  - Sibling Seq is rewritten for the whole run (write.rs:533-578).
- Delete Playlist / Delete Folder: NO confirmation. Soft-deletes subtree and memberships (write.rs:629-696). Undoable (exact row ids). Clears selection if it was the deleted node. Message "Deleted X.".
- Sort Items (folder menu only): App.tsx:1201-1215. Children sorted by localeCompare (sensitivity base), then one move per child from index 0. N undo entries. Message "Sorted X.". Folders-first ordering is unknown [ASSUME].
- Add Artwork (playlist/smart menu only, not folder; contextMenus.ts:249): pickImage("Choose the artwork") then add_playlist_artwork. Message "Artwork added to X.". JPEG or PNG only (write.rs:2098-2121). File goes to /PIONEER/Artwork/<3 hex>/<uuid>/artwork.<ext> plus artwork_m.jpg (240px) and artwork_s.jpg (80px) (write.rs:2701-2725). No clear command for playlist art, though set_playlist_artwork(None) exists in the writer. Not undoable.
- Add To Shortcut / Delete Shortcut: stored in view prefs (App.tsx:1218-1240), not the library.
- Create smart playlist: App.tsx:1139-1152 opens SmartPlaylistEditor with name "Untitled Intelligent List" and rule {logic:"all", conditions:[]}.
- Edit smart playlist: smart_rule, then the editor. Save runs setSmartRule then renamePlaylist if the name changed (App.tsx:1164-1180).

### Tree context menu (contextMenus.ts:208-269)
- Collection: Create New Playlist / Create New Folder.
- Folder: Export Folder, Create New Playlist, Create New Folder, Playlist display setting (greyed), Rename Folder, Delete Folder, Sort Items, Add To Shortcut.
- Playlist / smart: Export Playlist (submenu), Create New Playlist, Edit Intelligent Playlist (smart only), Create New Folder, display setting (greyed), Add Artwork, Rename Playlist, Delete Playlist, Export a playlist to a file (m3u8 / txt), Add To Shortcut.
- Write items are disabled under readOnly by WRITES (contextMenus.ts:382-401): createPlaylist, createFolder, rename, delete, sortItems, addArtwork, createSmartPlaylist, editSmartPlaylist.

### SmartPlaylistEditor (views/tree/SmartPlaylistEditor.tsx)
- Titlebar = "Create New Intelligent Playlist" or "Edit the Intelligent Playlist". Fields: "List name" (autofocus, selected); "Match [all of the | any of the] following conditions:" (select appears only with 2+ rows; else "Match the following condition:"); "+" add row; rows of property select, operator select, value, optional "to" upper value (operator 5), optional unit select (operators 6/7), and "−" remove (disabled on the only row). OK / Cancel. Escape cancels; no unsaved-changes guard.
- canSave (line 158): name.trim() non-empty and every condition's left non-empty (trimmed on save).
- Properties (48-72), in order: Album (album, text); Album artist (albumArtist, text); Artist (artist, text); BPM (bpm, number); Color (grouping, text); Comments (comments, text); Composer (producer, text); Date Added (stockDate, date); Date Created (dateCreated, date); DJ play count (counter, number); File name (fileName, text); Genre (genre, text); Key (key, text); Label (label, text); Mix name (mixName, text); My Tag (myTag, tag); Original artist (originalArtist, text); Rating (rating, number); Release Date (dateReleased, date); Remixer (remixedBy, text); Time (duration, number); Track Title (name, text); Year (year, number).
- Operators (75-87), code and label: 1 "=" (text/number/date); 2 "≠" (same); 3 ">" (number/date); 4 "<" (number/date); 5 "is in the range" (number/date); 6 "is in the last" (date); 7 "is not in the last" (date); 8 "contains" (text, tag); 9 "does not contain" (text, tag); 10 "starts with" (text); 11 "ends with" (text).
- Units: day(s), week(s), month(s), year(s); default "day".
- changeProperty (136-151): keeps the operator if valid for the new kind, else the first valid one. Crossing into or out of My Tag clears the values.
- changeOperator (153-156): relative operators get a unit; "is in the range" keeps the upper value.
- My Tag value is a picked tag (grouped by category). The stored value is the tag id, compared as a signed 32-bit integer (tagKey, lines 105-108; rbl-index smart.rs:733 my_tag_key). Unknown tags are kept disabled.
- Properties not in this list are shown disabled and cannot be re-chosen (but see finding 5).

### Smart rule format (rbl-index/src/smart.rs)
- XML: `<NODE Id="…" LogicalOperator="1|2" AutomaticUpdate="1"><CONDITION PropertyName="…" Operator="…" ValueUnit="…" ValueLeft="…" ValueRight="…"/></NODE>`. LogicalOperator 1 = all, 2 = any (parse line ~246, to_xml 295-332).
- to_xml writes no whitespace. Attribute values are escaped via rbl_core::xml::escape.
- Nested groups are rejected on read (commands.rs:2265-2270, "This intelligent playlist nests groups of conditions, which this editor cannot show.").
- Operator codes: 1 =, 2 ≠, 3 >, 4 <, 5 range, 6 in last, 7 not in last, 8 contains, 9 not contains, 10 starts, 11 ends (smart.rs:71-83).
- Property names: see the React list above (smart.rs:142-167 and from_name 173-205).
- A rule the editor cannot represent is still stored by parse, but finding 5 applies.
- Conditions with an unknown operator are dropped on parse (smart.rs:383-385). A rule with a dropped condition saves without it.
- Intelligent playlists refuse hand edits (refuse_if_smart, write.rs:2618-2630, "an intelligent playlist's tracks are its rule; they cannot be edited by hand"). They are excluded from Add To Playlist and from drop targets.
- Writer validation: set_smart_list (write.rs:438-452) refuses non-smart ids.

## 5. Area 3: tracks in playlists

### Commands
- add_tracks_to_playlist(playlist, tracks: Vec<String>) -> u32 (commands.rs:2440). Non-undoable.
- remove_tracks_from_playlist(playlist, tracks) -> EditHistoryDto (2497). Undoable (RemovePlaylistTracks, with exact memberships and order).
- reorder_playlist(playlist, tracks) -> u32 (2927). Non-undoable.

### Behaviour
- Add: appends in the order given, skips tracks already present (write.rs:784-834). TrackNo runs 1..n and is contiguous. Whole call refused if the playlist is missing or is smart. Message "Added N track(s) to X." or "Already in X." (when the count is 0), or "Nothing added to X; K skipped." for loose files.
- Remove: no confirmation. Closes TrackNo gaps (write.rs:836-885). Message "Removed N track(s)." (N = number of ids sent, not rows deleted).
- Remove from Playlist menu entry: enabled only when the source is a playlist (contextMenus.ts:166, enabled() 416). Over the Tag List it becomes "Remove from Tag List" (contextMenus.ts:477-479). In a history view it is "Remove from History".
- Reorder allowed only when (App.tsx:1322-1328):
  - the source is a playlist,
  - !readOnly (protection included),
  - sort column is trackNo,
  - the search query is empty,
  - no filter is applied.
  Otherwise rows are not draggable to reorder and the TrackTable gets no onReorder.
- Reorder drop (TrackTable.tsx:1107-1146): the list of full ids is fetched with view.idsInRange(0, count). The insertion point is counted against the staying ids, with the carried rows lifted out. The full new order is sent, so the backend sees every id.
- Backend reorder (write.rs:1034-1078): keeps the given ids that are present, in the given order, then appends any left out in their old order. TrackNo is renumbered. Tests: writes.rs:419-450.
- Drop line (TrackTable.tsx:1316-1349): top or bottom half of the hovered row sets above or below. Dropping below the last row targets the end. Reorder only applies when the drag is local (isLocalDrag). External drags copy in.
- Selection drag (TrackTable.tsx:1032-1056): dragging an unselected row moves only that row. Dragging a selected row carries the whole selection. Playlists take all ids. Decks take the first in list order.
- Drag onto a tree playlist: App.tsx:893-931 addDraggedTo. Loose Explorer rows (id "file:<path>") are imported first (importLoose). Messages as above.
- Add To Playlist submenu (App.tsx menuPlaylists, ~1420-1440): playlists only (no smart), each labelled "Folder › Playlist". Items are importsLoose: true, so loose files are imported first (App.tsx:1437-1460).

### Drop external files to import
- DOM drop onto the track list (TrackTable.tsx:1333-1344, setFileOver, onDropFiles) or onto a tree playlist (TreeView:217). Both are gated by readOnly (App.tsx:2192, 2369).
- Native drop (see area 9). App.tsx subscribeNativeFileDrops (~1000-1020): targets [data-file-drop-playlist] rows or the track scroll area when a playlist is selected. Otherwise refuse "Drop files or folders onto a playlist to import them.".
- importDroppedPathsTo (App.tsx:933-965): protection check, then message "Importing N items into X…". Calls import_files, adds imported and already-present tracks to the playlist, reloads the tree, queues analysis if Auto Analysis is on. Message "Imported X of Y files into X[; K skipped][; M already in the library].".

## 6. Area 4: track metadata

### Commands
- set_track_rating(track, stars: u8) -> EditHistoryDto (commands.rs:2938). 0 to 5; else refused.
- set_track_comment(track, comment) -> EditHistoryDto (2950). Free text, no length limit, no trim in the writer (xml import trims).
- set_track_color(track, color: Option<String>) -> EditHistoryDto (2962). ColorID stored as text.
- set_track_field(track, field, value) -> EditHistoryDto (details.rs:94-133).
- set_my_tags(track, tags: Vec<String>) -> EditHistoryDto (details.rs:36-45).
- add_artwork(track, image) -> EditHistoryDto (details.rs:50-60). clear_artwork(track) -> EditHistoryDto (details.rs:78-86).
- filter_values and track_details/track_lookups are read-only.

### Behaviour and validation
- Rating: Stars (TrackTable.tsx:160-200) lights up to the star clicked. Clicking the lit star clears it (rating === star ? 0 : star). Two quick clicks are two writes. Message "Rated N of 5." or "Rating cleared.". Optimistic pending overlay (App.tsx:883-886) cleared on library:changed.
- Comment (TrackTable.tsx:200-345, EditableCell): Enter or blur commits, Escape abandons, commit only if the draft changed. Click-to-edit (preference, on selected rows) or double-click. Message "Comment saved.".
- Colour: InfoPanel only (Select "Color"). Options "0" then "1"..."8". Names: Pink, Red, Orange, Yellow, Green, Aqua, Blue, Purple (fields.ts COLORS). "0" = none. Messages "Color saved." / "Color cleared.". No palette check (finding 9).
- set_track_field (rbl-db write.rs:198-216 TrackField::parse, 1600-1680):
  - Wire names: title, artist, album, year, trackNumber, discNumber, originalArtist, composer, remixer, lyricist, playCount, genre, label, key, bpm.
  - Unknown name: ErrorKind::ReadOnly "{field} cannot be edited here." (details.rs:101-103).
  - Numbers (touch_number, write.rs:2229-2238): trimmed, parsed as integer, else "{value} is not a whole number"; range checks: year 0..9999, trackNumber 0..9999, discNumber 0..999, playCount 0..999999. Out of range: "{n} is outside 0 to {max}".
  - Reference fields (touch_reference, write.rs:2240-2265): artist, originalArtist, composer, remixer use djmdArtist; album, genre, label use their own tables. The name is trimmed and interned by exact Name match (case-sensitive). Empty becomes NULL (intern returns None on empty, write.rs:2569-2574). The lookup row is not deleted.
  - key (touch_key, write.rs:2267-2290): must already exist in djmdKey by ScaleName. Otherwise refused ("a new djmdKey row needs its Seq explained by a diff recording"). Empty clears KeyID.
  - title and lyricist: plain text.
  - bpm: goes to grid::set_tempo (finding 3). Refusals: "The beat grid is locked. Unlock it to edit." (details.rs:108-110 and grid.rs:485), rekordbox running (write_refusal_reason). After success: forget grid history, emit grid:changed, reload, then edit-history with clear_redo only (details.rs:111-127).
- Client-side pre-check (fields.ts acceptable): year, trackNumber, discNumber, playCount by digit regex; bpm 20 to 400 (conflicts, finding 3). Refused text is put back in the box, no round trip.
- Info panel (InfoPanel.tsx:266-416): editable title, artist, year (numeric), album, trackNumber (numeric), originalArtist, discNumber (numeric), key (select of djmdKey names), composer, lyricist, playCount (numeric), rating (Stars), comment (CommentBox), remixer, label, genre (datalist), colour. Read-only (Locked): Release Date, Album Artist, BPM, Message, Mix Name, and the auto-load HotCue and Publish checkboxes. Field commit on Enter or blur; Escape reverts (Field, InfoPanel.tsx ~476-535). Messages "<Field label> saved." (FIELD_LABEL, InfoPanel.tsx:247-263: "Track Title", "Artist", "Album", "Year", "Track number", "Disc number", "Original Artist", "Composer", "Remixer", "Lyricist", "DJ Play Count", "Genre", "Label", "Key", "BPM").
- Pending overlay (App.tsx:83-86 ROW_FIELDS): title, artist, album, genre, label show before the round trip. Other fields wait for the re-read.
- Table editable columns (TrackTable.tsx:150-157): title, artist, album, genre, label, bpm, plus comment. Title is click-on-selected to edit and double-click to load.
- My Tags (InfoPanel.tsx ~390-405): categories from track_lookups (myTagCategories). Each tag toggles. The new list is the current list plus or minus the tag. set_my_tags makes it exact (write.rs:1718-1790): tags must exist with Attribute 0, else "no My Tag {id}". Memberships not present are soft-deleted; new ones go on the end of each tag's list. Messages "My Tag added." / "My Tag removed.". Undo via TrackTagEdit.
- Artwork (InfoPanel.tsx:722-780, Artwork tab): Add Artwork = pickImage("Choose the artwork") then add_artwork. Delete Artwork = confirm "Remove this track's artwork? The image file stays where it is." then clear_artwork. Delete disabled when no artwork. Messages "Artwork added." / "Artwork removed.".
- Artwork writer (write.rs:2034-2062): JPEG or PNG only ("{path} is not a JPEG or PNG"). Copies into /PIONEER/Artwork/<3 hex>/<uuid>/artwork.<ext> with 240px and 80px JPEG variants (non-square cropped to centre). ImagePath set. Clear sets ImagePath to "" and leaves the file.
- Embedded art: analysis.rs:171 calls import_artwork after analysis, only when the track has no ImagePath (write.rs:2063-2096).
- Analysis, grid lock and BPM-driven edits are documented in area 8.

## 7. Area 5: Tag List, history and collection

### Tag List
- add_to_tag_list(tracks) -> u32 (commands.rs:2470). Appends in order; a track already on the list is skipped (write.rs:940-982). Any missing track refuses the whole batch ("no track {id}") since the transaction is not committed. Rows have usn NULL and the counter is not advanced (rekordbox-matching shape, per comment at write.rs:933-939).
- remove_from_tag_list(tracks) -> u32 (2479). Soft-delete then renumber (write.rs:984-1015).
- clear_tag_list() -> u32 (2489). Soft-deletes all rows. No UI caller (finding 13).
- reload_tags(tracks) -> u32 (2454). Per track, Writer::reload_tags (write.rs:2122-2172): reads the file's tags; writes Title, Commnt, ArtistID, AlbumID, GenreID, LabelID, ReleaseYear, TrackNo; fields the file leaves empty are kept. Message "Tags reloaded on N tracks.". Touched::Tracks (full reload), not undoable. Not cancelled on mid-batch error (earlier tracks stay written).
- Menu: "Add To Tag List" (needs track, enabled under readOnly? no; it is in WRITES), "Reload Tag" (WRITES), "Remove from Tag List" (Tag List view only).
- Tag List view: spec.source.kind === "tagList", from the source rail "Tag List" (SourceRail.tsx:42). Tag-list edits only refresh Tag-List views (tag-list:changed).

### History
- record_play(track) -> u32 (commands.rs:2857; Touched::Histories([track])). Trigger: Player.tsx:1205-1229. Counts seconds while playing; at 60 s (PLAY_RECORD_SECONDS, Player.tsx:539) records once per loaded track when Advanced ▸ Others ▸ "Record play history" is on and the library is not readOnly. Error message "The play could not be recorded.".
- Writer (write.rs:1909-1940): finds or creates the month folder and the session named "HISTORY yyyy-mm-dd" for today (rbl-db history_node/month_folder). Appends a play with a new djmdSongHistory row and DJPlayCount += 1 (append_play, write.rs ~2870-2895).
- remove_from_history(history, tracks) -> u32 (commands.rs:2867; Histories([])). Soft-deletes plays and renumbers (write.rs:2001-2025). DJPlayCount NOT decremented. Not undoable. Message "Removed N plays from the history.". Menu "Remove from History" needs a history view.
- LINK history (new_link_history, add_to_history, write.rs:1942-2000) is for the LINK session only.

### Reset play count
- reset_play_count(tracks) -> EditHistoryDto (commands.rs:2894). Sets DJPlayCount to 0 per track via set_field_with_undo (recorded as Track(vec), label "Track Edit"). No confirmation. Message "DJ Play Count reset on N tracks.".

### Remove from collection
- remove_from_collection(tracks) -> u32 (commands.rs:2913; permanent_edit, Touched::Tracks). Writer::delete_track (write.rs:2317-2360): tombstones the content row and its djmdSongPlaylist memberships, renumbering each affected playlist. History, Tag List, My Tags and cues are not touched (finding 6). Files stay on disk. Whole undo history is cleared.
- UI (App.tsx:1378-1395): native ask (backend.confirm) "Remove N tracks from the collection? This can’t be undone. The files stay where they are." (N = "1 track" or "N tracks"). Only if confirmed: message "Removed N tracks from the collection.".
- Duplicates section also calls removeFromCollection after its own confirm (AdvancedPane.tsx ~260-275).
- Menu "Remove from Collection" is enabled regardless of view (contextMenus.ts:167). Under readOnly it is disabled (WRITES).

### Convert Memory Cues to Hot Cues
- convert_memory_cues_to_hot(track) -> u32 (cues.rs:234). Messages: "N memory cue(s) converted to hot cues." or "No memory cue to convert, or every hot cue slot is taken.".

## 8. Area 6: import

### Commands and shapes
- import_files(paths: Vec<String>) -> ImportReportDto {imported: u32, skipped: [String], tracks: [{id,title}], existing: [{id,title}]} (commands.rs:2158-2216). Title = file name.
- import_xml(path) -> XmlImportReportDto {imported, existing: u32, skipped, playlists, cues, tracks} (commands.rs:2568).
- import_itunes(path) -> XmlImportReportDto (2587).
- itunes_default_library() -> Option<{path, tree}> (2625; candidates from dirs::audio_dir: Music/Library.xml, then iTunes/iTunes Music Library.xml, itunes.rs:35-37).
- itunes_library_at(path) -> {path, tree} (2644).
- import_itunes_selected(path, ids: ["itunes:<n>"]) -> XmlImportReportDto (2661). Error "Select at least one iTunes playlist to import." if no ids. Uses rbl_db::xml::subset (folders kept where needed).
- import_collection (2681-2729): one writer session for the whole document (writing.write), progress event per track (import:progress), reload if imported or playlists > 0.
- export_xml(path) -> u32 (commands.rs:2768), menu "Export Collection in xml format…".

### File and folder import
- Pickers (client.ts:167-197): importFiles uses multiple-select with the audio extensions list. importFolder uses directory mode. Titles "Add music to the library" and "Add a folder of music to the library". Cancel is a null outcome (note cleared).
- Menu items "import" and "import-folder" are writes (menu.ts:31-32, 59-60), so under readOnly they are refused by resolveMenu.
- expand_import_paths (commands.rs:2110-2157): chosen files are kept even if not audio (reported as skipped by the writer). Directories are walked breadth-first to depth 16, up to 500,000 entries in all. Hidden directories (leading dot) are skipped. Only audio extensions are collected: mp3, m4a, aac, flac, wav, aiff, aif, ogg, opus (rbl-db/src/import.rs:15-16).
- Per file (commands.rs:2170-2199): track_id_at(file) (exact FolderPath match) becomes existing (no new row). Otherwise import_file. WriteRefused becomes skipped "path: reason".
- Writer::import_file (write.rs:1110-1224): normalises the path; read_tags via lofty (refuses non-audio: "{ext} is not a format rekordbox plays"); refuses if the FolderPath already exists ("{path} is already in the library"); interns artist, album, genre, label; Analysed left NULL; new row shape matches rekordbox's own. Title falls back to the file name (import.rs docs).
- Message: "Choosing files to import…" then "Imported X of Y files[; K skipped][; M already in the library]." (App.tsx:1622-1650). Analysis queued when Auto Analysis is on (imported tracks only).

### rekordbox XML (rbl-db/src/xml.rs)
- Parsing: TRACK elements (TrackID, Name, Artist, Location (file://localhost URL, percent-decoded), Rating, Comments, POSITION_MARK cues) and PLAYLISTS NODEs (Type 0 folder, 1 playlist with TRACK Key children).
- Rating: stars = (rating + 25) / 51, capped at 5 (xml.rs:199-203). Values 0, 51, 102, 153, 204, 255.
- Cues (add_cues, xml.rs ~345-380): Num -1 is a memory cue; 0 and up is a hot cue by letter from A; seconds become milliseconds; a mark with End after Start is a loop.
- Import body (xml.rs:274-342): track missing or not a file is skipped with "{label}: not a file" or "{label}: {path} is not there". A duplicate is reused (existing_id) and keeps its own cues. Rating and comment are applied only to newly imported tracks. Tree built with a stack of ids by depth. Folders via create_folder, playlists via create_playlist then add_tracks.
- Errors: "That is not a rekordbox XML collection." if no tracks and no nodes (commands.rs:2573-2578).
- Message (App.tsx:1664-1682): "N tracks imported, M already here, K skipped, P playlists, C cues." (singular/plural handled).

### iTunes / Music.app (rbl-db/src/itunes.rs)
- Reads Apple plist: Tracks (dict) and Playlists (array). Fields: Name, Artist, Location, Rating (0 to 100, twenty per star: (r + 10) / 20, xml.rs:206-207), Comments; playlist Name, Folder, Persistent ID, Parent, Master, Distinguished Kind, Playlist Items.
- Master and Distinguished (built-in) playlists are dropped (itunes.rs:111). Folders are kept.
- Error: "That is not an iTunes or Music library file.".

### Sync Manager iTunes column (SyncManager.tsx:370-445)
- Default library found automatically, or chosen via a picker (chooseItunesLibrary, title "Choose the iTunes or Music Library.xml").
- Ticked playlists are imported with import_itunes_selected. Refused if rekordbox is open ("Quit rekordbox to import from iTunes."). Message "Imported N playlists from iTunes (A tracks, B new)." plus "Skipped K tracks." and the list.

### USB import (usb_import.rs, command import_usb)
- import_usb(path, cues, history, settings) -> ImportReport {tracks, histories, settings, skipped, warnings}. Requires the device to be mounted (rbl_devices::list, error "Device is no longer connected").
- Cues and grid: matches USB content ids to library ids through the export manifest and OneLibrary content table, checked against masterDbId (usb_import.rs:85-105). Locked grids and tracks without cue analysis are skipped. Writes analysis files through a file journal, then the cue rows, then emits grid:changed and cues:changed per track (usb_import.rs:107-147, 61-62).
- History: rebuilds sessions as "<name> (USB xxxxxx)" with a deterministic UUID; refuses partial matches (session left on the stick, warning) (usb_import.rs:149-166).
- Settings: MYSETTING.DAT, MYSETTING2.DAT, DJMMYSETTING.DAT validated (length, marker, CRC) and copied to backup_dir/../usb-settings (usb_import.rs:168-180, 184-197).
- Protection: the cue and history import rows in SyncManager show "Turn off Library Protection to import cues and grids." / "…play history." (SyncManager.tsx:166-167). The backend does not check protection.
- Note: the progress/status code for the Sync Manager is out of scope here.

## 9. Area 7: missing tracks, relocate, auto relocate, duplicates

### Commands
- missing_tracks(limit) -> {total, tracks: [{id,title,artist,path}]} (commands.rs:2058-2085). Index-based Path::exists per track. Empty path is not "missing" (never had a file). Count exact; list bounded by limit.
- relocate_track(track, path) -> u32 (commands.rs:2218). Writer::relocate (write.rs:2294-2316): path must be a file; sets FolderPath and FileNameL. Analysis, cues and memberships are kept (test writes.rs:953-1011). Not undoable.
- auto_relocate(folders: [String]) -> {relocated, unresolved} (relocate.rs:89-144). Missing tracks are collected from the index first; a clean library does no walk. index_folders (relocate.rs:43-80) walks each folder breadth-first, depth 16, max 500,000 entries, skipping hidden dirs. Name collisions: first folder wins, shallower wins. Writes all relocations in one writer session. Reloads only if any relocated.
- find_duplicates(limit) -> {groups, extra, shown: [{title, artist, tracks: [{id, path, durationSec, present}]}]} (commands.rs:2516-2565). Key = case- and accent-folded title plus folded artist (artist NO_ID is one bucket). Empty titles skipped. Groups sorted by title. extra = sum(len - 1). present = file exists.

### UI and where it lives
- Preferences > Advanced > Database (AdvancedPane.tsx). The "Library" facts show Tracks, Playlists, Database version, and Editing ("Read-only — rekordbox is running" / "Protected — see Browse" / "Available").
- **Duplicates section: always visible.** "Find duplicates" button. Summary "N titles with more than one copy, K extra copies in all.". Shows the first 20 groups (DUPLICATE_GROUPS_SHOWN). Each copy row: m:ss · path, "(file missing)" if absent, and a Remove button (disabled under readOnly or protection, or while busy). Remove asks "Remove this copy of <title> from the collection? This can’t be undone. The file stays where it is." then calls removeFromCollection and rescans. Empty: "No two tracks share a title and an artist.".
- **Missing files and Auto Relocate Search Folders: hidden.** MISSING_FILES_ENABLED = false (AdvancedPane.tsx:27-35), and the File > Missing File Manager item is hidden by MISSING_FILE_MANAGER = false (src-tauri/src/menu.rs:85, 155). The code is complete and can be turned on.
  - Search folders: list, Add (pickFolder "Choose a folder to search for moved files"), Del. Stored in advanced.relocateFolders.
  - "Check for missing files" then: "Every track's file is where the library expects it." or "N tracks cannot be found." Show first 20 (MISSING_SHOWN).
  - "Auto Relocate" (disabled under readOnly, no folders, or scanning) then "R relocated[, U not found in the search folders.]". Hint with no folders: "Add a search folder above to relocate them automatically.".
  - Per row "Locate…": relocateTrack (client.ts:415-432) opens a file picker (title "Choose the file for this track", audio extensions) and calls relocate_track. Cancelling leaves the list alone.
- Match rule for auto relocate is by file name only (relocate.rs:4-8). A same-named different recording is not checked.

## 10. Area 8: analysis

### Commands
- analyse_track(trackId, mode?: "rbxport" default | "rekordbox", settings?: {bpmGrid=true, key=true, highPrecision=true, minBpm=70, maxBpm=180}) -> AnalysisResultDto {trackId, analysed, bpmX100, key, beats, peak, durationSec, elapsedMs, analysisPath} (analysis.rs:97-121). Emits analysis:changed(trackId).
- edit_phrase(track, edit) -> bool (analysis.rs ~330-370). Emits analysis:changed on change. Refused when rekordbox runs.
- grid_lock(track, on) -> GridState (grid.rs:631, emits grid:changed). The "Analysis Lock" menu sets it per selected track.

### Behaviour and errors
- settings validation (analysis.rs:52-60):
  - both bpmGrid and key off: "Select BPM / Grid or KEY to analyze.".
  - minBpm/maxBpm outside 40 to 300, or min >= max: "Choose a valid BPM range between 40 and 300.".
  - unknown mode: "Unknown analysis mode.".
- Order (analysis.rs:136-160): not in library, grid-lock check (ensure_analysis_unlocked), empty path ("That track has no file path."), then rekordbox-running check before decode ("rekordbox is running. Quit it before analysing.", ReadOnly). Then decode (cap 1800 s, DECODE_CAP_SECS line 30; "That file could not be decoded.").
- Writes under edit_gate and analysis_write: file journal recover, import_artwork, DAT/EXT/2EX written atomically (each to a temp name then renamed), register_analysis (write.rs:1259), ensure_detected_key. Key-only mode uses analyse_key_only.
- Settings are validated server-side. Results return to the client, which draws BPM, key and the analysed flag immediately.

### Queue (lib/queue.ts, store/useAnalysis.ts)
- SLOTS = 3 default (queue.ts:19); ANALYSIS_SLOTS = [1..4] (queue.ts:20), clamped to 1..4 (queue.ts:86).
- State: pending, running, done, failed[{id,title,reason}], cancelling flag.
- enqueue dedupes against pending and running (queue.ts:67-80). start fills free slots. succeed/fail move items. cancel stops starting new items; running items finish. reset clears.
- useAnalysis: effect sends analyseTrack for each running item (inFlight set prevents duplicates). Each success calls onAnalysed, which sets a pending overlay for analysed, bpmX100, key, durationSec (App.tsx:501-512). onDrained (run ended, any reason) calls reloadLibrary once (App.tsx:513).
- add(items, settings) captures settings at enqueue time (useAnalysis.ts:87-92). Later preference changes do not alter a queued batch.

### Triggers and gating
- Track menu "Analyze Track" (contextMenus.ts:129, WRITES: "analyse"). Deck ≡ menu "Analyze Track" (contextMenus deckMenu line 335) uses analyseOne.
- Cmd+Shift+A = analyseSelection (shortcuts.ts:483) on the Browse pane: opens AnalysisDialog (App.tsx:2537-2545) with the track count and initialMode. Confirm re-checks readOnly.
- analyseTracks (App.tsx:1598-1605): if readOnly, refuse "The library is read-only, so nothing can be analysed.". Otherwise open the dialog.
- Auto Analysis (analysisPrefs.auto) queues imported tracks after import (App.tsx ~908, 958, 1414, 1450, 1642, 1678).

### Status bar (StatusBar.tsx:66-116)
- Progress from analysisProgress: completed = done + failed.length, total. Percent floored.
- Stop button (cancel). Failures count via analysisFailures.
- Errors on the same line as role="alert" (10 s, App.tsx:2652-2655 note timer).

## 11. Area 9: native drag-out and drop

### drag_tracks (src-tauri/src/file_drag.rs:4-55)
- Args: ids: [String]. Returns Result<(), String>. macOS only; other platforms error "Dragging files out is currently supported on macOS.".
- resolve_paths (file_drag.rs:58-79): every id must have an audio path, absolute and existing. Dedupes. Errors: "No tracks were selected.", "A selected track has no audio file.", "The audio file is missing: <path>".
- Starts drag::start_drag on the main thread with DragMode::Copy and the 32x32 icon. Resolves when the drag ends (channel). Panics are caught with run_command.
- Frontend: nativeTrackDragging() = isTauri && mac (client.ts ~22-25). TrackRow (TrackTable.tsx:347-625): pointer press followed by >5 px movement starts the native drag (TrackTable.tsx:1080-1100). The HTML draggable attribute is off in native mode. Failure is reported via onDragError.

### file_drop.rs (dropped_file_paths)
- Args: names: [String]. macOS: reads the NSPasteboard drag board's file URLs (file_drop.rs:19-50). validate_paths (file_drop.rs:55-67): the multiset of file names must match exactly (order-insensitive) and the counts must agree; else "The dropped files' locations could not be resolved. Please drag them from Finder again.". Non-macOS: "This platform did not provide the dropped files' locations.".
- client.ts:37-47 droppedFilePaths: uses File.path if the WebView provides it; otherwise invokes dropped_file_paths.
- Linux-style native drops (client.ts subscribeNativeFileDrops) feed App.tsx's native-drop effect. Targets: element at point with [data-file-drop-playlist], or the track scroll area while a playlist is selected. Otherwise refuse.

### Rules
- Drop onto the tree row is allowed only for playlists. Folders and smart playlists refuse (TreeView:140, 567). File drops go to fileDroppable playlists only.
- Track-to-tree drops use the HTML5 drag payload and the `dragging` flag (App.tsx:2191).
- When readOnly, onDropFiles and onMoveNode are undefined (App.tsx:2192, 2376).

## 12. Area 10: testing

### Rust integration (src-tauri/tests/commands.rs, 1502 lines)
- Harness (lines 51-100): shell() builds a fixture library in a tempdir with rbl_db::fixture::build(Shape::default()) (40 tracks, 3 playlists of 5 tracks each, 2 history sessions, start_usn 1000). AppState::with_backups(tempdir/backups), then set_library(library, read_only=false, db_version, 0, location). Nothing can reach the real library: fixture is_real_install=false.
- Mock app: tauri::test::mock_app(); AppState, Player and Preview are managed; the test listens to library:changed (generations recorded) and tag-list:changed.
- run(fut) = tauri::async_runtime::block_on. Helpers: tree(), node(name), open(spec), rows(view), playlist_rows(id), deck_state(), pull_until(...).
- Key tests to mirror:
  - a_playlist_is_made_filled_reordered_renamed_moved_and_deleted (424)
  - a_deleted_playlist_tree_can_be_undone_and_redone (502)
  - library_history_names_and_reverses_each_supported_edit (537)
  - removing_from_collection_is_permanent_and_clears_history (594)
  - every_edit_bumps_the_generation_and_tells_the_interface (604)
  - library_backups_are_manual_only (624)
  - an_edit_closes_the_views_that_were_open_over_the_old_library (646)
  - a_write_the_library_refuses_is_read_only_to_the_interface_and_changes_nothing (660): asserts ErrorKind::ReadOnly, no reload, no event
  - the_tag_list_takes_tracks_in_order_ignores_a_repeat_and_empties_on_clear (684); a_tag_list_add_naming_a_track_that_is_not_there... (731)
  - a_rating_a_comment_and_a_colour_show_in_the_rows_after_the_edit (755); the_information_panel_reads_the_record_and_writes_a_field... (781)
  - an_intelligent_playlist_is_made_from_a_rule_and_its_rule_is_edited (1382); an_intelligent_playlist_on_a_my_tag... (1430)
  - an_imported_file_goes_into_a_playlist_and_plays_on_a_deck (989)
- Unit tests inside src-tauri: commands.rs tests for expand_import_paths (1700s range, 3 tests); relocate.rs (index_folders precedence and hidden dirs); usb_import.rs (import with a fixture and file journal; validate_settings; onelibrary tree; interrupted publication message); file_drag.rs (resolve_paths); file_drop.rs (validate_paths and a pasteboard round-trip test on macOS with a private pasteboard name).

### rbl-db write tests (crates/rbl-db/tests/writes.rs, 2278 lines)
- fixture_with(Shape) builds a fixture, then Writer::open(location, tempdir/backups). Writer is the unit under test. Helpers: track_numbers(playlist), children(parent), count, one.
- Examples: the_library_is_backed_up_before_the_first_write_and_only_once (810), a_writer_told_the_session_is_backed_up… (829), a_refused_action_leaves_nothing_behind (876), a_key_is_found_never_made (639), a_number_that_is_not_one_is_refused_rather_than_zeroed (551), relocating_leaves_the_analysis_and_memberships_alone (991), a_partial_reorder_keeps_the_tracks_it_did_not_mention (432), a_playlist_deletion_can_be_undone_and_redone_exactly (322).
- fixture.rs: tables transcribed column-for-column from the real schema (via the schema_dump example). track_id(i), playlist_id(i), history_id(i). point_at_audio, set_analysis_path, set_image_path, set_tempo helpers.
- lib.rs test read_write_against_the_real_library_is_refused_in_test_mode (lib.rs:400) plus pure tests of write_refusal_reason.

### rbl-app and frontend
- rbl-app/src/state.rs:856 small_edits_refresh_and_persist (fixture, backup, edit, reopen). rbl-app/src/events.rs:69-76 payload format tests.
- Frontend unit (vitest, `npm test`): contextMenus.test.ts, tree.test.ts, SmartPlaylistEditor.test.tsx (470 lines), InfoPanel.test.ts, TrackTable.columns.test.ts, useAnalysis.test.tsx, queue.test.ts, editHistory.test.ts, menu.test.ts, shortcuts.test.ts.
- Playwright e2e (e2e/playlist-management.spec.ts, 527 lines; `npm run e2e`): runs the web build against ipc/backend-mock.ts. Opens at /?writable=1 (mock readOnly unless writable=1, backend-mock.ts:1624). Mock disableReadOnly rejects with the env message (backend-mock.ts:1628). Covers create, drop, remove, delete, reorder, rename, protected tree menu, and rename refused while rekordbox runs.

### Pattern for the port (no real library)
1. Build a fixture in a temp directory with the real schema (fixture::build). Verify is_real_install=false.
2. Create AppState::with_backups(tmp/backups) and set_library(...) pointing at the fixture.
3. Call the command or rbl-app function directly; assert on AppState, the reloaded index and the event sink.
4. Use a recording EventSink (a Vec<AppEvent> behind a Mutex) to assert event order and payloads, in place of the mock Tauri listener.
5. Use RBXPORT_TEST=1 in CI so real-install writes are refused even by mistake.

## 13. Refusal and confirmation strings (for the port's copy)
- Gate: "Editing is locked by Library Protection. Turn it off in Preferences to edit." / "Editing is locked while rekordbox is running. Quit rekordbox to enable editing." / "rekordbox is running. Quit it before making changes." / "A library restore is unfinished. Restart the app to recover it before editing." / "Set RBX_DISABLE_READ_ONLY before launching rbxport to enable this override.".
- Loose files: "That file is not in the collection. Import it first.".
- Analysis: "The library is read-only, so nothing can be analysed." / "rekordbox is running. Quit it before analysing.".
- Confirms (native ask, warning kind): "Remove N tracks from the collection? This can’t be undone. The files stay where they are."; "Remove this track's artwork? The image file stays where it is."; "Remove this copy of <title> from the collection? …"; "Delete the backup from {date}? This cannot be undone." (BackupsPane).
- Sync: "Quit rekordbox to enable synchronization.", "Quit rekordbox to import from iTunes.".
- No confirmation exists for: Delete Playlist/Folder, Remove from Playlist, Remove from History, Reset DJ Play Count, Sort Items, Rename, Add/Clear playlist artwork.

## Caveats
- I did not run the test suite or the app. Behaviour above is from reading the code. Items marked [ASSUME] or "verify" need checking against rekordbox or the rbl-index loader.
- No files were created or modified.