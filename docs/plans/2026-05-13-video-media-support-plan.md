# Video Media Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use flutter-craft:flutter-executing to implement this plan task-by-task.

**Goal:** Let the library import video files as audio-playable media, render standalone picked videos with cover artwork, and keep folder-imported videos behaving like normal audio tracks.

**Architecture:** Existing Provider-based library/playback pipeline plus Android platform-channel media helpers

**Dependencies:** Reuse existing `ffmpeg_kit_flutter_new_audio` if needed, but prefer Android native media APIs for frame extraction.

---

### Task 1: Extend media model and persistence

**Layer:** Data

**Files:**
- Modify: `lib/models/music_track.dart`
- Modify: `lib/services/app_database.dart`
- Modify: `test/app_database_test.dart`

**Implementation:**
- Add an `isVideo` flag to `MusicTrack`
- Persist `isVideo` through JSON and SQLite
- Add DB migration for existing installs

### Task 2: Expand import and scan support to video containers

**Layer:** Data

**Files:**
- Modify: `lib/screens/library_tab_import_actions.dart`
- Modify: `lib/screens/library_tab_folder_imports.dart`
- Modify: `lib/screens/library_tab_edit.dart`
- Modify: `android/app/src/main/kotlin/com/nameless/audio/MainActivity.kt`
- Modify: `lib/services/platform_channels.dart`

**Implementation:**
- Accept common video files in manual add and folder/library scans
- Mark manually added videos as `isSingle: true, isVideo: true`
- Mark folder/library videos as `isVideo: true` but keep existing folder-track behavior
- Expand Android picker MIME filters and native scan/path detection

### Task 3: Add video artwork fallback

**Layer:** Data / Integration

**Files:**
- Modify: `lib/providers/audio_provider_notification_covers.dart`
- Modify: `android/app/src/main/kotlin/com/nameless/audio/MainActivity.kt`
- Modify: `lib/services/platform_channels.dart`

**Implementation:**
- Add a platform-channel method that extracts and caches one frame from a video
- Use it as cover fallback when the track is a video and no image/manual cover is available
- Reuse the same cached result for playlist/library artwork

### Task 4: Render standalone video entries like folder cards

**Layer:** Presentation

**Files:**
- Modify: `lib/screens/library_tab_tree_widgets.dart`
- Modify: `lib/screens/library_tab_category_widgets.dart`

**Implementation:**
- Add a large-card layout for `isSingle && isVideo`
- Show left artwork thumbnail from extracted frame
- Keep folder-contained videos on the existing compact track-row presentation

### Task 5: Verify playback and queue behavior

**Layer:** Integration / Test

**Files:**
- Modify: targeted tests as needed

**Implementation:**
- Confirm playback preparation accepts imported video paths as media URIs
- Add/adjust tests for persistence and import classification
- Run `flutter analyze`, `flutter test`, and `flutter build apk --debug`
