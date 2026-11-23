# Full-repo adversarial code review — 2026-11-22 (HEAD `6fa8a67`)

Five fresh-context reviewers covered every line of all 73 Swift files, packages,
tests and infra (OCR delegation: `ocr delegate preview/rule`; 45 reviewable + 28
explicitly-included excluded files; ~8.9k Swift lines). Findings verified with
live syscall probes, lldb on the running app, and executed engine scenarios.

Verdicts: **NO-SHIP ×5** — this document tracks what shipped as fixes and what stays open.

---

# Final full-repo OCR delegate review — 2026-11-22 (HEAD `3e22cd6`)

Host-agent delegation run (ocr delegate preview/rule; clean tree → review set =
all 74 tracked Swift files + configs per request, ~9.7k Swift lines; the Swift
rule checklist applied file-by-file). Verified the shipped fixes for the five
NO-SHIP reports all remain intact, then audited the two post-review commits
(`d4f48d0`, `3e22cd6`) line-by-line plus a fresh sweep of the established
modules. Build gate re-verified honestly: `make clean && make build &&
make test` → BUILD SUCCEEDED, all suites green, exit 0; window probe onscreen=true.

**Verdict: SHIP** — after the fixes below.

## Fixed in this pass (final review findings)

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| F1 | high | **Stale cells on metadata-only refreshes**: identical row ids made `applyRowTransition` a no-op, so a watcher metadata update (mtime/size changed, sort unchanged) never reconfigured visible cells — "Date Modified" text stayed wrong until the next structural change. | `needsVisibleRowRefresh(transition:oldGeneration:newGeneration:)` — `.none`+new generation → `reloadData(forRowIndexes:columnIndexes:)` over visible rows only (selection/viewport untouched); SDK-verified API; 3 new unit tests (`VisibleRowRefreshTests`, suite 21→24). |
| F2 | high | **Advertised thumbnail purge was dead code**: `ThumbnailCoordinator.purge()` had no call site; in-flight QL jobs were never actually cancelled (`cancel(_:)` never called), and a purged cache could be re-polluted by a job finishing after the purge. | Purge wired into `ContentViewContainer.tearDown()` (window close) with an honest comment (per-navigation purge would defeat the cache other windows may rely on); service now cancels the real `QLThumbnailGenerator.Request`s and checks `Task.isCancelled` before cache-store/delivery. |
| F3 | medium | **Concurrency cap accounting bug**: `inFlight` was keyed by `Request` — duplicate requests (scroll past the same item twice pre-cache) overwrote each other's slots, so the cap undercounted and let >5 QL jobs run; race also corrupted bookkeeping. | UUID-keyed job slots (one per running job, cap exact); duplicate requests join a waiters list and get delivered when the original job completes — no duplicate QL generation, no dropped deliveries. |
| F4 | medium | **Breadcrumb chevron menus popped uninvited**: enumeration completes async and popped `NSMenu` unconditionally — a stale completion (user clicked away / navigated) stole the event loop ~50 ms after the click. | Monotonic request id + weak anchor + `window != nil` + 1.0 s freshness gate; `update(path:)` invalidates outstanding loads on navigation. |
| F5 | medium | **Drag-over pasteboard re-read every callback**: `validateDrop` fires on every drag-motion row crossing; each uncached `readObjects` is a pasteboard-server IPC round trip. | Session cache keyed by drag pasteboard name (bounded, self-pruning). |
| F6 | medium | **`DirectoryModel.refresh` removed names O(k·n) on the main actor**: per-name `firstIndex(where:)` scans — mass events (git checkout, bulk delete) stalled the UI on large folders. | Single-pass filter + identity rebuild, merged in O(n + k) with one allocation. |
| F7 | low | `SidebarView.update` rebuilt `Entry.standardEntries()` per row per applyTab (8 allocs + home-dir lookups × rows); pointless `weak row` capture. | Entries computed once at init; `update` reads the cached array. |
| F8 | low | Duplicate `syncSortIndicators()` in `DetailsViewController.attach` (else-branch call + unconditional call). | Removed the redundant branch. |
| F9 | low | `FolderViewStore.prune()` existed but was never called — folder-views.json grows forever. | `save()` now prunes (500-entry cap) before scheduling the write. |
| F10 | **critical** | **Runtime crash (SIGTRAP, EXC_BREAKPOINT)** — the debounced folder-view persist carried `@MainActor` isolation onto the private `com.dorasoft.dora.folderviews` background queue; the Swift 6 runtime's executor assertion (`_swift_task_checkIsolatedSwift`) trapped 0.4 s after ANY sort/group/column/hidden change. Two `.ips` crash reports confirmed (21:34, 14:02). Not caught by smoke probes (they never changed view settings). | `persist` is now `nonisolated static` with an explicit `@Sendable` work-item closure (encode+write is pure I/O and belongs off-main); debounce interval injectable; repo-wide sweep for the same pattern found no other instance (`WindowRegistry`'s work item runs on the main queue, legal). Regression test runs the full debounced path — it killed the test process before the fix and passes after (suite 24→25). |

