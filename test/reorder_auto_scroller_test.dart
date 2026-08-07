import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/reorder_auto_scroller.dart';

void main() {
  testWidgets('pointer in the content center does not start auto-scroll', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_buildScrollable(controller));

    final gesture = await tester.startGesture(const Offset(150, 200));
    await gesture.moveTo(const Offset(150, 201));
    await tester.pump(const Duration(milliseconds: 80));

    expect(controller.offset, 0);
    await gesture.up();
  });

  testWidgets(
    'pointer near the bottom edge auto-scrolls and stops on release',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_buildScrollable(controller));

      final gesture = await tester.startGesture(const Offset(150, 200));
      await gesture.moveTo(const Offset(150, 390));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final offsetWhileDragging = controller.offset;
      expect(offsetWhileDragging, greaterThan(0));

      await gesture.up();
      await tester.pump();
      final offsetAfterRelease = controller.offset;
      await tester.pump(const Duration(milliseconds: 120));

      expect(controller.offset, offsetAfterRelease);
    },
  );
}

Widget _buildScrollable(ScrollController controller) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 300,
        height: 400,
        child: ReorderAutoScroller(
          scrollController: controller,
          isDragging: true,
          contentMarginTop: 40,
          contentMarginBottom: 40,
          child: ListView.builder(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 40,
            itemExtent: 48,
            itemBuilder: (context, index) =>
                SizedBox(height: 48, child: Text('Item $index')),
          ),
        ),
      ),
    ),
  );
}
