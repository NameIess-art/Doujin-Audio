# Testing

Run these checks before merging app changes:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

`flutter analyze` is expected to report zero issues. CI runs the same baseline checks on pushes to `main` and on pull requests.

Focused core logic tests can be run while refactoring playback behavior:

```bash
flutter test test/library_organizer_test.dart
flutter test test/playback_queue_resolver_test.dart
flutter test test/timer_runtime_calculator_test.dart
```

These tests cover pure Dart logic extracted from the provider layer: library grouping and sorting, next-track queue resolution, and sleep timer runtime calculations.

For Android playback changes, also perform a device smoke test:

1. Install the debug APK on a physical Android device.
2. Start playback from a local folder.
3. Turn the screen off and confirm playback continues.
4. If multi-session playback is enabled, confirm all active sessions keep playing.
5. Toggle notification controls and confirm playback state stays consistent.