## Confirmed still open (carried, risk-ordered)

All prior open ledger items stand as written below: C6 (TrashStore sync
init/load on main), C7 (TrashStore prune never called), C8 (undo-path trash not
re-recorded in store), B11/B12/B10, A3 (Escape strands hidden path field as
first responder), A4 (breadcrumb context-menu coordinate space), A5 (+now
sidebar divider) snap-back on every applyTab, A8 overflow overlap, A10 full
breadcrumb rebuild, D2 user-drag widths not persisted, D4 FolderViewStore
init/flushNow sync on main, D6 multi-select copies only first path, D7 F2 on
`Set.first`, E10/E11/E16/E19, C9 unbounded navigation history, A13 dead search
UI (searchField + Filter button have no wiring — Phase 13), A6 StatusBarView
layer color baked at init, A15 VoiceOver values.

## Not reopened (checked and sound this pass)

PassRetained/release-callback FSEvents balance and failure paths · redo
step-inversion · replace park/revert trio · self-source + recursion guards ·
row-space-before-mutation order + `isSyncingSelection` bracket ·
`shouldPerformMove` live-session gate · tab-strip arranged-subview cleanup ·
per-id tab menus · pre-removal workspace persistence · bulk parser format ·
ID scheme unification (`parent#ino`, hard-link `#name`) · CI project/scheme,
pipefail gate.

## Fixed in the review sprint (`feat/fixes-review-1` commit)

