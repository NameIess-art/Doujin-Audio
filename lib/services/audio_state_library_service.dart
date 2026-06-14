part of 'audio_state_services.dart';

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
  Future<LibraryTreeSnapshot>? libraryTreeBuildFuture;
  int libraryTreeBuildRevision = -1;
  int contentRevision = 0;
  int cachedLibraryLeafFolderCount = 0;
  int libraryBatchDepth = 0;
  bool libraryBatchChanged = false;
  bool libraryBatchChangedGroupOrder = false;
  final List<MusicTrack> libraryBatchPersistTracks = <MusicTrack>[];
  final Map<String, LibraryEntry> libraryBatchPersistEntriesByKey =
      <String, LibraryEntry>{};
  Timer? scanProgressNotifyTimer;
  int structureRevision = 0;
  final AudioStateSlice<LibraryState> slice = AudioStateSlice<LibraryState>(
    const LibraryState(),
  );

  void markStructureChanged() {
    libraryTreeDirty = true;
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      return;
    }
    structureRevision++;
    contentRevision++;
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

  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return LibraryEntrySnapshot(
      libraryPath: normalizedLibraryPath,
      entries:
          libraryEntriesByLibrary[normalizedLibraryPath]?.values ??
          const <LibraryEntry>[],
    );
  }

  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return LibraryExclusionMatcher(
      libraryPath: normalizedLibraryPath,
      excludedTrackPaths:
          excludedLibraryTracks[normalizedLibraryPath] ?? const <String>{},
      excludedFolderPaths:
          excludedLibraryFolders[normalizedLibraryPath] ?? const <String>{},
    );
  }

  LibraryEntry? libraryEntryForPath(String libraryPath, String entryPath) {
    final entries = libraryEntriesByLibrary[PathMatcher.normalize(libraryPath)];
    if (entries == null) return null;
    return entries[PathMatcher.normalize(entryPath)];
  }

  String? libraryEntryDisplayNameForPath(String libraryPath, String entryPath) {
    final displayName = libraryEntryForPath(
      libraryPath,
      entryPath,
    )?.displayName.trim();
    return displayName == null || displayName.isEmpty ? null : displayName;
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
      if (!PathMatcher.isWithinOrEqualNormalized(
        entry.path,
        normalizedFolderPath,
      )) {
        return false;
      }
      final retained = entry.isFolder
          ? retainedPaths.any(
              (path) => PathMatcher.isWithinOrEqualNormalized(path, entry.path),
            )
          : PathMatcher.containsEquivalent(retainedPaths, entry.path);
      if (retained) return false;
      removedPaths.add(entry.path);
      return true;
    });

    if (removedPaths.isNotEmpty) {
      final folders = excludedLibraryFolders[normalizedLibraryPath];
      final tracks = excludedLibraryTracks[normalizedLibraryPath];
      for (final removedPath in removedPaths) {
        if (folders != null) _removePathsWithin(folders, removedPath);
        if (tracks != null) _removePathsWithin(tracks, removedPath);
      }
    }

    return removedPaths;
  }

  List<String> removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    if (entries == null || entries.isEmpty) return const <String>[];
    final normalizedEntryPaths = entryPaths.map(PathMatcher.normalize).toSet();
    if (normalizedEntryPaths.isEmpty) return const <String>[];

    final removedPaths = <String>[];
    entries.removeWhere((entryPath, entry) {
      if (!normalizedEntryPaths.contains(PathMatcher.normalize(entryPath))) {
        return false;
      }
      removedPaths.add(entry.path);
      return true;
    });

    if (removedPaths.isNotEmpty) {
      final folders = excludedLibraryFolders[normalizedLibraryPath];
      final tracks = excludedLibraryTracks[normalizedLibraryPath];
      for (final removedPath in removedPaths) {
        if (folders != null) _removePathsWithin(folders, removedPath);
        if (tracks != null) _removePathsWithin(tracks, removedPath);
      }
    }

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

  void syncSlice({
    required bool isInitialized,
    required int detailRevision,
    int categorySnapshotRevision = 0,
  }) {
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
        contentRevision: contentRevision,
        detailRevision: detailRevision,
        categorySnapshotRevision: categorySnapshotRevision,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
