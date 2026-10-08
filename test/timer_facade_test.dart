import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
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
    testWidgets(
      'ordinary countdown only writes fade at transitions and during fade',
      (tester) async {
        final service = TimerService();
        final multipliers = <double>[];
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: _RecordingPowerPlatformService(),
        );
        addTearDown(timer.dispose);
        _attachNoopRuntime(timer, applyFadeMultiplier: multipliers.add);
        timer.configureTimer(TimerMode.manual, const Duration(minutes: 5));
        timer.startCountdown();
        multipliers.clear();

        for (var tick = 0; tick < 3; tick++) {
          service.timerEndsAt = DateTime.now().add(Duration(minutes: 4 - tick));
          await tester.pump(const Duration(seconds: 1));
        }
        expect(multipliers, isEmpty);

        service.timerEndsAt = DateTime.now().add(const Duration(seconds: 10));
        await tester.pump(const Duration(seconds: 1));
        expect(multipliers, hasLength(1));
        expect(multipliers.single, inExclusiveRange(0.0, 1.0));
        timer.configureTimer(TimerMode.manual, const Duration(minutes: 5));
        expect(multipliers.last, 1.0);
        timer.startCountdown();
        timer.cancelTimer();
        expect(multipliers.last, 1.0);
      },
    );

    testWidgets('restored countdown resets fade once before ordinary ticks', (
      tester,
    ) async {
      final service = TimerService()
        ..timerMode = TimerMode.manual
        ..timerDuration = const Duration(minutes: 5)
        ..timerActive = true
        ..timerRemaining = const Duration(minutes: 5)
        ..timerEndsAt = DateTime.now().add(const Duration(minutes: 5));
      final multipliers = <double>[];
      final timer = TimerFacade.create(
        service: service,
        powerPlatformService: _RecordingPowerPlatformService(),
      );
      addTearDown(timer.dispose);
      _attachNoopRuntime(timer, applyFadeMultiplier: multipliers.add);
      timer.restoreCountdownTimer();
      expect(multipliers, [1.0]);
      service.timerEndsAt = DateTime.now().add(const Duration(minutes: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(multipliers, [1.0]);
      timer.cancelTimer();
    });

    test(
      'track end captures playback intent and fades each target independently',
      () async {
        final multipliers = <(String, double)>[];
        final first = _TestSession('first')..requested = true;
        final second = _TestSession('second')..requested = true;
        final sessions = <PlaybackSession>[first, second];
        final commands = <(String, bool)>[];
        final timer = TimerFacade.create();
        addTearDown(timer.dispose);
        _attachNoopRuntime(
          timer,
          sessions: () => sessions,
          applySessionFadeMultiplier: (id, value) =>
              multipliers.add((id, value)),
          setNativeTrackStop: (id, enabled) async {
            commands.add((id, enabled));
            return true;
          },
        );
        timer.setStopAfterCurrentTrack(true);
        await timer.pendingTrackStopSync;
        sessions.add(_TestSession('new')..requested = true);
        expect(commands, [('first', true), ('second', true)]);
        timer.applyTrackEndFade('first', 0.8);
        timer.applyTrackEndFade('first', 0.3);
        timer.applyTrackEndFade('second', 0.6);
        timer.applyTrackEndFade('new', 0.1);
        expect(multipliers, isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(multipliers, [('first', 0.3), ('second', 0.6)]);

        await timer.releaseTrackStopTarget('first');
        expect(timer.stopAfterCurrentTrack, true);
        expect(multipliers.last, ('first', 1.0));
        timer.applyTrackEndFade('second', 0.2);
        timer.setStopAfterCurrentTrack(false);
        await Future<void>.delayed(Duration.zero);
        expect(multipliers, [
          ('first', 0.3),
          ('second', 0.6),
          ('first', 1.0),
          ('second', 1.0),
        ]);
      },
    );

    for (final cleanup in ['reset', 'detach', 'dispose']) {
      test('$cleanup cancels a pending track end fade', () async {
        final multipliers = <double>[];
        final timer = TimerFacade.create();
        addTearDown(timer.dispose);
        _attachNoopRuntime(
          timer,
          sessions: () => [_TestSession('one')..requested = true],
          applyFadeMultiplier: multipliers.add,
          applySessionFadeMultiplier: (_, value) => multipliers.add(value),
        );
        timer.setStopAfterCurrentTrack(true);
        timer.applyTrackEndFade('one', 0.2);
        if (cleanup == 'reset') {
          timer.resetRuntimeState();
        } else if (cleanup == 'detach') {
          timer.detachRuntime();
        } else {
          await timer.dispose();
        }
        await Future<void>.delayed(Duration.zero);
        expect(multipliers, cleanup == 'reset' ? [1.0, 1.0] : [1.0]);
      });
    }

    test(
      'failed track stop commands release targets and allow retry',
      () async {
        final timer = TimerFacade.create();
        addTearDown(timer.dispose);
        var attempt = 0;
        _attachNoopRuntime(
          timer,
          sessions: () => [_TestSession('one')..requested = true],
          setNativeTrackStop: (_, enabled) async {
            if (!enabled) return true;
            attempt++;
            if (attempt == 1) return false;
            if (attempt == 2) throw StateError('channel unavailable');
            return true;
          },
        );
        for (var index = 0; index < 2; index++) {
          timer.setStopAfterCurrentTrack(true);
          await timer.pendingTrackStopSync;
          expect(timer.stopAfterCurrentTrack, false);
        }
        timer.setStopAfterCurrentTrack(true);
        await timer.pendingTrackStopSync;
        expect(timer.stopsAfterCurrentTrack('one'), true);
        await timer.clearTimerPauseForManualStop('one');
        expect(timer.stopAfterCurrentTrack, false);
        expect(attempt, 3);
      },
    );

    test(
      'stale arming skips targets and finishing every target clears toggle',
      () async {
        final timer = TimerFacade.create();
        addTearDown(timer.dispose);
        final first = _TestSession('first')..requested = true;
        final second = _TestSession('second')..requested = true;
        final sessions = [first, second];
        final calls = <(String, bool)>[];
        _attachNoopRuntime(
          timer,
          sessions: () => sessions,
          setNativeTrackStop: (id, enabled) async {
            calls.add((id, enabled));
            return true;
          },
        );
        timer.setStopAfterCurrentTrack(true);
        timer.setStopAfterCurrentTrack(false);
        timer.setStopAfterCurrentTrack(true);
        await timer.pendingTrackStopSync;
        expect(calls.where((call) => call.$2), [
          ('first', true),
          ('second', true),
        ]);
        first.requested = false;
        timer.reconcileTrackStopTargets();
        expect(timer.stopsAfterCurrentTrack('first'), false);
        expect(timer.stopAfterCurrentTrack, true);
        sessions.clear();
        timer.reconcileTrackStopTargets();
        await timer.pendingTrackStopSync;
        expect(timer.stopAfterCurrentTrack, false);
      },
    );

    for (final target in [TargetPlatform.android, TargetPlatform.windows]) {
      test(
        '$target manual confirmation synchronizes only the final timer',
        () async {
          debugDefaultTargetPlatformOverride = target;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final platform = _RecordingPowerPlatformService();
          final service = TimerService();
          final timer = TimerFacade.create(
            service: service,
            powerPlatformService: platform,
          );
          addTearDown(timer.dispose);
          _attachNoopRuntime(timer);

          timer.configureTimer(TimerMode.manual, const Duration(minutes: 5));
          timer.startCountdown();
          await timer.syncNativeAlarms();

          expect(platform.timerSyncs, hasLength(1));
          expect(
            platform.timerSyncs.single['timerEndsAtWallClockMs'],
            service.timerEndsAt!.millisecondsSinceEpoch,
          );
          expect(
            platform.timerSyncs.single['generation'],
            service.timerGeneration,
          );
        },
      );
    }

    test(
      'alarm changes wait for the previous native reply and send the latest state',
      () async {
        final platform = _RecordingPowerPlatformService();
        final gate = Completer<void>();
        platform.syncGate = gate;
        final timer = TimerFacade.create(powerPlatformService: platform);
        addTearDown(timer.dispose);
        _attachNoopRuntime(timer);
        timer.configureTimer(TimerMode.manual, const Duration(minutes: 5));
        timer.startCountdown();
        await Future<void>.delayed(Duration.zero);
        expect(platform.timerSyncs, hasLength(1));

        timer.setAutoResume(true, 8, 15);
        timer.cancelTimer();
        final finished = timer.syncNativeAlarms();
        await Future<void>.delayed(Duration.zero);
        expect(platform.timerSyncs, hasLength(1));
        gate.complete();
        await finished;

        expect(platform.timerSyncs, hasLength(2));
        expect(platform.timerSyncs.last['timerMode'], isNull);
        expect(platform.timerSyncs.last['timerEndsAtWallClockMs'], isNull);
        expect(platform.timerSyncs.last['autoResumeAtMs'], isNull);
      },
    );

    test(
      'Android auto-resume alarms wait for the paused definitions to flush',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final platform = _RecordingPowerPlatformService();
        final service = TimerService()
          ..timerGeneration = 7
          ..autoResumeAt = DateTime.now().add(const Duration(hours: 1))
          ..pausedByTimerSessionIds.addAll(['a', 'b']);
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: platform,
        );
        addTearDown(timer.dispose);
        final gate = Completer<void>();
        final flushed = <String>[];
        _attachNoopRuntime(
          timer,
          flushSessionPersistence: (id) async {
            flushed.add(id);
            if (id == 'a') await gate.future;
          },
        );
        final sync = timer.syncNativeAlarms();
        await Future<void>.delayed(Duration.zero);
        expect(flushed, ['a']);
        expect(platform.timerSyncs, isEmpty);
        gate.complete();
        await sync;
        expect(flushed, ['a', 'b']);
        expect(platform.timerSyncs.single['pausedSessionIds'], ['a', 'b']);
      },
    );

    test(
      'a changed timer invalidates an alarm blocked on cold persistence',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final platform = _RecordingPowerPlatformService();
        final service = TimerService()
          ..timerGeneration = 7
          ..autoResumeAt = DateTime.now().add(const Duration(hours: 1))
          ..pausedByTimerSessionIds.add('a');
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: platform,
        );
        addTearDown(timer.dispose);
        final gate = Completer<void>();
        _attachNoopRuntime(timer, flushSessionPersistence: (_) => gate.future);
        final sync = timer.syncNativeAlarms();
        await Future<void>.delayed(Duration.zero);
        timer.configureTimer(TimerMode.trigger, const Duration(minutes: 5));
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        await sync;
        expect(platform.timerSyncs, isNotEmpty);
        expect(
          platform.timerSyncs.every(
            (value) => value['generation'] == service.timerGeneration,
          ),
          true,
        );
        expect(
          platform.timerSyncs.every((value) => value['autoResumeAtMs'] == null),
          true,
        );
        expect(platform.timerSyncs.last['timerMode'], TimerMode.trigger.index);
      },
    );

    test(
      'Windows alarms do not register cold Android recovery definitions',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final platform = _RecordingPowerPlatformService();
        final service = TimerService()
          ..autoResumeAt = DateTime.now().add(const Duration(hours: 1))
          ..pausedByTimerSessionIds.add('a');
        final timer = TimerFacade.create(
          service: service,
          powerPlatformService: platform,
        );
        addTearDown(timer.dispose);
        final flushed = <String>[];
        _attachNoopRuntime(
          timer,
          flushSessionPersistence: (id) async => flushed.add(id),
        );
        await timer.syncNativeAlarms();
        expect(flushed, isEmpty);
        expect(platform.timerSyncs, hasLength(1));
      },
    );

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

    test('auto resume preserves a native audio-focus retry', () async {
      final retryAt = DateTime.now().add(const Duration(seconds: 30));
      final platform = _ControlledPowerPlatformService()
        ..autoResumeResult.complete(TimerExecutionResult.executed)
        ..nativeRuntime.complete(<String, Object?>{
          'generation': 7,
          'autoResumeEnabled': true,
          'autoResumeAtMs': retryAt.millisecondsSinceEpoch,
          'pausedSessionIds': ['session-a'],
        });
      final timerService = TimerService()
        ..timerGeneration = 7
        ..autoResumeAt = DateTime.now().subtract(const Duration(seconds: 1))
        ..pausedByTimerSessionIds.add('session-a');
      final timer = _createTimer(timerService, platform);

      timer.retryOverdueAutoResume();
      await platform.nativeRuntimeReadStarted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(timerService.timerGeneration, 7);
      expect(
        timerService.autoResumeAt?.millisecondsSinceEpoch,
        retryAt.millisecondsSinceEpoch,
      );
      expect(timerService.pausedByTimerSessionIds, ['session-a']);
      expect(timerService.autoResumeTimer?.isActive, true);
      await _expectPersistedGeneration(7);
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
        sessions: () => [_TestSession('one')..requested = true],
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
      expect(fadeMultipliers, isEmpty);

      timer.setStopAfterCurrentTrack(true);
      timer.cancelTimer();
      expect(timer.stopAfterCurrentTrack, isFalse);
      expect(timer.state.stopAfterCurrentTrack, isFalse);
    });

    test('auto-resume ramps fade multiplier from 0.0 to 1.0', () async {
      final platform = _ControlledPowerPlatformService();
      final timerService = TimerService()
        ..autoResumeEnabled = true
        ..autoResumeAt = DateTime.now().subtract(const Duration(minutes: 1))
        ..pausedByTimerSessionIds.add('session-1');
      final timer = TimerFacade.create(
        service: timerService,
        powerPlatformService: platform,
        resumeFadeInDuration: const Duration(milliseconds: 250),
      );
      addTearDown(timer.dispose);

      final fadeMultipliers = <double>[];
      final resumedSessions = <String>[];
      final session = _TestSession('session-1');

      timer.attachRuntime(
        hasPlayingSession: () => false,
        sessions: () => [session],
        pauseSession: (_) async => true,
        activateAudioSession: () async => true,
        resumeSession: (s) async {
          resumedSessions.add(s.id);
          return true;
        },
        onStateChanged: () {},
        onRuntimeRestored: () {},
        applyFadeMultiplier: fadeMultipliers.add,
      );

      platform.autoResumeResult.complete(TimerExecutionResult.failed);
      timer.retryOverdueAutoResume();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(resumedSessions, contains('session-1'));
      expect(fadeMultipliers.first, 0.0);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fadeMultipliers.last, 1.0);
      expect(fadeMultipliers.length, greaterThan(2));
    });
  });
}