| # | Severity | Finding | Fix |
|---|----------|---------|-----|
| B1 | high | **getattrlistbulk fast path was 100% dead** — the decoder expected a record format that doesn't exist (`u16 bitmapcount` guard) and misread the group length word, silently falling back to per-entry readdir+lstat on every directory. The perf tests stayed green because they validated the fallback. | Parser rewritten against the SDK man page example + live kernel buffers: `[u32 total length] [attribute_set_t] [attrs by ascending bit, sequential packing]`; name via attrreference offset. Proof test parses a **raw captured kernel buffer**. |
| B3 | high | Watcher refresh built `hashValue`-based ids that never matched enumerated `path#ino` ids — touching a listed file appended a **duplicate row**. | Unified id scheme `parentDir#st_ino` (hard links add `#name`). Empirical note: bulk's `ATTR_CMN_FILEID` vends the **POSIX inode**, single-file `getattrlist` vends a **different catalog id** for the same bit — processors must not mix them. |
| B2 | medium | Bulk tests couldn't distinguish bulk from fallback (the reason B1 shipped). | Raw-buffer fixture test + hard-link identity test assert the actual parse. |
| B4 | high | FSEvents context used `passUnretained` with nil retain/release: stop/nil racing an in-flight callback = use-after-free, exercised on every navigation. | `passRetained` + release callback; failure paths balance the retain. |
| B7 | medium | `WatchRoot` only set for `recursive` — deleting the watched folder or unmounting left the model permanently stale. | Flag always set; root-changed → `.rescan` (already wired downstream). |
| B5 | medium | Fire-and-forget refresh tasks: interleaved `.removed`/`.inserted` could delete fresh rows; stale-directory refresh could inject wrong items. | Tasks tracked in `refreshTasks`, cancelled with loads; freshness gate `eventDirectory == directory`. |
| B6 | medium | Load captured `settings` at start; final publish re-imposed stale sort/group after a mid-load settings change. | Fresh settings read at both publish points. |
| B8 | medium | `path#inode` collided for same-dir hard links (duplicated/overwritten rows). | nlink>1 disambiguates with `#name`; covered by `hardLinksGetDistinctIDs`. |
| C1 | high | `.replace` + failed follow-up copy left the parked original in the Trash with **no undo record and no bookkeeping**. | Failed-after-park reverts the park (moves original back to its exact path) before reporting. |
| C2 | high | No self-source guard: move/replace into the folder containing the source **trashed the source itself**. | `resolve()` returns `.skip` for `proposed == source` before any policy applies. |
| C3 | high | Redo replayed steps in forward order — redo of replace corrupted state: files renamed `(2)`, restored originals re-trashed, move-redos failed then trashed. | `applyUndo` collects step inverses in execution order and **reverses** them for the redo record; covered by replace/copy + replace/move redo tests. |
| C4 | medium | Same-folder move under keepBoth silently renamed the user's file in place. | Same-source guard (Finder-style no-op). |
| C5 | medium | No ancestor/descendant guard: folder-into-itself copy created 130-deep junk trees with partial residue. | Guarded for copy and move; junk-tree regression test. |
| C13 | medium | Vacuous test (`!failures.isEmpty || !succeeded.isEmpty`). | Replaced with hard self-copy, redos, park revertions, recursion guard (FileOps suite 9→13). |
| D1 | high | `applyRowTransition` ran unbracketed with the stale row space: synchronous `endUpdates()` selection notifications corrupted `tab.selectedItemIDs` — next publish visually deselected rows and Edit>Copy no-op'd. | Row space swapped **before** table mutation; splice+reapply bracketed by `isSyncingSelection`. |
| A1 | high | `TabStripView.rebuild` right-click closure captured its own view (self-retain) AND never removed arranged subviews — leaked the full tab view tree on **every sync**, forever. | Weak anchor; `removeArrangedSubview` before `removeFromSuperview`; selected-tab scroll deferred to post-layout. |
| A2 | high | Tab context-menu items all targeted the **selected** tab: "Close tab" closed a different tab; "Close other tabs" deleted the clicked one. | Menu actions are per-id (`menuCloseSpecificTab` etc.) and operate on the clicked tab. |
| A9/E7 | medium | Tear-off / close-others / close-right never cancelled the removed tabs' models/watchers. | All removal paths route through `contentContainer.closeTab(id)`. |
| E1 | high | Stale cut marker made the next ⌘V **move files** from a dead cut (pasteboard outlives the app; marker undeletable). | `shouldPerformMove` requires live session `cutPaths` — empty means copy. |
| E2 | high | Undo/redo popped records before the async apply; a superseded task evaporated them. | In-flight guard; records popped only on completion; cancellation-tagged failures suppressed from error sheets (E8). |
| E3 | high | Closing the last window snapshotted an **empty workspace** — restore worked only for menu-quit. | Workspace persisted pre-removal in `closeWindow`; redundant empty-list save removed. |
| E4 | high | CI invoked `Fenestra.xcodeproj`; it has never been able to pass. | `Dora.xcodeproj` / scheme `Dora`. |
| E5 | high | `make test` piped through `tail`, reporting **tail's** exit status — the test gate couldn't fail. | `set -o pipefail`. |
| E6 | medium | `validateMenuItem` was plain Swift (invisible to the ObjC responder machinery) — menu state lied about every command. | `@objc` exposure. |
| E8 | medium | Cancelled op surfaced a literal "cancelled" error sheet. | `FileOperationFailure.isCancellation`; suppressed. |
| E9 | medium | "Up" bound to caret, not ⇧⌘↑ (README lied). | `NSUpArrowFunctionKey` binding; README table now true. |
| A17/C12 | low | Dead `GlassHostView`/`ChromeBackground` SwiftUI surface misdescribing the architecture. | Deleted. |

