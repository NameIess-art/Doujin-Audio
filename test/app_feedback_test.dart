import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/confirm_action_dialog.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';

Widget _feedbackApp({required bool blurEnabled, required Widget home}) {
  return ProviderScope(
    key: ValueKey<bool>(blurEnabled),
    overrides: [
      settingsStateProvider.overrideWith(
        (ref) => Stream<SettingsState>.value(
          SettingsState(uiBlurEffectEnabled: blurEnabled),
        ),
      ),
    ],
    child: MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: home),
  );
}

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
      _feedbackApp(
        blurEnabled: true,
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

  testWidgets('top feedback can be dismissed by swiping right', (tester) async {
    await tester.pumpWidget(
      _feedbackApp(
        blurEnabled: true,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showAppSnackBar(
                  context,
                  'Saved successfully.',
                  tone: AppFeedbackTone.success,
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

    final dismissible = find.byType(Dismissible);
    expect(dismissible, findsOneWidget);
    expect(
      tester.widget<Dismissible>(dismissible).direction,
      DismissDirection.startToEnd,
    );

    await tester.drag(dismissible, const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(find.text('Saved successfully.'), findsNothing);
  });

  testWidgets('top feedback follows blur setting and keeps icon on the left', (
    tester,
  ) async {
    Widget buildSurface(bool blurEnabled) {
      return _feedbackApp(
        blurEnabled: blurEnabled,
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: AppFeedbackSurface(
                tone: AppFeedbackTone.info,
                icon: Icons.info_outline_rounded,
                title: 'Notice',
                message: 'Operation is still running.',
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildSurface(true));
    await tester.pumpAndSettle();

    final surface = find.byType(AppFeedbackSurface);
    final clip = tester.widget<ClipRRect>(
      find.descendant(of: surface, matching: find.byType(ClipRRect)),
    );
    expect(
      clip.borderRadius,
      BorderRadius.circular(AppDesignTokens.dark.radiusCard),
    );
    expect(
      find.descendant(of: surface, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final blurredDecoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: surface,
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(blurredDecoration.color!.a, lessThan(1));
    expect(
      tester.getCenter(find.byIcon(Icons.info_outline_rounded)).dx,
      lessThan(tester.getCenter(find.text('Operation is still running.')).dx),
    );

    await tester.pumpWidget(buildSurface(false));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: surface, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final opaqueDecoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: surface,
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(opaqueDecoration.color!.a, 1);
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
