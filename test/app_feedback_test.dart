import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/widgets/app_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('continuous feedback deduplicates repeated values', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      AppInteractionFeedback.resetContinuous();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await AppInteractionFeedback.continuous(
      10,
      interval: const Duration(seconds: 1),
    );
    await AppInteractionFeedback.continuous(
      10,
      interval: const Duration(seconds: 1),
    );
    await AppInteractionFeedback.continuous(
      11,
      interval: const Duration(seconds: 1),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'HapticFeedback.vibrate');
  });

  test('reset allows continuous feedback to start a new interaction', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      AppInteractionFeedback.resetContinuous();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await AppInteractionFeedback.continuous(10);
    AppInteractionFeedback.resetContinuous();
    await AppInteractionFeedback.continuous(10);

    expect(calls, hasLength(2));
  });

  testWidgets('top feedback action invokes callback and dismisses surface', (
    tester,
  ) async {
    var actionCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showAppSnackBar(
                  context,
                  'Check the folder and retry.',
                  tone: AppFeedbackTone.destructive,
                  title: 'Import failed',
                  actionLabel: 'Retry',
                  onAction: () => actionCount++,
                  duration: const Duration(seconds: 10),
                );
              },
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show'));
    await tester.pump();

    expect(find.text('Import failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(actionCount, 1);
    expect(find.text('Import failed'), findsNothing);
  });
}
