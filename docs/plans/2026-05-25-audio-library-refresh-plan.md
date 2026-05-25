# Audio Library Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use flutter-craft:flutter-executing to implement this plan task-by-task.

**Goal:** Rebuild the audio library pull-to-refresh pipeline so scanning and UI presentation are decoupled, with heavy scan work completed in the background and visible library updates applied to the UI in small non-janky batches.

**Architecture:** Existing Provider + Riverpod slice architecture, refactored into scan staging, commit scheduling, and presentation-safe batched application.

**Dependencies:** No new packages.

---

## Task 1: Add staged refresh models for background scan output

**Layer:** Data

**Files:**
- Modify: `lib/services/library_scanner_service.dart`
- Modify: `lib/services/library_scanner_isolate.dart`

**Implementation:**
- Introduce immutable refresh-staging models in `library_scanner_service.dart` for one refresh pass:
  - `LibraryRefreshChunk`
  - `LibraryRefreshPlan`
  - `LibraryRefreshFolderResult`
- Each staged folder result should contain:
  - source folder path
  - effective library root
  - scanned tracks ready for merge
  - disk paths or retained paths used for deletion pruning
  - child folders discovered under watched libraries
  - duplicate/failure counts needed for progress/result reporting
- Keep isolate work responsible only for transforming raw scanned tracks into merge-ready lists and entry batches; do not let it touch provider state.
- Add helpers that collect all scan results first, without mutating visible library content:
  - `_buildLibraryRefreshPlan(...)`
  - `_scanLibraryRootForRefresh(...)`
  - `_scanWatchedFolderForRefresh(...)`
- Preserve current exclusion behavior and path canonicalization when building the staged plan.

**Verification:**
```bash
flutter analyze lib/services/library_scanner_service.dart lib/services/library_scanner_isolate.dart
# Expected: No issues found
```

**Commit:**
```bash
git add lib/services/library_scanner_service.dart lib/services/library_scanner_isolate.dart
git commit -m "refactor(library): stage refresh scan output before commit"
```

## Task 2: Add provider-level staged commit APIs for non-blocking UI application

**Layer:** Presentation

**Files:**
- Modify: `lib/providers/audio_provider_library.dart`
- Modify: `lib/providers/audio_provider.dart`
- Modify: `lib/services/audio_state_services.dart`

**Implementation:**
- Add explicit staged-refresh application APIs on `AudioProvider` so scanner code does not call `addOrReplaceTracks`, deletion pruning, node-order syncing, and batch close logic directly during scanning.
- Add methods along these lines:
  - `beginStagedLibraryRefresh(...)`
  - `applyStagedLibraryRefreshChunk(...)`
  - `finishStagedLibraryRefresh(...)`
- Extend library batch state so heavy rebuilds are not triggered for every chunk:
  - keep collecting changed tracks, deleted paths, library entry mutations, watched-folder additions/removals
  - defer `_rebuildLibraryIndexes()`, `_syncGroupOrderFromLibrary()`, `_syncLibraryNodeOrder(...)`, and final slice sync to controlled commit boundaries
- Ensure each visible commit chunk:
  - mutates only a bounded number of tracks/folders
  - does not emit broad progress notifications that force `LibraryTab` to rebuild content mid-commit
  - yields back to the event loop between chunks
- Add a dedicated revision or state flag for "visible library content changed" separate from transient background scan progress so list consumers can ignore scan-only changes.
- Keep persistence batched and fire-and-forget during refresh where safe.

**Verification:**
```bash
flutter analyze lib/providers/audio_provider_library.dart lib/providers/audio_provider.dart lib/services/audio_state_services.dart
# Expected: No issues found
```

**Commit:**
```bash
git add lib/providers/audio_provider_library.dart lib/providers/audio_provider.dart lib/services/audio_state_services.dart
git commit -m "refactor(library): add staged refresh commit pipeline"
```

## Task 3: Rewrite refreshWatchedFolders to use plan-then-commit flow

**Layer:** Presentation

**Files:**
- Modify: `lib/services/library_scanner_service.dart`

