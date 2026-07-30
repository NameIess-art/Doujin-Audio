import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/library_node.dart';
import '../application/library_scan_models.dart';
import '../application/library_state_models.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/search_query_utils.dart';
import '../domain/audio_library_category.dart';

@immutable
class LibraryHeaderState {
  const LibraryHeaderState({
    required this.audioCount,
    required this.watchedFolderCount,
    required this.watchedLibraryCount,
    required this.isInitialized,
    this.isRefreshing = false,
    this.operationProgress,
    this.operationError,
  });

  final int audioCount;
  final int watchedFolderCount;
  final int watchedLibraryCount;
  final bool isInitialized;
  final bool isRefreshing;
  final double? operationProgress;
  final Object? operationError;

  bool get hasWatchedSources =>
      watchedFolderCount > 0 || watchedLibraryCount > 0;

  @override
  bool operator ==(Object other) {
    return other is LibraryHeaderState &&
        other.audioCount == audioCount &&
        other.watchedFolderCount == watchedFolderCount &&
        other.watchedLibraryCount == watchedLibraryCount &&
        other.isInitialized == isInitialized &&
        other.isRefreshing == isRefreshing &&
        other.operationProgress == operationProgress &&
        other.operationError == operationError;
  }

  @override
  int get hashCode => Object.hash(
    audioCount,
    watchedFolderCount,
    watchedLibraryCount,
    isInitialized,
    isRefreshing,
    operationProgress,
    operationError,
  );
}

@immutable
class LibraryListState {
  const LibraryListState({
    required this.rawTree,
    required this.watchedFolders,
    required this.watchedLibraries,
    required this.watchedFolderCount,
    required this.watchedLibraryCount,
    required this.isScanning,
    required this.isBackgroundScanning,
    required this.structureRevision,
    required this.isInitialized,
    this.isRefreshing = false,
    this.operationProgress,
    this.operationError,
  });

  final List<LibraryNode> rawTree;
  final List<String> watchedFolders;
  final List<String> watchedLibraries;
  final int watchedFolderCount;
  final int watchedLibraryCount;
  final bool isScanning;
  final bool isBackgroundScanning;
  final int structureRevision;
  final bool isInitialized;
  final bool isRefreshing;
  final double? operationProgress;
  final Object? operationError;

  bool get hasLibrary => rawTree.isNotEmpty;
  bool get canPullRefresh => watchedFolderCount > 0 || watchedLibraryCount > 0;

  @override
  bool operator ==(Object other) {
    return other is LibraryListState &&
        identical(other.rawTree, rawTree) &&
        listEquals(other.watchedFolders, watchedFolders) &&
        listEquals(other.watchedLibraries, watchedLibraries) &&
        other.watchedFolderCount == watchedFolderCount &&
        other.watchedLibraryCount == watchedLibraryCount &&
        other.isScanning == isScanning &&
        other.isBackgroundScanning == isBackgroundScanning &&
        other.structureRevision == structureRevision &&
        other.isInitialized == isInitialized &&
        other.isRefreshing == isRefreshing &&
        other.operationProgress == operationProgress &&
        other.operationError == operationError;
  }

  @override
  int get hashCode => Object.hash(
    rawTree,
    Object.hashAll(watchedFolders),
    Object.hashAll(watchedLibraries),
    watchedFolderCount,
    watchedLibraryCount,
    isScanning,
    isBackgroundScanning,
    structureRevision,
    isInitialized,
    isRefreshing,
    operationProgress,
    operationError,
  );
}

@immutable
class LibraryScanUiState {
  const LibraryScanUiState({
    required this.isScanning,
    required this.isBackgroundScanning,
    required this.source,
    required this.stage,
    required this.processed,
    required this.total,
    required this.foundCount,
    required this.duplicateCount,
    required this.failureCount,
  });

  final bool isScanning;
  final bool isBackgroundScanning;
  final String source;
  final FolderScanStage stage;
  final int processed;
  final int? total;
  final int foundCount;
  final int duplicateCount;
  final int failureCount;

  @override
  bool operator ==(Object other) {
    return other is LibraryScanUiState &&
        other.isScanning == isScanning &&
        other.isBackgroundScanning == isBackgroundScanning &&
        other.source == source &&
        other.stage == stage &&
        other.processed == processed &&
        other.total == total &&
        other.foundCount == foundCount &&
        other.duplicateCount == duplicateCount &&
        other.failureCount == failureCount;
  }

  @override
  int get hashCode => Object.hash(
    isScanning,
    isBackgroundScanning,
    source,
    stage,
    processed,
    total,
    foundCount,
    duplicateCount,
    failureCount,
  );
}

@immutable
class FilteredLibraryTreeResult {
  const FilteredLibraryTreeResult({
    required this.tree,
    required this.matchCount,
  });

  final List<LibraryNode> tree;
  final int matchCount;
}

class LibrarySearchIndex {
  int? _cachedRevision;
  final LinkedHashMap<String, FilteredLibraryTreeResult> _cache =
      LinkedHashMap<String, FilteredLibraryTreeResult>();

  static const int _maxEntries = 12;

