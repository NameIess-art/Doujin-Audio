# Experience Guidelines

This document records the first user-facing polish baseline for Nameless Audio.
It keeps future UI changes small, consistent, and easy to verify.

## Library-Like Cards

- Use `LibraryLikeCardMetrics` for cards that show cover art plus metadata.
- Root cards use `rootTileHeight`, `rootTilePadding`, `cardRadius`, and
  `coverRadius`; avoid local magic numbers for the same measurements.
- The current compact baseline is `rootTileHeight` 148, `contentHeight` 140,
  `infoBlockHeight` 96, `titleBlockHeight` 38, `coverAspectRatio` 1.25, and
  `actionButtonSize` 40.
- Keep root card titles to two static lines in Android list surfaces.
- Keep metadata labels on the fixed 16 px text rhythm. Multi-line tag fields
  may use the remaining rows, but short values must not reserve blank rows.
- Keep card bottom whitespace inside the root tile tight. Do not increase
  `rootTileHeight` or add local bottom padding unless the cover or buttons are
  visibly clipped.
- Keep list metadata text static by default. Use marquee only in focused
  playback surfaces where the user is inspecting one item.
- Preserve the existing 44 px minimum touch height for play, expand, and
  contextual action buttons.

## Platform Motion

- Android list text should not scroll. This keeps notification shade, app
  backgrounding, and system gestures responsive on lower-end devices.
- Windows may keep marquee text in focused playback areas, but large scrolling
  lists should avoid many simultaneous marquee animations.
- Reduced-motion settings should continue to disable decorative animation and
  keep loading states readable.

## Empty, Loading, and Error States

- Empty states should include a short explanation and one clear next action.
- Loading states should avoid layout jumps and keep the final content footprint
  predictable.
- Failure states should name what failed and offer retry, details, or diagnostic
  export when those actions already exist.
- Use consistent feedback verbs:
  - Primary recovery: `Retry`, `Import Audio`, `Check for updates`, or
    `Open release page`.
  - Secondary inspection: `View details` or `Export diagnostics`.
  - Dismissal: `Cancel`, `Close`, or no action for passive SnackBars.
- Import, scan, metadata, download, update, and backup failures should include
  one useful next step instead of only reporting that something failed.

## Permission Status

- Permission entry points live in the permission center and contextual flows;
  do not add first-launch prompts for optional permissions.
- Show each permission as one of four user-facing states: authorized, not
  allowed, limited, or suggested.
- Restricted states should explain the consequence and point to the platform
  settings or the relevant app action when that route already exists.

## Update and Backup Results

- Successful update checks should confirm the version, release source, and
  checksum status when available.
- Successful backups and diagnostic exports should show the file location.
- Failed update or backup actions should offer retry and diagnostic export when
  the existing service can provide enough context.

## Verification Baseline

- Run `flutter analyze` for every experience change.
- Run the focused widget tests for touched screens, usually
  `test/experience_quality_widgets_test.dart`, `test/marquee_ui_test.dart`,
  and `test/library_playlist_widgets_test.dart`.
- Run `test/document_encoding_test.dart` when documentation is touched. It
  verifies `README.md` and `docs/*.md` remain readable as UTF-8 and do not
  contain replacement characters.
- Before release, manually smoke-test Android long-list scrolling, playback
  detail drag, notification shade pull-down, app backgrounding, cover loading,
  and large-library scanning.

## Manual Experience Matrix

Record device, app version, build mode, median result from at least three
runs, and notes. Do not commit device traces.

| Platform | Area | Check |
|---|---|---|
| Android | Long lists | ASMR.ONE and local library scroll smoothly with static list text |
| Android | Player detail | Dragging down reveals the previous page and keeps system gestures responsive |
| Android | System gestures | Notification shade pull-down and background/foreground switching stay responsive |
| Android | Library scale | Cover loading and large-library scans do not block interaction |
| Windows | Library cards | Cover resolution, button placement, and title rhythm remain stable |
| Windows | Motion | Required marquee text continues in focused playback areas without list-wide animation |
