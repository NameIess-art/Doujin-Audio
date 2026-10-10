import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  Widget header({required int trailingButtons}) {
    return MaterialApp(
      home: Scaffold(
        body: TopPageHeader(
          topCapsuleTitle: 'Library',
          titleWidget: HeaderActionPill(
            children: List.generate(
              4,
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
      expect(tester.getSize(find.byKey(const ValueKey('action_0'))).width, 28);
      final lastAction = tester.getRect(find.byKey(const ValueKey('action_3')));
      final firstTrailing = tester.getRect(
        find.byType(HeaderFloatingButton).first,
      );
      expect(lastAction.right, lessThan(firstTrailing.left));

      await tester.binding.setSurfaceSize(const Size(510, 600));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey('action_0'))).width, 48);
    });
  }
}
