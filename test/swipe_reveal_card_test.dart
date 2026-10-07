import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_shared_helpers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_list_view.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final coordinator = UiInteractionCoordinator.instance;
  setUp(coordinator.resetForTest);
  tearDown(coordinator.resetForTest);

  for (final kind in ['library', 'playlist']) {
    testWidgets('$kind pin fades only after the entry closes', (tester) async {
      var pinned = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                height: 96,
                child: StatefulBuilder(
                  builder: (context, setState) => SwipeRevealCard(
                    shape: const RoundedRectangleBorder(),
                    actionLabel: 'Remove',
                    removeTooltip: 'Remove',
                    onRemove: () {},
                    leadingActionLabel: 'Unpin',
                    leadingActionTooltip: 'Unpin',
                    leadingActionIcon: Icons.push_pin_rounded,
                    animateLeadingActionClose: true,
                    onLeadingAction: () => setState(() => pinned = false),
                    child: Row(
                      children: [
                        if (kind == 'library')
                          LibraryPinnedIndicator(
                            path: 'entry',
                            isPinned: pinned,
                          )
                        else
                          PlaylistPinnedIndicator(
                            sessionId: 'entry',
                            isPinned: pinned,
                          ),
                        const Text('Entry'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final entry = find.text('Entry');
      final closedRect = tester.getRect(entry);
      final pin = find.descendant(
        of: find.byType(
          kind == 'library' ? LibraryPinnedIndicator : PlaylistPinnedIndicator,
        ),
        matching: find.byIcon(Icons.push_pin_rounded),
      );
      double opacity() => tester
          .widgetList<FadeTransition>(
            find.ancestor(of: pin, matching: find.byType(FadeTransition)),
          )
          .fold(1.0, (value, fade) => value * fade.opacity.value);

      await tester.drag(entry, const Offset(180, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Unpin'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(pinned, isTrue);
      expect(opacity(), 1);
      expect(tester.getRect(entry), isNot(closedRect));
      await tester.pump(const Duration(milliseconds: 111));
      await tester.pump();
      await tester.pump();
      expect(pinned, isFalse);
      expect(tester.getRect(entry), closedRect);
      expect(pin, findsOneWidget);
      expect(opacity(), 1);
      await tester.pump(const Duration(milliseconds: 225));
      expect(opacity(), closeTo(0.5, 0.01));
      await tester.pumpAndSettle();
      expect(pin, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'async data waits through dragging and settling, then resumes while open',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                height: 96,
                child: SwipeRevealCard(
                  shape: const RoundedRectangleBorder(),
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () {},
                  child: const Text('Swipe target'),
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Swipe target')),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-40, 0));
      expect(coordinator.isInteracting, isTrue);
      var committed = false;
      final result = Completer<void>();
      final completion = result.future.then(
        (_) => coordinator.scheduleCommit(
          key: 'swipe-result',
          commit: () => committed = true,
        ),
      );
      result.complete();
      await completion;
      await tester.pump();
      expect(committed, isFalse);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(committed, isFalse);
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
      await tester.pump();
      expect(committed, isTrue);
      expect(coordinator.isInteracting, isFalse);
      expect(find.byTooltip('Remove'), findsOneWidget);
    },
  );

  for (final ending in ['cancel', 'hide', 'dispose', 'disable']) {
    testWidgets('swipe $ending releases animation protection', (tester) async {
      var enabled = true;
      var ticking = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return TickerMode(
                  enabled: ticking,
                  child: Center(
                    child: SizedBox(
                      width: 260,
                      height: 96,
                      child: SwipeRevealCard(
                        enabled: enabled,
                        shape: const RoundedRectangleBorder(),
                        actionLabel: 'Remove',
                        removeTooltip: 'Remove',
                        onRemove: () {},
                        child: const Text('Swipe target'),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Swipe target')),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await gesture.moveBy(const Offset(-40, 0));
      expect(coordinator.isInteracting, isTrue);
      if (ending == 'cancel') {
        await gesture.cancel();
      } else if (ending == 'dispose') {
        await tester.pumpWidget(const SizedBox());
        await gesture.cancel();
      } else {
        update(() {
          if (ending == 'hide') ticking = false;
          if (ending == 'disable') enabled = false;
        });
        await tester.pump();
        await gesture.cancel();
      }
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
      expect(coordinator.isInteracting, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reduced motion settles swipe immediately', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                height: 96,
                child: SwipeRevealCard(
                  shape: const RoundedRectangleBorder(),
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () {},
                  child: const Text('Swipe target'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.text('Swipe target'), const Offset(-180, 0));
    await tester.pump();
    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.byType(TweenAnimationBuilder<double>),
          )
          .duration,
      Duration.zero,
    );
    await tester.pump(coordinator.idleDelay);
    expect(coordinator.isInteracting, isFalse);
  });

  testWidgets(
    'Windows context menu reuses all actions without triggering tap',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 100,
                child: SwipeRevealCard(
                  shape: const RoundedRectangleBorder(),
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () => calls.add('Remove'),
                  onSecondaryAction: () => calls.add('Details'),
                  secondaryActionLabel: 'Details',
                  onTertiaryAction: () => calls.add('Download'),
                  tertiaryActionLabel: 'Download',
                  onLeadingAction: () => calls.add('Pin'),
                  leadingActionLabel: 'Pin',
                  child: InkWell(
                    onTap: () => calls.add('Play'),
                    child: const Center(child: Text('Track')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(SwipeRevealCard);
      final originalPosition = tester.getTopLeft(find.text('Track'));
      await tester.drag(card, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Track')), originalPosition);
      expect(find.byType(IconButton), findsNothing);
      for (final label in ['Pin', 'Download', 'Details', 'Remove']) {
        final click = await tester.startGesture(
          tester.getCenter(card),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await click.up();
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<VoidCallback>), findsNWidgets(4));
        final item = tester.widget<PopupMenuItem<VoidCallback>>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(PopupMenuItem<VoidCallback>),
          ),
        );
        expect(item.height, 40);
        final iconContext = tester.element(
          find.descendant(
            of: find.ancestor(
              of: find.text(label),
              matching: find.byType(PopupMenuItem<VoidCallback>),
            ),
            matching: find.byType(Icon),
          ),
        );
        final colors = Theme.of(iconContext).colorScheme;
        expect(
          IconTheme.of(iconContext).color,
          label == 'Remove' ? colors.error : colors.primary,
        );
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(calls, ['Pin', 'Download', 'Details', 'Remove']);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('Windows disabled card never opens a context menu', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeRevealCard(
            enabled: false,
            shape: const RoundedRectangleBorder(),
            actionLabel: 'Remove',
            removeTooltip: 'Remove',
            onRemove: () => fail('Disabled action executed'),
            child: const SizedBox(width: 300, height: 100),
          ),
        ),
      ),
    );
    final click = await tester.startGesture(
      tester.getCenter(find.byType(SwipeRevealCard)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await click.up();
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('default reveal colors follow the active color scheme', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme, useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 260,
              height: 96,
              child: SwipeRevealCard(
                shape: shape,
                actionLabel: 'Details',
                removeTooltip: 'Details',
                destructive: false,
                onRemove: () {},
                child: const SizedBox.expand(child: Text('Themed card')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Themed card'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    final revealPane = tester.widget<DecoratedBox>(
      find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return decoration is ShapeDecoration && decoration.gradient != null;
      }),
    );
    final decoration = revealPane.decoration as ShapeDecoration;
    expect(decoration.gradient!.colors.last, scheme.primary);
  });

  testWidgets(
    'default destructive reveal colors stay consistent in dark mode',
    (tester) async {
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      );
      final lightScheme = ThemeAccentPreset.rose.colorScheme(Brightness.light);
      final darkScheme = ThemeAccentPreset.rose.colorScheme(Brightness.dark);

      Future<Color> revealColor(ThemeData theme) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  height: 96,
                  child: SwipeRevealCard(
                    shape: shape,
                    actionLabel: 'Remove',
                    removeTooltip: 'Remove',
                    onRemove: () {},
                    child: const SizedBox.expand(
                      child: Text('Destructive card'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.drag(find.byType(SwipeRevealCard), const Offset(-180, 0));
        await tester.pumpAndSettle();
        final revealPane = tester.widget<DecoratedBox>(
          find.byWidgetPredicate((widget) {
            if (widget is! DecoratedBox) return false;
            final decoration = widget.decoration;
            return decoration is ShapeDecoration && decoration.gradient != null;
          }),
        );
        return (revealPane.decoration as ShapeDecoration).gradient!.colors.last;
      }

      final lightRevealColor = await revealColor(
        ThemeData(colorScheme: lightScheme, useMaterial3: true),
      );
      final darkRevealColor = await revealColor(
        ThemeData(colorScheme: darkScheme, useMaterial3: true),
      );

      expect(lightRevealColor, lightScheme.error);
      expect(darkRevealColor, lightRevealColor);
    },
  );

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

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'closed card keeps its subtree when TickerMode changes on $platform',
      (tester) async {
        final ticking = ValueNotifier<bool>(true);
        addTearDown(ticking.dispose);
        await tester.pumpWidget(_tickerCard(ticking));
        final gesture = find.descendant(
          of: find.byType(SwipeRevealCard),
          matching: find.byType(GestureDetector),
        );
        final original = tester.widget<GestureDetector>(gesture);
        for (var i = 0; i < 3; i++) {
          ticking.value = false;
          await tester.pump();
          ticking.value = true;
          await tester.pump();
        }
        expect(tester.widget<GestureDetector>(gesture), same(original));
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final phase in ['opening', 'open', 'closing']) {
    testWidgets('inactive page closes a revealed card during $phase', (
      tester,
    ) async {
      final ticking = ValueNotifier<bool>(true);
      addTearDown(ticking.dispose);
      await tester.pumpWidget(_tickerCard(ticking));
      await tester.drag(find.text('Swipe target'), const Offset(-180, 0));
      if (phase != 'opening') {
        await tester.pumpAndSettle();
      }
      if (phase == 'closing') {
        await tester.tapAt(tester.getCenter(find.byType(SwipeRevealCard)));
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
      ticking.value = false;
      await tester.pump();
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(coordinator.isInteracting, isFalse);
      ticking.value = true;
      await tester.pump();
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('reveal pane matches card bounds without a second border', (
    tester,
  ) async {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: Colors.red, width: 2),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              height: 148,
              child: SwipeRevealCard(
                shape: shape,
                actionLabel: 'Remove',
                removeTooltip: 'Remove',
                onRemove: () {},
                child: const SizedBox.expand(child: Text('Library card')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Library card'), const Offset(-180, 0));
    await tester.pumpAndSettle();
    final revealPane = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      return decoration is ShapeDecoration && decoration.gradient != null;
    });
    final closedSurface = find.descendant(
      of: find.byType(SwipeRevealCard),
      matching: find.byWidgetPredicate((widget) => widget is ColoredBox),
    );
    expect(revealPane, findsOneWidget);
    final decoration = tester.widget<DecoratedBox>(revealPane).decoration;
    final revealShape = (decoration as ShapeDecoration).shape;

    expect(revealShape, isA<RoundedRectangleBorder>());
    expect((revealShape as RoundedRectangleBorder).side, BorderSide.none);
    expect(tester.getSize(revealPane), tester.getSize(closedSurface.first));
  });

  for (final direction in [-1.0, 1.0]) {
    testWidgets('playlist closing paints no opposite underlayer ($direction)', (
      tester,
    ) async {
      const captureKey = ValueKey('playlist_swipe_capture');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: RepaintBoundary(
                key: captureKey,
                child: SizedBox(
                  width: 260,
                  height: playlistRowHeight,
                  child: SwipeRevealCard(
                    shape: playlistRowShape,
                    color: Colors.red,
                    closedColor: Colors.white,
                    actionLabel: 'Remove',
                    removeTooltip: 'Remove',
                    onRemove: () {},
                    onLeadingAction: () {},
                    leadingActionLabel: 'Pin',
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(SwipeRevealCard);
      await tester.drag(card, Offset(direction * 180, 0));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(card));
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final redPixels = await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData())!;
            var count = 0;
            final start = direction > 0 ? image.width ~/ 2 : 0;
            final end = direction > 0 ? image.width : image.width ~/ 2;
            for (var y = 0; y < image.height; y++) {
              for (var x = start; x < end; x++) {
                final offset = (y * image.width + x) * 4;
                if (bytes.getUint8(offset) > bytes.getUint8(offset + 1) + 20) {
                  count++;
                }
              }
            }
            return count;
          } finally {
            image.dispose();
          }
        });
        expect(redPixels, 0, reason: 'Opposite underlayer at frame $frame');
      }
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    });

    testWidgets('closing swipe stays on its original side ($direction)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                height: 96,
                child: SwipeRevealCard(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () {},
                  onLeadingAction: () {},
                  leadingActionLabel: 'Pin',
                  leadingActionTooltip: 'Pin',
                  child: const SizedBox.expand(
                    key: ValueKey('bounded_swipe_content'),
                    child: Text('Swipe target'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final card = find.byType(SwipeRevealCard);
      final content = find.byKey(const ValueKey('bounded_swipe_content'));
      final closedLeft = tester.getTopLeft(content).dx;
      final center = tester.getCenter(card);
      await tester.dragFrom(center, Offset(direction * 180, 0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(content).dx - closedLeft, direction * 72);

      await tester.dragFrom(center, Offset(-direction * 180, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(-direction * 180, 0));
      await tester.pump();
      for (var frame = 0; frame < 16; frame++) {
        final distance =
            (tester.getTopLeft(content).dx - closedLeft) * direction;
        expect(distance, inInclusiveRange(0.0, 72.0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Reversing the same gesture after reaching zero keeps its original side.
      await gesture.moveBy(Offset(direction * 400, 0));
      await tester.pump();
      for (var frame = 0; frame < 16; frame++) {
        final distance =
            (tester.getTopLeft(content).dx - closedLeft) * direction;
        expect(distance, inInclusiveRange(0.0, 72.0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.getTopLeft(content).dx - closedLeft, direction * 72);
      await gesture.moveBy(Offset(-direction * 400, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(content).dx, closedLeft);
    });
  }

  testWidgets('leading action reveals on a right swipe', (tester) async {
    var downloads = 0;
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
                actionLabel: 'Favorite',
                removeTooltip: 'Favorite',
                onRemove: () {},
                leadingActionLabel: 'Download',
                leadingActionTooltip: 'Download',
                onLeadingAction: () => downloads++,
                child: const SizedBox.expand(child: Text('Downloadable card')),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Downloadable card'), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Download'), findsOneWidget);
    expect(find.byIcon(Icons.swipe_right_rounded), findsNothing);

    await tester.tap(find.byTooltip('Download'));
    await tester.pump();
    expect(downloads, 1);
  });

  testWidgets(
    'opposite swipe closes a leading action without revealing trailing actions',
    (tester) async {
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
                  actionLabel: 'Favorite',
                  removeTooltip: 'Favorite',
                  onRemove: () {},
                  leadingActionLabel: 'Download',
                  leadingActionTooltip: 'Download',
                  onLeadingAction: () {},
                  child: const SizedBox.expand(child: Text('Swipe target')),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.drag(find.text('Swipe target'), const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Download'), findsOneWidget);

      await tester.drag(find.text('Swipe target'), const Offset(-180, 0));
      await tester.pump();
      expect(find.byIcon(Icons.swipe_left_rounded), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
      expect(find.text('Swipe target'), findsOneWidget);
    },
  );

  testWidgets(
    'vertical actions reveal Info on top and Download below on right swipe, Pin on top and Remove below on left swipe',
    (tester) async {
      final calls = <String>[];
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 120,
                child: SwipeRevealCard(
                  shape: shape,
                  verticalActions: true,
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () => calls.add('Remove'),
                  onSecondaryAction: () => calls.add('Pin'),
                  secondaryActionLabel: 'Pin',
                  secondaryActionTooltip: 'Pin',
                  secondaryActionIcon: Icons.push_pin_rounded,
                  onLeadingAction: () => calls.add('Info'),
                  leadingActionLabel: 'Info',
                  leadingActionTooltip: 'Info',
                  leadingActionIcon: Icons.info_outline_rounded,
                  onSecondaryLeadingAction: () => calls.add('Download'),
                  secondaryLeadingActionLabel: 'Download',
                  secondaryLeadingActionTooltip: 'Download',
                  child: const SizedBox.expand(child: Text('Card Content')),
                ),
              ),
            ),
          ),
        ),
      );

      // Right swipe reveals left actions (Info on top, Download below)
      await tester.drag(find.text('Card Content'), const Offset(200, 0));
      await tester.pumpAndSettle();

      final infoBtn = find.byTooltip('Info');
      final downloadBtn = find.byTooltip('Download');
      expect(infoBtn, findsOneWidget);
      expect(downloadBtn, findsOneWidget);

      final infoRect = tester.getRect(infoBtn);
      final downloadRect = tester.getRect(downloadBtn);
      expect(infoRect.bottom, lessThanOrEqualTo(downloadRect.top));

      await tester.tap(downloadBtn);
      await tester.pumpAndSettle();
      expect(calls, ['Download']);

      // Left swipe reveals right actions (Pin on top, Remove below)
      await tester.drag(find.text('Card Content'), const Offset(-200, 0));
      await tester.pumpAndSettle();

      final pinBtn = find.byTooltip('Pin');
      final removeBtn = find.byTooltip('Remove');
      expect(pinBtn, findsOneWidget);
      expect(removeBtn, findsOneWidget);

      final pinRect = tester.getRect(pinBtn);
      final removeRect = tester.getRect(removeBtn);
      expect(pinRect.bottom, lessThanOrEqualTo(removeRect.top));

      await tester.tap(pinBtn);
      await tester.pumpAndSettle();
      expect(calls, ['Download', 'Pin']);
    },
  );

  testWidgets(
    'Windows context menu shows Info, Download, Pin, Remove in order',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 100,
                child: SwipeRevealCard(
                  shape: const RoundedRectangleBorder(),
                  verticalActions: true,
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () => calls.add('Remove'),
                  onSecondaryAction: () => calls.add('Pin'),
                  secondaryActionLabel: 'Pin',
                  onLeadingAction: () => calls.add('Info'),
                  leadingActionLabel: 'Info',
                  onSecondaryLeadingAction: () => calls.add('Download'),
                  secondaryLeadingActionLabel: 'Download',
                  child: const Center(child: Text('Windows Card')),
                ),
              ),
            ),
          ),
        ),
      );

      final card = find.byType(SwipeRevealCard);
      for (final label in ['Info', 'Download', 'Pin', 'Remove']) {
        final click = await tester.startGesture(
          tester.getCenter(card),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await click.up();
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<VoidCallback>), findsNWidgets(4));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(calls, ['Info', 'Download', 'Pin', 'Remove']);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

Widget _tickerCard(ValueNotifier<bool> ticking) => MaterialApp(
  home: Scaffold(
    body: ValueListenableBuilder<bool>(
      valueListenable: ticking,
      builder: (_, enabled, child) =>
          TickerMode(enabled: enabled, child: child!),
      child: Center(
        child: SizedBox(
          width: 260,
          height: 96,
          child: SwipeRevealCard(
            shape: const RoundedRectangleBorder(),
            actionLabel: 'Remove',
            removeTooltip: 'Remove',
            onRemove: () {},
            child: const SizedBox.expand(child: Text('Swipe target')),
          ),
        ),
      ),
    ),
  ),
);