**Tests:** FSCore 30 (incl. raw-kernel bulk proof, hard-link ids, watcher), FileOps 13
(park revert, replace redos, self-source, recursion), app 21 (row-transition edges);
all previously green suites re-run.

## Open (next sprints, risk-ordered)

- **C6** main-thread `TrashStore` init/load from `WindowController` (move to lazy async load); **C7** `prune()` never called; **C8** undo-path trash not recorded in store.
- **E7-outcome** `menuCloseOtherTabs` mass-close should batch a debounced persist (currently one synchronous save).
- **B11** `firstBatchLatency` not reset per reload; **B12** numeric comparator overflow/non-ASCII digits (not strict-weak); **B10** symlink rows drift via follow-symlink probes; **B14** `.renamed`/timestamp dead API; **B15** VolumeService test leaks observers; **B16** vacuous main-thread-IO test; **B13** stale doc + dead `treatPackagesAsFiles`.
- **A3** Escape leaves hidden field first responder + stale edit-mode primer; **A4** breadcrumb context-menu coordinate space (`segment.convert`); **A5** divider drags snap back (persist `splitViewDidResizeSubviews`); **A6** dynamic layer colors baked at init (add `viewDidChangeEffectiveAppearance` overrides); **A8** « overflow overlaps first segment; **A10** breadcrumb trail full rebuild per navigation (diff/reuse); **A12** unreadable-folder menu says "No subfolders" (E-level: message the error); **A14** root volume-name placeholder until next update; **A15** VoiceOver value updates for tabs/breadcrumbs (Phase 18 pass).
- **D2** user column-drag not persisted (only chooser/fit changes); **D3** packages render as plain folders (icon cache key ignores UTType for directories); **D4** `FolderViewStore` init + `flushNow` synchronous on main (align with WorkspaceStore's queue); **D5** rename-field staleness across splices; **D6** multi-select "Copy as Pathname" copies only the first path; **D7** F2 renames a `Set.first` arbitrary member (use topmost row); **D9** click-away discards rename text (Windows commits); **D10** hover fill survives row recycle; **D12** rename validation O(n) NFC pass per commit at 100k (pre-normalized index).
- **E9-adjacent** `isEnabled` flag in PersistedWorkspace never written true/false meaningfully; **E10** Settings… dead item (Settings window = Phase 16); **E11** sidebar/details widths never round-trip (tie to A5); **E12** quit with in-flight ops (applicationShouldTerminate flow); **E16** smoke-test vacuous nil-`bundleIdentifier` assertion; **E17** restoring path re-saves + redundant syncChrome; **E19** missing standard menu items (Enter Full Screen); **E20** icon-render nits; **E21** trademark name review; **E22/C15** AppCore zero logic tests (closeTab math, restore bounds, store round-trip); **C9** unbounded navigation history; **A13** search/filter UI dead (Phase 13); **A19+** localization/a11y umbrella (Phase 18).

## Performance notes (from review and probes)

The dead bulk decoder was the single biggest perf regression in the product —
its resurrection is the "efficiency parity" workstream's core fix. Watcher
duplicate rows (B3) caused visible row-doubling and selection drift; combined
with the splice-based publish these deliver Finder-grade live updates.
