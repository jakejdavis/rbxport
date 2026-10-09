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

## Status

Phases 0-6 are done on branch `native-macos-spike`; the React/Tauri app is untouched and still builds.

- 0 Spike: `3b7d3a8`
- 1 Foundation (rbl-app extraction, Swift `Backend` actor, events): `13c8fa2`, `35c408e`
- 2 Browse parity (table, filters, sidebar, context menus, info panel, artwork): `a1a6c07`, `a65f2ca`, `d1785cd`
- 3 Player (deck A, waveforms, cues, loops, grid, dual deck, mixer): `22192df`, `3ff707e`, `a9e650f`
- 4 Library editing (write gate, undo/redo, playlists, metadata, import, analysis, drag-out): `2a0a966`, `e2a1d7a`, `5f8acff`
- 5 Devices (USB export, Sync Manager, USB/iTunes import, Pro DJ Link): `bb084de`, `cbb4cbb`, `686b523`
- 6 App chrome (prefs, menus, keymap, backups, bug report, AppleScript, localisation): `460df80`, `f78df2c`, `70ca20f`, `09619f5`
- 7 prep (uncommitted at time of writing): narrow-window player layouts, sidebar icon tint, deck-key window guard,
  `macos/scripts/package.sh` (Release app + DMG, optional notarization), `.github/workflows/native-macos.yml`.

### Known gaps and deferred items

- 2 PLAYER layout has no GRID row or memory SET/DEL buttons (the keys work); narrow rows also drop loop halve/double,
  the beat-jump size menu and then the Q/metronome chips.
- Apple silicon only (`ARCHS: arm64`); no universal build.
- Hardened runtime is off and signing is the personal Apple Development team: notarization needs a Developer ID
  identity and `ENABLE_HARDENED_RUNTIME: YES` (plus any entitlements the audio and AppleScript paths need).
- AppleScript has unit tests only; it has not been exercised through a real Automation grant.
- Live Pro DJ Link, real USB export and real audio output are covered by mocks and fixtures, not by hardware runs.
- The CI workflow has not run on GitHub yet.
- No auto-updater (by design).

### Cutover steps (waiting for the owner's go-ahead; none done)

1. Delete `src-tauri/src` and `src/` (the React reference app).
2. Move the shared crates out of the Tauri-shaped layout (workspace members, `rbxport` crate, root `Cargo.toml`).
3. Switch CI: retire the Tauri release workflows in favour of `native-macos.yml` plus a release job that runs `package.sh`.
4. Set up a Developer ID identity and notary profile (`NOTARY_PROFILE`), enable hardened runtime, notarize and staple.
