import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/presentation/session_video_viewport.dart';

void main() {
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
