import 'package:flutter/foundation.dart';

import '../domain/library_node.dart';
import '../application/library_scan_models.dart';
import '../application/library_state_models.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/path_matcher.dart';
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
  FilteredLibraryTreeResult({
    required this.tree,
    required this.matchCount,
    Set<String> expandedFolderPaths = const <String>{},
  }) : expandedFolderPaths = Set<String>.unmodifiable(expandedFolderPaths),
       initialRows = List.unmodifiable(
         projectLibrarySearchRows(tree, expandedFolderPaths),
       );

  final List<LibraryNode> tree;
  final int matchCount;
  final Set<String> expandedFolderPaths;
  final List<LibrarySearchRow> initialRows;

  Future<FilteredLibraryTreeResult?> filterSubtitles({
    required AudioLibraryCategorySnapshot snapshot,
    required bool hasSubtitle,
    required Future<bool> Function(String) checkTrack,
    required bool Function() isActive,
  }) async {
    if (tree.isEmpty) return this;
    Future<bool> checkWork(LibraryNode node) async {
      if (node is TrackNode) return checkTrack(node.path);
      if (node is! FolderNode) return false;
      // Text search can trim a folder. Test subtitle availability on the work.
      final tracks =
          snapshot
              .entryFor(AudioDetailTarget.libraryRootFolder(node.path))
              ?.tracks ??
          node.allTracks;
      for (final track in tracks) {
        if (!isActive()) return false;
        if (await checkTrack(track.path)) return true;
      }
      return false;
    }

    final selected = <LibraryNode>[];
    const batchSize = 8;
    for (var start = 0; start < tree.length; start += batchSize) {
      if (!isActive()) return null;
      final batch = tree.skip(start).take(batchSize).toList(growable: false);
      final matches = await Future.wait(batch.map(checkWork));
      for (var index = 0; index < batch.length; index++) {
        if (matches[index] == hasSubtitle) selected.add(batch[index]);
      }
    }
    if (!isActive()) return null;
    if (selected.length == tree.length) return this;
    final kept = selected.toSet();
    final expanded = <String>{};
    var keepRow = false;
    for (final row in initialRows) {
      if (row.depth == 0) keepRow = kept.contains(row.node);
      if (keepRow && row.node is FolderNode) {
        final path = PathMatcher.normalize(row.node.path);
        if (expandedFolderPaths.contains(path)) expanded.add(path);
      }
    }
    return FilteredLibraryTreeResult(
      tree: List.unmodifiable(selected),
      matchCount: libraryTreeTrackCount(selected),
      expandedFolderPaths: expanded,
    );
  }
}

typedef LibrarySearchRow = ({LibraryNode node, int depth});

List<LibrarySearchRow> projectLibrarySearchRows(
  List<LibraryNode> tree,
  Set<String> expandedPaths, {
  int depth = 0,
}) {
  final rows = <LibrarySearchRow>[];
  void addNode(LibraryNode node, int depth) {
    rows.add((node: node, depth: depth));
    if (node is FolderNode &&
        expandedPaths.contains(PathMatcher.normalize(node.path))) {
      for (final child in node.children) {
        addNode(child, depth + 1);
      }
    }
  }

  for (final node in tree) {
    addNode(node, depth);
  }
  return rows;
}

AudioLibraryCategorySnapshot? currentLibraryCategorySnapshot({
  required AudioLibraryCategorySnapshot? snapshot,
  required int detailRevision,
}) {
  return snapshot?.detailRevision == detailRevision ? snapshot : null;
}

class LibrarySearchIndex {
  int? _cachedRevision;
  int? _cachedDetailRevision;
  final _cache = <(String, SearchFilters), FilteredLibraryTreeResult>{};

  static const int _maxEntries = 12;

  (List<LibraryNode>, int, int)? _corpusKey;
  LibrarySearchCorpus? _corpus;

  Future<FilteredLibraryTreeResult> searchInBackground({
    required List<LibraryNode> tree,
    required String query,
    required int structureRevision,
    required int detailRevision,
    required AudioLibraryCategorySnapshot categorySnapshot,
    SearchFilters filters = emptySearchFilters,
  }) async {
    final key = (tree, structureRevision, detailRevision);
    if (_corpusKey != key) {
      _corpusKey = key;
      _corpus = null;
    }
    final previous = _corpus;
    final (corpus, result) = await compute(buildFilteredLibraryTreeSnapshot, (
      previous ?? LibrarySearchCorpus(tree, categorySnapshot),
      query,
      filters,
    ));
    if (_corpusKey == key && identical(_corpus, previous)) {
      _corpus = corpus;
    }
    return result;
  }

  FilteredLibraryTreeResult resolve({
    required List<LibraryNode> tree,
    required String query,
    required int structureRevision,
    AudioLibraryCategorySnapshot? categorySnapshot,
    SearchFilters filters = emptySearchFilters,
  }) {
    final detailRevision = categorySnapshot?.detailRevision ?? 0;
    final cached = cachedResult(
      query: query,
      structureRevision: structureRevision,
      detailRevision: detailRevision,
      filters: filters,
    );
    if (cached != null) return cached;
    final key = (tree, structureRevision, detailRevision);
    if (_corpusKey != key || _corpus == null) {
      _corpusKey = key;
      _corpus = LibrarySearchCorpus(tree, categorySnapshot);
    }
    final result = _corpus!.search(query, filters: filters);
    storeResult(
      query: query,
      structureRevision: structureRevision,
      detailRevision: detailRevision,
      filters: filters,
      result: result,
    );
    return result;
  }

