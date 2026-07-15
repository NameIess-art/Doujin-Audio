part of 'audio_provider.dart';

extension AudioProviderPlaybackTimer on AudioProvider {
  Future<void> _handleTimerExpiredOnPlatform(int generation) async {
    final result = await _executeTimerActionOnPlatform(
      _powerPlatformService.executeTimerExpiredNow,
      generation,
    );
    if (result == TimerExecutionResult.failed) {
      await _applyLocalTimerExpiryFallback();
      return;
    }
    await _timerFacade.syncRuntimeFromNative();
    _maybeResetTimerAfterExpiry();
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_timerFacade.saveRuntime());
  }

  Future<void> _applyLocalTimerExpiryFallback() async {
    final playingSessions = _sessions.values
        .where((session) => session.effectivePlaying)
        .toList(growable: false);
    _pausedByTimerSessionIds.clear();
    for (final session in playingSessions) {
      if (await _pauseSessionPlayback(session)) {
        _pausedByTimerSessionIds.add(session.id);
      }
    }

    if (_autoResumeEnabled && _pausedByTimerSessionIds.isNotEmpty) {
      _timerFacade.scheduleAutoResumeTimer(
        _nextClockTime(_autoResumeHour, _autoResumeMinute),
      );
    }
    _maybeResetTimerAfterExpiry();
    _syncKeepCpuAwake();
    _notifyListeners();
    await _timerFacade.saveRuntime();
    await _timerFacade.syncNativeAlarms();
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
    _timerFacade.resetRuntimeState();
  }

  Future<void> _handleAutoResumeOnPlatform(int generation) async {
    final result = await _executeTimerActionOnPlatform(
      _powerPlatformService.executeAutoResumeNow,
      generation,
    );
    if (result == TimerExecutionResult.failed) {
      await _resumeTimerPausedSessions();
      return;
    }
    await _timerFacade.syncRuntimeFromNative();
    // After auto-resume the timer is fully done — reset to original state.
    _timerFacade.resetRuntimeState();
    _syncKeepCpuAwake();
    _notifyListeners();
    unawaited(_timerFacade.saveRuntime());
  }

  Future<TimerExecutionResult> _executeTimerActionOnPlatform(
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

  void _resetTimerAfterAutoResumeSuccess() {
    _timerFacade.resetRuntimeState(clearPausedSessions: false);
  }

  Future<void> _resumeTimerPausedSessions() async {
    final activated = await _activateAudioSessionForPlayback();
    if (!activated) {
      _syncKeepCpuAwake();
      _notifyListeners();
      await _timerFacade.saveRuntime();
      await _timerFacade.syncNativeAlarms();
      return;
    }

    final resumableSessions = _sessions.values
        .where((s) => _pausedByTimerSessionIds.contains(s.id))
        .toList();

    if (resumableSessions.isEmpty) {
      _pausedByTimerSessionIds.clear();
      _syncKeepCpuAwake();
      _notifyListeners();
      await _timerFacade.saveRuntime();
      await _timerFacade.syncNativeAlarms();
      return;
    }

    for (final session in resumableSessions) {
      final resumed = await _startSessionPlayback(
        session,
        shouldStartTriggerCountdown: false,
      );
      if (resumed) {
        _pausedByTimerSessionIds.remove(session.id);
      }
    }
    _pausedByTimerSessionIds.removeWhere(
      (sessionId) => !_sessions.containsKey(sessionId),
    );
    if (_pausedByTimerSessionIds.isEmpty) {
      _autoResumeAt = null;
      _resetTimerAfterAutoResumeSuccess();
    } else {
      _autoResumeTimer?.cancel();
      _autoResumeTimer = null;
    }
    _syncKeepCpuAwake();
    _notifyListeners();
    await _timerFacade.saveRuntime();
    await _timerFacade.syncNativeAlarms();
  }

  DateTime _nextClockTime(int hour, int minute) {
    return _timerRuntimeCalculator.nextClockTime(
      now: DateTime.now(),
      hour: hour,
      minute: minute,
    );
  }

  void _applyFadeMultiplierToAllPlaying(double multiplier) {
    for (final session in _sessions.values) {
      if (session.state.playing) {
        unawaited(
          _nativePlaybackRepository.setFadeMultiplier(session.id, multiplier),
        );
      }
    }
  }
}
