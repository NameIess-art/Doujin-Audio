part of 'audio_provider.dart';

const PlaybackQueueResolver _playbackQueueResolver = PlaybackQueueResolver();
const TimerRuntimeCalculator _timerRuntimeCalculator = TimerRuntimeCalculator();

String _folderKeyForTrack(MusicTrack track) {
  if (track.remoteMetadataKind == 'asmr.one' ||
      PathMatcher.isRemoteUri(track.path)) {
    final remotePath = track.remoteMetadata?['trackDirectoryPath']?.toString();
    if (remotePath != null && remotePath.isNotEmpty && remotePath != '.') {
      return '${track.groupKey}::$remotePath';
    }
  }
  return track.groupKey;
}

extension AudioProviderPlayback on AudioProvider {
  List<String> _crossFolderTrackPathsFor(MusicTrack? currentTrack) {
    if (currentTrack == null) return const <String>[];
    return _audioPathCoordinator
        .tracksInSameWork(currentTrack.path)
        .map((track) => _playbackFacade.resolveRetargetedPath(track.path))
        .toList(growable: false);
  }
}