  FilteredLibraryTreeResult? cachedResult({
    required String query,
    required int structureRevision,
    required int detailRevision,
    SearchFilters filters = emptySearchFilters,
  }) {
    final key = _cacheKey(query, structureRevision, detailRevision, filters);
    final cached = _cache.remove(key);
    if (cached != null) _cache[key] = cached;
    return cached;
  }

  void storeResult({
    required String query,
    required int structureRevision,
    required int detailRevision,
    required FilteredLibraryTreeResult result,
    SearchFilters filters = emptySearchFilters,
  }) {
    final key = _cacheKey(query, structureRevision, detailRevision, filters);
    _cache.remove(key);
    _cache[key] = result;
    if (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  (String, SearchFilters) _cacheKey(
    String query,
    int structureRevision,
    int detailRevision,
    SearchFilters filters,
  ) {
    if (_cachedRevision != structureRevision ||
        _cachedDetailRevision != detailRevision) {
      _cache.clear();
      _cachedRevision = structureRevision;
      _cachedDetailRevision = detailRevision;
    }
    // Subtitle availability is read from files after the indexed search.
    return (canonicalElementQuery(query).toLowerCase(), filters);
  }
}

/// Reuses normalized fields for nodes visited across queries of one revision.
class LibrarySearchCorpus {
  LibrarySearchCorpus(this.tree, AudioLibraryCategorySnapshot? categorySnapshot)
    : _categorySnapshot = categorySnapshot;

  final List<LibraryNode> tree;
  final AudioLibraryCategorySnapshot? _categorySnapshot;
  final _text = Map<LibraryNode, String>.identity();

  String _textFor(LibraryNode node) {
    return _text.putIfAbsent(node, () {
      if (node is FolderNode) {
        final entry = _categorySnapshot?.entryFor(
          AudioDetailTarget.libraryRootFolder(node.path),
        );
        return normalizeSearchText([
          node.name,
          node.path,
          if (entry != null) entry.searchableText,
        ]);
      }
      if (node is TrackNode) {
        final track = node.track;
        final entry = _categorySnapshot?.entryFor(
          AudioDetailTarget.singleAudioFile(track.path),
        );
        return normalizeSearchText([
          track.displayName,
          track.groupTitle,
          track.groupSubtitle,
          track.path,
          ...track.tags,
          if (entry != null) entry.searchableText,
        ]);
      }
      return '';
    });
  }

  bool _matchesRootMetadata(LibraryNode node, SearchFilters filters) {
    final target = node is FolderNode
        ? AudioDetailTarget.libraryRootFolder(node.path)
        : AudioDetailTarget.singleAudioFile(node.path);
    final detail = _categorySnapshot?.detailFor(target);
    Duration? duration;
    if (filters.minimumDuration != null || filters.maximumDuration != null) {
      duration = detail?.duration;
      if (duration == null &&
          node is FolderNode &&
          node.totalTrackCount > 0 &&
          node.allTracks.every((track) => track.duration > Duration.zero)) {
        duration = node.totalDuration;
      }
      if (duration == null &&
          node is TrackNode &&
          node.track.duration > Duration.zero) {
        duration = node.track.duration;
      }
    }
    return matchesSearchMetadata(
      filters,
      rating: detail?.rating,
      duration: duration,
      releaseDate: detail?.releaseDate,
    );
  }

  FilteredLibraryTreeResult search(
    String query, {
    SearchFilters filters = emptySearchFilters,
  }) {
    final elements = parseSearchElements(query) ?? emptySearchElements;
    final terms = (
      all: elements.all.map((term) => term.toLowerCase()).toList(),
      any: elements.any.map((term) => term.toLowerCase()).toList(),
    );
    final hasText = terms.all.isNotEmpty || terms.any.isNotEmpty;
    final hasMetadataFilters =
        filters.minimumRating != null ||
        filters.minimumDuration != null ||
        filters.maximumDuration != null ||
        filters.firstReleaseDate != null ||
        filters.lastReleaseDate != null;
    if (!hasText && !hasMetadataFilters) {
      return FilteredLibraryTreeResult(
        tree: tree,
        matchCount: libraryTreeTrackCount(tree),
      );
    }

    final expandedPaths = <String>{};
    var matchCount = 0;
    LibraryNode? filter(LibraryNode node) {
      if (!hasText || matchesNormalizedSearchText(_textFor(node), terms)) {
        matchCount += node is FolderNode ? node.totalTrackCount : 1;
        return node;
      }
      if (node is! FolderNode) return null;
      final children = <LibraryNode>[];
      for (final child in node.children) {
        final result = filter(child);
        if (result != null) children.add(result);
      }
      if (children.isEmpty) return null;
      expandedPaths.add(PathMatcher.normalize(node.path));
      return FolderNode.searchResult(node, children);
    }

    final nodes = <LibraryNode>[];
    for (final node in tree) {
      if (hasMetadataFilters && !_matchesRootMetadata(node, filters)) {
        continue;
      }
      final result = filter(node);
      if (result != null) nodes.add(result);
    }
    return FilteredLibraryTreeResult(
      tree: List.unmodifiable(nodes),
      matchCount: matchCount,
      expandedFolderPaths: expandedPaths,
    );
  }
}

(LibrarySearchCorpus, FilteredLibraryTreeResult)
buildFilteredLibraryTreeSnapshot(
  (LibrarySearchCorpus, String, SearchFilters) input,
) => (input.$1, input.$1.search(input.$2, filters: input.$3));

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
