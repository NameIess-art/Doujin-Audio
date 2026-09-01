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
    List<int> queueIndices = const <int>[],
    required this.currentIndex,
    required this.isPlaybackQueue,
    required this.isCustomQueue,
  }) : paths = immutableList(paths),
       queueIndices = immutableList(queueIndices);

  final List<String> paths;
  final List<int> queueIndices;
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
      final queueIndices = _customQueueIndices(
        currentTrack: currentTrack,
        loopMode: loopMode,
        customQueueTracks: customTracks,
        isPlaybackQueue: isPlaybackQueue,
        folderKeyForTrack: folderKeyForTrack,
      );
      final paths = queueIndices
          .map((index) => trackPath(customTracks[index]))
          .toList(growable: false);
      return PlaybackQueueScope(
        paths: paths,
        queueIndices: queueIndices,
        currentIndex: _currentIndexForPaths(
          paths: paths,
          currentPath: currentPath,
          currentQueueIndex: currentQueueIndex,
          useQueueIndex: isPlaybackQueue,
          queueIndices: queueIndices,
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
        ? (loopMode == SessionLoopMode.single
              ? SessionLoopMode.folderSequential
              : loopMode)
        : loopMode;
    if (effectiveLoopMode == SessionLoopMode.single || paths.length == 1) {
      return PlaybackAdvanceResult(
        path: paths[scope.currentIndex.clamp(0, paths.length - 1)],
        queueIndex: scope.isCustomQueue
            ? scope.queueIndices[scope.currentIndex.clamp(0, paths.length - 1)]
            : null,
      );
    }

    final nextIndex = effectiveLoopMode.isShuffle
        ? _randomDifferentIndex(paths, scope.currentIndex, nextInt)
        : (scope.currentIndex + (forward ? 1 : -1) + paths.length) %
              paths.length;
    return PlaybackAdvanceResult(
      path: paths[nextIndex],
      queueIndex: scope.isCustomQueue ? scope.queueIndices[nextIndex] : null,
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

  List<int> _customQueueIndices({
    required MusicTrack? currentTrack,
    required SessionLoopMode loopMode,
    required List<MusicTrack> customQueueTracks,
    required bool isPlaybackQueue,
    required TrackFolderKeyResolver folderKeyForTrack,
  }) {
    if (loopMode == SessionLoopMode.single && !isPlaybackQueue) {
      final index = currentTrack == null
          ? -1
          : customQueueTracks.indexWhere(
              (track) => identical(track, currentTrack),
            );
      return index < 0 ? const <int>[] : <int>[index];
    }
    final folderKey = currentTrack == null
        ? null
        : folderKeyForTrack(currentTrack);
    if (loopMode.isCrossFolder || folderKey == null) {
      return List<int>.generate(customQueueTracks.length, (index) => index);
    }
    return <int>[
      for (var index = 0; index < customQueueTracks.length; index++)
        if (folderKeyForTrack(customQueueTracks[index]) == folderKey) index,
    ];
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
    if (loopMode == SessionLoopMode.single) return <String>[currentPath];
    if (loopMode.isCrossFolder) {
      return sortedLibraryTrackPaths.isEmpty
          ? <String>[currentPath]
          : sortedLibraryTrackPaths;
    }
    final scope = tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[];
    return scope.isEmpty
        ? <String>[currentPath]
        : scope.map(trackPath).toList(growable: false);
  }

  int _currentIndexForPaths({
    required List<String> paths,
    required String currentPath,
    required int currentQueueIndex,
    required bool useQueueIndex,
    List<int>? queueIndices,
  }) {
    if (paths.isEmpty) return 0;
    if (useQueueIndex && queueIndices != null) {
      final scopeIndex = queueIndices.indexOf(currentQueueIndex);
      if (scopeIndex >= 0 &&
          PathMatcher.equalsNormalized(paths[scopeIndex], currentPath)) {
        return scopeIndex;
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
