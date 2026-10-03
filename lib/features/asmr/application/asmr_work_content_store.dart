import 'dart:collection';
import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../domain/asmr_models.dart';
import 'asmr_library_view_state.dart';

typedef AsmrWorkRequestKey = ({
  int workId,
  int contentEpoch,
  int authEpoch,
  int runtimeCacheEpoch,
});

/// Owns work content caches; the library controller coordinates account state.
final class AsmrWorkContentStore {
  AsmrWorkContentStore({required VoidCallback onChanged})
    : _onChanged = onChanged;

  static const int _trackCacheLimit = 32;
  final VoidCallback _onChanged;
  final LinkedHashMap<int, List<AsmrTrackFile>> _trackCache = LinkedHashMap();
  final LinkedHashMap<int, List<AsmrTrackFile>> _visibleTrackCache =
      LinkedHashMap();
  Set<String> _hiddenTracks = <String>{};
  final Map<int, ({AsmrWork work, List<MusicTrack> tracks})>
  _playableTrackCache = {};
  final Set<int> _loadingTrackWorkIds = <int>{};
  final Map<int, Object> _trackTreeErrors = <int, Object>{};
  final Map<AsmrWorkRequestKey, Future<List<AsmrTrackFile>>> _trackTreeTasks =
      <AsmrWorkRequestKey, Future<List<AsmrTrackFile>>>{};
  final Map<int, int> _trackRevisions = <int, int>{};

  Set<String> get hiddenTracks => UnmodifiableSetView(_hiddenTracks);
  bool isLoading(int workId) => _loadingTrackWorkIds.contains(workId);
  List<MusicTrack>? cachedPlayableTracks(AsmrWork work) {
    final cached = _playableTrackCache[work.id];
    return cached != null && identical(cached.work, work)
        ? cached.tracks
        : null;
  }

  List<MusicTrack> storePlayableTracks(AsmrWork work, List<MusicTrack> tracks) {
    final frozen = List<MusicTrack>.unmodifiable(tracks);
    _playableTrackCache[work.id] = (work: work, tracks: frozen);
    return frozen;
  }

  void replaceHiddenTracks(Set<String> tracks, {int? changedWorkId}) {
    _hiddenTracks = tracks;
    if (changedWorkId == null) {
      _visibleTrackCache.clear();
      _playableTrackCache.clear();
    } else {
      _visibleTrackCache.remove(changedWorkId);
      _playableTrackCache.remove(changedWorkId);
      bumpTrackRevision(changedWorkId);
    }
  }

  void clearCaches({bool clearErrors = false}) {
    _trackCache.clear();
    _visibleTrackCache.clear();
    _playableTrackCache.clear();
    if (clearErrors) _trackTreeErrors.clear();
  }

  void clearTrackTreeError(int workId) => _trackTreeErrors.remove(workId);
  void setTrackTreeError(int workId, Object error) =>
      _trackTreeErrors[workId] = error;

  AsmrTrackTreeViewState trackTreeViewState(int workId) {
    final tree = cachedTrackTree(workId);
    return AsmrTrackTreeViewState(
      workId: workId,
      tree: tree,
      visibleTree: tree == null ? null : _visibleTrackTreeFor(workId, tree),
      isLoading: _loadingTrackWorkIds.contains(workId),
      isRefreshing: _loadingTrackWorkIds.contains(workId) && tree != null,
      isStale: _loadingTrackWorkIds.contains(workId) && tree != null,
      operationError: _trackTreeErrors[workId],
      revision: _trackRevisions[workId] ?? 0,
    );
  }

  Future<List<AsmrTrackFile>> requestTrackTree(
    AsmrWorkRequestKey key,
    Future<List<AsmrTrackFile>> Function() load,
  ) {
    final existing = _trackTreeTasks[key];
    if (existing != null) return existing;
    _trackTreeErrors.remove(key.workId);
    if (!_trackTreeTasks.keys.any(
          (candidate) => candidate.workId == key.workId,
        ) &&
        _loadingTrackWorkIds.add(key.workId)) {
      bumpTrackRevision(key.workId);
      _onChanged();
    }
    late final Future<List<AsmrTrackFile>> task;
    task = load().whenComplete(() {
      if (identical(_trackTreeTasks[key], task)) {
        _trackTreeTasks.remove(key);
      }
      if (!_trackTreeTasks.keys.any(
        (candidate) => candidate.workId == key.workId,
      )) {
        _loadingTrackWorkIds.remove(key.workId);
        _trimTrackCache();
        bumpTrackRevision(key.workId);
        _onChanged();
      }
    });
    _trackTreeTasks[key] = task;
    return task;
  }

  void bumpTrackRevision(int workId) {
    _trackRevisions[workId] = (_trackRevisions[workId] ?? 0) + 1;
  }

  void bumpAllTrackRevisions() {
    for (final workId in _trackRevisions.keys.toList(growable: false)) {
      bumpTrackRevision(workId);
    }
  }

  List<AsmrTrackFile>? cachedTrackTree(int workId) {
    final cached = _trackCache.remove(workId);
    if (cached != null) _trackCache[workId] = cached;
    return cached;
  }

  List<AsmrTrackFile> storeTrackTree(int workId, List<AsmrTrackFile> tree) {
    final sortedTree = immutableList(sortAsmrTrackTreeNaturally(tree));
    _trackCache.remove(workId);
    _trackCache[workId] = sortedTree;
    _visibleTrackCache.remove(workId);
    _playableTrackCache.remove(workId);
    _trimTrackCache();
    return sortedTree;
  }

  void _trimTrackCache() {
    while (_trackCache.length > _trackCacheLimit) {
      final evictedWorkId = _trackCache.keys.firstWhere(
        (workId) => !_loadingTrackWorkIds.contains(workId),
        orElse: () => -1,
      );
      if (evictedWorkId < 0) return;
      _trackCache.remove(evictedWorkId);
      _visibleTrackCache.remove(evictedWorkId);
      _playableTrackCache.remove(evictedWorkId);
    }
  }

  List<AsmrTrackFile> _visibleTrackTreeFor(
    int workId,
    List<AsmrTrackFile> tree,
  ) {
    final cached = _visibleTrackCache.remove(workId);
    if (cached != null) {
      _visibleTrackCache[workId] = cached;
      return cached;
    }
    List<AsmrTrackFile> filter(List<AsmrTrackFile> nodes) {
      final result = <AsmrTrackFile>[];
      for (final node in nodes) {
        if (node.isFolder) {
          final children = filter(node.children);
          if (children.isNotEmpty) result.add(node.withChildren(children));
        } else if (node.hasBrowsableContent &&
            !_hiddenTracks.contains('$workId:${node.stableKey}')) {
          result.add(node);
        }
      }
      return result;
    }

    final visible = immutableList(filter(tree));
    _visibleTrackCache[workId] = visible;
    while (_visibleTrackCache.length > _trackCacheLimit) {
      _visibleTrackCache.remove(_visibleTrackCache.keys.first);
    }
    return visible;
  }
}
