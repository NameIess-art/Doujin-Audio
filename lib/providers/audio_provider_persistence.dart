part of 'audio_provider.dart';

extension AudioProviderPersistence on AudioProvider {
  Future<void> _loadLibrary() async {
    try {
      final db = AppDatabase.instance;
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveGroupOrder() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_kGroupOrderKey, json.encode(_groupOrder));
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveLibraryNodeOrder() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(
        _kLibraryNodeOrderKey,
        json.encode(_libraryNodeOrder),
      );
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveSessionOrder() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_kSessionOrderKey, json.encode(_sessionOrder));
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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

    // Phase 3: In-memory syncs that depend on library + loaded order data.
    _syncGroupOrderFromLibrary();
    _syncLibraryNodeOrder(persist: false);
    _markLibraryStructureDirty();

    // Phase 4: Notification state + first UI update.
    if (!_notificationsEnabled) {
      await NativePlaybackBridge.instance.setForegroundEnabled(false);
    }
    _notifyListeners();

    // Phase 5: Load sessions (heavy — native calls per session).
    await _loadSessions();

    // Phase 6: Post-session operations (sequenced to avoid timer/session races).
    if (!_multiThreadPlaybackEnabled) {
      await _enforceSingleThreadPlayback();
    }
    await _loadTimerRuntime();

    // Phase 7: Deferred warmup, keep-alive sync, final UI update.
    _scheduleLibraryAndSessionCacheWarmup();
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  void _scheduleLibraryAndSessionCacheWarmup() {
    _cacheWarmupTimer?.cancel();
    _cacheWarmupTimer = Timer(const Duration(seconds: 2), () {
      _cacheWarmupTimer = null;
      if (_isScanning) return;
      _warmLibraryAndSessionCaches();
    });
  }

  void _warmLibraryAndSessionCaches() {
    final tree = libraryTree;
    var warmedFolders = 0;
    for (final node in tree) {
      if (node is! FolderNode || node.path.startsWith('content://')) continue;
      unawaited(coverPathFutureForFolder(node.path));
      warmedFolders++;
      if (warmedFolders >= 6) break;
    }

    var warmedSessions = 0;
    for (final session in activeSessions) {
      final trackPath = session.currentTrackPath;
      _ensureSubtitleTrackLoaded(trackPath);
      final track = trackByPath(trackPath);
      unawaited(coverPathFutureForTrack(track));
      warmedSessions++;
      if (warmedSessions >= 4) break;
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
      _autoPlayAddedSessions = map['autoPlayAddedSessions'] as bool? ?? true;
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _savePlaybackSettings() async {
    try {
      final prefs = await _prefs;
      final encoded = json.encode({
        'multiThreadPlaybackEnabled': _multiThreadPlaybackEnabled,
        'notificationsEnabled': _notificationsEnabled,
        'showPlaybackCard': _showPlaybackCard,
        'autoPlayAddedSessions': _autoPlayAddedSessions,
      });
      await prefs.setString(_kPlaybackSettingsKey, encoded);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveWatchedFolders() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_kWatchedFoldersKey, json.encode(_watchedFolders));
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveWatchedLibraries() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(
        _kWatchedLibrariesKey,
        json.encode(_watchedLibraries),
      );
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
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
    _notifyListeners();
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
    _notifyListeners();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    if (_notificationsEnabled == enabled) return;
    _notificationsEnabled = enabled;
    _unifiedNotificationSyncKey = null;
    _notifyListeners();
    await _notificationService.setEnabled(enabled);
    if (enabled) {
      await NativePlaybackBridge.instance.undismissNotifications();
    } else {
      await NativePlaybackBridge.instance.dismissNotifications();
    }
    _syncKeepCpuAwake();
    _syncNotificationState(immediateUnifiedSync: true);
    _notifyListeners();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setShowPlaybackCard(bool show) async {
    if (_showPlaybackCard == show) return;
    _showPlaybackCard = show;
    _notifyListeners();
    unawaited(_savePlaybackSettings());
  }

  Future<void> setAutoPlayAddedSessions(bool enabled) async {
    if (_autoPlayAddedSessions == enabled) return;
    _autoPlayAddedSessions = enabled;
    _notifyListeners();
    unawaited(_savePlaybackSettings());
  }
}
