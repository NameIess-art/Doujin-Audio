import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../domain/playback_mode.dart';
import '../../../core/media/path_matcher.dart';

typedef NextInt = int Function(int max);
typedef TrackPathResolver = String Function(MusicTrack track);
typedef TrackFolderKeyResolver = String Function(MusicTrack track);

String _defaultTrackPath(MusicTrack track) => track.path;

String _defaultTrackFolderKey(MusicTrack track) => track.groupKey;

class PlaybackQueueScope {
  PlaybackQueueScope({
    required List<String> paths,
    required this.currentIndex,
    required this.isPlaybackQueue,
    required this.isCustomQueue,
  }) : paths = immutableList(paths);

  final List<String> paths;
  final int currentIndex;
  final bool isPlaybackQueue;
  final bool isCustomQueue;
}

class PlaybackAdvanceResult {
  const PlaybackAdvanceResult({required this.path, this.queueIndex});

  final String path;
  final int? queueIndex;
}

class PlaybackQueueResolver {
  const PlaybackQueueResolver();

  PlaybackQueueScope resolveScope({
    required String currentPath,
    required MusicTrack? currentTrack,
    required SessionLoopMode loopMode,
    required List<String> sortedLibraryTrackPaths,
    required Map<String, List<MusicTrack>> tracksByGroup,
    List<MusicTrack>? customQueueTracks,
    bool isPlaybackQueue = false,
    int currentQueueIndex = 0,
    TrackPathResolver trackPath = _defaultTrackPath,
    TrackFolderKeyResolver folderKeyForTrack = _defaultTrackFolderKey,
  }) {
    final customTracks = customQueueTracks;
    if (customTracks != null && customTracks.isNotEmpty) {
      final paths = _customQueuePaths(
        currentTrack: currentTrack,
        loopMode: loopMode,
        customQueueTracks: customTracks,
        isPlaybackQueue: isPlaybackQueue,
        trackPath: trackPath,
        folderKeyForTrack: folderKeyForTrack,
      );
      return PlaybackQueueScope(
        paths: paths,
        currentIndex: _currentIndexForPaths(
          paths: paths,
          currentPath: currentPath,
          currentQueueIndex: currentQueueIndex,
          useQueueIndex: isPlaybackQueue,
        ),
        isPlaybackQueue: isPlaybackQueue,
        isCustomQueue: true,
      );
    }

    final paths = _libraryScopePaths(
      currentPath: currentPath,
      currentTrack: currentTrack,
      loopMode: loopMode,
      sortedLibraryTrackPaths: sortedLibraryTrackPaths,
      tracksByGroup: tracksByGroup,
      trackPath: trackPath,
    );
    return PlaybackQueueScope(
      paths: paths,
      currentIndex: _currentIndexForPaths(
        paths: paths,
        currentPath: currentPath,
        currentQueueIndex: currentQueueIndex,
        useQueueIndex: false,
      ),
      isPlaybackQueue: false,
      isCustomQueue: false,
    );
  }

  PlaybackAdvanceResult? resolveAdvance({
    required PlaybackQueueScope scope,
    required bool forward,
    required SessionLoopMode loopMode,
    required NextInt nextInt,
  }) {
    final paths = scope.paths;
    if (paths.isEmpty) return null;
    final effectiveLoopMode = scope.isPlaybackQueue
        ? SessionLoopMode.folderSequential
        : loopMode;
    if (effectiveLoopMode == SessionLoopMode.single || paths.length == 1) {
      return PlaybackAdvanceResult(
        path: paths[scope.currentIndex.clamp(0, paths.length - 1)],
        queueIndex: scope.isCustomQueue ? 0 : null,
      );
    }

    final nextIndex = effectiveLoopMode.isShuffle
        ? _randomDifferentIndex(paths, scope.currentIndex, nextInt)
        : (scope.currentIndex + (forward ? 1 : -1) + paths.length) %
              paths.length;
    return PlaybackAdvanceResult(
      path: paths[nextIndex],
      queueIndex: scope.isCustomQueue ? nextIndex : null,
    );
  }

  bool hasAdjacentInScope({
    required PlaybackQueueScope scope,
    required SessionLoopMode loopMode,
  }) {
    if (scope.paths.isEmpty) return false;
    if (scope.isPlaybackQueue) return scope.paths.length > 1;
    if (!scope.isCustomQueue && loopMode == SessionLoopMode.single) {
      return true;
    }
    if (!scope.isCustomQueue && loopMode.isCrossFolder) {
      return true;
    }
    return scope.paths.length > 1;
  }

