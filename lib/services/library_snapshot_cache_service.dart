import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/audio_detail.dart';
import '../models/audio_library_category.dart';
import '../models/library_node.dart';
import '../models/music_track.dart';
import 'app_log_service.dart';
import 'audio_detail_cache_service.dart';
import 'audio_state_services.dart';
import 'library_organizer.dart';
import 'ui_interaction_coordinator.dart';

class LibrarySnapshotCacheService {
  LibrarySnapshotCacheService({
    required LibraryService libraryService,
    required AudioDetailCacheService detailCacheService,
    UiInteractionCoordinator? interactionCoordinator,
  }) : _libraryService = libraryService,
       _detailCacheService = detailCacheService,
       _interactionCoordinator =
           interactionCoordinator ?? UiInteractionCoordinator.instance {
    if (_libraryService.library.isEmpty &&
        _libraryService.watchedFolders.isEmpty) {
      _cachedTreeRevision = _libraryService.structureRevision;
    }
  }

  final LibraryService _libraryService;
  final AudioDetailCacheService _detailCacheService;
  final UiInteractionCoordinator _interactionCoordinator;

  List<LibraryNode> _cachedTree = const <LibraryNode>[];
  int _cachedTreeRevision = -1;
  int _cachedLeafFolderCount = 0;
  Future<LibraryTreeSnapshot>? _treeFuture;
  int _treeFutureRevision = -1;
  final List<VoidCallback> _treeCommitCallbacks = <VoidCallback>[];

  AudioLibraryCategorySnapshot? _categorySnapshot;
  Future<AudioLibraryCategorySnapshot>? _categoryFuture;
  int _categoryFutureStructureRevision = -1;
  int _categoryFutureDetailRevision = -1;
  int _categorySnapshotRevision = 0;

  List<LibraryNode> get tree => _cachedTree;

  int get treeSnapshotRevision => _cachedTreeRevision;

  int get leafFolderCount => _cachedLeafFolderCount;

  int get categorySnapshotRevision => _categorySnapshotRevision;

  AudioLibraryCategorySnapshot? get categorySnapshotSync => _categorySnapshot;

  Future<LibraryTreeSnapshot> treeSnapshot({
    required VoidCallback onCommitted,
  }) {
    final revision = _libraryService.structureRevision;
    if (_cachedTreeRevision == revision) {
      return Future<LibraryTreeSnapshot>.value(
        LibraryTreeSnapshot(
          tree: _cachedTree,
          leafFolderCount: _cachedLeafFolderCount,
        ),
      );
    }
    final inFlight = _treeFuture;
    if (inFlight != null && _treeFutureRevision == revision) {
      _treeCommitCallbacks.add(onCommitted);
      return inFlight;
    }

    final payload = _LibraryTreeBuildPayload(
      tracks: List<MusicTrack>.unmodifiable(_libraryService.library),
      watchedFolders: List<String>.unmodifiable(_libraryService.watchedFolders),
      nodeOrder: List<String>.unmodifiable(_libraryService.libraryNodeOrder),
    );
    final future = AppLogService.measureAsync(
      'library_tree_snapshot_build',
      () => compute(_buildLibraryTreeFromPayload, payload),
      details: <String, Object?>{'tracks': payload.tracks.length},
    );
    _treeFuture = future;
    _treeFutureRevision = revision;
    _treeCommitCallbacks
      ..clear()
      ..add(onCommitted);
    unawaited(
      future
          .then((snapshot) {
            if (_libraryService.structureRevision != revision) return;
            void commit() {
              if (_libraryService.structureRevision != revision) return;
              _cacheTreeSnapshot(snapshot);
              final callbacks = List<VoidCallback>.of(_treeCommitCallbacks);
              _treeCommitCallbacks.clear();
              for (final callback in callbacks) {
                callback();
              }
            }

            if (_interactionCoordinator.isInteracting) {
              _interactionCoordinator.scheduleCommit(
                key: 'library_tree_snapshot',
                priority: 0,
                commit: commit,
              );
            } else {
              commit();
            }
          })
          .whenComplete(() {
            if (identical(_treeFuture, future)) {
              _treeFuture = null;
              _treeCommitCallbacks.clear();
            }
          }),
    );
    return future;
  }

