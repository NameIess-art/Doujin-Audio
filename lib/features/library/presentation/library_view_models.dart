import 'dart:async';
import 'dart:isolate';

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

  bool get canPullRefresh => watchedFolderCount > 0 || watchedLibraryCount > 0;

  @override
  bool operator ==(Object other) {
    return other is LibraryListState &&
        identical(other.rawTree, rawTree) &&
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
    Map<String, bool>? workSubtitleCache,
    Map<String, bool>? trackSubtitleCache,
  }) async {
    if (tree.isEmpty) return this;
    Future<bool> checkTrackCached(String trackPath) async {
      if (trackSubtitleCache == null) return checkTrack(trackPath);
      final key = PathMatcher.equivalenceKey(trackPath);
      final cached = trackSubtitleCache[key];
      if (cached != null) return cached;
      final found = await checkTrack(trackPath);
      if (isActive()) {
        trackSubtitleCache[key] = found;
      }
      return found;
    }

    Future<bool> checkWork(LibraryNode node) async {
      if (node is TrackNode) return checkTrackCached(node.path);
      if (node is! FolderNode) return false;
      final workKey = workSubtitleCache == null
          ? null
          : PathMatcher.equivalenceKey(node.path);
      if (workKey != null) {
        final cached = workSubtitleCache![workKey];
        if (cached != null) return cached;
      }
      // Text search can trim a folder. Test subtitle availability on the work.
      final tracks =
          snapshot
              .entryFor(AudioDetailTarget.libraryRootFolder(node.path))
              ?.tracks ??
          node.allTracks;
      for (final track in tracks) {
        if (!isActive()) return false;
        if (await checkTrackCached(track.path)) {
          if (workKey != null && isActive()) {
            workSubtitleCache![workKey] = true;
          }
          return true;
        }
      }
      if (workKey != null && isActive()) {
        workSubtitleCache![workKey] = false;
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
        expandedPaths.isNotEmpty &&
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
  int? _subtitleCacheStructureRevision;
  Map<String, bool> _workSubtitleCache = <String, bool>{};
  Map<String, bool> _trackSubtitleCache = <String, bool>{};

  static const int _maxEntries = 12;

  (List<LibraryNode>, int, int)? _corpusKey;
  _LibrarySearchCorpus? _corpus;
  (List<LibraryNode>, int, int)? _workerKey;
  _LibrarySearchWorker? _worker;

  void _syncSubtitleCacheRevision(int structureRevision) {
    if (_subtitleCacheStructureRevision == structureRevision) return;
    _subtitleCacheStructureRevision = structureRevision;
    _workSubtitleCache = <String, bool>{};
    _trackSubtitleCache = <String, bool>{};
  }

  Map<String, bool> workSubtitleCacheForRevision(int structureRevision) {
    _syncSubtitleCacheRevision(structureRevision);
    return _workSubtitleCache;
  }

  Map<String, bool> trackSubtitleCacheForRevision(int structureRevision) {
    _syncSubtitleCacheRevision(structureRevision);
    return _trackSubtitleCache;
  }

  void invalidateSubtitleCache() {
    _workSubtitleCache = <String, bool>{};
    _trackSubtitleCache = <String, bool>{};
    _cache.removeWhere((key, _) => key.$2.hasSubtitle != null);
  }

  Future<FilteredLibraryTreeResult> searchInBackground({
    required List<LibraryNode> tree,
    required String query,
    required int structureRevision,
    required int detailRevision,
    required AudioLibraryCategorySnapshot categorySnapshot,
    SearchFilters filters = emptySearchFilters,
  }) async {
    final key = (tree, structureRevision, detailRevision);
    if (_workerKey != key || _worker?.isClosed != false) {
      // Only a new snapshot transfers the source tree to the worker.
      _worker?.dispose();
      _workerKey = key;
      _worker = _LibrarySearchWorker(tree, categorySnapshot);
    }
    final worker = _worker!;
    final selection = await worker.search(query, filters);
    return _projectLibrarySearchSelection(tree, selection);
  }

  void dispose() {
    _worker?.dispose();
    _worker = null;
    _workerKey = null;
    _corpus = null;
    _corpusKey = null;
    _workSubtitleCache.clear();
    _trackSubtitleCache.clear();
    _cache.clear();
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
      _corpus = _LibrarySearchCorpus(tree, categorySnapshot);
    }
    final result = _projectLibrarySearchSelection(
      tree,
      _corpus!.select(query, filters),
    );
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
class _LibrarySearchCorpus {
  _LibrarySearchCorpus(
    this.tree,
    AudioLibraryCategorySnapshot? categorySnapshot,
  ) : _categorySnapshot = categorySnapshot;

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
      userRating: detail?.userRating,
      listenStatus: detail?.listenStatus,
      duration: duration,
      releaseDate: detail?.releaseDate,
    );
  }

  _LibrarySearchSelection select(String query, SearchFilters filters) {
    final elements = parseSearchElements(query) ?? emptySearchElements;
    final terms = (
      all: elements.all.map((term) => term.toLowerCase()).toList(),
      any: elements.any.map((term) => term.toLowerCase()).toList(),
    );
    final hasText = terms.all.isNotEmpty || terms.any.isNotEmpty;
    final hasMetadataFilters =
        filters.minimumRating != null ||
        filters.minimumUserRating != null ||
        filters.listenStatus != null ||
        filters.minimumDuration != null ||
        filters.maximumDuration != null ||
        filters.firstReleaseDate != null ||
        filters.lastReleaseDate != null;
    if (!hasText && !hasMetadataFilters) {
      return (branches: null, matchCount: libraryTreeTrackCount(tree));
    }

    final branches = <int>[];
    var matchCount = 0;
    bool filter(LibraryNode node, int index) {
      final start = branches.length;
      if (!hasText || matchesNormalizedSearchText(_textFor(node), terms)) {
        matchCount += node is FolderNode ? node.totalTrackCount : 1;
        branches.add(index);
        branches.add(0);
        return true;
      }
      if (node is! FolderNode) return false;
      branches.add(index);
      branches.add(0);
      var matchedChildren = 0;
      for (var child = 0; child < node.children.length; child++) {
        if (filter(node.children[child], child)) matchedChildren++;
      }
      if (matchedChildren == 0) {
        branches.length = start;
        return false;
      }
      branches[start + 1] = matchedChildren;
      return true;
    }

    for (var index = 0; index < tree.length; index++) {
      final node = tree[index];
      if (hasMetadataFilters && !_matchesRootMetadata(node, filters)) {
        continue;
      }
      filter(node, index);
    }
    return (branches: branches, matchCount: matchCount);
  }
}

// Each selected branch is a sibling index and a selected-child count.
// Zero children means the original node matched and can be reused whole.
typedef _LibrarySearchSelection = ({List<int>? branches, int matchCount});

FilteredLibraryTreeResult _projectLibrarySearchSelection(
  List<LibraryNode> tree,
  _LibrarySearchSelection selection,
) {
  final branches = selection.branches;
  if (branches == null) {
    return FilteredLibraryTreeResult(
      tree: tree,
      matchCount: selection.matchCount,
    );
  }
  final expanded = <String>{};
  var offset = 0;
  LibraryNode project(List<LibraryNode> siblings) {
    final node = siblings[branches[offset++]];
    final count = branches[offset++];
    if (count == 0) return node;
    final folder = node as FolderNode;
    expanded.add(PathMatcher.normalize(folder.path));
    return FolderNode.searchResult(folder, [
      for (var child = 0; child < count; child++) project(folder.children),
    ]);
  }

  final nodes = <LibraryNode>[];
  while (offset < branches.length) {
    nodes.add(project(tree));
  }
  return FilteredLibraryTreeResult(
    tree: List.unmodifiable(nodes),
    matchCount: selection.matchCount,
    expandedFolderPaths: expanded,
  );
}

final class _LibrarySearchWorker {
  _LibrarySearchWorker(
    List<LibraryNode> tree,
    AudioLibraryCategorySnapshot categorySnapshot,
  ) {
    _messages.listen(_receive);
    unawaited(_start(tree, categorySnapshot));
  }

  final _messages = ReceivePort();
  SendPort? _requests;
  Completer<_LibrarySearchSelection>? _inFlight;
  ({
    String query,
    SearchFilters filters,
    Completer<_LibrarySearchSelection> completer,
  })?
  _queued;
  Isolate? _isolate;
  bool isClosed = false;

  Future<void> _start(
    List<LibraryNode> tree,
    AudioLibraryCategorySnapshot categorySnapshot,
  ) async {
    try {
      final isolate = await Isolate.spawn(
        _serveLibrarySearches,
        (tree, categorySnapshot, _messages.sendPort),
        onError: _messages.sendPort,
        onExit: _messages.sendPort,
        debugName: 'library_search',
      );
      if (isClosed) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    } catch (error, stack) {
      _close(error, stack);
    }
  }

  Future<_LibrarySearchSelection> search(String query, SearchFilters filters) {
    if (isClosed) {
      return Future<_LibrarySearchSelection>.error(
        StateError('Library search was closed.'),
      );
    }
    final superseded = _queued;
    if (superseded != null) {
      _queued = null;
      superseded.completer.completeError(
        StateError('Library search was superseded.'),
      );
    }
    final response = Completer<_LibrarySearchSelection>();
    final requests = _requests;
    if (requests != null && _inFlight == null) {
      _inFlight = response;
      requests.send((query, filters));
    } else {
      _queued = (query: query, filters: filters, completer: response);
    }
    return response.future;
  }

  void _dispatchNext() {
    final requests = _requests;
    final next = _queued;
    if (isClosed || requests == null || _inFlight != null || next == null) {
      return;
    }
    _queued = null;
    _inFlight = next.completer;
    requests.send((next.query, next.filters));
  }

  void _receive(Object? message) {
    if (message is SendPort) {
      _requests = message;
      _dispatchNext();
    } else if (message is _LibrarySearchSelection) {
      final completer = _inFlight;
      _inFlight = null;
      completer?.complete(message);
      _dispatchNext();
    } else if (message case [final String error, final String stack]) {
      final remote = RemoteError(error, stack);
      _close(remote, remote.stackTrace);
    } else {
      _close(StateError('Library search isolate stopped.'));
    }
  }

  void dispose() => _close(StateError('Library search was closed.'));

  void _close(Object error, [StackTrace? stack]) {
    if (isClosed) return;
    isClosed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _messages.close();
    final inFlight = _inFlight;
    _inFlight = null;
    inFlight?.completeError(error, stack);
    final queued = _queued;
    _queued = null;
    queued?.completer.completeError(error, stack);
  }
}

void _serveLibrarySearches(
  (List<LibraryNode>, AudioLibraryCategorySnapshot, SendPort) startup,
) {
  final (tree, categorySnapshot, responses) = startup;
  final corpus = _LibrarySearchCorpus(tree, categorySnapshot);
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((message) {
    final (query, filters) = message as (String, SearchFilters);
    responses.send(corpus.select(query, filters));
  });
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
