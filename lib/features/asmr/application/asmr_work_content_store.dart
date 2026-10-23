import 'dart:collection';
import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../domain/asmr_models.dart';
import 'asmr_library_view_state.dart';
import 'asmr_request_cancellation.dart';

typedef AsmrWorkRequestKey = ({
  String workKey,
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
  final LinkedHashMap<String, List<AsmrTrackFile>> _trackCache =
      LinkedHashMap();
  final LinkedHashMap<String, List<AsmrTrackFile>> _visibleTrackCache =
      LinkedHashMap();
  final Map<String, ({AsmrWork work, List<MusicTrack> tracks})>
  _playableTrackCache = {};
  final Map<
    (AsmrWorkRequestKey, AsmrWork, List<AsmrTrackFile>),
    Future<List<MusicTrack>>
  >
  _playableTrackTasks = {};
  final Set<String> _loadingTrackWorkIds = <String>{};
  final Map<String, Object> _trackTreeErrors = <String, Object>{};
  final Map<
    AsmrWorkRequestKey,
    ({
      Future<List<AsmrTrackFile>> task,
      AsmrRequestCancellationToken cancellationToken,
    })
  >
  _trackTreeTasks = {};
  final Map<String, int> _trackRevisions = <String, int>{};

  bool isLoading(String workKey) => _loadingTrackWorkIds.contains(workKey);
  List<MusicTrack>? cachedPlayableTracks(AsmrWork work) {
    final cached = _playableTrackCache[work.workKey];
    return cached != null && identical(cached.work, work)
        ? cached.tracks
        : null;
  }

  List<MusicTrack> storePlayableTracks(AsmrWork work, List<MusicTrack> tracks) {
    final frozen = List<MusicTrack>.unmodifiable(tracks);
    _playableTrackCache[work.workKey] = (work: work, tracks: frozen);
    return frozen;
  }

  Future<List<MusicTrack>> requestPlayableTracks(
    AsmrWorkRequestKey key,
    AsmrWork work,
    List<AsmrTrackFile> tree,
    Future<List<MusicTrack>> Function() load,
  ) {
    final request = (key, work, tree);
    final existing = _playableTrackTasks[request];
    if (existing != null) return existing;
    late final Future<List<MusicTrack>> task;
    task = load().whenComplete(() {
      if (identical(_playableTrackTasks[request], task)) {
        _playableTrackTasks.remove(request);
      }
    });
    _playableTrackTasks[request] = task;
    return task;
  }

  void clearCaches({bool clearErrors = false}) {
    cancelRequests();
    _trackCache.clear();
    _visibleTrackCache.clear();
    _playableTrackCache.clear();
    _playableTrackTasks.clear();
    if (clearErrors) _trackTreeErrors.clear();
  }

  void cancelRequests() {
    for (final request in _trackTreeTasks.values.toList(growable: false)) {
      request.cancellationToken.cancel();
    }
  }

  void clearTrackTreeError(String workKey) => _trackTreeErrors.remove(workKey);
  void setTrackTreeError(String workKey, Object error) =>
      _trackTreeErrors[workKey] = error;

  AsmrTrackTreeViewState trackTreeViewState(String workKey) {
    final tree = cachedTrackTree(workKey);
    return AsmrTrackTreeViewState(
      workKey: workKey,
      tree: tree,
      visibleTree: tree == null ? null : _visibleTrackTreeFor(workKey, tree),
      isLoading: _loadingTrackWorkIds.contains(workKey),
      isRefreshing: _loadingTrackWorkIds.contains(workKey) && tree != null,
      isStale: _loadingTrackWorkIds.contains(workKey) && tree != null,
      operationError: _trackTreeErrors[workKey],
      revision: _trackRevisions[workKey] ?? 0,
    );
  }

  Future<List<AsmrTrackFile>> requestTrackTree(
    AsmrWorkRequestKey key,
    Future<List<AsmrTrackFile>> Function(AsmrRequestCancellationToken) load,
  ) {
    final existing = _trackTreeTasks[key];
    if (existing != null) return existing.task;
    _trackTreeErrors.remove(key.workKey);
    if (!_trackTreeTasks.keys.any(
          (candidate) => candidate.workKey == key.workKey,
        ) &&
        _loadingTrackWorkIds.add(key.workKey)) {
      bumpTrackRevision(key.workKey);
      _onChanged();
    }
    final cancellationToken = AsmrRequestCancellationToken();
    late final Future<List<AsmrTrackFile>> task;
    task = load(cancellationToken).whenComplete(() {
      if (identical(_trackTreeTasks[key]?.task, task)) {
        _trackTreeTasks.remove(key);
      }
      if (!_trackTreeTasks.keys.any(
        (candidate) => candidate.workKey == key.workKey,
      )) {
        _loadingTrackWorkIds.remove(key.workKey);
        _trimTrackCache();
        bumpTrackRevision(key.workKey);
        _onChanged();
      }
    });
    _trackTreeTasks[key] = (task: task, cancellationToken: cancellationToken);
    return task;
  }

  void bumpTrackRevision(String workKey) {
    _trackRevisions[workKey] = (_trackRevisions[workKey] ?? 0) + 1;
  }

  void bumpAllTrackRevisions() {
    for (final workKey in _trackRevisions.keys.toList(growable: false)) {
      bumpTrackRevision(workKey);
    }
  }

  List<AsmrTrackFile>? cachedTrackTree(String workKey) {
    final cached = _trackCache.remove(workKey);
    if (cached != null) _trackCache[workKey] = cached;
    return cached;
  }

  List<AsmrTrackFile> storeTrackTree(String workKey, List<AsmrTrackFile> tree) {
    final sortedTree = immutableList(tree);
    _trackCache.remove(workKey);
    _trackCache[workKey] = sortedTree;
    _visibleTrackCache.remove(workKey);
    _playableTrackCache.remove(workKey);
    _trimTrackCache();
    return sortedTree;
  }

  void _trimTrackCache() {
    while (_trackCache.length > _trackCacheLimit) {
      final evictedWorkId = _trackCache.keys.firstWhere(
        (workKey) => !_loadingTrackWorkIds.contains(workKey),
        orElse: () => '',
      );
      if (evictedWorkId.isEmpty) return;
      _trackCache.remove(evictedWorkId);
      _visibleTrackCache.remove(evictedWorkId);
      _playableTrackCache.remove(evictedWorkId);
    }
  }

  List<AsmrTrackFile> _visibleTrackTreeFor(
    String workKey,
    List<AsmrTrackFile> tree,
  ) {
    final cached = _visibleTrackCache.remove(workKey);
    if (cached != null) {
      _visibleTrackCache[workKey] = cached;
      return cached;
    }
    List<AsmrTrackFile> filter(List<AsmrTrackFile> nodes) {
      final result = <AsmrTrackFile>[];
      for (final node in nodes) {
        if (node.isFolder) {
          final children = filter(node.children);
          if (children.isNotEmpty) result.add(node.withChildren(children));
        } else if (node.hasBrowsableContent) {
          result.add(node);
        }
      }
      return result;
    }

    final visible = immutableList(filter(tree));
    _visibleTrackCache[workKey] = visible;
    while (_visibleTrackCache.length > _trackCacheLimit) {
      _visibleTrackCache.remove(_visibleTrackCache.keys.first);
    }
    return visible;
  }
}
