import 'package:doujin_audio/core/widgets/app_fixed_extent_wheel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'AppFixedExtentWheel supports keyboard navigation, tap selection, and multi-notch wheel on Windows',
    (tester) async {
      var selected = 5;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140,
                height: 160,
                child: StatefulBuilder(
                  builder: (context, setState) => AppFixedExtentWheel(
                    value: selected,
                    itemCount: 30,
                    labelAt: (index) => 'Item $index',
                    onChanged: (value) => setState(() => selected = value),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap a visible neighboring item to select and focus the wheel.
      await tester.tap(find.text('Item 6'));
      await tester.pumpAndSettle();
      expect(selected, 6);

      // Keyboard ArrowDown / ArrowUp / PageDown / PageUp.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected, 7);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(selected, 6);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(selected, 11);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(selected, 6);

      // Large wheel delta advances multiple items on Windows.
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(AppFixedExtentWheel)),
          scrollDelta: const Offset(0, 300),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, 9);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
