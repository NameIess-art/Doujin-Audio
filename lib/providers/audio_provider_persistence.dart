part of 'audio_provider.dart';

void _logAudioProviderPersistenceFailure(Object error, StackTrace stackTrace) {
  AppLogService.error(
    'audio_provider_persistence_failed',
    error: error,
    stackTrace: stackTrace,
  );
}

extension AudioProviderPersistence on AudioProvider {
  Future<void> reloadPersistedStateAfterBackupRestore() async {
    if (_isDisposed) return;
    await _resetRuntimeStateForPersistenceReload();
    await _loadData();
    _clearResolvedCoverPaths();
    scheduleUiWarmup(currentPageIndex: 0, immediate: true);
    _notifyListeners();
  }

  Future<void> _resetRuntimeStateForPersistenceReload() async {
    _isInitialized = false;
    _cachedPrefs = null;

    _saveSessionStateTimer?.cancel();
    _saveSessionStateTimer = null;
    _saveSessionOrderTimer?.cancel();
    _saveSessionOrderTimer = null;
    _scanProgressNotifyTimer?.cancel();
    _scanProgressNotifyTimer = null;
    _deferredWarmupTimer?.cancel();
    _deferredWarmupTimer = null;
    _notificationProgressRefreshTimer?.cancel();
    _notificationProgressRefreshTimer = null;
    _unifiedNotificationSyncTimer?.cancel();
    _unifiedNotificationSyncTimer = null;
    _notificationActionRefreshTimer?.cancel();
    _notificationStateService.notificationActionRefreshTimer = null;
    _notificationActionGuardTimeout?.cancel();
    _notificationStateService.notificationActionGuardTimeout = null;

    _countdownTimer?.cancel();
    _countdownTimer = null;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;

    final removedSessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    _sessionOrder.clear();
    _markActiveSessionsDirty();
    for (final session in removedSessions) {
      session.isPlaybackStarting = false;
      session.dispose();
    }
    try {
      await _nativePlaybackRepository.clearAll();
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }

    _deferredVolumeReloadSessionIds.clear();
    _retargetedPathAliases.clear();
    _timeSegmentLoopsBySessionId.clear();
    _timeSegmentLoopBoundSessionIds.clear();
    _timeSegmentLoopSeekPendingSessionIds.clear();

    _library.clear();
    _libraryByPath.clear();
    _libraryIndexByPath.clear();
    _tracksByGroup.clear();
    _sortedLibraryTracks = const <MusicTrack>[];
    _sortedLibraryTrackPaths = const <String>[];
    _groupOrder.clear();
    _groupOrderSet.clear();
    _libraryNodeOrder.clear();
    _watchedFolders.clear();
    _watchedLibraries.clear();
    _excludedLibraryFolders.clear();
    _excludedLibraryTracks.clear();
    _libraryService.libraryEntriesByLibrary.clear();
    _isScanning = false;
    _isBackgroundScanning = false;
    _scanCurrentFolder = '';
    _scanFoundCount = 0;
    _scanDuplicateCount = 0;
    _scanFailureCount = 0;
    _librarySnapshotCacheService.clear();
    _libraryBatchDepth = 0;
    _libraryBatchChanged = false;
    _libraryBatchChangedGroupOrder = false;
    _libraryBatchPersistTracks.clear();
    _libraryBatchPersistEntriesByKey.clear();
    _markLibraryStructureDirty();

    _resetTimerRuntimeState();
    _timerDraftMode = TimerMode.manual;
    _timerDraftDuration = const Duration(minutes: 30);
    _autoResumeEnabled = false;
    _autoResumeHour = 7;
    _autoResumeMinute = 0;

    _converterFormat = 'mp3';
    _converterBitrate = '320k';
    _multiThreadPlaybackEnabled = false;
    _notificationsEnabled = true;
    _showPlaybackCard = true;
    _startupPage = StartupPage.library;
    _bottomNavigationStyle = BottomNavigationStyle.capsule;
    _autoPlayAddedSessions = true;
    _autoCheckUpdates = false;
    _settingsRepository.recordPlaybackProgress = true;
    _settingsRepository.asmrPlaybackCacheEnabled = false;
    _settingsRepository.blurPlayerBackgroundEnabled = true;
    _settingsRepository.uiBlurEffectEnabled = true;
    _settingsRepository.coverImageResolution = CoverImageResolution.balanced;
    _settingsRepository.asmrDownloadDestinationRoot = null;
    _settingsRepository.asmrDownloadConflictPolicy =
        AsmrDownloadConflictPolicy.overwrite;
    _dlsiteMetadataLanguage = AppLanguage.ja;
    _settingsRepository.cardInfoFields = CardInfoField.defaults;
    _settingsRepository.cardPositionsLocked = false;
    _settingsRepository.customEqPresets = const <EqPreset>[];
    _maxCacheBytes = AppCacheService.defaultMaxCacheBytes;

    _notificationFocusSessionId = null;
    _unifiedNotificationSyncKey = null;
    _unifiedNotificationSyncInFlight = false;
    _unifiedNotificationSyncPending = false;
    _queuedNotificationRefreshSessionId = null;
    _notificationsDismissedWhilePaused = false;
    _notificationStateService.notificationActionRefreshPending = false;
    _keepAliveSyncDeferred = false;
    _subtitleTrackFutures.clear();
    _subtitleTracks.clear();
    _subtitleTrackResultFutures.clear();
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

  Future<void> _loadLibrary() async {
    try {
      final db = _audioDatabaseRepository;
      var tracks = await db.loadAllTracks();
      if (tracks.isNotEmpty) {
        _library.addAll(tracks);
        _rebuildLibraryIndexes();
        _notifyListeners();
        // Clean up legacy SharedPreferences blob after successful migration.
        final prefs = await _prefs;
        await prefs.remove(_kLibraryKey);
        return;
      }
      // One-shot migration from legacy SharedPreferences JSON.
      final prefs = await _prefs;
      final raw = prefs.getString(_kLibraryKey);
      final migrated = AppDatabase.tryMigrateFromJson(raw);
      if (migrated != null && migrated.isNotEmpty) {
        await db.saveAllTracks(migrated);
        await prefs.remove(_kLibraryKey);
        _library.addAll(migrated);
        _rebuildLibraryIndexes();
        _notifyListeners();
      }
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _loadGroupOrder() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kGroupOrderKey);
      if (raw == null || raw.isEmpty) return;
      final list = (json.decode(raw) as List<dynamic>).cast<String>();
      _groupOrder
        ..clear()
        ..addAll(list);
      _groupOrderSet
        ..clear()
        ..addAll(list);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveGroupOrder() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_kGroupOrderKey, json.encode(_groupOrder));
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _loadLibraryNodeOrder() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kLibraryNodeOrderKey);
      if (raw == null || raw.isEmpty) return;
      final list = (json.decode(raw) as List<dynamic>).cast<String>();
      _libraryNodeOrder
        ..clear()
        ..addAll(list);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveLibraryNodeOrder() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(
        _kLibraryNodeOrderKey,
        json.encode(_libraryNodeOrder),
      );
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _loadSessionOrder() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kSessionOrderKey);
      if (raw == null || raw.isEmpty) return;
      final list = (json.decode(raw) as List<dynamic>).cast<String>();
      _sessionOrder
        ..clear()
        ..addAll(list);
      _markActiveSessionsDirty();
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveSessionOrder() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_kSessionOrderKey, json.encode(_sessionOrder));
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  void _scheduleSaveSessionOrder({
    Duration delay = const Duration(milliseconds: 180),
  }) {
    _saveSessionOrderTimer?.cancel();
    _saveSessionOrderTimer = Timer(delay, () {
      _saveSessionOrderTimer = null;
      unawaited(_saveSessionOrder());
    });
  }

  Future<void> _loadData() async {
    try {
      // Phase 1: Load library (foundation — everything else depends on it).
      await _loadLibrary();

      // Phase 2: Load all independent SharedPreferences settings in parallel.
      await Future.wait<void>([
        _loadGroupOrder(),
        _loadWatchedFolders(),
        _loadWatchedLibraries(),
        _loadLibraryExclusions(),
        _loadLibraryNodeOrder(),
        _loadSessionOrder(),
        _loadPlaybackSettings(),
        _loadConverterSettings(),
        _loadTimerSettings(),
      ]);

      await _loadLibraryEntries();
      await _ensureLibraryEntriesForLoadedTracks();

      // Phase 3: In-memory syncs that depend on library + loaded order data.
      _syncGroupOrderFromLibrary();
      _syncLibraryNodeOrder(persist: false);
      _markLibraryStructureDirty();

      // Phase 4: Notification state + first UI update.
      if (!_notificationsEnabled) {
        await _nativePlaybackRepository.setForegroundEnabled(false);
      }
      _notifyListeners();

      // Phase 5: Load sessions (heavy — native calls per session).
      await _loadSessions();

      // Phase 6: Post-session operations (sequenced to avoid timer/session races).
      if (!_multiThreadPlaybackEnabled) {
        await _enforceSingleThreadPlayback();
      }
      await loadTimerRuntimeFromSystem();
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    } finally {
      // Phase 7: Deferred warmup, keep-alive sync, final UI update.
      scheduleUiWarmup(currentPageIndex: 0);
      _syncKeepCpuAwake();
      _isInitialized = true;
      _notifyListeners();
    }
  }

  Future<void> _loadPlaybackSettings() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kPlaybackSettingsKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      _multiThreadPlaybackEnabled =
          map['multiThreadPlaybackEnabled'] as bool? ?? false;
      _notificationsEnabled = map['notificationsEnabled'] as bool? ?? true;
      _showPlaybackCard = map['showPlaybackCard'] as bool? ?? true;
      _startupPage = _decodeStartupPage(map['startupPage']);
      _bottomNavigationStyle = _decodeBottomNavigationStyle(
        map['bottomNavigationStyle'],
      );
      _autoPlayAddedSessions = map['autoPlayAddedSessions'] as bool? ?? true;
      _autoCheckUpdates = map['autoCheckUpdates'] as bool? ?? false;
      _settingsRepository.recordPlaybackProgress =
          map['recordPlaybackProgress'] as bool? ?? true;
      _settingsRepository.asmrPlaybackCacheEnabled =
          map['asmrPlaybackCacheEnabled'] as bool? ?? false;
      _settingsRepository.blurPlayerBackgroundEnabled =
          map['blurPlayerBackgroundEnabled'] as bool? ?? true;
      _settingsRepository.uiBlurEffectEnabled =
          map['uiBlurEffectEnabled'] as bool? ?? true;
      _settingsRepository.coverImageResolution = _decodeCoverImageResolution(
        map['coverImageResolution'],
      );
      _settingsRepository.asmrDownloadDestinationRoot =
          _decodeOptionalTrimmedString(map['asmrDownloadDestinationRoot']) ??
          _decodeOptionalTrimmedString(
            await AppPreferences.getString(
              AsmrDownloadManager.legacyDefaultDestinationKey,
            ),
          );
      if (_settingsRepository.asmrDownloadDestinationRoot != null) {
        await AppPreferences.remove(
          AsmrDownloadManager.legacyDefaultDestinationKey,
        );
      }
      _settingsRepository.asmrDownloadConflictPolicy =
          _decodeAsmrDownloadConflictPolicy(map['asmrDownloadConflictPolicy']);
      _dlsiteMetadataLanguage = _decodeDlsiteMetadataLanguage(
        map['dlsiteMetadataLanguage'],
      );
      _settingsRepository.cardInfoFields = CardInfoField.decode(
        map['cardInfoFields'],
      );
      _settingsRepository.cardPositionsLocked =
          map['cardPositionsLocked'] as bool? ?? false;
      _settingsRepository.customEqPresets = _decodeCustomEqPresets(
        map['customEqPresets'],
      );
      _maxCacheBytes =
          (map['maxCacheBytes'] as num?)?.toInt() ??
          AppCacheService.defaultMaxCacheBytes;
      unawaited(AppCacheService.setMaxCacheBytes(_maxCacheBytes));
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _savePlaybackSettings() async {
    try {
      final prefs = await _prefs;
      final encoded = json.encode({
        'multiThreadPlaybackEnabled': _multiThreadPlaybackEnabled,
        'notificationsEnabled': _notificationsEnabled,
        'showPlaybackCard': _showPlaybackCard,
        'startupPage': _startupPage.name,
        'bottomNavigationStyle': _bottomNavigationStyle.name,
        'autoPlayAddedSessions': _autoPlayAddedSessions,
        'autoCheckUpdates': _autoCheckUpdates,
        'recordPlaybackProgress': _settingsRepository.recordPlaybackProgress,
        'asmrPlaybackCacheEnabled':
            _settingsRepository.asmrPlaybackCacheEnabled,
        'blurPlayerBackgroundEnabled':
            _settingsRepository.blurPlayerBackgroundEnabled,
        'uiBlurEffectEnabled': _settingsRepository.uiBlurEffectEnabled,
        'coverImageResolution': _settingsRepository.coverImageResolution.name,
        'asmrDownloadDestinationRoot':
            _settingsRepository.asmrDownloadDestinationRoot,
        'asmrDownloadConflictPolicy':
            _settingsRepository.asmrDownloadConflictPolicy.name,
        'dlsiteMetadataLanguage': _dlsiteMetadataLanguage.name,
        'cardInfoFields': _settingsRepository.cardInfoFields
            .map((field) => field.name)
            .toList(growable: false),
        'cardPositionsLocked': _settingsRepository.cardPositionsLocked,
        'customEqPresets': _settingsRepository.customEqPresets
            .map((preset) => preset.toJson())
            .toList(growable: false),
        'maxCacheBytes': _maxCacheBytes,
      });
      await prefs.setString(_kPlaybackSettingsKey, encoded);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  AppLanguage _decodeDlsiteMetadataLanguage(Object? value) {
    if (value is! String) return AppLanguage.ja;
    for (final language in AppLanguage.values) {
      if (language.name == value) return language;
    }
    return AppLanguage.ja;
  }

  CoverImageResolution _decodeCoverImageResolution(Object? value) {
    if (value is! String) return CoverImageResolution.balanced;
    for (final resolution in CoverImageResolution.values) {
      if (resolution.name == value) return resolution;
    }
    return CoverImageResolution.balanced;
  }

  AsmrDownloadConflictPolicy _decodeAsmrDownloadConflictPolicy(Object? value) {
    if (value is! String) return AsmrDownloadConflictPolicy.overwrite;
    for (final policy in AsmrDownloadConflictPolicy.values) {
      if (policy.name == value) return policy;
    }
    return AsmrDownloadConflictPolicy.overwrite;
  }

  String? _decodeOptionalTrimmedString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  StartupPage _decodeStartupPage(Object? value) {
    if (value is! String) return StartupPage.library;
    return StartupPage.values.firstWhere(
      (page) => page.name == value,
      orElse: () => StartupPage.library,
    );
  }

  BottomNavigationStyle _decodeBottomNavigationStyle(Object? value) {
    if (value is! String) return BottomNavigationStyle.capsule;
    return BottomNavigationStyle.values.firstWhere(
      (style) => style.name == value,
      orElse: () => BottomNavigationStyle.capsule,
    );
  }

  List<EqPreset> _decodeCustomEqPresets(Object? value) {
    if (value is! List) return const <EqPreset>[];
    return value
        .map(EqPreset.fromJson)
        .where((preset) => preset.id.isNotEmpty && preset.labelKey.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _loadWatchedFolders() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kWatchedFoldersKey);
      if (raw == null || raw.isEmpty) return;
      final list = (json.decode(raw) as List<dynamic>).cast<String>();
      _watchedFolders
        ..clear()
        ..addAll(list);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveWatchedFolders() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_kWatchedFoldersKey, json.encode(_watchedFolders));
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _loadWatchedLibraries() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kWatchedLibrariesKey);
      if (raw == null || raw.isEmpty) return;
      final list = (json.decode(raw) as List<dynamic>).cast<String>();
      _watchedLibraries
        ..clear()
        ..addAll(list);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveWatchedLibraries() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(
        _kWatchedLibrariesKey,
        json.encode(_watchedLibraries),
      );
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _loadLibraryExclusions() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kLibraryExclusionsKey);
      if (raw == null || raw.isEmpty) return;
      final data = json.decode(raw) as Map<String, dynamic>;
      _decodeExclusionMap(data['folders'], _excludedLibraryFolders);
      _decodeExclusionMap(data['tracks'], _excludedLibraryTracks);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveLibraryExclusions() async {
    try {
      final prefs = await _prefs;
      final encoded = json.encode({
        'folders': _encodeExclusionMap(_excludedLibraryFolders),
        'tracks': _encodeExclusionMap(_excludedLibraryTracks),
      });
      await prefs.setString(_kLibraryExclusionsKey, encoded);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _loadLibraryEntries() async {
    try {
      final entries = await _audioDatabaseRepository.loadAllLibraryEntries();
      if (entries.isEmpty) return;
      _libraryService.replaceLibraryEntries(entries);
      // Rebuild the in-memory exclusion maps from the database so that
      // exclusions survive app restarts even if SharedPreferences is cleared.
      // SQLite is the durable source of truth; this call overwrites whatever
      // _loadLibraryExclusions() loaded from SharedPreferences.
      _libraryService.rebuildExclusionsFromEntries(entries);
      // Remove any tracks that are marked excluded in the database from the
      // in-memory library.  _loadLibrary() loads all tracks unconditionally,
      // so we must prune the excluded ones here.  _removeTracksWhere will
      // call _rebuildLibraryIndexes again, but only if there are exclusions.
      _applyExclusionsToLibrary();
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
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
        entriesToPersist.addAll(_buildLibraryEntries(libraryPath, tracks));
      }
      if (entriesToPersist.isEmpty) return;
      _libraryService.replaceLibraryEntries(entriesToPersist);
      await _audioDatabaseRepository.upsertLibraryEntries(entriesToPersist);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  void _decodeExclusionMap(Object? raw, Map<String, Set<String>> target) {
    target.clear();
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final libraryPath = entry.key?.toString();
      final values = entry.value;
      if (libraryPath == null || values is! List) continue;
      target[path.normalize(libraryPath)] = values
          .map((value) => path.normalize(value.toString()))
          .where((value) => value.isNotEmpty)
          .toSet();
    }
  }

  Map<String, List<String>> _encodeExclusionMap(Map<String, Set<String>> map) {
    return map.map(
      (libraryPath, values) =>
          MapEntry(libraryPath, values.toList(growable: false)..sort()),
    );
  }

  Future<void> _loadConverterSettings() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kConverterSettingsKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;

      final savedFormat = map['format'] as String?;
      final savedBitrate = map['bitrate'] as String?;

      if (savedFormat != null &&
          AudioProvider.converterFormats.contains(savedFormat)) {
        _converterFormat = savedFormat;
      }
      if (savedBitrate != null &&
          AudioProvider.converterBitrates.contains(savedBitrate)) {
        _converterBitrate = savedBitrate;
      }
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  Future<void> _saveConverterSettings() async {
    try {
      final prefs = await _prefs;
      final encoded = json.encode({
        'format': _converterFormat,
        'bitrate': _converterBitrate,
      });
      await prefs.setString(_kConverterSettingsKey, encoded);
    } catch (error, stackTrace) {
      _logAudioProviderPersistenceFailure(error, stackTrace);
    }
  }

  void setConverterSettings({String? format, String? bitrate}) {
    var changed = false;
    if (format != null &&
        AudioProvider.converterFormats.contains(format) &&
        format != _converterFormat) {
      _converterFormat = format;
      changed = true;
    }
    if (bitrate != null &&
        AudioProvider.converterBitrates.contains(bitrate) &&
        bitrate != _converterBitrate) {
      _converterBitrate = bitrate;
      changed = true;
    }
    if (!changed) return;
    _notifySettingsChanged();
    unawaited(_saveConverterSettings());
  }

  Future<void> setMultiThreadPlaybackEnabled(bool enabled) async {
    if (_multiThreadPlaybackEnabled == enabled) return;
    _multiThreadPlaybackEnabled = enabled;
    if (!enabled) {
      await _resetSessionsForSingleThreadMode();
    }
    _unifiedNotificationSyncKey = null;
    await _clearUnifiedPlaybackNotificationsOnPlatform();
    _syncKeepCpuAwake();
    _syncNotificationState(immediateUnifiedSync: true);
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
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
    unawaited(_savePlaybackSettings());
  }

  Future<void> setShowPlaybackCard(bool show) async {
    if (_showPlaybackCard == show) return;
    _showPlaybackCard = show;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setStartupPage(StartupPage page) async {
    if (_startupPage == page) return;
    _startupPage = page;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setBottomNavigationStyle(BottomNavigationStyle style) async {
    if (_bottomNavigationStyle == style) return;
    _bottomNavigationStyle = style;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setBlurPlayerBackgroundEnabled(bool enabled) async {
    if (_settingsRepository.blurPlayerBackgroundEnabled == enabled) return;
    _settingsRepository.blurPlayerBackgroundEnabled = enabled;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setUiBlurEffectEnabled(bool enabled) async {
    if (_settingsRepository.uiBlurEffectEnabled == enabled) return;
    _settingsRepository.uiBlurEffectEnabled = enabled;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setCoverImageResolution(CoverImageResolution resolution) async {
    if (_settingsRepository.coverImageResolution == resolution) return;
    _settingsRepository.coverImageResolution = resolution;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setAsmrDownloadDestinationRoot(String? destinationRoot) async {
    final normalized = destinationRoot?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_settingsRepository.asmrDownloadDestinationRoot == next) return;
    _settingsRepository.asmrDownloadDestinationRoot = next;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setAsmrDownloadConflictPolicy(
    AsmrDownloadConflictPolicy policy,
  ) async {
    if (_settingsRepository.asmrDownloadConflictPolicy == policy) return;
    _settingsRepository.asmrDownloadConflictPolicy = policy;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setAutoPlayAddedSessions(bool enabled) async {
    if (_autoPlayAddedSessions == enabled) return;
    _autoPlayAddedSessions = enabled;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setAutoCheckUpdates(bool enabled) async {
    if (_autoCheckUpdates == enabled) return;
    _autoCheckUpdates = enabled;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setRecordPlaybackProgress(bool enabled) async {
    if (_settingsRepository.recordPlaybackProgress == enabled) return;
    _settingsRepository.recordPlaybackProgress = enabled;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setAsmrPlaybackCacheEnabled(bool enabled) async {
    if (_settingsRepository.asmrPlaybackCacheEnabled == enabled) return;
    _settingsRepository.asmrPlaybackCacheEnabled = enabled;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setDlsiteMetadataLanguage(AppLanguage language) async {
    if (_dlsiteMetadataLanguage == language) return;
    _dlsiteMetadataLanguage = language;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setCardInfoFields(Iterable<CardInfoField> fields) async {
    final normalized = CardInfoField.normalize(fields);
    if (listEquals(_settingsRepository.cardInfoFields, normalized)) return;
    _settingsRepository.cardInfoFields = normalized;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setCardPositionsLocked(bool locked) async {
    if (_settingsRepository.cardPositionsLocked == locked) return;
    _settingsRepository.cardPositionsLocked = locked;
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> saveCustomEqPreset(String name, PlaybackSession session) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;
    final preset = EqPreset(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      labelKey: trimmedName,
      bandLevels: Map<int, double>.unmodifiable(
        session.audioEffects.eqBandLevels,
      ),
    );
    _settingsRepository.customEqPresets = List<EqPreset>.unmodifiable([
      ..._settingsRepository.customEqPresets,
      preset,
    ]);
    _notifySettingsChanged();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setMaxCacheBytes(int bytes) async {
    final normalized = bytes <= 0
        ? AppCacheService.defaultMaxCacheBytes
        : bytes;
    if (_maxCacheBytes == normalized) return;
    _maxCacheBytes = normalized;
    _notifySettingsChanged();
    await AppCacheService.setMaxCacheBytes(normalized);
    unawaited(_savePlaybackSettings());
  }
}
