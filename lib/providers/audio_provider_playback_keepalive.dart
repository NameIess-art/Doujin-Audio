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
        hasPausedByTimerPaths: _pausedByTimerPaths.isNotEmpty,
      );

  void _syncKeepCpuAwake() {
    final hasPlayback = _hasPlaybackToKeepAlive;
    final hasTimer =
        _timerActive || _timerWaitingForPlayback || _hasPendingAutoResume;
    final usesUnifiedNotifications =
        _multiThreadPlaybackEnabled && _notificationsEnabled;
    final shouldKeepAwake = hasPlayback || hasTimer || _hasPendingAutoResume;
    final keepForegroundServiceAlive = _notificationsEnabled && shouldKeepAwake;
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
    _keepCpuAwake =
        _keepAliveHasPlayback || _keepAliveHasTimer || _hasPendingAutoResume;
    _keepAliveKeepsForegroundService = _notificationsEnabled && _keepCpuAwake;
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
      await AudioProvider._powerChannel.invokeMethod<void>('setKeepCpuAwake', {
        'enabled': enabled,
        'hasActivePlayback': hasActivePlayback,
        'hasActiveTimer': hasActiveTimer,
        'usesUnifiedPlaybackNotifications': usesUnifiedPlaybackNotifications,
        'keepForegroundServiceAlive': keepForegroundServiceAlive,
      });
    } on MissingPluginException {
      // Non-Android platforms don't expose this channel.
    } catch (e) {
      debugPrint('AudioProvider._setKeepCpuAwake error: $e');
    }
  }

  Future<bool> _activateAudioSessionForPlayback() async {
    try {
      final audioSession = await AudioSession.instance;
      return await audioSession.setActive(true);
    } catch (e) {
      debugPrint('AudioProvider._activateAudioSessionForPlayback error: $e');
      return true;
    }
  }

  Future<void> _deactivateAudioSession() async {
    try {
      final audioSession = await AudioSession.instance;
      await audioSession.setActive(false);
    } catch (e) {
      debugPrint('AudioProvider._deactivateAudioSession error: $e');
    }
  }
}
