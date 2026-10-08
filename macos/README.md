# rbxport native (macOS spike)

A SwiftUI/AppKit front end over the Rust library crates. It proves the
bridge and the track table; it is read-only and has no updater.

## Prerequisites

- macOS 15+, Xcode (Swift 6), Apple silicon (arm64 only for now)
- Rust via rustup (the toolchain in `rust-toolchain.toml` installs itself)
- XcodeGen: `brew install xcodegen`
- rekordbox installed (the app opens `~/Library/Pioneer/rekordbox` read-only)

## Build and run

```sh
macos/scripts/build-rust.sh debug     # first run builds SQLCipher/OpenSSL: slow
cd macos && xcodegen generate
xcodebuild -scheme rbxport -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/rbxport.app
```

`build-rust.sh` must run once before `xcodegen` (the project references its
output). The Xcode project also runs it as a pre-build script, which is a
no-op when the Rust library has not changed.

## How the bridge works

`crates/rbl-ffi` is a thin UniFFI layer (proc-macros, no UDL) over `crates/rbl-app`,
the Tauri-free app core. It holds an `Arc<AppState>`, calls `rbl_app::browse::*` and
`startup::load_library`, and converts DTOs to UniFFI records/enums in `convert.rs`.
It has no logic of its own; views live in rbl-app's registry.

- `Core.new(listener:cacheDir:)` opens the installed library; `Core.withFixture(listener:dir:)`
  builds/opens a fixture (tests, previews, `RBXPORT_FIXTURE_DIR=<dir>` for the app).
- `core.loadLibrary()` blocks (backup/journal recovery, snapshot cache, read-only open) and
  also emits `LibraryReady` / `LibraryProblem` to the `EventListener` callback.
- Typed API: `SortKey`, `NodeKind`, `TrackSource`, `ViewSpec`; errors are `FfiError`
  (ReadOnly/NotFound/Malformed/Cancelled/Internal, with message and detail).

`build-rust.sh` builds the static library, runs `uniffi-bindgen` to write Swift bindings, and
packages `Generated/rbl_ffi.xcframework`. `Generated/`, `build/` and `*.xcodeproj` are gitignored.

## Swift architecture

- `BackendProtocol` (async API + `events: AsyncStream<LibraryEvent>`), implemented by
  `actor Backend` (owns the UniFFI `Core`; `EventBridge` turns the callback into the stream)
  and `actor MockBackend` (in-memory, for previews and tests).
- `AppModel` (`@MainActor @Observable`) starts the event loop and the load, and reacts to
  `LibraryReady` (load tree/summary), `LibraryProblem` (failed phase) and `LibraryChanged`
  (reload tree and summary, keep the selected node, reopen the view).
- `RowPager` pages rows lazily (128 per page), caches by view id + page with eviction;
  `TrackTable` (`NSTableView`) renders from it.
- The snapshot cache lives in `~/Library/Caches/com.rbxport.native`.

## Tests

```sh
cargo test -p rbl-ffi -p rbl-app
xcodebuild -scheme rbxport -configuration Debug -derivedDataPath build test
```

`macos/Tests`: model, pager and event-reload tests against `MockBackend`, plus an integration
test of the real FFI over a temporary fixture library.
