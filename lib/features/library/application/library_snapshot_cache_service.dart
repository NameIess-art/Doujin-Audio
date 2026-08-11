import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/audio_detail.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../../../core/media/music_track.dart';
import '../../../core/logging/app_log_service.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'library_service.dart';
import 'library_organizer.dart';

@immutable
class LibraryDerivedSnapshotPayload {
  LibraryDerivedSnapshotPayload({
    required List<MusicTrack> tracks,
    required List<String> watchedFolders,
    List<String> watchedLibraries = const <String>[],
  }) : tracks = immutableList(tracks),
       watchedFolders = immutableList(watchedFolders),
       watchedLibraries = immutableList(watchedLibraries);

  final List<MusicTrack> tracks;
  final List<String> watchedFolders;
  final List<String> watchedLibraries;
}

@immutable
class LibraryDerivedSnapshot {
  LibraryDerivedSnapshot({
    required List<MusicTrack> library,
    required Map<String, MusicTrack> libraryByPath,
    required Map<String, int> libraryIndexByPath,
    required Map<String, List<MusicTrack>> tracksByGroup,
    required List<MusicTrack> sortedLibraryTracks,
    required List<String> sortedLibraryTrackPaths,
    required this.cardSnapshot,
  }) : library = immutableList(library),
       libraryByPath = immutableMap(libraryByPath),
       libraryIndexByPath = immutableMap(libraryIndexByPath),
       tracksByGroup = immutableMap(
         tracksByGroup.map((key, value) => MapEntry(key, immutableList(value))),
       ),
       sortedLibraryTracks = immutableList(sortedLibraryTracks),
       sortedLibraryTrackPaths = immutableList(sortedLibraryTrackPaths);

  final List<MusicTrack> library;
  final Map<String, MusicTrack> libraryByPath;
  final Map<String, int> libraryIndexByPath;
  final Map<String, List<MusicTrack>> tracksByGroup;
  final List<MusicTrack> sortedLibraryTracks;
  final List<String> sortedLibraryTrackPaths;
  final LibraryTreeSnapshot cardSnapshot;
}

LibraryDerivedSnapshot buildLibraryDerivedSnapshot(
  LibraryDerivedSnapshotPayload payload,
) {
  const organizer = LibraryOrganizer();
  final library = List<MusicTrack>.of(payload.tracks);
  final libraryByPath = <String, MusicTrack>{};
  final libraryIndexByPath = <String, int>{};
  for (var index = 0; index < library.length; index++) {
    final track = library[index];
    libraryByPath[track.path] = track;
    libraryIndexByPath[track.path] = index;
  }
  final sortedTracks = List<MusicTrack>.of(library)
    ..sort(organizer.compareTracks);
  final tracksByGroup = <String, List<MusicTrack>>{};
  for (final track in sortedTracks) {
    tracksByGroup.putIfAbsent(track.groupKey, () => <MusicTrack>[]).add(track);
  }
  final immutableTracksByGroup = tracksByGroup.map(
    (groupKey, tracks) =>
        MapEntry(groupKey, List<MusicTrack>.unmodifiable(tracks)),
  );
  final cardSnapshot = organizer.buildCardTree(
    tracks: sortedTracks,
    watchedFolders: payload.watchedFolders,
    watchedLibraries: payload.watchedLibraries,
    tracksAlreadySorted: true,
  );
  return LibraryDerivedSnapshot(
    library: library,
    libraryByPath: libraryByPath,
    libraryIndexByPath: libraryIndexByPath,
    tracksByGroup: immutableTracksByGroup,
    sortedLibraryTracks: List<MusicTrack>.unmodifiable(sortedTracks),
    sortedLibraryTrackPaths: List<String>.unmodifiable(
      sortedTracks.map((track) => track.path),
    ),
    cardSnapshot: cardSnapshot,
  );
}

typedef LibraryCardSnapshotBuilder =
    Future<LibraryTreeSnapshot> Function(LibraryDerivedSnapshotPayload payload);

Future<LibraryTreeSnapshot> _defaultCardSnapshotBuilder(
  LibraryDerivedSnapshotPayload payload,
) {
  return compute(
    _buildLibraryCardsFromPayload,
    _LibraryTreeBuildPayload(
      tracks: payload.tracks,
      watchedFolders: payload.watchedFolders,
      watchedLibraries: payload.watchedLibraries,
    ),
  );
}

