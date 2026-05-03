part of 'audio_provider.dart';

extension AudioProviderNotifications on AudioProvider {

  void _bindNotificationHandler() {
    _notificationService.bindCallbacks(
      onPlay: playPrimarySessionFromNotification,
      onPlayFromMediaId: playNotificationSessionById,
      onPause: pausePrimarySessionFromNotification,
      onStop: stopPrimarySessionFromNotification,
      onSkipToNext: skipPrimarySessionToNextFromNotification,
      onSkipToPrevious: skipPrimarySessionToPreviousFromNotification,
      onSeek: seekPrimarySessionFromNotification,
      onTogglePlayPause: togglePrimarySessionPlayPauseFromNotification,
      onToggleSessionPlayback: toggleSessionPlaybackFromNotification,
      onSkipToPreviousSession: skipNotificationSessionToPreviousById,
      onSkipToNextSession: skipNotificationSessionToNextById,
      onNotificationDeleted: dismissNotificationsAfterPauseAll,
      onRestoreNotifications: restoreNotificationsAfterSystemClear,
    );
    _syncNotificationState();
  }

  Future<void> playPrimarySessionFromNotification() {
    return _guardNotificationAction(() async {
      final session = _resolveNotificationSession();
      if (session == null) return;
      await _resumeNotificationSession(session);
    });
  }

  Future<void> playNotificationSessionById(String mediaId) {
    return _guardNotificationAction(() async {
      final session = _resolveNotificationSession(mediaId);
      if (session == null) return;
      await _resumeNotificationSession(session);
    });
  }

