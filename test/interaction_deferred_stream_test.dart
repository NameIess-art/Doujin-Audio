import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/ui/interaction_deferred_stream.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
