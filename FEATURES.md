# Fenestra — feature inventory

Derived from the build prompts. Each line is a concrete, checkable behaviour. Phases are the build order.

Status legend: `[ ]` unbuilt, `[x]` built and tested.

## 1. Filesystem core (Phase 1)
- [ ] `FileItem` Sendable struct: volume/file ID, url, name, displayName, isDirectory, isPackage, isSymlink, isAlias, isHidden, size, allocatedSize, created/modified/accessed/added, UTType, permissions, flags, tags.
- [ ] Bulk directory enumeration via `getattrlistbulk(2)`, batched `AsyncStream<[FileItem]>` (~500), first batch < 100 ms for 100k files on APFS.
- [ ] Fallback to `FileManager.enumerator` with prefetched resource keys when bulk fails (network FS).
- [ ] Cancellation of in-flight enumeration; "show hidden" respect; hidden filtering.
- [ ] FSEvents watcher: file-events flag, cf-types, no-defer, 0.1 s latency; coalesced diffs by file ID (insert/remove/modify/rename).
- [ ] Volume mount/unmount detection via `NSWorkspace` notifications.
- [ ] `DirectoryModel` (`@MainActor @Observable`): incremental sort/grouping, diff application preserving selection and scroll, stable snapshot for the table.
- [ ] `VolumeService`: name, icon, capacity, `volumeAvailableCapacityForImportantUsage`, fs name, removable/ejectable/network/internal.
- [ ] Tests: 50k-file enumeration correctness + order; watcher create/delete/rename within 1 s; sort stability; hidden filtering.

## 2. Shell: windows, tabs, chrome (Phase 2)
- [ ] AppKit `NSWindow` with traffic lights, transparent title bar, full-size content.
- [ ] Tab strip in the title bar: icon, title, close on hover, `+`, overflow scroll, middle-click close.
- [ ] Tab context menu: New, Duplicate, Close, Close others, Close to the right, Move to new window, Reopen closed tab.
- [ ] Drag to reorder tabs; tear off into a new window; drop onto another window's strip.
- [ ] Navigation bar row: Back, Forward, Up, Refresh, breadcrumb (placeholder), search field.
- [ ] Command bar row (placeholder in Phase 2).
- [ ] `NSSplitView` body: nav pane | content | details/preview pane, collapsible, remembered widths.
- [ ] Status bar: "N items | M selected  X MB" + view toggles on the right.
- [ ] Liquid glass on tab strip, nav bar, command bar, status bar as one grouped container; system sidebar glass; opaque content area.
- [ ] Reduce Transparency and Increase Contrast fall back to solid fills.
- [ ] Per-tab state: navigation history, view settings, selection. Restore tabs and windows on launch (setting).
- [ ] Shortcuts: ⌘T, ⌘W, ⌘⇧T, ⌃Tab, ⌃⇧Tab, ⌘1…9, ⌘N.
- [ ] Acceptance: 20 tabs, switch < 16 ms; tear-off/merge; restore after relaunch.

## 3. Details view (Phase 3)
- [ ] `NSTableView`, view-based, cell reuse, 32 px rows (24 px compact).
- [ ] Columns: Name, Date modified, Type, Size; optional columns (Created, Added, Tags, Kind, Dimensions, Duration, Version, Comments, Git status).
- [ ] Header right-click column chooser with "More…" sheet listing all metadata columns with search.
- [ ] Reorder/resize columns; "Size all columns to fit".
- [ ] Sort by header click, asc/desc indicator, secondary sort by name.
- [ ] Groups: None / Type / Date modified (Today, Yesterday, Earlier this week, Last week, Earlier this month, Last month, Earlier this year, A long time ago) / Size (Empty, Tiny, Small, Medium, Large, Huge, Gigantic); collapsible headers.
- [ ] Selection: click, Shift, ⌘, rubber band, type-to-select, select all/none/invert, checkbox column.
- [ ] Inline rename: F2, name-without-extension pre-selected, Tab next item, Esc cancel, illegal chars/duplicates rejected.
- [ ] Double-click/Enter: folder navigates in the same tab, file opens via `NSWorkspace`. ⌘+double-click or middle-click on a folder opens a new tab.
- [ ] Icons via `NSWorkspace.icon(forFile:)` cached by UTType; thumbnails deferred to Phase 6.
- [ ] Per-folder view memory (sort, columns, grouping) keyed by folder file ID, JSON/SQLite store; folder-type templates (General, Documents, Pictures, Music, Videos) with "Apply to all folders".
- [ ] Empty state "This folder is empty."; error state for unreadable folders.
- [ ] Status bar counts + total size computed off-main.
- [ ] Acceptance: 100k items scroll at 120 fps, 0 hitches; sort switch < 150 ms; live FS changes without losing selection or scroll.

