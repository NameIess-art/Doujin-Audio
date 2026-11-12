import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/core/widgets/windows_smooth_scroll_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  Future<ScrollController> pumpList(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    final controller = WindowsSmoothScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: SizedBox(
              width: 200,
              height: 400,
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
    return controller;
  }

  Future<void> wheel(WidgetTester tester, double delta) =>
      tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(100, 200),
          scrollDelta: Offset(0, delta),
        ),
      );

  testWidgets('independent scroll views get independent wheel motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: Row(
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('list'),
                children: const [SizedBox(height: 1600)],
              ).withWindowsSmoothScroll(),
            ),
            Expanded(
              child: const SingleChildScrollView(
                key: ValueKey('sheet'),
                child: SizedBox(height: 1600),
              ).withWindowsSmoothScroll(),
            ),
          ],
        ),
      ),
    );

    final list = find.byKey(const ValueKey('list'));
    final sheet = find.byKey(const ValueKey('sheet'));
    ScrollPosition positionOf(Finder finder) => tester
        .state<ScrollableState>(
          find.descendant(of: finder, matching: find.byType(Scrollable)),
        )
        .position;
    for (final (view, delta) in [(list, 80.0), (sheet, 120.0)]) {
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(view),
          scrollDelta: Offset(0, delta),
        ),
      );
    }
    expect(positionOf(list).pixels, 0);
    expect(positionOf(sheet).pixels, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    expect(positionOf(list).pixels, inExclusiveRange(0, 80));
    expect(positionOf(sheet).pixels, inExclusiveRange(0, 120));
    await tester.pumpAndSettle();
    expect(positionOf(list).pixels, 80);
    expect(positionOf(sheet).pixels, 120);
  }, variant: windows);

  testWidgets('Windows animates and accumulates fractional wheel deltas', (
    tester,
  ) async {
    final controller = await pumpList(tester);
    await wheel(tester, 80);
    expect(controller.offset, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(controller.offset, inExclusiveRange(0, 80));

    await wheel(tester, 0.25);
    await wheel(tester, 19.5);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(99.75, 0.001));
  }, variant: windows);

  testWidgets('one wheel step is still easing at 120 ms', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 80);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final offsetAt120ms = controller.offset;
    expect(offsetAt120ms, inExclusiveRange(0, 80));
    await tester.pump(const Duration(milliseconds: 40));
    final offsetAt160ms = controller.offset;
    expect(offsetAt160ms, inExclusiveRange(offsetAt120ms, 80));
    await tester.pump(const Duration(milliseconds: 40));
    expect(controller.offset, 80);
    expect(80 - offsetAt160ms, lessThan(offsetAt160ms - offsetAt120ms));
  }, variant: windows);

  testWidgets('wheel input on every frame keeps moving before input stops', (
    tester,
  ) async {
    final controller = await pumpList(tester);
    await wheel(tester, 10);
    await tester.pump(const Duration(microseconds: 16667));
    for (var frame = 1; frame < 12; frame++) {
      final previous = controller.offset;
      await wheel(tester, 10);
      await tester.pump(const Duration(microseconds: 16667));
      expect(controller.offset, greaterThan(previous));
    }
    await tester.pumpAndSettle();
    expect(controller.offset, 120);
  }, variant: windows);

  testWidgets(
    'reversing before the first frame cancels travel at either edge',
    (tester) async {
      final controller = await pumpList(tester);
      final end = controller.position.maxScrollExtent;
      for (final (offset, delta) in [(0.0, 80.0), (end, -80.0)]) {
        controller.jumpTo(offset);
        await tester.pump();
        await wheel(tester, delta);
        expect(controller.position.isScrollingNotifier.value, isTrue);
        await wheel(tester, -delta);
        expect(controller.position.isScrollingNotifier.value, isFalse);
        await tester.pumpAndSettle();
        expect(controller.offset, offset);
      }
    },
    variant: windows,
  );

  testWidgets(
    'rapid same-direction wheel steps carry over the current speed',
    (tester) async {
      final controller = await pumpList(tester);
      await wheel(tester, 80);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 46));
      final earlierOffset = controller.offset;
      const sample = Duration(milliseconds: 2);
      await tester.pump(sample);
      final offsetBeforeInput = controller.offset;
      final travelBeforeInput = offsetBeforeInput - earlierOffset;
      expect(travelBeforeInput, greaterThan(0));

      await wheel(tester, 80);
      await wheel(tester, 80);
      await tester.pump();
      await tester.pump(sample);
      final travelAfterInput = controller.offset - offsetBeforeInput;
      expect(
        travelAfterInput,
        closeTo(travelBeforeInput, travelBeforeInput * 0.2),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, 240);
    },
    variant: windows,
  );

  testWidgets('reversing drops old wheel travel and clamps at the bounds', (
    tester,
  ) async {
    final controller = await pumpList(tester);
    await wheel(tester, 160);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    final offsetAtReversal = controller.offset;
    expect(offsetAtReversal, inExclusiveRange(30, 160));

    await wheel(tester, -30);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.offset, lessThan(offsetAtReversal));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(offsetAtReversal - 30, 0.001));

    await wheel(tester, -200);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    final end = controller.position.maxScrollExtent;
    controller.jumpTo(end - 10);
    await wheel(tester, 100);
    await tester.pumpAndSettle();
    expect(controller.offset, end);
  }, variant: windows);

  testWidgets('starting a thumb drag interrupts the wheel animation', (
    tester,
  ) async {
    final controller = await pumpList(tester);
    await wheel(tester, 80);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    final pointer = await tester.startGesture(
      const Offset(196, 24),
      kind: PointerDeviceKind.mouse,
    );
    await pointer.moveBy(const Offset(0, 20));
    await pointer.moveBy(const Offset(0, 30));
    await tester.pump();
    final offsetDuringDrag = controller.offset;
    expect(offsetDuringDrag, greaterThan(80));
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.offset, offsetDuringDrag);
    await pointer.up();
    await tester.pumpAndSettle();
  }, variant: windows);

  testWidgets('touchpad pan can take over a wheel animation', (tester) async {
    final controller = await pumpList(tester);
    await wheel(tester, 80);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    const center = Offset(100, 200);
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomUpdate(center, pan: const Offset(0, -40));
    final offset = controller.offset;
    await gesture.panZoomUpdate(center, pan: const Offset(0, -70));
    expect(controller.offset, closeTo(offset + 30, 0.001));
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
  }, variant: windows);

  testWidgets(
    'Windows applies wheel deltas immediately with reduced motion',
    (tester) async {
      final controller = await pumpList(tester, disableAnimations: true);
      await wheel(tester, 80);
      expect(controller.offset, 80);
    },
    variant: windows,
  );

  testWidgets('Android retains the standard scroll position behavior', (
    tester,
  ) async {
    final controller = await pumpList(tester);
    await wheel(tester, 80);
    expect(controller.offset, 80);
  }, variant: android);
}
