part of 'audio_provider.dart';

extension AudioProviderPlaybackTimer on AudioProvider {
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
  }

  void cancelTimer() {
    _resetTimerRuntimeState();
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerRuntime());
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
  }

  void _onTimerExpired() {
    _timerGeneration++;
    _timerActive = false;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;

    _pausedByTimerPaths
      ..clear()
      ..addAll(
        _sessions.values
            .where((s) => s.state.playing)
            .map((s) => s.currentTrackPath),
      );

    for (final session in _sessions.values) {
      unawaited(NativePlaybackBridge.instance.pause(session.id));
      session.setOptimisticState(playing: false);
    }

    _notifyListeners();

    if (_autoResumeEnabled) {
      _scheduleAutoResumeTimer(
        _nextClockTime(_autoResumeHour, _autoResumeMinute),
      );
    }
    _syncKeepCpuAwake();
    unawaited(_saveTimerRuntime());
  }

  void _onAutoResume() {
    _autoResumeTimer = null;
    _autoResumeAt = null;
    unawaited(_saveTimerRuntime());
    unawaited(_resumeTimerPausedSessions());
  }

  void _resetTimerAfterAutoResumeSuccess() {
    _resetTimerRuntimeState(clearPausedSessions: false);
  }

  Future<void> _resumeTimerPausedSessions() async {
    final activated = await _activateAudioSessionForPlayback();
    if (!activated) return;

    final resumableSessions = _sessions.values
        .where((s) => _pausedByTimerPaths.contains(s.currentTrackPath))
        .toList();

    if (resumableSessions.isEmpty) {
      _pausedByTimerPaths.clear();
      _syncKeepCpuAwake();
      _notifyListeners();
      await _saveTimerRuntime();
      return;
    }

    for (final session in resumableSessions) {
      await _startSessionPlayback(session, shouldStartTriggerCountdown: false);
    }
    _pausedByTimerPaths.clear();
    _autoResumeAt = null;
    _resetTimerAfterAutoResumeSuccess();
    _syncKeepCpuAwake();
    _notifyListeners();
    await _saveTimerRuntime();
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
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_saveTimerSettings());
    unawaited(_saveTimerRuntime());
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