## 4. Other views (Phase 4)
- [ ] Extra large (256), Large (96), Medium (48), Small (16) icons, List, Tiles, Content — `NSCollectionView` with compositional layout and prefetching.
- [ ] ⌘+wheel and ⌘+/− cycle icon sizes.
- [ ] Shared `FileListController` for selection, rename, drag/drop, keyboard, grouping.
- [ ] View switch preserves selection and scroll anchor.
- [ ] Shortcuts: ⌃⇧1…8 (Windows mapping), ⌘1…4 (Mac mapping); tab jump moves to ⌃1…9 in Mac mapping (documented).
- [ ] Acceptance: 8 views at 120 fps on 20k images (thumbnails off); view switch < 50 ms.

## 5. Navigation bar (Phase 5)
- [ ] Breadcrumb segments with chevrons; chevron menu lists child folders (async, scrollable); overflow collapses to `«` menu.
- [ ] Edit mode: ⌘L / Ctrl+L / F4 / Alt+D, full-path text field, autocomplete child folders, Tab completes, Enter navigates, Esc restores breadcrumbs.
- [ ] Accepts `~`, `/`, relative paths, `smb://`, `afp://` (mount via NetFS) and aliases Home, Desktop, Downloads, Documents, Trash, Applications, iCloud.
- [ ] Invalid path → inline error shake, no modal.
- [ ] Drag files onto a segment to move/copy with spring-loading.
- [ ] Segment context menu: Copy address, Copy as text, Open in new tab/window, Edit address.
- [ ] Back/Forward long-press or right-click history dropdown (last 15); Alt+←/→, ⌘[ / ⌘], mouse buttons 4/5, two-finger swipe; Up Alt+↑ / ⌘↑; Refresh F5 / ⌘R.
- [ ] Window/tab title shows folder name (option: full path).
- [ ] Tests: path parsing/alias resolution; UI test for breadcrumb, edit mode, history.

## 6. Thumbnails (Phase 6)
- [ ] `ThumbnailService` actor over `QLThumbnailGenerator`: low-res icon first, then thumbnail; concurrency limit (default 6); visible-first priority; prefetch next screenful; cancel on cell reuse.
- [ ] Two-tier cache: `NSCache` (≈150 MB, cost = pixel bytes) + disk LRU (1 GB) keyed by file ID, mtime, size, pixel size.
- [ ] Off-main decode and downsample to exact pixel size.
- [ ] Folder thumbnails with up to 2 preview images (setting).
- [ ] "Always show icons, never thumbnails" setting.
- [ ] Video frames via QL; audio artwork.
- [ ] Acceptance: 20k photos in Large icons at 120 fps; disk-cache hits instant; no work after leaving the folder (signposts).

## 7. Navigation pane (Phase 7)
- [ ] `NSOutlineView` source list: Home, Gallery, iCloud Drive + File Provider domains, Quick access (pins), This Mac (Desktop, Documents, Downloads, Music, Pictures, Movies, volumes with capacity bars), Network, Tags.
- [ ] Lazy children; "Expand to open folder"; "Show all folders".
- [ ] Quick access pin/unpin/reorder, persisted.
- [ ] Volume eject, live add/remove, low-space colour >90%.
- [ ] Network: Bonjour SMB discovery, Connect to server, saved favourites, reconnect at login, `NetFSMountURLAsync`.
- [ ] Drop targets everywhere with spring-loading.
- [ ] Item context menu: Open in new tab/window, Pin/Unpin, Properties, Eject, Show in enclosing folder.
- [ ] Keyboard: arrows navigate the tree, Enter opens.
- [ ] Acceptance: unreachable network share never blocks the main thread.

## 8. Command bar & registry (Phase 8)
- [ ] `Command` registry: id, title, symbol, Windows + Mac shortcuts, isEnabled, isVisible, perform.
- [ ] `CommandContext`: current tab, folder, selection, pasteboard state.
- [ ] Command bar: New ▾ (Folder, Text document, Rich text, user templates, Alias, Symlink), Cut, Copy, Paste, Rename, Share, Delete, Sort ▾, View ▾ (all views, Compact, Show ▸ panes/check boxes/extensions/hidden), Filter, "…" overflow (Undo, Redo, Select all/none/invert, Properties, Options).
- [ ] Contextual commands: Extract all, Rotate left/right, Set as desktop picture, Play, Eject, Restore/Restore all/Empty Trash.
- [ ] Customize command bar sheet.
- [ ] Same registry drives menu bar, shortcuts, and command palette (⌘⇧P fuzzy search).
- [ ] Cut marks items ghosted; paste moves. Private pasteboard type for cut intent; cross-app paste still copies.
- [ ] Tests for enabling rules.

