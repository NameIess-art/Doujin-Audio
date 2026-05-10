import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/services/warmup_scheduler.dart';

void main() {
  test('deduplicates queued work by key within a generation', () {
    final scheduler = WarmupScheduler(maxConcurrent: 1, maxQueueSize: 4);
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
      final scheduler = WarmupScheduler(maxConcurrent: 1, maxQueueSize: 4);
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
    final scheduler = WarmupScheduler(maxConcurrent: 1, maxQueueSize: 4);
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
}
