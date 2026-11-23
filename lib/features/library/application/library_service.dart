import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/state/audio_state_slice.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../domain/library_entry.dart';
import 'library_organizer.dart';
import 'library_track_merge.dart';
import 'library_scan_models.dart';
import 'library_state_models.dart';

class LibraryService {
  static const LibraryOrganizer organizer = LibraryOrganizer();

  static Map<String, T> createPathIndex<T>([Map<String, T>? values]) =>
      HashMap<String, T>(
        equals: PathMatcher.equivalenceEquals,
        hashCode: PathMatcher.equivalenceHashCode,
      )..addAll(values ?? <String, T>{});

  static Set<String> createPathSet([Iterable<String>? values]) =>
      HashSet<String>(
        equals: PathMatcher.equivalenceEquals,
        hashCode: PathMatcher.equivalenceHashCode,
      )..addAll(values ?? const <String>[]);

  List<MusicTrack> library = <MusicTrack>[];
  Map<String, MusicTrack> libraryByPath = createPathIndex<MusicTrack>();

  /// Maps each track path to its index in [library].  Kept in sync by
  /// [rebuildLibraryIndexes] and incremental mutations so [addOrReplaceTracks]
  /// can update existing entries in O(1) instead of O(n).
  Map<String, int> libraryIndexByPath = createPathIndex<int>();
  Map<String, List<MusicTrack>> tracksByGroup = <String, List<MusicTrack>>{};
  final List<String> groupOrder = <String>[];
  final Set<String> groupOrderSet = <String>{};
  final _watchedFolders = LinkedHashSet<String>(
    equals: PathMatcher.equivalenceEquals,
    hashCode: PathMatcher.equivalenceHashCode,
  );
  late final Set<String> watchedFolders = UnmodifiableSetView(_watchedFolders);
  List<String>? _watchedFoldersSnapshot;
  List<String> get watchedFoldersSnapshot =>
      _watchedFoldersSnapshot ??= List.unmodifiable(_watchedFolders);
  final List<String> watchedLibraries = <String>[];
  int _rootIndexGeneration = -1;
  PathRootIndex _watchedFoldersIndex = PathRootIndex(const <String>[]);
  PathRootIndex _watchedLibrariesIndex = PathRootIndex(const <String>[]);
  List<String> _sortedWatchedFoldersCache = const <String>[];
  List<String> _sortedWatchedLibrariesCache = const <String>[];
  Map<String, String> _watchedFolderByPathCache = createPathIndex<String>();
  final Map<String, Set<String>> excludedLibraryFolders =
      createPathIndex<Set<String>>();
  final Map<String, Set<String>> excludedLibraryTracks =
      createPathIndex<Set<String>>();
  final _exclusionMatchers = createPathIndex<LibraryExclusionMatcher>();
  Map<String, Map<String, LibraryEntry>> libraryEntriesByLibrary =
      createPathIndex<Map<String, LibraryEntry>>();
  bool isScanning = false;
  bool isBackgroundScanning = false;
  String scanCurrentFolder = '';
  int scanFoundCount = 0;
  int scanDuplicateCount = 0;
  int scanFailureCount = 0;
  int scanGenerationSeed = 0;
  int scanGeneration = 0;
  FolderScanStage scanStage = FolderScanStage.idle;
  int scanProcessed = 0;
  int? scanTotal;
  int contentRevision = 0;
  int libraryBatchDepth = 0;
  bool libraryBatchChanged = false;
  int libraryDerivedGeneration = 0;
  final List<MusicTrack> libraryBatchPersistTracks = <MusicTrack>[];
  final Map<String, LibraryEntry> libraryBatchPersistEntriesByKey =
      <String, LibraryEntry>{};
  Timer? scanProgressNotifyTimer;
  int structureRevision = 0;
  final AudioStateSlice<LibraryState> slice = AudioStateSlice<LibraryState>(
    const LibraryState(),
  );

