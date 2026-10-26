import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/playing_sound_wave_indicator.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets(
    'playing wave stops ticking during scroll and respects playback on resume',
    (tester) async {
      var playing = true;
      var visible = true;
      var reducedMotion = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQueryData(disableAnimations: reducedMotion),
                child: TickerMode(
                  enabled: visible,
                  child: ScrollActivityGate(
                    child: Center(
                      child: PlayingSoundWaveIndicator(isPlaying: playing),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, 1);
      final element = tester.element(find.byType(PlayingSoundWaveIndicator));
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 100,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      void start() => ScrollStartNotification(
        metrics: metrics,
        context: element,
      ).dispatch(element);
      Future<void> end() async {
        ScrollEndNotification(
          metrics: metrics,
          context: element,
        ).dispatch(element);
        await tester.pump(const Duration(milliseconds: 200));
      }

      start();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.binding.transientCallbackCount, 0);
      await end();
      expect(tester.binding.transientCallbackCount, 1);

      start();
      update(() => playing = false);
      await tester.pump();
      await end();
      expect(tester.binding.transientCallbackCount, 0);
      update(() => playing = true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 1);

      update(() => reducedMotion = true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      update(() {
        reducedMotion = false;
        visible = false;
      });
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      update(() => visible = true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
