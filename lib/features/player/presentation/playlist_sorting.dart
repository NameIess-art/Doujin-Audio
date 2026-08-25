import '../../../core/media/audio_detail.dart';
import '../../../core/media/list_sorting_utils.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/music_track.dart';
import '../../library/application/library_facade.dart';
import '../../settings/application/settings_state.dart';
import '../application/playback_session_snapshot.dart';

List<PlaybackSessionSnapshot> sortPlaylistSessions({
  required List<PlaybackSessionSnapshot> sessions,
  required PlaylistSortCriterion criterion,
  required bool ascending,
  required bool groupByLibrary,
  required LibraryFacade library,
  required MusicTrack? Function(PlaybackSessionSnapshot session)
  trackForSession,
}) {
  if (sessions.length < 2) return sessions;
  final sorted = List<PlaybackSessionSnapshot>.of(sessions);
  sorted.sort((left, right) {
    final leftValue = _playlistSortValue(left, library, trackForSession);
    final rightValue = _playlistSortValue(right, library, trackForSession);
    if (groupByLibrary) {
      final groupResult = compareGroupedSortStrings(
        leftValue.libraryKey,
        rightValue.libraryKey,
        ascending,
      );
      if (groupResult != 0) return groupResult;
    }
    final valueResult = comparePlaylistSortValues(
      leftValue,
      rightValue,
      criterion,
      ascending,
    );
    if (valueResult != 0) return valueResult;
    final nameResult = compareNatural(leftValue.name, rightValue.name);
    if (nameResult != 0) return nameResult;
    return compareNatural(left.id, right.id, caseSensitive: true);
  });
  return List<PlaybackSessionSnapshot>.unmodifiable(sorted);
}

class PlaylistSortValue {
  const PlaylistSortValue({
    required this.name,
    required this.libraryKey,
    required this.voiceActor,
    required this.releaseDate,
    required this.addedAt,
  });

  final String name;
  final String? libraryKey;
  final String? voiceActor;
  final DateTime? releaseDate;
  final DateTime addedAt;
}

PlaylistSortValue _playlistSortValue(
  PlaybackSessionSnapshot session,
  LibraryFacade library,
  MusicTrack? Function(PlaybackSessionSnapshot session) trackForSession,
) {
  final queue = session.playbackQueue;
  final currentTrack = trackForSession(session);
  final queueTrack = queue?.expandedTracks.firstOrNull;
  final track = currentTrack ?? queueTrack;
  final detail = track == null ? null : _detailForTrack(track, library);
  final voiceActors =
      detail?.voiceActors ??
      stringListFromSortMetadata(track?.remoteMetadata?['voiceActors']);
  return PlaylistSortValue(
    name: queue?.name.trim().isNotEmpty == true
        ? queue!.name
        : track?.displayName ?? session.currentTrackPath,
    libraryKey: track == null ? null : library.libraryRootForPath(track.path),
    voiceActor: voiceActors.isEmpty ? null : voiceActors.join('\u0000'),
    releaseDate:
        detail?.releaseDate ??
        dateTimeFromSortMetadata(track?.remoteMetadata?['releaseDate']),
    addedAt: session.createdAt,
  );
}

AudioDetail? _detailForTrack(MusicTrack track, LibraryFacade library) {
  final target = library.audioDetailTargetForTrack(track);
  return library.resolvedAudioDetail(target) ??
      library.categorySnapshot?.detailFor(target);
}

int comparePlaylistSortValues(
  PlaylistSortValue left,
  PlaylistSortValue right,
  PlaylistSortCriterion criterion,
  bool ascending,
) {
  final result = switch (criterion) {
    PlaylistSortCriterion.name => compareNatural(left.name, right.name),
    PlaylistSortCriterion.voiceActor => compareOptionalSortStrings(
      left.voiceActor,
      right.voiceActor,
    ),
    PlaylistSortCriterion.releaseDate => compareOptionalSortValues(
      left.releaseDate,
      right.releaseDate,
      (a, b) => a.compareTo(b),
    ),
    PlaylistSortCriterion.addedAt => left.addedAt.compareTo(right.addedAt),
  };
  return ascending ? result : -result;
}
