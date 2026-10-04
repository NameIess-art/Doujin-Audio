import 'package:doujin_audio/core/widgets/animated_reorder.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget list(
    List<int> order, {
    int columns = 1,
    ScrollController? scroll,
    bool disableAnimations = false,
    bool tickerEnabled = true,
    ValueChanged<int>? onTap,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: TickerMode(
        enabled: tickerEnabled,
        child: Scaffold(
          body: AnimatedReorder(
            order: order,
            child: ListView.builder(
              controller: scroll,
              cacheExtent: 0,
              itemCount: (order.length / columns).ceil(),
              findChildIndexCallback: columns == 1
                  ? (key) => order.indexOf((key as ValueKey<int>).value)
                  : null,
              itemBuilder: (context, row) {
                Widget entry(int index) {
                  final id = order[index];
                  return AnimatedReorderItem(
                    key: ValueKey(id),
                    id: id,
                    child: SizedBox(
                      height: 80 + id % 2 * 20,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap?.call(id),
                        child: RepaintBoundary(child: Text('entry-$id')),
                      ),
                    ),
                  );
                }

                if (columns == 1) return entry(row);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var col = 0; col < columns; col++)
                      Expanded(child: entry(row * columns + col)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  for (final columns in [1, 2]) {
    testWidgets('reorders $columns columns from their painted positions', (
      tester,
    ) async {
      await tester.pumpWidget(list([0, 1, 2, 3], columns: columns));
      final before = tester.getTopLeft(find.text('entry-3'));
      final element = tester.element(find.text('entry-3'));
      await tester.pumpWidget(list([3, 0, 1, 2], columns: columns));
      expect(tester.getTopLeft(find.text('entry-3')), before);
      await tester.pump(kAppMotionSlow ~/ 2);
      final during = tester.getTopLeft(find.text('entry-3'));
      expect(during.dy, lessThan(before.dy));
      expect(during.dy, greaterThan(0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('entry-3')), Offset.zero);
      if (columns == 1) {
        expect(tester.element(find.text('entry-3')), same(element));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a second reorder continues from the current visual position', (
    tester,
  ) async {
    await tester.pumpWidget(list([0, 1, 2, 3]));
    await tester.pumpWidget(list([3, 0, 1, 2]));
    await tester.pump(const Duration(milliseconds: 70));
    final before = tester.getTopLeft(find.text('entry-3'));
    await tester.pumpWidget(list([0, 1, 2, 3]));
    expect(tester.getTopLeft(find.text('entry-3')), before);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('entry-3')).dy, 260);
  });

  testWidgets('hit testing follows a moving entry', (tester) async {
    int? tapped;
    void onTap(int id) => tapped = id;
    await tester.pumpWidget(list([0, 1, 2, 3], onTap: onTap));
    await tester.pumpWidget(list([3, 0, 1, 2], onTap: onTap));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(
      tester.getTopLeft(find.text('entry-3')) + const Offset(4, 4),
    );
    expect(tapped, 3);
    await tester.pumpAndSettle();
  });

  testWidgets('scrolling is included in the starting position and stays lazy', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final order = List.generate(200, (index) => index);
    await tester.pumpWidget(list(order, scroll: scroll));
    scroll.jumpTo(900);
    await tester.pump();
    final before = tester.getTopLeft(find.text('entry-11'));
    final next = List.of(order);
    next[10] = 11;
    next[11] = 10;
    await tester.pumpWidget(list(next, scroll: scroll));
    expect(tester.getTopLeft(find.text('entry-11')), before);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('entry-11')).dy, 0);
    expect(find.byType(AnimatedReorderItem).evaluate().length, lessThan(20));
    expect(scroll.offset, 900);
  });

  testWidgets('inserting an entry does not animate a reorder', (tester) async {
    await tester.pumpWidget(list([0, 1, 2]));
    await tester.pumpWidget(list([3, 0, 1, 2]));
    expect(tester.getTopLeft(find.text('entry-0')).dy, 100);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final disable in [true, false]) {
    testWidgets('skips motion when ${disable ? 'disabled' : 'ticker muted'}', (
      tester,
    ) async {
      await tester.pumpWidget(list([0, 1, 2]));
      await tester.pumpWidget(
        list([2, 0, 1], disableAnimations: disable, tickerEnabled: disable),
      );
      expect(tester.getTopLeft(find.text('entry-2')), Offset.zero);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('disabling motion settles an active reorder immediately', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(list([0, 1, 2]));
      await tester.pumpWidget(list([2, 0, 1]));
      await tester.pump(const Duration(milliseconds: 70));
      expect(tester.getTopLeft(find.text('entry-2')).dy, greaterThan(0));
      await tester.pumpWidget(list([2, 0, 1], disableAnimations: true));
      expect(tester.getTopLeft(find.text('entry-2')), Offset.zero);
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
