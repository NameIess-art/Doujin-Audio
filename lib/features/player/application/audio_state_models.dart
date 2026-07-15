part of 'audio_state_services.dart';

class AudioStateSlice<T> {
  AudioStateSlice(this._state);

  T _state;
  final StreamController<T> _controller = StreamController<T>.broadcast();

  T get state => _state;

  Stream<T> get stream async* {
    yield _state;
    yield* _controller.stream;
  }

  void update(T next) {
    if (next == _state) return;
    _state = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }

  Future<void> dispose() => _controller.close();
}

@immutable
class LibraryState {
  const LibraryState({
    this.libraryTrackCount = 0,
    this.watchedFolderCount = 0,
    this.watchedLibraryCount = 0,
    this.isScanning = false,
    this.isBackgroundScanning = false,
    this.scanCurrentFolder = '',
    this.scanFoundCount = 0,
    this.scanDuplicateCount = 0,
    this.scanFailureCount = 0,
    this.scanGeneration = 0,
    this.scanStage = FolderScanStage.idle,
    this.scanProcessed = 0,
    this.scanTotal,
    this.structureRevision = 0,
    this.treeSnapshotRevision = -1,
    this.contentRevision = 0,
    this.detailRevision = 0,
    this.categorySnapshotRevision = 0,
    this.isInitialized = false,
  });

  final int libraryTrackCount;
  final int watchedFolderCount;
  final int watchedLibraryCount;
  final bool isScanning;
  final bool isBackgroundScanning;
  final String scanCurrentFolder;
  final int scanFoundCount;
  final int scanDuplicateCount;
  final int scanFailureCount;
  final int scanGeneration;
  final FolderScanStage scanStage;
  final int scanProcessed;
  final int? scanTotal;
  final int structureRevision;
  final int treeSnapshotRevision;
  final int contentRevision;
  final int detailRevision;
  final int categorySnapshotRevision;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is LibraryState &&
        other.libraryTrackCount == libraryTrackCount &&
        other.watchedFolderCount == watchedFolderCount &&
        other.watchedLibraryCount == watchedLibraryCount &&
        other.isScanning == isScanning &&
        other.isBackgroundScanning == isBackgroundScanning &&
        other.scanCurrentFolder == scanCurrentFolder &&
        other.scanFoundCount == scanFoundCount &&
        other.scanDuplicateCount == scanDuplicateCount &&
        other.scanFailureCount == scanFailureCount &&
        other.scanGeneration == scanGeneration &&
        other.scanStage == scanStage &&
        other.scanProcessed == scanProcessed &&
        other.scanTotal == scanTotal &&
        other.structureRevision == structureRevision &&
        other.treeSnapshotRevision == treeSnapshotRevision &&
        other.contentRevision == contentRevision &&
        other.detailRevision == detailRevision &&
        other.categorySnapshotRevision == categorySnapshotRevision &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    libraryTrackCount,
    watchedFolderCount,
    watchedLibraryCount,
    isScanning,
    isBackgroundScanning,
    scanCurrentFolder,
    scanFoundCount,
    scanDuplicateCount,
    scanFailureCount,
    scanGeneration,
    scanStage,
    scanProcessed,
    scanTotal,
    structureRevision,
    treeSnapshotRevision,
    contentRevision,
    detailRevision,
    categorySnapshotRevision,
    isInitialized,
  );
}

class LibraryExclusionMatcher {
  LibraryExclusionMatcher({
    required String libraryPath,
    Iterable<String> excludedTrackPaths = const <String>[],
    Iterable<String> excludedFolderPaths = const <String>[],
  }) : libraryPath = PathMatcher.normalize(libraryPath),
       _excludedTrackPaths = excludedTrackPaths
           .map(PathMatcher.normalize)
           .toSet(),
       _excludedFolderPaths = excludedFolderPaths
           .map(PathMatcher.normalize)
           .toSet();

  final String libraryPath;
  final Set<String> _excludedTrackPaths;
  final Set<String> _excludedFolderPaths;

