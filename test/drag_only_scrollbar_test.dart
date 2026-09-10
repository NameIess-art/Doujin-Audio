import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
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
}
