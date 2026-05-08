import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/playback_mode.dart';
import '../../models/playback_session.dart';
import '../../services/native_playback_bridge.dart';
import '../../services/platform_channels.dart';
import '../../services/timer_runtime_calculator.dart';

abstract class TimerCoordinator {
  void syncKeepCpuAwake();
  void notifyListeners();
  void syncNotificationState();
  Future<bool> activateAudioSession();
  Future<void> startSessionPlayback(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  });
  bool get hasPlayingSession;
  Map<String, PlaybackSession> get sessions;
  void resetTimerRuntimeState({bool clearPausedSessions = true});
}

class TimerDelegate {
  TimerDelegate({
    required TimerCoordinator coordinator,
    required Future<SharedPreferences> Function() prefs,
  }) : _coord = coordinator,
       _prefs = prefs;

  static const _kTimerSettingsKey = 'timer_settings_v1';
  static const _kTimerRuntimeKey = 'timer_runtime_v1';
  static const MethodChannel _powerChannel = MethodChannel(PowerChannel.name);

  final TimerCoordinator _coord;
  final Future<SharedPreferences> Function() _prefs;

  static const TimerRuntimeCalculator _runtimeCalculator =
      TimerRuntimeCalculator();

  TimerMode? _timerMode;
  Duration? _timerDuration;
  bool _timerActive = false;
  Duration? _timerRemaining;
  DateTime? _timerEndsAt;
  Timer? _countdownTimer;
  bool _timerWaitingForPlayback = false;
  TimerMode _timerDraftMode = TimerMode.manual;
  Duration _timerDraftDuration = const Duration(minutes: 30);
  int _timerGeneration = 0;

  bool _autoResumeEnabled = false;
  int _autoResumeHour = 7;
  int _autoResumeMinute = 0;
  Timer? _autoResumeTimer;
  DateTime? _autoResumeAt;

  final List<String> _pausedByTimerPaths = [];
  List<String> get pausedByTimerPaths => List.unmodifiable(_pausedByTimerPaths);

  final ValueNotifier<TimerInfo> _timerNotifier = ValueNotifier<TimerInfo>(
    const TimerInfo(),
  );
  ValueListenable<TimerInfo> get timerNotifier => _timerNotifier;

  // --- Public getters ---

  TimerMode? get mode => _timerMode;
  Duration? get duration => _timerDuration;
  bool get active => _timerActive;
  Duration? get remaining => _timerRemaining;
  DateTime? get endsAt => _timerEndsAt;
  bool get waitingForPlayback => _timerWaitingForPlayback;
  TimerMode get draftMode => _timerDraftMode;
  Duration get draftDuration => _timerDraftDuration;
  int get generation => _timerGeneration;

  bool get autoResumeEnabled => _autoResumeEnabled;
  int get autoResumeHour => _autoResumeHour;
  int get autoResumeMinute => _autoResumeMinute;
  DateTime? get autoResumeAt => _autoResumeAt;

  bool get hasArmedRuntime {
    return _runtimeCalculator.hasArmedRuntime(
      mode: _timerMode,
      duration: _timerDuration,
      waitingForPlayback: _timerWaitingForPlayback,
      active: _timerActive,
      endsAt: _timerEndsAt,
      autoResumeAt: _autoResumeAt,
      hasPausedByTimerPaths: _pausedByTimerPaths.isNotEmpty,
    );
  }

  bool get hasPendingAutoResume {
    return _runtimeCalculator.hasPendingAutoResume(
      autoResumeAt: _autoResumeAt,
      hasPausedByTimerPaths: _pausedByTimerPaths.isNotEmpty,
    );
  }

  // --- Timer actions ---

  bool _isGenerationCurrent(int g) => g == _timerGeneration;

  void _syncTimerNotifier() {
    _timerNotifier.value = TimerInfo(
      duration: _timerDuration,
      remaining: _timerRemaining,
      active: _timerActive,
      mode: _timerMode,
    );
  }

  DateTime? _plannedAutoResumeForTimerEnd(DateTime? timerEndsAt) {
    if (!_autoResumeEnabled || timerEndsAt == null) return null;
    return _runtimeCalculator.nextClockTime(
      now: timerEndsAt,
      hour: _autoResumeHour,
      minute: _autoResumeMinute,
    );
  }