  bool get hasExclusions =>
      _excludedTrackPaths.isNotEmpty || _excludedFolderPaths.isNotEmpty;

  bool isExcluded(String entityPath) {
    final normalizedPath = PathMatcher.normalize(entityPath);
    if (_excludedTrackPaths.contains(normalizedPath)) {
      return true;
    }
    if (_excludedFolderPaths.isEmpty) {
      return false;
    }
    for (final folderPath in _candidateFolderPaths(normalizedPath)) {
      if (_excludedFolderPaths.contains(folderPath)) {
        return true;
      }
    }
    return false;
  }

  Iterable<String> _candidateFolderPaths(String normalizedPath) sync* {
    if (_excludedFolderPaths.contains(normalizedPath)) {
      yield normalizedPath;
    }

    if (PathMatcher.isContentUri(libraryPath) ||
        PathMatcher.isContentUri(normalizedPath)) {
      final relativePath = PathMatcher.relativeWithin(
        normalizedPath,
        libraryPath,
      );
      if (relativePath == null || relativePath.isEmpty) {
        return;
      }
      var current = _trimRightSlash(relativePath.replaceAll('\\', '/'));
      while (current.isNotEmpty) {
        yield '$libraryPath::$current';
        final slashIndex = current.lastIndexOf('/');
        if (slashIndex < 0) {
          break;
        }
        current = current.substring(0, slashIndex);
      }
      return;
    }

    var current = normalizedPath;
    while (!PathMatcher.equalsNormalized(current, libraryPath)) {
      yield current;
      final parent = PathMatcher.normalize(path.dirname(current));
      if (parent == current) {
        break;
      }
      current = parent;
    }
  }

  static String _trimRightSlash(String value) {
    var result = value;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}

class LibraryEntrySnapshot {
  LibraryEntrySnapshot({
    required String libraryPath,
    Iterable<LibraryEntry> entries = const <LibraryEntry>[],
  }) : libraryPath = PathMatcher.normalize(libraryPath),
       entriesByPath = <String, LibraryEntry>{
         for (final entry in entries) PathMatcher.normalize(entry.path): entry,
       };

  final String libraryPath;
  final Map<String, LibraryEntry> entriesByPath;

  LibraryEntry? entryForPath(String entryPath) {
    return entriesByPath[PathMatcher.normalize(entryPath)];
  }

  void remember(Iterable<LibraryEntry> entries) {
    for (final entry in entries) {
      entriesByPath[PathMatcher.normalize(entry.path)] = entry;
    }
  }

  bool entryNeedsRefresh(LibraryEntry nextEntry) {
    final existing = entryForPath(nextEntry.path);
    if (existing == null) {
      return true;
    }
    if (existing.kind != nextEntry.kind ||
        existing.state != nextEntry.state ||
        existing.parentPath != nextEntry.parentPath ||
        existing.displayName != nextEntry.displayName) {
      return true;
    }
    if (nextEntry.isFolder) {
      return false;
    }
    return existing.groupKey != nextEntry.groupKey ||
        existing.groupTitle != nextEntry.groupTitle ||
        existing.groupSubtitle != nextEntry.groupSubtitle ||
        existing.isSingle != nextEntry.isSingle ||
        existing.isVideo != nextEntry.isVideo ||
        existing.fileSizeBytes != nextEntry.fileSizeBytes ||
        existing.modifiedAt?.millisecondsSinceEpoch !=
            nextEntry.modifiedAt?.millisecondsSinceEpoch;
  }
}

@immutable
class PlaybackStateSliceData {
  const PlaybackStateSliceData({
    this.activeSessions = const <PlaybackSession>[],
    this.playingSessionCount = 0,
    this.focusedSessionId,
    this.multiThreadPlaybackEnabled = false,
    this.coverGeneration = 0,
    this.sessionStateVersion = 0,
    this.isInitialized = false,
  });

