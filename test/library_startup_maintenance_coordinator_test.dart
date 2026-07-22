import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/library/application/library_startup_maintenance_coordinator.dart';

void main() {
  test(
    'cancelAndWait waits for active cleanup and invalidates entry writes',
    () async {
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      var ensuredEntries = 0;
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_) async => true,
        cleanupOrphanedImports: (_) async {
          cleanupStarted.complete();
          await releaseCleanup.future;
        },
        ensureEntries: (_) async {
          ensuredEntries++;
        },
      );

      coordinator.schedule(const <String>['/music/track.mp3']);
      await cleanupStarted.future;

      var cancellationCompleted = false;
      final cancellation = coordinator.cancelAndWait().then((_) {
        cancellationCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(cancellationCompleted, isFalse);

      releaseCleanup.complete();
      await cancellation;

      expect(ensuredEntries, 0);
    },
  );

  test(
    'dispose waits for active maintenance and prevents later schedules',
    () async {
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      var cleanupCalls = 0;
      var ensuredEntries = 0;
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_) async => true,
        cleanupOrphanedImports: (_) async {
          cleanupCalls++;
          cleanupStarted.complete();
          await releaseCleanup.future;
        },
        ensureEntries: (_) async {
          ensuredEntries++;
        },
      );

      coordinator.schedule(const <String>['/music/track.mp3']);
      await cleanupStarted.future;

      var disposalCompleted = false;
      final disposal = coordinator.dispose().then((_) {
        disposalCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(disposalCompleted, isFalse);

      releaseCleanup.complete();
      await disposal;
      coordinator.schedule(const <String>['/music/other.mp3']);
      await Future<void>.delayed(Duration.zero);

      expect(cleanupCalls, 1);
      expect(ensuredEntries, 0);
    },
  );

  test('maintenance failure does not block disposal', () async {
    final coordinator = LibraryStartupMaintenanceCoordinator(
      waitForUiIdle: (_) async => true,
      cleanupOrphanedImports: (_) async => throw StateError('cleanup failed'),
      ensureEntries: (_) async {},
    );

    coordinator.schedule(const <String>['/music/track.mp3']);

    await expectLater(coordinator.dispose(), completes);
  });
}
