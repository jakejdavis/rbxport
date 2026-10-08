# Native macOS port — plan

Goal: replace the Tauri/React UI with SwiftUI + AppKit, keep the Rust crates. macOS only, no auto-updater.
The React app stays buildable until parity: it is the reference spec (`src/ipc/types.ts` is the call surface).

## Architecture

```
crates/rbl-*        existing domain crates (unchanged)
crates/rbl-app      NEW: tauri-free app core — AppState, errors, view registry, command bodies,
                    startup recovery, an EventSink trait. Both src-tauri and rbl-ffi depend on it.
crates/rbl-ffi      thin UniFFI layer over rbl-app: records/enums, typed ids, callback interface for events
macos/              XcodeGen project; Swift `actor Backend` wraps rbl-ffi; @Observable models; SwiftUI shell,
                    AppKit for table / outline / waveforms
```

Conventions:
- Typed Swift-facing API: enums for sort keys, node kinds, sources; no stringly ids across the bridge.
- Low-rate events (library changed, export progress…) push via a UniFFI callback interface → `AsyncStream`.
- High-rate state (deck position, meters) is **pulled** by Swift once per display frame, not pushed.
- Bulk bytes (waveforms, artwork) cross as `Vec<u8>` → `Data`, cached Swift-side.
- Real rekordbox library is only ever opened read-only until Phase 4, and writes go through rbl-app's existing edit gate.

## Phases

0. **Spike** ✅ — rbl-ffi (copied helpers), sidebar tree, lazy NSTableView, sort, search.
1. **Foundation** — extract `rbl-app` from src-tauri (state.rs, error.rs, dto conversions, build_tree, recovery,
   reload); port src-tauri to use it; rebuild rbl-ffi on it and delete the copies. Event callback interface.
   Swift `Backend` actor + `BackendProtocol` for a mock. Audit rbl-db's hot-journal read-write reopen.
2. **Browse parity** — column chooser/persistence, extra columns, filters, search field scope, multi-select,
   context menus, info panel, artwork, related/tag-list/folder (Explorer) sources, keyboard nav, track preview.
3. **Player** — rbl-deck over FFI (Rubber Band build), deck state pull loop, waveform rendering (Core Animation
   or Metal), cues/loops, dual deck, mixer/EQ, metronome, beat-grid editing, audio device prefs.
4. **Library editing** — playlist/folder CRUD, drag & drop (reorder, add, drop files, drag-out to Finder),
   import files/XML/iTunes, ratings/colours/comments/My Tags, smart playlists, undo/redo, relocate, duplicates.
5. **Devices** — USB export, Sync Manager window, device settings, eject, Pro DJ Link status/peers/control.
6. **App chrome** — Settings scene (all prefs panes), menu bar commands, keymap, backups, bug report window,
   AppleScript (`.sdef` + Rust Cocoa scripting or move to Swift), String Catalogs from the 17 locales.
7. **Cutover** — delete src-tauri + src/, macOS CI (build, test, sign, notarize, DMG).

Phases 2, 4, 5, 6 are largely independent after Phase 1 and can run in parallel worktrees; Phase 3 is the largest.

## Workflow per slice

1. Explore (Haiku): map the React view(s) + commands + DTOs for the slice → short spec.
2. Build (Sonnet): rbl-app/rbl-ffi additions with Rust tests, Swift UI, Swift unit tests against the mock.
3. Review (orchestrator): diff review, `cargo clippy/test`, `xcodebuild`, launch check; user eyeballs UI.
4. Commit one slice per commit.