class LibrarySnapshotCacheService {
  LibrarySnapshotCacheService({
    required LibraryService libraryService,
    required AudioDetailCacheService detailCacheService,
    LibraryCardSnapshotBuilder? cardSnapshotBuilder,
  }) : _libraryService = libraryService,
       _detailCacheService = detailCacheService,
       _cardSnapshotBuilder =
           cardSnapshotBuilder ?? _defaultCardSnapshotBuilder {
    if (_libraryService.library.isEmpty &&
        _libraryService.watchedFolders.isEmpty) {
      _cachedCardRevision = _libraryService.structureRevision;
      _cachedTreeRevision = _libraryService.structureRevision;
    }
  }

  final LibraryService _libraryService;
  final AudioDetailCacheService _detailCacheService;
  final LibraryCardSnapshotBuilder _cardSnapshotBuilder;

  List<LibraryNode> _cachedCards = const <LibraryNode>[];
  int _cachedCardRevision = -1;
  int _cachedCardLeafFolderCount = 0;
  Future<LibraryTreeSnapshot>? _cardFuture;
  int _cardFutureRevision = -1;
  final List<VoidCallback> _cardCommitCallbacks = <VoidCallback>[];

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

  List<LibraryNode> get cards => _cachedCards;

  int get cardSnapshotRevision => _cachedCardRevision;

  List<LibraryNode> get tree => _cachedTree;

  int get treeSnapshotRevision => _cachedTreeRevision;

  int get leafFolderCount => _cachedCardLeafFolderCount;

  int get categorySnapshotRevision => _categorySnapshotRevision;

  AudioLibraryCategorySnapshot? get categorySnapshotSync => _categorySnapshot;

  void adoptCardSnapshot(LibraryTreeSnapshot snapshot) {
    _cacheCardSnapshot(snapshot);
    _cardFuture = null;
    _cardFutureRevision = -1;
    _cardCommitCallbacks.clear();
    _categoryFuture = null;
  }