**Implementation:**
- Replace the current refresh flow in `refreshWatchedFolders(...)`.
- New flow:
  1. mark scan as background
  2. build a complete refresh plan in the background
  3. once the plan is ready, commit visible updates in bounded UI chunks
  4. close the staged refresh and show result snackbar
- During plan building:
  - update internal counters as needed
  - avoid mutating visible `provider.libraryTree`-backed content
  - avoid repeated `endLibraryBatch()` / `beginLibraryBatch()` cycles during background scan
- During commit:
  - apply results in chunked order, such as 50-150 tracks per frame-sized batch
  - call `await Future<void>.delayed(Duration.zero)` between chunks
  - only rebuild indexes/tree at explicit chunk boundaries or final flush, not per scanned folder
- Preserve existing behavior for:
  - library roots with child folders
  - content URI scan fallback rules
  - deleted file pruning
  - exclusion filtering
  - snackbars and refresh completion counts

**Verification:**
```bash
flutter analyze lib/services/library_scanner_service.dart
# Expected: No issues found
```

**Commit:**
```bash
git add lib/services/library_scanner_service.dart
git commit -m "refactor(library): decouple refresh scan from visible commits"
```

## Task 4: Narrow LibraryTab rebuild triggers during background refresh

**Layer:** Presentation

**Files:**
- Modify: `lib/screens/library_tab.dart`
- Modify: `lib/screens/library_tab_category_widgets.dart`
- Modify: `lib/screens/library_tab_edit.dart`

**Implementation:**
- Keep current UI and gesture behavior, but stop large library widgets from observing transient scan-only state.
- In `LibraryTab`, split observed state into:
  - header refresh/loading state
  - visible list structure/content revision
  - optional foreground scan card state
- Ensure pull-to-refresh background scan does not cause tree recomputation while content is unchanged.
- Keep category snapshot refresh tied to actual library content/detail revisions, not background scan progress.
- Remove broad watchers where possible, especially patterns that watch full `libraryStateProvider` or full `provider.libraryTree` when a narrower selector or memoized lookup can be used.
- Preserve `GlassRefreshIndicator`, current layout, search behavior, and category views.

**Verification:**
```bash
flutter analyze lib/screens/library_tab.dart lib/screens/library_tab_category_widgets.dart lib/screens/library_tab_edit.dart
# Expected: No issues found
```

**Commit:**
```bash
git add lib/screens/library_tab.dart lib/screens/library_tab_category_widgets.dart lib/screens/library_tab_edit.dart
git commit -m "refactor(library): narrow rebuild scope during refresh"
```

## Task 5: Add refresh regression tests for staged commit behavior

**Layer:** Test

**Files:**
- Modify: `test/audio_provider_integration_test.dart`

**Implementation:**
- Add integration coverage for the new refresh pipeline with `AudioProvider.test(...)`.
- Test cases:
  - background refresh does not expose partial visible content before staged commit begins
  - staged chunk application updates library content incrementally and finishes with correct final library state
  - deletion pruning still removes missing tracks and library entries
  - exclusion state survives refresh
  - refresh with unchanged scan results does not inflate structure/content revisions unnecessarily
- Keep tests repository/state focused rather than widget-heavy.

**Verification:**
```bash
flutter test test/audio_provider_integration_test.dart
# Expected: All tests passed
```

**Commit:**
```bash
git add test/audio_provider_integration_test.dart
git commit -m "test(library): cover staged refresh pipeline"
```

## Task 6: Full verification and manual refresh validation

**Layer:** Test

**Files:**
- Modify: existing changed files only if verification exposes issues

**Implementation:**
- Run static checks and targeted tests.
- Run the app and manually verify library pull-to-refresh on a realistic library.
- Validation checklist:
  - pull gesture stays smooth
  - refresh indicator animates smoothly
  - no long frozen frames before list becomes interactive again
  - content remains stable during background scan
  - when visible updates begin, they arrive in batches instead of one blocking freeze
  - no regressions in library edit page and category views

**Verification:**
```bash
flutter analyze
flutter test test/audio_provider_integration_test.dart
flutter run
# Then manually verify Library tab pull-to-refresh behavior
```

**Commit:**
```bash
git add <only-files-changed-during-verification>
git commit -m "fix(library): address staged refresh verification issues"
```
