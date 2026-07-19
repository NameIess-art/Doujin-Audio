import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/core/widgets/swipe_reveal_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default reveal colors use the dark theme palette', () {
    expect(SwipeRevealCard.darkDestructiveActionColor, const Color(0xFF93000A));
    expect(SwipeRevealCard.darkPrimaryActionColor, const Color(0xFFF08599));
  });

  testWidgets('closed card surface can differ from reveal action color', (
    tester,
  ) async {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 96,
              child: SwipeRevealCard(
                shape: shape,
                color: Colors.blue,
                closedColor: Colors.red,
                actionLabel: 'Details',
                removeTooltip: 'Details',
                onRemove: () {},
                child: const SizedBox.expand(child: Text('Closed content')),
              ),
            ),
          ),
        ),
      ),
    );

    final closedSurface = tester.widgetList<ColoredBox>(
      find.byWidgetPredicate((widget) {
        return widget is ColoredBox && widget.color == Colors.red;
      }),
    );
    expect(closedSurface, isNotEmpty);
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        if (decoration is! ShapeDecoration || decoration.color != Colors.red) {
          return false;
        }
        final shape = decoration.shape;
        return shape is RoundedRectangleBorder && shape.side != BorderSide.none;
      }),
      findsNothing,
      reason: 'The reveal backing must not repaint the child card border.',
    );
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });
}
