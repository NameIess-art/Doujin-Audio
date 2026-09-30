part of 'playback_command_coordinator.dart';

const PlaybackQueueResolver _playbackQueueResolver = PlaybackQueueResolver();
String _folderKeyForTrack(MusicTrack track) => track.groupKey;

extension PlaybackCommandScope on PlaybackCommandCoordinator {
  List<String> _crossFolderTrackPathsFor(MusicTrack? currentTrack) {
    if (currentTrack == null) return const <String>[];
    return _audioPathCoordinator
        .tracksInSameWork(currentTrack.path)
        .map((track) => _playbackFacade.resolveRetargetedPath(track.path))
        .toList(growable: false);
  }
}
