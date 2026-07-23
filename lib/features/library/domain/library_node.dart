import 'dart:collection';

import '../../../core/media/music_track.dart';
import '../../../core/immutable_collections.dart';

abstract class LibraryNode {
  String get name;
  String get path;
}

class FolderNode extends LibraryNode {
  FolderNode(this.name, this.path, {this.depth = 0}) {
    _childrenView = UnmodifiableListView<LibraryNode>(_children);
  }

  @override
  final String name;

  @override
  final String path;

  final int depth;
  final List<LibraryNode> _children = <LibraryNode>[];
  late final List<LibraryNode> _childrenView;
  FolderNode? _parent;
  List<MusicTrack>? _allTracksCache;
  MusicTrack? _firstTrackCache;
  int? _cachedTotalTrackCount;
  int? _cachedLeafFolderCount;
  Duration? _cachedTotalDuration;

  bool get isModuleNode => depth == 0;
  List<LibraryNode> get children => _childrenView;

  List<MusicTrack> get allTracks {
    final cached = _allTracksCache;
    if (cached != null) {
      return cached;
    }

    final list = <MusicTrack>[];
    for (final child in _children) {
      if (child is TrackNode) {
        list.add(child.track);
      } else if (child is FolderNode) {
        list.addAll(child.allTracks);
      }
    }
    final snapshot = immutableList(list);
    _allTracksCache = snapshot;
    return snapshot;
  }

  MusicTrack? get firstTrack {
    final cached = _firstTrackCache;
    if (cached != null) {
      return cached;
    }

    for (final child in _children) {
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
    if (!_children.any((child) => child is FolderNode)) {
      return 1;
    }
    return _children.whereType<FolderNode>().fold<int>(
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
    _allTracksCache = allTracks == null ? null : immutableList(allTracks);
  }

  void addChild(LibraryNode child) {
    _attachChild(child);
    _children.add(child);
    _invalidateMetrics();
  }

  void addChildren(Iterable<LibraryNode> children) {
    final additions = children.toList(growable: false);
    if (additions.isEmpty) return;
    for (final child in additions) {
      _attachChild(child);
    }
    _children.addAll(additions);
    _invalidateMetrics();
  }

  void replaceChildren(Iterable<LibraryNode> children) {
    for (final child in _children.whereType<FolderNode>()) {
      if (identical(child._parent, this)) child._parent = null;
    }
    _children.clear();
    for (final child in children) {
      _attachChild(child);
      _children.add(child);
    }
    _invalidateMetrics();
  }

  void removeChildrenWhere(bool Function(LibraryNode child) test) {
    var changed = false;
    _children.removeWhere((child) {
      if (!test(child)) return false;
      if (child is FolderNode && identical(child._parent, this)) {
        child._parent = null;
      }
      changed = true;
      return true;
    });
    if (changed) _invalidateMetrics();
  }

  void sortChildren(int Function(LibraryNode a, LibraryNode b) compare) {
    _children.sort(compare);
    _invalidateMetrics();
  }

  void _attachChild(LibraryNode child) {
    if (child is FolderNode) child._parent = this;
  }

  void _invalidateMetrics() {
    _allTracksCache = null;
    _firstTrackCache = null;
    _cachedTotalTrackCount = null;
    _cachedLeafFolderCount = null;
    _cachedTotalDuration = null;
    _parent?._invalidateMetrics();
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
  LibraryTreeSnapshot({
    required List<LibraryNode> tree,
    required this.leafFolderCount,
  }) : tree = immutableList(tree);

  final List<LibraryNode> tree;
  final int leafFolderCount;
}
