import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  for (final unmount in [false, true]) {
    testWidgets(
      'scroll protection releases on ${unmount ? 'unmount' : 'hide'}',
      (tester) async {
        const childKey = ValueKey('scroll-child');
        Widget shell({bool enabled = true}) => TickerMode(
          enabled: enabled,
          child: const ScrollActivityGate(child: SizedBox(key: childKey)),
        );
        await tester.pumpWidget(shell());
        void startScroll() => ScrollStartNotification(
          metrics: FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 100,
            pixels: 0,
            viewportDimension: 100,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 1,
          ),
          context: tester.element(find.byKey(childKey)),
        ).dispatch(tester.element(find.byKey(childKey)));

        startScroll();
        expect(interaction.isInteracting, isTrue);
        var commits = 0;
        interaction.scheduleCommit(
          key: 'scroll-result',
          commit: () => commits++,
        );
        await tester.pump();
        expect(commits, 0);
        final overlappingSource = Object();
        interaction.beginInteraction(overlappingSource);
        await tester.pumpWidget(
          unmount ? const SizedBox() : shell(enabled: false),
        );
        interaction.cancelInteraction(overlappingSource);
        expect(interaction.isInteracting, isFalse);
        await tester.pump();
        expect(commits, 1);

        if (!unmount) {
          startScroll();
          expect(interaction.isInteracting, isFalse);
          await tester.pumpWidget(shell());
          startScroll();
          expect(interaction.isInteracting, isTrue);
          await tester.pumpWidget(const SizedBox());
          expect(interaction.isInteracting, isFalse);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(commits, 1);
      },
    );
  }
}
