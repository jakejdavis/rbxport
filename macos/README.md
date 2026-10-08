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

`crates/rbl-ffi` exposes `LibraryHandle` through UniFFI proc-macros (no UDL).
`build-rust.sh` builds the static library, runs the `uniffi-bindgen` binary
(`--features cli`) in library mode to write Swift bindings, and packages the
library plus header and modulemap as `Generated/rbl_ffi.xcframework`. The
bindings (`Generated/swift/rbl_ffi.swift`) compile into the app; `Generated/`,
`build/` and `*.xcodeproj` are gitignored.

Calls are synchronous and blocking, so Swift runs them in `Task.detached`.
The table (`NSTableView`) asks for cells, which loads pages of 128 rows via
`fetch_rows`, cached by view id + page. Sorting and search re-open the view.
