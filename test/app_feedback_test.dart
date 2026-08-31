import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/confirm_action_dialog.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
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

  testWidgets('undoable removal merges, resets its window, and commits', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    final committed = <String>[];

    await tester.pumpWidget(
      _feedbackApp(
        blurEnabled: true,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const SizedBox(height: 140),
                TextButton(
                  onPressed: () => showUndoableRemovalFeedback(
                    context,
                    service: service,
                    action: UndoableRemovalAction(
                      key: const UndoableRemovalKey('test', 'one'),
                      commit: () => committed.add('one'),
                      undo: () {},
                    ),
                    message: 'Removed one',
                    batchMessage: (count) => 'Removed $count',
                    undoLabel: 'Undo',
                    failureMessage: 'Failed',
                  ),
                  child: const Text('Remove one'),
                ),
                TextButton(
                  onPressed: () => showUndoableRemovalFeedback(
                    context,
                    service: service,
                    action: UndoableRemovalAction(
                      key: const UndoableRemovalKey('test', 'two'),
                      commit: () => committed.add('two'),
                      undo: () {},
                    ),
                    message: 'Removed two',
                    batchMessage: (count) => 'Removed $count',
                    undoLabel: 'Undo',
                    failureMessage: 'Failed',
                  ),
                  child: const Text('Remove two'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Remove one'));
    await tester.pump();
    expect(find.text('Undo (4s)'), findsOneWidget);
    expect(find.text('Removed one'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Remove two'));
    await tester.pump();
    expect(find.text('Undo (4s)'), findsOneWidget);
    expect(find.text('Removed 2'), findsOneWidget);
    for (var i = 0; i < 35; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(committed, isEmpty);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(committed, <String>['one', 'two']);
  });

  testWidgets('undo action restores pending removals without committing', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    var commits = 0;
    var undos = 0;
    await tester.pumpWidget(
      _feedbackApp(
        blurEnabled: true,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUndoableRemovalFeedback(
                context,
                service: service,
                action: UndoableRemovalAction(
                  key: const UndoableRemovalKey('test', 'one'),
                  commit: () => commits++,
                  undo: () => undos++,
                ),
                message: 'Removed',
                batchMessage: (count) => 'Removed $count',
                undoLabel: 'Undo',
                failureMessage: 'Failed',
              ),
              child: const Text('Remove'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.tap(find.text('Undo (4s)'));
    await tester.pump();

    expect(undos, 1);
    expect(commits, 0);
    expect(service.state.hiddenKeys, isEmpty);
  });

  testWidgets('swiping undoable feedback commits the pending removal', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    var commits = 0;
    await tester.pumpWidget(
      _feedbackApp(
        blurEnabled: true,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUndoableRemovalFeedback(
                context,
                service: service,
                action: UndoableRemovalAction(
                  key: const UndoableRemovalKey('test', 'swipe'),
                  commit: () => commits++,
                  undo: () {},
                ),
                message: 'Removed',
                batchMessage: (count) => 'Removed $count',
                undoLabel: 'Undo',
                failureMessage: 'Failed',
              ),
              child: const Text('Remove'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(commits, 1);
    expect(service.state.hasPending, isFalse);
  });

  testWidgets('ordinary feedback replacement commits pending removals', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    var commits = 0;
    await tester.pumpWidget(
      _feedbackApp(
        blurEnabled: true,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const SizedBox(height: 140),
                TextButton(
                  onPressed: () => showUndoableRemovalFeedback(
                    context,
                    service: service,
                    action: UndoableRemovalAction(
                      key: const UndoableRemovalKey('test', 'replace'),
                      commit: () => commits++,
                      undo: () {},
                    ),
                    message: 'Removed',
                    batchMessage: (count) => 'Removed $count',
                    undoLabel: 'Undo',
                    failureMessage: 'Failed',
                  ),
                  child: const Text('Remove'),
                ),
                TextButton(
                  onPressed: () => showAppSnackBar(context, 'Ordinary'),
                  child: const Text('Replace'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.tap(find.text('Replace'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(commits, 1);
    expect(find.text('Ordinary'), findsOneWidget);
  });

  testWidgets('top feedback can be dismissed by swiping horizontally', (
    tester,
  ) async {
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
      DismissDirection.horizontal,
    );

    await tester.drag(dismissible, const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('Saved successfully.'), findsNothing);

    await tester.tap(find.text('Show'));
    await tester.pump();
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
      BorderRadius.circular(AppDesignTokens.dark.radiusCapsule),
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

  testWidgets(
    'top feedback positions close to header and avoids landscape menu bar',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _feedbackApp(
          blurEnabled: true,
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 260, child: Text('NavigationMenu')),
                Expanded(
                  child: KeyedSubtree(
                    key: const ValueKey<String>('main_page_canvas_0'),
                    child: Builder(
                      builder: (context) => TextButton(
                        onPressed: () {
                          showAppSnackBar(
                            context,
                            'Landscape feedback message',
                            duration: const Duration(seconds: 10),
                          );
                        },
                        child: const Text('Trigger'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();

      final surfaceFinder = find.byType(AppFeedbackSurface);
      expect(surfaceFinder, findsOneWidget);

      final topLeft = tester.getTopLeft(surfaceFinder);
      final topRight = tester.getTopRight(surfaceFinder);

      // Should be positioned at the second row capsule area (~48px)
      expect(topLeft.dy, closeTo(48.0, 5.0));
      // In landscape with a 260px menu, left edge should start at 260 + 16 = 276
      expect(topLeft.dx, closeTo(276.0, 5.0));
      // Right edge should align with standard 16px right margin (screen width - 16 = 1264)
      expect(topRight.dx, closeTo(1264.0, 5.0));
    },
  );

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

  testWidgets('destructive removal prompt displays and updates countdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      _feedbackApp(
        blurEnabled: false,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showAppSnackBar(
                  context,
                  'Item deleted',
                  tone: AppFeedbackTone.destructive,
                );
              },
              child: const Text('Delete'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Delete'));
    await tester.pump();

    expect(find.text('Item deleted (4s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1050));
    expect(find.text('Item deleted (3s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Item deleted (2s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Item deleted (1s)'), findsOneWidget);
  });
}

