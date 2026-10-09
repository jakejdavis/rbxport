<p align="center">
  <a href="https://rbxport.com">
    <img src="docs/assets/brand/combined/rbxport-logo-color-white.png" alt="rbxport" width="360">
  </a>
</p>

# rbxport

> This is a native macOS rebuild of [chrisle/rbxport](https://github.com/chrisle/rbxport).
> It is a separate project and is not maintained by the original authors.

rbxport is a music library management app inspired by rekordbox. It keeps its
feature set deliberately small, aiming for a faster, simpler user experience.

Its scope is limited to library management, USB exporting, and PRO DJ LINK. It
is a native Mac app, written in SwiftUI and AppKit over a Rust core, and it needs
macOS 15 or later on Apple silicon.

## Project vision

The core vision of rbxport is **fewer features**.

Because rbxport is open source, you are free to fork it and build a version of
rekordbox customized by the community. The core project does not aim to be that.
A project that keeps adding features eventually becomes what rekordbox already is: full-featured
DJ software. rbxport stays small on purpose. Any contribution that adds a feature
is weighed carefully against this vision, and a good feature can still be
declined.

Two commitments define what "small" must not cost:

- **Compatibility.** rbxport aims to be fully compatible with the current
  version of rekordbox and all the hardware that rekordbox supports.
- **Performance.** rbxport stays fast by being native: track tables are lazy
  and paged, waveforms are drawn by the system, and high-rate state such as deck
  position is pulled once per display frame instead of pushed.

If you want to propose a feature, read
[Feature proposals](CONTRIBUTING.md#feature-proposals) in the contributing guide
first.

## Tech stack

| Layer | Technology |
| --- | --- |
| Desktop app | SwiftUI and AppKit, with an `NSTableView` for track browsing. |
| Bridge | UniFFI, over the Tauri-free `rbl-app` core. |
| Backend | Rust, with independent `rbl-*` crates for library, audio, export, and LINK logic. |
| Database | SQLCipher for rekordbox libraries and OneLibrary USB exports. |
| Build tooling | Xcode, XcodeGen, and Cargo. |
| Testing | Swift Testing against a mock backend, and Rust tests with temporary library fixtures. |

See [macOS app](macos/README.md) for how the bridge and the Swift layers fit
together, and [Architecture](docs/development/architecture.md) for the Rust
crates.

## Start here

You need macOS 15 or later, Xcode with Swift 6, Rust via rustup, and XcodeGen
(`brew install xcodegen`). The app opens your installed rekordbox library, so back it up first. To use a
throwaway library instead, set `RBXPORT_FIXTURE_DIR=<dir>`.

```sh
macos/scripts/build-rust.sh debug     # first run builds SQLCipher/OpenSSL: slow
cd macos && xcodegen generate
xcodebuild -scheme rbxport -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/rbxport.app
```

For signing, packaging, and the DMG, read [macOS app](macos/README.md).

## Developer reading path

Read these in order to understand the project and make your first change:

1. [macOS app](macos/README.md): prerequisites, build, the bridge, and the Swift architecture.
2. [Architecture](docs/development/architecture.md): crate responsibilities and edit flow.
3. [Development conventions](docs/development/conventions.md): code style, performance, translation, and evidence rules.
4. [Testing](docs/development/testing.md): checks, test setup, and what each result proves.
5. [Contributing](CONTRIBUTING.md): issues, branches, implementation, validation, and review.
6. [Debugging](docs/development/debugging.md): logs, diagnostics, environment variables, and cleanup.
7. [Releases](docs/development/releases.md): versions, CI, packaging, and publication.

The [documentation index](docs/README.md) also links to user guides and detailed
analysis, USB-format, and hardware references.

## Common commands

| Command | Purpose |
| --- | --- |
| `macos/scripts/build-rust.sh debug` | Build the Rust bridge, Swift bindings, and XCFramework. |
| `xcodegen generate` | Regenerate the Xcode project (run in `macos/`). |
| `xcodebuild -scheme rbxport -configuration Debug -derivedDataPath build test` | Swift tests against the mock backend and a fixture library. |
| `cargo test -p rbl-app -p rbl-ffi` | Rust tests for the app core and the bridge. |
| `RB_LITE_TEST=1 cargo test --workspace` | Rust tests with installed-library writes refused. |
| `macos/scripts/package.sh` | Release build and DMG. |

## License and trademarks

rbxport is GPL-2.0-or-later. See [LICENSE](LICENSE) and
[Licensing](LICENSING.md) for bundled components and distribution terms.
Third-party product names belong to their respective owners. rbxport is an
independent project and is not affiliated with, endorsed by, or sponsored by
their owners.

## Disclaimer

rbxport is provided "as is", without warranty to the extent permitted by
applicable law. Use it at your own risk and keep backups of your music library
and USB drives. Unless required by
applicable law or agreed to in writing, the authors and contributors are not
liable for damages arising from using or being unable to use rbxport,
including lost or corrupted data, equipment damage, or financial losses.
See [LICENSE](LICENSE) for the full warranty and liability terms.

rbxport is an independent project and is not affiliated with, endorsed by,
or sponsored by AlphaTheta or Pioneer DJ. References to rekordbox,
PRO DJ LINK, and other products describe compatibility only. All trademarks
and product names belong to their respective owners.

## Special thanks

evanpurkhiser, Maddix, Morgan Page, nichi, profbx, Sean Tyas, shiz, syl, trancejesus, xorbxbx, and
AlphaTheta.
