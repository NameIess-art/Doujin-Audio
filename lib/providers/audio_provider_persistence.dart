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
    await _loadLibrary();
    await _loadGroupOrder();
    await _loadWatchedFolders();
    await _loadWatchedLibraries();
    await _loadLibraryNodeOrder();
    _syncGroupOrderFromLibrary();
    _syncLibraryNodeOrder(persist: false);
    _markLibraryStructureDirty();
    await _loadSessionOrder();
    await _loadPlaybackSettings();
    await _loadConverterSettings();
    await _loadTimerSettings();
    if (!_notificationsEnabled) {
      await NativePlaybackBridge.instance.setForegroundEnabled(false);
    }
    _notifyListeners();
    await _loadSessions();
    if (!_multiThreadPlaybackEnabled) {
      await _enforceSingleThreadPlayback();
    }
    await _loadTimerRuntime();
    _syncKeepCpuAwake();
    _notifyListeners();
  }

  Future<void> _loadSessions() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kSessionsKey);
      if (raw == null || raw.isEmpty) return;
      final list = json.decode(raw) as List<dynamic>;

      final restoredIds = <String>[];
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final trackPath = item['path'] as String?;
        if (trackPath == null) continue;
        final track = trackByPath(trackPath);
        if (track == null) continue;

        final loopModeIndex =
            item['loopMode'] as int? ?? SessionLoopMode.folderSequential.index;
        final loopMode = SessionLoopMode
            .values[loopModeIndex.clamp(0, SessionLoopMode.values.length - 1)];
        final volume = (item['volume'] as num?)?.toDouble() ?? 1.0;
        final restoredPositionMs = (item['positionMs'] as num?)?.toInt() ?? 0;
        final restoredPosition = Duration(
          milliseconds: max(0, restoredPositionMs),
        );

        final restoredSessionId = item['id'] as String? ?? _nextSessionId();
        final session = PlaybackSession(
          id: restoredSessionId,
          currentTrackPath: track.path,
          loopMode: loopMode,
          nonSingleLoopMode: loopMode == SessionLoopMode.single
              ? SessionLoopMode.folderSequential
              : loopMode,
          volume: volume,
          createdAt: DateTime.now(),
          state: PlayerState(false, ProcessingState.idle),
        );
        session.lastKnownPosition = restoredPosition;
        session.lastPersistedPositionBucket = restoredPosition.inSeconds ~/ 5;
        _sessions[session.id] = session;
        _markActiveSessionsDirty();
        _bindSessionListeners(session);
        restoredIds.add(session.id);

        try {
          final uri = track.path.startsWith('content://')
              ? Uri.parse(track.path)
              : Uri.file(track.path);
          final prepareResult = await NativePlaybackBridge.instance
              .prepareSession(
                sessionId: session.id,
                uri: uri,
                title: track.displayName,
                subtitle: track.groupTitle,
                startPosition: restoredPosition,
                volume: volume,
                repeatOne: loopMode == SessionLoopMode.single,
              );
          if ((prepareResult['ok'] as bool?) != true) {
            continue;
          }
          session.loadedPath = track.path;
          _ensureSubtitleTrackLoaded(track.path);
          _refreshNotificationSubtitleForSession(
            session,
            position: restoredPosition,
            syncNotification: false,
          );
        } catch (e) {
          debugPrint('AudioProvider persistence error: $e');
        }
      }

      final validOrdered = _sessionOrder
          .where((id) => restoredIds.contains(id))
          .toList();
      for (final id in restoredIds) {
        if (!validOrdered.contains(id)) validOrdered.add(id);
      }
      _sessionOrder
        ..clear()
        ..addAll(validOrdered);
      _markActiveSessionsDirty();
      _notificationFocusSessionId = _sessionOrder.isNotEmpty
          ? _sessionOrder.first
          : restoredIds.isNotEmpty
          ? restoredIds.first
          : null;

      final snapshotResponse = await NativePlaybackBridge.instance.snapshot();
      final snapshotValue = snapshotResponse['value'];
      if (snapshotValue is List) {
        for (final raw in snapshotValue.whereType<Map<dynamic, dynamic>>()) {
          _handleNativePlaybackSnapshot(NativePlaybackSnapshot.fromMap(raw));
        }
      } else if (snapshotValue is Map) {
        _handleNativePlaybackSnapshot(
          NativePlaybackSnapshot.fromMap(snapshotValue),
        );
      }

      _syncNotificationState();
      if (_sessions.isNotEmpty) _notifyListeners();
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveSessionState() async {
    try {
      final prefs = await _prefs;
      final ordered = _sessionOrder
          .map((id) => _sessions[id])
          .whereType<PlaybackSession>()
          .toList();
      final encoded = json.encode(
        ordered
            .map(
              (s) => {
                'id': s.id,
                'path': s.currentTrackPath,
                'loopMode': s.loopMode.index,
                'volume': s.volume,
                'positionMs': max(
                  0,
                  max(
                    s.position.inMilliseconds,
                    s.lastKnownPosition.inMilliseconds,
                  ),
                ),
              },
            )
            .toList(),
      );
      await prefs.setString(_kSessionsKey, encoded);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  void _scheduleSaveSessionState({
    Duration delay = const Duration(milliseconds: 220),
  }) {
    _saveSessionStateTimer?.cancel();
    _saveSessionStateTimer = Timer(delay, () {
      _saveSessionStateTimer = null;
      unawaited(_saveSessionState());
    });
  }

  void _scheduleSessionPersistence() {
    _scheduleSaveSessionState();
    _scheduleSaveSessionOrder();
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

  Future<void> _loadTimerSettings() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kTimerSettingsKey);
      if (raw == null || raw.isEmpty) return;
      final map = json.decode(raw) as Map<String, dynamic>;
      _autoResumeEnabled = map['autoResumeEnabled'] as bool? ?? false;
      _autoResumeHour = map['autoResumeHour'] as int? ?? 7;
      _autoResumeMinute = map['autoResumeMinute'] as int? ?? 0;
      final draftModeIndex = map['timerDraftMode'] as int?;
      final draftDurationMs = map['timerDraftDurationMs'] as int?;
      if (draftModeIndex != null &&
          draftModeIndex >= 0 &&
          draftModeIndex < TimerMode.values.length) {
        _timerDraftMode = TimerMode.values[draftModeIndex];
      }
      if (draftDurationMs != null && draftDurationMs > 0) {
        _timerDraftDuration = Duration(milliseconds: draftDurationMs);
      }
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveTimerSettings() async {
    try {
      final prefs = await _prefs;
      final encoded = json.encode({
        'autoResumeEnabled': _autoResumeEnabled,
        'autoResumeHour': _autoResumeHour,
        'autoResumeMinute': _autoResumeMinute,
        'timerDraftMode': _timerDraftMode.index,
        'timerDraftDurationMs': _timerDraftDuration.inMilliseconds,
      });
      await prefs.setString(_kTimerSettingsKey, encoded);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  void setTimerDraft(TimerMode mode, Duration duration) {
    final normalizedDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    if (_timerDraftMode == mode && _timerDraftDuration == normalizedDuration) {
      return;
    }
    _timerDraftMode = mode;
    _timerDraftDuration = normalizedDuration;
    _notifyListeners();
    unawaited(_saveTimerSettings());
  }

  Future<void> _loadTimerRuntime() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_kTimerRuntimeKey);
      if (raw == null || raw.isEmpty) return;

      final map = json.decode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      final durationMs = map['timerDurationMs'] as int?;
      final timerModeIndex = map['timerMode'] as int?;
      final waitingForPlayback =
          map['timerWaitingForPlayback'] as bool? ?? false;
      final timerEndsAtMs = map['timerEndsAtMs'] as int?;
      final autoResumeAtMs = map['autoResumeAtMs'] as int?;
      final pausedPaths =
          (map['pausedByTimerPaths'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList();

      final hasPendingTrigger =
          waitingForPlayback &&
          durationMs != null &&
          durationMs > 0 &&
          timerModeIndex == TimerMode.trigger.index;
      final hasRunningCountdown =
          timerEndsAtMs != null &&
          durationMs != null &&
          timerEndsAtMs > now.millisecondsSinceEpoch;
      final hasPostTimerState =
          autoResumeAtMs != null || pausedPaths.isNotEmpty;
      if (!hasPendingTrigger && !hasRunningCountdown && !hasPostTimerState) {
        await prefs.remove(_kTimerRuntimeKey);
        return;
      }

      _pausedByTimerPaths
        ..clear()
        ..addAll(pausedPaths);
      _autoResumeAt = autoResumeAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(autoResumeAtMs);

      if (timerModeIndex != null &&
          timerModeIndex >= 0 &&
          timerModeIndex < TimerMode.values.length) {
        _timerMode = TimerMode.values[timerModeIndex];
      }
      if (durationMs != null && durationMs > 0) {
        _timerDuration = Duration(milliseconds: durationMs);
      }

      if (_timerDuration != null && waitingForPlayback) {
        _timerRemaining = _timerDuration;
        _timerWaitingForPlayback = true;
        _timerActive = false;
      }

      if (timerEndsAtMs != null && _timerDuration != null) {
        final restoredEndsAt = DateTime.fromMillisecondsSinceEpoch(
          timerEndsAtMs,
        );
        if (restoredEndsAt.isAfter(now)) {
          final generation = ++_timerGeneration;
          _timerEndsAt = restoredEndsAt;
          _timerActive = true;
          _timerWaitingForPlayback = false;
          final remaining = restoredEndsAt.difference(now);
          _timerRemaining = Duration(
            seconds: (remaining.inMilliseconds + 999) ~/ 1000,
          );
          _countdownTimer?.cancel();
          _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (generation != _timerGeneration) return;
            _tickCountdown();
          });
        } else {
          _timerEndsAt = null;
          _timerActive = false;
          _timerRemaining = Duration.zero;
        }
      }

      if (_autoResumeAt != null) {
        if (_autoResumeAt!.isAfter(now) && _pausedByTimerPaths.isNotEmpty) {
          _scheduleAutoResumeTimer(_autoResumeAt!);
        } else if (_pausedByTimerPaths.isNotEmpty) {
          await _resumeTimerPausedSessions();
        } else {
          _autoResumeAt = null;
        }
      }

      _syncNotificationState();
      _notifyListeners();
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
  }

  Future<void> _saveTimerRuntime() async {
    try {
      final prefs = await _prefs;
      final hasRuntime = _hasArmedTimerRuntime;
      if (!hasRuntime) {
        await prefs.remove(_kTimerRuntimeKey);
        return;
      }

      final encoded = json.encode({
        'timerMode': _timerMode?.index,
        'timerDurationMs': _timerDuration?.inMilliseconds,
        'timerWaitingForPlayback': _timerWaitingForPlayback,
        'timerEndsAtMs': _timerEndsAt?.millisecondsSinceEpoch,
        'autoResumeAtMs': _autoResumeAt?.millisecondsSinceEpoch,
        'pausedByTimerPaths': _pausedByTimerPaths,
      });
      await prefs.setString(_kTimerRuntimeKey, encoded);
    } catch (e) {
      debugPrint('AudioProvider persistence error: $e');
    }
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
}
