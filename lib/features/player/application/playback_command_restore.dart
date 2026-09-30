part of 'playback_command_coordinator.dart';

extension PlaybackCommandRestore on PlaybackCommandCoordinator {
  Future<void> _restorePersistedRuntime(
    List<PlaybackSession> restoredSessions, {
    required String? focusedSessionId,
  }) async {
    try {
      final initialNativeRuntime = await _applyNativeRuntimeSnapshot(
        syncUi: false,
      );
      if (initialNativeRuntime == null) return;
      if (initialNativeRuntime.focusedSessionId == null &&
          focusedSessionId != null &&
          _sessions.containsKey(focusedSessionId)) {
        _notificationFacade.setFocusedSession(focusedSessionId);
      }
      // Missing native sessions stay as persisted definitions. Their sources,
      // queues and players are prepared only when playback is requested.
      _syncNotificationState(immediateUnifiedSync: true);
      if (_sessions.isNotEmpty) _notifyPlaybackChanged();
    } catch (error, stackTrace) {
      _logRestoreFailure(error, stackTrace);
    }
  }

  Future<void> _reconcileNativeRuntime() async {
    await _applyNativeRuntimeSnapshot(syncUi: true);
  }

  Future<NativePlaybackBundleSnapshot?> _applyNativeRuntimeSnapshot({
    required bool syncUi,
  }) async {
    final response = await _nativePlaybackRepository.snapshot();
    final bundle = response.valueOrNull;
    if (bundle == null) {
      AppLogService.warning(
        'native_playback_snapshot_failed '
        'code=${response.errorCodeOrNull} error=${response.errorOrNull}',
      );
      return null;
    }
    _playbackFacade.replaceNativeRetainedContentUris(bundle.sessions);
    for (final snapshot in bundle.sessions) {
      if (!_sessions.containsKey(snapshot.sessionId)) {
        AppLogService.warning(
          'native_playback_unmatched_session_preserved '
          'sessionId=${snapshot.sessionId}',
        );
        continue;
      }
      // Idle native definitions may predate local paused edits. Only a live
      // playback runtime can replace the persisted definition during reconnect.
      if (!snapshot.playWhenReady && snapshot.processingState == 'idle') {
        continue;
      }
      _handleNativePlaybackSnapshot(snapshot);
    }
    final focusedSessionId = bundle.focusedSessionId;
    if (focusedSessionId != null && _sessions.containsKey(focusedSessionId)) {
      _notificationFacade.setFocusedSession(focusedSessionId);
    }
    if (syncUi) {
      _syncNotificationState(immediateUnifiedSync: true);
      if (_sessions.isNotEmpty) _notifyPlaybackChanged();
    }
    return bundle;
  }

  void _logRestoreFailure(Object error, StackTrace stackTrace) {
    AppLogService.error(
      'playback_runtime_restore_failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