  void markStructureChanged() {
    libraryDerivedGeneration++;
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      return;
    }
    structureRevision++;
    contentRevision++;
  }

  void _ensureRootIndexes() {
    if (_rootIndexGeneration == libraryDerivedGeneration) return;
    _watchedFoldersIndex = PathRootIndex(_watchedFolders);
    _watchedLibrariesIndex = PathRootIndex(watchedLibraries);
    _sortedWatchedFoldersCache = _watchedFolders.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    _sortedWatchedLibrariesCache = watchedLibraries.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    final folderByPath = createPathIndex<String>();
    for (final folder in _sortedWatchedFoldersCache) {
      folderByPath.putIfAbsent(folder, () => PathMatcher.normalize(folder));
    }
    _watchedFolderByPathCache = folderByPath;
    _rootIndexGeneration = libraryDerivedGeneration;
  }

  List<String> get sortedWatchedFolders {
    _ensureRootIndexes();
    return _sortedWatchedFoldersCache;
  }

  List<String> get sortedWatchedLibraries {
    _ensureRootIndexes();
    return _sortedWatchedLibrariesCache;
  }

  Map<String, String> get watchedFolderByPath {
    _ensureRootIndexes();
    return _watchedFolderByPathCache;
  }

  PathRootIndex get watchedFoldersIndex {
    _ensureRootIndexes();
    return _watchedFoldersIndex;
  }

  PathRootIndex get watchedLibrariesIndex {
    _ensureRootIndexes();
    return _watchedLibrariesIndex;
  }

  String? mostSpecificWatchedFolder(String value) {
    _ensureRootIndexes();
    return _watchedFoldersIndex.mostSpecificContaining(value);
  }

  String? mostSpecificWatchedLibrary(String value) {
    _ensureRootIndexes();
    return _watchedLibrariesIndex.mostSpecificContaining(value);
  }

  bool containsWatchedLibrary(String value) {
    _ensureRootIndexes();
    return _watchedLibrariesIndex.containsEquivalent(value);
  }

  void replaceWatchedFolders(Iterable<String> folders) {
    _watchedFolders
      ..clear()
      ..addAll(folders);
    _watchedFoldersSnapshot = null;
    _rootIndexGeneration = -1;
  }

  bool addWatchedFolder(String folderPath, {VoidCallback? onPersist}) {
    if (!_watchedFolders.add(folderPath)) return false;
    _watchedFoldersSnapshot = null;
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
    markStructureChanged();
    onPersist?.call();
    return true;
  }

  bool removeWatchedFolder(String folderPath, {VoidCallback? onPersist}) {
    if (!_watchedFolders.remove(folderPath)) return false;
    _watchedFoldersSnapshot = null;
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
    markStructureChanged();
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
    return _exclusionMatchers.putIfAbsent(
      normalizedLibraryPath,
      () => LibraryExclusionMatcher(
        libraryPath: normalizedLibraryPath,
        excludedTrackPaths:
            excludedLibraryTracks[normalizedLibraryPath] ?? const <String>{},
        excludedFolderPaths:
            excludedLibraryFolders[normalizedLibraryPath] ?? const <String>{},
      ),
    );
  }

  void invalidateExclusionMatcher(String libraryPath) =>
      _exclusionMatchers.remove(PathMatcher.normalize(libraryPath));

  void invalidateExclusionMatchers() => _exclusionMatchers.clear();

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
    final matcher = libraryExclusionMatcherForLibrary(normalizedLibraryPath);
    if (!matcher.hasExclusions) return false;
    final normalizedPath = PathMatcher.normalize(entityPath);
    if (matcher.isExcluded(normalizedPath)) return true;
    if (!PathMatcher.isContentUri(normalizedLibraryPath) ||
        !PathMatcher.isContentUri(normalizedPath)) {
      return false;
    }
    return matcher.isEntryExcluded(
      libraryEntryForPath(normalizedLibraryPath, normalizedPath),
      normalizedPath,
    );
  }

  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final matcher = libraryExclusionMatcherForLibrary(normalizedLibraryPath);
    if (!matcher.hasExcludedFolders) return false;
    final normalizedPath = PathMatcher.normalize(entityPath);
    if (matcher.isInheritedExcluded(normalizedPath)) return true;
    if (!PathMatcher.isContentUri(normalizedLibraryPath) ||
        !PathMatcher.isContentUri(normalizedPath)) {
      return false;
    }
    return matcher.isEntryInheritedExcluded(
      libraryEntryForPath(normalizedLibraryPath, normalizedPath),
      normalizedPath,
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

  ({bool changed, List<String> affectedEntryPaths}) setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded, {
    VoidCallback? onPersist,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final folders = excludedLibraryFolders.putIfAbsent(
      normalizedLibraryPath,
      createPathSet,
    );
    final changed = excluded
        ? folders.add(normalizedFolderPath)
        : _removePathsWithin(folders, normalizedFolderPath);
    if (!changed) {
      return (changed: false, affectedEntryPaths: const <String>[]);
    }
    _exclusionMatchers.remove(normalizedLibraryPath);
    if (!excluded) {
      excludedLibraryTracks[normalizedLibraryPath]?.removeWhere(
        (trackPath) => isLibraryEntryWithin(
          libraryEntryForPath(normalizedLibraryPath, trackPath),
          trackPath,
          normalizedFolderPath,
        ),
      );
    }
    final affectedEntryPaths = setLibraryEntriesSubtreeState(
      normalizedLibraryPath,
      normalizedFolderPath,
      excluded ? LibraryEntryState.excluded : LibraryEntryState.active,
    );
    if (affectedEntryPaths.isEmpty) markStructureChanged();
    onPersist?.call();
    return (changed: true, affectedEntryPaths: affectedEntryPaths);
  }

  ({bool changed, List<String> affectedEntryPaths}) setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded, {
    VoidCallback? onPersist,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final tracks = excludedLibraryTracks.putIfAbsent(
      normalizedLibraryPath,
      createPathSet,
    );
    if (excluded && isLibraryPathInheritedExcluded(libraryPath, trackPath)) {
      return (changed: false, affectedEntryPaths: const <String>[]);
    }
    final changed = excluded
        ? tracks.add(normalizedTrackPath)
        : tracks.remove(normalizedTrackPath);
    if (!changed) {
      return (changed: false, affectedEntryPaths: const <String>[]);
    }
    _exclusionMatchers.remove(normalizedLibraryPath);
    final entryChanged = setLibraryEntryState(
      normalizedLibraryPath,
      normalizedTrackPath,
      excluded ? LibraryEntryState.excluded : LibraryEntryState.active,
    );
    if (!entryChanged) markStructureChanged();
    onPersist?.call();
    return (
      changed: true,
      affectedEntryPaths: entryChanged
          ? <String>[normalizedTrackPath]
          : const <String>[],
    );
  }

  LibraryExclusionClearResult clearLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final removedFolders = excludedLibraryFolders.remove(normalizedLibraryPath);
    final removedTracks = excludedLibraryTracks.remove(normalizedLibraryPath);
    _exclusionMatchers.remove(normalizedLibraryPath);
    if ((removedFolders == null || removedFolders.isEmpty) &&
        (removedTracks == null || removedTracks.isEmpty)) {
      return const LibraryExclusionClearResult();
    }
    final restoredEntryPaths = setLibraryEntriesSubtreeState(
      normalizedLibraryPath,
      normalizedLibraryPath,
      LibraryEntryState.active,
    );
    final restoredTracks = libraryEntriesForLibrary(normalizedLibraryPath)
        .where(
          (entry) => entry.isTrack && !libraryByPath.containsKey(entry.path),
        )
        .map((entry) => entry.toTrack())
        .toList(growable: false);
    return LibraryExclusionClearResult(
      changed: true,
      restoredEntryPaths: restoredEntryPaths,
      restoredTracks: restoredTracks,
    );
  }

  LibraryFolderRetargetResult retargetLibraryFolder(
    String oldFolderPath,
    String newFolderPath,
    String folderName, {
    String? libraryRootPath,
    Iterable<MusicTrack> retainedTracks = const [],
  }) {
    final oldRoot = PathMatcher.normalize(oldFolderPath);
    final newRoot = PathMatcher.normalize(newFolderPath);
    final oldLibraryRoot = PathMatcher.normalize(libraryRootPath ?? oldRoot);
    final newLibraryRoot = PathMatcher.equalsNormalized(oldLibraryRoot, oldRoot)
        ? newRoot
        : oldLibraryRoot;
    final retargetedTracks = createPathIndex<MusicTrack>();
    final activeRetargeted = <({int index, MusicTrack oldTrack, MusicTrack nextTrack})>[];
    final affectedGroups = <String>{};

    MusicTrack retargetTrack(MusicTrack track) {
      final nextTrackPath = _replacePathPrefix(track.path, oldRoot, newRoot);
      final nextGroupKey = PathMatcher.isWithinOrEqual(track.groupKey, oldRoot)
          ? _replacePathPrefix(track.groupKey, oldRoot, newRoot)
          : track.groupKey;
      return _copyTrackForRetarget(
        track,
        path: nextTrackPath,
        groupKey: nextGroupKey,
        groupTitle: PathMatcher.equalsNormalized(nextGroupKey, newRoot)
            ? folderName
            : PathDisplay.folderName(nextGroupKey),
        groupSubtitle: PathDisplay.displayPathFor(nextGroupKey),
        coverCachePath: _retargetNullablePath(
          track.coverCachePath,
          oldRoot,
          newRoot,
        ),
        lyricsPath: _retargetNullablePath(track.lyricsPath, oldRoot, newRoot),
        manualCoverPath: _retargetNullablePath(
          track.manualCoverPath,
          oldRoot,
          newRoot,
        ),
      );
    }

    for (var i = 0; i < library.length; i++) {
      final track = library[i];
      if (!PathMatcher.isWithinOrEqual(track.path, oldRoot)) continue;
      final updatedTrack = retargetTrack(track);
      library[i] = updatedTrack;
      retargetedTracks[track.path] = updatedTrack;
      activeRetargeted.add((index: i, oldTrack: track, nextTrack: updatedTrack));
      affectedGroups
        ..add(track.groupKey)
        ..add(updatedTrack.groupKey);
    }
    for (final track in retainedTracks) {
      if (retargetedTracks.containsKey(track.path) ||
          !PathMatcher.isWithinOrEqual(track.path, oldRoot)) {
        continue;
      }
      retargetedTracks[track.path] = retargetTrack(track);
    }

    // Update path indexes incrementally for moved active tracks.
    for (final item in activeRetargeted) {
      libraryByPath.remove(item.oldTrack.path);
      libraryIndexByPath.remove(item.oldTrack.path);
    }
    for (final item in activeRetargeted) {
      libraryByPath[item.nextTrack.path] = item.nextTrack;
      libraryIndexByPath[item.nextTrack.path] = item.index;
    }

    // Incrementally rebuild and sort only the affected track groups.
    if (affectedGroups.isNotEmpty) {
      final rebuiltGroups = <String, List<MusicTrack>>{};
      for (final group in affectedGroups) {
        final existing = tracksByGroup.remove(group);
        if (existing == null) continue;
        final surviving = <MusicTrack>[
          for (final track in existing)
            if (!retargetedTracks.containsKey(track.path)) track,
        ];
        if (surviving.isNotEmpty) rebuiltGroups[group] = surviving;
      }
      for (final item in activeRetargeted) {
        rebuiltGroups
            .putIfAbsent(item.nextTrack.groupKey, () => <MusicTrack>[])
            .add(item.nextTrack);
      }
      for (final entry in rebuiltGroups.entries) {
        entry.value.sort(compareTracks);
        tracksByGroup[entry.key] = List<MusicTrack>.unmodifiable(entry.value);
      }
    }

    List<String> retargetRoots(Iterable<String> roots) {
      final seen = <String>{};
      final migrated = <String>[];
      for (final root in roots) {
        final next = PathMatcher.replaceWithinOrEqual(root, oldRoot, newRoot);
        if (seen.add(PathMatcher.equivalenceKey(next))) migrated.add(next);
      }
      return migrated;
    }

    final nextFolders = retargetRoots(watchedFolders);
    final nextLibraries = retargetRoots(watchedLibraries);
    replaceWatchedFolders(nextFolders);
    watchedLibraries
      ..clear()
      ..addAll(nextLibraries);
    for (var i = 0; i < groupOrder.length; i++) {
      if (PathMatcher.isWithinOrEqual(groupOrder[i], oldRoot)) {
        groupOrder[i] = _replacePathPrefix(groupOrder[i], oldRoot, newRoot);
      }
    }

    _retargetLibraryExclusions(oldRoot, newRoot);
    final entryRetarget = _retargetLibraryEntries(
      oldRoot,
      newRoot,
      folderName,
      oldLibraryRoot: oldLibraryRoot,
      newLibraryRoot: newLibraryRoot,
    );
    _syncGroupOrderFromTrackedGroups();
    markStructureChanged();
    return LibraryFolderRetargetResult(
      retargetedTracks: retargetedTracks,
      retargetedEntries: entryRetarget.retargetedEntries,
      removedEntryPaths: entryRetarget.removedEntryPaths,
    );
  }

  void _syncGroupOrderFromTrackedGroups() {
    final activeGroupKeys = tracksByGroup.keys.toSet();
    final nextOrder = <String>[];
    final seen = <String>{};
    for (final groupKey in groupOrder) {
      if (activeGroupKeys.contains(groupKey) && seen.add(groupKey)) {
        nextOrder.add(groupKey);
      }
    }
    for (final groupKey in activeGroupKeys) {
      if (seen.add(groupKey)) nextOrder.add(groupKey);
    }
    groupOrder
      ..clear()
      ..addAll(nextOrder);
    groupOrderSet
      ..clear()
      ..addAll(nextOrder);
  }

  LibraryTrackRetargetResult retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName, {
    MusicTrack? retainedTrack,
  }) {
    final oldPath = PathMatcher.normalize(oldTrackPath);
    final newPath = PathMatcher.normalize(newTrackPath);
    final retargetedEntries = <LibraryEntry>[];
    final removedEntryPathsByLibrary = <String, List<String>>{};
    for (final libraryEntry in libraryEntriesByLibrary.entries) {
      final entries = libraryEntry.value;
      final entry = entries.remove(oldPath);
      if (entry == null) continue;
      final updatedEntry = entry.copyWith(
        path: newPath,
        displayName: displayName,
      );
      entries[newPath] = updatedEntry;
      retargetedEntries.add(updatedEntry);
      removedEntryPathsByLibrary[libraryEntry.key] = <String>[entry.path];
    }
    for (final excluded in excludedLibraryTracks.values) {
      if (excluded.remove(oldPath)) excluded.add(newPath);
    }
    invalidateExclusionMatchers();
    final track = libraryByPath[oldPath] ?? retainedTrack;
    if (track == null) {
      markStructureChanged();
      return LibraryTrackRetargetResult(
        retargetedEntries: retargetedEntries,
        removedEntryPathsByLibrary: removedEntryPathsByLibrary,
      );
    }
    final originalTrackPath = track.path;
    final updatedTrack = _copyTrackForRetarget(
      track,
      path: newPath,
      displayName: displayName,
    );
    final mappedIndex = libraryIndexByPath[oldPath];
    final index =
        mappedIndex != null &&
            mappedIndex < library.length &&
            PathMatcher.equalsNormalized(library[mappedIndex].path, oldPath)
        ? mappedIndex
        : library.indexWhere(
            (item) => PathMatcher.equalsNormalized(item.path, oldPath),
          );
    if (index >= 0) {
      library[index] = updatedTrack;
      libraryByPath.remove(oldPath);
      libraryIndexByPath.remove(oldPath);
      libraryByPath[newPath] = updatedTrack;
      libraryIndexByPath[newPath] = index;
      final groupTracks = tracksByGroup[updatedTrack.groupKey];
      if (groupTracks != null) {
        final nextGroup = <MusicTrack>[
          for (final item in groupTracks)
            if (PathMatcher.equalsNormalized(item.path, oldPath))
              updatedTrack
            else
              item,
        ]..sort(compareTracks);
        tracksByGroup[updatedTrack.groupKey] = List<MusicTrack>.unmodifiable(
          nextGroup,
        );
      } else {
        tracksByGroup[updatedTrack.groupKey] = List<MusicTrack>.unmodifiable([
          updatedTrack,
        ]);
      }
    }
    markStructureChanged();
    return LibraryTrackRetargetResult(
      originalTrackPath: originalTrackPath,
      updatedTrack: updatedTrack,
      retargetedEntries: retargetedEntries,
      removedEntryPathsByLibrary: removedEntryPathsByLibrary,
    );
  }

  void _retargetLibraryExclusions(String oldRoot, String newRoot) {
    Map<String, Set<String>> retarget(Map<String, Set<String>> source) {
      final result = createPathIndex<Set<String>>();
      for (final entry in source.entries) {
        final nextKey = PathMatcher.equalsNormalized(entry.key, oldRoot)
            ? newRoot
            : entry.key;
        final nextValues = createPathSet(
          entry.value.map(
            (value) => PathMatcher.isWithinOrEqual(value, oldRoot)
                ? _replacePathPrefix(value, oldRoot, newRoot)
                : value,
          ),
        );
        result.putIfAbsent(nextKey, createPathSet).addAll(nextValues);
      }
      return result;
    }

    final nextFolderExclusions = retarget(excludedLibraryFolders);
    final nextTrackExclusions = retarget(excludedLibraryTracks);
    excludedLibraryFolders
      ..clear()
      ..addAll(nextFolderExclusions);
    excludedLibraryTracks
      ..clear()
      ..addAll(nextTrackExclusions);
    invalidateExclusionMatchers();
  }

  ({List<LibraryEntry> retargetedEntries, List<String> removedEntryPaths})
  _retargetLibraryEntries(
    String oldRoot,
    String newRoot,
    String folderName, {
    required String oldLibraryRoot,
    required String newLibraryRoot,
  }) {
    final existingEntries = libraryEntriesByLibrary[oldLibraryRoot];
    if (existingEntries == null || existingEntries.isEmpty) {
      return (
        retargetedEntries: const <LibraryEntry>[],
        removedEntryPaths: const <String>[],
      );
    }
    final rootChanged = !PathMatcher.equalsNormalized(
      oldLibraryRoot,
      newLibraryRoot,
    );
    if (rootChanged) {
      libraryEntriesByLibrary.remove(oldLibraryRoot);
      final removedPaths = <String>[];
      final retargetedEntries = <LibraryEntry>[];
      final nextEntries = createPathIndex<LibraryEntry>();
      for (final entry in existingEntries.values) {
        removedPaths.add(entry.path);
        final updated = _retargetLibraryEntry(
          entry,
          oldRoot: oldRoot,
          newRoot: newRoot,
          folderName: folderName,
          libraryPath: newLibraryRoot,
        );
        retargetedEntries.add(updated);
        nextEntries[updated.path] = updated;
      }
      libraryEntriesByLibrary[newLibraryRoot] = nextEntries;
      return (
        retargetedEntries: retargetedEntries,
        removedEntryPaths: removedPaths,
      );
    }

    // Subfolder rename within the same library root: only mutate affected rows.
    final changedEntries = <LibraryEntry>[];
    final removedPaths = <String>[];
    final toUpdate = <({String oldPath, LibraryEntry next})>[];
    for (final entry in existingEntries.values) {
      final pathMatches = PathMatcher.isWithinOrEqual(entry.path, oldRoot);
      final parentMatches =
          entry.parentPath != null &&
          PathMatcher.isWithinOrEqual(entry.parentPath!, oldRoot);
      final groupMatches =
          !entry.isFolder &&
          PathMatcher.isWithinOrEqual(entry.groupKey, oldRoot);
      if (!pathMatches && !parentMatches && !groupMatches) continue;
      final updated = _retargetLibraryEntry(
        entry,
        oldRoot: oldRoot,
        newRoot: newRoot,
        folderName: folderName,
        libraryPath: newLibraryRoot,
      );
      toUpdate.add((oldPath: entry.path, next: updated));
      changedEntries.add(updated);
      if (entry.path != updated.path) {
        removedPaths.add(entry.path);
      }
    }
    for (final item in toUpdate) {
      existingEntries.remove(item.oldPath);
    }
    for (final item in toUpdate) {
      existingEntries[item.next.path] = item.next;
    }
    return (
      retargetedEntries: changedEntries,
      removedEntryPaths: removedPaths,
    );
  }

  LibraryEntry _retargetLibraryEntry(
    LibraryEntry entry, {
    required String oldRoot,
    required String newRoot,
    required String folderName,
    required String libraryPath,
  }) {
    final nextPath = PathMatcher.isWithinOrEqual(entry.path, oldRoot)
        ? _replacePathPrefix(entry.path, oldRoot, newRoot)
        : entry.path;
    final nextParentPath =
        entry.parentPath != null &&
            PathMatcher.isWithinOrEqual(entry.parentPath!, oldRoot)
        ? _replacePathPrefix(entry.parentPath!, oldRoot, newRoot)
        : entry.parentPath;
    if (entry.isFolder) {
      return LibraryEntry.folder(
        libraryPath: libraryPath,
        path: nextPath,
        parentPath: nextParentPath,
        state: entry.state,
        displayName: PathMatcher.equalsNormalized(entry.path, oldRoot)
            ? folderName
            : entry.displayName,
      );
    }
    final nextGroupKey = PathMatcher.isWithinOrEqual(entry.groupKey, oldRoot)
        ? _replacePathPrefix(entry.groupKey, oldRoot, newRoot)
        : entry.groupKey;
    return LibraryEntry(
      libraryPath: libraryPath,
      path: nextPath,
      kind: entry.kind,
      state: entry.state,
      parentPath: nextParentPath,
      displayName: entry.displayName,
      groupKey: nextGroupKey,
      groupTitle: PathMatcher.equalsNormalized(nextGroupKey, newRoot)
          ? folderName
          : PathDisplay.folderName(nextGroupKey),
      groupSubtitle: PathDisplay.displayPathFor(nextGroupKey),
      isSingle: entry.isSingle,
      isVideo: entry.isVideo,
      scannedAt: entry.scannedAt,
      fileSizeBytes: entry.fileSizeBytes,
      modifiedAt: entry.modifiedAt,
    );
  }

  String? _retargetNullablePath(String? value, String oldRoot, String newRoot) {
    if (value == null || !PathMatcher.isWithinOrEqual(value, oldRoot)) {
      return value;
    }
    return _replacePathPrefix(value, oldRoot, newRoot);
  }

  String _replacePathPrefix(String value, String oldRoot, String newRoot) {
    return PathMatcher.replaceWithinOrEqual(value, oldRoot, newRoot);
  }

  MusicTrack _copyTrackForRetarget(
    MusicTrack track, {
    required String path,
    String? displayName,
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    String? coverCachePath,
    String? lyricsPath,
    String? manualCoverPath,
  }) {
    return MusicTrack(
      path: path,
      displayName: displayName ?? track.displayName,
      groupKey: groupKey ?? track.groupKey,
      groupTitle: groupTitle ?? track.groupTitle,
      groupSubtitle: groupSubtitle ?? track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
      lastPlayedPosition: track.lastPlayedPosition,
      lastPlayedAt: track.lastPlayedAt,
      isFavorite: track.isFavorite,
      tags: track.tags,
      coverCachePath: coverCachePath ?? track.coverCachePath,
      lyricsPath: lyricsPath ?? track.lyricsPath,
      manualCoverPath: manualCoverPath ?? track.manualCoverPath,
      remoteCoverUrl: track.remoteCoverUrl,
      remoteMetadataKind: track.remoteMetadataKind,
      remoteMetadata: track.remoteMetadata,
      duration: track.duration,
    );
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
        createPathIndex<LibraryEntry>,
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
    invalidateExclusionMatchers();
    excludedLibraryFolders.clear();
    excludedLibraryTracks.clear();
    for (final entry in entries) {
      if (!entry.isExcluded) continue;
      final lib = PathMatcher.normalize(entry.libraryPath);
      final p = PathMatcher.normalize(entry.path);
      if (entry.isFolder) {
        excludedLibraryFolders.putIfAbsent(lib, createPathSet).add(p);
      } else {
        excludedLibraryTracks.putIfAbsent(lib, createPathSet).add(p);
      }
    }
  }

  LibraryExclusionSnapshot snapshotLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return LibraryExclusionSnapshot(
      libraryPath: normalizedLibraryPath,
      excludedFolders: List<String>.unmodifiable(
        excludedLibraryFolders[normalizedLibraryPath] ?? const <String>{},
      ),
      excludedTracks: List<String>.unmodifiable(
        excludedLibraryTracks[normalizedLibraryPath] ?? const <String>{},
      ),
      entries: List<LibraryEntry>.unmodifiable(
        libraryEntriesForLibrary(
          normalizedLibraryPath,
        ).map((entry) => entry.copyWith()),
      ),
    );
  }

  ({List<String> excludedEntryPaths, List<String> activeEntryPaths})
  restoreLibraryExclusions(LibraryExclusionSnapshot snapshot) {
    final normalizedLibraryPath = PathMatcher.normalize(snapshot.libraryPath);
    _exclusionMatchers.remove(normalizedLibraryPath);
    if (snapshot.excludedFolders.isEmpty) {
      excludedLibraryFolders.remove(normalizedLibraryPath);
    } else {
      excludedLibraryFolders[normalizedLibraryPath] = createPathSet(
        snapshot.excludedFolders,
      );
    }
    if (snapshot.excludedTracks.isEmpty) {
      excludedLibraryTracks.remove(normalizedLibraryPath);
    } else {
      excludedLibraryTracks[normalizedLibraryPath] = createPathSet(
        snapshot.excludedTracks,
      );
    }

    final excludedEntryPaths = <String>[];
    final activeEntryPaths = <String>[];
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    if (entries != null && snapshot.entries.isNotEmpty) {
      for (final previous in snapshot.entries) {
        final normalizedPath = PathMatcher.normalize(previous.path);
        final current = entries[normalizedPath];
        if (current == null || current.state == previous.state) continue;
        entries[normalizedPath] = current.copyWith(state: previous.state);
        if (previous.isExcluded) {
          excludedEntryPaths.add(current.path);
        } else {
          activeEntryPaths.add(current.path);
        }
      }
    }
    if (excludedEntryPaths.isNotEmpty ||
        activeEntryPaths.isNotEmpty ||
        snapshot.excludedFolders.isNotEmpty ||
        snapshot.excludedTracks.isNotEmpty) {
      markStructureChanged();
    }
    return (
      excludedEntryPaths: excludedEntryPaths,
      activeEntryPaths: activeEntryPaths,
    );
  }

  List<String> removeLibraryEntriesMissingFromFolderScan(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths, {
    void Function(LibraryEntry entry)? onRemoved,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final entries = libraryEntriesByLibrary[normalizedLibraryPath];
    if (entries == null || entries.isEmpty) return const <String>[];
    final retainedPathIndex = PathMembershipIndex(retainedPaths);

    final removedPaths = <String>[];
    entries.removeWhere((entryPath, entry) {
      if (!isLibraryEntryWithin(entry, entry.path, normalizedFolderPath)) {
        return false;
      }
      final retained = entry.isFolder
          ? retainedPathIndex.containsDescendantOrEqual(entry.path)
          : retainedPathIndex.containsEquivalent(entry.path);
      if (retained) return false;
      onRemoved?.call(entry);
      removedPaths.add(entry.path);
      return true;
    });

    if (removedPaths.isNotEmpty) {
      _removeExclusionsWithinRemovedPaths(normalizedLibraryPath, removedPaths);
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
    final removedPaths = <String>[];
    for (final path in entryPaths) {
      if (entries.remove(path) case final entry?) {
        removedPaths.add(entry.path);
      }
    }

    if (removedPaths.isNotEmpty) {
      _removeExclusionsWithinRemovedPaths(normalizedLibraryPath, removedPaths);
    }

    return removedPaths;
  }

  void _removeExclusionsWithinRemovedPaths(
    String normalizedLibraryPath,
    List<String> removedPaths,
  ) {
    _exclusionMatchers.remove(normalizedLibraryPath);
    final folders = excludedLibraryFolders[normalizedLibraryPath];
    final tracks = excludedLibraryTracks[normalizedLibraryPath];
    final hasFolders = folders != null && folders.isNotEmpty;
    final hasTracks = tracks != null && tracks.isNotEmpty;
    if (!hasFolders && !hasTracks) return;
    if (removedPaths.length == 1) {
      final removedPath = removedPaths.first;
      if (hasFolders) _removePathsWithin(folders, removedPath);
      if (hasTracks) _removePathsWithin(tracks, removedPath);
      return;
    }
    final removedIndex = PathMembershipIndex(removedPaths);
    if (hasFolders) {
      folders.removeWhere(removedIndex.containsAncestorOrEqual);
    }
    if (hasTracks) {
      tracks.removeWhere(removedIndex.containsAncestorOrEqual);
    }
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
    for (final entry in entries.values) {
      if (!isLibraryEntryWithin(entry, entry.path, normalizedRootPath)) {
        continue;
      }
      if (entry.state == state) continue;
      changedPaths.add(entry.path);
    }
    for (final entryPath in changedPaths) {
      final entry = entries[entryPath];
      if (entry != null) entries[entryPath] = entry.copyWith(state: state);
    }
    if (changedPaths.isNotEmpty) {
      markStructureChanged();
    }
    return changedPaths;
  }

  bool isLibraryEntryWithin(
    LibraryEntry? entry,
    String entryPath,
    String rootPath,
  ) {
    if (PathMatcher.isWithinOrEqual(entryPath, rootPath)) return true;
    if (entry == null ||
        !entry.isTrack ||
        !PathMatcher.hasSameContentTree(entry.path, entry.libraryPath)) {
      return false;
    }
    return PathMatcher.isWithinOrEqual(
      entry.parentPath ?? entry.libraryPath,
      rootPath,
    );
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

  String? libraryRootForPath(String entityPath) {
    return mostSpecificWatchedLibrary(entityPath) ??
        mostSpecificWatchedFolder(entityPath);
  }

  int compareTracks(MusicTrack first, MusicTrack second) {
    return organizer.compareTracks(first, second);
  }

  bool fillMissingTrackDurations(
    Map<String, Duration> durations, {
    bool notifyStructure = true,
  }) {
    final changedTracks = <String, MusicTrack>{};
    final changedGroups = <String>{};
    for (final entry in durations.entries) {
      final current = libraryByPath[entry.key];
      final index = libraryIndexByPath[entry.key];
      if (current == null ||
          index == null ||
          current.duration > Duration.zero ||
          index >= library.length ||
          !identical(library[index], current)) {
        continue;
      }
      final next = current.copyWith(duration: entry.value);
      library[index] = next;
      libraryByPath[current.path] = next;
      changedTracks[current.path] = next;
      changedGroups.add(current.groupKey);
    }
    if (changedTracks.isEmpty) return false;
    // Duration does not change group membership or track order.
    for (final group in changedGroups) {
      final tracks = tracksByGroup[group];
      if (tracks == null) continue;
      tracksByGroup[group] = List<MusicTrack>.unmodifiable(
        tracks.map((track) => changedTracks[track.path] ?? track),
      );
    }
    if (notifyStructure) markStructureChanged();
    return true;
  }

  void rebuildLibraryIndexes() {
    final nextTracksByGroup = <String, List<MusicTrack>>{};
    libraryByPath.clear();
    libraryIndexByPath.clear();
    for (var index = 0; index < library.length; index++) {
      final track = library[index];
      libraryByPath[track.path] = track;
      libraryIndexByPath[track.path] = index;
      nextTracksByGroup
          .putIfAbsent(track.groupKey, () => <MusicTrack>[])
          .add(track);
    }
    for (final entry in nextTracksByGroup.entries) {
      entry.value.sort(compareTracks);
    }
    tracksByGroup
      ..clear()
      ..addAll(
        nextTracksByGroup.map(
          (groupKey, tracks) =>
              MapEntry(groupKey, List<MusicTrack>.unmodifiable(tracks)),
        ),
      );
    groupOrderSet
      ..clear()
      ..addAll(groupOrder);
    markStructureChanged();
  }

  void syncGroupOrderFromLibrary() {
    final activeGroupKeys = library.map((track) => track.groupKey).toSet();
    groupOrder.removeWhere((groupKey) => !activeGroupKeys.contains(groupKey));
    groupOrderSet
      ..clear()
      ..addAll(groupOrder);
    for (final groupKey in activeGroupKeys) {
      if (groupOrderSet.add(groupKey)) groupOrder.add(groupKey);
    }
  }

  void _updateTracksByGroupIncremental({
    required Set<String> affectedGroups,
    Map<String, List<MusicTrack>> upsertedByGroup =
        const <String, List<MusicTrack>>{},
    Set<String> excludedPaths = const <String>{},
  }) {
    for (final groupKey in affectedGroups) {
      final existing = tracksByGroup[groupKey];
      final upserted = upsertedByGroup[groupKey];
      final nextBucket = <MusicTrack>[];
      if (existing != null) {
        if (excludedPaths.isEmpty) {
          nextBucket.addAll(existing);
        } else {
          for (final track in existing) {
            if (!excludedPaths.contains(track.path)) {
              nextBucket.add(track);
            }
          }
        }
      }
      if (upserted != null) {
        nextBucket.addAll(upserted);
      }
      if (nextBucket.isEmpty) {
        tracksByGroup.remove(groupKey);
      } else {
        nextBucket.sort(compareTracks);
        tracksByGroup[groupKey] = List<MusicTrack>.unmodifiable(nextBucket);
      }
    }
    markStructureChanged();
  }

  ({List<MusicTrack> tracks, bool didChangeGroupOrder, bool batched}) addTracks(
    List<MusicTrack> newTracks, {
    required bool persist,
  }) {
    final addedTracks = <MusicTrack>[];
    var didChangeGroupOrder = false;
    for (final track in newTracks) {
      if (libraryByPath.containsKey(track.path)) continue;
      libraryIndexByPath[track.path] = library.length;
      library.add(track);
      libraryByPath[track.path] = track;
      addedTracks.add(track);
      if (groupOrderSet.add(track.groupKey)) {
        groupOrder.add(track.groupKey);
        didChangeGroupOrder = true;
      }
    }
    if (addedTracks.isEmpty) {
      return (
        tracks: const <MusicTrack>[],
        didChangeGroupOrder: false,
        batched: false,
      );
    }
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      if (persist) libraryBatchPersistTracks.addAll(addedTracks);
      return (
        tracks: addedTracks,
        didChangeGroupOrder: didChangeGroupOrder,
        batched: true,
      );
    }
    if (tracksByGroup.isEmpty && library.length > addedTracks.length) {
      rebuildLibraryIndexes();
    } else {
      final affectedGroups = <String>{};
      final addedByGroup = <String, List<MusicTrack>>{};
      for (final track in addedTracks) {
        affectedGroups.add(track.groupKey);
        addedByGroup
            .putIfAbsent(track.groupKey, () => <MusicTrack>[])
            .add(track);
      }
      _updateTracksByGroupIncremental(
        affectedGroups: affectedGroups,
        upsertedByGroup: addedByGroup,
      );
    }
    return (
      tracks: addedTracks,
      didChangeGroupOrder: didChangeGroupOrder,
      batched: false,
    );
  }

  ({
    List<MusicTrack> tracks,
    bool didChangeGroupOrder,
    bool didReplaceGroup,
    bool batched,
  })
  addOrReplaceTracks(
    List<MusicTrack> tracks, {
    required bool persist,
    bool mergeExistingState = true,
  }) {
    var didChangeGroupOrder = false;
    var didReplaceGroup = false;
    final changedTracks = <MusicTrack>[];
    final affectedGroups = <String>{};
    final upsertedByGroup = <String, List<MusicTrack>>{};
    final replacedPaths = createPathSet();
    final hadExistingTracks = library.isNotEmpty;

    for (final track in tracks) {
      final existing = libraryByPath[track.path];
      var nextTrack = existing == null || !mergeExistingState
          ? track
          : mergeLibraryTrackState(existing, track);
      if (existing != null && nextTrack.path != existing.path) {
        nextTrack = _copyTrackForRetarget(nextTrack, path: existing.path);
      }
      if (existing != null &&
          mergeExistingState &&
          !mergedLibraryTrackHasChanges(existing, track)) {
        continue;
      }
      if (existing != null) {
        affectedGroups.add(existing.groupKey);
        replacedPaths.add(existing.path);
        if (existing.groupKey != nextTrack.groupKey) {
          didReplaceGroup = true;
        }
      }
      if (existing == null) {
        libraryIndexByPath[nextTrack.path] = library.length;
        library.add(nextTrack);
      } else {
        final index = libraryIndexByPath[nextTrack.path];
        if (index != null &&
            index < library.length &&
            library[index].path == nextTrack.path) {
          library[index] = nextTrack;
        } else {
          final fallbackIndex = library.indexWhere(
            (item) => item.path == nextTrack.path,
          );
          if (fallbackIndex >= 0) {
            library[fallbackIndex] = nextTrack;
            libraryIndexByPath[nextTrack.path] = fallbackIndex;
          } else {
            libraryIndexByPath[nextTrack.path] = library.length;
            library.add(nextTrack);
          }
        }
      }
      libraryByPath[nextTrack.path] = nextTrack;
      changedTracks.add(nextTrack);
      affectedGroups.add(nextTrack.groupKey);
      upsertedByGroup
          .putIfAbsent(nextTrack.groupKey, () => <MusicTrack>[])
          .add(nextTrack);
      if (groupOrderSet.add(nextTrack.groupKey)) {
        groupOrder.add(nextTrack.groupKey);
        didChangeGroupOrder = true;
      }
    }

    if (changedTracks.isEmpty) {
      return (
        tracks: const <MusicTrack>[],
        didChangeGroupOrder: false,
        didReplaceGroup: false,
        batched: false,
      );
    }
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      if (persist) libraryBatchPersistTracks.addAll(changedTracks);
      return (
        tracks: changedTracks,
        didChangeGroupOrder: didChangeGroupOrder,
        didReplaceGroup: didReplaceGroup,
        batched: true,
      );
    }
    if (hadExistingTracks && tracksByGroup.isEmpty) {
      rebuildLibraryIndexes();
      syncGroupOrderFromLibrary();
    } else {
      _updateTracksByGroupIncremental(
        affectedGroups: affectedGroups,
        upsertedByGroup: upsertedByGroup,
        excludedPaths: replacedPaths,
      );
      if (didReplaceGroup) {
        groupOrder.removeWhere((key) => !tracksByGroup.containsKey(key));
        groupOrderSet
          ..clear()
          ..addAll(groupOrder);
      }
    }
    return (
      tracks: changedTracks,
      didChangeGroupOrder: didChangeGroupOrder,
      didReplaceGroup: didReplaceGroup,
      batched: false,
    );
  }

  ({List<MusicTrack> tracks, bool batched}) removeTracksWhere(
    bool Function(MusicTrack track) test,
  ) {
    final removedTracks = <MusicTrack>[];
    var firstRemovedIndex = -1;
    for (var i = 0; i < library.length; i++) {
      final track = library[i];
      if (test(track)) {
        if (firstRemovedIndex < 0) firstRemovedIndex = i;
        removedTracks.add(track);
      }
    }
    if (removedTracks.isEmpty) {
      return (tracks: const <MusicTrack>[], batched: false);
    }
    final removedPaths = createPathSet(
      removedTracks.map((track) => track.path),
    );
    final affectedGroups = <String>{
      for (final track in removedTracks) track.groupKey,
    };
    library.removeWhere((track) => removedPaths.contains(track.path));
    for (final trackPath in removedPaths) {
      libraryByPath.remove(trackPath);
      libraryIndexByPath.remove(trackPath);
    }
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      return (tracks: removedTracks, batched: true);
    }
    if (tracksByGroup.isEmpty || removedTracks.length * 4 >= library.length) {
      rebuildLibraryIndexes();
    } else {
      for (var i = firstRemovedIndex; i < library.length; i++) {
        libraryIndexByPath[library[i].path] = i;
      }
      _updateTracksByGroupIncremental(
        affectedGroups: affectedGroups,
        excludedPaths: removedPaths,
      );
    }
    return (tracks: removedTracks, batched: false);
  }

  List<LibraryEntry> buildLibraryEntries(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    LibraryExclusionMatcher? exclusionMatcher,
  }) => organizer.buildLibraryEntries(
    libraryPath,
    tracks,
    folderPaths: folderPaths,
    exclusionMatcher:
        exclusionMatcher ??
        libraryExclusionMatcherForLibrary(PathMatcher.normalize(libraryPath)),
  );

  String? libraryPathForTrack(MusicTrack track) {
    return mostSpecificWatchedLibrary(track.path) ??
        (track.groupKey.isEmpty
            ? null
            : mostSpecificWatchedLibrary(track.groupKey)) ??
        mostSpecificWatchedFolder(track.path) ??
        (track.groupKey.isEmpty
            ? null
            : mostSpecificWatchedFolder(track.groupKey));
  }

  String? folderPathForLibraryTrack(String libraryPath, MusicTrack track) =>
      organizer.folderPathForLibraryTrack(libraryPath, track);

  String canonicalLibraryFolderPath(String libraryPath, String folderPath) =>
      organizer.canonicalLibraryFolderPath(libraryPath, folderPath);

  String? parentLibraryFolderPath(String folderPath, String rootPath) =>
      organizer.parentLibraryFolderPath(folderPath, rootPath);

  ({bool changed, List<String> removedFolderPaths}) removeLibrary(
    String libraryPath, {
    VoidCallback? onSaveWatchedFolders,
    VoidCallback? onSaveWatchedLibraries,
    VoidCallback? onSaveLibraryExclusions,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final childFolders = watchedFolders
        .where(
          (folderPath) => PathMatcher.isWithinOrEqualNormalized(
            PathMatcher.normalize(folderPath),
            normalizedLibraryPath,
          ),
        )
        .toList(growable: false);
    final watchedLibraryCount = watchedLibraries.length;
    final hadFolderExclusions = excludedLibraryFolders.containsKey(
      normalizedLibraryPath,
    );
    final hadTrackExclusions = excludedLibraryTracks.containsKey(
      normalizedLibraryPath,
    );
    final hadEntries = libraryEntriesByLibrary.containsKey(
      normalizedLibraryPath,
    );
    if (childFolders.isNotEmpty) {
      _watchedFolders.removeAll(childFolders);
      _watchedFoldersSnapshot = null;
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
    _exclusionMatchers.remove(normalizedLibraryPath);
    libraryEntriesByLibrary.removeWhere(
      (pathValue, _) =>
          PathMatcher.equalsNormalized(pathValue, normalizedLibraryPath),
    );
    final changed =
        childFolders.isNotEmpty ||
        watchedLibraries.length != watchedLibraryCount ||
        hadFolderExclusions ||
        hadTrackExclusions ||
        hadEntries;
    if (!changed) {
      return (changed: false, removedFolderPaths: const <String>[]);
    }
    markStructureChanged();
    onSaveWatchedFolders?.call();
    onSaveWatchedLibraries?.call();
    onSaveLibraryExclusions?.call();
    return (changed: true, removedFolderPaths: childFolders);
  }

  void syncSlice({
    required bool isInitialized,
    required int detailRevision,
    int treeSnapshotRevision = -1,
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
        scanGeneration: scanGeneration,
        scanStage: scanStage,
        scanProcessed: scanProcessed,
        scanTotal: scanTotal,
        structureRevision: structureRevision,
        treeSnapshotRevision: treeSnapshotRevision,
        contentRevision: contentRevision,
        detailRevision: detailRevision,
        categorySnapshotRevision: categorySnapshotRevision,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}

class LibraryExclusionClearResult {
  const LibraryExclusionClearResult({
    this.changed = false,
    this.restoredEntryPaths = const <String>[],
    this.restoredTracks = const <MusicTrack>[],
  });

  final bool changed;
  final List<String> restoredEntryPaths;
  final List<MusicTrack> restoredTracks;
}

class LibraryFolderRetargetResult {
  const LibraryFolderRetargetResult({
    required this.retargetedTracks,
    required this.retargetedEntries,
    this.removedEntryPaths = const <String>[],
  });

  final Map<String, MusicTrack> retargetedTracks;
  final List<LibraryEntry> retargetedEntries;
  final List<String> removedEntryPaths;
}

class LibraryTrackRetargetResult {
  const LibraryTrackRetargetResult({
    this.originalTrackPath,
    this.updatedTrack,
    this.retargetedEntries = const <LibraryEntry>[],
    this.removedEntryPathsByLibrary = const <String, List<String>>{},
  });

  final String? originalTrackPath;
  final MusicTrack? updatedTrack;
  final List<LibraryEntry> retargetedEntries;
  final Map<String, List<String>> removedEntryPathsByLibrary;
}
