part of 'audio_provider.dart';

extension AudioProviderPersistenceTimer on AudioProvider {
  int? _readMillisValue(Object? raw) {
    return switch (raw) {
      final int value => value,
      final num value => value.round(),
      _ => null,
    };
  }

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

  Future<void> _restoreTimerRuntimeFromMap(
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
        map['autoResumeEnabled'] as bool? ?? _autoResumeEnabled;
    final autoResumeHour =
        _readMillisValue(map['autoResumeHour']) ?? _autoResumeHour;
    final autoResumeMinute =
        _readMillisValue(map['autoResumeMinute']) ?? _autoResumeMinute;
    final autoResumeAtMs = _readMillisValue(map['autoResumeAtMs']);
    final generation = _readMillisValue(map['generation']) ?? _timerGeneration;
    final pausedSessionIds =
        (map['pausedSessionIds'] as List<dynamic>? ??
                map['pausedByTimerPaths'] as List<dynamic>? ??
                const [])
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
        final prefs = await _prefs;
        await prefs.remove(_kTimerRuntimeKey);
      }
      return;
    }

    _countdownTimer?.cancel();
    _countdownTimer = null;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _timerMode = null;
    _timerDuration = null;
    _timerRemaining = null;
    _timerActive = false;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;
    _autoResumeAt = null;
    _timerGeneration = generation;
    _autoResumeEnabled = autoResumeEnabled;
    _autoResumeHour = autoResumeHour;
    _autoResumeMinute = autoResumeMinute;
    _pausedByTimerSessionIds
      ..clear()
      ..addAll(pausedSessionIds);

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
      final restoredEndsAt = DateTime.fromMillisecondsSinceEpoch(timerEndsAtMs);
      if (restoredEndsAt.isAfter(now)) {
        final activeGeneration = _timerGeneration;
        _timerEndsAt = restoredEndsAt;
        _timerActive = true;
        _timerWaitingForPlayback = false;
        final remaining = restoredEndsAt.difference(now);
        _timerRemaining = Duration(
          seconds: (remaining.inMilliseconds + 999) ~/ 1000,
        );
        _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (activeGeneration != _timerGeneration) return;
          _tickCountdown();
        });
      } else {
        _timerRemaining = Duration.zero;
      }
    }

    _autoResumeAt = autoResumeAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(autoResumeAtMs);
    if (_autoResumeAt != null) {
      if (_autoResumeAt!.isAfter(now) && _pausedByTimerSessionIds.isNotEmpty) {
        _scheduleAutoResumeTimer(_autoResumeAt!);
      } else if (_pausedByTimerSessionIds.isNotEmpty) {
        await _handleAutoResumeOnPlatform(_timerGeneration);
        return;
      } else {
        _autoResumeAt = null;
      }
    }

    if (removeLegacyPrefsWhenEmpty) {
      await _saveTimerRuntime();
    }
    _syncNotificationState();
    _syncKeepCpuAwake();
    if (syncNativeAfterRestore) {
      await _syncNativeTimerAlarms();
    }
    _notifyListeners();
  }

  Future<bool> _loadNativeTimerRuntime() async {
    try {
      final map = await AudioProvider._powerChannel
          .invokeMapMethod<dynamic, dynamic>(
            PowerMethod.getNativeTimerRuntimeState,
          );
      if (map == null || map.isEmpty) {
        return false;
      }
      await _restoreTimerRuntimeFromMap(
        map,
        removeLegacyPrefsWhenEmpty: true,
        syncNativeAfterRestore: false,
      );
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('AudioProvider native timer runtime restore error: $e');
      return false;
    }
  }

  Future<void> _loadTimerRuntime() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kTimerRuntimeKey);
      if (raw == null || raw.isEmpty) return;

      final map = json.decode(raw) as Map<String, dynamic>;
      await _restoreTimerRuntimeFromMap(
        map,
        removeLegacyPrefsWhenEmpty: true,
        syncNativeAfterRestore: true,
      );
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> loadTimerRuntimeFromSystem() async {
    final restoredFromNative = await _loadNativeTimerRuntime();
    if (restoredFromNative) return;
    await _loadTimerRuntime();
  }

  Future<void> syncTimerRuntimeFromNative() async {
    await _loadNativeTimerRuntime();
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
        'timerEndsAtWallClockMs': _timerEndsAt?.millisecondsSinceEpoch,
        'autoResumeEnabled': _autoResumeEnabled,
        'autoResumeHour': _autoResumeHour,
        'autoResumeMinute': _autoResumeMinute,
        'autoResumeAtMs': _autoResumeAt?.millisecondsSinceEpoch,
        'pausedSessionIds': _pausedByTimerSessionIds,
        'generation': _timerGeneration,
      });
      await prefs.setString(_kTimerRuntimeKey, encoded);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }
}
