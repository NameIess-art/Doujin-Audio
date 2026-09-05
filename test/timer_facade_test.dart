import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
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

    test(
      'manual playback clears the completed timer pause before restarting',
      () async {
        final platform = _RecordingPowerPlatformService();
        final timerService = TimerService()
          ..timerMode = TimerMode.manual
          ..timerDuration = const Duration(minutes: 30)
          ..timerRemaining = Duration.zero
          ..pausedByTimerSessionIds.add('session-a');
        final timer = TimerFacade.create(
          service: timerService,
          powerPlatformService: platform,
        );
        addTearDown(timer.dispose);
        _attachNoopRuntime(timer);

        await timer.clearTimerPauseForManualPlayback('session-a');

        expect(timerService.pausedByTimerSessionIds, isEmpty);
        expect(timerService.timerMode, isNull);
        expect(timerService.timerDuration, isNull);
        expect(timer.hasArmedRuntime, isFalse);
        expect(platform.timerSyncs, hasLength(1));
        expect(platform.timerSyncs.single['pausedSessionIds'], isEmpty);
        expect(platform.timerSyncs.single['timerMode'], isNull);
      },
    );

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

    for (final result in <TimerExecutionResult>[
      TimerExecutionResult.stale,
      TimerExecutionResult.failed,
    ]) {
      test('$result expiry keeps a newly configured timer', () async {
        final platform = _ControlledPowerPlatformService();
        final timerService = TimerService();
        var sessionReads = 0;
        final timer = _createTimer(
          timerService,
          platform,
          sessions: () {
            sessionReads++;
            return const [];
          },
        );

        timer.configureTimer(TimerMode.manual, const Duration(milliseconds: 1));
        timer.startCountdown();
        await platform.expiryStarted.future;

        timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));
        final newGeneration = timerService.timerGeneration;
        platform.expiryResult.complete(result);
        await Future<void>.delayed(Duration.zero);

        _expectNewTimer(timerService, newGeneration);
        expect(platform.nativeRuntimeReads, 0);
        expect(sessionReads, 0);
        await _expectPersistedGeneration(newGeneration);
      });
    }

    test('stale auto resume keeps a newly configured timer', () async {
      final platform = _ControlledPowerPlatformService();
      final timerService = TimerService()
        ..timerGeneration = 7
        ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1))
        ..pausedByTimerSessionIds.add('session-a');
      final timer = _createTimer(timerService, platform);

      timer.retryOverdueAutoResume();
      await platform.autoResumeStarted.future;
      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));
      final newGeneration = timerService.timerGeneration;
      platform.autoResumeResult.complete(TimerExecutionResult.stale);
      await Future<void>.delayed(Duration.zero);

      _expectNewTimer(timerService, newGeneration);
      expect(platform.nativeRuntimeReads, 0);
      await _expectPersistedGeneration(newGeneration);
    });

    test('expiry ignores a late native runtime', () async {
      final platform = _ControlledPowerPlatformService()
        ..expiryResult.complete(TimerExecutionResult.executed);
      final timerService = TimerService();
      final timer = _createTimer(timerService, platform);

      timer.configureTimer(TimerMode.manual, const Duration(milliseconds: 1));
      timer.startCountdown();
      await platform.nativeRuntimeReadStarted.future;
      timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));
      final newGeneration = timerService.timerGeneration;
      platform.nativeRuntime.complete(<String, Object?>{
        'generation': newGeneration,
      });
      await Future<void>.delayed(Duration.zero);

      _expectNewTimer(timerService, newGeneration);
      await _expectPersistedGeneration(newGeneration);
    });

    test('stopAfterCurrentTrack toggles state and resets on cancel', () {
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

      expect(timer.stopAfterCurrentTrack, isFalse);
      expect(timer.state.stopAfterCurrentTrack, isFalse);

      timer.setStopAfterCurrentTrack(true);
      expect(timer.stopAfterCurrentTrack, isTrue);
      expect(timer.state.stopAfterCurrentTrack, isTrue);
      expect(stateChanges, 1);

      timer.setStopAfterCurrentTrack(false);
      expect(timer.stopAfterCurrentTrack, isFalse);
      expect(timer.state.stopAfterCurrentTrack, isFalse);
      expect(fadeMultipliers, contains(1.0));

      timer.setStopAfterCurrentTrack(true);
      timer.cancelTimer();
      expect(timer.stopAfterCurrentTrack, isFalse);
      expect(timer.state.stopAfterCurrentTrack, isFalse);
    });
  });
}

