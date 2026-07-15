import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';

void main() {
  group('TimerFacade', () {
    test('owns timer configuration, countdown, and cancellation', () async {
      final timer = TimerFacade.create();
      addTearDown(timer.dispose);
      var stateChanges = 0;
      var runtimeSaves = 0;
      var settingsSaves = 0;
      final fadeMultipliers = <double>[];
      timer.attachRuntime(
        hasPlayingSession: () => false,
        onStateChanged: () {
          stateChanges++;
          timer.service.syncSlice(isInitialized: true);
        },
        applyFadeMultiplier: fadeMultipliers.add,
        saveSettings: () async => settingsSaves++,
        saveRuntime: () async => runtimeSaves++,
        syncNativeAlarms: () async {},
        onTimerExpired: (_) async {},
        onAutoResume: (_) async {},
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
      expect(settingsSaves, 1);
      expect(runtimeSaves, greaterThanOrEqualTo(2));
    });

    test('starts trigger countdown when playback is already active', () {
      final timer = TimerFacade.create();
      addTearDown(timer.dispose);
      timer.attachRuntime(
        hasPlayingSession: () => true,
        onStateChanged: () {
          timer.service.syncSlice(isInitialized: true);
        },
        applyFadeMultiplier: (_) {},
        saveSettings: () async {},
        saveRuntime: () async {},
        syncNativeAlarms: () async {},
        onTimerExpired: (_) async {},
        onAutoResume: (_) async {},
      );

      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));

      expect(timer.state.active, isTrue);
      expect(timer.service.timerWaitingForPlayback, isFalse);
      expect(timer.service.timerEndsAt, isNotNull);
    });

    test(
      'dispatches an overdue auto-resume through the attached runtime',
      () async {
        final timer = TimerFacade.create();
        addTearDown(timer.dispose);
        final generations = <int>[];
        timer.attachRuntime(
          hasPlayingSession: () => false,
          onStateChanged: () {},
          applyFadeMultiplier: (_) {},
          saveSettings: () async {},
          saveRuntime: () async {},
          syncNativeAlarms: () async {},
          onTimerExpired: (_) async {},
          onAutoResume: (generation) async => generations.add(generation),
        );
        timer.service
          ..timerGeneration = 7
          ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1))
          ..pausedByTimerSessionIds.add('session-a');

        timer.retryOverdueAutoResume();
        await Future<void>.delayed(Duration.zero);

        expect(generations, <int>[7]);
      },
    );
  });
}
