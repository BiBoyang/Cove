# Cove

A native macOS NAS media player. Long-term goal: video playback, image/comic/PDF
reading, warm-up caching and a local vault, all directly off your NAS — in the
spirit of SenPlayer, but for the Mac.

**v0 scope**: built-in SMB client (direct NAS connection) + file browsing.
Everything else comes later.

## Features (v0)

- Add SMB servers (address / share / username / password).
- Passwords are stored in the Keychain; only address, share and username are
  persisted in `UserDefaults`.
- Browse directories, navigate into folders and back up.
- Files are classified by type (video / image / pdf / text / other) and shown
  with type icons.
- Double-click an image file to open it in a viewer window (read-pipeline
  probe, no optimization).
- Connection failures surface as an alert with the concrete error.

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
swift run --package-path Frameworks/SourceKit smb-spike <host> <share> <user> <password> <path>

# example
swift run --package-path Frameworks/SourceKit smb-spike 192.168.1.10 media alice secret /movies
```

It connects, lists the given directory (name + size per entry), then reads the
first 64 KB of the first file and prints elapsed time and throughput.

## Bundle ID placeholder

The bundle identifier is currently `com.biboyang.cove`, which is a
**placeholder**. Before publishing to the App Store, replace it with your own
identifier in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`).

## Architecture

- `Cove/` — the app target. Pure AppKit (no SwiftUI), no storyboards.
  - `Application/` — `main.swift` + `AppDelegate`, manual wiring.
  - `Services/` — server persistence + SMB session lifecycle.
  - `Interface/` — window & view controllers (never touches AMSMB2 directly).
  - `Resources/` — `Info.plist`, sandbox entitlements.
- `Frameworks/` — local Swift packages:
  - `TraceKit` — thin `os_log` wrapper, zero dependencies.
  - `KeychainKit` — thin `SecItem` wrapper, zero dependencies.
  - `SourceKit` — `ContentSource` protocol + `SMBSource` (the only place that
    imports [AMSMB2](https://github.com/amosavian/AMSMB2)) + the `smb-spike`
    executable.

See `AGENTS.md` for the layering rules.

## License

MIT. See `LICENSE`.
