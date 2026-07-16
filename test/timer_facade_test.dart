import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/core/platform/power_platform_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('TimerFacade', () {
    test('owns timer configuration, countdown, and cancellation', () async {
      final timer = TimerFacade.create();
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
          timer.service.syncSlice(isInitialized: true);
        },
        onRuntimeRestored: () {},
        applyFadeMultiplier: fadeMultipliers.add,
      );

      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 10));
      await Future<void>.delayed(Duration.zero);

      expect(timer.service.timerWaitingForPlayback, isTrue);
      expect(timer.state.duration, const Duration(minutes: 10));
      expect(timer.hasArmedRuntime, isTrue);

      timer.startCountdown();
      expect(timer.state.active, isTrue);
      expect(timer.service.timerWaitingForPlayback, isFalse);

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
      final timer = TimerFacade.create();
      addTearDown(timer.dispose);
      timer.attachRuntime(
        hasPlayingSession: () => true,
        sessions: () => const [],
        pauseSession: (_) async => false,
        activateAudioSession: () async => false,
        resumeSession: (_) async => false,
        onStateChanged: () {
          timer.service.syncSlice(isInitialized: true);
        },
        onRuntimeRestored: () {},
        applyFadeMultiplier: (_) {},
      );

      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));

      expect(timer.state.active, isTrue);
      expect(timer.service.timerWaitingForPlayback, isFalse);
      expect(timer.service.timerEndsAt, isNotNull);
    });

    test('retains overdue sessions when playback activation fails', () async {
      final timer = TimerFacade.create(
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
      timer.service
        ..timerGeneration = 7
        ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1))
        ..pausedByTimerSessionIds.add('session-a');

      timer.retryOverdueAutoResume();
      await Future<void>.delayed(Duration.zero);

      expect(activationCount, 1);
      expect(timer.service.pausedByTimerSessionIds, <String>['session-a']);
      expect(timer.service.autoResumeAt, isNotNull);
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
      final timer = TimerFacade.create();
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

      expect(timer.service.autoResumeEnabled, isTrue);
      expect(timer.service.autoResumeHour, 8);
      expect(timer.service.autoResumeMinute, 15);
      expect(timer.service.timerDraftMode, TimerMode.trigger);
      expect(timer.service.timerDraftDuration, const Duration(minutes: 45));
      expect(timer.service.timerMode, TimerMode.trigger);
      expect(timer.service.timerDuration, const Duration(minutes: 10));
      expect(timer.service.timerWaitingForPlayback, isTrue);
      expect(timer.service.timerGeneration, 4);
      expect(restoreCount, 1);
    });
  });
}
