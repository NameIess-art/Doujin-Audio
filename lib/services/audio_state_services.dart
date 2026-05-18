import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/library_node.dart';
import '../models/library_entry.dart';
import '../models/music_track.dart';
import '../models/playback_mode.dart';
import '../models/playback_session.dart';
import 'library_organizer.dart';
import 'native_playback_bridge.dart';
import 'path_matcher.dart';
import 'playback_notification_service.dart';
import 'subtitle_parser.dart';
import 'warmup_scheduler.dart';

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
    this.structureRevision = 0,
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
  final int structureRevision;
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
        other.structureRevision == structureRevision &&
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
    structureRevision,
    isInitialized,
  );
}

@immutable
class PlaybackStateSliceData {
  const PlaybackStateSliceData({
    this.activeSessions = const <PlaybackSession>[],
    this.playingSessionCount = 0,
    this.focusedSessionId,
    this.multiThreadPlaybackEnabled = false,
    this.sessionStateVersion = 0,
    this.isInitialized = false,
  });

  final List<PlaybackSession> activeSessions;
  final int playingSessionCount;
  final String? focusedSessionId;
  final bool multiThreadPlaybackEnabled;
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
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    sessionStateVersion,
    Object.hashAll(activeSessions),
    playingSessionCount,
    focusedSessionId,
    multiThreadPlaybackEnabled,
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

@immutable
class SettingsState {
  const SettingsState({
    this.converterFormat = 'mp3',
    this.converterBitrate = '320k',
    this.multiThreadPlaybackEnabled = false,
    this.notificationsEnabled = true,
    this.showPlaybackCard = true,
    this.autoPlayAddedSessions = true,
    this.isPageTransitioning = false,
  });

  final String converterFormat;
  final String converterBitrate;
  final bool multiThreadPlaybackEnabled;
  final bool notificationsEnabled;
  final bool showPlaybackCard;
  final bool autoPlayAddedSessions;
  final bool isPageTransitioning;

  @override
  bool operator ==(Object other) {
    return other is SettingsState &&
        other.converterFormat == converterFormat &&
        other.converterBitrate == converterBitrate &&
        other.multiThreadPlaybackEnabled == multiThreadPlaybackEnabled &&
        other.notificationsEnabled == notificationsEnabled &&
        other.showPlaybackCard == showPlaybackCard &&
        other.autoPlayAddedSessions == autoPlayAddedSessions &&
        other.isPageTransitioning == isPageTransitioning;
  }

  @override
  int get hashCode => Object.hash(
    converterFormat,
    converterBitrate,
    multiThreadPlaybackEnabled,
    notificationsEnabled,
    showPlaybackCard,
    autoPlayAddedSessions,
    isPageTransitioning,
  );
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

class LibraryService {
  static const LibraryOrganizer organizer = LibraryOrganizer();

  final List<MusicTrack> library = <MusicTrack>[];
  final Map<String, MusicTrack> libraryByPath = <String, MusicTrack>{};

  /// Maps each track path to its index in [library].  Kept in sync by
  /// [_rebuildLibraryIndexes] so that [addOrReplaceTracks] can update
  /// existing entries in O(1) instead of O(n).
  final Map<String, int> libraryIndexByPath = <String, int>{};
  final Map<String, List<MusicTrack>> tracksByGroup =
      <String, List<MusicTrack>>{};
  List<MusicTrack> sortedLibraryTracks = const <MusicTrack>[];
  List<String> sortedLibraryTrackPaths = const <String>[];
  final List<String> groupOrder = <String>[];
  final Set<String> groupOrderSet = <String>{};
  final List<String> libraryNodeOrder = <String>[];
  final List<String> watchedFolders = <String>[];
  final List<String> watchedLibraries = <String>[];
  final Map<String, Set<String>> excludedLibraryFolders =
      <String, Set<String>>{};
  final Map<String, Set<String>> excludedLibraryTracks =
      <String, Set<String>>{};
  final Map<String, Map<String, LibraryEntry>> libraryEntriesByLibrary =
      <String, Map<String, LibraryEntry>>{};
  bool isScanning = false;
  bool isBackgroundScanning = false;
  String scanCurrentFolder = '';
  int scanFoundCount = 0;
  int scanDuplicateCount = 0;
  int scanFailureCount = 0;
  bool libraryTreeDirty = true;
  List<LibraryNode> cachedLibraryTree = const <LibraryNode>[];
  int cachedLibraryLeafFolderCount = 0;
  int libraryBatchDepth = 0;
  bool libraryBatchChanged = false;
  bool libraryBatchChangedGroupOrder = false;
  final List<MusicTrack> libraryBatchPersistTracks = <MusicTrack>[];
  Timer? scanProgressNotifyTimer;
  int structureRevision = 0;
  final AudioStateSlice<LibraryState> slice = AudioStateSlice<LibraryState>(
    const LibraryState(),
  );

