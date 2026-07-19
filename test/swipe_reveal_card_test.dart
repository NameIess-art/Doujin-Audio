import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('Windows context menu prefers nested card under the pointer', (
    tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    final platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    var parentRemoved = false;
    var childRemoved = false;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: SwipeRevealCard(
                shape: shape,
                actionLabel: 'Parent remove',
                removeTooltip: 'Parent remove',
                onRemove: () => parentRemoved = true,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 300,
                    height: 64,
                    child: SwipeRevealCard(
                      shape: shape,
                      actionLabel: 'Child remove',
                      removeTooltip: 'Child remove',
                      onRemove: () => childRemoved = true,
                      child: const ColoredBox(
                        color: Colors.white,
                        child: Center(child: Text('Child row')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('Child row')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Child remove'), findsOneWidget);
    expect(find.text('Parent remove'), findsNothing);
    expect(
      tester
          .widget<PopupMenuItem<VoidCallback>>(
            find.widgetWithText(PopupMenuItem<VoidCallback>, 'Child remove'),
          )
          .height,
      42,
    );

    await tester.tap(find.text('Child remove'));
    await tester.pumpAndSettle();

    expect(childRemoved, isTrue);
    expect(parentRemoved, isFalse);
    expect(platformCalls, isNotEmpty);
  });
}
