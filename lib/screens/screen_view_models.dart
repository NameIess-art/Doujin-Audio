import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/audio_effects.dart';
import '../models/library_node.dart';
import '../models/playback_mode.dart';
import '../models/playback_session.dart';
import '../services/audio_state_services.dart';
import '../services/search_query_utils.dart';

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
    required this.watchedFolders,
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
  final List<String> watchedFolders;
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
    Object.hashAll(watchedFolders),
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
class LibraryUiState {
  const LibraryUiState({
    required this.header,
    required this.list,
    required this.detailRevision,
    required this.categorySnapshotRevision,
  });

  final LibraryHeaderState header;
  final LibraryListState list;
  final int detailRevision;
  final int categorySnapshotRevision;

  @override
  bool operator ==(Object other) {
    return other is LibraryUiState &&
        other.header == header &&
        other.list == list &&
        other.detailRevision == detailRevision &&
        other.categorySnapshotRevision == categorySnapshotRevision;
  }

  @override
  int get hashCode =>
      Object.hash(header, list, detailRevision, categorySnapshotRevision);
}

@immutable
class PlaylistHeaderState {
  const PlaylistHeaderState({
    required this.sessionCount,
    required this.playingCount,
    required this.timerDuration,
    required this.timerRemaining,
    required this.timerActive,
    this.autoResumeAt,
  });

  final int sessionCount;
  final int playingCount;
  final Duration? timerDuration;
  final Duration? timerRemaining;
  final bool timerActive;

  /// When the timer has expired and auto-resume is scheduled, this holds the
  /// wall-clock time at which playback will resume.  Null otherwise.
  final DateTime? autoResumeAt;

  bool get hasTimer => timerDuration != null || autoResumeAt != null;

  @override
  bool operator ==(Object other) {
    return other is PlaylistHeaderState &&
        other.sessionCount == sessionCount &&
        other.playingCount == playingCount &&
        other.timerDuration == timerDuration &&
        other.timerRemaining == timerRemaining &&
        other.timerActive == timerActive &&
        other.autoResumeAt == autoResumeAt;
  }

