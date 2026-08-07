import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../app/application/audio_state_slice.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/path_display.dart';
import '../domain/library_entry.dart';
import 'library_organizer.dart';
import 'library_scan_models.dart';
import 'library_state_models.dart';

class LibraryService {
  static const LibraryOrganizer organizer = LibraryOrganizer();

  List<MusicTrack> library = <MusicTrack>[];
  Map<String, MusicTrack> libraryByPath = <String, MusicTrack>{};

  /// Maps each track path to its index in [library].  Kept in sync by
  /// [_rebuildLibraryIndexes] so that [addOrReplaceTracks] can update
  /// existing entries in O(1) instead of O(n).
  Map<String, int> libraryIndexByPath = <String, int>{};
  Map<String, List<MusicTrack>> tracksByGroup = <String, List<MusicTrack>>{};
  List<MusicTrack> sortedLibraryTracks = const <MusicTrack>[];
  List<String> sortedLibraryTrackPaths = const <String>[];
  final List<String> groupOrder = <String>[];
  final Set<String> groupOrderSet = <String>{};
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
  int scanGenerationSeed = 0;
  int scanGeneration = 0;
  FolderScanStage scanStage = FolderScanStage.idle;
  int scanProcessed = 0;
  int? scanTotal;
  int contentRevision = 0;
  int libraryBatchDepth = 0;
  bool libraryBatchChanged = false;
  bool libraryBatchChangedGroupOrder = false;
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
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      return;
    }
    structureRevision++;
    contentRevision++;
  }

  bool addWatchedFolder(String folderPath, {VoidCallback? onPersist}) {
    if (watchedFolders.any(
      (watchedFolder) =>
          PathMatcher.equalsNormalized(watchedFolder, folderPath),
    )) {
      return false;
    }
    watchedFolders.add(folderPath);
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
      () => <String>{},
    );
    final changed = excluded
        ? folders.add(normalizedFolderPath)
        : _removePathsWithin(folders, normalizedFolderPath);
    if (!changed) {
      return (changed: false, affectedEntryPaths: const <String>[]);
    }
    if (!excluded) {
      excludedLibraryTracks[normalizedLibraryPath]?.removeWhere(
        (trackPath) => PathMatcher.isWithinOrEqualNormalized(
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
      () => <String>{},
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
    String folderName,
  ) {
    final oldRoot = PathMatcher.normalize(oldFolderPath);
    final newRoot = PathMatcher.normalize(newFolderPath);
    final retargetedTracks = <String, MusicTrack>{};
    for (var i = 0; i < library.length; i++) {
      final track = library[i];
      if (!PathMatcher.isWithinOrEqual(track.path, oldRoot)) continue;
      final nextTrackPath = _replacePathPrefix(track.path, oldRoot, newRoot);
      final nextGroupKey = PathMatcher.isWithinOrEqual(track.groupKey, oldRoot)
          ? _replacePathPrefix(track.groupKey, oldRoot, newRoot)
          : track.groupKey;
      final updatedTrack = _copyTrackForRetarget(
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
      library[i] = updatedTrack;
      retargetedTracks[track.path] = updatedTrack;
    }

    for (var i = 0; i < watchedFolders.length; i++) {
      if (PathMatcher.equalsNormalized(watchedFolders[i], oldRoot)) {
        watchedFolders[i] = newRoot;
      }
    }
    for (var i = 0; i < watchedLibraries.length; i++) {
      if (PathMatcher.equalsNormalized(watchedLibraries[i], oldRoot)) {
        watchedLibraries[i] = newRoot;
      }
    }
    for (var i = 0; i < groupOrder.length; i++) {
      if (PathMatcher.isWithinOrEqual(groupOrder[i], oldRoot)) {
        groupOrder[i] = _replacePathPrefix(groupOrder[i], oldRoot, newRoot);
      }
    }

    _retargetLibraryExclusions(oldRoot, newRoot);
    final retargetedEntries = _retargetLibraryEntries(
      oldRoot,
      newRoot,
      folderName,
    );
    syncGroupOrderFromLibrary();
    rebuildLibraryIndexes();
    markStructureChanged();
    return LibraryFolderRetargetResult(
      retargetedTracks: retargetedTracks,
      retargetedEntries: retargetedEntries,
    );
  }

  MusicTrack? retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) {
    final oldPath = PathMatcher.normalize(oldTrackPath);
    final newPath = PathMatcher.normalize(newTrackPath);
    final track = libraryByPath[oldPath];
    if (track == null) return null;
    final updatedTrack = _copyTrackForRetarget(
      track,
      path: newPath,
      displayName: displayName,
    );
    final index = library.indexWhere(
      (item) => PathMatcher.equalsNormalized(item.path, oldPath),
    );
    if (index >= 0) library[index] = updatedTrack;
    rebuildLibraryIndexes();
    markStructureChanged();
    return updatedTrack;
  }

  void _retargetLibraryExclusions(String oldRoot, String newRoot) {
    Map<String, Set<String>> retarget(Map<String, Set<String>> source) {
      final result = <String, Set<String>>{};
      for (final entry in source.entries) {
        final nextKey = PathMatcher.equalsNormalized(entry.key, oldRoot)
            ? newRoot
            : entry.key;
        final nextValues = entry.value
            .map(
              (value) => PathMatcher.isWithinOrEqual(value, oldRoot)
                  ? _replacePathPrefix(value, oldRoot, newRoot)
                  : value,
            )
            .toSet();
        result.putIfAbsent(nextKey, () => <String>{}).addAll(nextValues);
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
  }

  List<LibraryEntry> _retargetLibraryEntries(
    String oldRoot,
    String newRoot,
    String folderName,
  ) {
    final existingEntries = libraryEntriesByLibrary.remove(oldRoot);
    if (existingEntries == null || existingEntries.isEmpty) {
      return const <LibraryEntry>[];
    }
    final retargetedEntries = existingEntries.values
        .map(
          (entry) => _retargetLibraryEntry(
            entry,
            oldRoot: oldRoot,
            newRoot: newRoot,
            folderName: folderName,
          ),
        )
        .toList(growable: false);
    libraryEntriesByLibrary[newRoot] = <String, LibraryEntry>{
      for (final entry in retargetedEntries) entry.path: entry,
    };
    return retargetedEntries;
  }

  LibraryEntry _retargetLibraryEntry(
    LibraryEntry entry, {
    required String oldRoot,
    required String newRoot,
    required String folderName,
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
        libraryPath: newRoot,
        path: nextPath,
        parentPath: nextParentPath,
        state: entry.state,
        displayName: entry.displayName,
      );
    }
    final nextGroupKey = PathMatcher.isWithinOrEqual(entry.groupKey, oldRoot)
        ? _replacePathPrefix(entry.groupKey, oldRoot, newRoot)
        : entry.groupKey;
    return LibraryEntry(
      libraryPath: newRoot,
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
    final retainedPathIndex = PathMembershipIndex(retainedPaths);

    final removedPaths = <String>[];
    entries.removeWhere((entryPath, entry) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        entry.path,
        normalizedFolderPath,
      )) {
        return false;
      }
      final retained = entry.isFolder
          ? retainedPathIndex.containsDescendantOrEqual(entry.path)
          : retainedPathIndex.containsEquivalent(entry.path);
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
    for (final entry in entries.values) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        entry.path,
        normalizedRootPath,
      )) {
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

  int compareTracks(MusicTrack first, MusicTrack second) {
    return organizer.compareTracks(first, second);
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
    sortedLibraryTracks = List<MusicTrack>.unmodifiable(
      library.toList()..sort(compareTracks),
    );
    sortedLibraryTrackPaths = List<String>.unmodifiable(
      sortedLibraryTracks.map((track) => track.path),
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

  ({List<MusicTrack> tracks, bool didChangeGroupOrder, bool batched}) addTracks(
    List<MusicTrack> newTracks, {
    required bool persist,
  }) {
    final addedTracks = <MusicTrack>[];
    var didChangeGroupOrder = false;
    for (final track in newTracks) {
      if (libraryByPath.containsKey(track.path)) continue;
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
      if (didChangeGroupOrder) libraryBatchChangedGroupOrder = true;
      return (
        tracks: addedTracks,
        didChangeGroupOrder: didChangeGroupOrder,
        batched: true,
      );
    }
    rebuildLibraryIndexes();
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
  addOrReplaceTracks(List<MusicTrack> tracks, {required bool persist}) {
    var didChangeGroupOrder = false;
    var didReplaceGroup = false;
    final changedTracks = <MusicTrack>[];

    for (final track in tracks) {
      final existing = libraryByPath[track.path];
      final nextTrack = existing == null
          ? track
          : _mergeExistingTrackState(existing, track);
      if (existing != null && !_mergedTrackHasChanges(existing, track)) {
        continue;
      }
      if (existing != null && existing.groupKey != nextTrack.groupKey) {
        didReplaceGroup = true;
      }
      if (existing == null) {
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
          } else {
            library.add(nextTrack);
          }
        }
      }
      libraryByPath[nextTrack.path] = nextTrack;
      changedTracks.add(nextTrack);
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
      if (didChangeGroupOrder || didReplaceGroup) {
        libraryBatchChangedGroupOrder = true;
      }
      return (
        tracks: changedTracks,
        didChangeGroupOrder: didChangeGroupOrder,
        didReplaceGroup: didReplaceGroup,
        batched: true,
      );
    }
    rebuildLibraryIndexes();
    syncGroupOrderFromLibrary();
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
    final removedTracks = library.where(test).toList(growable: false);
    if (removedTracks.isEmpty) {
      return (tracks: const <MusicTrack>[], batched: false);
    }
    final removedPaths = removedTracks.map((track) => track.path).toSet();
    library.removeWhere((track) => removedPaths.contains(track.path));
    for (final trackPath in removedPaths) {
      libraryByPath.remove(trackPath);
      libraryIndexByPath.remove(trackPath);
    }
    if (libraryBatchDepth > 0) {
      libraryBatchChanged = true;
      return (tracks: removedTracks, batched: true);
    }
    rebuildLibraryIndexes();
    return (tracks: removedTracks, batched: false);
  }

  List<LibraryEntry> buildLibraryEntries(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    LibraryExclusionMatcher? exclusionMatcher,
  }) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final matcher =
        exclusionMatcher ??
        libraryExclusionMatcherForLibrary(normalizedLibraryPath);
    final entriesByKey = <String, LibraryEntry>{};

    void putEntry(LibraryEntry entry) {
      entriesByKey['${entry.kind.dbValue}:${entry.path}'] = entry;
    }

    void ensureFolder(String folderPath) {
      final normalizedFolderPath = canonicalLibraryFolderPath(
        normalizedLibraryPath,
        folderPath,
      );
      if (PathMatcher.equalsNormalized(
            normalizedFolderPath,
            normalizedLibraryPath,
          ) ||
          !PathMatcher.isWithinOrEqual(
            normalizedFolderPath,
            normalizedLibraryPath,
          )) {
        return;
      }
      final parentPath = parentLibraryFolderPath(
        normalizedFolderPath,
        normalizedLibraryPath,
      );
      if (parentPath != null) ensureFolder(parentPath);
      putEntry(
        LibraryEntry.folder(
          libraryPath: normalizedLibraryPath,
          path: normalizedFolderPath,
          parentPath: parentPath,
          state: matcher.isExcluded(normalizedFolderPath)
              ? LibraryEntryState.excluded
              : LibraryEntryState.active,
          displayName: PathDisplay.folderName(normalizedFolderPath),
        ),
      );
    }

    for (final folderPath in folderPaths) {
      ensureFolder(folderPath);
    }
    for (final track in tracks) {
      if (!PathMatcher.isWithinOrEqual(track.path, normalizedLibraryPath)) {
        continue;
      }
      final parentPath = folderPathForLibraryTrack(
        normalizedLibraryPath,
        track,
      );
      if (parentPath != null) ensureFolder(parentPath);
      putEntry(
        LibraryEntry.track(
          libraryPath: normalizedLibraryPath,
          track: track,
          parentPath: parentPath,
          state: matcher.isExcluded(track.path)
              ? LibraryEntryState.excluded
              : LibraryEntryState.active,
        ),
      );
    }
    return entriesByKey.values.toList(growable: false);
  }

  String? libraryPathForTrack(MusicTrack track) {
    for (final libraryPath in watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(track.path, libraryPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, libraryPath)) {
        return libraryPath;
      }
    }
    for (final folderPath in watchedFolders) {
      if (PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath)) {
        return folderPath;
      }
    }
    return null;
  }

  String? folderPathForLibraryTrack(String libraryPath, MusicTrack track) {
    if (!track.isSingle &&
        track.groupKey.isNotEmpty &&
        track.groupKey != '__single_files__' &&
        PathMatcher.isWithinOrEqual(track.groupKey, libraryPath) &&
        !PathMatcher.equalsNormalized(track.groupKey, libraryPath)) {
      return canonicalLibraryFolderPath(libraryPath, track.groupKey);
    }
    final relative = PathMatcher.relativeWithin(track.path, libraryPath);
    if (relative == null || relative.isEmpty) return null;
    final normalizedRelative = relative.replaceAll('\\', '/');
    final relativeFolder = path.posix.dirname(normalizedRelative);
    if (relativeFolder == '.' || relativeFolder.isEmpty) return null;
    if (PathMatcher.isContentUri(libraryPath)) {
      return '$libraryPath::$relativeFolder';
    }
    return path.normalize(path.join(libraryPath, relativeFolder));
  }

  String canonicalLibraryFolderPath(String libraryPath, String folderPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (!PathMatcher.isContentUri(normalizedLibraryPath) ||
        normalizedFolderPath.contains('::')) {
      return normalizedFolderPath;
    }
    final relativeFolderPath = PathMatcher.relativeWithin(
      normalizedFolderPath,
      normalizedLibraryPath,
    );
    if (relativeFolderPath == null || relativeFolderPath.isEmpty) {
      return normalizedFolderPath;
    }
    return '$normalizedLibraryPath::${relativeFolderPath.replaceAll('\\', '/')}';
  }

  String? parentLibraryFolderPath(String folderPath, String rootPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (PathMatcher.equalsNormalized(normalizedFolderPath, rootPath)) {
      return null;
    }
    if (PathMatcher.isContentUri(normalizedFolderPath)) {
      final markerIndex = normalizedFolderPath.indexOf('::');
      if (markerIndex >= 0) {
        final base = normalizedFolderPath.substring(0, markerIndex);
        final relative = normalizedFolderPath
            .substring(markerIndex + 2)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/+'), '')
            .replaceFirst(RegExp(r'/+$'), '');
        final parentRelative = path.posix.dirname(relative);
        if (parentRelative == '.' || parentRelative.isEmpty) return base;
        return '$base::$parentRelative';
      }
    }
    final parentPath = path.dirname(normalizedFolderPath);
    return PathMatcher.equalsNormalized(parentPath, rootPath)
        ? rootPath
        : parentPath;
  }

  bool trackNeedsRefresh(MusicTrack nextTrack) {
    final existing = libraryByPath[nextTrack.path];
    return existing == null || _mergedTrackHasChanges(existing, nextTrack);
  }

  bool _mergedTrackHasChanges(MusicTrack existing, MusicTrack scanned) {
    return existing.displayName != scanned.displayName ||
        existing.groupKey != scanned.groupKey ||
        existing.groupTitle != scanned.groupTitle ||
        existing.groupSubtitle != scanned.groupSubtitle ||
        existing.isSingle != scanned.isSingle ||
        existing.isVideo != scanned.isVideo ||
        existing.fileSizeBytes != scanned.fileSizeBytes ||
        existing.modifiedAt?.millisecondsSinceEpoch !=
            scanned.modifiedAt?.millisecondsSinceEpoch ||
        existing.coverCachePath == null && scanned.coverCachePath != null ||
        existing.lyricsPath == null && scanned.lyricsPath != null ||
        existing.manualCoverPath == null && scanned.manualCoverPath != null ||
        existing.remoteCoverUrl == null && scanned.remoteCoverUrl != null ||
        existing.remoteMetadataKind == null &&
            scanned.remoteMetadataKind != null ||
        existing.remoteMetadata == null && scanned.remoteMetadata != null ||
        existing.duration == Duration.zero && scanned.duration != Duration.zero;
  }

  MusicTrack _mergeExistingTrackState(MusicTrack existing, MusicTrack scanned) {
    return MusicTrack(
      path: scanned.path,
      displayName: scanned.displayName,
      groupKey: scanned.groupKey,
      groupTitle: scanned.groupTitle,
      groupSubtitle: scanned.groupSubtitle,
      isSingle: scanned.isSingle,
      isVideo: scanned.isVideo,
      scannedAt: scanned.scannedAt,
      fileSizeBytes: scanned.fileSizeBytes,
      modifiedAt: scanned.modifiedAt,
      lastPlayedPosition: existing.lastPlayedPosition,
      lastPlayedAt: existing.lastPlayedAt,
      isFavorite: existing.isFavorite,
      tags: existing.tags,
      coverCachePath: existing.coverCachePath ?? scanned.coverCachePath,
      lyricsPath: existing.lyricsPath ?? scanned.lyricsPath,
      manualCoverPath: existing.manualCoverPath ?? scanned.manualCoverPath,
      remoteCoverUrl: existing.remoteCoverUrl ?? scanned.remoteCoverUrl,
      remoteMetadataKind:
          existing.remoteMetadataKind ?? scanned.remoteMetadataKind,
      remoteMetadata: existing.remoteMetadata ?? scanned.remoteMetadata,
      duration: existing.duration == Duration.zero
          ? scanned.duration
          : existing.duration,
    );
  }

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
    watchedFolders.removeWhere(
      (folderPath) => PathMatcher.isWithinOrEqualNormalized(
        PathMatcher.normalize(folderPath),
        normalizedLibraryPath,
      ),
    );
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
  });

  final Map<String, MusicTrack> retargetedTracks;
  final List<LibraryEntry> retargetedEntries;
}
