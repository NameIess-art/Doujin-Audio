import 'package:doujin_audio/core/widgets/app_buttons.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('right-click highlights only the source card until dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final title in ['First track', 'Second track'])
                SwipeRevealCard(
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () => fail('Dismissal must not remove a track'),
                  child: SizedBox(
                    width: 200,
                    height: 56,
                    child: Center(child: Text(title)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final first = find.text('First track');
    final tint = appPressedTint(Theme.of(tester.element(first)).colorScheme);
    final highlightedCard = find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.position == DecorationPosition.foreground &&
          widget.decoration is ShapeDecoration &&
          (widget.decoration as ShapeDecoration).color == tint,
    );
    expect(highlightedCard, findsNothing);

    final mouse = await tester.startGesture(
      tester.getCenter(first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    addTearDown(mouse.removePointer);
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('Remove')));
    await tester.pump();
    expect(highlightedCard, findsOneWidget);
    expect(
      find.descendant(of: highlightedCard, matching: first),
      findsOneWidget,
    );
    expect(highlightedCard, paints..rrect(color: tint));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
    expect(highlightedCard, findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('focused card opens menu using keyboard and executes action', (
    tester,
  ) async {
    var removed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeRevealCard(
            shape: const RoundedRectangleBorder(),
            actionLabel: 'Remove',
            removeTooltip: 'Remove',
            onRemove: () => removed = true,
            child: InkWell(
              onTap: () {},
              child: const SizedBox(
                width: 300,
                height: 100,
                child: Text('Track'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(removed, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'popup keyboard skips disabled rows, selects and restores focus',
    (tester) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: UnifiedPopupMenuButton<int>(
                icon: Icons.more_vert,
                tooltip: 'Menu',
                onSelected: (value) => selected = value,
                entries: const [
                  UnifiedMenuEntry.action(
                    value: 0,
                    icon: Icons.block,
                    label: 'Disabled',
                    enabled: false,
                  ),
                  UnifiedMenuEntry.action(
                    value: 1,
                    icon: Icons.play_arrow,
                    label: 'First',
                  ),
                  UnifiedMenuEntry.action(
                    value: 2,
                    icon: Icons.pause,
                    label: 'Second',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('First'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
