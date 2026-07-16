# Testing

Run these checks before merging app changes:

```bash
flutter pub get
flutter analyze
flutter test --coverage --concurrency=1
dart run tool/verify_coverage.dart
cd android && ./gradlew testDebugUnitTest && cd ..
flutter build apk --debug
flutter build windows --release
dart run tool/verify_release.dart
```

`flutter analyze` is expected to report zero issues. CI runs the same baseline checks on pushes to `main` and on pull requests. The Gradle unit test task is configured to run app and in-repository Android tests while skipping external Flutter plugin test tasks from the Pub cache.

Release builds require a complete `android/key.properties` and matching
keystore. Missing or incomplete release signing configuration intentionally
fails `assembleRelease`, `bundleRelease`, and Flutter release APK builds.
For repeatable local release deployment, run
`powershell -ExecutionPolicy Bypass -File tool/setup_local_release_signing.ps1`
once. It creates a persistent, Git-ignored local signing identity and does not
replace the official GitHub Release signing key.
When that local signing identity exists, local debug APKs use it too, so debug
and release deployments can update each other on the same device. The release
deployment script also raises the temporary Android `versionCode` above the
currently installed app when needed, without changing `pubspec.yaml`.
The sqlite3 native-assets hook uses each platform's system SQLite library
(`winsqlite3` on Windows and `sqlite` on Android), so builds do not depend on
downloading a GitHub-hosted sqlite3 binary.
Devices carrying a legacy debug-signed release require a one-time migration.
After exporting a `.nalbackup`, run `script\deploy_arm64.bat --replace-signature`;
or run `tool/deploy_android_release.ps1 -ReplaceSignature`. The flag explicitly
allows uninstalling the old package and its local data.
Running `script\deploy_arm64.bat` without arguments also prompts for the same
one-time migration when it detects a signature mismatch; type `REPLACE` only
after exporting a backup.
Tag workflows create temporary signing files from GitHub Secrets and publish
arm64 APK/Windows ZIP assets together with SHA-256 checksum files.
CI also proves that release signing validation fails when `key.properties` is
absent, preventing accidental debug-signed release artifacts.
The app refuses to install downloaded updates unless the matching checksum
asset is present and valid.

Coverage is aggregated by configured directory prefix rather than by an
arbitrary first matching file. The verifier fails when LCOV is empty, a
configured prefix matches no source record, or any threshold regresses. The
current anti-regression floors are total 61%, app state 70%, player application
74%, library application 71%, ASMR application 76%, settings application 69%,
data-support application 82%, core platform 52%, and core persistence 90%.
Raise them after tests land; never lower or bypass them to merge a change.

Architecture checks are part of the normal Flutter suite. They enforce pure
feature domain imports, confine ordinary channel construction to
`core/platform` (with the native playback bridge as the documented high-rate
exception), and prevent presentation from creating channels or importing the
database.

Notification behavior is covered through Dart platform-service tests and
Android notification-routing tests. Keep these tests aligned with the native
notification payload instead of introducing a second Dart notification
handler.

Foreground-service scheduling is covered by the pure JVM
`NativePlaybackForegroundCoordinatorTest`. Extend its fake host when changing
bootstrap, notification signatures, grace-stop, watchdog, or task-removal
decisions; keep platform notification rendering in the existing notification
tests.

MethodChannel names and methods are centralized in Dart and Kotlin platform
channel constants. Keep `test/platform_channels_test.dart` and
`android/app/src/test/.../PlatformChannelsTest.kt` aligned whenever the
protocol changes.

Envelope decoding and required-argument behavior also have focused coverage:

```bash
flutter test test/native_playback_bridge_test.dart test/platform_method_client_test.dart test/platform_services_test.dart
cd android && ./gradlew testDebugUnitTest --tests com.nameless.audio.ChannelContractTest
```

Database responsibility files remain one library. Run both database suites and
the ASMR persistence suite after moving methods between those files:

```bash
flutter test test/app_database_test.dart test/app_database_maintenance_test.dart test/asmr_one_settings_test.dart
```

All Dart `file_cache` platform behavior is exercised through
`FileCachePlatformGateway`. Add gateway tests for payload construction, native
value parsing, missing-plugin/error degradation, and scan-stream fallback
before changing its wire contract.

Widget tests must fail on every unexpected Flutter exception. Do not drain or
filter `tester.takeException()` merely to keep a test green. App-shell coverage
must include portrait, Android landscape, and dynamic view-size changes so
responsive regressions remain visible.

Focused core logic tests can be run while refactoring playback behavior:

```bash
flutter test test/library_organizer_test.dart
flutter test test/playback_queue_resolver_test.dart
flutter test test/timer_runtime_calculator_test.dart
```

These tests cover pure Dart logic extracted from the provider layer: library grouping and sorting, next-track queue resolution, and sleep timer runtime calculations.

Release-safety and recovery contracts have focused tests:

```bash
dart run tool/verify_release.dart
flutter test test/app_backup_service_test.dart test/diagnostic_report_service_test.dart
flutter test test/permission_status_service_test.dart test/theme_provider_test.dart
flutter test test/accessibility_motion_test.dart test/i18n_language_tables_test.dart
```

Experience quality checks have focused UI and documentation baselines:

```bash
flutter test test/experience_quality_widgets_test.dart test/marquee_ui_test.dart
flutter test test/player_playlist_widgets_test.dart test/library_widgets_test.dart test/audio_detail_widgets_test.dart test/settings_widgets_test.dart
flutter test test/document_encoding_test.dart test/accessibility_motion_test.dart test/i18n_language_tables_test.dart
```

Use these when changing list cards, settings groups, empty/error states,
feedback copy, permissions, update/backup result flows, or documentation
encoding. The manual performance process remains observational and is recorded
in [`docs/release-quality.md`](release-quality.md).

The runtime owner suites are organized by responsibility and share
`test/support/app_runtime_test_fixture.dart` for SQLite schema 3,
platform-channel cleanup, ordered runtime disposal, widget hosting, and pump
helpers:

```bash
flutter test --concurrency=1 test/playback_command_coordinator_race_test.dart test/playback_facade_features_test.dart
flutter test --concurrency=1 test/playback_queue_coordinator_test.dart test/library_facade_test.dart test/library_audio_detail_cover_test.dart
```

Update parsing and selection remain focused in
`test/app_update_service_test.dart`; add malformed GitHub JSON/URL and
asset/checksum pairing cases there without exposing the private typed models.

Run the Android device integration smoke test and use the release-candidate
matrix and performance baseline process in
[`docs/release-quality.md`](release-quality.md) before publishing a tag.
Copy [`release-candidate-template.md`](release-candidate-template.md) into the
release issue or release notes and fill it with real device results.

For Android playback changes, also perform a device smoke test:

1. Install the debug APK on a physical Android device.
2. Start playback from a local folder.
3. Turn the screen off and confirm playback continues.
4. If multi-session playback is enabled, confirm all active sessions keep playing.
5. Toggle notification controls and confirm playback state stays consistent.

For release checks, install the generated arm64 split APK on a physical Android device and smoke test startup, playback, notification controls, video-to-audio conversion, and any permission handoff touched by the change.
