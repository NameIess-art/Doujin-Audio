part of 'playback_command_coordinator.dart';

const PlaybackQueueResolver _playbackQueueResolver = PlaybackQueueResolver();
String _folderKeyForTrack(MusicTrack track) {
  if (!track.isRemoteAsmr) return track.groupKey;
  final directory = track.remoteMetadata?['trackDirectoryPath'] as String?;
  final relativePath = track.remoteMetadata?['trackRelativePath'] as String?;
  // Remote URLs identify streams; the catalog metadata carries their folders.
  final normalizedDirectory = path.posix.normalize(
    directory?.replaceAll('\\', '/') ??
        path.posix.dirname((relativePath ?? '').replaceAll('\\', '/')),
  );
  return '${track.groupKey}/$normalizedDirectory';
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
