import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_speed_controls.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_panel.dart';
import 'package:doujin_audio/features/player/presentation/timer_tab.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  group('Windows mouse wheel single-line scrolling', () {
    testWidgets(
      'TimerTab duration picker scrolls exactly 1 unit per wheel event on Windows',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          final fixture = AppRuntimeWidgetTestFixture();
          addTearDown(fixture.dispose);

          await tester.pumpWidget(
            fixture.build(
              const TimerTab(
                showHeader: false,
                useSafeArea: false,
                compactOnly: true,
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Find the 3 wheel pickers: hours, minutes, seconds
          final wheels = find.byType(ListWheelScrollView);
          expect(wheels, findsNWidgets(3));
          final minutesWheel = wheels.at(1);
          final controller = tester.widget<ListWheelScrollView>(minutesWheel).controller! as FixedExtentScrollController;
          final initialItem = controller.selectedItem;

          final wheelLocation = tester.getCenter(minutesWheel);
          final pointer = TestPointer(1, PointerDeviceKind.mouse);
          pointer.hover(wheelLocation);

          // A typical Windows mouse wheel notch has dy = 100
          // On Windows, it must only scroll exactly +1 item
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, 100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(controller.selectedItem, initialItem + 1);

          // Scroll again
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, 100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(controller.selectedItem, initialItem + 2);

          // Reverse wheel
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, -100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(controller.selectedItem, initialItem + 1);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'SpeedWheelPage scrolls exactly 1 speed step per wheel event on Windows',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              nativePlaybackChannel,
              (_) async => <String, Object?>{'ok': true, 'value': null},
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              notificationsChannel,
              (_) async => <String, Object?>{'ok': true, 'value': null},
            );
        try {
          final fixture = AppRuntimeWidgetTestFixture();
          addTearDown(() {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(nativePlaybackChannel, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(notificationsChannel, null);
            fixture.dispose();
          });

          final session = PlaybackSession(
            id: 'test-session',
            currentTrackPath: '/track.mp3',
            loopMode: SessionLoopMode.single,
            nonSingleLoopMode: SessionLoopMode.single,
            volume: 1,
            createdAt: DateTime(2026),
            state: const PlayerState(false, ProcessingState.ready),
          )..speed = 1.0;

          fixture.playbackService.registerSession(session);
          fixture.playbackService.syncSlice(
            activeSessions: [session],
            playingSessionCount: 0,
            focusedSessionId: session.id,
            multiThreadPlaybackEnabled: false,
            coverGeneration: 1,
            isInitialized: true,
          );

          final snapshot = fixture.runtimeGraph.playback.sessionSnapshotById(session.id)!;

          await tester.pumpWidget(
            fixture.build(
              SizedBox(
                width: 300,
                height: 400,
                child: SpeedWheelPage(
                  session: snapshot,
                  playback: fixture.runtimeGraph.playback,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final wheelFinder = find.byKey(const ValueKey('playback_speed_wheel'));
          expect(wheelFinder, findsOneWidget);

          FixedExtentScrollController currentController() =>
              tester.widget<ListWheelScrollView>(wheelFinder).controller! as FixedExtentScrollController;

          // 1.0x is at index 3 in [0.25, 0.5, 0.75, 1.0, 1.25, ...]
          expect(currentController().selectedItem, 3);

          final wheelLocation = tester.getCenter(wheelFinder);
          final pointer = TestPointer(1, PointerDeviceKind.mouse);
          pointer.hover(wheelLocation);

          // 1 wheel notch down (dy = 100) advances by exactly 1 step to index 4 (1.25x)
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, 100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(currentController().selectedItem, 4); // 1.25x

          // Scroll again -> index 5 (1.5x)
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, 100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(currentController().selectedItem, 5); // 1.5x

          // Reverse wheel -> index 4 (1.25x)
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, -100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));

          expect(currentController().selectedItem, 4); // 1.25x

          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'SessionSubtitlePanel timeline scrolls exactly 1 cue line per wheel event on Windows',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          final fixture = AppRuntimeWidgetTestFixture(
            configureSettingsRepository: (settings) {
              settings.playbackDetailSubtitleStyle = PlaybackDetailSubtitleStyle.timeline;
              settings.syncSlice(isInitialized: true);
            },
          );
          addTearDown(fixture.dispose);

          final cues = List.generate(
            10,
            (i) => SubtitleCue(
              start: Duration(seconds: i * 10),
              end: Duration(seconds: i * 10 + 5),
              text: 'Subtitle cue line $i',
            ),
          );

          final track = MusicTrack(
            path: '/library/track.mp3',
            displayName: 'Test track',
            groupKey: '/library',
            groupTitle: 'Album',
            groupSubtitle: '/library',
            isSingle: true,
          );
          final subtitleTrack = SubtitleTrack(
            sourcePath: '/library/track.srt',
            cues: cues,
          );
          final subtitleService = PlaybackSubtitleService(
            trackResolver: (_) => track,
            subtitleLoader: (_, _) async => subtitleTrack,
          );
          await subtitleService.load(track.path);

          final session = PlaybackSession(
            id: 'test-session',
            currentTrackPath: track.path,
            loopMode: SessionLoopMode.single,
            nonSingleLoopMode: SessionLoopMode.single,
            volume: 1,
            createdAt: DateTime(2026),
            state: const PlayerState(false, ProcessingState.ready),
          );
          fixture.playbackService.registerSession(session);
          fixture.playbackService.syncSlice(
            activeSessions: [session],
            playingSessionCount: 0,
            focusedSessionId: session.id,
            multiThreadPlaybackEnabled: false,
            coverGeneration: 1,
            isInitialized: true,
          );
          final snapshot = fixture.runtimeGraph.playback.sessionSnapshotById(session.id)!;

          await tester.pumpWidget(
            fixture.build(
              SizedBox(
                width: 400,
                height: 300,
                child: SessionSubtitlePanel(
                  session: snapshot,
                ),
              ),
              subtitleService: subtitleService,
            ),
          );
          await tester.pumpAndSettle();

          final listFinder = find.byKey(const ValueKey('subtitle_timeline_list'));
          expect(listFinder, findsOneWidget);

          final timelineView = find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_TimelineSubtitleView',
          );
          final dynamic state = tester.state(timelineView);
          expect(state.debugFocusedIndex, 0);

          final scrollLocation = tester.getCenter(listFinder);
          final pointer = TestPointer(1, PointerDeviceKind.mouse);
          pointer.hover(scrollLocation);

          // A single wheel notch down (dy = 100) on Windows should advance exactly 1 line
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, 100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(state.debugFocusedIndex, 1);

          // Another wheel notch down -> cue 2
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, 100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(state.debugFocusedIndex, 2);

          // Wheel notch up -> cue 1
          tester.binding.handlePointerEvent(
            pointer.scroll(const Offset(0, -100)),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));

          expect(state.debugFocusedIndex, 1);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
