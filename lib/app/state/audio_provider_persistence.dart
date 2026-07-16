part of 'audio_provider.dart';

void _logAudioProviderPersistenceFailure(Object error, StackTrace stackTrace) {
  AppLogService.error(
    'audio_provider_persistence_failed',
    error: error,
    stackTrace: stackTrace,
  );
}

extension AudioProviderPersistence on AudioProvider {
  Future<void> _beforePersistenceReset() async {
    _isReloadingPersistedState = true;
    _isInitialized = false;
    _settingsInitialized = false;
    _libraryInitialized = false;
    _playbackInitialized = false;
    _playbackFacade.cancelScheduledPersistence();
    _scanProgressNotifyTimer?.cancel();
    _scanProgressNotifyTimer = null;
    _uiWarmupCoordinator.enterBackground();
    _notificationProgressRefreshTimer?.cancel();
    _notificationProgressRefreshTimer = null;
    _unifiedNotificationSyncTimer?.cancel();
    _unifiedNotificationSyncTimer = null;
    _notificationActionRefreshTimer?.cancel();
    _notificationStateService.notificationActionRefreshTimer = null;
    _notificationActionGuardTimeout?.cancel();
    _notificationStateService.notificationActionGuardTimeout = null;
  }

  Future<void> _afterPersistenceReset() async {
    _notificationFocusSessionId = null;
    _unifiedNotificationSyncKey = null;
    _unifiedNotificationSyncInFlight = false;
    _unifiedNotificationSyncPending = false;
    _queuedNotificationRefreshSessionId = null;
    _notificationsDismissedWhilePaused = false;
    _notificationStateService.notificationActionRefreshPending = false;
    _keepAliveSyncDeferred = false;
    _subtitleService.clear();
    _notificationSubtitleTexts.clear();
    _notificationSubtitleTrackPaths.clear();
    _clearResolvedCoverPaths();
    try {
      await _clearUnifiedPlaybackNotificationsOnPlatform();
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  Future<void> _onPersistedSettingsLoaded() async {
    if (_isDisposed) return;
    applyCoverImageCachePolicy(_settingsRepository.coverImageResolution);
    _settingsInitialized = true;
    _syncSettingsStateSlice();
    _notifyPresentationListeners();
  }

  Future<void> _onPersistedLibraryLoaded() async {
    if (_isDisposed) return;
    _libraryInitialized = true;
    _syncLibraryStateSlice(preserveSliceInitialized: true);
    if (!_notificationsEnabled) {
      await _nativePlaybackRepository.setForegroundEnabled(false);
    }
    _notifyListeners();
  }

  Future<void> _onPersistedPlaybackLoaded() async {
    if (_isDisposed) return;
    if (!_multiThreadPlaybackEnabled) {
      await AppLogService.measureAsync(
        'audio_provider_enforce_single_thread_playback',
        _enforceSingleThreadPlayback,
      );
    }
    await AppLogService.measureAsync(
      'audio_provider_load_timer_runtime',
      _timerFacade.loadRuntimeFromSystem,
    );
    if (_isDisposed) return;
    _syncNotificationState(immediateUnifiedSync: true);
  }

  Future<void> _onPersistedLoadCompleted() async {
    if (_isDisposed) return;
    if (_isReloadingPersistedState) {
      _uiWarmupCoordinator.resumeForeground();
      _clearResolvedCoverPaths();
      _uiWarmupCoordinator.schedule(currentPageIndex: 0, immediate: true);
      _isReloadingPersistedState = false;
    } else {
      _uiWarmupCoordinator.schedule(currentPageIndex: 0);
    }
    _syncKeepCpuAwake();
    await _ensureLibraryCardSnapshot(notifyOnCommit: false);
    _settingsInitialized = true;
    _libraryInitialized = true;
    _playbackInitialized = true;
    _isInitialized = true;
    _notifyListeners();
    _schedulePostStartupLibraryMaintenance();
  }

  void _schedulePostStartupLibraryMaintenance() {
    if (_postStartupLibraryMaintenance != null) return;
    final retainedPaths = _library
        .map((track) => track.path)
        .toList(growable: false);
    late final Future<void> task;
    task = _waitForContinuousUiIdle(const Duration(seconds: 3))
        .then((idleReached) async {
          if (!idleReached) return;
          await AppLogService.measureAsync(
            'audio_provider_post_startup_library_maintenance',
            () async {
              await AppCacheService.cleanupOrphanedPersistentImports(
                retainedPaths,
              );
              await _ensureLibraryEntriesForLoadedTracks();
            },
            details: <String, Object?>{'tracks': retainedPaths.length},
          );
        })
        .whenComplete(() {
          if (identical(_postStartupLibraryMaintenance, task)) {
            _postStartupLibraryMaintenance = null;
          }
        });
    _postStartupLibraryMaintenance = task;
  }

  Future<bool> _waitForContinuousUiIdle(Duration quietWindow) async {
    DateTime? idleSince;
    while (!_isDisposed) {
      if (UiInteractionCoordinator.instance.isInteracting) {
        idleSince = null;
      } else {
        idleSince ??= DateTime.now();
        if (DateTime.now().difference(idleSince) >= quietWindow) {
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    return false;
  }

  Future<void> _ensureLibraryEntriesForLoadedTracks() async {
    try {
      final knownLibraries = <String>{..._watchedLibraries, ..._watchedFolders};
      if (knownLibraries.isEmpty || _library.isEmpty) return;
      final entriesToPersist = <LibraryEntry>[];
      for (final libraryPath in knownLibraries) {
        if (_libraryService.hasLibraryEntriesForLibrary(libraryPath)) {
          continue;
        }
        final tracks = _library
            .where(
              (track) =>
                  PathMatcher.isWithinOrEqual(track.path, libraryPath) ||
                  PathMatcher.isWithinOrEqual(track.groupKey, libraryPath),
            )
            .toList(growable: false);
        if (tracks.isEmpty) continue;
        entriesToPersist.addAll(
          _libraryService.buildLibraryEntries(libraryPath, tracks),
        );
      }
      if (entriesToPersist.isEmpty) return;
      _libraryService.replaceLibraryEntries(entriesToPersist);
      await _audioDatabaseRepository.upsertLibraryEntries(entriesToPersist);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    if (_notificationsEnabled == enabled) return;
    _notificationsEnabled = enabled;
    _unifiedNotificationSyncKey = null;
    _notifySettingsChanged();
    await _notificationService.setEnabled(enabled);
    // setForegroundEnabled drives the native notification preference. During
    // active playback, Android still keeps a minimal foreground notification.
    // When enabling, setForegroundEnabled(true) is already called inside
    // _notificationService.setEnabled(true), so we only need the disable path.
    if (!enabled) {
      await _nativePlaybackRepository.setForegroundEnabled(false);
    }
    _syncKeepCpuAwake();
    _syncNotificationState(immediateUnifiedSync: true);
    _notifySettingsChanged();
    unawaited(_settingsRepository.persist());
  }

  Future<void> setCardPositionsLocked(bool locked) async {
    await _settingsRepository.setCardPositionsLocked(locked);
    _notifySettingsChanged();
  }
}