  Future<LibraryTreeSnapshot> cardSnapshot({
    required VoidCallback onCommitted,
  }) {
    final revision = _libraryService.structureRevision;
    if (_cachedCardRevision == revision) {
      return Future<LibraryTreeSnapshot>.value(
        LibraryTreeSnapshot(
          tree: _cachedCards,
          leafFolderCount: _cachedCardLeafFolderCount,
        ),
      );
    }
    final inFlight = _cardFuture;
    if (inFlight != null && _cardFutureRevision == revision) {
      _cardCommitCallbacks.add(onCommitted);
      return inFlight;
    }

    final payload = LibraryDerivedSnapshotPayload(
      tracks: List<MusicTrack>.unmodifiable(_libraryService.library),
      watchedFolders: List<String>.unmodifiable(_libraryService.watchedFolders),
      watchedLibraries: List<String>.unmodifiable(
        _libraryService.watchedLibraries,
      ),
    );
    final buildFuture = AppLogService.measureAsync(
      'library_card_snapshot_build',
      () => _cardSnapshotBuilder(payload),
      details: <String, Object?>{'tracks': payload.tracks.length},
    );
    _cardFutureRevision = revision;
    _cardCommitCallbacks
      ..clear()
      ..add(onCommitted);
    late final Future<LibraryTreeSnapshot> future;
    future = buildFuture
        .then((snapshot) {
          if (_libraryService.structureRevision == revision) {
            final callbacks = List<VoidCallback>.of(_cardCommitCallbacks);
            _cacheCardSnapshot(snapshot);
            for (final callback in callbacks) {
              callback();
            }
          }
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_cardFuture, future)) {
            _cardFuture = null;
            _cardCommitCallbacks.clear();
          }
        });
    _cardFuture = future;
    return future;
  }

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
      watchedLibraries: List<String>.unmodifiable(
        _libraryService.watchedLibraries,
      ),
    );
    final buildFuture = AppLogService.measureAsync(
      'library_tree_snapshot_build',
      () => compute(_buildLibraryTreeFromPayload, payload),
      details: <String, Object?>{'tracks': payload.tracks.length},
    );
    _treeFutureRevision = revision;
    _treeCommitCallbacks
      ..clear()
      ..add(onCommitted);
    late final Future<LibraryTreeSnapshot> future;
    future = buildFuture
        .then((snapshot) {
          if (_libraryService.structureRevision == revision) {
            _cacheTreeSnapshot(snapshot);
            final callbacks = List<VoidCallback>.of(_treeCommitCallbacks);
            for (final callback in callbacks) {
              callback();
            }
          }
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_treeFuture, future)) {
            _treeFuture = null;
            _treeCommitCallbacks.clear();
          }
        });
    _treeFuture = future;
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

    final buildFuture = AppLogService.measureAsync(
      'library_category_database_snapshot_build',
      () => _buildCategorySnapshot(
        structureRevision: structureRevision,
        detailRevision: detailRevision,
      ),
      details: <String, Object?>{'tracks': _libraryService.library.length},
    );
    _categoryFutureStructureRevision = structureRevision;
    _categoryFutureDetailRevision = detailRevision;
    late final Future<AudioLibraryCategorySnapshot> future;
    future = buildFuture
        .then((snapshot) {
          if (snapshot.structureRevision == _libraryService.structureRevision &&
              snapshot.detailRevision == _detailCacheService.revision) {
            _categorySnapshot = snapshot;
            _categorySnapshotRevision++;
            onCommitted();
          }
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_categoryFuture, future)) {
            _categoryFuture = null;
          }
        });
    _categoryFuture = future;
    return future;
  }

  void markStructureChanged() {
    _cachedCardRevision = -1;
    _cardFuture = null;
    _cardCommitCallbacks.clear();
    _cachedTreeRevision = -1;
    _treeFuture = null;
    _treeCommitCallbacks.clear();
    _categoryFuture = null;
  }

  void markDetailChanged([AudioDetail? detail]) {
    _categoryFuture = null;
    if (detail != null) {
      _applyDetailToCategorySnapshot(detail);
    }
  }

  void clear() {
    _cachedCards = const <LibraryNode>[];
    _cachedCardRevision = -1;
    _cachedCardLeafFolderCount = 0;
    _cardFuture = null;
    _cardFutureRevision = -1;
    _cardCommitCallbacks.clear();
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

  void _cacheCardSnapshot(LibraryTreeSnapshot snapshot) {
    _cachedCards = snapshot.tree;
    _cachedCardLeafFolderCount = snapshot.leafFolderCount;
    _cachedCardRevision = _libraryService.structureRevision;
  }

  Future<AudioLibraryCategorySnapshot> _buildCategorySnapshot({
    required int structureRevision,
    required int detailRevision,
  }) async {
    final snapshot = await cardSnapshot(onCommitted: () {});
    var tree = snapshot.tree;
    if (_libraryService.structureRevision != structureRevision) {
      tree = _cachedCardRevision == structureRevision
          ? _cachedCards
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

    final targets = requests.map((request) => request.target);
    final details = await _loadCategoryDetails(targets);
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
    List<AudioDetailLoadResult> results;
    try {
      results = await _detailCacheService.loadMany(orderedTargets);
    } catch (_) {
      results = await Future.wait(
        orderedTargets.map((target) async {
          try {
            return await _detailCacheService.load(target);
          } catch (_) {
            return AudioDetailLoadResult(detail: AudioDetail.empty(target));
          }
        }),
      );
    }
    return List<AudioDetail>.unmodifiable(
      results.map((result) => result.detail),
    );
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
  _LibraryTreeBuildPayload({
    required List<MusicTrack> tracks,
    required List<String> watchedFolders,
    required List<String> watchedLibraries,
  }) : tracks = immutableList(tracks),
       watchedFolders = immutableList(watchedFolders),
       watchedLibraries = immutableList(watchedLibraries);

  final List<MusicTrack> tracks;
  final List<String> watchedFolders;
  final List<String> watchedLibraries;
}

class _CategoryDetailRequest {
  _CategoryDetailRequest({
    required this.target,
    required this.title,
    required this.path,
    required this.isFolder,
    required List<MusicTrack> tracks,
  }) : tracks = immutableList(tracks);

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
    watchedLibraries: payload.watchedLibraries,
  );
}

LibraryTreeSnapshot _buildLibraryCardsFromPayload(
  _LibraryTreeBuildPayload payload,
) {
  return const LibraryOrganizer().buildCardTree(
    tracks: payload.tracks,
    watchedFolders: payload.watchedFolders,
    watchedLibraries: payload.watchedLibraries,
  );
}