  Future<AudioLibraryCategorySnapshot> categorySnapshot({
    required VoidCallback onCommitted,
  }) {
    final structureRevision = _libraryService.structureRevision;
    final detailRevision = _detailCacheService.revision;
    final cached = _categorySnapshot;
    if (cached != null &&
        cached.structureRevision == structureRevision &&
        cached.detailRevision == detailRevision) {
      return Future<AudioLibraryCategorySnapshot>.value(cached);
    }

    final inFlight = _categoryFuture;
    if (inFlight != null &&
        _categoryFutureStructureRevision == structureRevision &&
        _categoryFutureDetailRevision == detailRevision) {
      return inFlight;
    }

    final future = AppLogService.measureAsync(
      'library_category_snapshot_build',
      () => _buildCategorySnapshot(
        structureRevision: structureRevision,
        detailRevision: detailRevision,
      ),
    );
    _categoryFuture = future;
    _categoryFutureStructureRevision = structureRevision;
    _categoryFutureDetailRevision = detailRevision;
    unawaited(
      future
          .then((snapshot) {
            if (snapshot.structureRevision !=
                    _libraryService.structureRevision ||
                snapshot.detailRevision != _detailCacheService.revision) {
              return;
            }
            void commit() {
              if (snapshot.structureRevision !=
                      _libraryService.structureRevision ||
                  snapshot.detailRevision != _detailCacheService.revision) {
                return;
              }
              _categorySnapshot = snapshot;
              _categorySnapshotRevision++;
              onCommitted();
            }

            if (_interactionCoordinator.isInteracting &&
                _categorySnapshot != null) {
              _interactionCoordinator.scheduleCommit(
                key: 'library_category_snapshot',
                priority: 10,
                commit: commit,
              );
            } else {
              commit();
            }
          })
          .whenComplete(() {
            if (identical(_categoryFuture, future)) {
              _categoryFuture = null;
            }
          }),
    );
    return future;
  }

  void markStructureChanged() {
    _cachedTreeRevision = -1;
    _treeFuture = null;
    _treeCommitCallbacks.clear();
    _categoryFuture = null;
  }

  bool applyCurrentTopLevelOrder() {
    if (_cachedTree.isEmpty) return false;
    final nodesByPath = <String, LibraryNode>{
      for (final node in _cachedTree) node.path: node,
    };
    final nodeOrder = _libraryService.libraryNodeOrder;
    if (nodesByPath.length != _cachedTree.length ||
        nodeOrder.length != _cachedTree.length ||
        nodeOrder.any((path) => !nodesByPath.containsKey(path))) {
      return false;
    }

    _cachedTree = List<LibraryNode>.unmodifiable(
      nodeOrder.map((path) => nodesByPath[path]!),
    );
    _cachedTreeRevision = _libraryService.structureRevision;
    _treeFuture = null;
    _treeFutureRevision = -1;
    _treeCommitCallbacks.clear();
    _categoryFuture = null;
    return true;
  }

  void markDetailChanged([AudioDetail? detail]) {
    _categoryFuture = null;
    if (detail != null) {
      _applyDetailToCategorySnapshot(detail);
    }
  }

  void clear() {
    _cachedTree = const <LibraryNode>[];
    _cachedTreeRevision = -1;
    _cachedLeafFolderCount = 0;
    _treeFuture = null;
    _treeFutureRevision = -1;
    _treeCommitCallbacks.clear();
    _categorySnapshot = null;
    _categoryFuture = null;
    _categoryFutureStructureRevision = -1;
    _categoryFutureDetailRevision = -1;
    _categorySnapshotRevision = 0;
  }

  void _cacheTreeSnapshot(LibraryTreeSnapshot snapshot) {
    _cachedTree = snapshot.tree;
    _cachedLeafFolderCount = snapshot.leafFolderCount;
    _cachedTreeRevision = _libraryService.structureRevision;
  }

