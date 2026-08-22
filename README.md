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
- Files are classified by type (video / image / pdf / comic / text / other)
  and shown with type icons. Image files get real thumbnails (square
  center-crop at 160 px) loaded through the same two-pool disk cache as the
  reader: symbols show first, thumbnails fade in, off-screen rows never load,
  and duplicate requests coalesce.
- Double-click an image file to open a full-screen single-page reader:
  exactly one image is shown at a time on a black background, centered and
  fit proportionally. Previous/next buttons, `←`/`→` (plus PageUp/PageDown),
  `Esc`, and a page counter support manual navigation. Originals and
  downsampled display variants use the disk cache; A1 does not prefetch
  adjacent pages or start automatic directory warming.
- Double-click a `.cbz` comic archive to read it in the same single-page
  reader: the archive is cached whole in the original pool, its image entries
  are sorted naturally (`1, 2, …, 10`), and pages decode into the display
  pool one at a time. (`.cbr`/`.cbt` are not supported yet.)
- Optional preheating is limited to user-configured folders. Those folders
  are enumerated breadth-first (image files only, capped at 5000 files) and
  warmed over a dedicated SMB connection, so bulk reads never stall
  browsing; the pipeline can be rate-limited. Current-directory and
  reader-page preheating remain deferred until the adjacent-page design.
- Settings (app menu → 设置…, Cmd+,): cache budget (GB) and TTL (days) with
  live per-pool usage and a clear-now button; preheat on/off, rate limit
  (MB/s, 0 = unlimited), and the preheat folder list. Folder entries include
  the share name (e.g. `公共空间/动漫/xxx`) and only take effect while that
  share is connected.
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
make test       # Framework package tests + Cove Swift Testing + smb-spike compile check
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
  - `Features/` — feature-scoped AppKit views and `@MainActor` view models.
    The Reader feature now keeps its paging/loading state in a view model;
    its window controller only renders state and forwards user input, while
    `ReaderCoordinator` owns directory/CBZ content creation, loader/view-model
    assembly, pending archive-open cancellation, and Reader-window lifetime.
  - `Services/` — app adapters grouped by responsibility:
    `Infrastructure/` (SMB sessions and persisted servers), `Media/`
    (cache policy, thumbnails, and Reader content/loading adapters),
    `Preheat/` (background warming lifecycle), and `Settings/`
    (UserDefaults-backed configuration).
  - `SharedUI/` — reusable AppKit components shared by multiple features.
  - `Tests/CoveTests/` — app-target Swift Testing coverage for ViewModels and
    concurrency-sensitive presentation behavior.
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
  - `ImagePipeline` — image decoding with on-demand downsampling (thin
    ImageIO wrapper, zero dependencies).
  - `CacheKit` — two-pool on-disk cache (original / display) with LRU
    eviction, TTL expiry and a runtime-adjustable capacity/TTL policy
    (depends only on the local TraceKit).
  - `PreheatKit` — preheat scheduler: a three-priority FIFO queue with
    dedup against the cache, token-bucket rate limiting, and breadth-first
    preheat-folder enumeration (depends on SourceKit, CacheKit,
    ImagePipeline and TraceKit).
  - `ComicKit` — CBZ comic archives: in-memory ZIP parsing, image-entry
    filtering + natural page ordering, and thread-safe entry extraction
    (depends on SourceKit). The only place that imports
    [ZIPFoundation](https://github.com/weichsel/ZIPFoundation).
  - `ReaderKit` — Reader domain core: ordered page/document models and the
    original-page source protocol. It has no AppKit, SnapKit, SMB, ZIP, or
    cache implementation dependencies; concrete directory/CBZ/cache adapters
    stay in the app's Services layer.

See `AGENTS.md` for the layering rules.

## License

MIT. See `LICENSE`.
