# Time Segment Label Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use flutter-craft:flutter-executing to implement this plan task-by-task.

**Goal:** Make time-segment endpoints use the current playback position, assign localized sequential default names, and persist a label immediately once both endpoints are valid.

**Architecture:** Existing Riverpod runtime graph and `PlaybackTimeSegmentService`; no new dependencies or persistence paths.

**Dependencies:** None.

---

### Task 1: Add localized default label names

**Layer:** Presentation / Localization

**Files:**
- Modify: `lib/app/localization/app_language_zh.dart`
- Modify: `lib/app/localization/app_language_en.dart`
- Modify: `lib/app/localization/app_language_ja.dart`
- Test: `test/app_language_provider_test.dart`

**Implementation:** Add `segment_default_name` with an `{index}` parameter for all supported languages and assert the resolved text in each locale.

**Verification:** `flutter test test/app_language_provider_test.dart`

### Task 2: Fix current position and automatic persistence

**Layer:** Presentation

**Files:**
- Modify: `lib/features/player/presentation/playlist_tab_detail_content.dart`

**Implementation:** Generate a non-conflicting localized name when starting a new segment. Resolve the latest runtime session position when setting either endpoint. Reuse `_trySaveSegmentDraft` so the second valid endpoint triggers persistence immediately.

**Verification:** `flutter analyze lib/features/player/presentation/playlist_tab_detail_content.dart`

### Task 3: Add interaction regression coverage

**Layer:** Test

**Files:**
- Modify: `test/player_playlist_widgets_test.dart`

**Implementation:** Pump a session detail page, move runtime playback after the immutable detail snapshot exists, set both endpoints, assert immediate timestamp updates and persisted localized default label data.

**Verification:** `flutter test test/player_playlist_widgets_test.dart --plain-name "time segment endpoints use live position and save localized default label"`
