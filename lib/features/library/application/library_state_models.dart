import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

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
       _entriesByPath = <String, LibraryEntry>{
         for (final entry in entries) PathMatcher.normalize(entry.path): entry,
       } {
    entriesByPath = UnmodifiableMapView<String, LibraryEntry>(_entriesByPath);
  }

  final String libraryPath;
  final Map<String, LibraryEntry> _entriesByPath;
  late final Map<String, LibraryEntry> entriesByPath;

  LibraryEntry? entryForPath(String entryPath) {
    return _entriesByPath[PathMatcher.normalize(entryPath)];
  }

  void remember(Iterable<LibraryEntry> entries) {
    for (final entry in entries) {
      _entriesByPath[PathMatcher.normalize(entry.path)] = entry;
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
