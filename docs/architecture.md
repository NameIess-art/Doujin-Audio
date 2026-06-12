# Architecture Notes

Nameless Audio currently keeps `AudioProvider` as the UI-facing facade. Screens continue to read state and call commands through the provider, while platform-specific playback work remains behind the existing native playback bridge and notification services.

State ownership is intentionally split by responsibility:

- `AudioProvider` is the single mutable `ChangeNotifier` facade for legacy UI commands and orchestration.
- Riverpod exposes repositories, service state slices, and derived UI projections. It must not create a second mutable source for library, queue, session, timer, or playback state.
- New business rules belong in an existing pure Dart service when possible; `AudioProvider` should coordinate those rules and publish state changes.

Playback notifications use `PlaybackNotificationService` and
`NotificationsPlatformService` on the Dart side, with routing and rendering
implemented by the native Kotlin notification and playback services. There is
no separate Dart audio-service notification handler.

Current platform responsibility boundaries include:

- `LibraryScannerService`: refresh/import orchestration and scan-result merging.
- `LibraryScannerPlatformGateway`: Android scan, folder listing, picker, and cache MethodChannel I/O.
- `FileCacheOperations`: stable file-cache MethodChannel facade.
- `FileCacheMediaScanOrchestrator`: media-scan strategy and fallback ordering.
- `MediaNameMetadata`: display-name normalization and media-type rules.
- `ApplicationCachePolicy`: application-cache preferences, accounting, and eviction.
- `NativePlaybackService`: MediaSession lifecycle, playback commands, and foreground-service decisions.
- `NativePlaybackSessionRestorer`: persisted native-session reconstruction.

New core business rules should prefer pure Dart helpers under `lib/services` when they can be tested without Flutter widgets, method channels, or Android services. Current extracted helpers include:

- `LibraryOrganizer`: builds library folder trees, groups tracks by watched folders, sorts tracks, and handles duplicate or `content://` paths.
- `PlaybackQueueResolver`: resolves next and previous track paths for sequential, folder-scoped, and random playback modes.
- `TimerRuntimeCalculator`: calculates timer runtime state, countdown ticks, trigger waiting, and auto-resume readiness.

Shared lightweight models live under `lib/models`. Tests for these pure helpers live in `test/*_test.dart` and should be expanded before changing behavior in the corresponding provider methods.

Large screen and provider files are split with same-library `part` files when the extracted code still depends on private state. This keeps public APIs unchanged while separating page state, UI widgets, notification helpers, playback helpers, and persistence helpers into smaller maintenance units.
