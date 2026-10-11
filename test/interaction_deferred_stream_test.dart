import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/ui/interaction_deferred_stream.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final cancelPending in [false, true]) {
    test(
      'classified progress stays immediate and cannot bypass queued structure ($cancelPending)',
      () async {
        final interaction = UiInteractionCoordinator(
          idleDelay: Duration.zero,
          frameBudget: const Duration(seconds: 1),
        );
        final source =
            StreamController<({int revision, int progress})>.broadcast(
              sync: true,
            );
        final values = <({int revision, int progress})>[];
        final subscription = interactionDeferredValueStream(
          source.stream,
          coordinator: interaction,
          isStructuralUpdate: (previous, next) =>
              previous.revision != next.revision,
        ).listen(values.add);
        source.add((revision: 0, progress: 0));
        final motion = Object();
        interaction.beginInteraction(motion, deferVisualUpdates: true);
        source.add((revision: 0, progress: 1));
        expect(values.last, (revision: 0, progress: 1));
        expect(interaction.pendingCommitCount, 0);

        var earlierStructureCommitted = false;
        interaction.scheduleCommit(
          key: 'other-catalog',
          priority: 0,
          structural: true,
          commit: () => earlierStructureCommitted = true,
        );
        source.add((revision: 1, progress: 2));
        source.add((revision: 1, progress: 3));
        expect(values.last, (revision: 0, progress: 1));
        interaction.cancelInteraction(motion);
        interaction.flushPendingCommitsForTest();
        expect(earlierStructureCommitted, isTrue);
        expect(values.last, (revision: 0, progress: 1));
        source.add((revision: 1, progress: 4));
        expect(values.last, (revision: 0, progress: 1));
        if (cancelPending) await subscription.cancel();
        interaction.flushPendingCommitsForTest();
        expect(values, [
          (revision: 0, progress: 0),
          (revision: 0, progress: 1),
          if (!cancelPending) (revision: 1, progress: 4),
        ]);
        expect(interaction.pendingCommitCount, 0);

        if (!cancelPending) await subscription.cancel();
        await source.close();
        interaction.dispose();
      },
    );
  }

  for (final cancelPending in [false, true]) {
    test(
      'structural streams reuse initial data and spread idle updates across frames ($cancelPending)',
      () async {
        final interaction = UiInteractionCoordinator(
          idleDelay: Duration.zero,
          frameBudget: const Duration(seconds: 1),
        );
        final listenable = ValueNotifier<int>(0);
        final source = StreamController<int>.broadcast(sync: true);
        final listValues = <int>[];
        final streamValues = <int>[];
        var reads = 0;
        final listSubscription = interactionDeferredListenableStream(
          source: listenable,
          read: () {
            reads++;
            return listenable.value;
          },
          structural: true,
          coordinator: interaction,
        ).listen(listValues.add);
        final streamSubscription = interactionDeferredValueStream(
          source.stream,
          structural: true,
          coordinator: interaction,
        ).listen(streamValues.add);
        source.add(0);
        await Future<void>.delayed(Duration.zero);
        expect(listValues, [0]);
        expect(streamValues, [0]);

        listenable.value = 1;
        listenable.value = 2;
        source.add(1);
        source.add(2);
        expect(reads, 1);
        expect(listValues, [0]);
        expect(streamValues, [0]);
        interaction.flushPendingCommitsForTest();
        expect(reads, 2);
        expect(listValues, [0, 2]);
        expect(streamValues, [0]);
        if (cancelPending) await streamSubscription.cancel();
        interaction.flushPendingCommitsForTest();
        expect(streamValues, cancelPending ? [0] : [0, 2]);
        expect(interaction.pendingCommitCount, 0);

        await listSubscription.cancel();
        if (!cancelPending) await streamSubscription.cancel();
        await source.close();
        listenable.dispose();
        interaction.dispose();
      },
    );
  }

  test('initial listenable read waits until every interaction ends', () async {
    final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
    final source = ValueNotifier<int>(0);
    final values = <int>[];
    var reads = 0;
    final firstMotion = Object();
    final secondMotion = Object();
    interaction.beginInteraction(firstMotion);
    interaction.beginInteraction(secondMotion);
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () {
        reads++;
        return source.value;
      },
      coordinator: interaction,
      deferInitialRead: true,
    ).listen(values.add);
    await Future<void>.delayed(Duration.zero);
    source.value = 1;
    interaction.beginGeneration();
    source.value = 2;
    interaction.cancelInteraction(firstMotion);
    interaction.flushPendingCommitsForTest();
    expect(reads, 0);
    expect(values, isEmpty);

    interaction.cancelInteraction(secondMotion);
    interaction.flushPendingCommitsForTest();
    expect(reads, 1);
    expect(values, [2]);
    expect(interaction.pendingCommitCount, 0);
    await subscription.cancel();
    source.dispose();
    interaction.dispose();
  });

  test('cancellation discards a deferred initial read', () async {
    final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
    final source = ValueNotifier<int>(0);
    var reads = 0;
    final motion = Object();
    interaction.beginInteraction(motion);
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () {
        reads++;
        return source.value;
      },
      coordinator: interaction,
      deferInitialRead: true,
    ).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(interaction.pendingCommitCount, 1);
    await subscription.cancel();
    interaction.cancelInteraction(motion);
    interaction.flushPendingCommitsForTest();
    source.value = 1;
    expect(reads, 0);
    expect(interaction.pendingCommitCount, 0);
    source.dispose();
    interaction.dispose();
  });

  test(
    'initial read remains immediate by default during interaction',
    () async {
      final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
      final source = ValueNotifier<int>(7);
      final values = <int>[];
      final motion = Object();
      interaction.beginInteraction(motion);
      final subscription = interactionDeferredListenableStream(
        source: source,
        read: () => source.value,
        coordinator: interaction,
      ).listen(values.add);
      await Future<void>.delayed(Duration.zero);
      expect(values, [7]);
      expect(interaction.pendingCommitCount, 0);
      await subscription.cancel();
      interaction.cancelInteraction(motion);
      source.dispose();
      interaction.dispose();
    },
  );

  test('listenable bridge emits latest value after interaction', () async {
    final interaction = UiInteractionCoordinator(
      idleDelay: const Duration(days: 1),
    );
    final source = ValueNotifier<int>(0);
    final values = <int>[];
    var reads = 0;
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () {
        reads++;
        return source.value;
      },
      coordinator: interaction,
    ).listen(values.add);
    await Future<void>.delayed(Duration.zero);
    final interactionSource = Object();

    interaction.beginInteraction(interactionSource);
    source.value = 1;
    source.value = 2;
    interaction.beginGeneration();
    source.value = 3;

    expect(values, <int>[0]);
    expect(reads, 1);

    interaction.cancelInteraction(interactionSource);
    interaction.flushPendingCommitsForTest();

    expect(values, <int>[0, 3]);
    expect(reads, 2);
    await subscription.cancel();
    source.dispose();
    interaction.dispose();
  });

  test(
    'value stream emits its first event immediately and coalesces updates',
    () async {
      final interaction = UiInteractionCoordinator(
        idleDelay: const Duration(days: 1),
      );
      final source = StreamController<int>.broadcast(sync: true);
      final values = <int>[];
      final subscription = interactionDeferredValueStream(
        source.stream,
        coordinator: interaction,
      ).listen(values.add);
      final interactionSource = Object();

      interaction.beginInteraction(interactionSource);
      source.add(1);
      source.add(2);
      source.add(3);

      expect(values, <int>[1]);

      interaction.cancelInteraction(interactionSource);
      interaction.flushPendingCommitsForTest();

      expect(values, <int>[1, 3]);
      await subscription.cancel();
      await source.close();
      interaction.dispose();
    },
  );

  test('paused listenable reads only the latest value when resumed', () async {
    final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
    final source = ValueNotifier<int>(0);
    final values = <int>[];
    var reads = 0;
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () {
        reads++;
        return source.value;
      },
      coordinator: interaction,
    ).listen(values.add);
    await Future<void>.delayed(Duration.zero);

    subscription.pause();
    source.value = 1;
    source.value = 2;
    interaction.flushPendingCommitsForTest();
    expect(reads, 1);
    expect(values, [0]);
    expect(interaction.pendingCommitCount, 0);

    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 2);
    expect(values, [0, 2]);
    subscription.pause();
    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 2);
    expect(values, [0, 2]);
    await subscription.cancel();
    source.dispose();
    interaction.dispose();
  });

  test('pausing removes a commit and resuming still waits for idle', () async {
    final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
    final source = ValueNotifier<int>(0);
    final values = <int>[];
    var reads = 0;
    final motion = Object();
    interaction.beginInteraction(motion);
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () {
        reads++;
        return source.value;
      },
      coordinator: interaction,
      deferInitialRead: true,
    ).listen(values.add);
    await Future<void>.delayed(Duration.zero);
    expect(interaction.pendingCommitCount, 1);

    subscription.pause();
    expect(interaction.pendingCommitCount, 0);
    source.value = 1;
    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(interaction.pendingCommitCount, 1);
    expect(reads, 0);
    subscription.pause();
    interaction.cancelInteraction(motion);
    interaction.flushPendingCommitsForTest();
    expect(reads, 0);
    source.value = 2;
    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(values, [2]);
    await subscription.cancel();
    source.dispose();
    interaction.dispose();
  });

  test('pausing one listenable subscriber leaves the other active', () async {
    final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
    final source = ValueNotifier<int>(0);
    final stream = interactionDeferredListenableStream(
      source: source,
      read: () => source.value,
      coordinator: interaction,
    );
    final pausedValues = <int>[];
    final activeValues = <int>[];
    final paused = stream.listen(pausedValues.add);
    final active = stream.listen(activeValues.add);
    await Future<void>.delayed(Duration.zero);
    paused.pause();
    source.value = 1;
    source.value = 2;
    expect(pausedValues, [0]);
    expect(activeValues, [0, 1, 2]);
    paused.resume();
    await Future<void>.delayed(Duration.zero);
    expect(pausedValues, [0, 2]);
    await paused.cancel();
    await active.cancel();
    source.dispose();
    interaction.dispose();
  });

  test('cancelling a paused listenable discards its dirty value', () async {
    final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
    final source = ValueNotifier<int>(0);
    var reads = 0;
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () {
        reads++;
        return source.value;
      },
      coordinator: interaction,
    ).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    subscription.pause();
    source.value = 1;
    await subscription.cancel();
    source.value = 2;
    interaction.flushPendingCommitsForTest();
    expect(reads, 1);
    expect(interaction.pendingCommitCount, 0);
    source.dispose();
    interaction.dispose();
  });
  test(
    'value stream preserves its deferred final event before closing',
    () async {
      final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
      final source = StreamController<int>.broadcast(sync: true);
      final values = <int>[];
      var done = false;
      final subscription = interactionDeferredValueStream(
        source.stream,
        coordinator: interaction,
      ).listen(values.add, onDone: () => done = true);
      final interactionSource = Object();
      interaction.beginInteraction(interactionSource);
      source.add(1);
      source.add(2);
      await source.close();
      expect(values, [1]);
      expect(done, isFalse);
      interaction.cancelInteraction(interactionSource);
      interaction.flushPendingCommitsForTest();
      await Future<void>.delayed(Duration.zero);
      expect(values, [1, 2]);
      expect(done, isTrue);
      await subscription.cancel();
      interaction.dispose();
    },
  );

  test(
    'value stream gives a returning listener its first event during motion',
    () async {
      final interaction = UiInteractionCoordinator(idleDelay: Duration.zero);
      final source = StreamController<int>.broadcast(sync: true);
      final stream = interactionDeferredValueStream(
        source.stream,
        coordinator: interaction,
      );
      final first = stream.listen((_) {});
      source.add(1);
      await first.cancel();
      final interactionSource = Object();
      interaction.beginInteraction(interactionSource);
      final values = <int>[];
      final returning = stream.listen(values.add);
      source.add(2);
      expect(values, [2]);
      expect(interaction.pendingCommitCount, 0);
      await returning.cancel();
      await source.close();
      interaction.dispose();
    },
  );
  test(
    'cancelling a listenable subscription discards its deferred value',
    () async {
      final interaction = UiInteractionCoordinator(
        idleDelay: const Duration(days: 1),
      );
      final source = ValueNotifier<int>(0);
      var reads = 0;
      final stream = interactionDeferredListenableStream(
        source: source,
        read: () {
          reads++;
          return source.value;
        },
        coordinator: interaction,
      );
      final values = <int>[];
      final subscription = stream.listen(values.add);
      await Future<void>.delayed(Duration.zero);
      final interactionSource = Object();
      interaction.beginInteraction(interactionSource);
      source.value = 1;
      await subscription.cancel();
      final readsAtCancellation = reads;
      interaction.cancelInteraction(interactionSource);
      interaction.flushPendingCommitsForTest();
      expect(values, [0]);

      source.value = 2;
      expect(reads, readsAtCancellation);
      final resumedValues = <int>[];
      final resumed = stream.listen(resumedValues.add);
      await Future<void>.delayed(Duration.zero);
      expect(resumedValues, [2]);
      await resumed.cancel();
      source.dispose();
      interaction.dispose();
    },
  );
}
