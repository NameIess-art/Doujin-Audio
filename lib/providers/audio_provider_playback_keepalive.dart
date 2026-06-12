part of 'audio_provider.dart';

extension AudioProviderPlaybackKeepAlive on AudioProvider {
  bool get _hasPlayingSession => _sessions.values.any((s) => s.state.playing);

  String _nextSessionId() {
    _sessionSeed += 1;
    return 'session_${DateTime.now().microsecondsSinceEpoch}_$_sessionSeed';
  }

  bool get _hasPlaybackToKeepAlive => _sessions.values.any(
    (s) =>
        s.state.playing ||
        s.isLoading ||
        s.isPlaybackStarting ||
        s.loadedPath != null,
  );

  bool get _hasRetainedPlaybackSession => _sessions.isNotEmpty;

  bool get _hasPendingAutoResume =>
      _timerRuntimeCalculator.hasPendingAutoResume(
        autoResumeAt: _autoResumeAt,
        hasPausedByTimerSessionIds: _pausedByTimerSessionIds.isNotEmpty,
      );

  void _syncKeepCpuAwake() {
    final hasPlayback = _hasPlaybackToKeepAlive;
    final hasTimer =
        _timerActive || _timerWaitingForPlayback || _hasPendingAutoResume;
    final usesUnifiedNotifications =
        _multiThreadPlaybackEnabled && _notificationsEnabled;
    // Keep the CPU awake whenever there is active playback OR a timer is
    // running.  Previously this was only true for the timer case, which meant
    // pure playback had no redundant wake-lock protection from the keep-alive
    // service.
    final shouldKeepAwake = hasPlayback || hasTimer || _hasPendingAutoResume;
    final keepForegroundServiceAlive = shouldKeepAwake;
    if (_keepCpuAwake == shouldKeepAwake &&
        _keepAliveHasPlayback == hasPlayback &&
        _keepAliveHasTimer == hasTimer &&
        _keepAliveUsesUnifiedNotifications == usesUnifiedNotifications &&
        _keepAliveKeepsForegroundService == keepForegroundServiceAlive) {
      return;
    }
    _keepCpuAwake = shouldKeepAwake;
    _keepAliveHasPlayback = hasPlayback;
    _keepAliveHasTimer = hasTimer;
    _keepAliveUsesUnifiedNotifications = usesUnifiedNotifications;
    _keepAliveKeepsForegroundService = keepForegroundServiceAlive;
    // While a notification button action is in flight, defer the platform
    // call to avoid the keep-alive service calling stopForeground which
    // would remove the notification and cause a visible collapse/reappear.
    if (_notificationActionRefreshPending) {
      _keepAliveSyncDeferred = true;
    } else {
      _keepAliveSyncDeferred = false;
      unawaited(
        _setKeepCpuAwake(
          shouldKeepAwake,
          hasActivePlayback: hasPlayback,
          hasActiveTimer: hasTimer,
          usesUnifiedPlaybackNotifications: usesUnifiedNotifications,
          keepForegroundServiceAlive: keepForegroundServiceAlive,
        ),
      );
    }
    if (!hasPlayback && !_hasRetainedPlaybackSession) {
      unawaited(_deactivateAudioSession());
    }
  }

  void syncKeepAliveBeforeBackground() {
    _keepAliveHasPlayback = _hasPlaybackToKeepAlive;
    _keepAliveHasTimer =
        _timerActive || _timerWaitingForPlayback || _hasPendingAutoResume;
    _keepAliveUsesUnifiedNotifications =
        _multiThreadPlaybackEnabled && _notificationsEnabled;
    // Keep awake for both playback and timer (same logic as _syncKeepCpuAwake).
    _keepCpuAwake =
        _keepAliveHasPlayback || _keepAliveHasTimer || _hasPendingAutoResume;
    _keepAliveKeepsForegroundService = _keepCpuAwake;
    unawaited(
      _setKeepCpuAwake(
        _keepCpuAwake,
        hasActivePlayback: _keepAliveHasPlayback,
        hasActiveTimer: _keepAliveHasTimer,
        usesUnifiedPlaybackNotifications: _keepAliveUsesUnifiedNotifications,
        keepForegroundServiceAlive: _keepAliveKeepsForegroundService,
      ),
    );
  }

  Future<void> _setKeepCpuAwake(
    bool enabled, {
    required bool hasActivePlayback,
    required bool hasActiveTimer,
    required bool usesUnifiedPlaybackNotifications,
    required bool keepForegroundServiceAlive,
  }) async {
    try {
      await _powerPlatformService.setKeepCpuAwake(
        enabled: enabled,
        hasActivePlayback: hasActivePlayback,
        hasActiveTimer: hasActiveTimer,
        usesUnifiedPlaybackNotifications: usesUnifiedPlaybackNotifications,
        keepForegroundServiceAlive: keepForegroundServiceAlive,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'set_keep_cpu_awake_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> _activateAudioSessionForPlayback() async {
    try {
      final audioSession = await AudioSession.instance;
      return await audioSession.setActive(true);
    } catch (error, stackTrace) {
      AppLogService.error(
        'activate_audio_session_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    }
  }

  Future<void> _deactivateAudioSession() async {
    try {
      final audioSession = await AudioSession.instance;
      await audioSession.setActive(false);
    } catch (error, stackTrace) {
      AppLogService.error(
        'deactivate_audio_session_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
