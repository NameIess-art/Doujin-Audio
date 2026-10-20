import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';

void main() {
  const items = [
    DropdownMenuItem(value: 'a', child: Text('Alpha')),
    DropdownMenuItem(value: 'b', enabled: false, child: Text('Disabled')),
    DropdownMenuItem(value: 'c', child: Text('Charlie')),
  ];

  Widget harness(Widget child, {bool reduced = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  double menuOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('Charlie'),
              matching: find.byType(FadeTransition),
            )
            .first,
      )
      .opacity
      .value;

  for (final width in [190.0, 800.0]) {
    testWidgets(
      'dropdown uses the add menu style within a $width viewport',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 600);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          harness(
            SizedBox(
              width: 100,
              child: UnifiedDropdownButton<String>(
                value: 'a',
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: 'a',
                    child: Text('Alpha', textAlign: TextAlign.end),
                  ),
                  DropdownMenuItem(value: 'b', child: Text('Beta')),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.tap(find.text('Alpha'));
        await tester.pumpAndSettle();
        final menu = find.byType(SingleChildScrollView);
        final label = find.descendant(of: menu, matching: find.text('Alpha'));
        final row = find
            .ancestor(of: label, matching: find.byType(InkWell))
            .first;
        final menuRect = tester.getRect(menu);
        expect(menuRect.width, width < 236 ? width - 16 : 236);
        expect(menuRect.left, greaterThanOrEqualTo(8));
        expect(menuRect.right, lessThanOrEqualTo(width - 8));
        expect(tester.getSize(row).height, 48);
        expect(tester.widget<Text>(label).textAlign, TextAlign.start);
        final textStyle = DefaultTextStyle.of(tester.element(label)).style;
        expect(textStyle.fontWeight, FontWeight.w700);
        expect(
          textStyle.fontSize,
          Theme.of(tester.element(label)).textTheme.bodyMedium!.fontSize,
        );
        expect(tester.getTopLeft(label).dx, tester.getTopLeft(row).dx + 14);
        expect(
          find.descendant(of: menu, matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('dropdown fades for 300 ms and keyboard skips disabled options', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      harness(
        UnifiedDropdownButton<String>(
          value: 'a',
          items: items,
          onChanged: (value) => selected = value,
        ),
      ),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(menuOpacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 150));
    expect(menuOpacity(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(menuOpacity(tester), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, isNull);
    await tester.pump(const Duration(milliseconds: 150));
    expect(menuOpacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(selected, 'c');
    expect(find.text('Charlie'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dropdown honors multiline menu height and outside dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        UnifiedDropdownButton<int>(
          value: 0,
          items: List.generate(
            20,
            (index) => DropdownMenuItem(
              value: index,
              child: Text('Option $index\nSecond line'),
            ),
          ),
          onChanged: (_) {},
          multilineItems: true,
          menuMaxHeight: 160,
        ),
      ),
    );
    await tester.tap(find.text('Option 0\nSecond line'));
    await tester.pumpAndSettle();
    final scroll = find.byType(SingleChildScrollView);
    expect(tester.getSize(scroll).height, 160);
    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
    await tester.tapAt(const Offset(1, 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(scroll, findsOneWidget);
    await tester.pumpAndSettle();
    expect(scroll, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a long dropdown reveals its selected row', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      harness(
        UnifiedDropdownButton<int>(
          value: 18,
          items: List.generate(
            20,
            (index) =>
                DropdownMenuItem(value: index, child: Text('Choice $index')),
          ),
          menuMaxHeight: 160,
          onChanged: (value) => selected = value,
        ),
      ),
    );
    await tester.tap(find.text('Choice 18'));
    await tester.pumpAndSettle();
    final menu = find.byType(SingleChildScrollView);
    final selectedRow = find.descendant(
      of: menu,
      matching: find.text('Choice 18'),
    );
    final rowRect = tester.getRect(selectedRow);
    final menuRect = tester.getRect(menu);
    expect(rowRect.top, greaterThanOrEqualTo(menuRect.top));
    expect(rowRect.bottom, lessThanOrEqualTo(menuRect.bottom));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 18);
  });

  testWidgets('form field tracks changes, external values and reset', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    String? initial = 'a';
    late StateSetter update;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SizedBox(
              width: 240,
              child: Form(
                key: form,
                child: UnifiedDropdownButtonFormField<String>(
                  initialValue: initial,
                  items: items,
                  onChanged: (_) {},
                  decoration: const InputDecoration(labelText: 'Choice'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charlie'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UnifiedDropdownButton<String>>(
            find.byType(UnifiedDropdownButton<String>),
          )
          .value,
      'c',
    );
    form.currentState!.reset();
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    update(() => initial = null);
    await tester.pump();
    expect(
      tester
          .widget<UnifiedDropdownButton<String>>(
            find.byType(UnifiedDropdownButton<String>),
          )
          .value,
      isNull,
    );
  });

  testWidgets('reduced motion menu and Escape finish immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        UnifiedDropdownButton<String>(
          value: 'a',
          items: items,
          onChanged: (_) {},
        ),
        reduced: true,
      ),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(menuOpacity(tester), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Charlie'), findsNothing);
  });
}