## 9. File operations engine (Phase 9)
- [ ] `FileOperationQueue` actor: copy, move, trash, delete-permanently, new folder, rename, duplicate, compress, extract, alias, symlink.
- [ ] Concurrent across volumes, serial per destination volume by default.
- [ ] Copy via `copyfile(3)` with `COPYFILE_ALL | COPYFILE_CLONE`; byte/item progress; pause and resume.
- [ ] Same-volume move = `rename(2)`; cross-volume = copy + verify + delete.
- [ ] Pre-flight: counts, bytes, free space, permissions; fail fast.
- [ ] Conflict dialog: Replace, Skip, Compare info side-by-side with checkboxes, Keep both auto-rename, "Do this for all N".
- [ ] Errors: Retry / Skip / Cancel with "do this for all"; admin option gated behind a setting.
- [ ] Progress window: card per job, speed graph, current file, items remaining, ETA, Pause/Resume/Cancel, more/fewer details, collapse to status bar.
- [ ] Trash + Restore with our own original-location DB.
- [ ] Undo stack per window: rename, move, copy, new folder, trash.
- [ ] Drag & drop: same volume move, cross volume copy; Option copy, ⌘ move, Option+⌘ alias (Windows mapping: Ctrl copy, Shift move, Alt shortcut); cursor badge.
- [ ] Unicode normalization, long paths, `:` and `/` in names.
- [ ] Tests: 10k small files + 5 GB sparse file, cancel leaves no partial final-named file, conflict auto-rename, undo/redo chains, cross-volume move via disk image.

## 10. Context menu (Phase 10)
- [ ] Quick-action icon row: Cut, Copy, Rename, Share, Delete.
- [ ] Open, Open with ▸ (default first, "Choose another app…" with "Always use this app"), Open in new tab/window, Open in Terminal, Pin to Quick access, Add to Favorites, Compress to ▸ (ZIP, 7z, TAR, tar.gz, tar.xz), Extract all, Copy as path, Properties.
- [ ] "Show more options" (⇧F10 or Shift+right-click): Send to ▸, Create alias, Make symlink, Duplicate, Tags ▸, Get hash ▸, Services, Share extensions, Quick Look, Reveal in Finder, Get Info in Finder.
- [ ] Background menu: View ▸, Sort by ▸, Group by ▸, Refresh, Paste, Paste alias, Undo, New ▸, Open in Terminal, Properties.
- [ ] Customization: show/hide entries, custom shell actions with `$PATHS`/`$DIR`, per-type filters.
- [ ] Acceptance: menu opens < 50 ms with large selections; Open-with list resolved async.

## 11. Details / preview pane (Phase 11)
- [ ] Details pane: large thumbnail, name, kind, size, dates, clickable location, type-specific metadata, editable tags and comments, rating, sharing status, multi-selection summary, git info (branch/ahead-behind/last commit/status) via `git` CLI with timeout and cache.
- [ ] Preview pane: `QLPreviewView` with 120 ms debounce and cancellation; PDF, images, text/code, audio/video, Office; "No preview available".
- [ ] Space opens the QuickLook panel with arrow-key navigation.
- [ ] Pane widths persist per window.
- [ ] Acceptance: rapid arrow through 1000 images never stalls.

## 12. Home & Gallery (Phase 12)
- [ ] Home: Quick access grid, Favorites, Recent (NSMetadataQuery on `kMDItemLastUsedDate` + own log; Name, Date accessed, Activity, Location; Remove, Clear history), Shared, Recommended (frecency).
- [ ] Gallery: photo/video timeline from configured folders (not the Photos library DB), justified-row layout, month/year headers, timeline scrubber, Collection ▾.
- [ ] Acceptance: Home < 200 ms cached; Gallery smooth at 50k photos.

