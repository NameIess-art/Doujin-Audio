# Experience Guidelines

This document records the first user-facing polish baseline for Nameless Audio.
It keeps future UI changes small, consistent, and easy to verify.

## Library-Like Cards

- Use `LibraryLikeCardMetrics` for cards that show cover art plus metadata.
- Root cards use `rootTileHeight`, `rootTilePadding`, `cardRadius`, and
  `coverRadius`; avoid local magic numbers for the same measurements.
- Keep root card titles to two static lines in Android list surfaces.
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

## Verification Baseline

- Run `flutter analyze` for every experience change.
- Run the focused widget tests for touched screens, usually
  `test/marquee_ui_test.dart` and `test/library_playlist_widgets_test.dart`.
- Before release, manually smoke-test Android long-list scrolling, playback
  detail drag, notification shade pull-down, app backgrounding, cover loading,
  and large-library scanning.
