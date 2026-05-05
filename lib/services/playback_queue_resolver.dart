import '../models/music_track.dart';
import '../models/playback_mode.dart';

typedef NextInt = int Function(int max);

class PlaybackQueueResolver {
  const PlaybackQueueResolver();

  String? resolveNextPath({
    required MusicTrack? currentTrack,
    required bool forward,
    required SessionLoopMode loopMode,
    required List<String> sortedLibraryTrackPaths,
    required Map<String, List<MusicTrack>> tracksByGroup,
    required NextInt nextInt,
  }) {
    if (currentTrack == null || sortedLibraryTrackPaths.isEmpty) return null;

    switch (loopMode) {
      case SessionLoopMode.single:
        return currentTrack.path;
      case SessionLoopMode.crossRandom:
        if (forward) {
          return _randomDifferentPath(
            sortedLibraryTrackPaths,
            currentTrack.path,
            nextInt,
          );
        }
        return resolveNextPath(
          currentTrack: currentTrack,
          forward: true,
          loopMode: loopMode,
          sortedLibraryTrackPaths: sortedLibraryTrackPaths,
          tracksByGroup: tracksByGroup,
          nextInt: nextInt,
        );
      case SessionLoopMode.folderSequential:
        final scope =
            tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[];
        if (scope.isEmpty) return currentTrack.path;
        final idx = scope.indexWhere(
          (track) => track.path == currentTrack.path,
        );
        if (idx < 0) return scope.first.path;
        final next = (idx + (forward ? 1 : -1) + scope.length) % scope.length;
        return scope[next].path;
      case SessionLoopMode.crossSequential:
        return _crossSequentialPath(
          currentTrack: currentTrack,
          forward: forward,
          tracksByGroup: tracksByGroup,
        );
      case SessionLoopMode.folderRandom:
        if (forward) {
          final scope =
              (tracksByGroup[currentTrack.groupKey] ?? const <MusicTrack>[])
                  .map((track) => track.path)
                  .toList(growable: false);
          if (scope.isEmpty) return currentTrack.path;
          return _randomDifferentPath(scope, currentTrack.path, nextInt);
        }
        return resolveNextPath(
          currentTrack: currentTrack,
          forward: true,
          loopMode: loopMode,
          sortedLibraryTrackPaths: sortedLibraryTrackPaths,
          tracksByGroup: tracksByGroup,
          nextInt: nextInt,
        );
    }
  }

  String _randomDifferentPath(
    List<String> paths,
    String currentPath,
    NextInt nextInt,
  ) {
    if (paths.length <= 1) return paths.first;
    String candidate = paths[nextInt(paths.length)];
    var guard = 0;
    while (candidate == currentPath && guard < 10) {
      candidate = paths[nextInt(paths.length)];
      guard++;
    }
    return candidate;
  }

  String _crossSequentialPath({
    required MusicTrack currentTrack,
    required bool forward,
    required Map<String, List<MusicTrack>> tracksByGroup,
  }) {
    final groupEntries = tracksByGroup.entries.toList()
      ..sort((a, b) {
        final titleA = a.value.first.groupTitle.toLowerCase();
        final titleB = b.value.first.groupTitle.toLowerCase();
        return titleA.compareTo(titleB);
      });
    if (groupEntries.isEmpty) return currentTrack.path;
    final currentGroupIdx = groupEntries.indexWhere(
      (entry) => entry.key == currentTrack.groupKey,
    );
    if (currentGroupIdx < 0) {
      return groupEntries.first.value.first.path;
    }

    final currentGroup = groupEntries[currentGroupIdx].value;
    final trackIdx = currentGroup.indexWhere(
      (track) => track.path == currentTrack.path,
    );
    if (trackIdx < 0) return currentGroup.first.path;

    if (forward) {
      if (trackIdx < currentGroup.length - 1) {
        return currentGroup[trackIdx + 1].path;
      }
      final nextGroupIdx = (currentGroupIdx + 1) % groupEntries.length;
      return groupEntries[nextGroupIdx].value.first.path;
    }

    if (trackIdx > 0) {
      return currentGroup[trackIdx - 1].path;
    }
    final prevGroupIdx =
        (currentGroupIdx - 1 + groupEntries.length) % groupEntries.length;
    return groupEntries[prevGroupIdx].value.last.path;
  }
}
