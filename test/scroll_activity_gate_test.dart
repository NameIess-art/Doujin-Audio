import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  testWidgets(
    'layout scroll notifications defer UI updates until after the frame',
    (tester) async {
      final notificationPhases = <SchedulerPhase>[];
      final observedScrolling = <bool>[];
      ValueNotifier<bool>? scrollingNotifier;
      void recordNotification() =>
          notificationPhases.add(SchedulerBinding.instance.schedulerPhase);
      var interactionStartedDuringLayout = false;
      var notifiedDuringLayout = false;
      var clicks = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: LayoutBuilder(
            builder: (context, constraints) => ScrollActivityGate(
              child: Builder(
                builder: (context) {
                  observedScrolling.add(
                    ScrollActivityGate.isScrollingOf(context),
                  );
                  if (scrollingNotifier == null) {
                    context.visitAncestorElements((element) {
                      final widget = element.widget;
                      if (widget is InheritedNotifier<ValueNotifier<bool>>) {
                        scrollingNotifier = widget.notifier;
                        scrollingNotifier!.addListener(recordNotification);
                        return false;
                      }
                      return true;
                    });
                  }
                  return _NotifyScrollDuringLayout(
                    onLayout: () {
                      expect(
                        SchedulerBinding.instance.schedulerPhase,
                        SchedulerPhase.persistentCallbacks,
                      );
                      ScrollStartNotification(
                        metrics: FixedScrollMetrics(
                          minScrollExtent: 0,
                          maxScrollExtent: 100,
                          pixels: 110,
                          viewportDimension: 100,
                          axisDirection: AxisDirection.down,
                          devicePixelRatio: 1,
                        ),
                        context: context,
                      ).dispatch(context);
                      interactionStartedDuringLayout =
                          interaction.isInteracting;
                      notifiedDuringLayout = notificationPhases.isNotEmpty;
                    },
                    child: StatefulBuilder(
                      builder: (context, setState) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => clicks++),
                        child: Center(child: Text('clicks $clicks')),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(interactionStartedDuringLayout, isTrue);
      expect(notifiedDuringLayout, isFalse);
      expect(notificationPhases, [SchedulerPhase.postFrameCallbacks]);
      expect(observedScrolling, [false]);
      await tester.pump();
      expect(observedScrolling, [false, true]);
      await tester.tap(find.text('clicks 0'));
      await tester.pump();
      expect(find.text('clicks 1'), findsOneWidget);
      expect(clicks, 1);
      expect(tester.takeException(), isNull);
      scrollingNotifier!.removeListener(recordNotification);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'held drag keeps background work paused until scrolling ends',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ScrollActivityGate(
            child: ListView.builder(
              controller: controller,
              itemExtent: 80,
              itemCount: 100,
              itemBuilder: (_, index) => Text('item $index'),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      var commits = 0;
      interaction.scheduleCommit(key: 'held-drag', commit: () => commits++);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.position.isScrollingNotifier.value, isTrue);
      expect(interaction.isInteracting, isTrue);
      expect(commits, 0);
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(commits, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(interaction.isInteracting, isFalse);
      expect(commits, 1);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

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

class _NotifyScrollDuringLayout extends SingleChildRenderObjectWidget {
  const _NotifyScrollDuringLayout({
    required this.onLayout,
    required super.child,
  });

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNotifyScrollDuringLayout(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNotifyScrollDuringLayout renderObject,
  ) {
    renderObject.onLayout = onLayout;
  }
}

class _RenderNotifyScrollDuringLayout extends RenderProxyBox {
  _RenderNotifyScrollDuringLayout(this.onLayout);

  VoidCallback onLayout;
  bool _notified = false;

  @override
  void performLayout() {
    super.performLayout();
    if (_notified) return;
    _notified = true;
    onLayout();
  }
}
