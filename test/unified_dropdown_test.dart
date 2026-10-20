import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/core/widgets/unified_dropdown.dart';
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
      expect(dropdown.alignment, AlignmentDirectional.centerEnd);
      expect(dropdown.itemHeight, kMinInteractiveDimension);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disabled').last);
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.text('Charlie').last);
      await tester.pumpAndSettle();
      expect(selected, 'c');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('dropdown preserves v0.29 option typography and alignment', (
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
    expect(entry.alignment, AlignmentDirectional.centerEnd);
    expect(find.byIcon(Icons.check), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

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
                    decoration: const InputDecoration(labelText: 'Choice'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final field = find.byType(DropdownButtonFormField<String>);
      await tester.tap(find.text('Alpha').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Charlie').last);
      await tester.pumpAndSettle();
      expect(tester.state<FormFieldState<String>>(field).value, 'c');
      form.currentState!.reset();
      await tester.pump();
      expect(tester.state<FormFieldState<String>>(field).value, 'a');
      update(() => initial = null);
      await tester.pump();
      expect(tester.state<FormFieldState<String>>(field).value, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
