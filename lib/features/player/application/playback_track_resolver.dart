import '../../../core/media/music_track.dart';

abstract interface class PlaybackTrackResolver {
  MusicTrack? sessionTrackForPath(String sessionId, String trackPath);
}
