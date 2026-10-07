import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
