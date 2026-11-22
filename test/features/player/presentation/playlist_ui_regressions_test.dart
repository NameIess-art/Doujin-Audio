import 'dart:io';

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/bedtime_canvas_page.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_audio_features.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_list_view.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_progress_widgets.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_panel.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_transport_controls.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_video_widgets.dart';
import 'package:doujin_audio/features/player/presentation/session_video_surface.dart';
import 'package:doujin_audio/features/player/presentation/timer_tab.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  group('TimelineSubtitleView empty cues (#48)', () {
    testWidgets(
      'mounts with empty cues and transitions non-empty -> empty -> non-empty cleanly',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        await tester.pumpWidget(
          fixture.build(
            TimelineSubtitleView(
              cues: const <SubtitleCue>[],
              playbackSubtitleIndex: 0,
              onSeek: (_) async {},
            ),
          ),
        );
        expect(find.byKey(const ValueKey('subtitle_empty')), findsOneWidget);

        final populated = [
          const SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'Line 1',
          ),
          const SubtitleCue(
            start: Duration(seconds: 4),
            end: Duration(seconds: 6),
            text: 'Line 2',
          ),
        ];
        await tester.pumpWidget(
          fixture.build(
            TimelineSubtitleView(
              cues: populated,
              playbackSubtitleIndex: 1,
              onSeek: (_) async {},
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('subtitle_timeline_text_1')),
          findsOneWidget,
        );

        await tester.pumpWidget(
          fixture.build(
            TimelineSubtitleView(
              cues: const <SubtitleCue>[],
              playbackSubtitleIndex: 1,
              onSeek: (_) async {},
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('subtitle_empty')), findsOneWidget);
      },
    );
  });

  group('SessionSubtitlePanel unordered cues (#22)', () {
    testWidgets('displays and highlights out-of-order ASS cues in time order', (
      tester,
    ) async {
      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('subtitle_panel_'),
      );
      addTearDown(() async {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final audioFile = File('${tempDir!.path}/sample.mp3');
      final assFile = File('${tempDir.path}/sample.ass');
      await tester.runAsync(() async {
        await audioFile.writeAsBytes(const <int>[0]);
        await assFile.writeAsString('''
[Script Info]
ScriptType: v4.00+

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:30.00,0:00:35.00,Title,,0,0,0,,Late sign
Dialogue: 0,0:00:02.00,0:00:05.00,Default,,0,0,0,,Early line
Dialogue: 0,0:00:10.00,0:00:14.00,Default,,0,0,0,,Middle line
''');
      });

      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final track = testMusicTrack(
        name: 'Sample',
        path: audioFile.path,
        groupKey: tempDir.path,
        groupTitle: 'Folder',
      );
      fixture.library.addTracks([track], persist: false);
      final subtitleService = PlaybackSubtitleService(
        trackResolver: fixture.library.trackByPath,
      );
      addTearDown(subtitleService.dispose);
      final session = fixture.playback.createTrackSession(track)
        ..lastKnownPosition = const Duration(seconds: 12);
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.runAsync(() => subtitleService.load(audioFile.path));
      await tester.pumpWidget(
        fixture.build(
          SizedBox(
            width: 360,
            height: 260,
            child: SessionSubtitlePanel(
              session: fixture.playback.sessionSnapshotById(session.id)!,
            ),
          ),
          subtitleService: subtitleService,
        ),
      );
      await tester.pumpAndSettle();

      final timeline = tester.widget<TimelineSubtitleView>(
        find.byType(TimelineSubtitleView),
      );
      expect(timeline.cues.map((cue) => cue.text).toList(), [
        'Early line',
        'Middle line',
        'Late sign',
      ]);
      expect(timeline.playbackSubtitleIndex, 1);
    });
  });

  group('SessionVideoFullscreenPage reactivity (#45)', () {
    testWidgets(
      'rebuilds when loadedPath, loopMode, and currentTrackPath change',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        final firstVideo = testMusicTrack(
          name: 'Video 1',
          path: '/videos-a/v1.mp4',
          groupKey: '/videos-a',
          groupTitle: 'Videos A',
        ).copyWith(isVideo: true);
        final secondVideo = testMusicTrack(
          name: 'Video 2',
          path: '/videos-b/v2.mp4',
          groupKey: '/videos-b',
          groupTitle: 'Videos B',
        ).copyWith(isVideo: true);
        fixture.library.addTracks([firstVideo, secondVideo], persist: false);

        final session = fixture.playback.createTrackSession(firstVideo)
          ..loopMode = SessionLoopMode.single
          ..loadedPath = null;
        addTearDown(session.shutdown);
        fixture.playback.publishSessionState(session.id);

        final orientation = AppOrientationController(
          setPreferredOrientations: (_) async {},
          setSystemUiMode: (_) async {},
        );
        final lease = await orientation.enterVideoFullscreen();
        addTearDown(lease.release);

        await tester.pumpWidget(
          fixture.build(
            SessionVideoFullscreenPage(
              sessionId: session.id,
              trackPath: firstVideo.path,
              fullscreenLease: lease,
            ),
          ),
        );
        await tester.pump();

        // Initially not loaded -> no NativeSessionVideoSurface.
        expect(find.byType(NativeSessionVideoSurface), findsNothing);

        // Once loadedPath matches firstVideo -> NativeSessionVideoSurface mounts.
        session.loadedPath = firstVideo.path;
        fixture.playback.publishSessionState(session.id);
        await tester.pump();
        expect(find.byType(NativeSessionVideoSurface), findsOneWidget);

        // Switching track path (without custom queue) updates readiness cleanly.
        session.currentTrackPath = secondVideo.path;
        fixture.playback.publishSessionState(session.id);
        await tester.pump();
        expect(find.byType(NativeSessionVideoSurface), findsNothing);

        // Switching loadedPath to secondVideo brings surface back.
        session.loadedPath = secondVideo.path;
        fixture.playback.publishSessionState(session.id);
        await tester.pump();
        expect(find.byType(NativeSessionVideoSurface), findsOneWidget);

        // Changing loopMode updates adjacent track button availability.
        final nextFinder = find.byIcon(Icons.skip_next_rounded);
        expect(nextFinder, findsOneWidget);
        final beforeButton = tester.widget<IconButton>(
          find.ancestor(of: nextFinder, matching: find.byType(IconButton)),
        );
        session.loopMode = SessionLoopMode.folderSequential;
        fixture.playback.publishSessionState(session.id);
        await tester.pump();
        final afterButton = tester.widget<IconButton>(
          find.ancestor(of: nextFinder, matching: find.byType(IconButton)),
        );
        expect(beforeButton.onPressed, isNotNull);
        expect(afterButton.onPressed, isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('VolumeBalancePage narrow sound-field pad (#70)', () {
    testWidgets(
      'dragging sound-field pad with zero usable height does not throw NaN error',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Balance',
          path: '/music/balance.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track);
        addTearDown(session.shutdown);
        fixture.playback.publishSessionState(session.id);

        // Constrain height and scale button text so the pad receives <= 24 px
        // height (matching _thumbSize == 24 -> usable height <= 0).
        await tester.pumpWidget(
          fixture.build(
            Center(
              child: MediaQuery(
                data: const MediaQueryData(
                  textScaler: TextScaler.linear(3.2),
                ),
                child: SizedBox(
                  width: 320,
                  height: 200,
                  child: VolumeBalancePage(
                    session: fixture.playback.sessionSnapshotById(session.id)!,
                    playback: fixture.playback,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final pad = find.byKey(const ValueKey('sound_field_pad'));
        expect(pad, findsOneWidget);
        final padSize = tester.getSize(pad);
        expect(padSize.height, lessThanOrEqualTo(24));

        final center = tester.getCenter(pad);
        final gesture = await tester.startGesture(center);
        await tester.pump();
        await gesture.moveBy(const Offset(5, -5));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Workstream B UX interaction regressions', () {
    testWidgets(
      'P0-6: SessionProgressBar cancels drag state on track switch / unknown duration',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track1 = testMusicTrack(
          name: 'Track 1',
          path: '/music/t1.mp3',
          groupKey: '/music',
          groupTitle: 'Album',
        );
        final track2 = testMusicTrack(
          name: 'Track 2',
          path: '/music/t2.mp3',
          groupKey: '/music',
          groupTitle: 'Album',
        );
        fixture.library.addTracks([track1, track2], persist: false);
        final session = fixture.playback.createTrackSession(track1)
          ..setOptimisticDuration(const Duration(seconds: 100));
        addTearDown(session.shutdown);
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 40),
            duration: const Duration(seconds: 100),
            bufferedPosition: const Duration(seconds: 60),
            nativeElapsedRealtimeMs: 40000,
          ),
        );

        Future<void> pumpBar() => tester.pumpWidget(
          fixture.build(
            Center(
              child: SizedBox(
                width: 360,
                child: SessionProgressBar(
                  session: PlaybackSessionSnapshot.fromRuntime(session),
                  playback: fixture.playback,
                ),
              ),
            ),
          ),
        );

        await pumpBar();
        await tester.pumpAndSettle();

        final sliderRect = tester.getRect(find.byType(Slider));
        final gesture = await tester.startGesture(sliderRect.center);
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
        expect(SessionProgressBar.isInteracting, isTrue);

        // Track changes mid-drag with unknown duration -> drag must reset cleanly.
        session
          ..currentTrackPath = track2.path
          ..setOptimisticDuration(null);
        await pumpBar();
        await tester.pump();
        expect(SessionProgressBar.isInteracting, isFalse);

        await gesture.up();
        await tester.pump();
        expect(SessionProgressBar.isInteracting, isFalse);
      },
    );

    testWidgets(
      'P0-7: SessionSubtitlePanel shows playback error even when subtitles are disabled and tappable enable when hidden',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final remoteTrack = testMusicTrack(
          name: 'Remote Track',
          path: 'https://asmr.example/audio.mp3',
          groupKey: 'rj:123',
          groupTitle: 'RJ123',
        ).copyWith(remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne);
        fixture.library.addTracks([remoteTrack], persist: false);
        final session = fixture.playback.createTrackSession(remoteTrack);
        addTearDown(session.shutdown);
        session.applyNativeSnapshot(
          NativePlaybackSnapshot(
            sessionId: session.id,
            path: remoteTrack.path,
            playing: false,
            playWhenReady: false,
            processingState: 'idle',
            position: Duration.zero,
            bufferedPosition: Duration.zero,
            volume: 1.0,
            boostGain: 1.0,
            channelSwapEnabled: false,
            error: 'network timeout',
          ),
        );
        fixture.playback.publishSessionState(session.id);

        await tester.pumpWidget(
          fixture.build(
            SizedBox(
              width: 360,
              height: 200,
              child: SessionSubtitlePanel(
                session: fixture.playback.sessionSnapshotById(session.id)!,
                subtitleEnabled: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('subtitle_error')), findsOneWidget);
        expect(
          find.text(
            fixture.languageProvider.tr('asmr_playback_network_failed_retry'),
          ),
          findsOneWidget,
        );

        // Clearing error shows tappable hidden-subtitle prompt that re-enables subtitles.
        session.applyNativeSnapshot(
          NativePlaybackSnapshot(
            sessionId: session.id,
            path: remoteTrack.path,
            playing: false,
            playWhenReady: false,
            processingState: 'ready',
            position: Duration.zero,
            bufferedPosition: Duration.zero,
            volume: 1.0,
            boostGain: 1.0,
            channelSwapEnabled: false,
          ),
        );
        fixture.playback.publishSessionState(session.id);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SessionSubtitlePanel)),
        );
        container
            .read(subtitleSettingsProvider.notifier)
            .toggleShowSubtitles(session.id);
        expect(
          container.read(subtitleSettingsProvider).isShowEnabled(session.id),
          isFalse,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('subtitle_hidden')), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('subtitle_hidden_for_track')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('subtitle_hidden')));
        await tester.pump();
        expect(
          container.read(subtitleSettingsProvider).isShowEnabled(session.id),
          isTrue,
        );
      },
    );

    testWidgets(
      'P0-7/P0-8/P1-11: SessionVideoFullscreenPage shows error banner, center horizontal seek, hover-pinned controls, and subtitles',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);

        final video = testMusicTrack(
          name: 'Video',
          path: '/videos/demo.mp4',
          groupKey: '/videos',
          groupTitle: 'Videos',
        ).copyWith(isVideo: true);
        fixture.library.addTracks([video], persist: false);
        final subtitleService = PlaybackSubtitleService(
          trackResolver: fixture.library.trackByPath,
          subtitleLoader: (_, _) async => SubtitleTrack(
            sourcePath: '/videos/demo.srt',
            cues: const [
              SubtitleCue(
                start: Duration(seconds: 5),
                end: Duration(seconds: 25),
                text: 'Fullscreen subtitle line',
              ),
            ],
          ),
        );
        addTearDown(subtitleService.dispose);
        await tester.runAsync(() => subtitleService.load(video.path));

        final session = fixture.playback.createTrackSession(video)
          ..loadedPath = video.path
          ..setOptimisticDuration(const Duration(seconds: 120))
          ..lastKnownPosition = const Duration(seconds: 10);
        addTearDown(session.shutdown);
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 10),
            duration: const Duration(seconds: 120),
            bufferedPosition: const Duration(seconds: 60),
            nativeElapsedRealtimeMs: 10000,
          ),
        );
        fixture.playback.publishSessionState(session.id);

        final orientation = AppOrientationController(
          setPreferredOrientations: (_) async {},
          setSystemUiMode: (_) async {},
        );
        final lease = await orientation.enterVideoFullscreen();
        addTearDown(lease.release);

        await tester.pumpWidget(
          fixture.build(
            SessionVideoFullscreenPage(
              sessionId: session.id,
              trackPath: video.path,
              fullscreenLease: lease,
            ),
            subtitleService: subtitleService,
          ),
        );
        await tester.pumpAndSettle();

        // Synchronized subtitle overlay renders in fullscreen.
        expect(
          find.byKey(const ValueKey('fullscreen_video_subtitle_overlay')),
          findsOneWidget,
        );
        expect(find.text('Fullscreen subtitle line'), findsOneWidget);

        // Hovering over bottom control bar keeps controls visible beyond 3s timeout.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(
          tester.getCenter(
            find.byKey(const ValueKey('fullscreen_video_control_bar')),
          ),
        );
        await tester.pump(const Duration(seconds: 4));
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(const ValueKey('fullscreen_video_controls')),
              )
              .opacity,
          1.0,
        );

        // Center 50% horizontal swipe triggers seek.
        final gestureSurface = find.byKey(
          const ValueKey('fullscreen_video_gesture_surface'),
        );
        await tester.dragFrom(
          tester.getCenter(gestureSurface),
          const Offset(120, 0),
        );
        await tester.pump();
        expect(session.position, greaterThan(const Duration(seconds: 10)));

        // Playback error shows inline banner + retry button.
        session.applyNativeSnapshot(
          NativePlaybackSnapshot(
            sessionId: session.id,
            path: video.path,
            playing: false,
            playWhenReady: false,
            processingState: 'idle',
            position: session.position,
            bufferedPosition: const Duration(seconds: 60),
            duration: const Duration(seconds: 120),
            volume: 1.0,
            boostGain: 1.0,
            channelSwapEnabled: false,
            error: 'decoder error',
          ),
        );
        fixture.playback.publishSessionState(session.id);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fullscreen_video_error_banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('fullscreen_video_retry_button')),
          findsOneWidget,
        );

        // Keyboard shortcut F exits fullscreen cleanly.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'P0-9: BedtimeCanvasPage blocks back pop with hint and shows waiting-trigger & auto-resume timer states',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final i18n = fixture.languageProvider;

        fixture.timer.configureTimer(
          TimerMode.trigger,
          const Duration(minutes: 20),
        );
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(BedtimeCanvasPage.route(context)),
                  child: const Text('Open Bedtime'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Bedtime'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        // Trigger waiting state displays instead of "No timer set".
        expect(
          find.text(i18n.tr('waiting_to_start_countdown')),
          findsOneWidget,
        );

        // Back attempt is blocked by PopScope and shows subtle hint.
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byType(BedtimeCanvasPage), findsOneWidget);
        expect(
          find.byKey(const ValueKey('bedtime_back_blocked_hint')),
          findsOneWidget,
        );

        // Auto-resume countdown state displays cleanly.
        fixture.timerService
          ..timerActive = false
          ..timerRemaining = Duration.zero
          ..autoResumeEnabled = true
          ..autoResumeAt = DateTime.now().add(const Duration(minutes: 30));
        fixture.timer.syncPresentationState();
        await tester.pump();
        await tester.pump();
        expect(
          find.textContaining(i18n.tr('waiting_for_auto_resume')),
          findsOneWidget,
        );

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'P1-15: TimelineSubtitleView lets tapping focused cue seek while browsing and has >=44px seek button',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final seeks = <Duration>[];
        final cues = [
          const SubtitleCue(
            start: Duration(seconds: 1),
            end: Duration(seconds: 3),
            text: 'First cue',
          ),
          const SubtitleCue(
            start: Duration(seconds: 5),
            end: Duration(seconds: 8),
            text: 'Second cue',
          ),
          const SubtitleCue(
            start: Duration(seconds: 10),
            end: Duration(seconds: 13),
            text: 'Third cue',
          ),
        ];

        await tester.pumpWidget(
          fixture.build(
            SizedBox(
              width: 360,
              height: 220,
              child: TimelineSubtitleView(
                cues: cues,
                playbackSubtitleIndex: 0,
                onSeek: (position) async => seeks.add(position),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap second cue to enter browsing mode.
        await tester.tap(find.byKey(const ValueKey('subtitle_timeline_cue_1')));
        await tester.pumpAndSettle();

        final seekButton = find.byKey(
          const ValueKey('subtitle_timeline_seek_button'),
        );
        expect(seekButton, findsOneWidget);
        final buttonRect = tester.getRect(seekButton);
        expect(buttonRect.height, greaterThanOrEqualTo(44));
        expect(buttonRect.width, greaterThanOrEqualTo(44));

        // Seek button does not overlap centered focused cue in portrait.
        final focusedCueRect = tester.getRect(
          find.byKey(const ValueKey('subtitle_timeline_text_1')),
        );
        expect(buttonRect.overlaps(focusedCueRect), isFalse);

        // Tapping the centered focused cue while browsing seeks immediately.
        await tester.tap(find.byKey(const ValueKey('subtitle_timeline_cue_1')));
        await tester.pump();
        expect(seeks, [const Duration(seconds: 5)]);
      },
    );

    test('P1-12: TimerFacade.extendCountdown supports positive and negative deltas safely', () {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.timer.configureTimer(
        TimerMode.manual,
        const Duration(minutes: 10),
      );
      fixture.timer.startCountdown();
      final beforeRemaining = fixture.timer.state.remaining!;

      // Subtracting 15m from 10m is ignored instead of expiring immediately.
      fixture.timer.extendCountdown(const Duration(minutes: -15));
      expect(fixture.timer.state.active, isTrue);
      expect(
        fixture.timer.state.remaining!.inSeconds,
        closeTo(beforeRemaining.inSeconds, 2),
      );

      // Subtracting 5m from 10m shortens remaining to ~5m.
      fixture.timer.extendCountdown(const Duration(minutes: -5));
      final afterMinus5 = fixture.timer.state.remaining!;
      expect(fixture.timer.state.active, isTrue);
      expect(
        afterMinus5.inSeconds,
        closeTo(beforeRemaining.inSeconds - 300, 3),
      );

      // Adding 15m extends remaining by ~15m.
      fixture.timer.extendCountdown(const Duration(minutes: 15));
      final afterPlus15 = fixture.timer.state.remaining!;
      expect(fixture.timer.state.active, isTrue);
      expect(
        afterPlus15.inSeconds,
        greaterThanOrEqualTo(afterMinus5.inSeconds + 895),
      );
      fixture.timer.cancelTimer();
    });

    testWidgets(
      'active countdown displays -15, -5, +5, +15 mini capsules in one horizontal row',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        fixture.timer.configureTimer(
          TimerMode.manual,
          const Duration(minutes: 10),
        );
        fixture.timer.startCountdown();

        await tester.pumpWidget(
          fixture.build(
            const Center(
              child: SizedBox(
                width: 320,
                height: 460,
                child: TimerTab(
                  compactOnly: true,
                  initialCompactDetail: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        const keys = [
          ValueKey('timer_extend_-15m'),
          ValueKey('timer_extend_-5m'),
          ValueKey('timer_extend_5m'),
          ValueKey('timer_extend_15m'),
        ];
        final i18n = fixture.languageProvider;
        expect(
          find.text('-${i18n.tr('minutes_duration', {'count': 15})}'),
          findsOneWidget,
        );
        expect(
          find.text('-${i18n.tr('minutes_duration', {'count': 5})}'),
          findsOneWidget,
        );
        expect(
          find.text('+${i18n.tr('minutes_duration', {'count': 5})}'),
          findsOneWidget,
        );
        expect(
          find.text('+${i18n.tr('minutes_duration', {'count': 15})}'),
          findsOneWidget,
        );

        final rects = [for (final key in keys) tester.getRect(find.byKey(key))];
        // All four mini capsules sit on one horizontal row and stay compact.
        for (var i = 0; i < rects.length; i++) {
          expect(rects[i].height, lessThan(36));
          if (i > 0) {
            expect(rects[i].center.dy, closeTo(rects[0].center.dy, 0.5));
            expect(rects[i].left, greaterThan(rects[i - 1].right));
          }
        }

        // At 10m remaining, -15 is disabled while -5 works; after +15, -15 becomes enabled.
        final minus15Ink = tester.widget<AppEntryInkWell>(find.byKey(keys[0]));
        final minus5Ink = tester.widget<AppEntryInkWell>(find.byKey(keys[1]));
        expect(minus15Ink.onTap, isNull);
        expect(minus5Ink.onTap, isNotNull);

        await tester.tap(find.byKey(keys[3]));
        await tester.pump();
        expect(
          tester.widget<AppEntryInkWell>(find.byKey(keys[0])).onTap,
          isNotNull,
        );
        fixture.timer.cancelTimer();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('Windows playback icon transitions', () {
    testWidgets(
      'playlist play/pause and detail volume mute crossfade without scale or rotation on Windows',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: _AcceptingPlaybackRepository(),
        );
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Windows Icon Track',
          path: '/music/windows_icon.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track)
          ..loadedPath = track.path;
        fixture.playbackService.syncSlice(
          activeSessions: [session],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        final volumePreview = ValueNotifier<double?>(null);
        addTearDown(volumePreview.dispose);

        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: TargetPlatform.windows),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SessionListCard(
                    sessionId: session.id,
                    session: fixture.playback.sessionSnapshotById(session.id),
                    track: track,
                    coverCacheWidth: 100,
                    library: fixture.library,
                    playback: fixture.playback,
                    isTemporary: false,
                    onOpen: (_) {},
                  ),
                  SizedBox(
                    width: playbackSecondaryControlsWidth,
                    child: PlaybackSecondaryControlSurface(
                      child: SessionVolumeControls(
                        session: fixture.playback.sessionSnapshotById(
                          session.id,
                        )!,
                        playback: fixture.playback,
                        volumePreview: volumePreview,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final playButton = find.ancestor(
          of: find.byIcon(Icons.play_arrow_rounded),
          matching: find.byType(IconButton),
        );
        expect(
          find.descendant(
            of: playButton,
            matching: find.byType(AppPlaybackIconTransition),
          ),
          findsOneWidget,
        );

        await tester.tap(playButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          find.descendant(
            of: find.byType(SessionListCard),
            matching: find.byType(ScaleTransition),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AppPlaybackIconTransition),
            matching: find.byType(Transform),
          ),
          findsNothing,
        );
        await tester.pump(kAppPlaybackIconDuration);
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

        final muteButton = find.byKey(
          const ValueKey('session_volume_mute_button'),
        );
        await tester.tap(muteButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(
          find.descendant(
            of: muteButton,
            matching: find.byType(ScaleTransition),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: muteButton,
            matching: find.byType(Transform),
          ),
          findsNothing,
        );
        await tester.pump(kAppPlaybackIconDuration);
        expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}

class _AcceptingPlaybackRepository extends NativePlaybackRepository {
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume,
  ) async => const NativeSuccess();
}
