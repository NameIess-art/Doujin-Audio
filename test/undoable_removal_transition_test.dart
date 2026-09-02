import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';

void main() {
  testWidgets('UndoableRemovalTransition renders child normally when not hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UndoableRemovalTransition(
            hidden: false,
            child: SizedBox(
              key: ValueKey('test_item'),
              width: 200,
              height: 100,
              child: Text('Item Content'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Item Content'), findsOneWidget);
    final renderBox = tester.renderObject<RenderBox>(
      find.byKey(const ValueKey('test_item')),
    );
    expect(renderBox.size.height, 100);
  });

  testWidgets(
    'UndoableRemovalTransition smoothly collapses and moves items below upward when hidden',
    (tester) async {
      bool hidden = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    UndoableRemovalTransition(
                      hidden: hidden,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.linear,
                      reverseCurve: Curves.linear,
                      child: const SizedBox(
                        key: ValueKey('first_item'),
                        width: 200,
                        height: 100,
                        child: Text('First Item'),
                      ),
                    ),
                    const SizedBox(
                      key: ValueKey('second_item'),
                      width: 200,
                      height: 50,
                      child: Text('Second Item'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      // Initially, first item is at y = 0, second item is at y = 100.
      final secondInitial = tester.getTopLeft(
        find.byKey(const ValueKey('second_item')),
      );
      expect(secondInitial.dy, 100.0);

      // Trigger removal (hidden = true).
      hidden = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    UndoableRemovalTransition(
                      hidden: hidden,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.linear,
                      reverseCurve: Curves.linear,
                      child: const SizedBox(
                        key: ValueKey('first_item'),
                        width: 200,
                        height: 100,
                        child: Text('First Item'),
                      ),
                    ),
                    const SizedBox(
                      key: ValueKey('second_item'),
                      width: 200,
                      height: 50,
                      child: Text('Second Item'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      // Mid-animation at 100ms (50% progress with linear curve).
      await tester.pump(const Duration(milliseconds: 100));

      final secondMid = tester.getTopLeft(
        find.byKey(const ValueKey('second_item')),
      );
      // The second item should have moved upward from 100 towards 0!
      expect(secondMid.dy, lessThan(100.0));
      expect(secondMid.dy, greaterThan(0.0));
      expect(secondMid.dy, closeTo(50.0, 5.0));

      // Complete animation (total 200ms).
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final secondFinal = tester.getTopLeft(
        find.byKey(const ValueKey('second_item')),
      );
      // First item collapsed to 0 height, so second item is now at y = 0.
      expect(secondFinal.dy, 0.0);
      // The first item content is no longer rendered in the tree.
      expect(find.text('First Item'), findsNothing);
    },
  );

  testWidgets('UndoableRemovalTransition restores item when hidden becomes false', (
    tester,
  ) async {
    bool hidden = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  UndoableRemovalTransition(
                    hidden: hidden,
                    duration: const Duration(milliseconds: 200),
                    child: const SizedBox(
                      key: ValueKey('first_item'),
                      width: 200,
                      height: 100,
                      child: Text('First Item'),
                    ),
                  ),
                  const SizedBox(
                    key: ValueKey('second_item'),
                    width: 200,
                    height: 50,
                    child: Text('Second Item'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    // Initially hidden: first item is 0 height, second item at y = 0.
    expect(find.text('First Item'), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('second_item'))).dy,
      0.0,
    );

    // Undo: hidden = false.
    hidden = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  UndoableRemovalTransition(
                    hidden: hidden,
                    duration: const Duration(milliseconds: 200),
                    child: const SizedBox(
                      key: ValueKey('first_item'),
                      width: 200,
                      height: 100,
                      child: Text('First Item'),
                    ),
                  ),
                  const SizedBox(
                    key: ValueKey('second_item'),
                    width: 200,
                    height: 50,
                    child: Text('Second Item'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('First Item'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('second_item'))).dy,
      100.0,
    );
  });

  testWidgets(
    'UndoableRemovalTransition immediately snaps when animations are disabled',
    (tester) async {
      bool hidden = false;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return Column(
                    children: [
                      UndoableRemovalTransition(
                        hidden: hidden,
                        duration: const Duration(milliseconds: 200),
                        child: const SizedBox(
                          key: ValueKey('first_item'),
                          width: 200,
                          height: 100,
                          child: Text('First Item'),
                        ),
                      ),
                      const SizedBox(
                        key: ValueKey('second_item'),
                        width: 200,
                        height: 50,
                        child: Text('Second Item'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('second_item'))).dy,
        100.0,
      );

      // Trigger removal with animations disabled.
      hidden = true;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  return Column(
                    children: [
                      UndoableRemovalTransition(
                        hidden: hidden,
                        duration: const Duration(milliseconds: 200),
                        child: const SizedBox(
                          key: ValueKey('first_item'),
                          width: 200,
                          height: 100,
                          child: Text('First Item'),
                        ),
                      ),
                      const SizedBox(
                        key: ValueKey('second_item'),
                        width: 200,
                        height: 50,
                        child: Text('Second Item'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      // Without waiting for duration, it snaps to 0 immediately.
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('second_item'))).dy,
        0.0,
      );
      expect(find.text('First Item'), findsNothing);
    },
  );
}