## 13. Search (Phase 13)
- [ ] Search box (⌘F / Ctrl+E / F3); searches current folder + subfolders, replaces content with results view (extra Folder column), breadcrumb "Search results in X".
- [ ] Engine 1: `NSMetadataQuery`/`MDQuery` with live updates and streaming batches.
- [ ] Engine 2: parallel cancellable recursive crawler for non-indexed volumes; name matching unless "Search file contents" enabled (text only, size cap).
- [ ] Query syntax: free text, quotes, `name:`, `ext:`, `kind:`, `size:` comparisons and buckets, `modified:`/`created:` buckets and ranges, `tag:`, AND/OR/NOT, `-exclude`.
- [ ] Search options ▾: scope, kind, date, size, content toggle, Save search (smart folder), Recent searches.
- [ ] Highlight matched substrings.
- [ ] Acceptance: indexed 1M files first result < 150 ms; 200k non-indexed drive streams within 1 s; cancel immediate.

## 14. Properties (Phase 14)
- [ ] General: icon (drag to set custom icon), editable name, type, Opens with + Change, location, size, size on disk (live counting for folders), contains counts, dates, Locked/Hidden, multi-selection aggregate.
- [ ] Security: owner, group, POSIX rwx grid, ACL list, apply to enclosed items, auth when needed.
- [ ] Details: all metadata (MDItem, EXIF/IPTC/GPS, ID3/AV, PDF) with editable fields; "Remove properties and personal information".
- [ ] Previous versions: APFS snapshots / Time Machine, Open, Copy, Restore.
- [ ] Hashes: MD5, SHA-1, SHA-256, SHA-512 streamed, copy, compare.
- [ ] Volume variant: capacity pie chart, file system, eject, Open Disk Utility.
- [ ] Acceptance: 500k-file folder shows properties immediately, counts in the background, cancellable.

## 15. Archives (Phase 15)
- [ ] libarchive integration (BSD licence documented).
- [ ] Browse ZIP/7z/TAR/TGZ/TXZ/TBZ2/ZST/RAR (read-only) as virtual folders, preview on demand, drag out.
- [ ] Extract all dialog with destination, reveal when complete, progress through FileOps, password prompt.
- [ ] Compress ZIP/7z/TAR/tar.gz/tar.xz with level option and `.DS_Store`/`__MACOSX` exclusion setting.
- [ ] Zip-slip, symlink escape, bomb guards with test fixtures.

## 16. Bulk rename, Settings, key mapping (Phase 16)
- [ ] PowerRename sheet: find/replace (plain or regex), case, name/extension/both, numbering `${n:3}`, date tokens, case transforms, live preview with conflicts, single-step undo.
- [ ] Settings: General / View / Search / Keyboard / Context menu / Advanced; Reset folders; Restore defaults.
- [ ] Key mapping: Windows and Mac presets + overrides, conflict detection, cheat-sheet overlay (⌘/).
- [ ] Full Windows preset listed in the prompt; warn on conflicts with macOS-reserved combos.

## 17. System integration (Phase 17)
- [ ] Services: Open in Fenestra, Open in Fenestra (new tab), Reveal in Fenestra.
- [ ] `fenestra://open?path=…&tab=new` and `fen` CLI helper.
- [ ] App Intents: Open folder, Search, New folder, Compress, Extract.
- [ ] Dock menu (recent folders, New window); optional menu bar extra.
- [ ] Open in Terminal/iTerm/Warp/VS Code/Cursor (setting).
- [ ] File Provider status column + Always keep on this device / Free up space.
- [ ] AutoPlay-style prompt on mount.
- [ ] Onboarding: welcome, Full Disk Access deep link, key mapping choice, handler note (no full Finder replacement).

## 18. Accessibility, localization, polish (Phase 18)
- [ ] VoiceOver announcements for rows, breadcrumbs, tabs, progress cards.
- [ ] Full keyboard access with visible focus rings.
- [ ] Text size setting (Small/Medium/Large) affecting row heights.
- [ ] Reduce Motion, Reduce Transparency, Increase Contrast.
- [ ] String Catalog complete, pseudo-localization, RTL check.
- [ ] Animations for tabs/panes/glass < 250 ms, none on the navigation critical path.

## 19. Performance hardening & release (Phase 19)
- [ ] Perf tests with signposts: launch, open 10k/100k folder, sort, view switch, thumbnail scroll, search first result, copy 10k files; CI regression gate >15% on deterministic tests.
- [ ] Instruments run: top 10 hotspots fixed with before/after numbers.
- [ ] MetricKit diagnostics, opt-in only.
- [ ] Sparkle 2 auto-update with EdDSA signed appcast.
- [ ] Release: archive, Developer ID sign, notarize, staple, DMG, appcast.
- [ ] `docs/ARCHITECTURE.md`: modules, threading model, data flow, budgets.