class _TestSession extends Fake implements PlaybackSession {
  _TestSession(this.id);
  @override
  final String id;
  @override
  bool get effectivePlaying => false;
  bool requested = false;
  @override
  bool get playbackRequested => requested;
  @override
  String get currentTrackPath => id;
  @override
  bool get nativeStopAfterCurrentTrack => true;
  @override
  bool get isLoading => false;
  @override
  String? get pendingNativeTrackPath => null;
}

void _attachNoopRuntime(
  TimerFacade timer, {
  List<PlaybackSession> Function()? sessions,
  Future<void> Function(String sessionId)? flushSessionPersistence,
  void Function(double multiplier)? applyFadeMultiplier,
  void Function(String, double)? applySessionFadeMultiplier,
  Future<bool> Function(String, bool)? setNativeTrackStop,
}) {
  timer.attachRuntime(
    hasPlayingSession: () => false,
    sessions: sessions ?? () => const [],
    pauseSession: (_) async => false,
    activateAudioSession: () async => false,
    resumeSession: (_) async => false,
    onStateChanged: () {},
    onRuntimeRestored: () {},
    applyFadeMultiplier: applyFadeMultiplier ?? (_) {},
    flushSessionPersistence: flushSessionPersistence,
    applySessionFadeMultiplier: applySessionFadeMultiplier,
    setNativeTrackStop: setNativeTrackStop,
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
  Completer<void>? syncGate;

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
      'timerEndsAtWallClockMs': timerEndsAtWallClockMs,
      'pausedSessionIds': List<String>.from(pausedSessionIds),
      'generation': generation,
      'autoResumeAtMs': autoResumeAtMs,
    });
    await syncGate?.future;
  }
}
