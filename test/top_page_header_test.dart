import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('header safe area and margins block input behind its controls', (
    tester,
  ) async {
    var bodyTaps = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(top: 24),
          ),
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => bodyTaps++,
                  child: const SizedBox.expand(),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: TopPageHeader(
                    title: 'Title',
                    leading: IconButton(
                      key: const ValueKey('header-back'),
                      onPressed: () => buttonTaps++,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(TopPageHeader));
    for (final point in [
      const Offset(4, 8),
      Offset(rect.right - 2, rect.center.dy),
      Offset(rect.center.dx, rect.bottom - 1),
    ]) {
      await tester.tapAt(point);
    }
    expect(bodyTaps, 0);
    await tester.tap(find.byKey(const ValueKey('header-back')));
    expect(buttonTaps, 1);
    await tester.tapAt(Offset(rect.center.dx, rect.bottom + 10));
    expect(bodyTaps, 1);
  });

  testWidgets(
    'scrolling rebuilds only changing header geometry',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      const additionalChild = SizedBox(key: ValueKey('header-extra'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ListView.builder(
                  controller: controller,
                  itemExtent: 80,
                  itemCount: 100,
                  itemBuilder: (_, index) => Text('item $index'),
                ),
                TopPageHeader(
                  topCapsuleTitle: 'Library',
                  title: 'Actions',
                  collapseController: controller,
                  floatingReveal: true,
                  additionalChild: additionalChild,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final expandedHeight = tester.getSize(find.byType(TopPageHeader)).height;
      final geometryElement = tester.element(
        find.byWidgetPredicate(
          (widget) =>
              widget is AnimatedBuilder && widget.child == additionalChild,
        ),
      );
      var geometryBuilds = 0;
      var capsuleBuilds = 0;
      final previousCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousCallback?.call(element, builtOnce);
        if (element == geometryElement) geometryBuilds++;
        if (element.widget is HeaderTopCapsule) capsuleBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousCallback);

      for (var offset = 8.0; offset <= 80; offset += 8) {
        controller.jumpTo(offset);
        await tester.pump();
      }
      expect(geometryBuilds, greaterThan(0));
      expect(capsuleBuilds, 0);
      final collapsedHeight = tester.getSize(find.byType(TopPageHeader)).height;
      expect(collapsedHeight, lessThan(expandedHeight));

      geometryBuilds = 0;
      for (var offset = 100.0; offset <= 500; offset += 20) {
        controller.jumpTo(offset);
        await tester.pump();
      }
      expect(geometryBuilds, 0);
      expect(
        tester.getSize(find.byType(TopPageHeader)).height,
        collapsedHeight,
      );

      // Reversing first crosses the reveal threshold, then expands the header.
      controller.jumpTo(380);
      await tester.pump();
      expect(geometryBuilds, 0);
      controller.jumpTo(310);
      await tester.pump();
      expect(tester.getSize(find.byType(TopPageHeader)).height, expandedHeight);
      expect(capsuleBuilds, 0);
      controller.jumpTo(0);
      await tester.pump();
      expect(tester.getSize(find.byType(TopPageHeader)).height, expandedHeight);
      await tester.pumpWidget(const SizedBox());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  Widget header({required int trailingButtons, int actionButtons = 4}) {
    return MaterialApp(
      home: Scaffold(
        body: TopPageHeader(
          topCapsuleTitle: 'Library',
          titleWidget: HeaderActionPill(
            children: List.generate(
              actionButtons,
              (index) => IconButton(
                key: ValueKey('action_$index'),
                onPressed: () {},
                icon: const Icon(Icons.add),
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: HeaderActionPill.buttonConstraints,
              ),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < trailingButtons; index++) ...[
                if (index != 0) const SizedBox(width: 8),
                HeaderFloatingButton(
                  child: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.search),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('portrait action pill keeps original button spacing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(header(trailingButtons: 2));

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const ValueKey('action_0'))).width, 48);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('action_1'))).dx -
          tester.getTopLeft(find.byKey(const ValueKey('action_0'))).dx,
      48,
    );
  });

  for (final width in [320.0, 349.0]) {
    testWidgets('action pill fits $width wide content and restores spacing', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(header(trailingButtons: 3));

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('action_0'))).width,
        inExclusiveRange(28, 48),
      );
      final lastAction = tester.getRect(find.byKey(const ValueKey('action_3')));
      final firstTrailing = tester.getRect(
        find.byType(HeaderFloatingButton).first,
      );
      expect(lastAction.right, lessThan(firstTrailing.left));
      expect(firstTrailing.left - lastAction.right, closeTo(12, 0.01));

      await tester.binding.setSurfaceSize(const Size(510, 600));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey('action_0'))).width, 48);
    });
  }

  testWidgets(
    'split library action pill uses the space before trailing buttons',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(349.5, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(header(trailingButtons: 4, actionButtons: 3));

      expect(tester.takeException(), isNull);
      final first = tester.getRect(find.byKey(const ValueKey('action_0')));
      final second = tester.getRect(find.byKey(const ValueKey('action_1')));
      final last = tester.getRect(find.byKey(const ValueKey('action_2')));
      final trailing = tester.getRect(find.byType(HeaderFloatingButton).first);
      expect(first.width, inExclusiveRange(28, 48));
      expect(second.width, closeTo(first.width, 0.01));
      expect(last.width, closeTo(first.width, 0.01));
      expect(second.left - first.left, closeTo(first.width, 0.01));
      expect(trailing.left - last.right, closeTo(12, 0.01));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