  Future<AudioLibraryCategorySnapshot> _buildCategorySnapshot({
    required int structureRevision,
    required int detailRevision,
  }) async {
    final snapshot = await treeSnapshot(onCommitted: () {});
    var tree = snapshot.tree;
    if (_libraryService.structureRevision != structureRevision) {
      tree = _cachedTreeRevision == structureRevision
          ? _cachedTree
          : const <LibraryNode>[];
    }

    final requests = <_CategoryDetailRequest>[];
    for (final node in tree) {
      if (node is FolderNode) {
        final target = AudioDetailTarget.libraryRootFolder(node.path);
        requests.add(
          _CategoryDetailRequest(
            target: target,
            title: node.name,
            path: node.path,
            isFolder: true,
            tracks: List<MusicTrack>.unmodifiable(node.allTracks),
          ),
        );
      } else if (node is TrackNode && node.track.isSingle) {
        final target = AudioDetailTarget.singleAudioFile(node.track.path);
        requests.add(
          _CategoryDetailRequest(
            target: target,
            title: node.track.displayName,
            path: node.track.path,
            isFolder: false,
            tracks: List<MusicTrack>.unmodifiable([node.track]),
          ),
        );
      }
    }

    final details = await _loadCategoryDetails(
      requests.map((request) => request.target),
    );
    final entries = <AudioLibraryCategoryEntry>[
      for (var i = 0; i < requests.length; i++)
        AudioLibraryCategoryEntry(
          target: requests[i].target,
          title: requests[i].title,
          path: requests[i].path,
          isFolder: requests[i].isFolder,
          detail: details[i],
          tracks: requests[i].tracks,
        ),
    ];
    return _categorySnapshotFromEntries(
      entries,
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
  }

  Future<List<AudioDetail>> _loadCategoryDetails(
    Iterable<AudioDetailTarget> targets,
  ) async {
    final orderedTargets = targets.toList(growable: false);
    if (orderedTargets.isEmpty) return const <AudioDetail>[];
    try {
      final results = await _detailCacheService.loadMany(orderedTargets);
      return results.map((result) => result.detail).toList(growable: false);
    } catch (_) {
      return <AudioDetail>[
        for (final target in orderedTargets) AudioDetail.empty(target),
      ];
    }
  }

  void _applyDetailToCategorySnapshot(AudioDetail detail) {
    final cached = _categorySnapshot;
    if (cached == null) return;

    final targetKey = AudioLibraryCategorySnapshot.targetKey(detail.target);
    var changed = false;
    final updatedEntries = cached.entries
        .map((entry) {
          if (AudioLibraryCategorySnapshot.targetKey(entry.target) !=
              targetKey) {
            return entry;
          }
          changed = true;
          return AudioLibraryCategoryEntry(
            target: entry.target,
            title: entry.title,
            path: entry.path,
            isFolder: entry.isFolder,
            detail: detail,
            tracks: entry.tracks,
          );
        })
        .toList(growable: false);
    if (!changed) return;

    _categorySnapshot = _categorySnapshotFromEntries(
      updatedEntries,
      structureRevision: _libraryService.structureRevision,
      detailRevision: _detailCacheService.revision,
    );
  }

  AudioLibraryCategorySnapshot _categorySnapshotFromEntries(
    List<AudioLibraryCategoryEntry> entries, {
    required int structureRevision,
    required int detailRevision,
  }) {
    final tagFrequencies = <String, int>{};
    final voiceActorFrequencies = <String, int>{};
    final circleFrequencies = <String, int>{};
    for (final entry in entries) {
      _countCategoryTerms(
        entry,
        tagFrequencies,
        voiceActorFrequencies,
        circleFrequencies,
      );
    }
    return AudioLibraryCategorySnapshot(
      entries: List<AudioLibraryCategoryEntry>.unmodifiable(entries),
      tagTerms: AudioLibraryCategorySnapshot.sortTermsByFrequency(
        tagFrequencies,
      ),
      voiceActorTerms: AudioLibraryCategorySnapshot.sortTermsByFrequency(
        voiceActorFrequencies,
      ),
      circleTerms: AudioLibraryCategorySnapshot.sortTermsByFrequency(
        circleFrequencies,
      ),
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
  }

  void _countCategoryTerms(
    AudioLibraryCategoryEntry entry,
    Map<String, int> tagFrequencies,
    Map<String, int> voiceActorFrequencies,
    Map<String, int> circleFrequencies,
  ) {
    for (final term in AudioLibraryCategorySnapshot.splitTerms(
      entry.detail.tags,
    )) {
      tagFrequencies[term] = (tagFrequencies[term] ?? 0) + 1;
    }
    for (final term in AudioLibraryCategorySnapshot.splitTerms(
      entry.detail.voiceActors,
    )) {
      voiceActorFrequencies[term] = (voiceActorFrequencies[term] ?? 0) + 1;
    }
    for (final term in AudioLibraryCategorySnapshot.splitTerms([
      entry.detail.circleName,
    ])) {
      circleFrequencies[term] = (circleFrequencies[term] ?? 0) + 1;
    }
  }
}

class _LibraryTreeBuildPayload {
  const _LibraryTreeBuildPayload({
    required this.tracks,
    required this.watchedFolders,
    required this.nodeOrder,
  });

  final List<MusicTrack> tracks;
  final List<String> watchedFolders;
  final List<String> nodeOrder;
}

class _CategoryDetailRequest {
  const _CategoryDetailRequest({
    required this.target,
    required this.title,
    required this.path,
    required this.isFolder,
    required this.tracks,
  });

  final AudioDetailTarget target;
  final String title;
  final String path;
  final bool isFolder;
  final List<MusicTrack> tracks;
}

LibraryTreeSnapshot _buildLibraryTreeFromPayload(
  _LibraryTreeBuildPayload payload,
) {
  return const LibraryOrganizer().buildTree(
    tracks: payload.tracks,
    watchedFolders: payload.watchedFolders,
    nodeOrder: payload.nodeOrder,
  );
}
