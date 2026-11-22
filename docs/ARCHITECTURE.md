# Dora the Explorer — Architecture

Native macOS 26 file explorer (Windows 11 File Explorer structure where the platform
allows). AppKit lifecycle, Swift 6 language mode, strict concurrency everywhere.
Bundle ID `com.dorasoft.dora`, app **Dora the Explorer**, module/scheme **Dora**.

## Modules

```
Dora (app)                  windows, tab strip, chrome, content views, menu/clipboard wiring
├── AppCore                 window/tab state, navigation history, workspace persistence
├── FSCore                  FileItem, bulk enumeration, FSEvents watcher, DirectoryModel, volumes
├── FileOps                 FileOperationEngine (copy/move/trash/undo), TrashStore
├── DesignSystem            chrome background materials (NSVisualEffectView + accessibility fallbacks)
├── Thumbnails              QL pipeline (Phase 6)
├── Search                  query syntax + engines (Phase 13)
├── Archives                libarchive browsing (Phase 15)
└── ShellIntegration        services, URL scheme, CLI (Phase 17)
```

Layering rule: packages never import the app target; feature packages never import
each other except through `FSCore` models and `DesignSystem`.

## Threading model

| What | Where |
|---|---|
| All disk I/O (enumeration, stat, rename, copy, trash) | actor / `Task.detached`, never the main actor |
| Sorting, grouping, index building of any size | `DirectoryModel.prepare` in a detached task |
| Icon warm-up, volume-name warm-up, persistence writes | utility queues / detached tasks |
| UI state, selection, table refresh | `@MainActor` only, fed by `Sendable` snapshots |

`FSCore` calls `assertNotMainThreadForIO()` at every I/O entry point. The one legal
main-thread read is small config JSON at cold launch (folder views), flushed at quit.

**Publish flow**: `DirectoryEnumerator` streams batches → `DirectoryModel` sorts/groups
off-main and publishes an immutable `DirectorySnapshot` on the main actor →
`ContentViewContainer` (the *only* `onPublish` consumer) re-renders the table, the
overlay states (empty/loading/error), and the status-bar counts.

**Selection** is ID-addressed (`FileItem.ID`) and lives on `TabState`. The table never
derives selection from row indexes across publishes, so resorting or live FSEvents
updates cannot shift it; scroll restore happens only when the captured viewport
anchor was displaced by a publish.

**Tab lifecycle**: one `DirectoryModel` per tab, created lazily by the container.
Closing a tab calls `DirectoryModel.cancelLoads()` (stops enumeration + the FSEvents
watcher) and drops the box; window teardown cancels helper tasks and every model.
Group-collapse state, column widths and per-folder view memory are persisted per
folder in `folder-views.json`.

## File operations

`FileOperationEngine` (actor) executes copy/move/trash and returns
`OperationOutcome` with an undo record built from typed steps. Conflicts resolve
by policy; keep-both renames Windows-style ("name (2).ext"), replace parks the
overwritten original in the Trash — every path is undoable. `TrashStore` records
trash→original paths (macOS Put Back is Finder-private) so restore works.

Clipboard: Cut/Copy write standard file URLs (all apps understand them); Cut adds
a private pasteboard type that only Dora windows consult for move-on-paste, so
pasting in another app copies — Windows cross-app semantics.

## Performance budgets

Every budget gets an `OSSignposter` interval and a deterministic test where possible.

| Operation | Budget | Status |
|---|---|---|
| First batch of a 100k-file folder | < 100 ms | FSCore perf test (100k first-batch) |
| Details scroll, 100k items | 120 fps, 0 hitches | Instruments run pending |
| Sort switch, 100k items | < 150 ms | off-main prepare |
| Tab switch | < 16 ms | DEBUG `measureTabSwitch()` hook |
| View switch | < 50 ms | collection views pending (Phase 4) |
| Command/context menu open | < 50 ms | command bar synchronous from live state |
| Folder view store / workspace writes | off main | utility queues, synced only at quit |

## Third-party dependencies

None. Planned, justified exceptions only: Sparkle 2 (updates, Phase 19) and
libarchive (archives, Phase 15).

## Controller cheat-sheet

- `WindowRegistry` — owns `WindowController`s; workspace save/restore (`workspace.json`).
- `WindowController` — tab strip wiring, navigation routing, file-operation stacks
  (undo/redo per window), menu validation surface.
- `ExplorerChromeView` — four-row chrome layout, command-bar menus, breadcrumb wiring.
- `ContentViewContainer` — per-tab models, sole publish consumer, overlays, status counts.
- `DetailsViewController` — NSTableView view/row-space, selection/type-select/rename.

Build/test: `make test` (app + all packages), `make run`. XcodeGen regenerates
`Dora.xcodeproj` from `project.yml` — never edit the pbxproj by hand.