  bool hasAdjacentPath({
    required MusicTrack? currentTrack,
    required bool forward,
    required SessionLoopMode loopMode,
    required List<String> sortedLibraryTrackPaths,
    required Map<String, List<MusicTrack>> tracksByGroup,
  }) {
    if (currentTrack == null || sortedLibraryTrackPaths.isEmpty) return false;
    return hasAdjacentInScope(
      scope: resolveScope(
        currentPath: currentTrack.path,
        currentTrack: currentTrack,
        loopMode: loopMode,
        sortedLibraryTrackPaths: sortedLibraryTrackPaths,
        tracksByGroup: tracksByGroup,
      ),
      loopMode: loopMode,
    );
  }

  String? resolveNextPath({
    required MusicTrack? currentTrack,
    required bool forward,
    required SessionLoopMode loopMode,
    required List<String> sortedLibraryTrackPaths,
    required Map<String, List<MusicTrack>> tracksByGroup,
    required NextInt nextInt,
  }) {
    if (currentTrack == null || sortedLibraryTrackPaths.isEmpty) return null;
    return resolveAdvance(
      scope: resolveScope(
        currentPath: currentTrack.path,
        currentTrack: currentTrack,
        loopMode: loopMode,
        sortedLibraryTrackPaths: sortedLibraryTrackPaths,
        tracksByGroup: tracksByGroup,
      ),
      forward: forward,
      loopMode: loopMode,
      nextInt: nextInt,
    )?.path;
  }

  List<String> _customQueuePaths({
    required MusicTrack? currentTrack,
    required SessionLoopMode loopMode,
    required List<MusicTrack> customQueueTracks,
    required bool isPlaybackQueue,
    required TrackPathResolver trackPath,
    required TrackFolderKeyResolver folderKeyForTrack,
  }) {
    if (loopMode == SessionLoopMode.single && !isPlaybackQueue) {
      return currentTrack == null
          ? const <String>[]
          : <String>[trackPath(currentTrack)];
    }
    Iterable<MusicTrack> candidateTracks = customQueueTracks;
    if (!isPlaybackQueue && !loopMode.isCrossFolder) {
      final folderKey = currentTrack == null
          ? null
          : folderKeyForTrack(currentTrack);
      if (folderKey != null) {
        candidateTracks = candidateTracks.where(
          (track) => folderKeyForTrack(track) == folderKey,
        );
      }
    }
    return candidateTracks.map(trackPath).toList(growable: false);
  }

  List<String> _libraryScopePaths({
    required String currentPath,
    required MusicTrack? currentTrack,
    required SessionLoopMode loopMode,
    required List<String> sortedLibraryTrackPaths,
    required Map<String, List<MusicTrack>> tracksByGroup,
    required TrackPathResolver trackPath,
  }) {
    if (currentTrack == null) return const <String>[];
    if (currentTrack.isSingle) return <String>[currentPath];
    switch (loopMode) {
      case SessionLoopMode.single:
        return <String>[currentPath];
      case SessionLoopMode.crossSequential:
      case SessionLoopMode.crossRandom:
      case SessionLoopMode.crossOnce:
        return sortedLibraryTrackPaths.isEmpty
            ? <String>[currentPath]
            : sortedLibraryTrackPaths;
      case SessionLoopMode.folderSequential:
      case SessionLoopMode.folderRandom:
      case SessionLoopMode.folderOnce:
        final scope =
            tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[];
        return scope.isEmpty
            ? <String>[currentPath]
            : scope.map(trackPath).toList(growable: false);
    }
  }

  int _currentIndexForPaths({
    required List<String> paths,
    required String currentPath,
    required int currentQueueIndex,
    required bool useQueueIndex,
  }) {
    if (paths.isEmpty) return 0;
    if (useQueueIndex) {
      final queueIndex = currentQueueIndex.clamp(0, paths.length - 1);
      if (PathMatcher.equalsNormalized(paths[queueIndex], currentPath)) {
        return queueIndex;
      }
    }
    final index = paths.indexWhere(
      (path) => PathMatcher.equalsNormalized(path, currentPath),
    );
    return index < 0 ? 0 : index;
  }

  int _randomDifferentIndex(
    List<String> paths,
    int currentIndex,
    NextInt nextInt,
  ) {
    if (paths.length <= 1) return 0;
    final fallbackIndex = currentIndex.clamp(0, paths.length - 1);
    var candidateIndex = nextInt(paths.length);
    var guard = 0;
    while (candidateIndex == fallbackIndex && guard < 10) {
      candidateIndex = nextInt(paths.length);
      guard++;
    }
    return candidateIndex.clamp(0, paths.length - 1);
  }
}
