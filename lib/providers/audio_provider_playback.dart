part of 'audio_provider.dart';

extension AudioProviderPlayback on AudioProvider {
  bool get _hasArmedTimerRuntime {
    final hasPendingTrigger =
        _timerMode == TimerMode.trigger &&
        _timerDuration != null &&
        _timerWaitingForPlayback;
    final hasRunningCountdown = _timerActive && _timerEndsAt != null;
    return hasPendingTrigger ||
        hasRunningCountdown ||
        _autoResumeAt != null ||
        _pausedByTimerPaths.isNotEmpty;
  }

  void _resetTimerRuntimeState({bool clearPausedSessions = true}) {
    _timerGeneration++;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _timerMode = null;
    _timerDuration = null;
    _timerActive = false;
    _timerRemaining = null;
    _timerEndsAt = null;
    _timerWaitingForPlayback = false;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoResumeAt = null;
    if (clearPausedSessions) {
      _pausedByTimerPaths.clear();
    }
  }

  Future<void> spawnSession(MusicTrack track) async {
    final session = _createSessionForTrack(track);
    _registerSession(session);
    _scheduleSessionPersistence();
    unawaited(
      _enqueueSessionPreparation(session, nextPath: track.path, autoPlay: true),
    );
  }

  PlaybackSession _createSessionForTrack(
    MusicTrack track, {
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
    double volume = 1.0,
  }) {
    return PlaybackSession(
      id: _nextSessionId(),
      currentTrackPath: track.path,
      loopMode: loopMode,
      nonSingleLoopMode: loopMode == SessionLoopMode.single
          ? SessionLoopMode.folderSequential
          : loopMode,
      volume: volume,
      createdAt: DateTime.now(),
      state: PlayerState(false, ProcessingState.idle),
    );
  }

  void _registerSession(PlaybackSession session) {
    _sessions[session.id] = session;
    _notificationsDismissedWhilePaused = false;
    _notificationFocusSessionId = session.id;
    _sessionOrder.insert(0, session.id);
    _markActiveSessionsDirty();
    _bindSessionListeners(session);
    _syncKeepCpuAwake();
    _syncNotificationState();
    _notifyListeners();
  }

  Future<void> _enqueueSessionPreparation(
    PlaybackSession session, {
    required String nextPath,
    required bool autoPlay,
  }) {
    _sessionPreparationQueue = _sessionPreparationQueue.catchError((_) {}).then(
      (_) async {
        if (!_sessions.containsKey(session.id)) return;
        await _prepareAndPlay(
          session,
          nextPath: nextPath,
          autoPlay: autoPlay,
        );
      },
    );
    return _sessionPreparationQueue;
  }

  void _bindSessionListeners(PlaybackSession session) {
    final stateSub = session.stateStream.listen((state) {
      if (!_sessions.containsKey(session.id)) return;

      final previousState =
          session._previousStateBeforeLastStateEvent ?? session.state;
      session._previousStateBeforeLastStateEvent = null;
      final previousPlaying = previousState.playing;
      final previousProcessing = previousState.processingState;
      session.state = state;
      final isNewCompletion =
          previousProcessing != ProcessingState.completed &&
          state.processingState == ProcessingState.completed;
      final currentGeneration = session.playbackCommandGeneration;
      final shouldAutoAdvanceAfterCompletion =
          isNewCompletion &&
          !session.isLoading &&
          !session.isAdvancingAfterCompletion &&
          session.loopMode != SessionLoopMode.single &&
          _nextPathFor(session, forward: true) != null &&
          session.lastHandledCompletionGeneration != currentGeneration;
      if (shouldAutoAdvanceAfterCompletion) {
        session.isLoading = true;
        session.isAdvancingAfterCompletion = true;
        session.lastHandledCompletionGeneration = currentGeneration;
      }
      if (state.processingState == ProcessingState.idle ||
          state.processingState == ProcessingState.completed) {
        session.isPlaybackStarting = false;
      }
      if (state.processingState != ProcessingState.completed) {
        session.isAdvancingAfterCompletion = false;
      }
      _syncKeepCpuAwake();
      _syncNotificationState();
      _notifyListeners();

      if (previousPlaying != state.playing ||
          previousProcessing != state.processingState) {
        _scheduleSaveSessionState();
      }

      if (isNewCompletion && shouldAutoAdvanceAfterCompletion) {
        _handleSessionCompleted(session.id);
      }
    });
    session.subscriptions.add(stateSub);

    final positionSub = session.positionStream.listen((position) {
      if (!_sessions.containsKey(session.id)) return;
      session.lastKnownPosition = position;
      final positionBucket = position.inSeconds ~/ 5;
      if (positionBucket != session.lastPersistedPositionBucket) {
        session.lastPersistedPositionBucket = positionBucket;
        _scheduleSaveSessionState(delay: const Duration(milliseconds: 800));
      }
      if (_notificationFocusedSession?.id != session.id) return;
      final changed = _refreshNotificationSubtitleForSession(
        session,
        position: position,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: changed);
    });
    session.subscriptions.add(positionSub);

    final durationSub = session.durationStream.listen((_) {
      if (!_sessions.containsKey(session.id)) return;
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
    });
    session.subscriptions.add(durationSub);

    final bufferedPositionSub = session.bufferedPositionStream.listen((_) {
      if (!_sessions.containsKey(session.id)) return;
      _scheduleFocusedNotificationRefresh(session.id);
    });
    session.subscriptions.add(bufferedPositionSub);
  }