void _attachNoopRuntime(
  TimerFacade timer, {
  List<PlaybackSession> Function()? sessions,
}) {
  timer.attachRuntime(
    hasPlayingSession: () => false,
    sessions: sessions ?? () => const [],
    pauseSession: (_) async => false,
    activateAudioSession: () async => false,
    resumeSession: (_) async => false,
    onStateChanged: () {},
    onRuntimeRestored: () {},
    applyFadeMultiplier: (_) {},
  );
}

TimerFacade _createTimer(
  TimerService service,
  _ControlledPowerPlatformService platform, {
  List<PlaybackSession> Function()? sessions,
}) {
  final timer = TimerFacade.create(
    service: service,
    powerPlatformService: platform,
  );
  addTearDown(timer.dispose);
  _attachNoopRuntime(timer, sessions: sessions);
  return timer;
}

void _expectNewTimer(TimerService service, int generation) {
  expect(service.timerGeneration, generation);
  expect(service.timerDuration, const Duration(minutes: 5));
  expect(service.timerWaitingForPlayback, isTrue);
}

Future<void> _expectPersistedGeneration(int generation) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final preferences = await SharedPreferences.getInstance();
  final runtime =
      json.decode(preferences.getString('timer_runtime_v1')!)
          as Map<String, dynamic>;
  expect(runtime['generation'], generation);
}

final class _ControlledPowerPlatformService extends PowerPlatformService {
  _ControlledPowerPlatformService() : super(isAndroidOverride: false);

  final expiryStarted = Completer<void>();
  final expiryResult = Completer<TimerExecutionResult>();
  final autoResumeStarted = Completer<void>();
  final autoResumeResult = Completer<TimerExecutionResult>();
  final nativeRuntimeReadStarted = Completer<void>();
  final nativeRuntime = Completer<Map<dynamic, dynamic>?>();
  var nativeRuntimeReads = 0;

  @override
  Future<TimerExecutionResult> executeTimerExpiredNow(int generation) {
    if (!expiryStarted.isCompleted) expiryStarted.complete();
    return expiryResult.future;
  }

  @override
  Future<TimerExecutionResult> executeAutoResumeNow(int generation) {
    if (!autoResumeStarted.isCompleted) autoResumeStarted.complete();
    return autoResumeResult.future;
  }

  @override
  Future<Map<dynamic, dynamic>?> getNativeTimerRuntimeState() {
    nativeRuntimeReads++;
    if (!nativeRuntimeReadStarted.isCompleted) {
      nativeRuntimeReadStarted.complete();
    }
    return nativeRuntime.future;
  }
}

final class _RecordingPowerPlatformService extends PowerPlatformService {
  _RecordingPowerPlatformService() : super(isAndroidOverride: false);

  final List<Map<String, Object?>> timerSyncs = <Map<String, Object?>>[];

  @override
  Future<void> syncPlaybackTimerAlarms({
    required int? timerMode,
    required int? timerDurationMs,
    required bool timerWaitingForPlayback,
    required int? timerEndsAtWallClockMs,
    required bool autoResumeEnabled,
    required int autoResumeHour,
    required int autoResumeMinute,
    required int? autoResumeAtMs,
    required List<String> pausedSessionIds,
    required int generation,
  }) async {
    timerSyncs.add(<String, Object?>{
      'timerMode': timerMode,
      'pausedSessionIds': List<String>.from(pausedSessionIds),
    });
  }
}
