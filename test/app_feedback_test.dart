import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/widgets/app_feedback.dart';
import 'package:nameless_audio/widgets/confirm_action_dialog.dart';

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

  testWidgets('non-destructive confirmation uses the requested action', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showConfirmActionDialog(
                  context: context,
                  title: 'Open settings',
                  message: 'Change this permission in system settings.',
                  cancelLabel: 'Cancel',
                  confirmLabel: 'Open settings',
                  confirmIcon: Icons.settings_rounded,
                  isDestructive: false,
                );
              },
              child: const Text('Show settings prompt'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show settings prompt'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.settings_rounded), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Open settings'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