  FilteredLibraryTreeResult resolve({
    required List<LibraryNode> tree,
    required String query,
    required int structureRevision,
    AudioLibraryCategorySnapshot? categorySnapshot,
  }) {
    final searchTerms = extractSearchTerms(query);
    final detailRevision = categorySnapshot?.detailRevision ?? 0;
    final normalizedQuery = '$detailRevision|${searchTerms.join(' ')}';
    if (_cachedRevision != structureRevision) {
      _cache.clear();
      _cachedRevision = structureRevision;
    }

    final cached = _cache.remove(normalizedQuery);
    if (cached != null) {
      _cache[normalizedQuery] = cached;
      return cached;
    }

    final result = _buildFilteredTree(tree, searchTerms, categorySnapshot);
    _cache[normalizedQuery] = result;
    if (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  FilteredLibraryTreeResult _buildFilteredTree(
    List<LibraryNode> tree,
    List<String> searchTerms,
    AudioLibraryCategorySnapshot? categorySnapshot,
  ) {
    if (searchTerms.isEmpty) {
      return FilteredLibraryTreeResult(
        tree: tree,
        matchCount: _countTrackNodes(tree),
      );
    }

    final resultNodes = <LibraryNode>[];
    var totalMatches = 0;

    for (final node in tree) {
      if (node is FolderNode) {
        final folderResult = _filterFolderNode(
          node,
          searchTerms,
          categorySnapshot,
        );
        if (folderResult == null) continue;
        resultNodes.add(folderResult.node);
        totalMatches += folderResult.matchCount;
        continue;
      }

      final trackNode = node as TrackNode;
      if (_trackMatchesQuery(trackNode, searchTerms, categorySnapshot)) {
        resultNodes.add(trackNode);
        totalMatches++;
      }
    }

    return FilteredLibraryTreeResult(
      tree: List<LibraryNode>.unmodifiable(resultNodes),
      matchCount: totalMatches,
    );
  }

  _FilteredFolderNodeResult? _filterFolderNode(
    FolderNode folder,
    List<String> searchTerms,
    AudioLibraryCategorySnapshot? categorySnapshot,
  ) {
    final folderTargets = <AudioDetailTarget>[
      AudioDetailTarget.libraryRootFolder(folder.path),
    ];
    final folderEntries = categorySnapshot == null
        ? const <AudioLibraryCategoryEntry>[]
        : folderTargets
            .map((t) => categorySnapshot.entryFor(t))
            .whereType<AudioLibraryCategoryEntry>();

    final matchesFolderName = matchesSearchTerms(
      <String>[
        folder.name,
        folder.path,
        ...folderEntries.map((e) => e.searchableText),
      ],
      '',
      terms: searchTerms,
    );
    if (matchesFolderName) {
      return _FilteredFolderNodeResult(
        node: folder,
        matchCount: folder.totalTrackCount,
      );
    }

    final filteredChildren = <LibraryNode>[];
    var matchCount = 0;

    for (final child in folder.children) {
      if (child is FolderNode) {
        final nestedResult = _filterFolderNode(
          child,
          searchTerms,
          categorySnapshot,
        );
        if (nestedResult == null) continue;
        filteredChildren.add(nestedResult.node);
        matchCount += nestedResult.matchCount;
        continue;
      }

      final trackNode = child as TrackNode;
      if (_trackMatchesQuery(trackNode, searchTerms, categorySnapshot)) {
        filteredChildren.add(trackNode);
        matchCount++;
      }
    }

    if (filteredChildren.isEmpty) return null;

    final filteredFolder = FolderNode(
      folder.name,
      folder.path,
      depth: folder.depth,
    )..addChildren(filteredChildren);
    return _FilteredFolderNodeResult(
      node: filteredFolder,
      matchCount: matchCount,
    );
  }

  bool _trackMatchesQuery(
    TrackNode trackNode,
    List<String> searchTerms,
    AudioLibraryCategorySnapshot? categorySnapshot,
  ) {
    final track = trackNode.track;
    final trackEntry = categorySnapshot?.entryFor(
      AudioDetailTarget.singleAudioFile(track.path),
    );

    return matchesSearchTerms(
      <String>[
        track.displayName,
        track.groupTitle,
        track.groupSubtitle,
        track.path,
        ...track.tags,
        if (trackEntry != null) trackEntry.searchableText,
      ],
      '',
      terms: searchTerms,
    );
  }

  int _countTrackNodes(List<LibraryNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      if (node is TrackNode) {
        count++;
      } else if (node is FolderNode) {
        count += node.totalTrackCount;
      }
    }
    return count;
  }
}

class LibrarySearchSnapshotRequest {
  const LibrarySearchSnapshotRequest({
    required this.tree,
    required this.query,
    required this.structureRevision,
    this.categorySnapshot,
  });

  final List<LibraryNode> tree;
  final String query;
  final int structureRevision;
  final AudioLibraryCategorySnapshot? categorySnapshot;
}

FilteredLibraryTreeResult buildFilteredLibraryTreeSnapshot(
  LibrarySearchSnapshotRequest request,
) {
  return LibrarySearchIndex().resolve(
    tree: request.tree,
    query: request.query,
    structureRevision: request.structureRevision,
    categorySnapshot: request.categorySnapshot,
  );
}

int libraryTreeTrackCount(List<LibraryNode> tree) {
  var count = 0;
  for (final node in tree) {
    count += switch (node) {
      TrackNode() => 1,
      FolderNode() => node.totalTrackCount,
      _ => 0,
    };
  }
  return count;
}

class _FilteredFolderNodeResult {
  const _FilteredFolderNodeResult({
    required this.node,
    required this.matchCount,
  });

  final FolderNode node;
  final int matchCount;
}

LibraryHeaderState libraryHeaderStateFromSlice(
  LibraryState state, {
  bool isRefreshing = false,
  double? operationProgress,
  Object? operationError,
}) {
  return LibraryHeaderState(
    audioCount: state.libraryTrackCount,
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isInitialized: state.isInitialized,
    isRefreshing: isRefreshing,
    operationProgress: operationProgress,
    operationError: operationError,
  );
}
