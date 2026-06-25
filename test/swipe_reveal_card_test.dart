import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/widgets/swipe_reveal_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
