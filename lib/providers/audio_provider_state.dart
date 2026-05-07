part of 'audio_provider.dart';

extension AudioProviderState on AudioProvider {
  TimerMode? get timerMode => _timerMode;
  Duration? get timerDuration => _timerDuration;
  TimerMode get timerDraftMode => _timerDraftMode;
  Duration get timerDraftDuration => _timerDraftDuration;
  bool get timerActive => _timerActive;
  Duration? get timerRemaining => _timerRemaining;
  bool get timerConfigured => _timerDuration != null;
  bool get timerExpired =>
      timerConfigured &&
      !_timerActive &&
      _timerRemaining != null &&
      _timerRemaining! <= Duration.zero;
  bool get timerWaitingTrigger =>
      timerConfigured &&
      !timerExpired &&
      !_timerActive &&
      _timerMode == TimerMode.trigger &&
      _timerRemaining != null &&
      _timerRemaining! > Duration.zero;
  bool get autoResumeEnabled => _autoResumeEnabled;
  int get autoResumeHour => _autoResumeHour;
  int get autoResumeMinute => _autoResumeMinute;
  List<String> get pausedByTimerPaths => List.unmodifiable(_pausedByTimerPaths);

  String get converterFormat => _converterFormat;
  String get converterBitrate => _converterBitrate;
  bool get multiThreadPlaybackEnabled => _multiThreadPlaybackEnabled;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get showPlaybackCard => _showPlaybackCard;
  bool get autoPlayAddedSessions => _autoPlayAddedSessions;
  bool get isPageTransitioning => _isPageTransitioning;

  List<MusicTrack> get library => List.unmodifiable(_library);
  int get libraryTrackCount => _library.length;
  List<String> get watchedFolders => List.unmodifiable(_watchedFolders);
  List<String> get watchedLibraries => List.unmodifiable(_watchedLibraries);
  int get watchedFolderCount => _watchedFolders.length;
  int get watchedLibraryCount => _watchedLibraries.length;
  List<LibraryNode> get libraryTree {
    if (_libraryTreeDirty) {
      final snapshot = _buildLibraryTreeSnapshot();
      _cachedLibraryTree = snapshot.tree;
      _cachedLibraryLeafFolderCount = snapshot.leafFolderCount;
      _libraryTreeDirty = false;
    }
    return _cachedLibraryTree;
  }

  int get libraryLeafFolderCount {
    if (_libraryTreeDirty) {
      final _ = libraryTree;
    }
    return _cachedLibraryLeafFolderCount;
  }

  int get playingSessionCount =>
      _sessions.values.where((session) => session.state.playing).length;

  List<PlaybackSession> get activeSessions {
    if (_activeSessionsDirty) {
      final result = <PlaybackSession>[];
      final orderSet = _sessionOrder.toSet();
      for (final id in _sessionOrder) {
        final session = _sessions[id];
        if (session != null) {
          result.add(session);
        }
      }
      for (final session in _sessions.values) {
        if (!orderSet.contains(session.id)) {
          result.add(session);
        }
      }
      _activeSessionsCache = List<PlaybackSession>.unmodifiable(result);
      _activeSessionsDirty = false;
    }
    return _activeSessionsCache;
  }

  bool get isScanning => _isScanning;
  bool get isBackgroundScanning => _isBackgroundScanning;
  String get scanCurrentFolder => _scanCurrentFolder;
  int get scanFoundCount => _scanFoundCount;
  int get scanDuplicateCount => _scanDuplicateCount;
  int get scanFailureCount => _scanFailureCount;

  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
  }) {
    var changed = false;
    final nextFolder = currentFolder ?? _scanCurrentFolder;
    final nextFoundCount = foundCount ?? _scanFoundCount;
    final nextDuplicateCount = duplicateCount ?? _scanDuplicateCount;
    final nextFailureCount = failureCount ?? _scanFailureCount;
    changed =
        nextFolder != _scanCurrentFolder ||
        nextFoundCount != _scanFoundCount ||
        nextDuplicateCount != _scanDuplicateCount ||
        nextFailureCount != _scanFailureCount;
    if (!changed) return;
    if (currentFolder != null) _scanCurrentFolder = currentFolder;
    if (foundCount != null) _scanFoundCount = foundCount;
    if (duplicateCount != null) _scanDuplicateCount = duplicateCount;
    if (failureCount != null) _scanFailureCount = failureCount;
    _scheduleScanProgressNotify();
  }

  void _scheduleScanProgressNotify() {
    if (!_isScanning) {
      _notifyListeners();
      return;
    }
    if (_scanProgressNotifyTimer != null) return;
    _scanProgressNotifyTimer = Timer(const Duration(milliseconds: 160), () {
      _scanProgressNotifyTimer = null;
      if (_isScanning) {
        _notifyListeners();
      }
    });
  }

  void cancelScan() {
    if (!_isScanning) return;
    _isScanning = false;
    _scanProgressNotifyTimer?.cancel();
    _scanProgressNotifyTimer = null;
    _notifyListeners();
  }

  void setPageTransitioning(bool value) {
    if (_isPageTransitioning == value) return;
    _isPageTransitioning = value;
    _notifyListeners();
  }
}

extension AudioProviderCoreState on AudioProvider {
  void _markActiveSessionsDirty() {
    _activeSessionsDirty = true;
  }

  void _markLibraryStructureDirty() {
    _libraryTreeDirty = true;
  }

  void _rebuildLibraryIndexes() {
    final tracksByGroup = <String, List<MusicTrack>>{};
    _libraryByPath
      ..clear()
      ..addEntries(_library.map((track) => MapEntry(track.path, track)));
    for (final track in _library) {
      tracksByGroup
          .putIfAbsent(track.groupKey, () => <MusicTrack>[])
          .add(track);
    }
    for (final entry in tracksByGroup.entries) {
      entry.value.sort(getTrackComparator);
    }
    _tracksByGroup
      ..clear()
      ..addAll(
        tracksByGroup.map(
          (groupKey, tracks) =>
              MapEntry(groupKey, List<MusicTrack>.unmodifiable(tracks)),
        ),
      );
    _sortedLibraryTracks = List<MusicTrack>.unmodifiable(
      _library.toList()..sort(getTrackComparator),
    );
    _sortedLibraryTrackPaths = List<String>.unmodifiable(
      _sortedLibraryTracks.map((track) => track.path),
    );
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);
    _markLibraryStructureDirty();
  }

  void _syncGroupOrderFromLibrary() {
    final activeGroupKeys = _library.map((track) => track.groupKey).toSet();
    _groupOrder.removeWhere((groupKey) => !activeGroupKeys.contains(groupKey));
    for (final groupKey in activeGroupKeys) {
      if (_groupOrderSet.add(groupKey)) {
        _groupOrder.add(groupKey);
      }
    }
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);
  }

  Future<SharedPreferences> get _prefs async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }
}
