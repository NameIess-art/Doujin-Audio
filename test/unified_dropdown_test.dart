import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/core/widgets/app_dialog.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const items = [
    DropdownMenuItem(value: 'a', child: Text('Alpha')),
    DropdownMenuItem(value: 'b', enabled: false, child: Text('Disabled')),
    DropdownMenuItem(value: 'c', child: Text('Charlie')),
  ];

  Widget harness(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('Windows dropdown clears its blur as the menu fades', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Center(
            child: UnifiedDropdownButton<String>(
              value: 'a',
              items: items,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    final background = find.byType(AppModalBackground);
    final blur = find.descendant(
      of: background,
      matching: find.byType(BackdropFilter),
    );
    expect(blur, findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 76));
    expect(background, findsOneWidget);
    expect(blur, findsNothing);
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(of: background, matching: find.byType(ColoredBox)),
          )
          .color
          .a,
      0,
    );
    await tester.pumpAndSettle();
    expect(background, findsNothing);
  });

  testWidgets(
    'dropdown restores v0.29 Material styling and selection',
    (tester) async {
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
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(dropdown.borderRadius, AppRadius.borderMedium);
      expect(
        dropdown.dropdownColor,
        Theme.of(
          tester.element(find.text('Alpha').first),
        ).colorScheme.surfaceContainerHigh,
      );
      expect(dropdown.alignment, AlignmentDirectional.centerStart);
      expect(dropdown.itemHeight, kMinInteractiveDimension);
      final button = find.byType(DropdownButton<String>);
      final bounds = tester.getRect(button);
      expect(bounds.height, greaterThanOrEqualTo(44));
      await tester.tapAt(Offset(bounds.center.dx, bounds.top + 2));
      await tester.pumpAndSettle();
      expect(find.text('Charlie'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Charlie'), findsNothing);
      final trigger = find.descendant(
        of: button,
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(trigger).focusColor, Colors.transparent);
      expect(selected, isNull);

      await tester.tapAt(Offset(bounds.center.dx, bounds.bottom - 2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disabled').last);
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.text('Charlie').last);
      await tester.pumpAndSettle();
      expect(selected, 'c');
      expect(tester.widget<InkWell>(trigger).focusNode!.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('dropdown preserves option typography and aligns options left', (
    tester,
  ) async {
    const style = TextStyle(fontWeight: FontWeight.w700, fontSize: 18);
    await tester.pumpWidget(
      harness(
        UnifiedDropdownButton<String>(
          value: 'a',
          items: const [
            DropdownMenuItem(
              value: 'a',
              child: Text('Alpha', style: style),
            ),
            DropdownMenuItem(
              value: 'c',
              child: Text('Charlie', style: style),
            ),
          ],
          onChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    final label = find.text('Charlie').last;
    expect(tester.widget<Text>(label).style, style);
    final entry = tester.widget<DropdownMenuItem<String>>(
      find.ancestor(of: label, matching: find.byType(DropdownMenuItem<String>)),
    );
    expect(entry.alignment, AlignmentDirectional.centerStart);
    expect(
      tester.getRect(label).left,
      tester.getRect(find.text('Alpha').last).left,
    );
    expect(find.byIcon(Icons.check), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final alignment in [
    AlignmentDirectional.centerStart,
    Alignment.centerRight,
  ]) {
    testWidgets(
      'selected label stays in place when opened ($alignment)',
      (tester) async {
        final label = alignment == Alignment.centerRight
            ? 'Selected'
            : 'Selected dropdown option';
        await tester.pumpWidget(
          harness(
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 180,
                child: UnifiedDropdownButton<String>(
                  value: 'selected',
                  items: [
                    const DropdownMenuItem(value: 'a', child: Text('Alpha')),
                    DropdownMenuItem(value: 'selected', child: Text(label)),
                    const DropdownMenuItem(
                      value: 'c',
                      child: Text('Longer option to wrap'),
                    ),
                  ],
                  alignment: alignment,
                  multilineItems: true,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        );
        final closed = tester.getRect(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        final open = find.descendant(
          of: find.byType(Scrollable),
          matching: find.text(label),
        );
        expect(tester.getRect(open), closed);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets('popup uses the widest option instead of the available slot', (
    tester,
  ) async {
    const selectedLabel = 'Short';
    const widestLabel = 'Widest option';
    await tester.pumpWidget(
      harness(
        SizedBox(
          width: 420,
          child: UnifiedDropdownButton<String>(
            value: 'a',
            items: const [
              DropdownMenuItem(value: 'a', child: Text(selectedLabel)),
              DropdownMenuItem(
                value: 'b',
                child: Text(widestLabel, style: TextStyle(fontSize: 18)),
              ),
            ],
            alignment: Alignment.centerRight,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final closed = tester.getRect(find.text(selectedLabel));
    await tester.tap(find.text(selectedLabel));
    await tester.pumpAndSettle();
    final menu = find.byType(Scrollable);
    final widest = find.descendant(of: menu, matching: find.text(widestLabel));
    final selected = find.descendant(
      of: menu,
      matching: find.text(selectedLabel),
    );
    expect(
      tester.getSize(menu).width,
      closeTo(tester.getSize(widest).width + 44, 1),
    );
    expect(tester.getRect(selected), closed);
  });

  for (final isFormField in [false, true]) {
    testWidgets(
      'Windows ${isFormField ? 'form field' : 'dropdown'} label stays put after a mouse press',
      (tester) async {
        await tester.pumpWidget(
          harness(
            SizedBox(
              width: 240,
              child: isFormField
                  ? UnifiedDropdownButtonFormField<String>(
                      initialValue: 'c',
                      items: items,
                      onChanged: (_) {},
                      expandWidth: true,
                      decoration: const InputDecoration(
                        labelText: 'Choice',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    )
                  : UnifiedDropdownButton<String>(
                      value: 'c',
                      items: items,
                      onChanged: (_) {},
                      alignment: Alignment.centerRight,
                      multilineItems: true,
                    ),
            ),
          ),
        );
        final label = find.text('Charlie');
        final closed = tester.getRect(label);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: closed.center);
        await tester.pumpAndSettle();
        expect(tester.getRect(label), closed);
        await mouse.down(closed.center);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.getRect(label), closed);
        await mouse.up();
        await tester.pumpAndSettle();

        final open = find.descendant(
          of: find.byType(Scrollable),
          matching: label,
        );
        expect(tester.getRect(open), closed);
        await mouse.removePointer();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets('long multiline dropdown scrolls and selects an option', (
    tester,
  ) async {
    int? selected;
    await tester.pumpWidget(
      harness(
        UnifiedDropdownButton<int>(
          value: 18,
          items: List.generate(
            20,
            (index) => DropdownMenuItem(
              value: index,
              child: Text('Choice $index\nSecond line'),
            ),
          ),
          multilineItems: true,
          menuMaxHeight: 160,
          onChanged: (value) => selected = value,
        ),
      ),
    );
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    final menu = find.byType(Scrollable);
    final label = find.descendant(
      of: menu,
      matching: find.text('Choice 18\nSecond line'),
    );
    await tester.scrollUntilVisible(label, 80, scrollable: menu);
    await tester.pumpAndSettle();
    expect(tester.getSize(menu).height, lessThanOrEqualTo(160));
    final menuRect = tester.getRect(menu);
    final rowRect = tester.getRect(label);
    expect(rowRect.top, greaterThanOrEqualTo(menuRect.top));
    expect(rowRect.bottom, lessThanOrEqualTo(menuRect.bottom));
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(selected, 18);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Material form field tracks selection, external values and reset',
    (tester) async {
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
                    decoration: const InputDecoration(
                      labelText: 'Choice',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final field = find.byType(DropdownButtonFormField<String>);
      final fieldWidth = tester.getSize(field).width;
      expect(fieldWidth, lessThan(240));
      final closedLabel = tester.getRect(find.text('Alpha'));
      await tester.tap(find.text('Alpha').first);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Scrollable)).width, fieldWidth);
      expect(tester.getRect(find.text('Alpha').last), closedLabel);
      expect(
        tester.getRect(find.text('Alpha').last).left,
        tester.getRect(find.text('Charlie').last).left,
      );
      await tester.tap(find.text('Charlie').last);
      await tester.pumpAndSettle();
      expect(tester.state<FormFieldState<String>>(field).value, 'c');
      form.currentState!.reset();
      await tester.pump();
      expect(tester.state<FormFieldState<String>>(field).value, 'a');
      update(() => initial = null);
      await tester.pump();
      expect(tester.state<FormFieldState<String>>(field).value, isNull);
      update(() => initial = null);
      await tester.pump();
      expect(tester.state<FormFieldState<String>>(field).value, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final isFormField in [false, true]) {
    testWidgets(
      'Windows ${isFormField ? 'form field' : 'dropdown'} highlights its surface and preserves the trigger layout',
      (tester) async {
        await tester.pumpWidget(
          harness(
            SizedBox(
              width: 240,
              child: isFormField
                  ? UnifiedDropdownButtonFormField<String>(
                      initialValue: 'a',
                      items: items,
                      onChanged: (_) {},
                      expandWidth: true,
                      decoration: const InputDecoration(
                        labelText: 'Choice',
                        border: OutlineInputBorder(),
                      ),
                    )
                  : UnifiedDropdownButton<String>(
                      value: 'a',
                      items: items,
                      onChanged: (_) {},
                    ),
            ),
          ),
        );

        final trigger = isFormField
            ? find.byType(UnifiedDropdownButtonFormField<String>)
            : find.byType(UnifiedDropdownButton<String>);
        final arrowFinder = find.byIcon(Icons.arrow_drop_down);
        final bounds = tester.getRect(trigger);
        final initialIconColor = IconTheme.of(
          tester.element(arrowFinder),
        ).color;
        final initialLabelColor = DefaultTextStyle.of(
          tester.element(find.text('Alpha')),
        ).style.color;
        final decorator = find.byType(InputDecorator);
        final initialBorder = isFormField
            ? tester.widget<InputDecorator>(decorator).decoration.enabledBorder
            : null;
        final plainSurface = find.descendant(
          of: trigger,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).borderRadius ==
                    AppRadius.borderMedium,
          ),
        );
        Color? surfaceColor() => isFormField
            ? tester.widget<InputDecorator>(decorator).decoration.fillColor
            : (tester.widget<DecoratedBox>(plainSurface.first).decoration
                      as BoxDecoration)
                  .color;
        final idleColor = surfaceColor();

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: bounds.center);
        await tester.pumpAndSettle();

        expect(surfaceColor(), isNot(idleColor));
        expect(
          IconTheme.of(tester.element(arrowFinder)).color,
          initialIconColor,
        );
        expect(
          DefaultTextStyle.of(tester.element(find.text('Alpha'))).style.color,
          initialLabelColor,
        );
        expect(tester.getRect(trigger), bounds);
        if (isFormField) {
          expect(
            tester.widget<InputDecorator>(decorator).decoration.enabledBorder,
            initialBorder,
          );
        }

        await mouse.removePointer();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
