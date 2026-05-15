part of 'audio_provider.dart';

extension AudioProviderPlaybackTimer on AudioProvider {
  Future<void> _syncNativeTimerAlarms() async {
    try {
      final timerEndsAtWallClockMs = _timerActive
          ? _timerEndsAt?.millisecondsSinceEpoch
          : null;
      final autoResumeAtMs =
          _autoResumeAt != null && _pausedByTimerSessionIds.isNotEmpty
          ? _autoResumeAt!.millisecondsSinceEpoch
          : null;
      await AudioProvider._powerChannel
          .invokeMethod<void>('syncPlaybackTimerAlarms', {
            'timerMode': _timerMode?.index,
            'timerDurationMs': _timerDuration?.inMilliseconds,
            'timerWaitingForPlayback': _timerWaitingForPlayback,
            'timerEndsAtWallClockMs': timerEndsAtWallClockMs,
            'autoResumeEnabled': _autoResumeEnabled,
            'autoResumeHour': _autoResumeHour,
            'autoResumeMinute': _autoResumeMinute,
            'autoResumeAtMs': autoResumeAtMs,
            'pausedSessionIds': _pausedByTimerSessionIds,
            'generation': _timerGeneration,
          });
    } on MissingPluginException {
      // Non-Android platforms don't expose this channel.
    } catch (e) {
      debugPrint('AudioProvider._syncNativeTimerAlarms error: $e');
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
    if (mode == TimerMode.trigger && _hasPlayingSession) {
      startCountdown();
      return;
    }
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerSettings());
    unawaited(_saveTimerRuntime());
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
      if (generation != _timerGeneration) return;
      _tickCountdown();
    });
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void cancelTimer() {
    _resetTimerRuntimeState();
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerRuntime());
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
    _syncKeepCpuAwake();
    unawaited(_saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  void _onTimerExpired() {
    final generation = _timerGeneration;
    _timerActive = false;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;
    _timerRemaining = Duration.zero;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;

    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_handleTimerExpiredOnPlatform(generation));
  }

  Future<void> _handleTimerExpiredOnPlatform(int generation) async {
    final handled = await _executeTimerActionOnPlatform(
      PowerMethod.executeTimerExpiredNow,
      generation,
    );
    if (!handled) {
      _applyLocalTimerExpiryFallback();
      return;
    }
    await syncTimerRuntimeFromNative();
    _maybeResetTimerAfterExpiry();
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  void _applyLocalTimerExpiryFallback() {
    _pausedByTimerSessionIds
      ..clear()
      ..addAll(_sessions.values.where((s) => s.state.playing).map((s) => s.id));

    for (final session in _sessions.values) {
      unawaited(_nativePlaybackRepository.pause(session.id));
      session.setOptimisticState(playing: false);
    }

    if (_autoResumeEnabled) {
      _scheduleAutoResumeTimer(
        _nextClockTime(_autoResumeHour, _autoResumeMinute),
      );
    }
    _maybeResetTimerAfterExpiry();
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  /// Resets the timer configuration back to the pre-set state after expiry
  /// when there is no pending auto-resume.  If auto-resume is scheduled the
  /// timer state is kept so the capsule can show the auto-resume countdown.
  void _maybeResetTimerAfterExpiry() {
    if (_autoResumeAt != null ||
        _pausedByTimerSessionIds.isNotEmpty && _autoResumeEnabled) {
      // Auto-resume is pending — keep timer state so the UI can show it.
      return;
    }
    // No auto-resume: reset the timer to its original (unconfigured) state.
    _resetTimerRuntimeState();
  }

  void _onAutoResume() {
    _autoResumeTimer = null;
    unawaited(_handleAutoResumeOnPlatform(_timerGeneration));
  }

  Future<void> _handleAutoResumeOnPlatform(int generation) async {
    final handled = await _executeTimerActionOnPlatform(
      PowerMethod.executeAutoResumeNow,
      generation,
    );
    if (!handled) {
      await _resumeTimerPausedSessions();
      return;
    }
    await syncTimerRuntimeFromNative();
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  Future<bool> _executeTimerActionOnPlatform(
    String method,
    int generation,
  ) async {
    try {
      await AudioProvider._powerChannel.invokeMethod<bool>(method, {
        'generation': generation,
      });
      return true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('AudioProvider timer action error: $e');
      return false;
    }
  }

  void _resetTimerAfterAutoResumeSuccess() {
    _resetTimerRuntimeState(clearPausedSessions: false);
  }

  Future<void> _resumeTimerPausedSessions() async {
    final activated = await _activateAudioSessionForPlayback();
    if (!activated) {
      _syncKeepCpuAwake();
      _notifyListeners();
      await _saveTimerRuntime();
      await _syncNativeTimerAlarms();
      return;
    }

    final resumableSessions = _sessions.values
        .where((s) => _pausedByTimerSessionIds.contains(s.id))
        .toList();

    if (resumableSessions.isEmpty) {
      _pausedByTimerSessionIds.clear();
      _syncKeepCpuAwake();
      _notifyListeners();
      await _saveTimerRuntime();
      await _syncNativeTimerAlarms();
      return;
    }

    for (final session in resumableSessions) {
      await _startSessionPlayback(session, shouldStartTriggerCountdown: false);
    }
    _pausedByTimerSessionIds.clear();
    _autoResumeAt = null;
    _resetTimerAfterAutoResumeSuccess();
    _syncKeepCpuAwake();
    _notifyListeners();
    await _saveTimerRuntime();
    await _syncNativeTimerAlarms();
  }

  void retryOverdueAutoResume() {
    final autoResumeAt = _autoResumeAt;
    if (autoResumeAt == null || _pausedByTimerSessionIds.isEmpty) return;
    if (autoResumeAt.isAfter(DateTime.now())) {
      _scheduleAutoResumeTimer(autoResumeAt);
      _syncKeepCpuAwake();
      unawaited(_saveTimerRuntime());
      unawaited(_syncNativeTimerAlarms());
      return;
    }
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    unawaited(_handleAutoResumeOnPlatform(_timerGeneration));
  }

  void setAutoResume(bool enabled, int hour, int minute) {
    _autoResumeEnabled = enabled;
    _autoResumeHour = hour;
    _autoResumeMinute = minute;
    if (!enabled) {
      _autoResumeTimer?.cancel();
      _autoResumeTimer = null;
      _autoResumeAt = null;
    } else if (_pausedByTimerSessionIds.isNotEmpty) {
      _scheduleAutoResumeTimer(_nextClockTime(hour, minute));
    }
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerSettings());
    unawaited(_saveTimerRuntime());
    unawaited(_syncNativeTimerAlarms());
  }

  DateTime _nextClockTime(int hour, int minute) {
    return _timerRuntimeCalculator.nextClockTime(
      now: DateTime.now(),
      hour: hour,
      minute: minute,
    );
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

  void _maybeStartTriggerCountdown() {
    if (_timerMode != TimerMode.trigger ||
        _timerDuration == null ||
        _timerActive ||
        !_timerWaitingForPlayback) {
      return;
    }
    startCountdown();
  }

  void _tickCountdown() {
    final tick = _timerRuntimeCalculator.countdownTick(
      active: _timerActive,
      endsAt: _timerEndsAt,
      now: DateTime.now(),
      currentRemaining: _timerRemaining,
    );
    if (tick.expired) {
      _timerRemaining = tick.remaining;
      _notifyListeners();
      _onTimerExpired();
      return;
    }
    if (!tick.changed) return;
    _timerRemaining = tick.remaining;
    _notifyListeners();
  }
}
