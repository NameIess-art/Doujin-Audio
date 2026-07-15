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
  List<String> get pausedByTimerSessionIds =>
      List.unmodifiable(_pausedByTimerSessionIds);

  String get converterFormat => _converterFormat;
  String get converterBitrate => _converterBitrate;
  bool get multiThreadPlaybackEnabled => _multiThreadPlaybackEnabled;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get showPlaybackCard => _showPlaybackCard;
  StartupPage get startupPage => _startupPage;
  BottomNavigationStyle get bottomNavigationStyle => _bottomNavigationStyle;
  CoverImageResolution get coverImageResolution =>
      _settingsRepository.coverImageResolution;
  String? get asmrDownloadDestinationRoot =>
      _settingsRepository.asmrDownloadDestinationRoot;
  AsmrDownloadConflictPolicy get asmrDownloadConflictPolicy =>
      _settingsRepository.asmrDownloadConflictPolicy;
  bool get autoPlayAddedSessions => _autoPlayAddedSessions;
  bool get recordPlaybackProgress => _settingsRepository.recordPlaybackProgress;
  ContentLanguagePreference get dlsiteMetadataLanguage =>
      _dlsiteMetadataLanguagePreference;
  AppLanguage get effectiveDlsiteMetadataLanguage => _dlsiteMetadataLanguage;
  List<CardInfoField> get cardInfoFields =>
      List<CardInfoField>.unmodifiable(_settingsRepository.cardInfoFields);
  bool get cardPositionsLocked => _settingsRepository.cardPositionsLocked;
  List<EqPreset> get customEqPresets =>
      List<EqPreset>.unmodifiable(_settingsRepository.customEqPresets);
  int get maxCacheBytes => _maxCacheBytes;
  bool get asmrPlaybackCacheEnabled =>
      _settingsRepository.asmrPlaybackCacheEnabled;
  int get audioDetailRevision => _audioDetailCacheService.revision;

  List<MusicTrack> get library => UnmodifiableListView(_library);
  int get libraryTrackCount => _library.length;
  List<String> get watchedFolders => UnmodifiableListView(_watchedFolders);
  List<String> get watchedLibraries => UnmodifiableListView(_watchedLibraries);
  int get watchedFolderCount => _watchedFolders.length;
  int get watchedLibraryCount => _watchedLibraries.length;
  List<LibraryNode> get libraryCards {
    if (_librarySnapshotCacheService.cardSnapshotRevision !=
        _libraryService.structureRevision) {
      unawaited(_ensureLibraryCardSnapshot());
    } else if (_libraryService.slice.state.treeSnapshotRevision !=
        _librarySnapshotCacheService.cardSnapshotRevision) {
      scheduleMicrotask(
        () => _syncLibraryStateSlice(preserveSliceInitialized: true),
      );
    }
    return _librarySnapshotCacheService.cards;
  }

  List<LibraryNode> get libraryTree {
    if (_librarySnapshotCacheService.treeSnapshotRevision !=
        _libraryService.structureRevision) {
      unawaited(_ensureLibraryTreeSnapshot());
    }
    return _librarySnapshotCacheService.tree;
  }

  int get libraryCardSnapshotRevision =>
      _librarySnapshotCacheService.cardSnapshotRevision;

  int get libraryTreeSnapshotRevision =>
      _librarySnapshotCacheService.treeSnapshotRevision;

  int get libraryLeafFolderCount {
    return _librarySnapshotCacheService.leafFolderCount;
  }

  Future<List<LibraryNode>> loadLibraryTree() async {
    return (await _ensureLibraryTreeSnapshot()).tree;
  }

  Future<FolderNode?> loadLibraryFolderTree(String folderPath) async {
    final tree = await loadLibraryTree();
    for (final node in tree.whereType<FolderNode>()) {
      if (PathMatcher.equalsNormalized(node.path, folderPath)) return node;
    }
    return null;
  }

  int get playingSessionCount => _playbackService.playingSessionCount;

  List<PlaybackSession> get activeSessions => _playbackService.activeSessions;

  bool get isScanning => _isScanning;
  bool get isBackgroundScanning => _isBackgroundScanning;
  String get scanCurrentFolder => _scanCurrentFolder;
  int get scanFoundCount => _scanFoundCount;
  int get scanDuplicateCount => _scanDuplicateCount;
  int get scanFailureCount => _scanFailureCount;
  int get scanGeneration => _scanGeneration;
  FolderScanStage get scanStage => _scanStage;
  int get scanProcessed => _scanProcessed;
  int? get scanTotal => _scanTotal;
  int get libraryContentRevision => _libraryService.contentRevision;

  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
    int? generation,
    FolderScanStage? stage,
    int? processed,
    int? total,
  }) {
    _libraryFacade.setScanProgress(
      currentFolder: currentFolder,
      foundCount: foundCount,
      duplicateCount: duplicateCount,
      failureCount: failureCount,
      generation: generation,
      stage: stage,
      processed: processed,
      total: total,
    );
  }

  void cancelScan() {
    if (!_libraryFacade.isScanning) return;
    _libraryFacade.cancelScan();
    _notifyLibraryChanged();
  }

  int tryBeginScan({required String source, bool background = false}) {
    final generation = _libraryFacade.tryBeginScan(
      source: source,
      background: background,
    );
    if (generation != 0 && !background) _notifyLibraryChanged();
    return generation;
  }

  bool isScanGenerationActive(int generation) =>
      _libraryFacade.isScanGenerationActive(generation);

  void finishScan(int generation) {
    if (!_libraryFacade.isScanGenerationActive(generation)) return;
    final wasBackground = _libraryFacade.isBackgroundScanning;
    _libraryFacade.finishScan(generation);
    if (!wasBackground) _notifyLibraryChanged();
  }
}

extension AudioProviderCoreState on AudioProvider {
  void _markActiveSessionsDirty() {
    _playbackService.markActiveSessionsDirty();
  }

  void _markLibraryStructureDirty() {
    _libraryService.markStructureChanged();
    _librarySnapshotCacheService.markStructureChanged();
  }

  void _rebuildLibraryIndexes() {
    _libraryService.rebuildLibraryIndexes();
    _librarySnapshotCacheService.markStructureChanged();
  }

  void _syncGroupOrderFromLibrary() {
    _libraryService.syncGroupOrderFromLibrary();
  }

  Future<SharedPreferences> get _prefs async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  Future<LibraryTreeSnapshot> _ensureLibraryTreeSnapshot({
    bool notifyOnCommit = true,
  }) {
    return _librarySnapshotCacheService.treeSnapshot(
      onCommitted: () {
        _syncLibraryStateSlice(preserveSliceInitialized: true);
        if (notifyOnCommit) {
          _notifyPresentationListeners();
        }
      },
    );
  }

  Future<LibraryTreeSnapshot> _ensureLibraryCardSnapshot({
    bool notifyOnCommit = true,
  }) {
    return _librarySnapshotCacheService.cardSnapshot(
      onCommitted: () {
        _syncLibraryStateSlice(preserveSliceInitialized: true);
        if (notifyOnCommit) {
          _notifyPresentationListeners();
        }
      },
    );
  }
}