  Future<void> pausePrimarySessionFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null || !session.state.playing) return;
      _notificationFocusSessionId = session.id;
      await NativePlaybackBridge.instance.pause(session.id);
      session.setOptimisticState(playing: false);
    });
  }

  Future<void> togglePrimarySessionPlayPauseFromNotification() {
    return _guardNotificationAction(() async {
      final session = _resolveNotificationSession();
      if (session == null || session.isLoading) return;
      if (session.state.playing) {
        await NativePlaybackBridge.instance.pause(session.id);
        session.setOptimisticState(playing: false);
        return;
      }
      await _resumeNotificationSession(session);
    });
  }

  Future<void> stopPrimarySessionFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await NativePlaybackBridge.instance.pause(session.id);
      session.setOptimisticState(playing: false);
    });
  }

  Future<void> skipPrimarySessionToNextFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await seekSessionToNext(session.id);
    });
  }

  Future<void> skipPrimarySessionToPreviousFromNotification() {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await seekSessionToPrev(session.id);
    });
  }

  Future<void> toggleSessionPlaybackFromNotification(String sessionId) {
    return _guardNotificationAction(() async {
      final session = _sessions[sessionId];
      if (session == null) return;
      if (!_multiThreadPlaybackEnabled) {
        _notificationFocusSessionId = session.id;
      }
      await toggleSessionPlayPause(session.id);
    });
  }

  Future<void> skipNotificationSessionToPreviousById(String sessionId) {
    return _guardNotificationAction(() async {
      final session = _sessions[sessionId];
      if (session == null) return;
      if (!_multiThreadPlaybackEnabled) {
        _notificationFocusSessionId = session.id;
      }
      await seekSessionToPrev(session.id);
    });
  }

  Future<void> skipNotificationSessionToNextById(String sessionId) {
    return _guardNotificationAction(() async {
      final session = _sessions[sessionId];
      if (session == null) return;
      if (!_multiThreadPlaybackEnabled) {
        _notificationFocusSessionId = session.id;
      }
      await seekSessionToNext(session.id);
    });
  }

  Future<void> seekPrimarySessionFromNotification(Duration position) {
    return _guardNotificationAction(() async {
      final session = _notificationActionSession;
      if (session == null) return;
      _notificationFocusSessionId = session.id;
      await seekSession(session.id, position);
    });
  }

  Future<void> dismissNotificationsAfterPauseAll() async {
    _notificationsDismissedWhilePaused = true;
    await NativePlaybackBridge.instance.dismissNotifications();
    // Clear unified notifications before stopping the keep-alive service
    // so that activeNotificationCount is 0, which causes the keep-alive
    // service to use STOP_FOREGROUND_REMOVE instead of DETACH.
    await _clearUnifiedPlaybackNotificationsOnPlatform();
    await _stopPlaybackKeepAliveOnPlatform();
    await pauseAllSessions();
    // Clear the handler snapshot so audio_service shows no notification,
    // but keep the handler registered so that unified notification button
    // actions (via UnifiedPlaybackActionReceiver -> AudioService.dispatchCustomAction)
    // continue to work.
    _notificationService.updateSnapshot(null);
    _notificationFocusSessionId = _preferredSingleSessionId;
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  Future<void> restoreNotificationsAfterSystemClear() async {
    _notificationsDismissedWhilePaused = false;
    _unifiedNotificationSyncKey = null;
    await NativePlaybackBridge.instance.undismissNotifications();
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
  }

  void resyncNotificationsAfterResume() {
    if (!_notificationsDismissedWhilePaused) return;
    _notificationsDismissedWhilePaused = false;
    _unifiedNotificationSyncKey = null;
    unawaited(NativePlaybackBridge.instance.undismissNotifications());
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
  }

  List<PlaybackSession> get _singleThreadNotificationSessions {
    return activeSessions
        .where(
          (session) =>
              session.state.playing ||
              session.isPlaybackStarting ||
              session.state.processingState == ProcessingState.idle ||
              session.state.processingState == ProcessingState.ready ||
              session.state.processingState == ProcessingState.completed,
        )
        .toList(growable: false);
  }

  List<PlaybackSession> get _notificationQueueSessions {
    return _multiThreadPlaybackEnabled
        ? activeSessions
        : _singleThreadNotificationSessions;
  }

  PlaybackSession? _focusedSessionFrom(Iterable<PlaybackSession> sessions) {
    final focusedId = _notificationFocusSessionId;
    if (focusedId != null) {
      for (final session in sessions) {
        if (session.id == focusedId) return session;
      }
    }
    final fallback = sessions.isNotEmpty ? sessions.first : null;
    _notificationFocusSessionId = fallback?.id;
    return fallback;
  }

  PlaybackSession? get _notificationFocusedSession {
    return _focusedSessionFrom(_notificationQueueSessions);
  }

  PlaybackSession? get _notificationActionSession {
    final focused = _focusedSessionFrom(activeSessions);
    if (focused != null) {
      return focused;
    }
    return _focusedSessionFrom(_notificationQueueSessions);
  }

  PlaybackSession? _resolveNotificationSession([String? sessionId]) {
    if (sessionId != null) {
      final matchedSession = _sessions[sessionId];
      if (matchedSession != null) {
        _notificationFocusSessionId = matchedSession.id;
        return matchedSession;
      }
    }
    final focusedSession = _notificationActionSession;
    if (focusedSession != null) {
      _notificationFocusSessionId = focusedSession.id;
    }
    return focusedSession;
  }

  // Must be called synchronously at the *start* of every notification
  // button callback, before any state changes or platform calls that
  // could trigger intermediate NotificationManager.notify() while
  // Android's SystemUI is still processing the PendingIntent.
  void _beginNotificationAction() {
    _unifiedNotificationSyncKey = null;
    _unifiedNotificationSyncTimer?.cancel();
    _unifiedNotificationSyncTimer = null;
    _notificationActionRefreshTimer?.cancel();
    _notificationActionRefreshTimer = null;
    _notificationActionRefreshPending = true;

    // Safety timeout: force-clear the guard if _scheduleNotificationActionRefresh
    // is never called (e.g., due to an uncaught exception between begin/schedule).
    _notificationActionGuardTimeout?.cancel();
    _notificationActionGuardTimeout = Timer(
      const Duration(seconds: 5),
      () {
        _notificationActionGuardTimeout = null;
        if (_notificationActionRefreshPending) {
          debugPrint(
            'AudioProvider: notification action guard timed out, force-clearing',
          );
          _notificationActionRefreshPending = false;
          if (_keepAliveSyncDeferred) {
            _keepAliveSyncDeferred = false;
            _syncKeepCpuAwake();
          }
          _syncNotificationState(immediateUnifiedSync: true);
          _notifyListeners();
        }
      },
    );
  }

  Future<void> _guardNotificationAction(Future<void> Function() action) async {
    _beginNotificationAction();
    try {
      await action();
    } finally {
      _scheduleNotificationActionRefresh();
    }
  }

  void _scheduleNotificationActionRefresh() {
    // The guard was already set by _beginNotificationAction; reset the
    // timer so we extend the window from the last state mutation, then
    // schedule the real sync once SystemUI has finished processing the
    // PendingIntent.
    _notificationActionGuardTimeout?.cancel();
    _notificationActionGuardTimeout = null;
    _notificationActionRefreshTimer?.cancel();
    _notificationActionRefreshTimer = Timer(
      const Duration(milliseconds: 250),
      () {
        _notificationActionRefreshTimer = null;
        _notificationActionRefreshPending = false;
        // Flush any keep-alive sync that was deferred while the action
        // guard was active, so the foreground service state is updated
        // BEFORE the notification is re-posted.
        if (_keepAliveSyncDeferred) {
          _keepAliveSyncDeferred = false;
          _syncKeepCpuAwake();
        }
        _syncNotificationState(immediateUnifiedSync: true);
        _notifyListeners();
      },
    );

    _notifyListeners();
  }

  Future<void> _resumeNotificationSession(PlaybackSession session) async {
    if (session.isLoading || session.state.playing) return;
    _notificationFocusSessionId = session.id;
    if (session.state.processingState == ProcessingState.completed) {
      await _prepareAndPlay(session, nextPath: session.currentTrackPath);
      return;
    }
    await _startSessionPlayback(session, shouldStartTriggerCountdown: true);
  }

  String _notificationTitleForSession(PlaybackSession session) {
    final track = trackByPath(session.currentTrackPath);
    return track?.displayName ??
        path.basenameWithoutExtension(session.currentTrackPath);
  }

  List<String> _notificationOverviewTitles(Iterable<PlaybackSession> sessions) {
    final uniqueTitles = <String>{};
    for (final session in sessions) {
      final title = _notificationTitleForSession(session);
      if (title.isNotEmpty) {
        uniqueTitles.add(title);
      }
    }
    return uniqueTitles.toList(growable: false);
  }

  String _notificationSummaryText(List<PlaybackSession> sessions) {
    final titles = _notificationOverviewTitles(sessions);
    if (titles.isEmpty) {
      return '${sessions.length} active sessions';
    }
    if (titles.length == 1) {
      return titles.first;
    }
    if (titles.length == 2) {
      return '${titles[0]} / ${titles[1]}';
    }
    return '${titles.first} +${titles.length - 1}';
  }

  String? coverPathForTrack(MusicTrack? track) {
    final coverSearchKey = _notificationCoverSearchKey(track);
    if (coverSearchKey == null) {
      return null;
    }
    return _resolvedNotificationCoverPaths[coverSearchKey];
  }

  Future<String?> coverPathFutureForTrack(MusicTrack? track) {
    return _resolveNotificationCoverPathForTrack(track);
  }

  Future<String?> coverPathFutureForFolder(String folderPath) {
    if (folderPath.startsWith('content://')) {
      return Future<String?>.value(null);
    }
    return _resolveCoverPathForFolder(folderPath);
  }

  String? _notificationCoverSearchKey(MusicTrack? track) {
    if (track == null) {
      return null;
    }
    if (track.path.startsWith('content://')) {
      final groupKey = track.groupKey.trim();
      if (groupKey.isNotEmpty) {
        return 'content:$groupKey';
      }
      return 'content:${track.path}';
    }
    final directoryPath = path.dirname(track.path);
    if (directoryPath.isEmpty || directoryPath == '.') {
      return null;
    }
    return path.normalize(directoryPath);
  }

  Future<String?> _resolveNotificationCoverPathForTrack(MusicTrack? track) {
    final coverSearchKey = _notificationCoverSearchKey(track);
    if (coverSearchKey == null) {
      return Future<String?>.value(null);
    }
    if (_resolvedNotificationCoverPaths.containsKey(coverSearchKey)) {
      return Future<String?>.value(
        _resolvedNotificationCoverPaths[coverSearchKey],
      );
    }

    return _notificationCoverPathFutures.putIfAbsent(coverSearchKey, () async {
      String? coverPath;
      if (track != null) {
        if (track.path.startsWith('content://')) {
          coverPath = await _resolveContentCoverPathForTrack(track);
        } else {
          for (final candidateDirectory
              in _notificationCoverCandidateDirectories(track)) {
            coverPath = await _findNotificationCoverPath(candidateDirectory);
            if (coverPath != null) {
              break;
            }
          }
        }
      }

      _notificationCoverPathFutures.remove(coverSearchKey);
      final previous = _resolvedNotificationCoverPaths[coverSearchKey];
      _resolvedNotificationCoverPaths[coverSearchKey] = coverPath;

      if (previous != coverPath) {
        final focusedTrack = trackByPath(
          _notificationFocusedSession?.currentTrackPath ?? '',
        );
        if (_notificationCoverSearchKey(focusedTrack) == coverSearchKey) {
          _syncNotificationState();
          _notifyListeners();
        }
      }

      return coverPath;
    });
  }

  Future<String?> _resolveContentCoverPathForTrack(MusicTrack track) async {
    try {
      return await AudioProvider._fileCacheChannel.invokeMethod<String>(
        'resolveTrackCover',
        <String, dynamic>{'path': track.path, 'groupKey': track.groupKey},
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('AudioProvider._resolveContentCoverPathForTrack error: $e');
      return null;
    }
  }

  List<String> _notificationCoverCandidateDirectories(MusicTrack track) {
    final coverSearchKey = _notificationCoverSearchKey(track);
    if (coverSearchKey == null) {
      return const <String>[];
    }

    final directories = <String>[coverSearchKey];
    for (final watchedFolder in _watchedFolders) {
      if (watchedFolder.startsWith('content://')) {
        continue;
      }
      final normalizedRoot = path.normalize(watchedFolder);
      if (!_isPathWithinOrEqual(coverSearchKey, normalizedRoot)) {
        continue;
      }

      var current = coverSearchKey;
      while (!path.equals(current, normalizedRoot)) {
        final parent = path.dirname(current);
        if (parent == current || directories.contains(parent)) {
          break;
        }
        directories.add(parent);
        current = parent;
      }
    }
    return directories;
  }

  bool _isPathWithinOrEqual(String pathValue, String rootPath) {
    return path.equals(pathValue, rootPath) ||
        path.isWithin(rootPath, pathValue);
  }

  Future<String?> _resolveCoverPathForFolder(String folderPath) {
    if (_resolvedCoverPaths.containsKey(folderPath)) {
      return Future<String?>.value(_resolvedCoverPaths[folderPath]);
    }

    return _coverPathFutures.putIfAbsent(folderPath, () async {
      final coverPath = await _findNotificationCoverPath(folderPath);
      _coverPathFutures.remove(folderPath);

      final previous = _resolvedCoverPaths[folderPath];
      _resolvedCoverPaths[folderPath] = coverPath;

      if (previous != coverPath) {
        _notifyListeners();
      }

      return coverPath;
    });
  }

  Future<String?> _findNotificationCoverPath(String folderPath) async {
    final directory = Directory(folderPath);
    if (!await directory.exists()) return null;

    final images = <String>[];
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final extension = path.extension(entity.path).toLowerCase();
        if (AudioProvider._supportedImageExtensions.contains(extension)) {
          images.add(entity.path);
        }
      }
    } catch (_) {
      return null;
    }

    if (images.isEmpty) return null;
    images.sort((a, b) {
      final nameResult = path
          .basename(a)
          .toLowerCase()
          .compareTo(path.basename(b).toLowerCase());
      if (nameResult != 0) return nameResult;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return images.first;
  }

  void _clearResolvedCoverPaths() {
    _coverPathFutures.clear();
    _resolvedCoverPaths.clear();
    _notificationCoverPathFutures.clear();
    _resolvedNotificationCoverPaths.clear();
  }

  Future<void> _clearUnifiedPlaybackNotificationsOnPlatform() async {
    _unifiedNotificationSyncKey = null;
    await _notificationService.clearUnifiedNotifications();
  }

  Future<void> _stopPlaybackKeepAliveOnPlatform() async {
    try {
      await AudioProvider._powerChannel.invokeMethod<void>(
        'stopPlaybackKeepAlive',
      );
    } on MissingPluginException {
      // The Android power channel is not available on this platform.
    } catch (e) {
      debugPrint('AudioProvider._stopPlaybackKeepAliveOnPlatform error: $e');
    }
  }

  void _syncNotificationState({bool immediateUnifiedSync = false}) {
    if (!_notificationsEnabled) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationService.updateSnapshot(null);
      _clearUnifiedPlaybackNotificationsOnPlatform();
      return;
    }

    if (_notificationsDismissedWhilePaused && !_hasPlaybackToKeepAlive) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationService.updateSnapshot(null);
      _requestUnifiedPlaybackNotificationFlush();
      return;
    }

    if (immediateUnifiedSync) {
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _requestUnifiedPlaybackNotificationFlush();
    } else {
      _scheduleUnifiedPlaybackNotificationSync();
    }
  }

  void _scheduleUnifiedPlaybackNotificationSync() {
    if (_unifiedNotificationSyncTimer != null) {
      return;
    }
    if (_notificationActionRefreshPending) {
      return;
    }
    _unifiedNotificationSyncTimer = Timer(
      AudioProvider._unifiedNotificationDebounceInterval,
      () {
        _unifiedNotificationSyncTimer = null;
        _requestUnifiedPlaybackNotificationFlush();
      },
    );
  }

  void _requestUnifiedPlaybackNotificationFlush() {
    _unifiedNotificationSyncPending = true;
    if (_unifiedNotificationSyncInFlight) {
      return;
    }
    _unifiedNotificationSyncInFlight = true;
    unawaited(_flushUnifiedPlaybackNotificationState());
  }

  Future<void> _flushUnifiedPlaybackNotificationState() async {
    try {
      while (_unifiedNotificationSyncPending) {
        _unifiedNotificationSyncPending = false;
        final shouldShowUnifiedNotifications =
            _notificationsEnabled &&
            !_notificationsDismissedWhilePaused;
        if (!shouldShowUnifiedNotifications) {
          await _clearUnifiedPlaybackNotificationsOnPlatform();
          continue;
        }
        await _syncUnifiedPlaybackNotifications();
      }
    } finally {
      _unifiedNotificationSyncInFlight = false;
      if (_unifiedNotificationSyncPending) {
        _requestUnifiedPlaybackNotificationFlush();
      }
    }
  }

  void _scheduleFocusedNotificationRefresh(
    String sessionId, {
    bool immediate = false,
  }) {
    if (_notificationFocusedSession?.id != sessionId) {
      return;
    }

    if (_shouldUseUnifiedPlaybackNotifications) {
      immediate = false;
    }

    if (immediate) {
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      _syncNotificationState();
      return;
    }

    _queuedNotificationRefreshSessionId = sessionId;
    if (_notificationProgressRefreshTimer != null) {
      return;
    }

    _notificationProgressRefreshTimer = Timer(_notificationRefreshInterval, () {
      _notificationProgressRefreshTimer = null;
      final queuedSessionId = _queuedNotificationRefreshSessionId;
      _queuedNotificationRefreshSessionId = null;
      if (queuedSessionId == null ||
          _notificationFocusedSession?.id != queuedSessionId) {
        return;
      }
      _syncNotificationState();
    });
  }

  Future<void> _syncUnifiedPlaybackNotifications() async {
    final isMultiMode = _multiThreadPlaybackEnabled;
    final mainSession = _focusedSessionFrom(
      isMultiMode ? activeSessions : _singleThreadNotificationSessions,
    );
    final sessionsToShow = isMultiMode
        ? activeSessions
        : (mainSession == null ? const <PlaybackSession>[] : <PlaybackSession>[mainSession]);
    final showUnifiedSummary = sessionsToShow.isNotEmpty;
    final summaryText = showUnifiedSummary
        ? _notificationSummaryText(sessionsToShow)
        : null;
    final summaryLines = showUnifiedSummary && isMultiMode
        ? sessionsToShow
              .map(_notificationTitleForSession)
              .toList(growable: false)
        : const <String>[];

    final payload = sessionsToShow
        .map((session) {
          final title = _notificationTitleForSession(session);
          final subtitle = _notificationSubtitleForSession(session);
          final track = trackByPath(session.currentTrackPath);
          final artPath = coverPathForTrack(track);
          return <String, dynamic>{
            'id': session.id,
            'title': title,
            if (subtitle != null && subtitle.isNotEmpty) 'subtitle': subtitle,
            if (artPath != null && artPath.isNotEmpty) 'artPath': artPath,
            'playing': session.state.playing,
            'hasPrevious': _nextPathFor(session, forward: false) != null,
            'hasNext': _nextPathFor(session, forward: true) != null,
          };
        })
        .toList(growable: false);

    final styleVariant = isMultiMode ? 'multi_thread' : 'single_thread';
    final nextSyncKey = json.encode(<String, dynamic>{
      'mode': isMultiMode ? 'multi' : 'single',
      'styleVariant': styleVariant,
      'mainSessionId': mainSession?.id,
      'items': payload,
      'showSummary': showUnifiedSummary,
      'summaryText': summaryText,
      'summaryLines': summaryLines,
    });
    if (_unifiedNotificationSyncKey == nextSyncKey) {
      return;
    }

    if (payload.isEmpty) {
      await _clearUnifiedPlaybackNotificationsOnPlatform();
    } else {
      await _notificationService.syncUnifiedNotifications(<String, dynamic>{
        'mode': isMultiMode ? 'multi' : 'single',
        'styleVariant': styleVariant,
        'mainSessionId': mainSession?.id,
        'items': payload,
        'showSummary': showUnifiedSummary,
        'summaryText': summaryText,
        'summaryLines': summaryLines,
      });
    }
    _unifiedNotificationSyncKey = nextSyncKey;
  }

  void refreshNotificationState() {
    _syncNotificationState();
    _notifyListeners();
  }

  Future<void> selectNotificationSessionFromQueue(int index) async {
    final sessions = _notificationQueueSessions;
    if (index < 0 || index >= sessions.length) return;
    _notificationFocusSessionId = sessions[index].id;
    _syncNotificationState();
    _notifyListeners();
  }

  Future<SubtitleTrack?> subtitleTrackForPath(String trackPath) {
    return _subtitleTrackFutures.putIfAbsent(trackPath, () async {
      final subtitleTrack = await loadSubtitleTrackForAudio(trackPath);
      _subtitleTracks[trackPath] = subtitleTrack;

      var shouldRefreshNotification = false;
      for (final session in _sessions.values) {
        if (session.currentTrackPath != trackPath) continue;
        final changed = _refreshNotificationSubtitleForSession(
          session,
          syncNotification: false,
        );
        if (changed && _notificationFocusedSession?.id == session.id) {
          shouldRefreshNotification = true;
        }
      }

      if (shouldRefreshNotification) {
        _syncNotificationState();
        _notifyListeners();
      }
      return subtitleTrack;
    });
  }

  String? subtitleTextForTrackAt(
    String trackPath,
    Duration position, {
    SubtitleTrack? subtitleTrack,
  }) {
    final resolvedTrack = subtitleTrack;
    final cue = resolvedTrack?.cueAt(position);
    if (cue == null) return null;
    final text = cue.text.trim();
    return text.isEmpty ? null : text;
  }

  String? _notificationSubtitleForSession(PlaybackSession session) {
    _ensureSubtitleTrackLoaded(session.currentTrackPath);
    if (_notificationSubtitleTrackPaths[session.id] !=
            session.currentTrackPath ||
        !_notificationSubtitleTexts.containsKey(session.id)) {
      _refreshNotificationSubtitleForSession(session, syncNotification: false);
    }
    return _notificationSubtitleTexts[session.id];
  }

  bool get _shouldUseUnifiedPlaybackNotifications =>
      _multiThreadPlaybackEnabled;

  Duration get _notificationRefreshInterval =>
      _shouldUseUnifiedPlaybackNotifications
      ? AudioProvider._multiSessionNotificationRefreshInterval
      : AudioProvider._notificationProgressRefreshInterval;

  void _ensureSubtitleTrackLoaded(String trackPath) {
    if (_subtitleTracks.containsKey(trackPath) ||
        _subtitleTrackFutures.containsKey(trackPath)) {
      return;
    }
    unawaited(subtitleTrackForPath(trackPath));
  }

  bool _refreshNotificationSubtitleForSession(
    PlaybackSession session, {
    Duration? position,
    bool syncNotification = true,
  }) {
    final trackPath = session.currentTrackPath;
    _ensureSubtitleTrackLoaded(trackPath);
    final nextText = subtitleTextForTrackAt(
      trackPath,
      position ?? session.position,
      subtitleTrack: _subtitleTracks[trackPath],
    );
    final previousText = _notificationSubtitleTexts[session.id];
    final previousTrackPath = _notificationSubtitleTrackPaths[session.id];
    if (previousTrackPath == trackPath && previousText == nextText) {
      return false;
    }

    _notificationSubtitleTexts[session.id] = nextText;
    _notificationSubtitleTrackPaths[session.id] = trackPath;

    if (syncNotification && _notificationFocusedSession?.id == session.id) {
      _syncNotificationState();
    }
    return true;
  }

  void _clearNotificationSubtitleForSession(String sessionId) {
    _notificationSubtitleTexts.remove(sessionId);
    _notificationSubtitleTrackPaths.remove(sessionId);
  }
}
