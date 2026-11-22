import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/presentation/audio_ui_controllers.dart';

void main() {
  test('main screen controller can repeat the same scroll request', () async {
    final controller = MainScreenController();
    addTearDown(controller.dispose);
    final values = <int?>[];
    controller.scrollToTopTab.addListener(
      () => values.add(controller.scrollToTopTab.value),
    );

    controller.requestScrollToTop(2);
    await Future<void>.value();
    controller.requestScrollToTop(2);
    await Future<void>.value();

    expect(values, <int?>[2, null, 2, null]);
  });

  test(
    'main screen controller ignores pending microtasks and calls after dispose',
    () async {
      final controller = MainScreenController();
      controller.requestScrollToTop(1);
      controller.requestStopScroll(2);
      controller.dispose();

      // Flush both scheduled microtasks; neither may touch disposed notifiers.
      await Future<void>.delayed(Duration.zero);

      expect(() => controller.requestScrollToTop(3), returnsNormally);
      expect(() => controller.requestStopScroll(4), returnsNormally);
      expect(() => controller.dispose(), returnsNormally);
    },
  );

  test('playlist controller follows playback activation events', () async {
    final activations = StreamController<String>.broadcast();
    final controller = PlaylistUiController(activations.stream);
    addTearDown(() async {
      controller.dispose();
      await activations.close();
    });

    activations.add('session-2');
    await Future<void>.value();

    expect(controller.carouselSnap.value, 'session-2');
  });

  test('playlist controller repeats focus requests for the same session', () {
    final activations = StreamController<String>.broadcast();
    final controller = PlaylistUiController(activations.stream);
    addTearDown(() async {
      controller.dispose();
      await activations.close();
    });
    final values = <String?>[];
    controller.carouselSnap.addListener(
      () => values.add(controller.carouselSnap.value),
    );

    controller.requestCarouselSnap('session-2');
    controller.requestCarouselSnap('session-2');

    expect(values, <String?>['session-2', null, 'session-2']);
  });

  test('playlist controller releases its activation subscription', () async {
    final activations = StreamController<String>.broadcast();
    final controller = PlaylistUiController(activations.stream);
    var notifications = 0;
    controller.carouselSnap.addListener(() => notifications++);

    controller.dispose();
    activations.add('late-session');
    await Future<void>.value();
    await activations.close();

    expect(notifications, 0);
  });
}
