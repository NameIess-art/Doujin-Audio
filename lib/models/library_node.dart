import 'music_track.dart';

abstract class LibraryNode {
  String get name;
  String get path;
}

class FolderNode extends LibraryNode {
  FolderNode(this.name, this.path, {this.depth = 0});

  @override
  final String name;

  @override
  final String path;

  final int depth;
  final List<LibraryNode> children = [];
  List<MusicTrack>? _allTracksCache;
  MusicTrack? _firstTrackCache;
  int? _cachedTotalTrackCount;
  int? _cachedLeafFolderCount;
  Duration? _cachedTotalDuration;

  bool get isModuleNode => depth == 0;

  List<MusicTrack> get allTracks {
    final cached = _allTracksCache;
    if (cached != null) {
      return cached;
    }

    final list = <MusicTrack>[];
    for (final child in children) {
      if (child is TrackNode) {
        list.add(child.track);
      } else if (child is FolderNode) {
        list.addAll(child.allTracks);
      }
    }
    _allTracksCache = list;
    return list;
  }

  MusicTrack? get firstTrack {
    final cached = _firstTrackCache;
    if (cached != null) {
      return cached;
    }

    for (final child in children) {
      if (child is TrackNode) {
        _firstTrackCache = child.track;
        return child.track;
      }
      if (child is FolderNode) {
        final nested = child.firstTrack;
        if (nested != null) {
          _firstTrackCache = nested;
          return nested;
        }
      }
    }
    return null;
  }

  int get totalTrackCount {
    final cached = _cachedTotalTrackCount;
    if (cached != null) {
      return cached;
    }
    return allTracks.length;
  }

  Duration get totalDuration {
    final cached = _cachedTotalDuration;
    if (cached != null) {
      return cached;
    }
    final duration = allTracks.fold<Duration>(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );
    _cachedTotalDuration = duration;
    return duration;
  }

  int get leafFolderCount {
    final cached = _cachedLeafFolderCount;
    if (cached != null) {
      return cached;
    }
    if (!children.any((child) => child is FolderNode)) {
      return 1;
    }
    return children.whereType<FolderNode>().fold<int>(
      0,
      (sum, child) => sum + child.leafFolderCount,
    );
  }

  void cacheTreeMetrics({
    required int totalTrackCount,
    required int leafFolderCount,
    required MusicTrack? firstTrack,
    Duration? totalDuration,
    List<MusicTrack>? allTracks,
  }) {
    _cachedTotalTrackCount = totalTrackCount;
    _cachedLeafFolderCount = leafFolderCount;
    _firstTrackCache = firstTrack;
    _cachedTotalDuration = totalDuration;
    _allTracksCache = allTracks;
  }
}

class TrackNode extends LibraryNode {
  TrackNode(this.track);

  final MusicTrack track;

  @override
  String get name => track.displayName;

  @override
  String get path => track.path;
}

class LibraryTreeSnapshot {
  const LibraryTreeSnapshot({
    required this.tree,
    required this.leafFolderCount,
  });

  final List<LibraryNode> tree;
  final int leafFolderCount;
}
