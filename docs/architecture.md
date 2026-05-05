# Architecture Notes

AudioPlayer currently keeps `AudioProvider` as the UI-facing facade. Screens continue to read state and call commands through the provider, while platform-specific playback work remains behind the existing native playback bridge and notification services.

New core business rules should prefer pure Dart helpers under `lib/services` when they can be tested without Flutter widgets, method channels, or Android services. Current extracted helpers include:

- `LibraryOrganizer`: builds library folder trees, groups tracks by watched folders, sorts tracks, and handles duplicate or `content://` paths.
- `PlaybackQueueResolver`: resolves next and previous track paths for sequential, folder-scoped, and random playback modes.
- `TimerRuntimeCalculator`: calculates timer runtime state, countdown ticks, trigger waiting, and auto-resume readiness.

Shared lightweight models live under `lib/models`. Tests for these pure helpers live in `test/*_test.dart` and should be expanded before changing behavior in the corresponding provider methods.
