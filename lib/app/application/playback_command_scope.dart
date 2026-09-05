part of 'playback_command_coordinator.dart';

const PlaybackQueueResolver _playbackQueueResolver = PlaybackQueueResolver();
String _folderKeyForTrack(MusicTrack track) {
  if (track.isRemoteAsmr ||
      PathMatcher.isRemoteUri(track.path)) {
    final remotePath = track.remoteMetadata?['trackDirectoryPath']?.toString();
    if (remotePath != null && remotePath.isNotEmpty && remotePath != '.') {
      return '${track.groupKey}::$remotePath';
    }
  }
  return track.groupKey;
}

extension PlaybackCommandScope on PlaybackCommandCoordinator {
  List<String> _crossFolderTrackPathsFor(MusicTrack? currentTrack) {
    if (currentTrack == null) return const <String>[];
    return _audioPathCoordinator
        .tracksInSameWork(currentTrack.path)
        .map((track) => _playbackFacade.resolveRetargetedPath(track.path))
        .toList(growable: false);
  }
}
