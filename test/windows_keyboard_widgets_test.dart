import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/unified_popup_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

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
