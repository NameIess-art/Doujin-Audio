import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/ui/warmup_scheduler.dart';

void main() {
  test('deduplicates queued work by key within a generation', () {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.beginGeneration(1);

    final acceptedFirst = scheduler.schedule(
      key: 'cover:a',
      priority: 0,
      generation: 1,
      task: () async {},
    );
    final acceptedDuplicate = scheduler.schedule(
      key: 'cover:a',
      priority: 1,
      generation: 1,
      task: () async {},
    );

    expect(acceptedFirst, isTrue);
    expect(acceptedDuplicate, isFalse);
  });

  test(
    'limits concurrent work and starts queued task after completion',
    () async {
      final scheduler = WarmupScheduler(maxQueueSize: 4);
      scheduler.beginGeneration(2);

      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var secondRan = false;

      scheduler.schedule(
        key: 'first',
        priority: 0,
        generation: 2,
        task: () async {
          firstStarted.complete();
          await releaseFirst.future;
        },
      );
      scheduler.schedule(
        key: 'second',
        priority: 1,
        generation: 2,
        task: () async {
          secondRan = true;
        },
      );

      await firstStarted.future;
      expect(scheduler.activeCount, 1);
      expect(scheduler.pendingCount, 1);
      expect(secondRan, isFalse);

      releaseFirst.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(secondRan, isTrue);
      expect(scheduler.activeCount, 0);
      expect(scheduler.pendingCount, 0);
    },
  );

  test('drops stale queued work when generation advances', () async {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.beginGeneration(3);

    final releaseFirst = Completer<void>();
    var staleRan = false;

    scheduler.schedule(
      key: 'active',
      priority: 0,
      generation: 3,
      task: () async {
        await releaseFirst.future;
      },
    );
    scheduler.schedule(
      key: 'stale',
      priority: 1,
      generation: 3,
      task: () async {
        staleRan = true;
      },
    );

    scheduler.beginGeneration(4);
    releaseFirst.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(staleRan, isFalse);
    expect(scheduler.pendingCount, 0);
  });

  test('clears queued work by group without touching active work', () async {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.beginGeneration(5);

    final releaseActive = Completer<void>();
    var droppedRan = false;
    var keptRan = false;

    scheduler.schedule(
      key: 'active',
      priority: 0,
      generation: 5,
      group: 'session_cover',
      task: () async {
        await releaseActive.future;
      },
    );
    scheduler.schedule(
      key: 'drop',
      priority: 1,
      generation: 5,
      group: 'library_cover',
      task: () async {
        droppedRan = true;
      },
    );
    scheduler.schedule(
      key: 'keep',
      priority: 2,
      generation: 5,
      group: 'subtitle',
      task: () async {
        keptRan = true;
      },
    );

    scheduler.clearGroup('library_cover');
    expect(scheduler.pendingCount, 1);

    releaseActive.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(droppedRan, isFalse);
    expect(keptRan, isTrue);
  });

  test('defers queued work during generation cooldown', () async {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.beginGeneration(6, cooldown: const Duration(milliseconds: 20));

    var ran = false;
    scheduler.schedule(
      key: 'deferred',
      priority: 0,
      generation: 6,
      task: () async {
        ran = true;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(ran, isFalse);
    expect(scheduler.pendingCount, 1);

    await Future<void>.delayed(const Duration(milliseconds: 25));
    await Future<void>.delayed(Duration.zero);

    expect(ran, isTrue);
    expect(scheduler.pendingCount, 0);
  });

  test('new generation cancels previous cooldown timer', () async {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.beginGeneration(7, cooldown: const Duration(milliseconds: 40));

    var staleRan = false;
    scheduler.schedule(
      key: 'stale-cooldown',
      priority: 0,
      generation: 7,
      task: () async {
        staleRan = true;
      },
    );

    scheduler.beginGeneration(8);
    var freshRan = false;
    scheduler.schedule(
      key: 'fresh',
      priority: 0,
      generation: 8,
      task: () async {
        freshRan = true;
      },
    );

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(staleRan, isFalse);
    expect(freshRan, isTrue);
  });

  test('paused scheduler keeps queued work until resumed', () async {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.setPaused(true);
    scheduler.beginGeneration(9);
    var ran = false;

    scheduler.schedule(
      key: 'paused',
      priority: 0,
      generation: 9,
      task: () async {
        ran = true;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(ran, isFalse);
    expect(scheduler.pendingCount, 1);

    scheduler.setPaused(false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(ran, isTrue);
    expect(scheduler.pendingCount, 0);
  });

  test('shutdown drops queued work and waits for active work', () async {
    final scheduler = WarmupScheduler(maxQueueSize: 4);
    scheduler.beginGeneration(10);
    final activeStarted = Completer<void>();
    final releaseActive = Completer<void>();
    var queuedRan = false;

    scheduler.schedule(
      key: 'active',
      priority: 0,
      generation: 10,
      task: () async {
        activeStarted.complete();
        await releaseActive.future;
      },
    );
    scheduler.schedule(
      key: 'queued',
      priority: 1,
      generation: 10,
      task: () async {
        queuedRan = true;
      },
    );

    await activeStarted.future;
    var shutdownCompleted = false;
    final shutdown = scheduler.shutdown().then((_) {
      shutdownCompleted = true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(shutdownCompleted, isFalse);
    expect(scheduler.pendingCount, 0);
    expect(
      scheduler.schedule(
        key: 'rejected',
        priority: 0,
        generation: 10,
        task: () async {},
      ),
      isFalse,
    );

    releaseActive.complete();
    await shutdown;

    expect(queuedRan, isFalse);
    expect(scheduler.isIdle, isTrue);
  });
}