  @override
  int get hashCode => Object.hash(
    sessionCount,
    playingCount,
    timerDuration,
    timerRemaining,
    timerActive,
    autoResumeAt,
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
class PlaylistUiState {
  const PlaylistUiState({
    required this.header,
    required this.list,
    required this.coverGeneration,
  });

  final PlaylistHeaderState header;
  final PlaylistListState list;
  final int coverGeneration;

  @override
  bool operator ==(Object other) {
    return other is PlaylistUiState &&
        other.header == header &&
        other.list == list &&
        other.coverGeneration == coverGeneration;
  }

  @override
  int get hashCode => Object.hash(header, list, coverGeneration);
}

@immutable
class MainOverlayUiState {
  const MainOverlayUiState({
    required this.overlaySessions,
    required this.visibleSessions,
    required this.playingSessionCount,
    required this.activeSessionCount,
    required this.showPlaybackCard,
    required this.isInitialized,
  });

  final List<PlaybackSession> overlaySessions;
  final List<PlaybackSession> visibleSessions;
  final int playingSessionCount;
  final int activeSessionCount;
  final bool showPlaybackCard;
  final bool isInitialized;

  bool get hasPlayingSession => playingSessionCount > 0;
  bool get hasNowPlaying => visibleSessions.isNotEmpty;

  @override
  bool operator ==(Object other) {
    return other is MainOverlayUiState &&
        listEquals(other.overlaySessions, overlaySessions) &&
        listEquals(other.visibleSessions, visibleSessions) &&
        other.playingSessionCount == playingSessionCount &&
        other.activeSessionCount == activeSessionCount &&
        other.showPlaybackCard == showPlaybackCard &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(overlaySessions),
    Object.hashAll(visibleSessions),
    playingSessionCount,
    activeSessionCount,
    showPlaybackCard,
    isInitialized,
  );
}

@immutable
class SessionOrderState {
  const SessionOrderState({required this.sessionIds});

  final List<String> sessionIds;

  @override
  bool operator ==(Object other) {
    return other is SessionOrderState &&
        listEquals(other.sessionIds, sessionIds);
  }

  @override
  int get hashCode => Object.hashAll(sessionIds);
}

@immutable
class SessionDetailViewState {
  const SessionDetailViewState({
    required this.sessionId,
    required this.trackPath,
    required this.loopMode,
    required this.isPlaying,
    required this.isLoading,
    required this.channelSwapEnabled,
    required this.volume,
    required this.speed,
    required this.audioEffects,
    required this.eqCapabilities,
  });

  final String sessionId;
  final String trackPath;
  final SessionLoopMode loopMode;
  final bool isPlaying;
  final bool isLoading;
  final bool channelSwapEnabled;
  final double volume;
  final double speed;
  final AudioEffectsState audioEffects;
  final EqCapabilities eqCapabilities;

  @override
  bool operator ==(Object other) {
    return other is SessionDetailViewState &&
        other.sessionId == sessionId &&
        other.trackPath == trackPath &&
        other.loopMode == loopMode &&
        other.isPlaying == isPlaying &&
        other.isLoading == isLoading &&
        other.channelSwapEnabled == channelSwapEnabled &&
        other.volume == volume &&
        other.speed == speed &&
        other.audioEffects == audioEffects &&
        other.eqCapabilities == eqCapabilities;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    trackPath,
    loopMode,
    isPlaying,
    isLoading,
    channelSwapEnabled,
    volume,
    speed,
    audioEffects,
    eqCapabilities,
  );
}

@immutable
class SessionDetailUiState {
  const SessionDetailUiState({
    required this.sessionOrder,
    required this.detail,
    required this.coverGeneration,
  });

  final SessionOrderState sessionOrder;
  final SessionDetailViewState? detail;
  final int coverGeneration;

  @override
  bool operator ==(Object other) {
    return other is SessionDetailUiState &&
        other.sessionOrder == sessionOrder &&
        other.detail == detail &&
        other.coverGeneration == coverGeneration;
  }

  @override
  int get hashCode => Object.hash(sessionOrder, detail, coverGeneration);
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
    final searchTerms = extractSearchTerms(query);
    final normalizedQuery = searchTerms.join(' ');
    if (_cachedRevision != structureRevision) {
      _cache.clear();
      _cachedRevision = structureRevision;
    }

    final cached = _cache.remove(normalizedQuery);
    if (cached != null) {
      _cache[normalizedQuery] = cached;
      return cached;
    }

    final result = _buildFilteredTree(tree, searchTerms);
    _cache[normalizedQuery] = result;
    if (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  FilteredLibraryTreeResult _buildFilteredTree(
    List<LibraryNode> tree,
    List<String> searchTerms,
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
        final folderResult = _filterFolderNode(node, searchTerms);
        if (folderResult == null) continue;
        resultNodes.add(folderResult.node);
        totalMatches += folderResult.matchCount;
        continue;
      }

      final trackNode = node as TrackNode;
      if (_trackMatchesQuery(trackNode, searchTerms)) {
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
  ) {
    final matchesFolderName = matchesSearchTerms(
      <String>[folder.name],
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
        final nestedResult = _filterFolderNode(child, searchTerms);
        if (nestedResult == null) continue;
        filteredChildren.add(nestedResult.node);
        matchCount += nestedResult.matchCount;
        continue;
      }

      final trackNode = child as TrackNode;
      if (_trackMatchesQuery(trackNode, searchTerms)) {
        filteredChildren.add(trackNode);
        matchCount++;
      }
    }

    if (filteredChildren.isEmpty) return null;

    final filteredFolder = FolderNode(
      folder.name,
      folder.path,
      depth: folder.depth,
    )..children.addAll(filteredChildren);
    return _FilteredFolderNodeResult(
      node: filteredFolder,
      matchCount: matchCount,
    );
  }

  bool _trackMatchesQuery(TrackNode trackNode, List<String> searchTerms) {
    final track = trackNode.track;
    return matchesSearchTerms(
      <String>[
        track.displayName,
        track.groupTitle,
        track.groupSubtitle,
        track.path,
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
  });

  final List<LibraryNode> tree;
  final String query;
  final int structureRevision;
}

FilteredLibraryTreeResult buildFilteredLibraryTreeSnapshot(
  LibrarySearchSnapshotRequest request,
) {
  return LibrarySearchIndex().resolve(
    tree: request.tree,
    query: request.query,
    structureRevision: request.structureRevision,
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
    autoResumeAt: timerState.autoResumeAt,
  );
}

List<PlaybackSession> overlaySessionsFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  final sessions = playbackState.activeSessions
      .where((session) => session.currentTrackPath.isNotEmpty)
      .toList(growable: false);
  if (playbackState.multiThreadPlaybackEnabled || sessions.isEmpty) {
    return sessions;
  }
  final retainedSession = sessions.firstWhere(
    (session) => session.state.playing || session.isLoading,
    orElse: () => sessions.first,
  );
  return <PlaybackSession>[retainedSession];
}

SessionOrderState sessionOrderStateFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  return SessionOrderState(
    sessionIds: playbackState.activeSessions
        .map((session) => session.id)
        .toList(growable: false),
  );
}

SessionDetailViewState? sessionDetailViewStateFromPlaybackState(
  PlaybackStateSliceData playbackState,
  String sessionId,
) {
  for (final session in playbackState.activeSessions) {
    if (session.id != sessionId) continue;
    return SessionDetailViewState(
      sessionId: session.id,
      trackPath: session.currentTrackPath,
      loopMode: session.loopMode,
      isPlaying: session.state.playing,
      isLoading: session.isLoading || session.isPlaybackStarting,
      channelSwapEnabled: session.channelSwapEnabled,
      volume: session.volume,
      speed: session.speed,
      audioEffects: session.audioEffects,
      eqCapabilities: session.eqCapabilities,
    );
  }
  return null;
}
