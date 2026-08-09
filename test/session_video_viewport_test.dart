import 'dart:async';

import 'package:flutter/material.dart';
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

        expect(visibleRect, const Rect.fromLTRB(24, 0, 776, 336));
        expect(hiddenRect, const Rect.fromLTRB(24, 0, 776, 400));
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
    required Future<void> Function() onFullscreen,
    Duration controlsTimeout = const Duration(seconds: 3),
    bool isFullscreen = false,
  }) {
    return MaterialApp(
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
          onFullscreen: onFullscreen,
          fullscreenTooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
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

    expect(
      find.byKey(const ValueKey<String>('session_video_blurred_backdrop')),
      findsOneWidget,
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
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
}
