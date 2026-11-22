# Dora the Explorer — feature inventory

Derived from the build prompts. Each line is a concrete, checkable behaviour. Phases are the build order.

Status legend: `[ ]` unbuilt, `[x]` built and tested.

## 1. Filesystem core (Phase 1)
- [ ] `FileItem` Sendable struct: volume/file ID, url, name, displayName, isDirectory, isPackage, isSymlink, isAlias, isHidden, size, allocatedSize, created/modified/accessed/added, UTType, permissions, flags, tags.
- [x] Bulk directory enumeration via `getattrlistbulk(2)`, batched `AsyncStream<[FileItem]>` (~500), first batch < 100 ms for 100k files on APFS.
- [x] Fallback to `FileManager.enumerator` with prefetched resource keys when bulk fails (network FS).
- [x] Cancellation of in-flight enumeration; "show hidden" respect; hidden filtering.
- [x] FSEvents watcher: file-events flag, cf-types, no-defer, 0.1 s latency; coalesced diffs by file ID (insert/remove/modify/rename).
- [x] Volume mount/unmount detection via `NSWorkspace` notifications.
- [x] `DirectoryModel` (`@MainActor @Observable`): incremental sort/grouping, diff application preserving selection and scroll, stable snapshot for the table.
- [x] `VolumeService`: name, icon, capacity, `volumeAvailableCapacityForImportantUsage`, fs name, removable/ejectable/network/internal.
- [x] Tests: 50k-file enumeration correctness + order; watcher create/delete/rename within 1 s; sort stability; hidden filtering.

## 2. Shell: windows, tabs, chrome (Phase 2)
- [x] AppKit `NSWindow` with traffic lights, transparent title bar, full-size content.
- [x] Tab strip in the title bar: icon, title, close on hover, `+`, overflow scroll, middle-click close.
- [x] Tab context menu: New, Duplicate, Close, Close others, Close to the right, Move to new window, Reopen closed tab.
- [x] Tear off a tab into a new window (single-fire drag out, correct screen coordinates).
- [ ] Drag to reorder tabs; drop onto another window's strip.
- [x] Navigation bar row: Back, Forward, Up, Refresh, breadcrumb (placeholder), search field.
- [x] Command bar: New / Sort / View menus anchored under their buttons, wired to the live model.
- [x] `NSSplitView` body: nav pane | content | details pane, collapsible, remembered widths.
- [x] Status bar: item count, selection count, selected bytes, pane toggles.
- [x] Chrome surfaces use NSVisualEffectView materials (titlebar/toolbar strip, sidebar) — the only real AppKit glass; grouped Liquid Glass container still pending `.glassEffect` hosting.
- [x] Reduce Transparency and Increase Contrast fall back to solid fills.
- [x] Per-tab state: navigation history, view settings, selection. Restore tabs and windows on launch (setting).
- [x] Shortcuts: ⌘T, ⌘W, ⌘⇧T, ⌃Tab, ⌃⇧Tab, ⌘1…9, ⌘N.
- [ ] Acceptance: 20 tabs, switch < 16 ms; tear-off/merge; restore after relaunch.

## 3. Details view (Phase 3)
- [x] `NSTableView`, view-based, cell reuse, O(1) row space; 32 px rows (24 px compact pending setting).
- [x] Columns: Name, Date modified, Type, Size, plus Date created, Date added, Tags via chooser.
- [ ] Metadata columns needing lazy services: Kind, Dimensions, Duration, Version, Comments, Git status.
- [x] Header right-click column chooser (Name column pinned).
- [ ] “More…” sheet with search (ship with lazy-metadata columns).
- [x] Reorder/resize columns; "Size all columns to fit".
- [x] Sort by header click, asc/desc indicator, name always the tiebreaker.
- [x] Groups: None / Type / Date modified / Size with collapsible headers (ids stable across regroup).
- [x] Selection: click, Shift, ⌘, type-to-select (from any column), Select All — ID-addressed across live updates.
- [ ] Rubber band selection, Invert selection, item checkbox column.
- [x] Inline rename: F2, basename pre-selected (prefix-anchored), Tab rolls to next item, Esc cancels; empty/separator/dot/overlong/duplicate names rejected inline (no modal).
- [x] Double-click/Enter: folder navigates in the same tab, file opens via `NSWorkspace`; ⌘+double-click and middle-click open a new tab; Backspace navigates back, Delete trashes (W11), ⌘⌫ trashes (macOS).
- [x] Icons cached by UTType, common types warmed off-main at launch (thumbnails in Phase 6).
- [x] Per-folder view memory (sort, grouping, columns, widths, hidden) keyed by path; folder-file-ID keys pending the settings DB.
- [ ] Folder-type templates (General/Pictures/…) with “Apply to all folders”.
- [x] Empty state, loading spinner, error state with working Retry.
- [x] Status bar counts + selection size from published snapshots (no main-thread I/O).
- [ ] Acceptance: 100k items scroll at 120 fps, 0 hitches (Instruments run pending).