  final List<PlaybackSession> activeSessions;
  final int playingSessionCount;
  final String? focusedSessionId;
  final bool multiThreadPlaybackEnabled;
  final int coverGeneration;
  final int sessionStateVersion;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is PlaybackStateSliceData &&
        other.sessionStateVersion == sessionStateVersion &&
        listEquals(other.activeSessions, activeSessions) &&
        other.playingSessionCount == playingSessionCount &&
        other.focusedSessionId == focusedSessionId &&
        other.multiThreadPlaybackEnabled == multiThreadPlaybackEnabled &&
        other.coverGeneration == coverGeneration &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    sessionStateVersion,
    Object.hashAll(activeSessions),
    playingSessionCount,
    focusedSessionId,
    multiThreadPlaybackEnabled,
    coverGeneration,
    isInitialized,
  );
}

@immutable
class TimerStateSliceData {
  const TimerStateSliceData({
    this.mode,
    this.duration,
    this.draftMode = TimerMode.manual,
    this.draftDuration = const Duration(minutes: 30),
    this.active = false,
    this.remaining,
    this.autoResumeEnabled = false,
    this.autoResumeHour = 7,
    this.autoResumeMinute = 0,
    this.autoResumeAt,
    this.pausedByTimerSessionIds = const <String>[],
    this.isInitialized = false,
  });

  final TimerMode? mode;
  final Duration? duration;
  final TimerMode draftMode;
  final Duration draftDuration;
  final bool active;
  final Duration? remaining;
  final bool autoResumeEnabled;
  final int autoResumeHour;
  final int autoResumeMinute;

  /// Wall-clock time at which auto-resume will fire, or null if not scheduled.
  final DateTime? autoResumeAt;
  final List<String> pausedByTimerSessionIds;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is TimerStateSliceData &&
        other.mode == mode &&
        other.duration == duration &&
        other.draftMode == draftMode &&
        other.draftDuration == draftDuration &&
        other.active == active &&
        other.remaining == remaining &&
        other.autoResumeEnabled == autoResumeEnabled &&
        other.autoResumeHour == autoResumeHour &&
        other.autoResumeMinute == autoResumeMinute &&
        other.autoResumeAt == autoResumeAt &&
        listEquals(other.pausedByTimerSessionIds, pausedByTimerSessionIds) &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    duration,
    draftMode,
    draftDuration,
    active,
    remaining,
    autoResumeEnabled,
    autoResumeHour,
    autoResumeMinute,
    autoResumeAt,
    Object.hashAll(pausedByTimerSessionIds),
    isInitialized,
  );
}

enum StartupPage { asmrOne, library, playlist }

enum BottomNavigationStyle { capsule, bar }

enum CoverImageResolution { memorySaver, balanced, high, original }

@immutable
class SettingsState {
  const SettingsState({
    this.converterFormat = 'mp3',
    this.converterBitrate = '320k',
    this.multiThreadPlaybackEnabled = false,
    this.notificationsEnabled = true,
    this.showPlaybackCard = true,
    this.autoPlayAddedSessions = true,
    this.autoCheckUpdates = false,
    this.dlsiteMetadataLanguage = ContentLanguagePreference.followPage,
    this.cardInfoFields = CardInfoField.defaults,
    this.cardPositionsLocked = true,
    this.customEqPresets = const <EqPreset>[],
    this.maxCacheBytes = 300 * 1024 * 1024,
    this.asmrPlaybackCacheEnabled = false,
    this.recordPlaybackProgress = true,
    this.blurPlayerBackgroundEnabled = true,
    this.uiBlurEffectEnabled = true,
    this.hapticFeedbackEnabled = true,
    this.startupPage = StartupPage.library,
    this.bottomNavigationStyle = BottomNavigationStyle.capsule,
    this.coverImageResolution = CoverImageResolution.balanced,
    this.asmrDownloadDestinationRoot,
    this.asmrDownloadConflictPolicy = AsmrDownloadConflictPolicy.overwrite,
    this.isInitialized = false,
  });

