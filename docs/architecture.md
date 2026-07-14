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

- `LibraryScanCoordinator`: refresh/import/cancel operation state expressed as typed `LibraryScanOutcome` values. Localized labels and feedback mapping stay in library presentation.
- `LibraryScannerService`: scan generation, rollback, merge, and catalog writes. It reads and writes the catalog only through `LibraryCatalogReader` / `LibraryCatalogWriter` and returns typed outcomes instead of localized UI messages.
- `LibraryScanDataSource`: permission requests, file/folder selection, local file-system enumeration, and native local/SAF scanning.
- `LibraryScanRules`: pure duplicate, nested-directory, path-overlap, and standalone-folder promotion rules.
- `AudioProviderLibraryCatalog`: the compatibility adapter from the catalog ports to the existing `AudioProvider` facade; it must not own a second state copy.
- `AsmrRemoteCatalogService`: loads category/search pages, recommendations, details, and track trees without owning controller cache or UI state.
- `AsmrAccountSyncService`: owns session recovery, local favorite/history transactions, outbox draining, and remote merge rules. Auth epoch changes cancel stale writes.
- `AsmrPlaybackCoordinator`: resolves an ASMR work or track queue and launches it through `PlaybackSessionLauncher`, without coupling `AsmrLibraryController` to `AudioProvider`.
- `AsmrPreferencesStore`: instance-scoped ASMR persistence backed by an injected `AppDatabase`.
- `LibraryEntryEditorService`: local/SAF disk snapshots used by library editing; presentation only applies the typed snapshot to the existing facade.
- `DataSupportFileService` and `DiagnosticReportExporter`: picker, temporary-file, backup, and diagnostic-export lifecycles kept outside presentation.
- `VideoConversionInputService`: video source and output-directory selection kept outside the converter screen.
- `FileCachePlatformGateway`: the only Dart owner of `file_cache` MethodChannel/EventChannel I/O, including scanning, document operations, cache operations, media helpers, backup, and subtitle resolution.
- `PlatformMethodClient`: the shared strict decoder for envelope-based request/response channels. Best-effort services keep their public safe defaults but log preserved `NativeFailure` details.
- `AppUpdateFlow`: the single presentation coordinator used by startup and settings update checks; it reuses `AppUpdateService`, operation progress, install permission handling, retry, and install feedback.
- `AppUpdateService`: the stable update API. GitHub API and expanded-assets HTML are decoded immediately into private typed release/asset models; malformed rows and non-HTTP(S) URLs do not cross the application boundary.
- `FileCacheMediaScanOrchestrator`: media-scan strategy and fallback ordering.
- `MediaNameMetadata`: display-name normalization and media-type rules.
- `ApplicationCachePolicy`: application-cache preferences, accounting, and eviction.
- `FileCacheOperations`: thin compatibility facade delegating to scanner, storage, metadata, subtitle, and cover components.
- `NativePlaybackService`: MediaSession lifecycle, playback commands, session coordination, AudioFocus, recovery, and persistence.
- `NativePlaybackForegroundCoordinator`: foreground bootstrap/update signature deduplication, grace-stop, watchdog scheduling, and unified-notification retention through a small service host boundary. Notification construction remains in the existing factory/controller.
- `NativeAudioFocusController`: Android AudioFocus request/abandon mechanics and focus-held state.
- `NativePlaybackRecoveryController`: intended playback, retry/expiry scheduling, network and screen triggers, and stalled-session recovery through a testable host/environment boundary.
- `NativePlaybackSessionRestorer`: persisted native-session reconstruction.
- `NativeSessionAudioEffectsRuntime`: Equalizer, LoudnessEnhancer, DynamicsProcessing state mapping and release lifecycle for one native playback session.

Screens, providers, repositories, and feature services must use
`FileCachePlatformGateway` instead of creating direct `file_cache` channels.
Wire names and method names remain centralized in the Dart and Kotlin platform
channel constants.

Android `MainActivity` owns Flutter engine assembly, activity lifecycle, picker
delivery, and notification intent delivery. Power, update, and subtitle-overlay
method handling live in their dedicated handlers; new platform behavior should
extend the matching handler instead of growing `MainActivity`.

Production Dart ownership is reflected directly by the directory tree:

- `lib/app`: bootstrap-facing presentation, localization, theme, the compatibility `AudioProvider` facade, and Riverpod projections.
- `lib/core`: errors, logging, media primitives, persistence, platform gateways, shared UI operation/interaction scheduling, and feature-neutral widgets.
- `lib/features/<feature>/{domain,application,presentation}`: library, player, ASMR, settings, data support, and video conversion code.

New core business rules should prefer a pure helper in the owning feature or
`core` when they can be tested without Flutter widgets, method channels, or
Android services. Current extracted helpers include:

- `LibraryOrganizer`: builds library folder trees, groups tracks by watched folders, sorts tracks, and handles duplicate or `content://` paths.
- `PlaybackQueueResolver`: resolves next and previous track paths for sequential, folder-scoped, and random playback modes.
- `TimerRuntimeCalculator`: calculates timer runtime state, countdown ticks, trigger waiting, and auto-resume readiness.

Shared media models live under `lib/core/media`; feature-specific models remain
under the owning feature's `domain` directory. Tests for pure helpers live in
`test/*_test.dart` and should be expanded before changing behavior in the
corresponding application service.

Large screen and provider files are split with same-library `part` files when the extracted code still depends on private state. This keeps public APIs unchanged while separating page state, UI widgets, notification helpers, playback helpers, and persistence helpers into smaller maintenance units. `SettingsTab` keeps lifecycle and flow composition in its main file while general, appearance, playback, ASMR, data, and update sections are private part builders with explicit inputs and callbacks.

Player-only carousel and progress widgets live in player presentation instead of `core/widgets`. Playlist controls are grouped into transport, time-segment, audio-feature/equalizer, and speed-control parts. Audio-detail cover, field, and fetch-dialog widgets remain private same-library parts.

`audio_state_services.dart` is the stable import entry point. Its state models,
library service, playback/timer services, and notification/settings services
are maintained in responsibility-specific part files.

`AppDatabase` remains one Dart library and keeps schema version 3. Public data
operations are grouped into `app_database_tracks.dart`,
`app_database_sessions.dart`, `app_database_audio_details.dart`,
`app_database_library_entries.dart`, and `app_database_asmr.dart`; connection,
schema/migration, maintenance, and shared row codecs are separated into
`app_database.dart`, `app_database_schema.dart`,
`app_database_maintenance.dart`, and `app_database_row_codecs.dart` within the
same Dart library. This preserves private helper access, transactions, schema
version, and backup compatibility.

Android package ownership mirrors the native boundary: `channel`, `scanner`,
`storage`, `metadata`, `subtitle`, `update`, `common`, and
`player/{service,session,notification,recovery,effects,common}`. The root
`com.nameless.audio` package retains only `MainActivity`.

See [`platform-channels.md`](platform-channels.md) and
[`library-scanning.md`](library-scanning.md) for the boundary contracts and
end-to-end call flows.