## 4. Other views (Phase 4)
- [ ] Extra large (256), Large (96), Medium (48), Small (16) icons, List, Tiles, Content — `NSCollectionView` with compositional layout and prefetching.
- [ ] ⌘+wheel and ⌘+/− cycle icon sizes.
- [ ] Shared `FileListController` for selection, rename, drag/drop, keyboard, grouping.
- [ ] View switch preserves selection and scroll anchor.
- [ ] Shortcuts: ⌃⇧1…8 (Windows mapping), ⌘1…4 (Mac mapping); tab jump moves to ⌃1…9 in Mac mapping (documented).
- [ ] Acceptance: 8 views at 120 fps on 20k images (thumbnails off); view switch < 50 ms.

## 5. Navigation bar (Phase 5)
- [x] Breadcrumb segments with chevrons; chevron menus list child folders (FSCore enumerator off-main, capped at 400) and overflow collapses behind «.
- [x] Edit mode: ⌘L or click empty bar; full-path field, Enter navigates, Esc restores; search/autocomplete dropdown pending.
- [ ] Accepts `~`, relative paths, smb/afp mounts, and named aliases in edit mode (tilde expansion only).
- [x] Invalid path → inherent-folder error state (no modal); breadcrumb shake pending.
- [ ] Drag files onto a segment to move/copy with spring-loading.
- [x] Segment context menu: Copy Address, Copy as Text, Open in New Tab, Open in New Window, Edit Address.
- [x] Back / Forward / Up / Refresh wired: buttons, ⌘[ / ⌘], menu Shortcuts.
- [ ] History dropdown (last 15), Alt+arrows, mouse buttons 4/5, two-finger swipe.
- [x] Window/tab title shows folder name (full-path option pending).
- [ ] Tests: path parsing/alias resolution; UI test for breadcrumbs (Phase 16/18 pass).

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
- [x] `FileOperationEngine` actor: copy, move, trash, apply-undo (delete-permanently, compress, extract, alias/symlink pending).
- [x] Serialized inside the engine actor; per-destination-volume queues with the progress-window pass.
- [ ] Copy via `copyfile(3)` with byte/item progress, clone-fast paths, pause/resume (currently atomic per-item `FileManager.copyItem`).
- [x] Same-volume move is an atomic rename (`FileManager.moveItem`); cross-volume copy+delete handled by moveItem.
- [ ] Pre-flight: counts, bytes, free space, permissions; fail fast.
- [x] Conflicts auto-resolve keep-both (“name (2).ext”); replace parks the overwritten original in the Trash so undo restores it.
- [ ] Conflict dialog: Replace / Skip / Compare side-by-side / do-for-all.
- [ ] Errors: Retry / Skip / Cancel with "do this for all"; admin option gated behind a setting.
- [ ] Progress window: card per job, speed graph, current file, items remaining, ETA, Pause/Resume/Cancel, more/fewer details, collapse to status bar.
- [x] Trash + Restore with our own original-location DB (TrashStore actor, atomic JSON).
- [x] Undo/redo per window for copy, move, trash, replace (⌘Z / ⇧⌘Z, menu validation).
- [ ] Undo for rename and new folder (route through the engine).
- [ ] Drag & drop: same volume move, cross volume copy; Option copy, ⌘ move, Option+⌘ alias (Windows mapping: Ctrl copy, Shift move, Alt shortcut); cursor badge.
- [x] NFC-normalized, case/diacritic-insensitive duplicate checks; URL-based paths; separator/traversal validation on rename.
- [x] Engine tests: copy/move/trash round trips with undo/redo pairs, keep-both naming, skip/replace policies, store persistence (9 tests).
- [ ] Scale tests: 10k small files + 5 GB sparse, cross-volume via disk image.

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
- [ ] Services: Open in Dora the Explorer, Open in Dora the Explorer (new tab), Reveal in Dora the Explorer.
- [ ] `dora://open?path=…&tab=new` and `dora` CLI helper.
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
