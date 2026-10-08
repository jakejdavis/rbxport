# Phase 2 — browse parity spec

Distilled from the React app (`src/`). React file references are the source of truth for details;
read them when a line here is ambiguous. **Native idiom beats pixel parity**: use NSTableView/
NSOutlineView/NSMenu behaviour where it covers the feature, and match rekordbox semantics, not CSS.

## Decisions on gaps in the React build
- Shift+↑/↓ extends selection (NSTableView does this natively) — keep it.
- Search is debounced (~200 ms). Search query/scope are not persisted.
- File type code 6 shows "M4A" everywhere.
- Status bar selection text: "N tracks · total time · total size" when >1 selected (React has
  `formatSelectionSummary` in `src/lib/format.ts`, unused).
- "Auto-size column" measures content (NSTableColumn `sizeToFit`-style), not just reset width.
- Filter bar shows per-value counts from `filter_values`.
- Sidebar uses native **sections** (Playlists, Histories, Explorer, Devices, Tag List) in one
  source list instead of React's rail-filters-the-tree. Collapsible section headers.
- Related Tracks: out of scope (unreachable in React too).
- No row tint for colour, no missing-file styling, no type-to-select (none exist in React).
- My Tag filter columns: omit (inert in React).

## Track table (`src/views/browser/TrackTable.tsx`, `src/lib/columns.ts`, `src/store/useColumns.ts`)
- 40-column catalogue: id, label, width, alignment, sortable, extra (needs `fetch_rows` extra_columns).
  Port the table in `src/lib/columns.ts` exactly (ids/labels/widths/alignment/`MENU_ORDER`).
  Extra (22): size, discNo, albumArtist, composer, lyricist, fileType, year, mixName, remixer,
  originalArtist, sampleRate, bitrate, bitDepth, location, dateCreated, publishTrackInfo, message,
  color, djPlayCount, myTag, trackNumber, cloud. Only request visible extras; changing them reopens the view.
- Formats: BPM x100→2dp; time m:ss; dates M/D/YY; size MB/GB 1dp; sample rate kHz; bitrate "N kbps";
  bit depth "N bit"; disc 0→blank; fileType {1 MP3, 4 M4A, 5 FLAC, 6 M4A, 11 WAV, 12 AIFF};
  color COLOR_NAMES[v-1]; publishTrackInfo On/Off; cloud "Cloud" if path starts `/contents_`;
  hotCue letters joined ", "; Attribute = analysed star + "CUE" if hot cues; Rating = 5 stars (display only for now).
- Key display classic vs Camelot (`keyCamelot` sort when alphanumeric). Pref default: classic.
- Defaults per **context** (collection | playlist | history | folder): see `columns.ts`
  (non-folder: #, preview, artwork, title, key, bpm, duration, rating, artist, comment, label,
  dateAdded, releaseDate; folder has its own list/widths). `#` fixed first, title cannot be hidden.
- Header right-click: Auto-size this column / Auto-size all / separator / checkbox per column.
- Reorder + resize (32–1200 px) natively; `#` cannot move.
- Sort: click cycles ascending → descending → off (trackNo / view order).
- Persist per context in UserDefaults: `{order, widths}`, sanitised on load (drop unknown/dupes,
  restore title, clamp widths, empty → default). Reset to defaults command.
- Selection by **track id** (survives re-sort/reload). Click, ⌘-click, ⇧-click range (use
  `view_ids_in_range` for ids of unloaded rows), ⌘A all, arrows/PageUp/Down/Home/End, ⌘↑/↓.
- Double-click / Return: "load to deck" — Phase 3; for now no-op hook on the model.
- Page cache: 128-row pages, LRU, prefetch neighbours; invalidate on spec change / LibraryChanged.

## Search & filter (`src/lib/search.ts`, `src/views/browser/TrackFilter.tsx`, `src/lib/trackFilter.ts`)
- Search scope menu (SearchField enum): all, title, artist, album, genre, year, bpm, composer,
  albumArtist, remixer, label, comment, originalArtist, mixName. ⌘F focuses, Esc clears.
- Filter bar toggle (persist open/closed only). Columns: BPM (values + ±0..6 % tolerance; master
  BPM = nil until Phase 3), KEY, RATING 0–5, COLOR (8 names with dots). Per-column enable tick;
  click picks one, ⌘-click toggles; "All" clears; reset button. Only ticked, non-empty columns are sent.
- `filter_values(spec without filter)` supplies BPMs/keys with counts; re-run on source/query/library change.

## Sources & sidebar (`src/views/tree/*`, `src/lib/tree.ts`, `src/lib/explorer.ts`)
- From `playlist_tree`: allTracks, collection heading, folder, playlist, smartPlaylist, histories
  heading, history (year → month folders → sessions; months start collapsed).
- Tag List node (source `tagList`). Devices (`list_devices`) — list only in Phase 2, eject later.
- Explorer: `explorer_roots` → roots; `explorer_children(path)` lazily on expand (cap 2000, "N more
  folders not shown" note row); selecting a directory opens a `folder` source view (rows are loose
  files, ids `file:<path>`).
- Icons per kind (SF Symbols). Optional playlist child counts (pref, default off).
- Persist expansion state and selected node id across launches.

## Context menus (`src/lib/contextMenus.ts`) — Phase 2 implements read-only entries only
- Track row: Show in Finder (NSWorkspace on the track path), Show information (open info panel),
  Load to player 1/2 (disabled until Phase 3). Show edit entries greyed (they arrive in Phase 4).
- Tree playlist/folder: Export a playlist to a file ▸ m3u8 / txt (`export_playlist_file`, NSSavePanel).
  Edit entries greyed.

## Info panel (`src/views/info/InfoPanel.tsx`, `fields.ts`) — read-only in Phase 2
- Toggleable trailing inspector. Subject = selected row (single selection).
- Summary: artwork (or placeholder tinted by `artwork_hue`), title/artist/album; facts: Time,
  File Type, Size, Date Created, Sample Rate, Bitrate, DJ Play Count, Location.
- Info tab: all fields from `track_details` displayed (editing in Phase 4).
- Artwork tab: large artwork.
- Artwork bytes: `library.artwork_path_of(id)` resolved under share root with `resolve_under`
  (refuse `..`/escaping symlinks), 8 MiB cap (see `src-tauri/src/protocol.rs`). Cache NSImages.

## Waveform preview column (`src/views/browser/WaveformPreview.tsx`, `src/canvas/waveform.ts`)
- Analysed rows only. `track_waveform(id, kind)` bytes (kind from palette pref: bands/mono/colour;
  see `waveform_bytes` in `src-tauri/src/commands.rs`). Draw to column width × ~15 pt, cache bitmaps,
  overlay hot cue badges + memory cue markers. Throttle (≤16 in flight). Click-to-preview: Phase 3.

## Backend moves needed (src-tauri → rbl-app, then FFI)
filter_values, track_details + track_lookups (+ DTOs from details.rs), track_cues, waveform_bytes,
artwork resolution (protocol.rs logic, no http types), explorer roots/children/open_folder/fetch/ids,
list_devices, export_playlist_file, track path lookup for reveal. Leave thin tauri wrappers behind;
React app must keep working.
