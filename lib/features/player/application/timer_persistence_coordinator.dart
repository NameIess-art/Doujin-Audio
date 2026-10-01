import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/platform/power_platform_service.dart';
import '../domain/playback_mode.dart';
import 'audio_state_services.dart';
import 'playback_session.dart';
import 'timer_runtime_calculator.dart';

enum NativeTimerRuntimeLoadResult { loaded, empty, stale, failed }

/// Persists and restores the existing timer state without owning timer execution.
final class TimerPersistenceCoordinator {
  TimerPersistenceCoordinator({
    required TimerService service,
    required this.powerPlatformService,
    required Future<SharedPreferences> Function() preferencesLoader,
    required Set<String> restoredCountdownSessions,
    required Iterable<PlaybackSession> Function() sessions,
    required bool Function() hasArmedRuntime,
    required bool Function(int generation) isCurrentGeneration,
    required VoidCallback restoreCountdownTimer,
    required void Function(DateTime target) scheduleAutoResumeTimer,
    required Future<void> Function(int generation) handleAutoResumeOnPlatform,
    required VoidCallback onRuntimeRestored,
    required Future<void> Function(String sessionId) flushSessionPersistence,
  }) : _service = service,
       _preferencesLoader = preferencesLoader,
       _restoredCountdownSessions = restoredCountdownSessions,
       _sessions = sessions,
       _hasArmedRuntime = hasArmedRuntime,
       _isCurrentGeneration = isCurrentGeneration,
       _restoreCountdownTimer = restoreCountdownTimer,
       _scheduleAutoResumeTimer = scheduleAutoResumeTimer,
       _handleAutoResumeOnPlatform = handleAutoResumeOnPlatform,
       _onRuntimeRestored = onRuntimeRestored,
       _flushSessionPersistence = flushSessionPersistence;
  final TimerService _service;
  final PowerPlatformService powerPlatformService;
  final Future<SharedPreferences> Function() _preferencesLoader;
  SharedPreferences? _cachedPreferences;
  Future<void>? _nativeAlarmSync;
  bool _nativeAlarmSyncRequested = false;
  final Set<String> _restoredCountdownSessions;
  final Iterable<PlaybackSession> Function() _sessions;
  final bool Function() _hasArmedRuntime;
  final bool Function(int generation) _isCurrentGeneration;
  final VoidCallback _restoreCountdownTimer;
  final void Function(DateTime target) _scheduleAutoResumeTimer;
  final Future<void> Function(int generation) _handleAutoResumeOnPlatform;
  final VoidCallback _onRuntimeRestored;
  final Future<void> Function(String sessionId) _flushSessionPersistence;
  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;
  static const _settingsKey = 'timer_settings_v1';
  static const _runtimeKey = 'timer_runtime_v1';
  static const _runtimeCalculator = TimerRuntimeCalculator();
  void resetPreferencesCache() => _cachedPreferences = null;

