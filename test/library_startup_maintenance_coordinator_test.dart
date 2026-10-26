import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:doujin_audio/core/cache/app_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_startup_maintenance_coordinator.dart';

void main() {
  test(
    'delayed cleanup retains imports committed during its idle wait',
    () async {
      final imports = await Directory.systemTemp.createTemp(
        'maintenance_import_',
      );
      final old = await File(
        path.join(imports.path, 'old.mp3'),
      ).writeAsString('old');
      final retained = {old.path};
      final waiting = Completer<void>();
      final idle = Completer<bool>();
      final cleaned = Completer<void>();
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_, _) {
          if (!waiting.isCompleted) waiting.complete();
          return idle.future;
        },
        cleanupOrphanedImports: () async {
          await AppCacheService.cleanupOrphanedPersistentImports(
            retained.contains,
            importDirectory: imports,
          );
          cleaned.complete();
        },
        ensureEntries: (_) async {},
      );
      try {
        coordinator.schedule();
        await waiting.future;
        final added = await File(
          path.join(imports.path, 'new.mp3'),
        ).writeAsString('new');
        retained.add(added.path);
        final orphan = await File(
          path.join(imports.path, 'orphan.mp3'),
        ).writeAsString('old');
        idle.complete(true);
        await cleaned.future;
        await coordinator.dispose();
        expect(await added.exists(), isTrue);
        expect(await old.exists(), isTrue);
        expect(await orphan.exists(), isFalse);
      } finally {
        if (!idle.isCompleted) idle.complete(false);
        await coordinator.dispose();
        await imports.delete(recursive: true);
      }
    },
  );

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
        cleanupOrphanedImports: () async {
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

      coordinator.schedule();
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
      cleanupOrphanedImports: () async => fail('cancelled cleanup ran'),
      ensureEntries: (_) async => entries++,
    );

    coordinator.schedule();
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
        cleanupOrphanedImports: () async {
          cleanupStarted.complete();
          await releaseCleanup.future;
        },
        ensureEntries: (_) async {
          ensuredEntries++;
        },
      );

      coordinator.schedule();
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
        cleanupOrphanedImports: () async {
          cleanupCalls++;
          cleanupStarted.complete();
          await releaseCleanup.future;
        },
        ensureEntries: (_) async {
          ensuredEntries++;
        },
      );

      coordinator.schedule();
      await cleanupStarted.future;

      var disposalCompleted = false;
      final disposal = coordinator.dispose().then((_) {
        disposalCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(disposalCompleted, isFalse);

      releaseCleanup.complete();
      await disposal;
      coordinator.schedule();
      await Future<void>.delayed(Duration.zero);

      expect(cleanupCalls, 1);
      expect(ensuredEntries, 0);
    },
  );

  test('maintenance failure does not block disposal', () async {
    final coordinator = LibraryStartupMaintenanceCoordinator(
      waitForUiIdle: (_, _) async => true,
      cleanupOrphanedImports: () async => throw StateError('cleanup failed'),
      ensureEntries: (_) async {},
    );

    coordinator.schedule();

    await expectLater(coordinator.dispose(), completes);
  });

  test(
    'startup work repairs entries, imports details, then backfills',
    () async {
      final calls = <String>[];
      final completed = Completer<void>();
      final coordinator = LibraryStartupMaintenanceCoordinator(
        waitForUiIdle: (_, _) async => true,
        cleanupOrphanedImports: () async => calls.add('cleanup'),
        migrateCoverCache: (_) async => calls.add('covers'),
        ensureEntries: (_) async => calls.add('entries'),
        migrateAudioDetails: (_) async => calls.add('details'),
        backfillDurations: ({waitForIdle}) async {
          calls.add('durations');
          completed.complete();
        },
      );

      coordinator.schedule();
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
