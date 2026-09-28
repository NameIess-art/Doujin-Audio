import 'dart:async';

import '../../../core/media/music_track.dart';
import '../domain/playback_mode.dart';
import 'playback_facade.dart';

abstract interface class PlaybackSessionLauncher {
  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  });

  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  });

  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  });
}

final class PlaybackFacadeSessionLauncher implements PlaybackSessionLauncher {
  const PlaybackFacadeSessionLauncher(this._facade);

  final PlaybackFacade _facade;

  @override
  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) => _facade.playDirect(tracks, startIndex: startIndex, loopMode: loopMode);

  @override
  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  }) => _facade.addTrackToPlaylist(track, workTracks: workTracks);

  @override
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    return _facade.launchQueue(tracks, autoPlay: autoPlay, loopMode: loopMode);
  }
}
