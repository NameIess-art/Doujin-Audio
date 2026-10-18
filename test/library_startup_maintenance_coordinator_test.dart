import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/application/library_startup_maintenance_coordinator.dart';

void main() {
  test(
    'maintenance waits again when interaction starts between stages',
    () async {
      final idleRequested = Completer<void>();
      final releaseIdle = Completer<bool>();
      final completed = Completer<void>();
      final calls = <String>[];
      var interacting = false;
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_, _) async {
          if (!interacting) return true;
          if (!idleRequested.isCompleted) idleRequested.complete();
          return releaseIdle.future;
        },
        cleanupOrphanedImports: (_) async {
          calls.add('cleanup');
          interacting = true;
        },
        ensureEntries: (_) async => calls.add('entries'),
        backfillDurations: ({waitForIdle}) async {
          expect(await waitForIdle!(), isTrue);
          calls.add('durations');
          completed.complete();
        },
      );

      coordinator.schedule(const ['/music/track.mp3']);
      await idleRequested.future;
      expect(calls, ['cleanup']);
      interacting = false;
      releaseIdle.complete(true);
      await completed.future;
      await coordinator.dispose();
      expect(calls, ['cleanup', 'entries', 'durations']);
    },
  );

  test('cancelling an idle wait prevents later maintenance stages', () async {
    final waiting = Completer<void>();
    final release = Completer<void>();
    var entries = 0;
    final coordinator = LibraryStartupMaintenanceCoordinator(
      waitForUiIdle: (_, shouldCancel) async {
        waiting.complete();
        await release.future;
        return !shouldCancel();
      },
      cleanupOrphanedImports: (_) async => fail('cancelled cleanup ran'),
      ensureEntries: (_) async => entries++,
    );

    coordinator.schedule(const ['/music/track.mp3']);
    await waiting.future;
    final cancellation = coordinator.cancelAndWait();
    release.complete();
    await cancellation;
    await coordinator.dispose();
    expect(entries, 0);
  });

  test(
    'cancelAndWait waits for active cleanup and invalidates entry writes',
    () async {
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      var ensuredEntries = 0;
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_, _) async => true,
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
        waitForUiIdle: (_, _) async => true,
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
      waitForUiIdle: (_, _) async => true,
      cleanupOrphanedImports: (_) async => throw StateError('cleanup failed'),
      ensureEntries: (_) async {},
    );

    coordinator.schedule(const <String>['/music/track.mp3']);

    await expectLater(coordinator.dispose(), completes);
  });

  test(
    'startup work repairs entries, imports details, then backfills',
    () async {
      final calls = <String>[];
      final completed = Completer<void>();
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_, _) async => true,
        cleanupOrphanedImports: (_) async => calls.add('cleanup'),
        migrateCoverCache: (_) async => calls.add('covers'),
        ensureEntries: (_) async => calls.add('entries'),
        migrateAudioDetails: (_) async => calls.add('details'),
        backfillDurations: ({waitForIdle}) async {
          calls.add('durations');
          completed.complete();
        },
      );

      coordinator.schedule(const <String>['/music/track.mp3']);
      await completed.future;
      await coordinator.dispose();

      expect(calls, <String>[
        'cleanup',
        'covers',
        'entries',
        'details',
        'durations',
      ]);
    },
  );
}
