import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/media/path_matcher.dart';
import '../domain/library_entry.dart';
import 'library_scan_models.dart';

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

class LibraryExclusionSnapshot {
  const LibraryExclusionSnapshot({
    required this.libraryPath,
    this.excludedFolders = const <String>[],
    this.excludedTracks = const <String>[],
    this.entries = const <LibraryEntry>[],
  });

  final String libraryPath;
  final List<String> excludedFolders;
  final List<String> excludedTracks;
  final List<LibraryEntry> entries;
}

class LibraryExclusionMatcher {
  LibraryExclusionMatcher({
    required String libraryPath,
    Iterable<String> excludedTrackPaths = const <String>[],
    Iterable<String> excludedFolderPaths = const <String>[],
  }) : libraryPath = PathMatcher.normalize(libraryPath),
       _excludedTrackKeys = excludedTrackPaths
           .map(PathMatcher.equivalenceKey)
           .toSet(),
       _excludedFolderKeys = excludedFolderPaths
           .map(PathMatcher.equivalenceKey)
           .toSet();

  final String libraryPath;
  final Set<String> _excludedTrackKeys;
  final Set<String> _excludedFolderKeys;

  bool get hasExclusions =>
      _excludedTrackKeys.isNotEmpty || _excludedFolderKeys.isNotEmpty;

  bool get hasExcludedFolders => _excludedFolderKeys.isNotEmpty;

  bool isExcluded(String entityPath) {
    if (!hasExclusions) return false;
    final normalizedPath = PathMatcher.normalize(entityPath);
    if (_excludedTrackKeys.contains(
      PathMatcher.equivalenceKey(normalizedPath),
    )) {
      return true;
    }
    if (_excludedFolderKeys.isEmpty) {
      return false;
    }
    for (final folderPath in _candidateFolderPaths(normalizedPath)) {
      if (_excludedFolderKeys.contains(
        PathMatcher.equivalenceKey(folderPath),
      )) {
        return true;
      }
    }
    return false;
  }

  bool isInheritedExcluded(String entityPath) {
    if (_excludedFolderKeys.isEmpty) return false;
    final normalizedPath = PathMatcher.normalize(entityPath);
    final entityKey = PathMatcher.equivalenceKey(normalizedPath);
    for (final folderPath in _candidateFolderPaths(normalizedPath)) {
      final folderKey = PathMatcher.equivalenceKey(folderPath);
      if (folderKey != entityKey && _excludedFolderKeys.contains(folderKey)) {
        return true;
      }
    }
    return false;
  }

  bool isEntryExcluded(LibraryEntry? entry, String entityPath) {
    if (isExcluded(entityPath)) return true;
    // Opaque SAF document IDs do not encode their folder. Use the confirmed
    // scan parent only for tracks belonging to the same permission grant.
    return entry != null &&
        entry.isTrack &&
        PathMatcher.hasSameContentTree(entry.path, entry.libraryPath) &&
        isExcluded(entry.parentPath ?? entry.libraryPath);
  }

  bool isTrackPathExcluded(String trackPath, {String? parentPath}) {
    if (isExcluded(trackPath)) return true;
    return parentPath != null &&
        PathMatcher.hasSameContentTree(trackPath, libraryPath) &&
        PathMatcher.isWithinOrEqual(parentPath, libraryPath) &&
        isExcluded(parentPath);
  }

  bool isEntryInheritedExcluded(LibraryEntry? entry, String entityPath) {
    if (_excludedFolderKeys.isEmpty) return false;
    if (isInheritedExcluded(entityPath)) return true;
    if (entry == null ||
        !entry.isTrack ||
        !PathMatcher.hasSameContentTree(entry.path, entry.libraryPath)) {
      return false;
    }
    final parentPath = PathMatcher.normalize(
      entry.parentPath ?? entry.libraryPath,
    );
    final entityKey = PathMatcher.equivalenceKey(entityPath);
    for (final folderPath in _candidateFolderPaths(parentPath)) {
      final folderKey = PathMatcher.equivalenceKey(folderPath);
      if (folderKey != entityKey && _excludedFolderKeys.contains(folderKey)) {
        return true;
      }
    }
    return false;
  }

  Iterable<String> _candidateFolderPaths(String normalizedPath) sync* {
    if (_excludedFolderKeys.contains(
      PathMatcher.equivalenceKey(normalizedPath),
    )) {
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
      var current = PathMatcher.trimRightSlash(
        relativePath.replaceAll('\\', '/'),
      );
      while (current.isNotEmpty) {
        yield '$libraryPath::$current';
        final slashIndex = current.lastIndexOf('/');
        if (slashIndex < 0) {
          break;
        }
        current = current.substring(0, slashIndex);
      }
      yield libraryPath;
      return;
    }

    var current = normalizedPath;
    while (!PathMatcher.equalsNormalized(current, libraryPath)) {
      yield current;
      final parent = PathMatcher.parentPath(current);
      if (parent == null || parent == current) {
        break;
      }
      current = parent;
    }
    if (PathMatcher.equalsNormalized(current, libraryPath)) yield current;
  }
}

class LibraryEntrySnapshot {
  LibraryEntrySnapshot({
    required String libraryPath,
    Iterable<LibraryEntry> entries = const <LibraryEntry>[],
  }) : libraryPath = PathMatcher.normalize(libraryPath),
       _entriesByPath = {
         for (final entry in entries)
           PathMatcher.equivalenceKey(entry.path): entry,
       } {
    entriesByPath = UnmodifiableMapView<String, LibraryEntry>(_entriesByPath);
  }

  final String libraryPath;
  final Map<String, LibraryEntry> _entriesByPath;
  late final Map<String, LibraryEntry> entriesByPath;

  LibraryEntry? entryForPath(String entryPath) {
    return _entriesByPath[PathMatcher.equivalenceKey(entryPath)];
  }

  void remember(Iterable<LibraryEntry> entries) {
    for (final entry in entries) {
      _entriesByPath[PathMatcher.equivalenceKey(entry.path)] = entry;
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