  Future<void> _prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
  }) async {
    if (!_sessions.containsKey(session.id)) return;

    session.loadGeneration++;
    final generation = session.loadGeneration;
    session.playbackCommandGeneration = generation;

    final wasLoading = session.isLoading;
    session.isLoading = true;
    _syncKeepCpuAwake();
    _syncNotificationState();
    if (!wasLoading) {
      _notifyListeners();
    }

    var prepared = false;
    try {
      if (!_sessions.containsKey(session.id) || session.loadGeneration != generation) {
        return;
      }

      session.currentTrackPath = nextPath;
      session.lastPersistedPositionBucket = 0;
      _ensureSubtitleTrackLoaded(nextPath);
      _refreshNotificationSubtitleForSession(
        session,
        position: Duration.zero,
        syncNotification: false,
      );

      final uri = nextPath.startsWith('content://')
          ? Uri.parse(nextPath)
          : Uri.file(nextPath);

      final track = trackByPath(nextPath);
      final coverPath = coverPathForTrack(track);

      final isNewTrack = session.loadedPath != nextPath;
      if (isNewTrack) {
        session.resetStreamsForNewTrack();
      } else {
        session.setOptimisticPosition(Duration.zero);
      }

      if (isNewTrack) {
        final title = track?.displayName ?? path.basenameWithoutExtension(nextPath);
        final artUri = coverPath == null ? null : Uri.file(coverPath);
        var ok = false;
        for (var attempt = 0; attempt < 2; attempt++) {
          if (attempt > 0) {
            debugPrint(
              'AudioProvider._prepareAndPlay: retrying prepareSession '
              'after 300ms delay.',
            );
            await Future<void>.delayed(const Duration(milliseconds: 300));
            if (!_sessions.containsKey(session.id) ||
                session.loadGeneration != generation) {
              return;
            }
          }
          final result = await NativePlaybackBridge.instance.prepareSession(
            sessionId: session.id,
            uri: uri,
            title: title,
            subtitle: track?.groupTitle,
            artUri: artUri,
            startPosition: Duration.zero,
            volume: session.volume,
            repeatOne: session.loopMode == SessionLoopMode.single,
            autoPlay: false,
          );
          if (!_sessions.containsKey(session.id) ||
              session.loadGeneration != generation) {
            return;
          }
          if ((result['ok'] as bool?) == true) {
            ok = true;
            break;
          }
          debugPrint(
            'AudioProvider._prepareAndPlay: attempt ${attempt + 1} failed: '
            '${result['error'] ?? "unknown error"}.',
          );
        }
        if (!ok) return;
        session.loadedPath = nextPath;
      } else {
        await NativePlaybackBridge.instance.seek(session.id, Duration.zero);
        if (!_sessions.containsKey(session.id) ||
            session.loadGeneration != generation) {
          return;
        }
      }

      prepared = true;
    } catch (e) {
      debugPrint('AudioProvider._prepareAndPlay error: $e');
    } finally {
      if (_sessions.containsKey(session.id) && session.loadGeneration == generation) {
        session.isLoading = false;
        session.isAdvancingAfterCompletion = false;
        _syncKeepCpuAwake();
        _syncNotificationState();
        _scheduleSaveSessionState();
        _notifyListeners();
      }
    }

    if (!_sessions.containsKey(session.id) ||
        session.loadGeneration != generation) {
      return;
    }

    if (autoPlay && prepared) {
      await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
    } else {
      _syncNotificationState();
      _syncKeepCpuAwake();
    }
  }

  Future<void> toggleSessionPlayPause(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;

    if (session.state.playing) {
      session.isPlaybackStarting = false;
      await NativePlaybackBridge.instance.pause(session.id);
      session.setOptimisticState(playing: false);
    } else if (session.state.processingState == ProcessingState.completed ||
               session.state.processingState == ProcessingState.idle) {
      await _prepareAndPlay(session, nextPath: session.currentTrackPath);
    } else {
      await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
    }
  }

  Future<void> removeSession(String sessionId) async {
    await _removeSessions([sessionId]);
  }

  Future<void> _removeSessions(
    Iterable<String> sessionIds, {
    bool persist = true,
    bool notify = true,
  }) async {
    final removedSessions = <PlaybackSession>[];
    var removedAny = false;

    for (final sessionId in LinkedHashSet<String>.from(sessionIds)) {
      final session = _sessions.remove(sessionId);
      if (session == null) continue;
      removedAny = true;
      session.isPlaybackStarting = false;
      removedSessions.add(session);
      _clearNotificationSubtitleForSession(sessionId);
      if (_notificationFocusSessionId == sessionId) {
        _notificationFocusSessionId = null;
      }
      _sessionOrder.remove(sessionId);
    }

    if (!removedAny) return;

    _markActiveSessionsDirty();
    await Future.wait(
      removedSessions.map((session) async {
        await NativePlaybackBridge.instance.removeSession(session.id);
        session.dispose();
      }),
    );
    _syncKeepCpuAwake();
    _syncNotificationState();
    if (notify) {
      _notifyListeners();
    }
    if (persist) {
      _scheduleSaveSessionState();
      _scheduleSaveSessionOrder();
    }
  }

  Future<void> setSessionLoopMode(
    String sessionId,
    SessionLoopMode mode,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.loopMode = mode;
    if (mode != SessionLoopMode.single) {
      session.nonSingleLoopMode = mode;
    }
    await NativePlaybackBridge.instance.setRepeatOne(
      session.id,
      mode == SessionLoopMode.single,
    );
    _syncNotificationState();
    _notifyListeners();
    _scheduleSaveSessionState();
  }

  bool _isShuffleMode(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.folderRandom;
  }

  bool _isCrossFolderMode(SessionLoopMode mode) {
    return mode == SessionLoopMode.crossRandom ||
        mode == SessionLoopMode.crossSequential;
  }

  Future<void> toggleSessionSingleLoop(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.loopMode == SessionLoopMode.single) {
      await setSessionLoopMode(sessionId, session.nonSingleLoopMode);
      return;
    }
    session.nonSingleLoopMode = session.loopMode;
    await setSessionLoopMode(sessionId, SessionLoopMode.single);
  }

  Future<void> toggleSessionShuffle(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    final isCrossFolder = _isCrossFolderMode(session.loopMode);
    final isShuffle = _isShuffleMode(session.loopMode);
    final nextMode = isShuffle
        ? (isCrossFolder
              ? SessionLoopMode.crossSequential
              : SessionLoopMode.folderSequential)
        : (isCrossFolder
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.folderRandom);
    await setSessionLoopMode(sessionId, nextMode);
  }

  Future<void> toggleSessionCrossFolder(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.loopMode == SessionLoopMode.single) return;
    final isCrossFolder = _isCrossFolderMode(session.loopMode);
    final isShuffle = _isShuffleMode(session.loopMode);
    final nextMode = isCrossFolder
        ? (isShuffle
              ? SessionLoopMode.folderRandom
              : SessionLoopMode.folderSequential)
        : (isShuffle
              ? SessionLoopMode.crossRandom
              : SessionLoopMode.crossSequential);
    await setSessionLoopMode(sessionId, nextMode);
  }

  Future<void> setSessionVolume(
    String sessionId,
    double volume, {
    bool persist = true,
    bool notify = true,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final nextVolume = volume.clamp(0.0, 1.0);
    if ((session.volume - nextVolume).abs() < 0.001) {
      if (persist) {
        _scheduleSaveSessionState();
      }
      return;
    }
    session.volume = nextVolume;
    await NativePlaybackBridge.instance.setVolume(session.id, session.volume);
    if (notify) {
      _notifyListeners();
    }
    if (persist) {
      _scheduleSaveSessionState();
    }
  }

  Future<void> seekSession(String sessionId, Duration position) async {
    final session = _sessions[sessionId];
    if (session != null) {
      await NativePlaybackBridge.instance.seek(session.id, position);
      session.setOptimisticPosition(position);
      session.lastPersistedPositionBucket = position.inSeconds ~/ 5;
      _refreshNotificationSubtitleForSession(
        session,
        position: position,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
    }
  }

  Future<void> switchSessionTrack(String sessionId, String newPath) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;
    await _prepareAndPlay(session, nextPath: newPath);
    _scheduleSaveSessionState();
  }

  Future<void> seekSessionToNext(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;
    final nextPath = _nextPathFor(session, forward: true);
    if (nextPath != null) {
      await _prepareAndPlay(session, nextPath: nextPath);
    }
  }

  Future<void> seekSessionToPrev(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.isLoading) return;
    if (session.position.inSeconds > 3) {
      await NativePlaybackBridge.instance.seek(session.id, Duration.zero);
      session.setOptimisticPosition(Duration.zero);
      session.lastPersistedPositionBucket = 0;
      _refreshNotificationSubtitleForSession(
        session,
        position: Duration.zero,
        syncNotification: false,
      );
      _scheduleFocusedNotificationRefresh(session.id, immediate: true);
      return;
    }
    final prevPath = _nextPathFor(session, forward: false);
    if (prevPath != null) {
      await _prepareAndPlay(session, nextPath: prevPath);
    }
  }

  Future<void> pauseAllSessions() async {
    await NativePlaybackBridge.instance.pauseAll();
    for (final session in _sessions.values) {
      session.setOptimisticState(playing: false);
    }
    _syncKeepCpuAwake();
    _scheduleSaveSessionState();
  }

  Future<void> clearAllSessions() async {
    await _removeSessions(_sessions.keys.toList());
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
  }

  void startCountdown() {
    if (_timerDuration == null || _timerActive) return;
    _countdownTimer?.cancel();
    final generation = ++_timerGeneration;
    _timerActive = true;
    _timerWaitingForPlayback = false;
    _timerRemaining = _timerDuration;
    _timerEndsAt = DateTime.now().add(_timerDuration!);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
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
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, hour, minute);
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
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
    if (!_timerActive || _timerEndsAt == null) return;
    final remaining = _timerEndsAt!.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _timerRemaining = Duration.zero;
      _notifyListeners();
      _onTimerExpired();
      return;
    }

    final roundedSeconds = (remaining.inMilliseconds + 999) ~/ 1000;
    final next = Duration(seconds: roundedSeconds);
    if (next == _timerRemaining) return;
    _timerRemaining = next;
    _notifyListeners();
  }

  bool get _hasPlayingSession => _sessions.values.any((s) => s.state.playing);

  String _nextSessionId() {
    _sessionSeed += 1;
    return 'session_${DateTime.now().microsecondsSinceEpoch}_$_sessionSeed';
  }

  bool get _hasPlaybackToKeepAlive => _sessions.values.any(
    (s) => s.state.playing || s.isLoading || s.isPlaybackStarting,
  );

  bool get _hasRetainedPlaybackSession => _sessions.isNotEmpty;

  bool get _hasPendingAutoResume =>
      _autoResumeAt != null && _pausedByTimerPaths.isNotEmpty;

  void _syncKeepCpuAwake() {
    final hasPlayback = _hasPlaybackToKeepAlive;
    final hasTimer =
        _timerActive || _timerWaitingForPlayback || _hasPendingAutoResume;
    final usesUnifiedNotifications = _multiThreadPlaybackEnabled && _notificationsEnabled;
    final keepForegroundServiceAlive = _notificationsEnabled &&
        (hasPlayback || hasTimer || _hasPendingAutoResume);
    final shouldKeepAwake = keepForegroundServiceAlive;
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

  Future<void> _startSessionPlayback(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) async {
    if (!_sessions.containsKey(session.id)) return;
    final generation = ++session.playbackCommandGeneration;
    _notificationsDismissedWhilePaused = false;
    unawaited(NativePlaybackBridge.instance.undismissNotifications());
    if (!_multiThreadPlaybackEnabled) {
      await _enforceSingleThreadPlayback(preferredSessionId: session.id);
    }
    if (!_sessions.containsKey(session.id) ||
        session.playbackCommandGeneration != generation) {
      return;
    }
    final activated = await _activateAudioSessionForPlayback();
    if (!_sessions.containsKey(session.id) ||
        session.playbackCommandGeneration != generation) {
      return;
    }
    if (!activated) {
      debugPrint(
        'AudioProvider._startSessionPlayback: audio session activation '
        'returned false; continuing playback attempt.',
      );
    }

    _notificationFocusSessionId = session.id;
    session.isPlaybackStarting = true;
    _syncKeepCpuAwake();
    session.setOptimisticState(
      playing: true,
      processingState: session.state.processingState == ProcessingState.idle
          ? ProcessingState.loading
          : null,
    );

    try {
      final playResult = await NativePlaybackBridge.instance.play(session.id);
      if (!_sessions.containsKey(session.id) ||
          session.playbackCommandGeneration != generation) {
        return;
      }
      if ((playResult['ok'] as bool?) != true) {
        session.isPlaybackStarting = false;
        session.setOptimisticState(
          playing: false,
          processingState: session.loadedPath != null
              ? ProcessingState.ready
              : ProcessingState.idle,
        );
      } else if (!session.state.playing &&
          session.isPlaybackStarting) {
        // Stale EventChannel snapshots from prepareSession may have
        // overwritten the optimistic playing state. Re-assert it.
        session.setOptimisticState(
          playing: true,
          processingState: session.loadedPath != null
              ? ProcessingState.ready
              : ProcessingState.idle,
        );
      }
    } catch (e) {
      if (_sessions.containsKey(session.id) &&
          session.playbackCommandGeneration == generation) {
        session.isPlaybackStarting = false;
        session.setOptimisticState(
          playing: false,
          processingState: session.loadedPath != null
              ? ProcessingState.ready
              : ProcessingState.idle,
        );
      }
      debugPrint('AudioProvider._startSessionPlayback error: $e');
    }

    if (!_sessions.containsKey(session.id) ||
        session.playbackCommandGeneration != generation) {
      return;
    }
    _syncKeepCpuAwake();
    unawaited(_clearPlaybackStartingIfStillPending(session.id, generation));
    if (shouldStartTriggerCountdown) {
      _maybeStartTriggerCountdown();
    }
  }

  Future<void> _clearPlaybackStartingIfStillPending(
    String sessionId,
    int generation,
  ) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final session = _sessions[sessionId];
    if (session == null ||
        session.playbackCommandGeneration != generation ||
        !session.isPlaybackStarting ||
        session.state.playing) {
      return;
    }
    session.isPlaybackStarting = false;
    _syncKeepCpuAwake();
    _syncNotificationState();
  }

  Future<void> _resetSessionsForSingleThreadMode() async {
    if (_sessions.isEmpty) {
      _notificationFocusSessionId = null;
      _syncNotificationState();
      return;
    }

    await Future.wait(
      _sessions.values.map(
        (session) => NativePlaybackBridge.instance.pause(session.id),
      ),
    );
    for (final session in _sessions.values) {
      session.setOptimisticState(playing: false);
    }
    _syncKeepCpuAwake();
    _notificationFocusSessionId = null;
    _syncNotificationState();
    _notifyListeners();
  }

  Future<void> _enforceSingleThreadPlayback({
    String? preferredSessionId,
  }) async {
    final keepSessionId =
        (preferredSessionId != null &&
            _sessions.containsKey(preferredSessionId))
        ? preferredSessionId
        : _preferredSingleSessionId;
    if (keepSessionId == null) return;

    final sessionsToPause = _sessions.values
        .where(
          (session) => session.id != keepSessionId && session.state.playing,
        )
        .toList(growable: false);
    _notificationFocusSessionId = keepSessionId;
    if (sessionsToPause.isEmpty) {
      _syncNotificationState();
      _notifyListeners();
      return;
    }

    await Future.wait(
      sessionsToPause.map((session) {
        session.setOptimisticState(playing: false);
        return NativePlaybackBridge.instance.pause(session.id);
      }),
    );
    _notificationFocusSessionId = keepSessionId;
    _syncKeepCpuAwake();
    _syncNotificationState();
    _notifyListeners();
  }

  String? get _preferredSingleSessionId {
    for (final session in activeSessions) {
      if (session.state.playing) return session.id;
    }
    final sessions = activeSessions;
    if (sessions.isEmpty) return null;
    return sessions.first.id;
  }

  void reorderSessions(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _sessionOrder.length) return;
    if (newIndex < 0 || newIndex > _sessionOrder.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = _sessionOrder.removeAt(oldIndex);
    _sessionOrder.insert(newIndex, moved);
    _markActiveSessionsDirty();
    _syncNotificationState();
    _notifyListeners();
    _scheduleSaveSessionOrder();
  }

  Future<void> _handleSessionCompleted(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.loopMode == SessionLoopMode.single) {
      session.isAdvancingAfterCompletion = false;
      return;
    }

    final nextPath = _nextPathFor(session, forward: true);
    if (nextPath == null) {
      session.isAdvancingAfterCompletion = false;
      session.isLoading = false;
      _syncKeepCpuAwake();
      _syncNotificationState();
      return;
    }

    final completionGeneration = session.playbackCommandGeneration;
    session.isLoading = true;
    session.isAdvancingAfterCompletion = true;
    _syncKeepCpuAwake();
    _syncNotificationState();

    if (nextPath == session.currentTrackPath) {
      try {
        await NativePlaybackBridge.instance.seek(session.id, Duration.zero);
        if (!_sessions.containsKey(session.id) ||
            session.playbackCommandGeneration != completionGeneration) {
          return;
        }
        session.setOptimisticPosition(Duration.zero);
      } finally {
        if (_sessions.containsKey(session.id) &&
            session.playbackCommandGeneration == completionGeneration) {
          session.isLoading = false;
          session.isAdvancingAfterCompletion = false;
          _syncNotificationState();
          _notifyListeners();
        }
      }
      if (_sessions.containsKey(session.id) &&
          session.playbackCommandGeneration == completionGeneration) {
        await _startSessionPlayback(
          session,
          shouldStartTriggerCountdown: false,
        );
      }
    } else {
      await _prepareAndPlay(session, nextPath: nextPath);
      if (_sessions.containsKey(session.id)) {
        session.isAdvancingAfterCompletion = false;
      }
    }
  }

  String? _nextPathFor(PlaybackSession session, {required bool forward}) {
    final currentTrack = trackByPath(session.currentTrackPath);
    if (currentTrack == null || _library.isEmpty) return null;

    switch (session.loopMode) {
      case SessionLoopMode.single:
        return currentTrack.path;
      case SessionLoopMode.crossRandom:
        if (forward) {
          final all = _sortedLibraryTracks
              .map((track) => track.path)
              .toList(growable: false);
          if (all.length == 1) return all.first;
          final rnd = Random();
          String candidate = all[rnd.nextInt(all.length)];
          var guard = 0;
          while (candidate == currentTrack.path && guard < 10) {
            candidate = all[rnd.nextInt(all.length)];
            guard++;
          }
          return candidate;
        }
        return _nextPathFor(session, forward: true);
      case SessionLoopMode.folderSequential:
        final scope =
            _tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[];
        if (scope.isEmpty) return currentTrack.path;
        final idx = scope.indexWhere((t) => t.path == currentTrack.path);
        if (idx < 0) return scope.first.path;
        final next = (idx + (forward ? 1 : -1) + scope.length) % scope.length;
        return scope[next].path;
      case SessionLoopMode.crossSequential:
        final all = _sortedLibraryTracks;
        final idx = all.indexWhere((t) => t.path == currentTrack.path);
        if (idx < 0) return all.first.path;
        final next = (idx + (forward ? 1 : -1) + all.length) % all.length;
        return all[next].path;
      case SessionLoopMode.folderRandom:
        if (forward) {
          final scope =
              (_tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[])
                  .map((track) => track.path)
                  .toList(growable: false);
          if (scope.isEmpty) return currentTrack.path;
          if (scope.length == 1) return scope.first;
          final rnd = Random();
          String candidate = scope[rnd.nextInt(scope.length)];
          var guard = 0;
          while (candidate == currentTrack.path && guard < 10) {
            candidate = scope[rnd.nextInt(scope.length)];
            guard++;
          }
          return candidate;
        }
        return _nextPathFor(session, forward: true);
    }
  }
}
