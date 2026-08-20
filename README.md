# Cove

A native macOS NAS media player. Long-term goal: video playback, image/comic/PDF
reading, warm-up caching and a local vault, all directly off your NAS — in the
spirit of SenPlayer, but for the Mac.

**v0 scope**: built-in SMB client (direct NAS connection) + file browsing.
Everything else comes later.

## Features (v0)

- Add SMB servers with just an address, username and password — no share name
  needed. Connecting lists the server's shares automatically as a card grid
  (hidden/admin shares like `IPC$` are filtered out).
- Passwords are stored in the Keychain; only address, username and display
  name are persisted in `UserDefaults`. Right-click a server to delete it
  (drops both the config and the Keychain password, after confirmation).
- Double-click a share card to browse it: directories, navigation into
  folders and back up (the back button returns to the share grid from the
  share root). The window title shows the current path while browsing.
- `.DS_Store` and AppleDouble (`._*`) files are hidden.
- Files are classified by type (video / image / pdf / text / other) and shown
  with type icons.
- Double-click an image file to open it in a viewer window (read-pipeline
  probe, no optimization).
- Connection failures surface as an alert with the concrete error.

Logging: interpolated log content defaults to os_log `.auto` privacy
(redacted in persisted logs); hosts, share names and paths are logged with
explicit `.private`. Passwords are never logged.

## Requirements

- macOS 15.0+ (deployment target)
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```sh
make generate   # generate Cove.xcodeproj from project.yml via XcodeGen
make build      # Debug build via xcodebuild
make test       # unit tests for the Frameworks/* Swift packages (+ smb-spike compile check)
make clean
```

`project.yml` is the source of truth for the Xcode project. `*.xcodeproj` is
git-ignored — regenerate it with `make generate` after cloning.

Signing is configured as `Automatic` with an empty `DEVELOPMENT_TEAM`
("Sign to Run Locally") for development. Set your own team ID in
`project.yml` before distribution.

## smb-spike

`Frameworks/SourceKit` ships a small command-line connectivity probe that
exercises the SMB stack outside the app:

```sh
swift build --package-path Frameworks/SourceKit --product smb-spike

# directory listing + first-64KB read probe
swift run --package-path Frameworks/SourceKit smb-spike <host> <share> <user> <password> <path>

# share enumeration (share argument ignored; `-` is a placeholder)
swift run --package-path Frameworks/SourceKit smb-spike <host> - <user> <password> --shares

# streaming read probe (1 MB chunks, optional cap in MB, default 256)
swift run --package-path Frameworks/SourceKit smb-spike <host> <share> <user> <password> --read <file> [capMB]

# example
swift run --package-path Frameworks/SourceKit smb-spike 192.168.1.10 media alice secret /movies
```

Directory mode connects, lists the given directory (name + size per entry),
then reads the first 64 KB of the first file and prints elapsed time and
throughput. `--shares` enumerates the server's browsable shares (name +
comment). `--read` streams the given file and reports per-chunk latency plus
overall throughput.

## Bundle ID placeholder

The bundle identifier is currently `com.biboyang.cove`, which is a
**placeholder**. Before publishing to the App Store, replace it with your own
identifier in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`).

## Architecture

- `Cove/` — the app target. Pure AppKit (no SwiftUI), no storyboards; layout
  constraints are written with [SnapKit](https://github.com/SnapKit/SnapKit)
  (Interface layer only).
  - `Application/` — `main.swift` + `AppDelegate`, manual wiring.
  - `Services/` — server persistence + SMB session lifecycle.
  - `Interface/` — window & view controllers (never touches AMSMB2 directly).
  - `Resources/` — `Info.plist`, sandbox entitlements.
- `Frameworks/` — local Swift packages:
  - `TraceKit` — thin `os_log` wrapper, zero dependencies.
  - `KeychainKit` — thin `SecItem` wrapper, zero dependencies.
  - `SourceKit` — `ContentSource` protocol (list / metadata / ranged reads,
    with a default whole-file read) + `SMBSource` (share-level sessions, an
    actor) + `SMBServer` (server-level share enumeration) + the
    `smb-spike` executable. The only place that imports
    [AMSMB2](https://github.com/amosavian/AMSMB2).

See `AGENTS.md` for the layering rules.

## License

MIT. See `LICENSE`.
