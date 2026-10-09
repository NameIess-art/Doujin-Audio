import '../../../core/media/music_track.dart';

abstract interface class PlaybackLibraryCatalog {
  int get structureRevision;
  int get contentRevision;
  int get coverGeneration;
  MusicTrack? trackByPath(String trackPath);
  List<MusicTrack> tracksInGroup(String groupKey, {int? limit});
  void updateTrackDuration(String trackPath, Duration duration);
  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  });
  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  });
}