  Future<void> _syncNativeTimerAlarms() async {
    try {
      final timerEndsAtMs = _timerActive
          ? _timerEndsAt?.millisecondsSinceEpoch
          : null;
      final autoResumeAtMs = (() {
        if (_autoResumeAt != null && _pausedByTimerPaths.isNotEmpty) {
          return _autoResumeAt!.millisecondsSinceEpoch;
        }
        final plannedAutoResume = _plannedAutoResumeForTimerEnd(_timerEndsAt);
        if (_timerActive && plannedAutoResume != null) {
          return plannedAutoResume.millisecondsSinceEpoch;
        }
        return null;
      })();
      await _powerChannel.invokeMethod<void>(
        PowerMethod.syncPlaybackTimerAlarms,
        {'timerEndsAtMs': timerEndsAtMs, 'autoResumeAtMs': autoResumeAtMs},
      );
    } on MissingPluginException {
      // Non-Android platforms don't expose this channel.
    } catch (e) {
      debugPrint('TimerDelegate._syncNativeTimerAlarms error: $e');
    }
  }

  void configureTimer(TimerMode mode, Duration duration) {
    _timerDraftMode = mode;
    _timerDraftDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    _cancelTimerInternal();
    _timerMode = mode;
    _timerDuration = duration;
    _timerRemaining = duration;
    _timerEndsAt = null;
    _timerActive = false;
    _timerWaitingForPlayback = mode == TimerMode.trigger;
    if (mode == TimerMode.trigger && _coord.hasPlayingSession) {
      startCountdown();
      return;
    }
    _coord.syncKeepCpuAwake();
    _syncTimerNotifier();
    _coord.notifyListeners();
    unawaited(saveTimerSettings());
    unawaited(saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void startCountdown() {
    if (_timerDuration == null || _timerActive) return;
    _countdownTimer?.cancel();
    final generation = ++_timerGeneration;
    _timerActive = true;
    _timerWaitingForPlayback = false;
    _timerRemaining = _timerDuration;
    _timerEndsAt = DateTime.now().add(_timerDuration!);
    _countdownTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_isGenerationCurrent(generation)) return;
      _tickCountdown();
    });
    _coord.syncKeepCpuAwake();
    _syncTimerNotifier();
    _coord.notifyListeners();
    unawaited(saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void cancelTimer() {
    _coord.resetTimerRuntimeState();
    _syncTimerNotifier();
    _coord.syncKeepCpuAwake();
    _coord.notifyListeners();
    unawaited(saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void _cancelTimerInternal() {
    _timerGeneration++;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _timerEndsAt = null;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoResumeAt = null;
    _timerActive = false;
    _timerWaitingForPlayback = false;
    _syncTimerNotifier();
    _coord.syncKeepCpuAwake();
    unawaited(saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void _onTimerExpired() {
    _timerGeneration++;
    _timerActive = false;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;

    final pausedPaths = _pausedByTimerPaths;
    pausedPaths.clear();
    pausedPaths.addAll(
      _coord.sessions.values
          .where((s) => s.state.playing)
          .map((s) => s.currentTrackPath),
    );

    for (final session in _coord.sessions.values) {
      unawaited(NativePlaybackBridge.instance.pause(session.id));
      session.setOptimisticState(playing: false);
    }

    _syncTimerNotifier();
    _coord.notifyListeners();

    if (_autoResumeEnabled) {
      _scheduleAutoResumeTimer(
        _nextClockTime(_autoResumeHour, _autoResumeMinute),
      );
    }
    _coord.syncKeepCpuAwake();
    unawaited(saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  DateTime _nextClockTime(int hour, int minute) {
    return _runtimeCalculator.nextClockTime(
      now: DateTime.now(),
      hour: hour,
      minute: minute,
    );
  }

  void _onAutoResume() {
    _autoResumeTimer = null;
    unawaited(_resumeTimerPausedSessions());
  }

  void _resetTimerAfterAutoResumeSuccess() {
    _coord.resetTimerRuntimeState(clearPausedSessions: false);
  }

  Future<void> _resumeTimerPausedSessions() async {
    final activated = await _coord.activateAudioSession();
    if (!activated) {
      _coord.syncKeepCpuAwake();
      _coord.notifyListeners();
      await saveTimerRuntime();
      await _syncNativeTimerAlarms();
      return;
    }

    final resumableSessions = _coord.sessions.values
        .where((s) => _pausedByTimerPaths.contains(s.currentTrackPath))
        .toList();

    if (resumableSessions.isEmpty) {
      _pausedByTimerPaths.clear();
      _coord.syncKeepCpuAwake();
      _coord.notifyListeners();
      await saveTimerRuntime();
      await _syncNativeTimerAlarms();
      return;
    }

    for (final session in resumableSessions) {
      await _coord.startSessionPlayback(
        session,
        shouldStartTriggerCountdown: false,
      );
    }
    _pausedByTimerPaths.clear();
    _autoResumeAt = null;
    _resetTimerAfterAutoResumeSuccess();
    _coord.syncKeepCpuAwake();
    _coord.notifyListeners();
    await saveTimerRuntime();
    await _syncNativeTimerAlarms();
  }

  void retryOverdueAutoResume() {
    final autoResumeAt = _autoResumeAt;
    if (autoResumeAt == null || _pausedByTimerPaths.isEmpty) return;
    if (autoResumeAt.isAfter(DateTime.now())) {
      _scheduleAutoResumeTimer(autoResumeAt);
      _coord.syncKeepCpuAwake();
      unawaited(saveTimerRuntime());
      unawaited(_syncNativeTimerAlarms());
      return;
    }
    _onAutoResume();
  }

  void setAutoResume(bool enabled, int hour, int minute) {
    _autoResumeEnabled = enabled;
    _autoResumeHour = hour;
    _autoResumeMinute = minute;
    if (!enabled) {
      _autoResumeTimer?.cancel();
      _autoResumeTimer = null;
      _autoResumeAt = null;
    } else if (_pausedByTimerPaths.isNotEmpty) {
      _scheduleAutoResumeTimer(_nextClockTime(hour, minute));
    }
    _coord.syncKeepCpuAwake();
    _coord.notifyListeners();
    unawaited(saveTimerSettings());
    unawaited(saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void _scheduleAutoResumeTimer(DateTime target) {
    _autoResumeTimer?.cancel();
    _autoResumeAt = target;
    final delay = target.difference(DateTime.now());
    if (delay <= Duration.zero) {
      _onAutoResume();
      return;
    }
    _autoResumeTimer = Timer(delay, _onAutoResume);
  }

  void maybeStartTriggerCountdown() {
    if (_timerMode != TimerMode.trigger ||
        _timerDuration == null ||
        _timerActive ||
        !_timerWaitingForPlayback) {
      return;
    }
    startCountdown();
  }

  void _tickCountdown() {
    final tick = _runtimeCalculator.countdownTick(
      active: _timerActive,
      endsAt: _timerEndsAt,
      now: DateTime.now(),
      currentRemaining: _timerRemaining,
    );
    if (tick.expired) {
      _timerRemaining = tick.remaining;
      _coord.notifyListeners();
      _onTimerExpired();
      return;
    }
    if (!tick.changed) return;
    _timerRemaining = tick.remaining;
    _syncTimerNotifier();
    _coord.notifyListeners();
  }

  void resetRuntimeState({bool clearPausedSessions = true}) {
    _timerGeneration++;
    _timerMode = null;
    _timerDuration = null;
    _timerRemaining = null;
    _timerActive = false;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoResumeAt = null;
    if (clearPausedSessions) {
      _pausedByTimerPaths.clear();
    }
    unawaited(_syncNativeTimerAlarms());
  }

  // --- Persistence ---

  Future<void> loadTimerSettings() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kTimerSettingsKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      _autoResumeEnabled = map['autoResumeEnabled'] as bool? ?? false;
      _autoResumeHour = map['autoResumeHour'] as int? ?? 7;
      _autoResumeMinute = map['autoResumeMinute'] as int? ?? 0;
      final draftModeIndex = map['timerDraftMode'] as int?;
      final draftDurationMs = map['timerDraftDurationMs'] as int?;
      if (draftModeIndex != null &&
          draftModeIndex >= 0 &&
          draftModeIndex < TimerMode.values.length) {
        _timerDraftMode = TimerMode.values[draftModeIndex];
      }
      if (draftDurationMs != null && draftDurationMs > 0) {
        _timerDraftDuration = Duration(milliseconds: draftDurationMs);
      }
    } catch (e) {
      debugPrint('TimerDelegate persistence error: $e');
    }
  }

  Future<void> saveTimerSettings() async {
    try {
      final prefs = await _prefs();
      final encoded = json.encode({
        'autoResumeEnabled': _autoResumeEnabled,
        'autoResumeHour': _autoResumeHour,
        'autoResumeMinute': _autoResumeMinute,
        'timerDraftMode': _timerDraftMode.index,
        'timerDraftDurationMs': _timerDraftDuration.inMilliseconds,
      });
      await prefs.setString(_kTimerSettingsKey, encoded);
    } catch (e) {
      debugPrint('TimerDelegate persistence error: $e');
    }
  }

  void setTimerDraft(TimerMode mode, Duration duration) {
    final normalizedDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    if (_timerDraftMode == mode && _timerDraftDuration == normalizedDuration) {
      return;
    }
    _timerDraftMode = mode;
    _timerDraftDuration = normalizedDuration;
    _coord.notifyListeners();
    unawaited(saveTimerSettings());
  }

  Future<void> loadTimerRuntime() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kTimerRuntimeKey);
      if (raw == null || raw.isEmpty) return;

      final map = json.decode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      final durationMs = map['timerDurationMs'] as int?;
      final timerModeIndex = map['timerMode'] as int?;
      final waitingForPlayback =
          map['timerWaitingForPlayback'] as bool? ?? false;
      final timerEndsAtMs = map['timerEndsAtMs'] as int?;
      final autoResumeAtMs = map['autoResumeAtMs'] as int?;
      final pausedPaths =
          (map['pausedByTimerPaths'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList();

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
          autoResumeAtMs != null || pausedPaths.isNotEmpty;
      if (!hasPendingTrigger && !hasRunningCountdown && !hasPostTimerState) {
        await prefs.remove(_kTimerRuntimeKey);
        return;
      }

      _pausedByTimerPaths
        ..clear()
        ..addAll(pausedPaths);
      _autoResumeAt = autoResumeAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(autoResumeAtMs);

      if (timerModeIndex != null &&
          timerModeIndex >= 0 &&
          timerModeIndex < TimerMode.values.length) {
        _timerMode = TimerMode.values[timerModeIndex];
      }
      if (durationMs != null && durationMs > 0) {
        _timerDuration = Duration(milliseconds: durationMs);
      }

      if (_timerDuration != null && waitingForPlayback) {
        _timerRemaining = _timerDuration;
        _timerWaitingForPlayback = true;
        _timerActive = false;
      }

      if (timerEndsAtMs != null && _timerDuration != null) {
        final restoredEndsAt = DateTime.fromMillisecondsSinceEpoch(
          timerEndsAtMs,
        );
        if (restoredEndsAt.isAfter(now)) {
          final generation = ++_timerGeneration;
          _timerEndsAt = restoredEndsAt;
          _timerActive = true;
          _timerWaitingForPlayback = false;
          final remaining = restoredEndsAt.difference(now);
          _timerRemaining = Duration(
            seconds: (remaining.inMilliseconds + 999) ~/ 1000,
          );
          _countdownTimer?.cancel();
          _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (!_isGenerationCurrent(generation)) return;
            _tickCountdown();
          });
        } else {
          _timerEndsAt = null;
          _timerActive = false;
          _timerRemaining = Duration.zero;
        }
      }

      if (_autoResumeAt != null) {
        if (_autoResumeAt!.isAfter(now) && _pausedByTimerPaths.isNotEmpty) {
          _scheduleAutoResumeTimer(_autoResumeAt!);
        } else if (_pausedByTimerPaths.isNotEmpty) {
          await _resumeTimerPausedSessions();
        } else {
          _autoResumeAt = null;
        }
      }

      _coord.syncNotificationState();
      await _syncNativeTimerAlarms();
      _coord.notifyListeners();
    } catch (e) {
      debugPrint('TimerDelegate persistence error: $e');
    }
  }

  Future<void> saveTimerRuntime() async {
    try {
      final prefs = await _prefs();
      final hasRuntime = hasArmedRuntime;
      if (!hasRuntime) {
        await prefs.remove(_kTimerRuntimeKey);
        return;
      }

      final encoded = json.encode({
        'timerMode': _timerMode?.index,
        'timerDurationMs': _timerDuration?.inMilliseconds,
        'timerWaitingForPlayback': _timerWaitingForPlayback,
        'timerEndsAtMs': _timerEndsAt?.millisecondsSinceEpoch,
        'autoResumeAtMs': _autoResumeAt?.millisecondsSinceEpoch,
        'pausedByTimerPaths': _pausedByTimerPaths,
      });
      await prefs.setString(_kTimerRuntimeKey, encoded);
    } catch (e) {
      debugPrint('TimerDelegate persistence error: $e');
    }
  }

  void dispose() {
    _countdownTimer?.cancel();
    _autoResumeTimer?.cancel();
    _timerNotifier.dispose();
  }
}
