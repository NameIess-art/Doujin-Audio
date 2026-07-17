import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/power_platform_service.dart';
import '../domain/playback_mode.dart';
import 'audio_state_services.dart';
import 'playback_session.dart';
import 'timer_runtime_calculator.dart';

/// Owns timer state and timer-related platform power coordination.
final class TimerFacade {
  TimerFacade({
    required this.service,
    required this.powerPlatformService,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  factory TimerFacade.create({
    TimerService? service,
    PowerPlatformService? powerPlatformService,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) {
    return TimerFacade(
      service: service ?? TimerService(),
      powerPlatformService: powerPlatformService ?? PowerPlatformService(),
      preferencesLoader: preferencesLoader,
    );
  }

  final TimerService service;
  final PowerPlatformService powerPlatformService;
  final Future<SharedPreferences> Function() _preferencesLoader;
  SharedPreferences? _cachedPreferences;
  static const String _settingsKey = 'timer_settings_v1';
  static const String _runtimeKey = 'timer_runtime_v1';
  static const TimerRuntimeCalculator _runtimeCalculator =
      TimerRuntimeCalculator();

  bool Function() _hasPlayingSession = () => false;
  Iterable<PlaybackSession> Function() _sessions = _emptySessions;
  Future<bool> Function(PlaybackSession session) _pauseSession = _falseSession;
  Future<bool> Function() _activateAudioSession = _falseAsync;
  Future<bool> Function(PlaybackSession session) _resumeSession = _falseSession;
  void Function() _onStateChanged = _noop;
  void Function() _onRuntimeRestored = _noop;
  void Function(double multiplier) _applyFadeMultiplier = _noopFade;

  TimerStateSliceData get state => service.slice.state;
  Stream<TimerStateSliceData> get states => service.slice.stream;

  bool get hasArmedRuntime => _runtimeCalculator.hasArmedRuntime(
    mode: service.timerMode,
    duration: service.timerDuration,
    waitingForPlayback: service.timerWaitingForPlayback,
    active: service.timerActive,
    endsAt: service.timerEndsAt,
    autoResumeAt: service.autoResumeAt,
    hasPausedByTimerSessionIds: service.pausedByTimerSessionIds.isNotEmpty,
  );

  void attachRuntime({
    required bool Function() hasPlayingSession,
    required Iterable<PlaybackSession> Function() sessions,
    required Future<bool> Function(PlaybackSession session) pauseSession,
    required Future<bool> Function() activateAudioSession,
    required Future<bool> Function(PlaybackSession session) resumeSession,
    required void Function() onStateChanged,
    required void Function() onRuntimeRestored,
    required void Function(double multiplier) applyFadeMultiplier,
  }) {
    _hasPlayingSession = hasPlayingSession;
    _sessions = sessions;
    _pauseSession = pauseSession;
    _activateAudioSession = activateAudioSession;
    _resumeSession = resumeSession;
    _onStateChanged = onStateChanged;
    _onRuntimeRestored = onRuntimeRestored;
    _applyFadeMultiplier = applyFadeMultiplier;
  }

  void configureTimer(TimerMode mode, Duration duration) {
    service.timerDraftMode = mode;
    service.timerDraftDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    _cancelTimerInternal();
    service.timerMode = mode;
    service.timerDuration = duration;
    service.timerRemaining = duration;
    service.timerEndsAt = null;
    service.timerActive = false;
    service.timerWaitingForPlayback = mode == TimerMode.trigger;
    if (mode == TimerMode.trigger && _hasPlayingSession()) {
      startCountdown();
      return;
    }
    _changed();
    unawaited(saveSettings());
    unawaited(saveRuntime());
    unawaited(syncNativeAlarms());
  }

  void startCountdown() {
    if (service.timerDuration == null || service.timerActive) return;
    service.countdownTimer?.cancel();
    final generation = ++service.timerGeneration;
    service.timerActive = true;
    service.timerWaitingForPlayback = false;
    service.timerRemaining = service.timerDuration;
    service.timerEndsAt = DateTime.now().add(service.timerDuration!);
    service.countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (generation != service.timerGeneration) return;
      _tickCountdown();
    });
    _changed();
    unawaited(saveRuntime());
    unawaited(syncNativeAlarms());
  }

  void cancelTimer() {
    resetRuntimeState();
    _changed();
    unawaited(saveRuntime());
    unawaited(syncNativeAlarms());
  }

  void setTimerDraft(TimerMode mode, Duration duration) {
    final normalizedDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    if (service.timerDraftMode == mode &&
        service.timerDraftDuration == normalizedDuration) {
      return;
    }
    service.timerDraftMode = mode;
    service.timerDraftDuration = normalizedDuration;
    _changed();
    unawaited(saveSettings());
  }

  void setAutoResume(bool enabled, int hour, int minute) {
    service.autoResumeEnabled = enabled;
    service.autoResumeHour = hour;
    service.autoResumeMinute = minute;
    if (!enabled) {
      service.autoResumeTimer?.cancel();
      service.autoResumeTimer = null;
      service.autoResumeAt = null;
    } else if (service.pausedByTimerSessionIds.isNotEmpty) {
      scheduleAutoResumeTimer(
        _runtimeCalculator.nextClockTime(
          now: DateTime.now(),
          hour: hour,
          minute: minute,
        ),
      );
    }
    _changed();
    unawaited(saveSettings());
    unawaited(saveRuntime());
    unawaited(syncNativeAlarms());
  }

  void retryOverdueAutoResume() {
    final autoResumeAt = service.autoResumeAt;
    if (autoResumeAt == null || service.pausedByTimerSessionIds.isEmpty) {
      return;
    }
    if (autoResumeAt.isAfter(DateTime.now())) {
      scheduleAutoResumeTimer(autoResumeAt);
      _changed();
      unawaited(saveRuntime());
      unawaited(syncNativeAlarms());
      return;
    }
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    unawaited(_handleAutoResumeOnPlatform(service.timerGeneration));
  }

  void maybeStartTriggerCountdown() {
    if (service.timerMode != TimerMode.trigger ||
        service.timerDuration == null ||
        service.timerActive ||
        !service.timerWaitingForPlayback) {
      return;
    }
    startCountdown();
  }

  void resetRuntimeState({bool clearPausedSessions = true}) {
    service.timerGeneration++;
    service.countdownTimer?.cancel();
    service.countdownTimer = null;
    service.timerMode = null;
    service.timerDuration = null;
    service.timerActive = false;
    service.timerRemaining = null;
    service.timerEndsAt = null;
    service.timerWaitingForPlayback = false;
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    service.autoResumeAt = null;
    if (clearPausedSessions) {
      service.pausedByTimerSessionIds.clear();
    }
    _applyFadeMultiplier(1.0);
  }

  Future<void> resetForBackupRestore() async {
    _cachedPreferences = null;
    resetRuntimeState();
    service
      ..timerDraftMode = TimerMode.manual
      ..timerDraftDuration = const Duration(minutes: 30)
      ..autoResumeEnabled = false
      ..autoResumeHour = 7
      ..autoResumeMinute = 0;
  }

  void scheduleAutoResumeTimer(DateTime target) {
    service.autoResumeTimer?.cancel();
    service.autoResumeAt = target;
    final delay = target.difference(DateTime.now());
    if (delay <= Duration.zero) {
      service.autoResumeTimer = null;
      unawaited(_handleAutoResumeOnPlatform(service.timerGeneration));
      return;
    }
    service.autoResumeTimer = Timer(delay, () {
      service.autoResumeTimer = null;
      unawaited(_handleAutoResumeOnPlatform(service.timerGeneration));
    });
  }

  void restoreCountdownTimer() {
    final endsAt = service.timerEndsAt;
    if (endsAt == null) return;
    final generation = service.timerGeneration;
    service.countdownTimer?.cancel();
    service.countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (generation != service.timerGeneration) return;
      _tickCountdown();
    });
  }

  Future<void> _handleTimerExpiredOnPlatform(int generation) async {
    final result = await _executeTimerAction(
      powerPlatformService.executeTimerExpiredNow,
      generation,
    );
    if (result == TimerExecutionResult.failed) {
      await _applyLocalTimerExpiryFallback();
      return;
    }
    await syncRuntimeFromNative();
    _maybeResetTimerAfterExpiry();
    _changed();
    unawaited(saveRuntime());
  }

  Future<void> _applyLocalTimerExpiryFallback() async {
    final playingSessions = _sessions()
        .where((session) => session.effectivePlaying)
        .toList(growable: false);
    service.pausedByTimerSessionIds.clear();
    for (final session in playingSessions) {
      if (await _pauseSession(session)) {
        service.pausedByTimerSessionIds.add(session.id);
      }
    }
    if (service.autoResumeEnabled &&
        service.pausedByTimerSessionIds.isNotEmpty) {
      scheduleAutoResumeTimer(
        _runtimeCalculator.nextClockTime(
          now: DateTime.now(),
          hour: service.autoResumeHour,
          minute: service.autoResumeMinute,
        ),
      );
    }
    _maybeResetTimerAfterExpiry();
    _changed();
    await saveRuntime();
    await syncNativeAlarms();
  }

  void _maybeResetTimerAfterExpiry() {
    if (service.autoResumeAt != null ||
        service.pausedByTimerSessionIds.isNotEmpty &&
            service.autoResumeEnabled) {
      return;
    }
    resetRuntimeState();
  }

  Future<void> _handleAutoResumeOnPlatform(int generation) async {
    final result = await _executeTimerAction(
      powerPlatformService.executeAutoResumeNow,
      generation,
    );
    if (result == TimerExecutionResult.failed) {
      await _resumeTimerPausedSessions();
      return;
    }
    await syncRuntimeFromNative();
    resetRuntimeState();
    _changed();
    unawaited(saveRuntime());
  }

  Future<TimerExecutionResult> _executeTimerAction(
    Future<TimerExecutionResult> Function(int generation) action,
    int generation,
  ) async {
    try {
      return await action(generation);
    } catch (error, stackTrace) {
      AppLogService.error(
        'execute_timer_action_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return TimerExecutionResult.failed;
    }
  }

  Future<void> _resumeTimerPausedSessions() async {
    if (!await _activateAudioSession()) {
      _changed();
      await saveRuntime();
      await syncNativeAlarms();
      return;
    }
    final sessions = _sessions().toList(growable: false);
    final resumableSessions = sessions
        .where(
          (session) => service.pausedByTimerSessionIds.contains(session.id),
        )
        .toList(growable: false);
    if (resumableSessions.isEmpty) {
      service.pausedByTimerSessionIds.clear();
      _changed();
      await saveRuntime();
      await syncNativeAlarms();
      return;
    }
    for (final session in resumableSessions) {
      if (await _resumeSession(session)) {
        service.pausedByTimerSessionIds.remove(session.id);
      }
    }
    final sessionIds = sessions.map((session) => session.id).toSet();
    service.pausedByTimerSessionIds.removeWhere(
      (sessionId) => !sessionIds.contains(sessionId),
    );
    if (service.pausedByTimerSessionIds.isEmpty) {
      service.autoResumeAt = null;
      resetRuntimeState(clearPausedSessions: false);
    } else {
      service.autoResumeTimer?.cancel();
      service.autoResumeTimer = null;
    }
    _changed();
    await saveRuntime();
    await syncNativeAlarms();
  }

  Future<void> loadPersistedState() async {
    try {
      final raw = (await _preferences).getString(_settingsKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      service.autoResumeEnabled = map['autoResumeEnabled'] as bool? ?? false;
      service.autoResumeHour = map['autoResumeHour'] as int? ?? 7;
      service.autoResumeMinute = map['autoResumeMinute'] as int? ?? 0;
      final draftModeIndex = map['timerDraftMode'] as int?;
      final draftDurationMs = map['timerDraftDurationMs'] as int?;
      if (draftModeIndex != null &&
          draftModeIndex >= 0 &&
          draftModeIndex < TimerMode.values.length) {
        service.timerDraftMode = TimerMode.values[draftModeIndex];
      }
      if (draftDurationMs != null && draftDurationMs > 0) {
        service.timerDraftDuration = Duration(milliseconds: draftDurationMs);
      }
    } catch (error, stackTrace) {
      AppLogService.error(
        'timer_settings_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> saveSettings() async {
    try {
      final encoded = json.encode({
        'autoResumeEnabled': service.autoResumeEnabled,
        'autoResumeHour': service.autoResumeHour,
        'autoResumeMinute': service.autoResumeMinute,
        'timerDraftMode': service.timerDraftMode.index,
        'timerDraftDurationMs': service.timerDraftDuration.inMilliseconds,
      });
      await (await _preferences).setString(_settingsKey, encoded);
    } catch (error, stackTrace) {
      AppLogService.error(
        'timer_settings_save_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> loadRuntimeFromSystem() async {
    if (await _loadNativeRuntime()) return;
    try {
      final raw = (await _preferences).getString(_runtimeKey);
      if (raw == null || raw.isEmpty) return;
      await _restoreRuntimeFromMap(
        json.decode(raw) as Map<String, dynamic>,
        removeLegacyPrefsWhenEmpty: true,
        syncNativeAfterRestore: true,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'timer_runtime_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> syncRuntimeFromNative() async {
    await _loadNativeRuntime();
  }

  Future<void> saveRuntime() async {
    try {
      final preferences = await _preferences;
      if (!hasArmedRuntime) {
        await preferences.remove(_runtimeKey);
        return;
      }
      final encoded = json.encode({
        'timerMode': service.timerMode?.index,
        'timerDurationMs': service.timerDuration?.inMilliseconds,
        'timerWaitingForPlayback': service.timerWaitingForPlayback,
        'timerEndsAtWallClockMs': service.timerEndsAt?.millisecondsSinceEpoch,
        'autoResumeEnabled': service.autoResumeEnabled,
        'autoResumeHour': service.autoResumeHour,
        'autoResumeMinute': service.autoResumeMinute,
        'autoResumeAtMs': service.autoResumeAt?.millisecondsSinceEpoch,
        'pausedSessionIds': service.pausedByTimerSessionIds,
        'generation': service.timerGeneration,
      });
      await preferences.setString(_runtimeKey, encoded);
    } catch (error, stackTrace) {
      AppLogService.error(
        'timer_runtime_save_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> syncNativeAlarms() async {
    try {
      final autoResumeAt = service.autoResumeAt;
      await powerPlatformService.syncPlaybackTimerAlarms(
        timerMode: service.timerMode?.index,
        timerDurationMs: service.timerDuration?.inMilliseconds,
        timerWaitingForPlayback: service.timerWaitingForPlayback,
        timerEndsAtWallClockMs: service.timerActive
            ? service.timerEndsAt?.millisecondsSinceEpoch
            : null,
        autoResumeEnabled: service.autoResumeEnabled,
        autoResumeHour: service.autoResumeHour,
        autoResumeMinute: service.autoResumeMinute,
        autoResumeAtMs:
            autoResumeAt != null &&
                service.pausedByTimerSessionIds.isNotEmpty &&
                autoResumeAt.isAfter(DateTime.now())
            ? autoResumeAt.millisecondsSinceEpoch
            : null,
        pausedSessionIds: service.pausedByTimerSessionIds,
        generation: service.timerGeneration,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'sync_native_timer_alarms_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _loadNativeRuntime() async {
    try {
      final map = await powerPlatformService.getNativeTimerRuntimeState();
      if (map == null || map.isEmpty) return false;
      await _restoreRuntimeFromMap(
        map,
        removeLegacyPrefsWhenEmpty: true,
        syncNativeAfterRestore: false,
      );
      return true;
    } catch (error, stackTrace) {
      AppLogService.error(
        'native_timer_runtime_restore_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _restoreRuntimeFromMap(
    Map<dynamic, dynamic> map, {
    required bool removeLegacyPrefsWhenEmpty,
    required bool syncNativeAfterRestore,
  }) async {
    final now = DateTime.now();
    final durationMs = _readMillisValue(map['timerDurationMs']);
    final timerModeIndex = _readMillisValue(map['timerMode']);
    final waitingForPlayback = map['timerWaitingForPlayback'] as bool? ?? false;
    final timerEndsAtMs =
        _readMillisValue(map['timerEndsAtWallClockMs']) ??
        _readMillisValue(map['timerEndsAtMs']);
    final autoResumeEnabled =
        map['autoResumeEnabled'] as bool? ?? service.autoResumeEnabled;
    final autoResumeHour =
        _readMillisValue(map['autoResumeHour']) ?? service.autoResumeHour;
    final autoResumeMinute =
        _readMillisValue(map['autoResumeMinute']) ?? service.autoResumeMinute;
    final autoResumeAtMs = _readMillisValue(map['autoResumeAtMs']);
    final generation =
        _readMillisValue(map['generation']) ?? service.timerGeneration;
    final pausedSessionIds =
        (map['pausedSessionIds'] as List<dynamic>? ??
                map['pausedByTimerPaths'] as List<dynamic>? ??
                const <dynamic>[])
            .whereType<String>()
            .toList(growable: false);

    final hasPendingTrigger =
        waitingForPlayback &&
        durationMs != null &&
        durationMs > 0 &&
        timerModeIndex == TimerMode.trigger.index;
    final hasRunningCountdown =
        timerEndsAtMs != null &&
        durationMs != null &&
        timerEndsAtMs > now.millisecondsSinceEpoch;
    final hasPostTimerState =
        autoResumeAtMs != null || pausedSessionIds.isNotEmpty;
    if (!hasPendingTrigger && !hasRunningCountdown && !hasPostTimerState) {
      if (removeLegacyPrefsWhenEmpty) {
        await (await _preferences).remove(_runtimeKey);
      }
      return;
    }

    service.countdownTimer?.cancel();
    service.autoResumeTimer?.cancel();
    service
      ..countdownTimer = null
      ..autoResumeTimer = null
      ..timerMode = null
      ..timerDuration = null
      ..timerRemaining = null
      ..timerActive = false
      ..timerEndsAt = null
      ..timerWaitingForPlayback = false
      ..autoResumeAt = null
      ..timerGeneration = generation
      ..autoResumeEnabled = autoResumeEnabled
      ..autoResumeHour = autoResumeHour
      ..autoResumeMinute = autoResumeMinute;
    service.pausedByTimerSessionIds
      ..clear()
      ..addAll(pausedSessionIds);

    if (timerModeIndex != null &&
        timerModeIndex >= 0 &&
        timerModeIndex < TimerMode.values.length) {
      service.timerMode = TimerMode.values[timerModeIndex];
    }
    if (durationMs != null && durationMs > 0) {
      service.timerDuration = Duration(milliseconds: durationMs);
    }
    if (service.timerDuration != null && waitingForPlayback) {
      service
        ..timerRemaining = service.timerDuration
        ..timerWaitingForPlayback = true;
    } else if (service.timerDuration != null && timerEndsAtMs == null) {
      service.timerRemaining = Duration.zero;
    }

    if (timerEndsAtMs != null && service.timerDuration != null) {
      final restoredEndsAt = DateTime.fromMillisecondsSinceEpoch(timerEndsAtMs);
      if (restoredEndsAt.isAfter(now)) {
        final remaining = restoredEndsAt.difference(now);
        service
          ..timerEndsAt = restoredEndsAt
          ..timerActive = true
          ..timerWaitingForPlayback = false
          ..timerRemaining = Duration(
            seconds: (remaining.inMilliseconds + 999) ~/ 1000,
          );
        restoreCountdownTimer();
      } else {
        service.timerRemaining = Duration.zero;
      }
    }

    service.autoResumeAt = autoResumeAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(autoResumeAtMs);
    final autoResumeAt = service.autoResumeAt;
    if (autoResumeAt != null) {
      if (autoResumeAt.isAfter(now) &&
          service.pausedByTimerSessionIds.isNotEmpty) {
        scheduleAutoResumeTimer(autoResumeAt);
      } else if (service.pausedByTimerSessionIds.isNotEmpty) {
        await _handleAutoResumeOnPlatform(service.timerGeneration);
        return;
      } else {
        service.autoResumeAt = null;
      }
    }

    if (removeLegacyPrefsWhenEmpty) await saveRuntime();
    if (syncNativeAfterRestore) await syncNativeAlarms();
    _onRuntimeRestored();
  }

  Future<SharedPreferences> get _preferences async {
    return _cachedPreferences ??= await _preferencesLoader();
  }

  int? _readMillisValue(Object? raw) {
    return switch (raw) {
      final int value => value,
      final num value => value.round(),
      _ => null,
    };
  }

  void _cancelTimerInternal() {
    service.timerGeneration++;
    service.countdownTimer?.cancel();
    service.countdownTimer = null;
    service.timerEndsAt = null;
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    service.autoResumeAt = null;
    service.timerActive = false;
    service.timerWaitingForPlayback = false;
    unawaited(saveRuntime());
    unawaited(syncNativeAlarms());
  }

  void _tickCountdown() {
    final tick = _runtimeCalculator.countdownTick(
      active: service.timerActive,
      endsAt: service.timerEndsAt,
      now: DateTime.now(),
      currentRemaining: service.timerRemaining,
    );
    if (tick.expired) {
      service.timerRemaining = tick.remaining;
      _applyFadeMultiplier(1.0);
      _changed();
      _expireTimer();
      return;
    }
    if (!tick.changed) return;
    service.timerRemaining = tick.remaining;
    final duration = service.timerDuration;
    if (duration != null && duration.inMinutes >= 2) {
      final remainingMs = service.timerRemaining!.inMilliseconds;
      if (remainingMs <= 120000) {
        _applyFadeMultiplier((remainingMs / 120000.0).clamp(0.0, 1.0));
      }
    }
    _changed();
  }

  void _expireTimer() {
    final generation = service.timerGeneration;
    service.timerActive = false;
    service.countdownTimer?.cancel();
    service.countdownTimer = null;
    service.timerEndsAt = null;
    service.timerWaitingForPlayback = false;
    service.timerRemaining = Duration.zero;
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    _changed();
    unawaited(_handleTimerExpiredOnPlatform(generation));
  }

  void _changed() => _onStateChanged();

  Future<void> dispose() async {
    service.countdownTimer?.cancel();
    service.autoResumeTimer?.cancel();
    await service.dispose();
  }
}

void _noop() {}
void _noopFade(double _) {}
Iterable<PlaybackSession> _emptySessions() => const <PlaybackSession>[];
Future<bool> _falseSession(PlaybackSession _) async => false;
Future<bool> _falseAsync() async => false;
