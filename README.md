# Dora the Explorer

Native macOS 26 file explorer with Windows 11 File Explorer's structure: tabbed windows,
breadcrumb address bar, command bar, Details/Icons/List/Tiles/Content views, thumbnails,
search, archive browsing, FileOps with conflict handling, and a Windows keyboard preset.

AppKit lifecycle app, Swift 6 (strict concurrency), local SPM packages.

## Requirements

- macOS 26 (deployment target 26.0), Apple Silicon
- Xcode 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```sh
make generate      # regenerate Dora.xcodeproj from project.yml
make build         # Debug build into build/
make run           # build and open the app
make test          # app tests + every package's tests
make test-packages # package tests only (fast)
```

Or from Xcode: `xcodegen generate && open Dora.xcodeproj`.

## Layout

```
Dora/                AppKit app target (windows, tabs, chrome, content views)
DoraTests/           app-level tests
Packages/
  FSCore/            FileItem, bulk enumeration, FSEvents watcher, DirectoryModel, volumes
  FileOps/           copy/move/trash/undo engine (Phase 9)
  Thumbnails/        QLThumbnailGenerator pipeline + caches (Phase 6)
  Search/            MDQuery + fallback crawler + query syntax (Phase 13)
  Archives/          libarchive-backed archive browsing (Phase 15)
  ShellIntegration/  Services, URL scheme, CLI, Finder hand-off (Phase 17)
  DesignSystem/      spacing/metrics tokens, glass helpers
  AppCore/           window/tab state, command registry
docs/ARCHITECTURE.md modules, threading, data flow, perf budgets
FEATURES.md          feature inventory with build status
.cursor/rules/       project rules applied to every edit
```

## Identity

- App name: **Dora the Explorer** (`Dora the Explorer.app`)
- Bundle ID: `com.dorasoft.dora`, module/scheme: `Dora`
- URL scheme: `dora://`, CLI: `dora`

Local builds sign ad-hoc (`CODE_SIGN_IDENTITY = "-"`); set your Developer ID team in
`project.yml` for distribution.
