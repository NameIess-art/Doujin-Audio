part of 'audio_provider.dart';

extension AudioProviderPersistenceTimer on AudioProvider {
  Future<void> _loadTimerSettings() async {
    try {
      final prefs = await _prefs;
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
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveTimerSettings() async {
    try {
      final prefs = await _prefs;
      final encoded = json.encode({
        'autoResumeEnabled': _autoResumeEnabled,
        'autoResumeHour': _autoResumeHour,
        'autoResumeMinute': _autoResumeMinute,
        'timerDraftMode': _timerDraftMode.index,
        'timerDraftDurationMs': _timerDraftDuration.inMilliseconds,
      });
      await prefs.setString(_kTimerSettingsKey, encoded);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    _notifyListeners();
    unawaited(_saveTimerSettings());
  }

  Future<void> _loadTimerRuntime() async {
    try {
      final prefs = await _prefs;
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
            if (generation != _timerGeneration) return;
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

      _syncNotificationState();
      _notifyListeners();
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveTimerRuntime() async {
    try {
      final prefs = await _prefs;
      final hasRuntime = _hasArmedTimerRuntime;
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
      debugPrint('AudioProvider persistence error: $e');
    }
  }
}
