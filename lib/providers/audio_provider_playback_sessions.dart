part of 'audio_provider.dart';

extension AudioProviderPlaybackSessions on AudioProvider {
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
        await _prepareAndPlay(session, nextPath: nextPath, autoPlay: autoPlay);
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
      if (!_sessions.containsKey(session.id) ||
          session.loadGeneration != generation) {
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
        final title =
            track?.displayName ?? path.basenameWithoutExtension(nextPath);
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
            volume: session.volume,
            repeatOne: session.loopMode == SessionLoopMode.single,
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
      if (_sessions.containsKey(session.id) &&
          session.loadGeneration == generation) {
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
}
