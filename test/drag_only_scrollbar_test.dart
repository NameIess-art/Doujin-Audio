import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/page_header_inset.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'track clicks do not scroll, thumb dragging and wheel still work',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 400,
              child: ScrollConfiguration(
                behavior: const MaterialScrollBehavior().copyWith(
                  scrollbars: false,
                ),
                child: DragOnlyScrollbar(
                  controller: controller,
                  child: ListView.builder(
                    controller: controller,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, index) => Text('Item $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byType(DragOnlyScrollbar));
      Future<void> click(Offset offset) async {
        final pointer = await tester.startGesture(
          origin + offset,
          kind: PointerDeviceKind.mouse,
        );
        await pointer.up();
        await tester.pumpAndSettle();
      }

      await click(const Offset(196, 300));
      expect(controller.offset, 0);
      await click(const Offset(196, 20));
      expect(controller.offset, 0);

      final drag = await tester.startGesture(
        origin + const Offset(196, 20),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 140));
      await drag.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      final afterDrag = controller.offset;
      await click(const Offset(196, 380));
      await click(const Offset(196, 5));
      expect(controller.offset, afterDrag);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: origin + const Offset(100, 200),
          scrollDelta: const Offset(0, 80),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(afterDrag));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Android vertical list builds DragOnlyScrollbar and supports touch drag',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 400,
              child: DragOnlyScrollbar(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  itemExtent: 40,
                  itemCount: 100,
                  itemBuilder: (_, index) => Text('Item $index'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DragOnlyScrollbar), findsOneWidget);

      final origin = tester.getTopLeft(find.byType(DragOnlyScrollbar));
      final drag = await tester.startGesture(
        origin + const Offset(196, 20),
      );
      await drag.moveBy(const Offset(0, 140));
      await drag.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'PageHeaderInset shifts scrollbar track below header',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: PageHeaderInset(
              topInset: 100,
              child: SizedBox(
                width: 200,
                height: 400,
                child: DragOnlyScrollbar(
                  controller: controller,
                  child: ListView.builder(
                    controller: controller,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, index) => Text('Item $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DragOnlyScrollbar), findsOneWidget);

      final origin = tester.getTopLeft(find.byType(DragOnlyScrollbar));
      // Dragging inside the header area (y = 20 < 100) must NOT hit the scrollbar thumb
      final dragHeader = await tester.startGesture(
        origin + const Offset(196, 20),
      );
      await dragHeader.moveBy(const Offset(0, 50));
      await dragHeader.up();
      await tester.pumpAndSettle();
      expect(controller.offset, 0);

      // Dragging below the header area (y = 110, where thumb starts) drags the scrollbar
      final dragThumb = await tester.startGesture(
        origin + const Offset(196, 110),
      );
      await dragThumb.moveBy(const Offset(0, 100));
      await dragThumb.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('MaxScrollVelocityPhysics clamps maxFlingVelocity and carriedMomentum', () {
    const physics = MaxScrollVelocityPhysics();
    expect(physics.maxFlingVelocity, MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity);
    expect(physics.carriedMomentum(50000.0), 0.0);

    const bouncingPhysics = MaxScrollVelocityPhysics(
      parent: BouncingScrollPhysics(),
    );
    expect(bouncingPhysics.carriedMomentum(50000.0), MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity);
    expect(bouncingPhysics.carriedMomentum(-50000.0), -MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity);

    const customPhysics = MaxScrollVelocityPhysics(
      maxVelocity: 2500.0,
      parent: BouncingScrollPhysics(),
    );
    expect(customPhysics.maxFlingVelocity, 2500.0);
    expect(customPhysics.carriedMomentum(5000.0), 2500.0);

    final applied = customPhysics.applyTo(const AlwaysScrollableScrollPhysics());
    expect(applied, isA<MaxScrollVelocityPhysics>());
    expect(applied.maxVelocity, 2500.0);
  });

  test('MaxScrollVelocityPhysics clamps ballistic simulation velocity on vertical axis only', () {
    const physics = MaxScrollVelocityPhysics(
      maxVelocity: 2000.0,
      parent: ClampingScrollPhysics(),
    );

    final verticalMetrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 100,
      viewportDimension: 500,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1.0,
    );

    final verticalSimulation = physics.createBallisticSimulation(verticalMetrics, 8000.0);
    expect(verticalSimulation, isNotNull);
    expect(verticalSimulation!.dx(0), closeTo(2000.0, 0.001));

    final verticalNegSimulation = physics.createBallisticSimulation(verticalMetrics, -8000.0);
    expect(verticalNegSimulation, isNotNull);
    expect(verticalNegSimulation!.dx(0), closeTo(-2000.0, 0.001));

    final horizontalMetrics = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 100,
      viewportDimension: 500,
      axisDirection: AxisDirection.right,
      devicePixelRatio: 1.0,
    );

    final horizontalSimulation = physics.createBallisticSimulation(horizontalMetrics, 8000.0);
    expect(horizontalSimulation, isNotNull);
    expect(horizontalSimulation!.dx(0), closeTo(8000.0, 0.001));
  });

  testWidgets('AppScrollBehavior configures MaxScrollVelocityPhysics by default and on copyWith', (tester) async {
    const behavior = AppScrollBehavior();
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: behavior,
        home: Builder(
          builder: (context) {
            final physics = ScrollConfiguration.of(context).getScrollPhysics(context);
            expect(physics, isA<MaxScrollVelocityPhysics>());
            expect(physics.maxFlingVelocity, MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity);

            final copied = behavior.copyWith(
              physics: const ClampingScrollPhysics(),
            );
            final copiedPhysics = copied.getScrollPhysics(context);
            expect(copiedPhysics, isA<MaxScrollVelocityPhysics>());
            expect(copiedPhysics.maxFlingVelocity, MaxScrollVelocityPhysics.kDefaultMaxScrollVelocity);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  });

  testWidgets('vertical list view flings within maximum velocity cap', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(maxVelocity: 1500.0).copyWith(
          scrollbars: true,
          physics: AppScrollBehavior.defaultScrollPhysics,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 600,
            child: ListView.builder(
              controller: controller,
              itemExtent: 50,
              itemCount: 500,
              itemBuilder: (_, index) => Text('Item $index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byType(ListView),
      const Offset(0, -300),
      3000.0,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final offsetAfter100ms = controller.offset;
    expect(offsetAfter100ms, greaterThan(300.0));
    expect(offsetAfter100ms, lessThan(460.0));
    await tester.pumpAndSettle();
  });
}
