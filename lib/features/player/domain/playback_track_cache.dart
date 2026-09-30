import '../../../core/media/music_track.dart';

abstract interface class PlaybackTrackCache {
  Future<String?> cacheTrack(MusicTrack track, {String? playedPath});
  Future<void> dispose();
}
