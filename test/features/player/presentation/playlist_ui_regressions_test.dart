import 'dart:async';
import 'dart:io';

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/platform/video_display_platform_gateway.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/core/widgets/app_entry_ink_well.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/bedtime_canvas_page.dart';
import 'package:doujin_audio/features/player/presentation/playback_position_ui_gate.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_audio_features.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_batch_controller.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_list_view.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_progress_widgets.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_shared_helpers.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_subtitle_panel.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_transport_controls.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_video_widgets.dart';
import 'package:doujin_audio/features/player/presentation/session_video_surface.dart';
import 'package:doujin_audio/features/settings/application/settings_command_controller.dart';
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
        expect(
          sliderRect.height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
        );
        final gesture = await tester.startGesture(
          Offset(sliderRect.center.dx, sliderRect.top + 5),
        );
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
      variant: TargetPlatformVariant.only(TargetPlatform.android),
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
      'fullscreen gestures accumulate double-tap skips, support drag & long-press, and show pure circular icon feedback without text on Android',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final videoDisplay = _FakeVideoDisplayGateway();
        final repo = _AcceptingPlaybackRepository();
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: repo,
        );
        addTearDown(fixture.dispose);

        final video = testMusicTrack(
          name: 'Video',
          path: '/videos/gestures_android.mp4',
          groupKey: '/videos',
          groupTitle: 'Videos',
        ).copyWith(isVideo: true);
        fixture.library.addTracks([video], persist: false);
        final session = fixture.playback.createTrackSession(video)
          ..loadedPath = video.path
          ..setOptimisticDuration(const Duration(seconds: 120))
          ..lastKnownPosition = const Duration(seconds: 30);
        addTearDown(session.shutdown);
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 30),
            duration: const Duration(seconds: 120),
            bufferedPosition: const Duration(seconds: 60),
            nativeElapsedRealtimeMs: 10000,
          ),
        );
        fixture.playback.publishSessionState(session.id);

        final orientation = AppOrientationController(
          setPreferredOrientations: (_) async {},
          setSystemUiMode: (_) async {},
          videoDisplay: videoDisplay,
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
          ),
        );
        await tester.pumpAndSettle();

        final surface = find.byKey(
          const ValueKey('fullscreen_video_gesture_surface'),
        );
        final surfaceRect = tester.getRect(surface);
        final feedbackCard = find.byKey(
          const ValueKey('fullscreen_video_feedback_card'),
        );

        void expectPureCircularFeedback(
          IconData expectedIcon, {
          required bool hasProgressRing,
        }) {
          expect(feedbackCard, findsOneWidget);
          final material = tester.widget<Material>(feedbackCard);
          expect(material.shape, const CircleBorder());
          expect(
            find.descendant(of: feedbackCard, matching: find.byType(Text)),
            findsNothing,
          );
          expect(
            find.descendant(
              of: feedbackCard,
              matching: find.byIcon(expectedIcon),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: feedbackCard,
              matching: find.byType(CircularProgressIndicator),
            ),
            hasProgressRing ? findsOneWidget : findsNothing,
          );
        }

        // Consecutive double-taps on the right side accumulate +5s -> +10s.
        final rightDoubleTap = Offset(
          surfaceRect.right - 40,
          surfaceRect.center.dy,
        );
        await tester.tapAt(rightDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(rightDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.position, const Duration(seconds: 35));
        expectPureCircularFeedback(
          Icons.forward_5_rounded,
          hasProgressRing: false,
        );
        expect(
          tester.getCenter(feedbackCard).dx,
          greaterThan(surfaceRect.center.dx),
        );

        await tester.tapAt(rightDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(rightDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.position, const Duration(seconds: 40));

        // Double-tap on the left side skips -5s and shows left-aligned circular icon.
        final leftDoubleTap = Offset(
          surfaceRect.left + 40,
          surfaceRect.center.dy,
        );
        await tester.tapAt(leftDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(leftDoubleTap);
        await tester.pump(const Duration(milliseconds: 220));
        expect(session.position, const Duration(seconds: 35));
        expectPureCircularFeedback(
          Icons.replay_5_rounded,
          hasProgressRing: false,
        );
        expect(
          tester.getCenter(feedbackCard).dx,
          lessThan(surfaceRect.center.dx),
        );

        final slider = find.descendant(
          of: find.byKey(const ValueKey('fullscreen_video_progress')),
          matching: find.byType(Slider),
        );
        final sliderRect = tester.getRect(slider);
        await tester.tapAt(Offset(sliderRect.right - 50, sliderRect.center.dy));
        await tester.pump(const Duration(milliseconds: 50));
        final manuallySought = session.position;
        expect(manuallySought, greaterThan(const Duration(seconds: 70)));
        await tester.tapAt(leftDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(leftDoubleTap);
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.position, manuallySought - const Duration(seconds: 5));

        // Double-tap center toggles play/pause with centered circular icon.
        await tester.tapAt(surfaceRect.center);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(surfaceRect.center);
        await tester.pump(const Duration(milliseconds: 220));
        expectPureCircularFeedback(
          Icons.play_arrow_rounded,
          hasProgressRing: false,
        );
        expect(
          tester.getCenter(feedbackCard).dx,
          closeTo(surfaceRect.center.dx, 0.1),
        );

        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump(const Duration(milliseconds: 220));

        // Horizontal drag shows circular fast-forward icon + progress ring, no text.
        final hDrag = await tester.startGesture(surfaceRect.center);
        await hDrag.moveBy(const Offset(40, 0));
        await hDrag.moveBy(const Offset(80, 0));
        await tester.pump(const Duration(milliseconds: 50));
        expectPureCircularFeedback(
          Icons.fast_forward_rounded,
          hasProgressRing: true,
        );
        await hDrag.up();
        await tester.pump();
        expect(session.position, greaterThan(const Duration(seconds: 35)));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 220));

        // Left-side vertical drag adjusts brightness with circular ring icon, no text.
        final bDrag = await tester.startGesture(
          Offset(surfaceRect.left + 80, surfaceRect.center.dy),
        );
        await bDrag.moveBy(const Offset(0, -24));
        await bDrag.moveBy(const Offset(0, -80));
        await tester.pump(const Duration(milliseconds: 50));
        expect(feedbackCard, findsOneWidget);
        expect(
          find.descendant(of: feedbackCard, matching: find.byType(Text)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: feedbackCard,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        await bDrag.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(videoDisplay.lastBrightness, greaterThan(0.5));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 220));

        // Right-side vertical drag adjusts volume with circular ring icon, no text.
        final vDrag = await tester.startGesture(
          Offset(surfaceRect.right - 80, surfaceRect.center.dy),
        );
        await vDrag.moveBy(const Offset(0, 24));
        await vDrag.moveBy(const Offset(0, 100));
        await tester.pump(const Duration(milliseconds: 50));
        expect(feedbackCard, findsOneWidget);
        expect(
          find.descendant(of: feedbackCard, matching: find.byType(Text)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: feedbackCard,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        await vDrag.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.volume, lessThan(1.0));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 220));

        // Long-press activates temporary 2.0x speed with pure circular icon and clears on release.
        final hold = await tester.startGesture(surfaceRect.center);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        expect(repo.temporarySpeedCalls, [2.0]);
        expectPureCircularFeedback(Icons.speed_rounded, hasProgressRing: false);
        await hold.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(repo.temporarySpeedCalls, [2.0, null]);
        expect(feedbackCard, findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Windows fullscreen supports mouse wheel volume adjustment with pure circular icon feedback',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: _AcceptingPlaybackRepository(),
        );
        addTearDown(fixture.dispose);

        final video = testMusicTrack(
          name: 'Video',
          path: '/videos/gestures_windows.mp4',
          groupKey: '/videos',
          groupTitle: 'Videos',
        ).copyWith(isVideo: true);
        fixture.library.addTracks([video], persist: false);
        final session = fixture.playback.createTrackSession(video)
          ..loadedPath = video.path
          ..setOptimisticDuration(const Duration(seconds: 120));
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
              trackPath: video.path,
              fullscreenLease: lease,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final surface = find.byKey(
          const ValueKey('fullscreen_video_gesture_surface'),
        );
        final center = tester.getCenter(surface);

        // Scroll up increases volume and displays circular ring icon without text.
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.volume, greaterThan(1.0));
        final feedbackCard = find.byKey(
          const ValueKey('fullscreen_video_feedback_card'),
        );
        expect(feedbackCard, findsOneWidget);
        expect(
          tester.widget<Material>(feedbackCard).shape,
          const CircleBorder(),
        );
        expect(
          find.descendant(of: feedbackCard, matching: find.byType(Text)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: feedbackCard,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );

        // Scroll down decreases volume.
        final raisedVolume = session.volume;
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, 240),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.volume, lessThan(raisedVolume));

        await tester.pump(const Duration(milliseconds: 700));
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

        // Seek indicator row aligns vertically with the centered focused cue
        // without overlapping the cue text in portrait.
        final focusedCue = find.byKey(const ValueKey('subtitle_timeline_text_1'));
        final dashes = find.byKey(
          const ValueKey('subtitle_timeline_seek_dashes'),
        );
        final scale = tester.widget<AnimatedScale>(
          find.ancestor(of: focusedCue, matching: find.byType(AnimatedScale)),
        );
        final platform = Theme.of(tester.element(focusedCue)).platform;
        expect(scale.scale, platform == TargetPlatform.android ? 1 : 1.03);
        final focusedCueRect = tester.getRect(focusedCue);
        final dashesRect = tester.getRect(dashes);
        expect(buttonRect.center.dy, closeTo(focusedCueRect.center.dy, 0.5));
        expect(dashesRect.center.dy, closeTo(focusedCueRect.center.dy, 0.5));
        expect(buttonRect.overlaps(focusedCueRect), isFalse);
        expect(dashesRect.overlaps(focusedCueRect), isFalse);

        // Tapping the centered focused cue while browsing seeks immediately.
        await tester.tap(find.byKey(const ValueKey('subtitle_timeline_cue_1')));
        await tester.pump();
        expect(seeks, [const Duration(seconds: 5)]);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
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

  group('Deferred ref and lifecycle regressions', () {
    testWidgets(
      'stagePlaybackSessionRemovals commits after widget disposal without StateError',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: _AcceptingPlaybackRepository(),
        );
        addTearDown(fixture.dispose);
        final track1 = testMusicTrack(
          name: 'Track 1',
          path: '/music/remove_1.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        final track2 = testMusicTrack(
          name: 'Track 2',
          path: '/music/remove_2.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track1, track2], persist: false);
        final session1 = fixture.playback.createTrackSession(track1);
        final session2 = fixture.playback.createTrackSession(track2);
        fixture.playbackService.syncSlice(
          activeSessions: [session1, session2],
          playingSessionCount: 0,
          focusedSessionId: session1.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.runAsync(
          () => fixture.settings.pinPlaylistSessions([
            session1.id,
            session2.id,
          ]),
        );

        final removalService = UndoableRemovalService();
        addTearDown(removalService.dispose);
        final showConsumer = ValueNotifier<bool>(true);
        addTearDown(showConsumer.dispose);
        late WidgetRef capturedRef;
        late BuildContext capturedContext;

        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: showConsumer,
              builder: (_, visible, _) => visible
                  ? Consumer(
                      builder: (context, ref, _) {
                        capturedContext = context;
                        capturedRef = ref;
                        return const SizedBox.shrink();
                      },
                    )
                  : const SizedBox.shrink(),
            ),
            overrides: [
              undoableRemovalServiceProvider.overrideWithValue(removalService),
            ],
          ),
        );
        await tester.pump();

        final staged = await stagePlaybackSessionRemovals(
          capturedContext,
          capturedRef,
          [session1.id, session2.id],
        );
        expect(staged, isTrue);

        // Dispose the widget owning WidgetRef before commit runs.
        showConsumer.value = false;
        await tester.pump();

        await tester.runAsync(
          () => removalService.commitPending().timeout(
            const Duration(seconds: 3),
          ),
        );
        expect(fixture.playback.hasSession(session1.id), isFalse);
        expect(fixture.playback.hasSession(session2.id), isFalse);
        expect(fixture.settings.pinnedPlaylistSessionIds, isEmpty);
      },
    );

    testWidgets(
      'SessionProgressBar invokes onSeekCancel on cancelled drag and disposal',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track1 = testMusicTrack(
          name: 'Seek 1',
          path: '/music/seek_1.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        final track2 = testMusicTrack(
          name: 'Seek 2',
          path: '/music/seek_2.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track1, track2], persist: false);
        final session = fixture.playback.createTrackSession(track1)
          ..duration = const Duration(minutes: 5)
          ..lastKnownPosition = const Duration(minutes: 1);
        addTearDown(session.shutdown);
        fixture.playback.publishSessionState(session.id);

        var seekStarts = 0;
        var seekCancels = 0;
        var manualSeeks = 0;

        Widget buildBar(PlaybackSessionSnapshot snapshot) => fixture.build(
          Center(
            child: SizedBox(
              width: 320,
              child: SessionProgressBar(
                session: snapshot,
                playback: fixture.playback,
                onSeekStart: () => seekStarts++,
                onSeekCancel: () => seekCancels++,
                onManualSeek: (_) => manualSeeks++,
              ),
            ),
          ),
        );

        await tester.pumpWidget(
          buildBar(fixture.playback.sessionSnapshotById(session.id)!),
        );
        await tester.pump();

        // Start drag on slider, then switch track mid-drag to trigger _cancelActiveDrag().
        final sliderFinder = find.byType(Slider);
        final drag = await tester.startGesture(tester.getCenter(sliderFinder));
        await drag.moveBy(const Offset(24, 0));
        await tester.pump();
        expect(seekStarts, 1);
        expect(seekCancels, 0);

        session.currentTrackPath = track2.path;
        fixture.playback.publishSessionState(session.id);
        await tester.pumpWidget(
          buildBar(fixture.playback.sessionSnapshotById(session.id)!),
        );
        await tester.pump();
        expect(seekCancels, 1);
        expect(manualSeeks, 0);
        await drag.up();
        await tester.pump();

        // Start a second drag and unmount mid-drag -> dispose() notifies onSeekCancel.
        final drag2 = await tester.startGesture(tester.getCenter(sliderFinder));
        await drag2.moveBy(const Offset(24, 0));
        await tester.pump();
        expect(seekStarts, 2);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(seekCancels, 2);
        await drag2.up();
      },
    );

    testWidgets(
      'EqualizerPage preset removal does not read disposed WidgetRef inside prepare',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: _AcceptingPlaybackRepository(),
        );
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'EQ Track',
          path: '/music/eq.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final customPreset = EqPreset(
          id: 'custom_1',
          labelKey: 'Warm',
          bandLevels: const <int, double>{60: 3.0},
        );
        await tester.runAsync(
          () => fixture.settings
              .saveCustomEqPreset(customPreset)
              .timeout(const Duration(seconds: 3)),
        );
        final session = fixture.playback.createTrackSession(track)
          ..audioEffects = AudioEffectsState.flat.copyWith(
            eqEnabled: true,
            eqPresetId: customPreset.id,
            eqBandLevels: customPreset.bandLevels,
          );
        addTearDown(session.shutdown);
        fixture.playback.publishSessionState(session.id);

        final removalService = UndoableRemovalService();
        addTearDown(removalService.dispose);
        final showPage = ValueNotifier<bool>(true);
        addTearDown(showPage.dispose);

        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: showPage,
              builder: (_, visible, _) => visible
                  ? SizedBox(
                      width: 400,
                      height: 600,
                      child: EqualizerPage(
                        session: fixture.playback.sessionSnapshotById(
                          session.id,
                        )!,
                        playback: fixture.playback,
                        topInset: 0,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            overrides: [
              undoableRemovalServiceProvider.overrideWithValue(removalService),
              settingsCommandControllerProvider.overrideWithValue(
                SettingsCommandController(
                  settings: fixture.settings,
                  playback: fixture.playback,
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final deleteButton = find.byKey(
          const ValueKey<String>('delete_equalizer_preset'),
        );
        await tester.scrollUntilVisible(
          deleteButton,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(deleteButton);
        await tester.pump();
        expect(removalService.state.pendingCount, 1);

        // Dispose EqualizerPage before committing removal.
        showPage.value = false;
        await tester.pump();
        await tester.runAsync(
          () => removalService.commitPending().timeout(
            const Duration(seconds: 3),
          ),
        );

        expect(fixture.settings.customEqPresets, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'PlaylistBatchActions.playSelected and pauseSelected survive widget disposal mid-loop',
      (tester) async {
        final gate = _GatedPlaybackRepository();
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: gate,
        );
        addTearDown(fixture.dispose);
        final track1 = testMusicTrack(
          name: 'Batch 1',
          path: '/music/batch_1.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        final track2 = testMusicTrack(
          name: 'Batch 2',
          path: '/music/batch_2.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track1, track2], persist: false);
        final session1 = fixture.playback.createTrackSession(track1)
          ..loadedPath = track1.path
          ..setOptimisticState(
            playing: false,
            processingState: ProcessingState.ready,
          );
        final session2 = fixture.playback.createTrackSession(track2)
          ..loadedPath = track2.path
          ..setOptimisticState(
            playing: false,
            processingState: ProcessingState.ready,
          );
        addTearDown(session1.shutdown);
        addTearDown(session2.shutdown);
        fixture.playbackService.syncSlice(
          activeSessions: [session1, session2],
          playingSessionCount: 0,
          focusedSessionId: session1.id,
          coverGeneration: 0,
          isInitialized: true,
        );

        final showConsumer = ValueNotifier<bool>(true);
        addTearDown(showConsumer.dispose);
        late WidgetRef capturedRef;
        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<bool>(
              valueListenable: showConsumer,
              builder: (_, visible, _) => visible
                  ? Consumer(
                      builder: (_, ref, _) {
                        capturedRef = ref;
                        return const SizedBox.shrink();
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pump();

        final firstPlayGate = Completer<void>();
        gate.playGate = firstPlayGate;
        final playFuture = PlaylistBatchActions.playSelected(
          ref: capturedRef,
          selectedSessionIds: [session1.id, session2.id],
        );

        // Dispose widget owning WidgetRef before the first play call resolves.
        showConsumer.value = false;
        await tester.pump();
        gate.playGate = null;
        firstPlayGate.complete();
        await tester.runAsync(
          () => playFuture.timeout(const Duration(seconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          fixture.playback.sessionSnapshotById(session1.id)?.playbackRequested,
          isTrue,
        );
        expect(
          fixture.playback.sessionSnapshotById(session2.id)?.playbackRequested,
          isTrue,
        );

        // Verify pauseSelected also survives disposal mid-loop.
        showConsumer.value = true;
        await tester.pump();

        final firstPauseGate = Completer<void>();
        gate.pauseGate = firstPauseGate;
        final pauseFuture = PlaylistBatchActions.pauseSelected(
          ref: capturedRef,
          selectedSessionIds: [session1.id, session2.id],
        );

        showConsumer.value = false;
        await tester.pump();
        gate.pauseGate = null;
        firstPauseGate.complete();
        await tester.runAsync(
          () => pauseFuture.timeout(const Duration(seconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          fixture.playback.sessionSnapshotById(session1.id)?.playbackRequested,
          isFalse,
        );
        expect(
          fixture.playback.sessionSnapshotById(session2.id)?.playbackRequested,
          isFalse,
        );
      },
    );

    testWidgets(
      'PlaylistBatchActions pauseSelected ignores errored sessions and playSelected retries them',
      (tester) async {
        final repo = _GatedPlaybackRepository();
        final fixture = AppRuntimeWidgetTestFixture(
          providedNativePlaybackRepository: repo,
        );
        addTearDown(fixture.dispose);
        final tracks = [
          for (var i = 1; i <= 3; i++)
            testMusicTrack(
              name: 'Batch Err $i',
              path: '/music/batch_err_$i.mp3',
              groupKey: '/music',
              groupTitle: 'Music',
            ),
        ];
        fixture.library.addTracks(tracks, persist: false);
        final playingSession = fixture.playback.createTrackSession(tracks[0]);
        final pausedSession = fixture.playback.createTrackSession(tracks[1]);
        final erroredSession = fixture.playback.createTrackSession(tracks[2]);
        addTearDown(playingSession.shutdown);
        addTearDown(pausedSession.shutdown);
        addTearDown(erroredSession.shutdown);

        // Start playingSession cleanly, keep pausedSession paused, and mark erroredSession
        // with playbackRequested=true and a playbackError.
        playingSession
          ..loadedPath = tracks[0].path
          ..applyNativeSnapshot(
            NativePlaybackSnapshot(
              sessionId: playingSession.id,
              playing: true,
              playWhenReady: true,
              processingState: 'ready',
              position: Duration.zero,
              bufferedPosition: Duration.zero,
              volume: 1.0,
              boostGain: 1.0,
              channelSwapEnabled: false,
            ),
          );
        erroredSession.applyNativeSnapshot(
          NativePlaybackSnapshot(
            sessionId: erroredSession.id,
            playing: false,
            playWhenReady: true,
            processingState: 'idle',
            position: Duration.zero,
            bufferedPosition: Duration.zero,
            volume: 1.0,
            boostGain: 1.0,
            channelSwapEnabled: false,
            error: 'Source failed',
          ),
        );
        fixture.playback
          ..publishSessionState(playingSession.id)
          ..publishSessionState(pausedSession.id)
          ..publishSessionState(erroredSession.id);

        late WidgetRef capturedRef;
        await tester.pumpWidget(
          fixture.build(
            Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.pump();

        // Batch pause must pause playingSession only, never retry erroredSession.
        await tester.runAsync(
          () => PlaylistBatchActions.pauseSelected(
            ref: capturedRef,
            selectedSessionIds: [
              playingSession.id,
              pausedSession.id,
              erroredSession.id,
            ],
          ).timeout(const Duration(seconds: 5)),
        );
        await tester.pump();

        expect(repo.pausedSessionIds, [playingSession.id]);
        expect(repo.preparedSessionIds, isEmpty);
        expect(repo.playedSessionIds, isEmpty);
        expect(
          fixture.playback
              .sessionSnapshotById(playingSession.id)
              ?.playbackRequested,
          isFalse,
        );
        expect(
          fixture.playback
              .sessionSnapshotById(erroredSession.id)
              ?.playbackError,
          'Source failed',
        );

        // Batch play must resume both pausedSession and erroredSession.
        await tester.runAsync(
          () => PlaylistBatchActions.playSelected(
            ref: capturedRef,
            selectedSessionIds: [pausedSession.id, erroredSession.id],
          ).timeout(const Duration(seconds: 5)),
        );
        await tester.pump();

        expect(
          repo.preparedSessionIds,
          containsAll([pausedSession.id, erroredSession.id]),
        );
        expect(
          fixture.playback
              .sessionSnapshotById(pausedSession.id)
              ?.playbackRequested,
          isTrue,
        );
        expect(
          fixture.playback
              .sessionSnapshotById(erroredSession.id)
              ?.playbackError,
          isNull,
        );
      },
    );

    testWidgets(
      'SessionProgressBar dispose defers onSeekCancel so parent setState does not throw',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Dispose Seek',
          path: '/music/dispose_seek.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track)
          ..duration = const Duration(minutes: 5);
        addTearDown(session.shutdown);
        fixture.playback.publishSessionState(session.id);

        final showBar = ValueNotifier<bool>(true);
        addTearDown(showBar.dispose);
        var cancelSetStates = 0;

        await tester.pumpWidget(
          fixture.build(
            StatefulBuilder(
              builder: (context, setState) => ValueListenableBuilder<bool>(
                valueListenable: showBar,
                builder: (context, visible, _) {
                  if (!visible) return Text('cancelled:$cancelSetStates');
                  return Center(
                    child: SizedBox(
                      width: 320,
                      child: SessionProgressBar(
                        session: fixture.playback.sessionSnapshotById(
                          session.id,
                        )!,
                        playback: fixture.playback,
                        onSeekCancel: () {
                          setState(() => cancelSetStates++);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        final drag = await tester.startGesture(
          tester.getCenter(find.byType(Slider)),
        );
        await drag.moveBy(const Offset(24, 0));
        await tester.pump();

        showBar.value = false;
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(cancelSetStates, 1);
        expect(find.text('cancelled:1'), findsOneWidget);
        await drag.up();
      },
    );

    testWidgets(
      'PlaybackPositionUiGate alignToFrame honors minUpdateInterval on 120Hz frames',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Gate Track',
          path: '/music/gate.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track)
          ..duration = const Duration(minutes: 5);
        addTearDown(session.shutdown);

        final gate = PlaybackPositionUiGate(
          session: PlaybackSessionSnapshot.fromRuntime(session),
          minUpdateInterval: const Duration(milliseconds: 16),
          alignToFrame: true,
        );
        addTearDown(gate.dispose);
        var notifications = 0;
        gate.addListener(() => notifications++);

        session.setOptimisticPosition(const Duration(seconds: 1));
        await tester.pump();
        expect(notifications, 1);

        session.setOptimisticPosition(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 8));
        expect(notifications, 1);

        await tester.pump(const Duration(milliseconds: 8));
        expect(notifications, 2);
        expect(gate.value.position, const Duration(seconds: 2));
      },
    );

    test(
      'MainOverlayUiState equality and hashCode are symmetric across list implementations',
      () {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Overlay Track',
          path: '/music/overlay.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track);
        addTearDown(session.shutdown);
        final snap = PlaybackSessionSnapshot.fromRuntime(session);

        final withOverlayList = MainOverlayUiState(
          overlaySessions: PlaybackSessionOverlayList([snap]),
          playingSessionCount: 1,
          hasPlayingAudioSession: true,
          activeSessionCount: 1,
          isInitialized: true,
          startupReady: true,
        );
        final withPlainList = MainOverlayUiState(
          overlaySessions: [snap],
          playingSessionCount: 1,
          hasPlayingAudioSession: true,
          activeSessionCount: 1,
          isInitialized: true,
          startupReady: true,
        );

        expect(withOverlayList == withPlainList, isTrue);
        expect(withPlainList == withOverlayList, isTrue);
        expect(withOverlayList.hashCode, withPlainList.hashCode);
      },
    );
  });
}

class _AcceptingPlaybackRepository extends NativePlaybackRepository {
  final List<double?> temporarySpeedCalls = <double?>[];

  @override
  void startListening() {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() async =>
      NativeSuccess(NativePlaybackBundleSnapshot(sessions: const []));

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    int transportCommandId = 0,
    bool exclusive = false,
  }) async => const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) async => const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) async => const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setTemporarySpeed(
    String sessionId,
    double? speed,
  ) async {
    temporarySpeedCalls.add(speed);
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> setPlaybackBehavior({
    required bool pauseOnAudioDeviceDisconnect,
    required bool requestAudioFocus,
    required bool pauseOnTransientAudioFocusLoss,
    required bool resumeAfterTransientAudioFocusGain,
  }) async => const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume,
  ) async => const NativeSuccess();

  @override
  Future<NativeResult<void>> removeSession(String sessionId) async =>
      const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) async => const NativeSuccess();
}

class _GatedPlaybackRepository extends NativePlaybackRepository {
  Completer<void>? playGate;
  Completer<void>? pauseGate;
  final List<String> preparedSessionIds = <String>[];
  final List<String> playedSessionIds = <String>[];
  final List<String> pausedSessionIds = <String>[];

  @override
  void startListening() {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<NativeResult<NativePlaybackSnapshot>> prepareSession({
    required String sessionId,
    required Uri uri,
    required String title,
    String? path,
    String? subtitle,
    Uri? artUri,
    Duration startPosition = Duration.zero,
    double volume = 1.0,
    bool repeatOne = false,
    bool autoPlay = false,
    double speed = 1.0,
    NativeAudioEffects? audioEffects,
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
    List<Uri>? candidateUris,
    bool deferPlayerCreation = false,
    bool isTemporary = false,
    bool reuseExistingQueue = false,
  }) async {
    preparedSessionIds.add(sessionId);
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    bool exclusive = false,
    int transportCommandId = 0,
  }) async {
    playedSessionIds.add(sessionId);
    final gate = playGate;
    if (gate != null) await gate.future;
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) async {
    pausedSessionIds.add(sessionId);
    final gate = pauseGate;
    if (gate != null) await gate.future;
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setFadeMultiplier(
    String sessionId,
    double multiplier,
  ) async => const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setStopAfterCurrentTrack(
    String sessionId,
    bool enabled,
  ) async => const NativeSuccess();

  @override
  Future<NativeResult<NativePlaybackSnapshot>> removeSession(
    String sessionId,
  ) async => const NativeSuccess();
}

class _FakeVideoDisplayGateway implements VideoDisplayPlatformGateway {
  double? lastBrightness;

  @override
  Future<NativeResult<PlatformBrightnessLease>> beginBrightnessControl() async {
    lastBrightness = 0.5;
    return const NativeSuccess<PlatformBrightnessLease>(
      PlatformBrightnessLease(token: 'brightness-token', brightness: 0.5),
    );
  }

  @override
  Future<NativeResult<void>> setBrightness(
    String token,
    double brightness,
  ) async {
    lastBrightness = brightness;
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> endBrightnessControl(String token) async =>
      const NativeSuccess<void>();
}
