import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/interaction_deferred_stream.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('listenable bridge emits latest value after interaction', () async {
    final interaction = UiInteractionCoordinator(
      idleDelay: const Duration(days: 1),
    );
    final source = ValueNotifier<int>(0);
    final values = <int>[];
    final subscription = interactionDeferredListenableStream(
      source: source,
      read: () => source.value,
      coordinator: interaction,
    ).listen(values.add);
    final interactionSource = Object();

    interaction.beginInteraction(interactionSource);
    source.value = 1;
    source.value = 2;
    interaction.beginGeneration();
    source.value = 3;

    expect(values, <int>[0]);

    interaction.cancelInteraction(interactionSource);
    interaction.flushPendingCommitsForTest();

    expect(values, <int>[0, 3]);
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
}
