import '../../../core/media/music_track.dart';

abstract interface class PlaybackTrackResolver {
  MusicTrack? sessionTrackForPath(String sessionId, String trackPath);
  MusicTrack? trackByPath(
    String trackPath, {
    bool includeLibraryFallback = true,
  });
  List<MusicTrack> tracksInSameWork(String trackPath);
  String? workRootForTrack(String trackPath);
  String workTitleForTrack(MusicTrack track);
}
