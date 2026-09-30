import 'dart:async';

import '../../../core/media/music_track.dart';
import '../domain/playback_library_catalog.dart';
import 'playback_facade.dart';
import 'playback_track_resolver.dart';

/// Coordinates queue commands that need both library grouping and playback.
final class PlaybackQueueCoordinator {
  const PlaybackQueueCoordinator({
    required PlaybackFacade playback,
    required PlaybackTrackResolver paths,
    required PlaybackLibraryCatalog library,
  }) : _playback = playback,
       _paths = paths,
       _library = library;

  final PlaybackFacade _playback;
  final PlaybackTrackResolver _paths;
  final PlaybackLibraryCatalog _library;

  Future<void> addTrack(String sessionId, MusicTrack track) async {
    unawaited(_library.playbackCoverPathFutureForTrack(track));
    await _playback.addTrackToPlaybackQueue(sessionId, track);
  }

  Future<void> addWork(String sessionId, MusicTrack track) async {
    unawaited(_library.playbackCoverPathFutureForTrack(track));
    if (track.isSingle) {
      await _playback.addTrackToPlaybackQueue(sessionId, track);
      return;
    }

    final workRootPath = _paths.workRootForTrack(track.path);
    final tracks = _paths.tracksInSameWork(track.path);
    if (tracks.isEmpty) return;

    for (final t in tracks.take(4)) {
      unawaited(_library.playbackCoverPathFutureForTrack(t));
    }

    await _playback.addWorkToPlaybackQueue(
      sessionId,
      title: _paths.workTitleForTrack(track),
      tracks: tracks,
      workRootPath: workRootPath,
    );
  }
}
