import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:doujin_audio/core/platform/video_display_platform_gateway.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/bedtime_canvas_page.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';

import 'support/app_runtime_test_fixture.dart';

final class _RecordingBedtimePowerPlatformService
    extends PowerPlatformService {
  _RecordingBedtimePowerPlatformService() : super(isAndroidOverride: false);

  final List<bool> keepScreenOnCalls = <bool>[];

  @override
  Future<bool> setKeepScreenOn(bool enabled) async {
    keepScreenOnCalls.add(enabled);
    return true;
  }
}

final class _RecordingBedtimeVideoDisplayGateway
    implements VideoDisplayPlatformGateway {
  int beginCalls = 0;
  final List<double> brightnessValues = <double>[];
  final List<String> endTokens = <String>[];

  @override
  Future<NativeResult<PlatformBrightnessLease>> beginBrightnessControl() async {
    beginCalls++;
    return const NativeSuccess<PlatformBrightnessLease>(
      PlatformBrightnessLease(
        token: 'bedtime-brightness-token',
        brightness: 0.5,
      ),
    );
  }

  @override
  Future<NativeResult<void>> setBrightness(
    String token,
    double brightness,
  ) async {
    brightnessValues.add(brightness);
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> endBrightnessControl(String token) async {
    endTokens.add(token);
    return const NativeSuccess<void>();
  }
}

void main() {
  AppRuntimeTestFixture.initialize();

  group('BedtimeCanvasPage', () {
    late _RecordingBedtimePowerPlatformService powerService;
    late AppRuntimeWidgetTestFixture fixture;

    setUp(() {
      BedtimeCanvasPage.idleDimDelay = const Duration(seconds: 15);
      BedtimeCanvasPage.screenTimeoutDelay = const Duration(minutes: 2);
      powerService = _RecordingBedtimePowerPlatformService();
      fixture = AppRuntimeWidgetTestFixture(
        powerPlatformService: powerService,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            nativePlaybackChannel,
            (_) async => <String, Object?>{'ok': true, 'value': null},
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (_) async => null,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      BedtimeCanvasPage.idleDimDelay = const Duration(seconds: 15);
      BedtimeCanvasPage.screenTimeoutDelay = const Duration(minutes: 2);
      fixture.dispose();
    });

    Future<void> performDoubleTap(WidgetTester tester, Finder finder) async {
      final center = tester.getCenter(finder);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center);
      await tester.pump();
    }

    testWidgets('manages keepScreenOn lifecycle when entering and exiting', (
      tester,
    ) async {
      await tester.pumpWidget(
        fixture.build(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(BedtimeCanvasPage.route());
                    },
                    child: const Text('Open Bedtime Canvas'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(powerService.keepScreenOnCalls, isEmpty);

      // Open BedtimeCanvasPage (PageRouteBuilder duration is 350ms)
      await tester.tap(find.text('Open Bedtime Canvas'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(powerService.keepScreenOnCalls, equals([true]));
      expect(find.byType(BedtimeCanvasPage), findsOneWidget);

      // Long press for 2 seconds to exit
      final center = tester.getCenter(find.byType(BedtimeCanvasPage));
      final gesture = await tester.startGesture(center);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Still on page at 1 second
      expect(find.byType(BedtimeCanvasPage), findsOneWidget);

      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // BedtimeCanvasPage should be popped, and keepScreenOn(false) called
      expect(find.byType(BedtimeCanvasPage), findsNothing);
      expect(powerService.keepScreenOnCalls, equals([true, false]));
    });

    testWidgets('shows correct timer text for stopAfterCurrentTrack and active timer', (
      tester,
    ) async {
      final i18n = fixture.languageProvider;

      // 1. Initially no timer set
      await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
      await tester.pump();

      expect(find.text(i18n.tr('no_timer_set')), findsOneWidget);

      // 2. stopAfterCurrentTrack enabled
      fixture.timer.setStopAfterCurrentTrack(true);
      await tester.pump();

      expect(find.text(i18n.tr('stop_after_current_track')), findsOneWidget);

      // 3. active countdown timer
      fixture.timer.setStopAfterCurrentTrack(false);
      fixture.timer.configureTimer(TimerMode.manual, const Duration(minutes: 30));
      fixture.timer.startCountdown();
      await tester.pump();

      expect(find.textContaining(i18n.tr('sleep_countdown')), findsOneWidget);

      fixture.timer.cancelTimer();
      await tester.pump();
    });

    testWidgets(
      'double tap pauses and resumes multiple selected/playing sessions (not first in playlist)',
      (tester) async {
        // Session 1: first in playlist, paused
        final session1 = PlaybackSession(
          id: 'test-session-1',
          currentTrackPath: '/music/track1.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.8,
          createdAt: DateTime(2026),
          state: PlayerState(false, ProcessingState.ready),
        );
        // Session 2: playing
        final session2 = PlaybackSession(
          id: 'test-session-2',
          currentTrackPath: '/music/track2.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.6,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        // Session 3: playing
        final session3 = PlaybackSession(
          id: 'test-session-3',
          currentTrackPath: '/music/track3.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.7,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );

        fixture.playbackService.registerSession(session1);
        fixture.playbackService.registerSession(session2);
        fixture.playbackService.registerSession(session3);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session1, session2, session3],
          playingSessionCount: 2,
          focusedSessionId: session2.id,
          multiThreadPlaybackEnabled: true,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
        await tester.pump();

        // 1. Double tap while sessions 2 & 3 are playing -> should pause them
        await performDoubleTap(tester, find.byType(BedtimeCanvasPage));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

        // Update sessions to paused state
        session2.state = PlayerState(false, ProcessingState.ready);
        session3.state = PlayerState(false, ProcessingState.ready);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session1, session2, session3],
          playingSessionCount: 0,
          focusedSessionId: session2.id,
          multiThreadPlaybackEnabled: true,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pump(const Duration(seconds: 1)); // drain feedback

        // 2. Double tap while paused -> should resume sessions 2 & 3, NOT session 1!
        await performDoubleTap(tester, find.byType(BedtimeCanvasPage));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
        // Session 1 remains not playing
        expect(session1.effectivePlaying, isFalse);

        // Drain feedback timer before test end
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'vertical drag adjusts volume for multiple selected/playing sessions',
      (tester) async {
        final sessionA = PlaybackSession(
          id: 'test-session-a',
          currentTrackPath: '/music/a.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.5,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        final sessionB = PlaybackSession(
          id: 'test-session-b',
          currentTrackPath: '/music/b.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.6,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        fixture.playbackService.registerSession(sessionA);
        fixture.playbackService.registerSession(sessionB);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[sessionA, sessionB],
          playingSessionCount: 2,
          focusedSessionId: sessionA.id,
          multiThreadPlaybackEnabled: true,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
        await tester.pump();

        // Drag up (negative delta Y) increases volume for both sessions
        await tester.drag(
          find.byType(BedtimeCanvasPage),
          const Offset(0, -100),
        );
        await tester.pump();

        expect(sessionA.volume, greaterThan(0.5));
        expect(sessionB.volume, greaterThan(0.6));

        // Drain feedback timer before test end
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets('horizontal swipe does not perform track skipping', (
      tester,
    ) async {
      final session = PlaybackSession(
        id: 'test-session-no-swipe',
        currentTrackPath: '/music/test.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.5,
        createdAt: DateTime(2026),
        state: PlayerState(true, ProcessingState.ready),
      );
      fixture.playbackService.registerSession(session);
      fixture.playbackService.syncSlice(
        activeSessions: <PlaybackSession>[session],
        playingSessionCount: 1,
        focusedSessionId: session.id,
        multiThreadPlaybackEnabled: false,
        coverGeneration: 0,
        isInitialized: true,
      );

      await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
      await tester.pump();

      // Swipe left (negative X) -> should not skip track
      await tester.fling(
        find.byType(BedtimeCanvasPage),
        const Offset(-400, 0),
        1000,
      );
      await tester.pump();

      expect(find.byIcon(Icons.skip_next_rounded), findsNothing);
      expect(find.byIcon(Icons.skip_previous_rounded), findsNothing);

      // Verify updated bottom hints
      final i18n = fixture.languageProvider;
      expect(find.text(i18n.tr('swipe_to_adjust_track_volume')), findsOneWidget);
      expect(find.text(i18n.tr('hold_to_exit_sleep_mode')), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('isCanvasActive flag reflects page active lifecycle', (
      tester,
    ) async {
      expect(BedtimeCanvasPage.isCanvasActive, isFalse);

      await tester.pumpWidget(
        fixture.build(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(BedtimeCanvasPage.route());
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(BedtimeCanvasPage.isCanvasActive, isFalse);

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(BedtimeCanvasPage.isCanvasActive, isTrue);

      Navigator.of(tester.element(find.byType(BedtimeCanvasPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(BedtimeCanvasPage.isCanvasActive, isFalse);
    });

    testWidgets(
      'acquires brightness lease at 0.01 and restores it on dispose',
      (tester) async {
        final display = _RecordingBedtimeVideoDisplayGateway();
        await tester.pumpWidget(
          fixture.build(
            Navigator(
              onGenerateRoute: (settings) => MaterialPageRoute(
                builder: (context) => const BedtimeCanvasPage(),
              ),
            ),
            overrides: [
              videoDisplayPlatformGatewayProvider.overrideWithValue(display),
            ],
          ),
        );
        await tester.pump();

        expect(display.beginCalls, equals(1));
        expect(display.brightnessValues, equals([0.01]));
        expect(display.endTokens, isEmpty);

        Navigator.of(tester.element(find.byType(BedtimeCanvasPage))).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(display.endTokens, equals(['bedtime-brightness-token']));
      },
    );

    testWidgets(
      'stops breathing animation after idleDimDelay and wakes upon touch',
      (tester) async {
        BedtimeCanvasPage.idleDimDelay = const Duration(seconds: 15);

        await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
        await tester.pump();

        // Initially breathing animation is active
        // Fast forward 15 seconds: idle timeout triggers animateTo(0.0)
        await tester.pump(const Duration(seconds: 15));
        // Wait for animateTo(0.0) duration (1200ms) to complete
        await tester.pump(const Duration(milliseconds: 1300));

        // After stopping at 0.0, the opacity should be at baseline 0.16
        final textFinder = find.textContaining(':');
        expect(textFinder, findsOneWidget);
        final textWidget = tester.widget<Text>(textFinder);
        expect(textWidget.style?.color?.a, closeTo(0.16, 0.01));

        // Touch the screen (PointerDown) to wake breathing animation
        final center = tester.getCenter(find.byType(BedtimeCanvasPage));
        final gesture = await tester.startGesture(center);
        await tester.pump();
        await gesture.up();
        await tester.pump();

        // Advance 2 seconds into breathing animation (tween between 0.16 and 0.42)
        await tester.pump(const Duration(seconds: 2));
        final textWidgetAfterTouch = tester.widget<Text>(find.textContaining(':'));
        expect(textWidgetAfterTouch.style?.color?.a, greaterThan(0.18));
      },
    );

    testWidgets(
      'releases keepScreenOn after screenTimeoutDelay if no audio playing and no active timer',
      (tester) async {
        BedtimeCanvasPage.screenTimeoutDelay = const Duration(minutes: 2);

        await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
        await tester.pump();

        expect(powerService.keepScreenOnCalls, equals([true]));

        // Advance 1 minute (less than 2 min timeout): keepScreenOn still true
        await tester.pump(const Duration(minutes: 1));
        expect(powerService.keepScreenOnCalls, equals([true]));

        // Advance past 2 minutes: keepScreenOn is released (false)
        await tester.pump(const Duration(minutes: 1, seconds: 5));
        expect(powerService.keepScreenOnCalls, equals([true, false]));

        // Tap on screen: wake up and re-acquire keepScreenOn
        final center = tester.getCenter(find.byType(BedtimeCanvasPage));
        final gesture = await tester.startGesture(center);
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(powerService.keepScreenOnCalls, equals([true, false, true]));

        // Drain gesture double tap timeout before test teardown
        await tester.pump(const Duration(seconds: 1));
      },
    );

    testWidgets(
      'audio playback keeps screen on and prevents inactivity timeout',
      (tester) async {
        BedtimeCanvasPage.screenTimeoutDelay = const Duration(minutes: 2);

        final session = PlaybackSession(
          id: 'test-session-power',
          currentTrackPath: '/music/test.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.8,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        fixture.playbackService.registerSession(session);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session],
          playingSessionCount: 1,
          focusedSessionId: session.id,
          multiThreadPlaybackEnabled: false,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const BedtimeCanvasPage()));
        await tester.pump();

        expect(powerService.keepScreenOnCalls, equals([true]));

        // Advance 5 minutes while audio is playing
        await tester.pump(const Duration(minutes: 5));
        // Screen should still be on, no keepScreenOn(false) call
        expect(powerService.keepScreenOnCalls, equals([true]));
      },
    );
  });

  group('SettingsRepository SleepModeAutoTrigger', () {
    test('defaults to manual, persists, syncs, and resets', () async {
      final repository = SettingsRepository();
      expect(repository.sleepModeAutoTrigger, SleepModeAutoTrigger.manual);
      expect(
        repository.slice.state.sleepModeAutoTrigger,
        SleepModeAutoTrigger.manual,
      );

      await repository.setSleepModeAutoTrigger(
        SleepModeAutoTrigger.afterPlayback5min,
      );
      expect(
        repository.sleepModeAutoTrigger,
        SleepModeAutoTrigger.afterPlayback5min,
      );
      expect(
        repository.slice.state.sleepModeAutoTrigger,
        SleepModeAutoTrigger.afterPlayback5min,
      );

      await repository.resetPersistedState();
      expect(repository.sleepModeAutoTrigger, SleepModeAutoTrigger.manual);
      expect(
        repository.slice.state.sleepModeAutoTrigger,
        SleepModeAutoTrigger.manual,
      );
      await repository.dispose();
    });
  });

  group('MainScreen SleepModeAutoTrigger', () {
    late _RecordingBedtimePowerPlatformService powerService;
    late AppRuntimeWidgetTestFixture fixture;

    setUp(() {
      powerService = _RecordingBedtimePowerPlatformService();
      fixture = AppRuntimeWidgetTestFixture(
        powerPlatformService: powerService,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            nativePlaybackChannel,
            (_) async => <String, Object?>{'ok': true, 'value': null},
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (_) async => null,
          );
      MainScreen.sleepModeAutoTriggerDelay = const Duration(minutes: 5);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      MainScreen.sleepModeAutoTriggerDelay = const Duration(minutes: 5);
      fixture.dispose();
    });

    testWidgets(
      'automatically enters BedtimeCanvasPage after 5 min of playback',
      (tester) async {
        await fixture.settings.setSleepModeAutoTrigger(
          SleepModeAutoTrigger.afterPlayback5min,
        );

        final session = PlaybackSession(
          id: 'test-session-auto',
          currentTrackPath: '/music/test.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.8,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        fixture.playbackService.registerSession(session);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session],
          playingSessionCount: 1,
          focusedSessionId: session.id,
          multiThreadPlaybackEnabled: false,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const MainScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));

        expect(find.byType(BedtimeCanvasPage), findsNothing);

        // Advance 4 minutes (not yet triggered)
        await tester.pump(const Duration(minutes: 4));
        expect(find.byType(BedtimeCanvasPage), findsNothing);

        // Advance remaining 1 minute + route transition
        await tester.pump(const Duration(minutes: 1));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(BedtimeCanvasPage), findsOneWidget);
      },
    );

    testWidgets(
      'cancels auto-entry if playback is paused before 5 min',
      (tester) async {
        await fixture.settings.setSleepModeAutoTrigger(
          SleepModeAutoTrigger.afterPlayback5min,
        );

        final session = PlaybackSession(
          id: 'test-session-pause',
          currentTrackPath: '/music/test.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.8,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        fixture.playbackService.registerSession(session);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session],
          playingSessionCount: 1,
          focusedSessionId: session.id,
          multiThreadPlaybackEnabled: false,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const MainScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));

        // Advance 2 minutes
        await tester.pump(const Duration(minutes: 2));

        // Pause playback
        session.state = PlayerState(false, ProcessingState.ready);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          multiThreadPlaybackEnabled: false,
          coverGeneration: 0,
          isInitialized: true,
        );
        await tester.pump();

        // Advance another 4 minutes (total elapsed > 5 min, but paused)
        await tester.pump(const Duration(minutes: 4));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(BedtimeCanvasPage), findsNothing);
      },
    );

    testWidgets(
      'automatically enters BedtimeCanvasPage after 5 min of countdown',
      (tester) async {
        await fixture.settings.setSleepModeAutoTrigger(
          SleepModeAutoTrigger.afterCountdown5min,
        );

        fixture.timer.configureTimer(
          TimerMode.manual,
          const Duration(minutes: 30),
        );
        fixture.timer.startCountdown();

        await tester.pumpWidget(fixture.build(const MainScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));

        expect(find.byType(BedtimeCanvasPage), findsNothing);

        // Advance 4 minutes
        await tester.pump(const Duration(minutes: 4));
        expect(find.byType(BedtimeCanvasPage), findsNothing);

        // Advance remaining 1 minute + route transition
        await tester.pump(const Duration(minutes: 1));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(BedtimeCanvasPage), findsOneWidget);

        fixture.timer.cancelTimer();
        await tester.pump();
      },
    );

    testWidgets(
      'does not enter BedtimeCanvasPage when manual even after 5 min',
      (tester) async {
        await fixture.settings.setSleepModeAutoTrigger(
          SleepModeAutoTrigger.manual,
        );

        final session = PlaybackSession(
          id: 'test-session-manual',
          currentTrackPath: '/music/test.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 0.8,
          createdAt: DateTime(2026),
          state: PlayerState(true, ProcessingState.ready),
        );
        fixture.playbackService.registerSession(session);
        fixture.playbackService.syncSlice(
          activeSessions: <PlaybackSession>[session],
          playingSessionCount: 1,
          focusedSessionId: session.id,
          multiThreadPlaybackEnabled: false,
          coverGeneration: 0,
          isInitialized: true,
        );

        await tester.pumpWidget(fixture.build(const MainScreen()));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));

        // Advance 6 minutes
        await tester.pump(const Duration(minutes: 6));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(BedtimeCanvasPage), findsNothing);
      },
    );
  });
}