  Future<void> loadPersistedState() async {
    try {
      final raw = (await _preferences).getString(_settingsKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      _service.autoResumeEnabled = map['autoResumeEnabled'] as bool? ?? false;
      _service.autoResumeHour = map['autoResumeHour'] as int? ?? 7;
      _service.autoResumeMinute = map['autoResumeMinute'] as int? ?? 0;
      final draftModeIndex = map['timerDraftMode'] as int?;
      final draftDurationMs = map['timerDraftDurationMs'] as int?;
      if (draftModeIndex != null &&
          draftModeIndex >= 0 &&
          draftModeIndex < TimerMode.values.length) {
        _service.timerDraftMode = TimerMode.values[draftModeIndex];
      }
      if (draftDurationMs != null && draftDurationMs > 0) {
        _service.timerDraftDuration = Duration(milliseconds: draftDurationMs);
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
        'autoResumeEnabled': _service.autoResumeEnabled,
        'autoResumeHour': _service.autoResumeHour,
        'autoResumeMinute': _service.autoResumeMinute,
        'timerDraftMode': _service.timerDraftMode.index,
        'timerDraftDurationMs': _service.timerDraftDuration.inMilliseconds,
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
    if (await loadNativeRuntime() == NativeTimerRuntimeLoadResult.loaded) {
      return;
    }
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
    await loadNativeRuntime();
  }

  Future<void> saveRuntime() async {
    try {
      final preferences = await _preferences;
      if (!_hasArmedRuntime()) {
        await preferences.remove(_runtimeKey);
        return;
      }
      final encoded = json.encode({
        'timerMode': _service.timerMode?.index,
        'timerDurationMs': _service.timerDuration?.inMilliseconds,
        'timerWaitingForPlayback': _service.timerWaitingForPlayback,
        'timerEndsAtWallClockMs': _service.timerEndsAt?.millisecondsSinceEpoch,
        'autoResumeEnabled': _service.autoResumeEnabled,
        'autoResumeHour': _service.autoResumeHour,
        'autoResumeMinute': _service.autoResumeMinute,
        'autoResumeAtMs': _service.autoResumeAt?.millisecondsSinceEpoch,
        'pausedSessionIds': _service.pausedByTimerSessionIds,
        if (_isWindows && _service.timerActive)
          'countdownSessionIds': {
            ..._restoredCountdownSessions,
            ..._sessions()
                .where((session) => session.effectivePlaying)
                .map((session) => session.id),
          }.toList(),
        'generation': _service.timerGeneration,
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

  Future<void> syncNativeAlarms() {
    _nativeAlarmSyncRequested = true;
    return _nativeAlarmSync ??= Future<void>.microtask(() async {
      // Configuration and countdown start can occur in the same UI action.
      // Send their final state and serialize later changes behind that reply.
      try {
        while (_nativeAlarmSyncRequested) {
          _nativeAlarmSyncRequested = false;
          await _syncNativeAlarms();
        }
      } finally {
        _nativeAlarmSync = null;
      }
    });
  }

  Future<void> get pendingNativeAlarmSync =>
      _nativeAlarmSync ?? Future<void>.value();

  Future<void> _syncNativeAlarms() async {
    try {
      final autoResumeAt = _service.autoResumeAt;
      final generation = _service.timerGeneration;
      if (defaultTargetPlatform == TargetPlatform.android &&
          autoResumeAt != null &&
          autoResumeAt.isAfter(DateTime.now()) &&
          _service.pausedByTimerSessionIds.isNotEmpty) {
        for (final id in List<String>.of(_service.pausedByTimerSessionIds)) {
          await _flushSessionPersistence(id);
          if (!_isCurrentGeneration(generation) ||
              _service.autoResumeAt != autoResumeAt) {
            return;
          }
        }
      }
      await powerPlatformService.syncPlaybackTimerAlarms(
        timerMode: _service.timerMode?.index,
        timerDurationMs: _service.timerDuration?.inMilliseconds,
        timerWaitingForPlayback: _service.timerWaitingForPlayback,
        timerEndsAtWallClockMs: _service.timerActive
            ? _service.timerEndsAt?.millisecondsSinceEpoch
            : null,
        autoResumeEnabled: _service.autoResumeEnabled,
        autoResumeHour: _service.autoResumeHour,
        autoResumeMinute: _service.autoResumeMinute,
        autoResumeAtMs:
            autoResumeAt != null &&
                _service.pausedByTimerSessionIds.isNotEmpty &&
                autoResumeAt.isAfter(DateTime.now())
            ? autoResumeAt.millisecondsSinceEpoch
            : null,
        pausedSessionIds: _service.pausedByTimerSessionIds,
        generation: _service.timerGeneration,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'sync_native_timer_alarms_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<NativeTimerRuntimeLoadResult> loadNativeRuntime({
    int? expectedGeneration,
  }) async {
    try {
      final map = await powerPlatformService.getNativeTimerRuntimeState();
      if (expectedGeneration != null &&
          !_isCurrentGeneration(expectedGeneration)) {
        return NativeTimerRuntimeLoadResult.stale;
      }
      if (map == null || map.isEmpty) {
        return NativeTimerRuntimeLoadResult.empty;
      }
      final nativeGeneration = _readMillisValue(map['generation']);
      if (expectedGeneration != null &&
          nativeGeneration != null &&
          nativeGeneration != expectedGeneration) {
        return NativeTimerRuntimeLoadResult.stale;
      }
      await _restoreRuntimeFromMap(
        map,
        removeLegacyPrefsWhenEmpty: true,
        syncNativeAfterRestore: false,
      );
      if (expectedGeneration != null &&
          !_isCurrentGeneration(expectedGeneration)) {
        return NativeTimerRuntimeLoadResult.stale;
      }
      return NativeTimerRuntimeLoadResult.loaded;
    } catch (error, stackTrace) {
      AppLogService.error(
        'native_timer_runtime_restore_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return NativeTimerRuntimeLoadResult.failed;
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
        map['autoResumeEnabled'] as bool? ?? _service.autoResumeEnabled;
    final autoResumeHour =
        _readMillisValue(map['autoResumeHour']) ?? _service.autoResumeHour;
    final autoResumeMinute =
        _readMillisValue(map['autoResumeMinute']) ?? _service.autoResumeMinute;
    var autoResumeAtMs = _readMillisValue(map['autoResumeAtMs']);
    final generation =
        _readMillisValue(map['generation']) ?? _service.timerGeneration;
    final pausedSessionIds =
        (map['pausedSessionIds'] as List<dynamic>? ??
                map['pausedByTimerPaths'] as List<dynamic>? ??
                const <dynamic>[])
            .whereType<String>()
            .toList();

    if (_isWindows) {
      _restoredCountdownSessions
        ..clear()
        ..addAll(
          (map['countdownSessionIds'] as List? ?? const [])
              .whereType<String>()
              .where((id) => _sessions().any((session) => session.id == id)),
        );
      if (timerEndsAtMs != null &&
          timerEndsAtMs <= now.millisecondsSinceEpoch &&
          autoResumeEnabled &&
          _restoredCountdownSessions.isNotEmpty) {
        pausedSessionIds.addAll(_restoredCountdownSessions);
        _restoredCountdownSessions.clear();
        autoResumeAtMs ??= _runtimeCalculator
            .nextClockTime(
              now: DateTime.fromMillisecondsSinceEpoch(timerEndsAtMs),
              hour: autoResumeHour,
              minute: autoResumeMinute,
            )
            .millisecondsSinceEpoch;
      }
    }

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
      if (_isWindows) await syncNativeAlarms();
      return;
    }

    _service.countdownTimer?.cancel();
    _service.autoResumeTimer?.cancel();
    _service
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
    _service.pausedByTimerSessionIds
      ..clear()
      ..addAll(pausedSessionIds);

    if (timerModeIndex != null &&
        timerModeIndex >= 0 &&
        timerModeIndex < TimerMode.values.length) {
      _service.timerMode = TimerMode.values[timerModeIndex];
    }
    if (durationMs != null && durationMs > 0) {
      _service.timerDuration = Duration(milliseconds: durationMs);
    }
    if (_service.timerDuration != null && waitingForPlayback) {
      _service
        ..timerRemaining = _service.timerDuration
        ..timerWaitingForPlayback = true;
    } else if (_service.timerDuration != null && timerEndsAtMs == null) {
      _service.timerRemaining = Duration.zero;
    }

    if (timerEndsAtMs != null && _service.timerDuration != null) {
      final restoredEndsAt = DateTime.fromMillisecondsSinceEpoch(timerEndsAtMs);
      if (restoredEndsAt.isAfter(now)) {
        final remaining = restoredEndsAt.difference(now);
        _service
          ..timerEndsAt = restoredEndsAt
          ..timerActive = true
          ..timerWaitingForPlayback = false
          ..timerRemaining = Duration(
            seconds: (remaining.inMilliseconds + 999) ~/ 1000,
          );
        _restoreCountdownTimer();
      } else {
        _service.timerRemaining = Duration.zero;
      }
    }

    _service.autoResumeAt = autoResumeAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(autoResumeAtMs);
    final autoResumeAt = _service.autoResumeAt;
    if (autoResumeAt != null) {
      if (autoResumeAt.isAfter(now) &&
          _service.pausedByTimerSessionIds.isNotEmpty) {
        _scheduleAutoResumeTimer(autoResumeAt);
      } else if (_service.pausedByTimerSessionIds.isNotEmpty) {
        await _handleAutoResumeOnPlatform(_service.timerGeneration);
        return;
      } else {
        _service.autoResumeAt = null;
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
}
