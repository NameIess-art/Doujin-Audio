import 'dart:async';

import '../../core/media/music_track.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';
import 'audio_path_coordinator.dart';

/// Coordinates queue commands that need both library grouping and playback.
final class PlaybackQueueCoordinator {
  const PlaybackQueueCoordinator({
    required PlaybackFacade playback,
    required AudioPathCoordinator paths,
    LibraryFacade? library,
  }) : _playback = playback,
       _paths = paths,
       _library = library;

  final PlaybackFacade _playback;
  final AudioPathCoordinator _paths;
  final LibraryFacade? _library;

  LibraryFacade get _resolvedLibrary => _library ?? _paths.library;

  Future<void> addTrack(String sessionId, MusicTrack track) async {
    unawaited(_resolvedLibrary.playbackCoverPathFutureForTrack(track));
    await _playback.addTrackToPlaybackQueue(sessionId, track);
  }

  Future<void> addWork(String sessionId, MusicTrack track) async {
    unawaited(_resolvedLibrary.playbackCoverPathFutureForTrack(track));
    if (track.isSingle) {
      await _playback.addTrackToPlaybackQueue(sessionId, track);
      return;
    }

    final workRootPath = _paths.workRootForTrack(track.path);
    final tracks = _paths.tracksInSameWork(track.path);
    if (tracks.isEmpty) return;

    for (final t in tracks.take(4)) {
      unawaited(_resolvedLibrary.playbackCoverPathFutureForTrack(t));
    }

    await _playback.addWorkToPlaybackQueue(
      sessionId,
      title: track.groupTitle,
      tracks: tracks,
      workRootPath: workRootPath,
    );
  }
}