  final String converterFormat;
  final String converterBitrate;
  final bool multiThreadPlaybackEnabled;
  final bool notificationsEnabled;
  final bool showPlaybackCard;
  final bool autoPlayAddedSessions;
  final bool autoCheckUpdates;
  final ContentLanguagePreference dlsiteMetadataLanguage;
  final List<CardInfoField> cardInfoFields;
  final bool cardPositionsLocked;
  final List<EqPreset> customEqPresets;
  final int maxCacheBytes;
  final bool asmrPlaybackCacheEnabled;
  final bool recordPlaybackProgress;
  final bool blurPlayerBackgroundEnabled;
  final bool uiBlurEffectEnabled;
  final bool hapticFeedbackEnabled;
  final StartupPage startupPage;
  final BottomNavigationStyle bottomNavigationStyle;
  final CoverImageResolution coverImageResolution;
  final String? asmrDownloadDestinationRoot;
  final AsmrDownloadConflictPolicy asmrDownloadConflictPolicy;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is SettingsState &&
        other.converterFormat == converterFormat &&
        other.converterBitrate == converterBitrate &&
        other.multiThreadPlaybackEnabled == multiThreadPlaybackEnabled &&
        other.notificationsEnabled == notificationsEnabled &&
        other.showPlaybackCard == showPlaybackCard &&
        other.autoPlayAddedSessions == autoPlayAddedSessions &&
        other.autoCheckUpdates == autoCheckUpdates &&
        other.dlsiteMetadataLanguage == dlsiteMetadataLanguage &&
        listEquals(other.cardInfoFields, cardInfoFields) &&
        other.cardPositionsLocked == cardPositionsLocked &&
        listEquals(other.customEqPresets, customEqPresets) &&
        other.maxCacheBytes == maxCacheBytes &&
        other.asmrPlaybackCacheEnabled == asmrPlaybackCacheEnabled &&
        other.recordPlaybackProgress == recordPlaybackProgress &&
        other.blurPlayerBackgroundEnabled == blurPlayerBackgroundEnabled &&
        other.uiBlurEffectEnabled == uiBlurEffectEnabled &&
        other.hapticFeedbackEnabled == hapticFeedbackEnabled &&
        other.startupPage == startupPage &&
        other.bottomNavigationStyle == bottomNavigationStyle &&
        other.coverImageResolution == coverImageResolution &&
        other.asmrDownloadDestinationRoot == asmrDownloadDestinationRoot &&
        other.asmrDownloadConflictPolicy == asmrDownloadConflictPolicy &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    converterFormat,
    converterBitrate,
    multiThreadPlaybackEnabled,
    notificationsEnabled,
    showPlaybackCard,
    autoPlayAddedSessions,
    autoCheckUpdates,
    dlsiteMetadataLanguage,
    Object.hashAll(cardInfoFields),
    cardPositionsLocked,
    Object.hashAll(customEqPresets),
    maxCacheBytes,
    asmrPlaybackCacheEnabled,
    recordPlaybackProgress,
    blurPlayerBackgroundEnabled,
    uiBlurEffectEnabled,
    hapticFeedbackEnabled,
    startupPage,
    bottomNavigationStyle,
    coverImageResolution,
    asmrDownloadDestinationRoot,
    asmrDownloadConflictPolicy,
    isInitialized,
  ]);
}

@immutable
class NotificationState {
  const NotificationState({
    this.focusedSessionId,
    this.notificationsDismissedWhilePaused = false,
    this.notificationActionRefreshPending = false,
    this.activeQueueLength = 0,
  });

  final String? focusedSessionId;
  final bool notificationsDismissedWhilePaused;
  final bool notificationActionRefreshPending;
  final int activeQueueLength;

  @override
  bool operator ==(Object other) {
    return other is NotificationState &&
        other.focusedSessionId == focusedSessionId &&
        other.notificationsDismissedWhilePaused ==
            notificationsDismissedWhilePaused &&
        other.notificationActionRefreshPending ==
            notificationActionRefreshPending &&
        other.activeQueueLength == activeQueueLength;
  }

  @override
  int get hashCode => Object.hash(
    focusedSessionId,
    notificationsDismissedWhilePaused,
    notificationActionRefreshPending,
    activeQueueLength,
  );
}
