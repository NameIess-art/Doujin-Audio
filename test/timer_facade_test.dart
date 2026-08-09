import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('TimerFacade', () {
    test('owns timer configuration, countdown, and cancellation', () async {
      final timerService = TimerService();
      final timer = TimerFacade.create(service: timerService);
      addTearDown(timer.dispose);
      var stateChanges = 0;
      final fadeMultipliers = <double>[];
      timer.attachRuntime(
        hasPlayingSession: () => false,
        sessions: () => const [],
        pauseSession: (_) async => false,
        activateAudioSession: () async => false,
        resumeSession: (_) async => false,
        onStateChanged: () {
          stateChanges++;
          timerService.syncSlice(isInitialized: true);
        },
        onRuntimeRestored: () {},
        applyFadeMultiplier: fadeMultipliers.add,
      );

      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 10));
      await Future<void>.delayed(Duration.zero);

      expect(timerService.timerWaitingForPlayback, isTrue);
      expect(timer.state.duration, const Duration(minutes: 10));
      expect(timer.hasArmedRuntime, isTrue);

      timer.startCountdown();
      expect(timer.state.active, isTrue);
      expect(timerService.timerWaitingForPlayback, isFalse);

      timer.cancelTimer();
      await Future<void>.delayed(Duration.zero);

      expect(timer.state.duration, isNull);
      expect(timer.state.active, isFalse);
      expect(timer.hasArmedRuntime, isFalse);
      expect(fadeMultipliers, contains(1.0));
      expect(stateChanges, greaterThanOrEqualTo(3));
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('timer_settings_v1'), isTrue);
      expect(preferences.containsKey('timer_runtime_v1'), isFalse);
    });

    test('starts trigger countdown when playback is already active', () {
      final timerService = TimerService();
      final timer = TimerFacade.create(service: timerService);
      addTearDown(timer.dispose);
      timer.attachRuntime(
        hasPlayingSession: () => true,
        sessions: () => const [],
        pauseSession: (_) async => false,
        activateAudioSession: () async => false,
        resumeSession: (_) async => false,
        onStateChanged: () {
          timerService.syncSlice(isInitialized: true);
        },
        onRuntimeRestored: () {},
        applyFadeMultiplier: (_) {},
      );

      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));

      expect(timer.state.active, isTrue);
      expect(timerService.timerWaitingForPlayback, isFalse);
      expect(timerService.timerEndsAt, isNotNull);
    });

    test('retains overdue sessions when playback activation fails', () async {
      final timerService = TimerService();
      final timer = TimerFacade.create(
        service: timerService,
        powerPlatformService: PowerPlatformService(isAndroidOverride: false),
      );
      addTearDown(timer.dispose);
      var activationCount = 0;
      timer.attachRuntime(
        hasPlayingSession: () => false,
        sessions: () => const [],
        pauseSession: (_) async => false,
        activateAudioSession: () async {
          activationCount++;
          return false;
        },
        resumeSession: (_) async => false,
        onStateChanged: () {},
        onRuntimeRestored: () {},
        applyFadeMultiplier: (_) {},
      );
      timerService
        ..timerGeneration = 7
        ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1))
        ..pausedByTimerSessionIds.add('session-a');

      timer.retryOverdueAutoResume();
      await Future<void>.delayed(Duration.zero);

      expect(activationCount, 1);
      expect(timerService.pausedByTimerSessionIds, <String>['session-a']);
      expect(timerService.autoResumeAt, isNotNull);
    });

    test('loads persisted settings and a pending trigger runtime', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'timer_settings_v1': json.encode(<String, Object>{
          'autoResumeEnabled': true,
          'autoResumeHour': 8,
          'autoResumeMinute': 15,
          'timerDraftMode': TimerMode.trigger.index,
          'timerDraftDurationMs': 45 * 60 * 1000,
        }),
        'timer_runtime_v1': json.encode(<String, Object>{
          'timerMode': TimerMode.trigger.index,
          'timerDurationMs': 10 * 60 * 1000,
          'timerWaitingForPlayback': true,
          'autoResumeEnabled': true,
          'autoResumeHour': 8,
          'autoResumeMinute': 15,
          'pausedSessionIds': <String>[],
          'generation': 4,
        }),
      });
      final timerService = TimerService();
      final timer = TimerFacade.create(service: timerService);
      addTearDown(timer.dispose);
      var restoreCount = 0;
      timer.attachRuntime(
        hasPlayingSession: () => false,
        sessions: () => const [],
        pauseSession: (_) async => false,
        activateAudioSession: () async => false,
        resumeSession: (_) async => false,
        onStateChanged: () {},
        onRuntimeRestored: () => restoreCount++,
        applyFadeMultiplier: (_) {},
      );

      await timer.loadPersistedState();
      await timer.loadRuntimeFromSystem();

      expect(timerService.autoResumeEnabled, isTrue);
      expect(timerService.autoResumeHour, 8);
      expect(timerService.autoResumeMinute, 15);
      expect(timerService.timerDraftMode, TimerMode.trigger);
      expect(timerService.timerDraftDuration, const Duration(minutes: 45));
      expect(timerService.timerMode, TimerMode.trigger);
      expect(timerService.timerDuration, const Duration(minutes: 10));
      expect(timerService.timerWaitingForPlayback, isTrue);
      expect(timerService.timerGeneration, 4);
      expect(restoreCount, 1);
    });
  });
}
