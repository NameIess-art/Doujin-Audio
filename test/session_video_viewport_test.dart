import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/presentation/session_video_viewport.dart';

void main() {
  group('fullscreen video gesture math', () {
    test(
      'blank tap hides visible controls and inactivity ignores play state',
      () {
        expect(sessionVideoControlsVisibleAfterBlankTap(true), isFalse);
        expect(sessionVideoControlsVisibleAfterBlankTap(false), isTrue);
        expect(
          sessionVideoShouldAutoHideControls(
            controlsVisible: true,
            controlsInteracting: false,
          ),
          isTrue,
        );
        expect(
          sessionVideoShouldAutoHideControls(
            controlsVisible: true,
            controlsInteracting: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'visible bottom controls are excluded from the screen gesture area',
      () {
        final visibleRect = sessionVideoFullscreenGestureRect(
          viewportSize: const Size(800, 400),
          controlsVisible: true,
        );
        final hiddenRect = sessionVideoFullscreenGestureRect(
          viewportSize: const Size(800, 400),
          controlsVisible: false,
        );

        expect(visibleRect, const Rect.fromLTRB(24, 0, 776, 272));
        expect(hiddenRect, const Rect.fromLTRB(24, 0, 776, 400));
        expect(
          sessionVideoFullscreenGestureRect(
            viewportSize: const Size(800, 400),
            controlsVisible: true,
            controlBarHeight: sessionVideoFullscreenControlBarHeight + 34,
          ),
          const Rect.fromLTRB(24, 0, 776, 238),
        );
      },
    );

    test('horizontal drag uses ninety seconds per viewport width', () {
      expect(
        sessionVideoHorizontalSeekTarget(
          startPosition: const Duration(minutes: 10),
          duration: const Duration(hours: 1),
          dragDx: 200,
          viewportWidth: 400,
        ),
        const Duration(minutes: 10, seconds: 45),
      );
      expect(
        sessionVideoHorizontalSeekTarget(
          startPosition: const Duration(seconds: 10),
          duration: const Duration(minutes: 1),
          dragDx: -400,
          viewportWidth: 400,
        ),
        Duration.zero,
      );
    });

    test('vertical drag and skip targets clamp to valid ranges', () {
      expect(
        sessionVideoVerticalGestureValue(
          startValue: 0.5,
          dragDy: -100,
          viewportHeight: 400,
          minimum: 0.05,
          maximum: 1,
        ),
        closeTo(0.7375, 0.0001),
      );
      expect(
        sessionVideoSkipTarget(
          position: const Duration(seconds: 58),
          duration: const Duration(minutes: 1),
          delta: const Duration(seconds: 5),
        ),
        const Duration(minutes: 1),
      );
      expect(sessionVideoGestureZone(99, 400), SessionVideoGestureZone.left);
      expect(sessionVideoGestureZone(100, 400), SessionVideoGestureZone.center);
      expect(sessionVideoGestureZone(299, 400), SessionVideoGestureZone.center);
      expect(sessionVideoGestureZone(300, 400), SessionVideoGestureZone.right);
      expect(
        sessionVideoVerticalGestureSide(199, 400),
        SessionVideoVerticalGestureSide.left,
      );
      expect(
        sessionVideoVerticalGestureSide(200, 400),
        SessionVideoVerticalGestureSide.right,
      );
    });

    test('unknown duration never rewinds an active video to zero', () {
      expect(
        sessionVideoHorizontalSeekTarget(
          startPosition: const Duration(seconds: 37),
          duration: Duration.zero,
          dragDx: 300,
          viewportWidth: 400,
        ),
        const Duration(seconds: 37),
      );
      expect(
        sessionVideoSkipTarget(
          position: const Duration(seconds: 37),
          duration: Duration.zero,
          delta: const Duration(seconds: 5),
        ),
        const Duration(seconds: 37),
      );
    });
  });

  Widget buildViewport({
    required bool videoReady,
    Future<void> Function()? onFullscreen,
    SessionVideoFullscreenCallback? onFullscreenHandoff,
    Duration controlsTimeout = const Duration(seconds: 3),
    bool isFullscreen = false,
    bool showTooltips = true,
  }) {
    return MaterialApp(
      builder: (_, child) =>
          TooltipVisibility(visible: showTooltips, child: child!),
      home: SizedBox.square(
        dimension: 320,
        child: SessionVideoViewport(
          poster: const ColoredBox(
            key: ValueKey<String>('poster'),
            color: Colors.blue,
          ),
          videoReady: videoReady,
          surfaceBuilder: (_) => const ColoredBox(
            key: ValueKey<String>('fake_video_surface'),
            color: Colors.black,
          ),
          onFullscreen:
              onFullscreenHandoff ??
              (handoff) async {
                if (!handoff.borrowSurface()) return;
                try {
                  if (onFullscreen != null) await onFullscreen();
                } finally {
                  handoff.restoreSurface();
                }
              },
          fullscreenTooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
          controlsLabel: 'Video controls',
          controlsTimeout: controlsTimeout,
          isFullscreen: isFullscreen,
        ),
      ),
    );
  }

  testWidgets('unprepared video keeps poster and has no controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildViewport(videoReady: false, onFullscreen: () async {}),
    );

    expect(find.byKey(const ValueKey<String>('poster')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fake_video_surface')),
      findsNothing,
    );
    expect(find.byIcon(Icons.fullscreen_rounded), findsNothing);
  });

  testWidgets('blurred backdrop remains visible before video is ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox.square(
          dimension: 320,
          child: SessionVideoBlurredBackdrop(
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    );

    final backdrop = find.byKey(
      const ValueKey<String>('session_video_blurred_backdrop'),
    );
    expect(tester.widget(backdrop), isA<RepaintBoundary>());
    expect(
      find.descendant(of: backdrop, matching: find.byType(ImageFiltered)),
      findsOneWidget,
    );
  });

  testWidgets('tap reveals controls and timeout hides them', (tester) async {
    await tester.pumpWidget(
      buildViewport(videoReady: true, onFullscreen: () async {}),
    );

    IgnorePointer pointer() => tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('session_video_fullscreen_control'),
        ),
        matching: find.byType(IgnorePointer),
      ),
    );

    expect(pointer().ignoring, isTrue);
    await tester.tap(
      find.byKey(const ValueKey<String>('session_video_tap_target')),
    );
    await tester.pump();
    expect(pointer().ignoring, isFalse);
    final viewport = tester.getRect(find.byType(SessionVideoViewport));
    final fullscreen = tester.getRect(find.byTooltip('Fullscreen'));
    expect(fullscreen.topRight, viewport.topRight + const Offset(-12, 12));
    expect(fullscreen.size, const Size.square(48));
    final icon = find.byIcon(Icons.fullscreen_rounded);
    expect(IconTheme.of(tester.element(icon)).size, 32);

    await tester.pump(const Duration(seconds: 3));
    expect(pointer().ignoring, isTrue);
  });

  testWidgets('fullscreen action removes surface until route returns', (
    tester,
  ) async {
    final routeCompleter = Completer<void>();
    await tester.pumpWidget(
      buildViewport(
        videoReady: true,
        onFullscreen: () => routeCompleter.future,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('session_video_tap_target')),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('fake_video_surface')),
      findsNothing,
    );

    routeCompleter.complete();
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('fake_video_surface')),
      findsOneWidget,
    );
  });

  testWidgets(
    'keyboard reveals inline video controls before activating fullscreen',
    (tester) async {
      var fullscreenRequests = 0;
      await tester.pumpWidget(
        buildViewport(
          videoReady: true,
          showTooltips: defaultTargetPlatform != TargetPlatform.windows,
          onFullscreen: () async {
            fullscreenRequests++;
          },
        ),
      );

      final controls = find.byKey(
        const ValueKey<String>('session_video_fullscreen_control'),
      );
      final fullscreenSemantics = find.semantics.byPredicate(
        (node) =>
            node.label == 'Fullscreen' ||
            node.getSemanticsData().tooltip == 'Fullscreen',
      );
      expect(find.semantics.byLabel('Video controls'), findsOne);
      expect(fullscreenSemantics, findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
      expect(fullscreenSemantics, findsOne);
      expect(fullscreenRequests, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(tester.widget<AnimatedOpacity>(controls).opacity, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fullscreenRequests, 1);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets('track loading during fullscreen keeps inline surface suspended', (
    tester,
  ) async {
    final fullscreen = Completer<void>();
    Future<void> openFullscreen() => fullscreen.future;
    await tester.pumpWidget(
      buildViewport(videoReady: true, onFullscreen: openFullscreen),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('session_video_tap_target')),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pump();

    await tester.pumpWidget(
      buildViewport(videoReady: false, onFullscreen: openFullscreen),
    );
    await tester.pumpWidget(
      buildViewport(videoReady: true, onFullscreen: openFullscreen),
    );
    expect(
      find.byKey(const ValueKey<String>('fake_video_surface')),
      findsNothing,
    );

    fullscreen.complete();
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('fake_video_surface')),
      findsOneWidget,
    );
  });

  testWidgets('fullscreen mode uses exit icon', (tester) async {
    await tester.pumpWidget(
      buildViewport(
        videoReady: true,
        isFullscreen: true,
        onFullscreen: () async {},
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('session_video_tap_target')),
    );
    await tester.pump();

    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
  });

  testWidgets('hover over video reveals fullscreen button and exit hides it', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildViewport(videoReady: true, onFullscreen: () async {}),
    );

    IgnorePointer pointer() => tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('session_video_fullscreen_control'),
        ),
        matching: find.byType(IgnorePointer),
      ),
    );

    expect(pointer().ignoring, isTrue);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    final posterRect = tester.getRect(
      find.byKey(const ValueKey<String>('poster')),
    );
    await gesture.moveTo(posterRect.center);
    await tester.pumpAndSettle();
    expect(pointer().ignoring, isFalse);

    await gesture.moveTo(posterRect.bottomRight + const Offset(50, 50));
    await tester.pumpAndSettle();
    expect(pointer().ignoring, isTrue);

    await gesture.moveTo(posterRect.center);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await gesture.moveTo(posterRect.bottomRight + const Offset(50, 50));
    await tester.pump(const Duration(seconds: 4));
    expect(pointer().ignoring, isFalse);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(pointer().ignoring, isTrue);
  });

  testWidgets(
    'inline surface stays opaque without remounting and keeps rendering until handoff borrows it',
    (tester) async {
      var preparationGate = Completer<void>();
      var borrowed = false;
      final routeGate = Completer<void>();

      await tester.pumpWidget(
        buildViewport(
          videoReady: true,
          onFullscreenHandoff: (handoff) async {
            await preparationGate.future;
            borrowed = handoff.borrowSurface();
            if (!borrowed) return;
            try {
              await routeGate.future;
            } finally {
              handoff.restoreSurface();
            }
          },
        ),
      );
      final initialSurfaceElement = tester.element(
        find.byKey(const ValueKey<String>('fake_video_surface')),
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey<String>('fake_video_surface')),
          matching: find.byWidgetPredicate(
            (widget) => widget is Opacity && widget.opacity < 1,
          ),
        ),
        findsNothing,
      );

      // Advance past the former 220ms fade window: the surface element must not
      // be unmounted and recreated.
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester.element(
          find.byKey(const ValueKey<String>('fake_video_surface')),
        ),
        same(initialSurfaceElement),
      );

      // While async fullscreen setup is still running, inline video remains visible.
      await tester.tap(
        find.byKey(const ValueKey<String>('session_video_tap_target')),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('fake_video_surface')),
        findsOneWidget,
      );
      expect(
        tester.element(
          find.byKey(const ValueKey<String>('fake_video_surface')),
        ),
        same(initialSurfaceElement),
      );

      // Once setup finishes, borrowing detaches the inline surface in the push turn.
      preparationGate.complete();
      await tester.pump();
      expect(borrowed, isTrue);
      expect(
        find.byKey(const ValueKey<String>('fake_video_surface')),
        findsNothing,
      );

      routeGate.complete();
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('fake_video_surface')),
        findsOneWidget,
      );

      // Case 1: unmounted before async setup finishes -> borrowSurface returns false.
      preparationGate = Completer<void>();
      borrowed = true;
      await tester.tap(
        find.byKey(const ValueKey<String>('session_video_tap_target')),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pumpWidget(const SizedBox.shrink());
      preparationGate.complete();
      await tester.pump();
      expect(borrowed, isFalse);

      // Case 2: videoReady clears before async setup finishes -> borrowSurface returns false.
      preparationGate = Completer<void>();
      borrowed = true;
      Future<void> abortingHandoff(SessionVideoFullscreenHandoff handoff) async {
        await preparationGate.future;
        borrowed = handoff.borrowSurface();
      }

      await tester.pumpWidget(
        buildViewport(videoReady: true, onFullscreenHandoff: abortingHandoff),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('session_video_tap_target')),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pumpWidget(
        buildViewport(videoReady: false, onFullscreenHandoff: abortingHandoff),
      );
      preparationGate.complete();
      await tester.pump();
      expect(borrowed, isFalse);

      // Surface recovers cleanly once videoReady becomes true again.
      await tester.pumpWidget(
        buildViewport(videoReady: true, onFullscreenHandoff: abortingHandoff),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('fake_video_surface')),
        findsOneWidget,
      );
    },
  );
}
