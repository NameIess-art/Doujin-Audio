import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/confirm_action_dialog.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

Widget _feedbackApp({required Widget home}) {
  return MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: home);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'completion feedback defers catalog commits only during its fade',
    (tester) async {
      final interaction = UiInteractionCoordinator.instance;
      addTearDown(interaction.resetForTest);
      late BuildContext feedbackContext;
      await tester.pumpWidget(
        _feedbackApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                feedbackContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      showAppSnackBar(feedbackContext, 'Refresh complete');
      await tester.pump();
      var commits = 0;
      interaction.scheduleCommit(
        key: 'refresh-result-test',
        structural: true,
        commit: () => commits++,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(commits, 0);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump();
      expect(commits, 1);
      expect(find.text('Refresh complete'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(interaction.isInteracting, isFalse);
    },
  );

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
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(actionCount, 1);
    expect(find.text('Import failed'), findsOneWidget);
    final fade = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.byType(AppFeedbackSurface),
        matching: find.byType(FadeTransition),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    await tester.tap(find.text('Retry'), warnIfMissed: false);
    expect(actionCount, 1);
    await tester.pump(const Duration(milliseconds: 150));
    expect(fade.opacity.value, closeTo(0, 0.001));
    await tester.pumpAndSettle();
    expect(find.text('Import failed'), findsNothing);
  });

  testWidgets('undoable removal updates in place and resets its window', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    final committed = <String>[];

    await tester.pumpWidget(
      _feedbackApp(
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
    expect(find.text('Undo (5s)'), findsOneWidget);
    expect(find.text('Removed one'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    final fade = find.ancestor(
      of: find.byType(AppFeedbackSurface),
      matching: find.byType(FadeTransition),
    );
    final firstFadeAnimation = tester.widget<FadeTransition>(fade).opacity;
    await tester.tap(find.text('Remove two'));
    await tester.pump();
    expect(
      identical(
        tester.widget<FadeTransition>(fade).opacity,
        firstFadeAnimation,
      ),
      isTrue,
    );
    expect(find.text('Undo (5s)'), findsOneWidget);
    expect(find.text('Removed 2'), findsOneWidget);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(committed, isEmpty);
    for (var i = 0; i < 35; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(committed, <String>['one', 'two']);
  });

  testWidgets('replacement across overlays ends only the old action contract', (
    tester,
  ) async {
    late BuildContext rootContext;
    late BuildContext scopedContext;
    final overlayKey = GlobalKey<OverlayState>();
    final dismissals = <String>[];
    var oldActions = 0;
    var newActions = 0;
    await tester.pumpWidget(
      _feedbackApp(
        home: Builder(
          builder: (context) {
            rootContext = context;
            return MobileOverlayInset(
              bottomInset: 0,
              menuOverlayKey: overlayKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Builder(
                    builder: (context) {
                      scopedContext = context;
                      return const SizedBox();
                    },
                  ),
                  Overlay(key: overlayKey),
                ],
              ),
            );
          },
        ),
      ),
    );
    showAppSnackBar(
      rootContext,
      'Old feedback',
      actionLabel: 'Old action',
      onAction: () => oldActions++,
      onDismissed: (reason) => dismissals.add('old:$reason'),
    );
    await tester.pumpAndSettle();
    showAppSnackBar(
      scopedContext,
      'New feedback',
      actionLabel: 'New action',
      onAction: () => newActions++,
      onDismissed: (reason) => dismissals.add('new:$reason'),
    );
    expect(dismissals, ['old:${AppFeedbackDismissReason.replaced}']);
    await tester.pump();
    expect(find.text('Old feedback'), findsOneWidget);
    expect(find.text('New feedback'), findsOneWidget);
    // A queued old callback is also rejected before the next painted frame.
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Old action'))
        .onPressed!();
    expect(oldActions, 0);
    await tester.pumpAndSettle();
    expect(find.text('Old feedback'), findsNothing);
    expect(dismissals, ['old:${AppFeedbackDismissReason.replaced}']);
    await tester.tap(find.text('New action'));
    expect(newActions, 1);
    expect(dismissals, [
      'old:${AppFeedbackDismissReason.replaced}',
      'new:${AppFeedbackDismissReason.action}',
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(AppFeedbackSurface), findsNothing);
  });

  testWidgets(
    'timeout keeps its deadline and then fades noninteractive pixels',
    (tester) async {
      final semantics = tester.ensureSemantics();
      late BuildContext feedbackContext;
      final dismissals = <AppFeedbackDismissReason>[];
      var actions = 0;
      await tester.pumpWidget(
        _feedbackApp(
          home: Builder(
            builder: (context) {
              feedbackContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      showAppSnackBar(
        feedbackContext,
        'Expiring notice',
        duration: const Duration(seconds: 1),
        actionLabel: 'Deadline action',
        onAction: () => actions++,
        onDismissed: dismissals.add,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final fade = tester.widget<FadeTransition>(
        find.ancestor(
          of: find.byType(AppFeedbackSurface),
          matching: find.byType(FadeTransition),
        ),
      );
      await tester.pump(const Duration(milliseconds: 699));
      expect(fade.opacity.value, 1);
      expect(dismissals, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(dismissals, [AppFeedbackDismissReason.timeout]);
      expect(find.text('Expiring notice'), findsOneWidget);
      expect(find.semantics.byLabel('Deadline action'), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await tester.tap(find.text('Deadline action'), warnIfMissed: false);
      expect(actions, 0);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.text('Expiring notice'), findsNothing);
      expect(dismissals, [AppFeedbackDismissReason.timeout]);
      semantics.dispose();
    },
  );

  testWidgets(
    'feedback expires at its deadline without waiting for fade frames',
    (tester) async {
      late BuildContext feedbackContext;
      final dismissals = <AppFeedbackDismissReason>[];
      await tester.pumpWidget(
        _feedbackApp(
          home: Builder(
            builder: (context) {
              feedbackContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      showAppSnackBar(
        feedbackContext,
        'One second notice',
        duration: const Duration(seconds: 1),
        onDismissed: dismissals.add,
      );
      await tester.pump();
      // No intermediate animation frames are delivered before the deadline.
      await tester.pump(const Duration(seconds: 1));
      expect(dismissals, [AppFeedbackDismissReason.timeout]);
      expect(find.text('One second notice'), findsNothing);
    },
  );

  testWidgets(
    'reduced motion dismisses feedback without retaining fade pixels',
    (tester) async {
      late BuildContext feedbackContext;
      var actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              feedbackContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      showAppSnackBar(
        feedbackContext,
        'Notice',
        actionLabel: 'Dismiss notice',
        onAction: () => actions++,
      );
      await tester.pump();
      expect(
        find.ancestor(
          of: find.byType(AppFeedbackSurface),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      await tester.tap(find.text('Dismiss notice'));
      await tester.pump();
      expect(actions, 1);
      expect(find.byType(AppFeedbackSurface), findsNothing);
    },
  );

  testWidgets('undo action restores pending removals without committing', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    var commits = 0;
    var undos = 0;
    await tester.pumpWidget(
      _feedbackApp(
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
    await tester.tap(find.text('Undo (5s)'));
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

  testWidgets(
    'top feedback uses an opaque surface and keeps icon on the left',
    (tester) async {
      Widget buildSurface() {
        return _feedbackApp(
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

      await tester.pumpWidget(buildSurface());
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
        findsNothing,
      );
      expect(
        tester.getCenter(find.byIcon(Icons.info_outline_rounded)).dx,
        lessThan(tester.getCenter(find.text('Operation is still running.')).dx),
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
    },
  );

  testWidgets('top feedback fades without moving its surface', (tester) async {
    await tester.pumpWidget(
      _feedbackApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSnackBar(
                context,
                'Added to playlist',
                tone: AppFeedbackTone.success,
                duration: const Duration(seconds: 10),
              ),
              child: const Text('Add'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pump();

    final surface = find.byType(AppFeedbackSurface);
    expect(
      find.ancestor(of: surface, matching: find.byType(FadeTransition)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: surface, matching: find.byType(BackdropFilter)),
      findsNothing,
    );

    final initialTopLeft = tester.getTopLeft(surface);
    await tester.pump(const Duration(milliseconds: 110));
    expect(tester.getTopLeft(surface), initialTopLeft);
  });

  testWidgets(
    'top feedback positions close to header and avoids landscape menu bar',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _feedbackApp(
          home: Scaffold(
            body: Row(
              children: [
                const SizedBox(width: 260, child: Text('NavigationMenu')),
                Expanded(
                  child: KeyedSubtree(
                    key: const ValueKey<String>('main_page_canvas'),
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

  for (final size in [const Size(1280, 800), const Size(580, 320)]) {
    testWidgets('feedback from menu stays inside content at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _feedbackApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 180,
                  child: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showAppSnackBar(
                        context,
                        'A long feedback message that must wrap within the content area. ' *
                            4,
                      ),
                      child: const Text('Menu trigger'),
                    ),
                  ),
                ),
                const Expanded(
                  child: ColoredBox(
                    key: ValueKey<String>('main_page_canvas'),
                    color: Colors.black,
                    child: SizedBox.expand(),
                  ),
                ),
                const SizedBox(width: 40),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Menu trigger'));
      await tester.pumpAndSettle();
      final surface = find.byType(AppFeedbackSurface);
      expect(tester.getTopLeft(surface).dx, 196);
      expect(tester.getTopRight(surface).dx, size.width - 56);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  }

  for (final scopedOverlay in [false, true]) {
    testWidgets(
      'feedback follows split pages and resizing with scoped overlay $scopedOverlay',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final service = UndoableRemovalService();
        addTearDown(service.dispose);
        var commits = 0;
        Widget trigger(String label) {
          final button = Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUndoableRemovalFeedback(
                  context,
                  service: service,
                  action: UndoableRemovalAction(
                    key: UndoableRemovalKey('split', label),
                    commit: () => commits++,
                    undo: () {},
                  ),
                  message: '$label feedback',
                  batchMessage: (count) => '$label feedback $count',
                  undoLabel: 'Undo',
                  failureMessage: 'Failed',
                ),
                child: Text(label),
              ),
            ),
          );
          if (!scopedOverlay) return button;
          final overlayKey = GlobalKey<OverlayState>();
          return MobileOverlayInset(
            bottomInset: 0,
            menuOverlayKey: overlayKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                button,
                Overlay(key: overlayKey),
              ],
            ),
          );
        }

        await tester.pumpWidget(
          _feedbackApp(
            home: Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 260),
                  Expanded(
                    child: ColoredBox(
                      key: const ValueKey('main_page_canvas'),
                      color: Colors.black,
                      child: trigger('Main'),
                    ),
                  ),
                  const SizedBox(width: 1),
                  Expanded(
                    child: Navigator(
                      key: const ValueKey('detail_navigator'),
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => Scaffold(body: trigger('Detail')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final surface = find.byType(AppFeedbackSurface);
        void expectPageBounds(String key) {
          final page = tester.getRect(find.byKey(ValueKey(key)));
          expect(tester.getTopLeft(surface).dx, page.left + 16);
          expect(tester.getTopRight(surface).dx, page.right - 16);
        }

        await tester.tap(find.text('Main'));
        await tester.pumpAndSettle();
        expectPageBounds('main_page_canvas');
        if (scopedOverlay) {
          tester.view.physicalSize = const Size(1380, 800);
          await tester.pumpAndSettle();
          expectPageBounds('main_page_canvas');
        }
        await tester.tap(find.text('Detail'));
        await tester.pumpAndSettle();
        expectPageBounds('detail_navigator');
        tester.view.physicalSize = const Size(1480, 800);
        await tester.pumpAndSettle();
        expectPageBounds('detail_navigator');
        expect(tester.takeException(), isNull);
        expect(service.state.pendingCount, 2);
        await tester.tap(find.textContaining('Undo'));
        await tester.pump();
        expect(service.state.pendingCount, 0);
        expect(commits, 0);
        await tester.pumpAndSettle();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final size in [
      const Size(1280, 800),
      const Size(800, 400),
      const Size(400, 800),
    ]) {
      testWidgets('top feedback fills standalone page on $platform at $size', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _feedbackApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  child: Builder(
                    builder: (context) => TextButton(
                      onPressed: () =>
                          showAppSnackBar(context, 'Page feedback'),
                      child: const Text('Trigger'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Trigger'));
        await tester.pumpAndSettle();

        final surface = find.byType(AppFeedbackSurface);
        expect(tester.getTopLeft(surface).dx, 16);
        expect(tester.getTopRight(surface).dx, size.width - 16);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  testWidgets('disposing a page overlay commits its pending removal', (
    tester,
  ) async {
    final service = UndoableRemovalService();
    addTearDown(service.dispose);
    var commits = 0;
    final overlayKey = GlobalKey<OverlayState>();
    await tester.pumpWidget(
      _feedbackApp(
        home: MobileOverlayInset(
          bottomInset: 0,
          menuOverlayKey: overlayKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showUndoableRemovalFeedback(
                      context,
                      service: service,
                      action: UndoableRemovalAction(
                        key: const UndoableRemovalKey('page', 'track'),
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
              Overlay(key: overlayKey),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(service.state.pendingCount, 1);
    await tester.pumpWidget(_feedbackApp(home: const Scaffold()));
    await tester.pumpAndSettle();
    expect(service.state.pendingCount, 0);
    expect(commits, 1);
    expect(tester.takeException(), isNull);
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

  testWidgets('destructive removal prompt displays and updates countdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      _feedbackApp(
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

    expect(find.text('Item deleted (5s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1050));
    expect(find.text('Item deleted (4s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Item deleted (3s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Item deleted (2s)'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Item deleted (1s)'), findsOneWidget);
  });

  testWidgets(
    'new feedback updates in place on existing surface without fade in/out flashing',
    (tester) async {
      await tester.pumpWidget(
        _feedbackApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  const SizedBox(height: 140),
                  TextButton(
                    onPressed: () => showAppSnackBar(
                      context,
                      'First message',
                      duration: const Duration(seconds: 5),
                    ),
                    child: const Text('First'),
                  ),
                  TextButton(
                    onPressed: () => showAppSnackBar(
                      context,
                      'Second message',
                      tone: AppFeedbackTone.success,
                      title: 'Updated title',
                      duration: const Duration(seconds: 5),
                    ),
                    child: const Text('Second'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Trigger first message
      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.pump(
        const Duration(milliseconds: 300),
      ); // Finish initial fade-in

      expect(find.text('First message'), findsOneWidget);
      final fade = find.ancestor(
        of: find.byType(AppFeedbackSurface),
        matching: find.byType(FadeTransition),
      );
      final firstFadeAnimation = tester.widget<FadeTransition>(fade).opacity;
      expect(firstFadeAnimation.value, 1.0);

      // Trigger second message while first is showing
      await tester.tap(find.text('Second'));
      await tester.pump();

      // Verify it updated in place without restarting fade animation
      expect(find.text('Second message'), findsOneWidget);
      expect(find.text('Updated title'), findsOneWidget);
      expect(find.text('First message'), findsOneWidget);
      final updatedFade = find.ancestor(
        of: find.byType(AppFeedbackSurface),
        matching: find.byType(FadeTransition),
      );
      final updatedFadeAnimation = tester
          .widget<FadeTransition>(updatedFade)
          .opacity;
      expect(identical(updatedFadeAnimation, firstFadeAnimation), isTrue);
      expect(
        updatedFadeAnimation.value,
        1.0,
      ); // Kept fully opaque without flashing
      await tester.pump(const Duration(milliseconds: 150));
      final textFade = find
          .ancestor(
            of: find.text('Second message'),
            matching: find.byType(FadeTransition),
          )
          .first;
      expect(
        tester.widget<FadeTransition>(textFade).opacity.value,
        inExclusiveRange(0, 1),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<FadeTransition>(textFade).opacity.value,
        closeTo(1, 0.001),
      );
      await tester.pumpAndSettle();
      expect(find.text('First message'), findsNothing);
      expect(find.text('Second message'), findsOneWidget);
    },
  );
}
