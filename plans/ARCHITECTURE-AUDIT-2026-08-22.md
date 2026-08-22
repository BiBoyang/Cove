# Cove Architecture Audit — 2026-08-22

## Current module map

```text
CoveApp (current Xcode application target)
├── Application/
│   └── Coordination/
│       ├── MainWindowController.swift   # composition root/window shell
│       └── LibraryCoordinator.swift     # server/share/browser workflow
├── Features/
│   ├── Browser/
│   │   ├── Views/BrowserViewController.swift
│   │   └── ViewModels/BrowserViewModel.swift
│   ├── Preferences/
│   │   ├── Views/PreferencesWindowController.swift
│   │   └── ViewModels/PreferencesViewModel.swift
│   ├── Reader/
│   │   ├── Coordination/ReaderCoordinator.swift
│   │   ├── ViewModels/ReaderViewModel.swift
│   │   └── Views/PagedReaderWindowController.swift
│   └── Servers/
│       ├── Views/{ServerList,ShareGrid,AddServer}ViewController.swift
│       └── ViewModels/{ServerList,ShareGrid}ViewModel.swift
├── Services/
│   ├── Infrastructure/{SMBSessionService,ServerConfig}.swift
│   ├── Media/{CacheService,ThumbnailService,ReaderContent,ReaderImageLoader}.swift
│   ├── Preheat/PreheatService.swift
│   └── Settings/SettingsService.swift
└── SharedUI/RoundedFillView.swift

ReaderKit (independent Swift package)
├── ReaderPage
├── ReaderDocument
├── ReaderPageSource
└── ReaderLoadError
```

## Dependency rules verified

- ReaderKit imports Foundation only; no AppKit, SnapKit, CacheKit, ImagePipeline,
  SourceKit, ComicKit, SMB, or ZIP implementation.
- Feature Views import AppKit/SnapKit and do not directly import the Reader
  loading pipeline, SMB session, or cache policy.
- Feature ViewModels own presentation state and task lifetime; they do not
  import SnapKit.
- Reader and Library Coordinators own cross-feature assembly and window/task
  lifetimes.
- Services remain App-target adapters over Frameworks; Frameworks do not depend
  on AppKit or SharedUI.
- `Interface/` is empty; feature ownership is represented by physical paths.
- No raw NSLayoutAnchor / `NSLayoutConstraint.activate` usage was found; UI
  layout remains SnapKit-based.

## Candidate future targets

Ready or nearly ready:

- `ReaderKit`: already independent and tested.
- `CoveSharedUI`: possible extraction after the shared component set grows.

Not yet worth extracting:

- Browser UI: still relies on App-target `ThumbnailProviding` and ContentItem.
- Servers UI: still relies on App-target `ServerConfig` and SourceKit share types.
- Preferences UI: uses the `PreferencesCacheManaging` contract from the
  Services/Media boundary; the concrete CacheKit adapter remains in Services.
- `CoveServices`: would be too broad while SMB, cache, thumbnail, preheat, and
  settings policies are still changing together.

## Test coverage added

`CoveTests` now covers:

- Browser metadata filtering, directory-first sorting, image projection, and
  path lookup;
- Server table-row/header boundaries;
- Share loading/empty/content presentation states;
- Preferences numeric validation and folder deduplication;
- Reader start-index clamping, navigation boundaries, and stale page result
  rejection.

## Deferred architecture work

- Add a dedicated `ErrorPresenter` if alert ownership grows beyond the main
  window shell.
- Decide whether `ContentItem`, `SMBShareInfo`, and `ServerConfig` should move
  into a shared domain package before extracting Browser/Servers UI targets.
- Revisit `ReaderPageSource` result type if a future non-macOS consumer makes
  `Data`/`CGImage` too specific.
- Reconsider the target split only after A2 adjacent-page preloading and the
  continuous Reader design settle; do not split unstable policies prematurely.

The Preferences cache contract is intentionally outside the Feature ViewModel
file. This keeps the dependency direction valid when Preferences UI and app
services become separate targets.