  void markStructureChanged() {
    structureRevision++;
    libraryTreeDirty = true;
  }

  List<String> currentTopLevelNodeIds() {
    return organizer.topLevelNodeIds(library, watchedFolders);
  }

  void syncLibraryNodeOrder({bool persist = true, VoidCallback? onPersist}) {
    final validNodeIds = currentTopLevelNodeIds();
    final validNodeIdSet = validNodeIds.toSet();
    var changed = false;
    final previousLength = libraryNodeOrder.length;
    libraryNodeOrder.removeWhere((id) => !validNodeIdSet.contains(id));
    if (libraryNodeOrder.length != previousLength) {
      changed = true;
    }

    final orderedNodeIdSet = libraryNodeOrder.toSet();
    final missingNodeIds = validNodeIds
        .where((nodeId) => !orderedNodeIdSet.contains(nodeId))
        .toList(growable: false);
    if (missingNodeIds.isNotEmpty) {
      libraryNodeOrder.insertAll(0, missingNodeIds);
      changed = true;
    }

    if (changed && persist) {
      onPersist?.call();
    }
  }

  void reorderLibraryNodes(
    int oldIndex,
    int newIndex, {
    required List<LibraryNode> currentTree,
    VoidCallback? onPersist,
  }) {
    final currentIds = currentTree.map((node) => node.path).toList();
    if (oldIndex < 0 || oldIndex >= currentIds.length) return;
    if (newIndex < 0 || newIndex > currentIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final movedId = currentIds.removeAt(oldIndex);
    currentIds.insert(newIndex, movedId);
    libraryNodeOrder
      ..clear()
      ..addAll(currentIds);
    markStructureChanged();
    onPersist?.call();
  }

  bool addWatchedFolder(String folderPath, {VoidCallback? onPersist}) {
    if (watchedFolders.any(
      (watchedFolder) =>
          PathMatcher.equalsNormalized(watchedFolder, folderPath),
    )) {
      return false;
    }
    watchedFolders.add(folderPath);
    syncLibraryNodeOrder(onPersist: onPersist);
    markStructureChanged();
    onPersist?.call();
    return true;
  }

  bool addWatchedLibrary(String folderPath, {VoidCallback? onPersist}) {
    if (watchedLibraries.any(
      (watchedLibrary) =>
          PathMatcher.equalsNormalized(watchedLibrary, folderPath),
    )) {
      return false;
    }
    watchedLibraries.add(folderPath);
    onPersist?.call();
    return true;
  }

  bool removeWatchedFolder(String folderPath, {VoidCallback? onPersist}) {
    final previousLength = watchedFolders.length;
    watchedFolders.removeWhere(
      (watchedFolder) =>
          PathMatcher.equalsNormalized(watchedFolder, folderPath),
    );
    if (watchedFolders.length == previousLength) return false;
    syncLibraryNodeOrder(persist: false);
    markStructureChanged();
    onPersist?.call();
    return true;
  }

  bool removeWatchedLibrary(String folderPath, {VoidCallback? onPersist}) {
    final previousLength = watchedLibraries.length;
    watchedLibraries.removeWhere(
      (watchedLibrary) =>
          PathMatcher.equalsNormalized(watchedLibrary, folderPath),
    );
    if (watchedLibraries.length == previousLength) return false;
    onPersist?.call();
    return true;
  }

  List<String> childFoldersForLibrary(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return watchedFolders
        .where(
          (folderPath) => PathMatcher.isWithinOrEqualNormalized(
            PathMatcher.normalize(folderPath),
            normalizedLibraryPath,
          ),
        )
        .toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<String> excludedFoldersForLibrary(String libraryPath) {
    return (excludedLibraryFolders[PathMatcher.normalize(libraryPath)] ??
            const <String>{})
        .toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<String> excludedTracksForLibrary(String libraryPath) {
    return (excludedLibraryTracks[PathMatcher.normalize(libraryPath)] ??
            const <String>{})
        .toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    if (entries == null) return const <LibraryEntry>[];
    return entries.values.toList(growable: false);
  }

  bool hasLibraryEntriesForLibrary(String libraryPath) {
    return libraryEntriesByLibrary[PathMatcher.normalize(libraryPath)]
            ?.isNotEmpty ??
        false;
  }

  bool isLibraryPathExcluded(String libraryPath, String entityPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedPath = PathMatcher.normalize(entityPath);
    // O(1) direct lookup for explicitly excluded tracks.
    if (excludedLibraryTracks[normalizedLibraryPath]?.contains(
          normalizedPath,
        ) ??
        false) {
      return true;
    }
    final folders = excludedLibraryFolders[normalizedLibraryPath];
    if (folders == null) return false;
    return folders.any(
      (folderPath) =>
          PathMatcher.isWithinOrEqualNormalized(normalizedPath, folderPath),
    );
  }

  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedPath = PathMatcher.normalize(entityPath);
    final folders = excludedLibraryFolders[normalizedLibraryPath];
    if (folders == null) return false;
    return folders.any(
      (folderPath) =>
          normalizedPath != folderPath &&
          PathMatcher.isWithinOrEqualNormalized(normalizedPath, folderPath),
    );
  }

  bool isLibraryFolderExplicitlyExcluded(
    String libraryPath,
    String folderPath,
  ) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return excludedLibraryFolders[PathMatcher.normalize(libraryPath)]?.contains(
          normalizedFolderPath,
        ) ??
        false;
  }

  bool isLibraryTrackExplicitlyExcluded(String libraryPath, String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    return excludedLibraryTracks[PathMatcher.normalize(libraryPath)]?.contains(
          normalizedTrackPath,
        ) ??
        false;
  }

  bool setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded, {
    VoidCallback? onPersist,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final folders = excludedLibraryFolders.putIfAbsent(
      normalizedLibraryPath,
      () => <String>{},
    );
    final changed = excluded
        ? folders.add(normalizedFolderPath)
        : _removePathsWithin(folders, normalizedFolderPath);
    if (!changed) return false;
    if (!excluded) {
      excludedLibraryTracks[normalizedLibraryPath]?.removeWhere(
        (trackPath) => PathMatcher.isWithinOrEqualNormalized(
          trackPath,
          normalizedFolderPath,
        ),
      );
    }
    setLibraryEntriesSubtreeState(
      normalizedLibraryPath,
      normalizedFolderPath,
      excluded ? LibraryEntryState.excluded : LibraryEntryState.active,
    );
    markStructureChanged();
    onPersist?.call();
    return true;
  }

  bool setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded, {
    VoidCallback? onPersist,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final tracks = excludedLibraryTracks.putIfAbsent(
      normalizedLibraryPath,
      () => <String>{},
    );
    if (excluded && isLibraryPathInheritedExcluded(libraryPath, trackPath)) {
      return false;
    }
    final changed = excluded
        ? tracks.add(normalizedTrackPath)
        : tracks.remove(normalizedTrackPath);
    if (!changed) return false;
    setLibraryEntryState(
      normalizedLibraryPath,
      normalizedTrackPath,
      excluded ? LibraryEntryState.excluded : LibraryEntryState.active,
    );
    markStructureChanged();
    onPersist?.call();
    return true;
  }

  bool _removePathsWithin(Set<String> paths, String parentPath) {
    final beforeLength = paths.length;
    paths.removeWhere(
      (pathValue) =>
          PathMatcher.isWithinOrEqualNormalized(pathValue, parentPath),
    );
    return paths.length != beforeLength;
  }

  void replaceLibraryEntries(Iterable<LibraryEntry> entries) {
    for (final entry in entries) {
      final normalizedLibraryPath = PathMatcher.normalize(entry.libraryPath);
      final normalizedPath = PathMatcher.normalize(entry.path);
      libraryEntriesByLibrary.putIfAbsent(
        normalizedLibraryPath,
        () => <String, LibraryEntry>{},
      )[normalizedPath] = entry
          .copyWith();
    }
    // Library entries back the edit/exclusion metadata tree, not the main
    // audio library tree. Refresh scans can replace many entry rows while the
    // visible library content is still unchanged, so avoid invalidating the
    // main tree on every metadata write.
  }

  /// Rebuilds [excludedLibraryFolders] and [excludedLibraryTracks] from the
  /// persisted [LibraryEntry] list.  Called after loading entries from the
  /// database so that SQLite (the durable source of truth) always wins over
  /// the SharedPreferences cache.
  void rebuildExclusionsFromEntries(Iterable<LibraryEntry> entries) {
    excludedLibraryFolders.clear();
    excludedLibraryTracks.clear();
    for (final entry in entries) {
      if (!entry.isExcluded) continue;
      final lib = PathMatcher.normalize(entry.libraryPath);
      final p = PathMatcher.normalize(entry.path);
      if (entry.isFolder) {
        excludedLibraryFolders.putIfAbsent(lib, () => <String>{}).add(p);
      } else {
        excludedLibraryTracks.putIfAbsent(lib, () => <String>{}).add(p);
      }
    }
  }

  List<String> removeLibraryEntriesMissingFromFolderScan(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    if (entries == null || entries.isEmpty) return const <String>[];

    final removedPaths = <String>[];
    entries.removeWhere((entryPath, entry) {
      if (entry.isFolder) return false;
      if (!PathMatcher.isWithinOrEqualNormalized(
        entry.path,
        normalizedFolderPath,
      )) {
        return false;
      }
      final retained = retainedPaths.contains(entry.path);
      if (retained) return false;
      removedPaths.add(entry.path);
      return true;
    });

    return removedPaths;
  }

  List<String> setLibraryEntriesSubtreeState(
    String libraryPath,
    String rootPath,
    LibraryEntryState state,
  ) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedRootPath = PathMatcher.normalize(rootPath);
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    if (entries == null) return const <String>[];
    final changedPaths = <String>[];
    // Iterating entries.values while updating existing keys (not adding/removing)
    // is safe in Dart's LinkedHashMap.
    for (final entry in entries.values) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        entry.path,
        normalizedRootPath,
      )) {
        continue;
      }
      if (entry.state == state) continue;
      entries[entry.path] = entry.copyWith(state: state);
      changedPaths.add(entry.path);
    }
    if (changedPaths.isNotEmpty) {
      markStructureChanged();
    }
    return changedPaths;
  }

  bool setLibraryEntryState(
    String libraryPath,
    String entryPath,
    LibraryEntryState state,
  ) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedEntryPath = PathMatcher.normalize(entryPath);
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    final entry = entries?[normalizedEntryPath];
    if (entry == null || entry.state == state) return false;
    entries![normalizedEntryPath] = entry.copyWith(state: state);
    markStructureChanged();
    return true;
  }

  MusicTrack? trackByPath(String trackPath) => libraryByPath[trackPath];

  Future<void> removeLibrary(
    String libraryPath, {
    required Future<void> Function(String folderPath) removeFolder,
    VoidCallback? onSaveWatchedLibraries,
    VoidCallback? onSaveLibraryExclusions,
  }) {
    return _removeLibraryInternal(
      libraryPath,
      removeFolder: removeFolder,
      onSaveWatchedLibraries: onSaveWatchedLibraries,
      onSaveLibraryExclusions: onSaveLibraryExclusions,
    );
  }

  Future<void> _removeLibraryInternal(
    String libraryPath, {
    required Future<void> Function(String folderPath) removeFolder,
    VoidCallback? onSaveWatchedLibraries,
    VoidCallback? onSaveLibraryExclusions,
  }) async {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final childFolders = watchedFolders
        .where(
          (folderPath) => PathMatcher.isWithinOrEqualNormalized(
            PathMatcher.normalize(folderPath),
            normalizedLibraryPath,
          ),
        )
        .toList(growable: false);
    for (final folderPath in childFolders) {
      await removeFolder(folderPath);
    }
    watchedLibraries.removeWhere(
      (pathValue) =>
          PathMatcher.equalsNormalized(pathValue, normalizedLibraryPath),
    );
    excludedLibraryFolders.removeWhere(
      (pathValue, _) =>
          PathMatcher.equalsNormalized(pathValue, normalizedLibraryPath),
    );
    excludedLibraryTracks.removeWhere(
      (pathValue, _) =>
          PathMatcher.equalsNormalized(pathValue, normalizedLibraryPath),
    );
    libraryEntriesByLibrary.removeWhere(
      (pathValue, _) =>
          PathMatcher.equalsNormalized(pathValue, normalizedLibraryPath),
    );
    syncLibraryNodeOrder(persist: false);
    markStructureChanged();
    onSaveWatchedLibraries?.call();
    onSaveLibraryExclusions?.call();
  }

  void syncSlice({required bool isInitialized}) {
    slice.update(
      LibraryState(
        libraryTrackCount: library.length,
        watchedFolderCount: watchedFolders.length,
        watchedLibraryCount: watchedLibraries.length,
        isScanning: isScanning,
        isBackgroundScanning: isBackgroundScanning,
        scanCurrentFolder: scanCurrentFolder,
        scanFoundCount: scanFoundCount,
        scanDuplicateCount: scanDuplicateCount,
        scanFailureCount: scanFailureCount,
        structureRevision: structureRevision,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}

class PlaybackSessionService {
  final Map<String, PlaybackSession> sessions = <String, PlaybackSession>{};
  final List<String> sessionOrder = <String>[];
  bool activeSessionsDirty = true;
  int sessionStateVersion = 0;
  List<PlaybackSession> activeSessionsCache = const <PlaybackSession>[];
  Future<void> sessionPreparationQueue = Future<void>.value();
  Timer? saveSessionStateTimer;
  Timer? saveSessionOrderTimer;
  final AudioStateSlice<PlaybackStateSliceData> slice =
      AudioStateSlice<PlaybackStateSliceData>(const PlaybackStateSliceData());

  List<PlaybackSession> get activeSessions {
    if (activeSessionsDirty) {
      final result = <PlaybackSession>[];
      final orderSet = sessionOrder.toSet();
      for (final id in sessionOrder) {
        final session = sessions[id];
        if (session != null) {
          result.add(session);
        }
      }
      for (final session in sessions.values) {
        if (!orderSet.contains(session.id)) {
          result.add(session);
        }
      }
      activeSessionsCache = List<PlaybackSession>.unmodifiable(result);
      activeSessionsDirty = false;
    }
    return activeSessionsCache;
  }

  int get playingSessionCount =>
      sessions.values.where((session) => session.state.playing).length;

  void markActiveSessionsDirty() {
    activeSessionsDirty = true;
    sessionStateVersion++;
  }

  PlaybackSession? sessionById(String sessionId) => sessions[sessionId];

  bool isTrackActive(String trackPath) =>
      sessions.values.any((session) => session.currentTrackPath == trackPath);

  void registerSession(PlaybackSession session) {
    sessions[session.id] = session;
    sessionOrder.remove(session.id);
    sessionOrder.insert(0, session.id);
    markActiveSessionsDirty();
  }

  List<PlaybackSession> removeSessions(Iterable<String> sessionIds) {
    final removedSessions = <PlaybackSession>[];
    for (final sessionId in LinkedHashSet<String>.from(sessionIds)) {
      final session = sessions.remove(sessionId);
      if (session == null) continue;
      removedSessions.add(session);
      sessionOrder.remove(sessionId);
    }
    if (removedSessions.isNotEmpty) {
      markActiveSessionsDirty();
    }
    return removedSessions;
  }

  void enqueueSessionPreparation(Future<void> Function() prepare) {
    sessionPreparationQueue = sessionPreparationQueue
        .catchError((_) {})
        .then((_) => prepare());
  }

  void reorderSessions(int oldIndex, int newIndex) {
    final orderedIds = activeSessions.map((session) => session.id).toList();
    if (oldIndex < 0 || oldIndex >= orderedIds.length) return;
    if (newIndex < 0 || newIndex > orderedIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final movedId = orderedIds.removeAt(oldIndex);
    orderedIds.insert(newIndex, movedId);
    sessionOrder
      ..clear()
      ..addAll(orderedIds);
    markActiveSessionsDirty();
  }

  bool applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    final session = sessions[snapshot.sessionId];
    if (session == null) return false;
    final previousTrackPath = session.currentTrackPath;
    session.applyNativeSnapshot(snapshot);
    if (session.currentTrackPath != previousTrackPath) {
      markActiveSessionsDirty();
    }
    return true;
  }

  void syncSlice({
    required List<PlaybackSession> activeSessions,
    required int playingSessionCount,
    required String? focusedSessionId,
    required bool multiThreadPlaybackEnabled,
    required bool isInitialized,
  }) {
    slice.update(
      PlaybackStateSliceData(
        activeSessions: UnmodifiableListView<PlaybackSession>(activeSessions),
        playingSessionCount: playingSessionCount,
        focusedSessionId: focusedSessionId,
        multiThreadPlaybackEnabled: multiThreadPlaybackEnabled,
        sessionStateVersion: sessionStateVersion,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}

class TimerService {
  TimerMode? timerMode;
  Duration? timerDuration;
  TimerMode timerDraftMode = TimerMode.manual;
  Duration timerDraftDuration = const Duration(minutes: 30);
  bool timerActive = false;
  Duration? timerRemaining;
  DateTime? timerEndsAt;
  Timer? countdownTimer;
  bool timerWaitingForPlayback = false;
  int timerGeneration = 0;
  final List<String> pausedByTimerSessionIds = <String>[];
  bool autoResumeEnabled = false;
  int autoResumeHour = 7;
  int autoResumeMinute = 0;
  Timer? autoResumeTimer;
  DateTime? autoResumeAt;
  final AudioStateSlice<TimerStateSliceData> slice =
      AudioStateSlice<TimerStateSliceData>(const TimerStateSliceData());

  void syncSlice({required bool isInitialized}) {
    slice.update(
      TimerStateSliceData(
        mode: timerMode,
        duration: timerDuration,
        draftMode: timerDraftMode,
        draftDuration: timerDraftDuration,
        active: timerActive,
        remaining: timerRemaining,
        autoResumeEnabled: autoResumeEnabled,
        autoResumeHour: autoResumeHour,
        autoResumeMinute: autoResumeMinute,
        autoResumeAt: autoResumeAt,
        pausedByTimerSessionIds: UnmodifiableListView<String>(
          pausedByTimerSessionIds,
        ),
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}

class NotificationCoordinatorService {
  final Map<String, Future<SubtitleTrack?>> subtitleTrackFutures =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, SubtitleTrack?> subtitleTracks = <String, SubtitleTrack?>{};
  final Map<String, Future<SubtitleTrack?>> subtitleTrackResultFutures =
      <String, Future<SubtitleTrack?>>{};
  final Map<String, String?> notificationSubtitleTexts = <String, String?>{};
  final Map<String, String> notificationSubtitleTrackPaths = <String, String>{};
  final Map<String, Future<String?>> coverPathFutures =
      <String, Future<String?>>{};
  final Map<String, String?> resolvedCoverPaths = <String, String?>{};
  final Map<String, Future<String?>> resolvedCoverPathFutures =
      <String, Future<String?>>{};
  final Map<String, Future<String?>> notificationCoverPathFutures =
      <String, Future<String?>>{};
  final Map<String, String?> resolvedNotificationCoverPaths =
      <String, String?>{};
  final Map<String, Future<String?>> resolvedNotificationCoverPathFutures =
      <String, Future<String?>>{};
  final Set<String> notificationCoverSearchMisses = <String>{};
  String? notificationFocusSessionId;
  String? unifiedNotificationSyncKey;
  Timer? notificationProgressRefreshTimer;
  Timer? unifiedNotificationSyncTimer;
  bool unifiedNotificationSyncInFlight = false;
  bool unifiedNotificationSyncPending = false;
  bool notificationActionRefreshPending = false;
  bool keepAliveSyncDeferred = false;
  String? queuedNotificationRefreshSessionId;
  bool notificationsDismissedWhilePaused = false;
  Timer? deferredWarmupTimer;
  Timer? notificationActionRefreshTimer;
  Timer? notificationActionGuardTimeout;
  final WarmupScheduler warmupScheduler = WarmupScheduler();
  int warmupGeneration = 0;
  final AudioStateSlice<NotificationState> slice =
      AudioStateSlice<NotificationState>(const NotificationState());

  List<PlaybackSession> singleThreadNotificationSessions(
    List<PlaybackSession> activeSessions,
  ) {
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

  List<PlaybackSession> notificationQueueSessions({
    required List<PlaybackSession> activeSessions,
    required bool multiThreadPlaybackEnabled,
  }) {
    return multiThreadPlaybackEnabled
        ? activeSessions
        : singleThreadNotificationSessions(activeSessions);
  }

  PlaybackSession? focusedSessionFrom(Iterable<PlaybackSession> sessions) {
    final focusedId = notificationFocusSessionId;
    if (focusedId != null) {
      for (final session in sessions) {
        if (session.id == focusedId) return session;
      }
    }
    final fallback = sessions.isNotEmpty ? sessions.first : null;
    notificationFocusSessionId = fallback?.id;
    return fallback;
  }

  PlaybackSession? notificationActionSession({
    required List<PlaybackSession> activeSessions,
    required List<PlaybackSession> queueSessions,
  }) {
    final focused = focusedSessionFrom(activeSessions);
    return focused ?? focusedSessionFrom(queueSessions);
  }

  PlaybackSession? resolveNotificationSession({
    required Map<String, PlaybackSession> sessions,
    required List<PlaybackSession> activeSessions,
    required List<PlaybackSession> queueSessions,
    String? sessionId,
  }) {
    if (sessionId != null) {
      final matchedSession = sessions[sessionId];
      if (matchedSession != null) {
        notificationFocusSessionId = matchedSession.id;
        return matchedSession;
      }
    }
    final focusedSession = notificationActionSession(
      activeSessions: activeSessions,
      queueSessions: queueSessions,
    );
    if (focusedSession != null) {
      notificationFocusSessionId = focusedSession.id;
    }
    return focusedSession;
  }

  void beginNotificationAction({
    required VoidCallback notify,
    required VoidCallback flushKeepAliveSync,
    required VoidCallback syncNotificationState,
  }) {
    unifiedNotificationSyncKey = null;
    unifiedNotificationSyncTimer?.cancel();
    unifiedNotificationSyncTimer = null;
    notificationActionRefreshTimer?.cancel();
    notificationActionRefreshTimer = null;
    notificationActionRefreshPending = true;

    notificationActionGuardTimeout?.cancel();
    notificationActionGuardTimeout = Timer(const Duration(seconds: 5), () {
      notificationActionGuardTimeout = null;
      if (notificationActionRefreshPending) {
        debugPrint(
          'AudioProvider: notification action guard timed out, force-clearing',
        );
        notificationActionRefreshPending = false;
        if (keepAliveSyncDeferred) {
          keepAliveSyncDeferred = false;
          flushKeepAliveSync();
        }
        syncNotificationState();
        notify();
      }
    });
  }

  Future<void> guardNotificationAction(
    Future<void> Function() action, {
    required VoidCallback notify,
    required VoidCallback flushKeepAliveSync,
    required VoidCallback syncNotificationState,
  }) async {
    beginNotificationAction(
      notify: notify,
      flushKeepAliveSync: flushKeepAliveSync,
      syncNotificationState: syncNotificationState,
    );
    try {
      await action();
    } finally {
      scheduleNotificationActionRefresh(
        notify: notify,
        flushKeepAliveSync: flushKeepAliveSync,
        syncNotificationState: syncNotificationState,
      );
    }
  }

  void scheduleNotificationActionRefresh({
    required VoidCallback notify,
    required VoidCallback flushKeepAliveSync,
    required VoidCallback syncNotificationState,
  }) {
    notificationActionGuardTimeout?.cancel();
    notificationActionGuardTimeout = null;
    notificationActionRefreshTimer?.cancel();
    notificationActionRefreshTimer = Timer(
      const Duration(milliseconds: 120),
      () {
        notificationActionRefreshTimer = null;
        notificationActionRefreshPending = false;
        if (keepAliveSyncDeferred) {
          keepAliveSyncDeferred = false;
          flushKeepAliveSync();
        }
        syncNotificationState();
        notify();
      },
    );

    notify();
  }

  void bindHandler({
    required PlaybackNotificationService notificationService,
    required Future<void> Function() onPlay,
    required Future<void> Function(String mediaId) onPlayFromMediaId,
    required Future<void> Function() onPause,
    required Future<void> Function() onStop,
    required Future<void> Function() onSkipToNext,
    required Future<void> Function() onSkipToPrevious,
    required Future<void> Function(Duration position) onSeek,
    required Future<void> Function() onTogglePlayPause,
    required Future<void> Function(String sessionId) onToggleSessionPlayback,
    required Future<void> Function(String sessionId) onSkipToPreviousSession,
    required Future<void> Function(String sessionId) onSkipToNextSession,
    required Future<void> Function() onNotificationDeleted,
    required Future<void> Function() onRestoreNotifications,
    required VoidCallback syncNotificationState,
  }) {
    notificationService.bindCallbacks(
      onPlay: onPlay,
      onPlayFromMediaId: onPlayFromMediaId,
      onPause: onPause,
      onStop: onStop,
      onSkipToNext: onSkipToNext,
      onSkipToPrevious: onSkipToPrevious,
      onSeek: onSeek,
      onTogglePlayPause: onTogglePlayPause,
      onToggleSessionPlayback: onToggleSessionPlayback,
      onSkipToPreviousSession: onSkipToPreviousSession,
      onSkipToNextSession: onSkipToNextSession,
      onNotificationDeleted: onNotificationDeleted,
      onRestoreNotifications: onRestoreNotifications,
    );
    syncNotificationState();
  }

  void syncSlice({required int activeQueueLength}) {
    slice.update(
      NotificationState(
        focusedSessionId: notificationFocusSessionId,
        notificationsDismissedWhilePaused: notificationsDismissedWhilePaused,
        notificationActionRefreshPending: notificationActionRefreshPending,
        activeQueueLength: activeQueueLength,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}

class SettingsRepository {
  String converterFormat = 'mp3';
  String converterBitrate = '320k';
  bool multiThreadPlaybackEnabled = false;
  bool notificationsEnabled = true;
  bool showPlaybackCard = true;
  bool autoPlayAddedSessions = true;
  bool isPageTransitioning = false;
  bool keepCpuAwake = false;
  bool keepAliveHasPlayback = false;
  bool keepAliveHasTimer = false;
  bool keepAliveUsesUnifiedNotifications = false;
  bool keepAliveKeepsForegroundService = false;
  final AudioStateSlice<SettingsState> slice = AudioStateSlice<SettingsState>(
    const SettingsState(),
  );

  void syncSlice() {
    slice.update(
      SettingsState(
        converterFormat: converterFormat,
        converterBitrate: converterBitrate,
        multiThreadPlaybackEnabled: multiThreadPlaybackEnabled,
        notificationsEnabled: notificationsEnabled,
        showPlaybackCard: showPlaybackCard,
        autoPlayAddedSessions: autoPlayAddedSessions,
        isPageTransitioning: isPageTransitioning,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
