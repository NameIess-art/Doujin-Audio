import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/library_node.dart';
import '../models/playback_session.dart';
import '../services/audio_state_services.dart';

@immutable
class LibraryHeaderState {
  const LibraryHeaderState({
    required this.audioCount,
    required this.watchedFolderCount,
    required this.watchedLibraryCount,
    required this.isInitialized,
  });

  final int audioCount;
  final int watchedFolderCount;
  final int watchedLibraryCount;
  final bool isInitialized;

  bool get hasWatchedSources =>
      watchedFolderCount > 0 || watchedLibraryCount > 0;

  @override
  bool operator ==(Object other) {
    return other is LibraryHeaderState &&
        other.audioCount == audioCount &&
        other.watchedFolderCount == watchedFolderCount &&
        other.watchedLibraryCount == watchedLibraryCount &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    audioCount,
    watchedFolderCount,
    watchedLibraryCount,
    isInitialized,
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
    required this.scanCurrentFolder,
    required this.scanFoundCount,
    required this.scanDuplicateCount,
    required this.scanFailureCount,
    required this.structureRevision,
    required this.isInitialized,
  });

  final List<LibraryNode> rawTree;
  final List<String> watchedLibraries;
  final int watchedFolderCount;
  final int watchedLibraryCount;
  final bool isScanning;
  final bool isBackgroundScanning;
  final String scanCurrentFolder;
  final int scanFoundCount;
  final int scanDuplicateCount;
  final int scanFailureCount;
  final int structureRevision;
  final bool isInitialized;

  bool get hasLibrary => rawTree.isNotEmpty;
  bool get canPullRefresh =>
      watchedFolderCount > 0 || watchedLibraryCount > 0;

  @override
  bool operator ==(Object other) {
    return other is LibraryListState &&
        identical(other.rawTree, rawTree) &&
        listEquals(other.watchedLibraries, watchedLibraries) &&
        other.watchedFolderCount == watchedFolderCount &&
        other.watchedLibraryCount == watchedLibraryCount &&
        other.isScanning == isScanning &&
        other.isBackgroundScanning == isBackgroundScanning &&
        other.scanCurrentFolder == scanCurrentFolder &&
        other.scanFoundCount == scanFoundCount &&
        other.scanDuplicateCount == scanDuplicateCount &&
        other.scanFailureCount == scanFailureCount &&
        other.structureRevision == structureRevision &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    rawTree,
    Object.hashAll(watchedLibraries),
    watchedFolderCount,
    watchedLibraryCount,
    isScanning,
    isBackgroundScanning,
    scanCurrentFolder,
    scanFoundCount,
    scanDuplicateCount,
    scanFailureCount,
    structureRevision,
    isInitialized,
  );
}

@immutable
class PlaylistHeaderState {
  const PlaylistHeaderState({
    required this.sessionCount,
    required this.playingCount,
    required this.timerDuration,
    required this.timerRemaining,
    required this.timerActive,
  });

  final int sessionCount;
  final int playingCount;
  final Duration? timerDuration;
  final Duration? timerRemaining;
  final bool timerActive;

  bool get hasTimer => timerDuration != null;

  @override
  bool operator ==(Object other) {
    return other is PlaylistHeaderState &&
        other.sessionCount == sessionCount &&
        other.playingCount == playingCount &&
        other.timerDuration == timerDuration &&
        other.timerRemaining == timerRemaining &&
        other.timerActive == timerActive;
  }

  @override
  int get hashCode => Object.hash(
    sessionCount,
    playingCount,
    timerDuration,
    timerRemaining,
    timerActive,
  );
}

@immutable
class PlaylistListState {
  const PlaylistListState({
    required this.sessions,
    required this.isInitialized,
  });

  final List<PlaybackSession> sessions;
  final bool isInitialized;

  bool get hasSessions => sessions.isNotEmpty;

  @override
  bool operator ==(Object other) {
    return other is PlaylistListState &&
        identical(other.sessions, sessions) &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(sessions, isInitialized);
}

@immutable
class SessionOrderState {
  const SessionOrderState({required this.sessionIds});

  final List<String> sessionIds;

  @override
  bool operator ==(Object other) {
    return other is SessionOrderState && listEquals(other.sessionIds, sessionIds);
  }

