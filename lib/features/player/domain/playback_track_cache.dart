import '../../../core/media/music_track.dart';

abstract interface class PlaybackTrackCache {
  Future<String?> cacheTrack(
    MusicTrack track, {
    String? playedPath,
    String? ownerId,
  });

  /// Releases one session without cancelling requests shared by other sessions.
  void releaseOwner(String ownerId);
  Future<void> dispose();
}