  @override
  int get hashCode => Object.hashAll(sessionIds);
}

@immutable
class SessionDetailViewState {
  const SessionDetailViewState({
    required this.sessionId,
    required this.trackPath,
    required this.isPlaying,
    required this.isLoading,
    required this.channelSwapEnabled,
  });

  final String sessionId;
  final String trackPath;
  final bool isPlaying;
  final bool isLoading;
  final bool channelSwapEnabled;

  @override
  bool operator ==(Object other) {
    return other is SessionDetailViewState &&
        other.sessionId == sessionId &&
        other.trackPath == trackPath &&
        other.isPlaying == isPlaying &&
        other.isLoading == isLoading &&
        other.channelSwapEnabled == channelSwapEnabled;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    trackPath,
    isPlaying,
    isLoading,
    channelSwapEnabled,
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
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    if (_cachedRevision != structureRevision) {
      _cache.clear();
      _cachedRevision = structureRevision;
    }

    final cached = _cache.remove(normalizedQuery);
    if (cached != null) {
      _cache[normalizedQuery] = cached;
      return cached;
    }

    final result = _buildFilteredTree(tree, normalizedQuery);
    _cache[normalizedQuery] = result;
    if (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  FilteredLibraryTreeResult _buildFilteredTree(
    List<LibraryNode> tree,
    String normalizedQuery,
  ) {
    if (normalizedQuery.isEmpty) {
      return FilteredLibraryTreeResult(
        tree: tree,
        matchCount: _countTrackNodes(tree),
      );
    }

    final resultNodes = <LibraryNode>[];
    var totalMatches = 0;

    for (final node in tree) {
      if (node is FolderNode) {
        final folderResult = _filterFolderNode(node, normalizedQuery);
        if (folderResult == null) continue;
        resultNodes.add(folderResult.node);
        totalMatches += folderResult.matchCount;
        continue;
      }

      final trackNode = node as TrackNode;
      if (_trackMatchesQuery(trackNode, normalizedQuery)) {
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
    String normalizedQuery,
  ) {
    final matchesFolderName = folder.name.toLowerCase().contains(normalizedQuery);
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
        final nestedResult = _filterFolderNode(child, normalizedQuery);
        if (nestedResult == null) continue;
        filteredChildren.add(nestedResult.node);
        matchCount += nestedResult.matchCount;
        continue;
      }

      final trackNode = child as TrackNode;
      if (_trackMatchesQuery(trackNode, normalizedQuery)) {
        filteredChildren.add(trackNode);
        matchCount++;
      }
    }

    if (filteredChildren.isEmpty) return null;

    final filteredFolder = FolderNode(folder.name, folder.path, depth: folder.depth)
      ..children.addAll(filteredChildren);
    return _FilteredFolderNodeResult(
      node: filteredFolder,
      matchCount: matchCount,
    );
  }

  bool _trackMatchesQuery(TrackNode trackNode, String normalizedQuery) {
    final track = trackNode.track;
    return track.displayName.toLowerCase().contains(normalizedQuery) ||
        track.groupTitle.toLowerCase().contains(normalizedQuery) ||
        track.groupSubtitle.toLowerCase().contains(normalizedQuery) ||
        track.path.toLowerCase().contains(normalizedQuery);
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

class _FilteredFolderNodeResult {
  const _FilteredFolderNodeResult({
    required this.node,
    required this.matchCount,
  });

  final FolderNode node;
  final int matchCount;
}

String buildSessionCoverPrecacheKey({
  required String sessionId,
  required String trackPath,
  required int cacheWidth,
  required int cacheHeight,
  required int coverGeneration,
}) {
  return '$sessionId|$trackPath|$cacheWidth|$cacheHeight|$coverGeneration';
}

LibraryHeaderState libraryHeaderStateFromSlice(LibraryState state) {
  return LibraryHeaderState(
    audioCount: state.libraryTrackCount,
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isInitialized: state.isInitialized,
  );
}

PlaylistHeaderState playlistHeaderStateFromSlices(
  PlaybackStateSliceData playbackState,
  TimerStateSliceData timerState,
) {
  return PlaylistHeaderState(
    sessionCount: playbackState.activeSessions.length,
    playingCount: playbackState.playingSessionCount,
    timerDuration: timerState.duration,
    timerRemaining: timerState.remaining,
    timerActive: timerState.active,
  );
}
