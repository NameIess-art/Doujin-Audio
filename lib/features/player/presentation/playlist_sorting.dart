import '../../../app/application/audio_path_coordinator.dart';
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
  required AudioPathCoordinator paths,
  required MusicTrack? Function(PlaybackSessionSnapshot session)
  trackForSession,
  Set<String> pinnedSessionIds = const <String>{},
}) {
  if (sessions.length < 2) return sessions;
  final items = [
    for (final session in sessions)
      if (!session.isTemporary)
        (
          session: session,
          value: _playlistSortValue(
            session,
            criterion,
            groupByLibrary,
            paths,
            trackForSession,
          ),
          pinned: pinnedSessionIds.contains(session.id),
        ),
  ];
  items.sort((left, right) {
    if (left.pinned != right.pinned) {
      return left.pinned ? -1 : 1;
    }
    final leftValue = left.value;
    final rightValue = right.value;
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
    return compareNatural(
      left.session.id,
      right.session.id,
      caseSensitive: true,
    );
  });
  return List<PlaybackSessionSnapshot>.unmodifiable([
    ...sessions.where((session) => session.isTemporary),
    ...items.map((e) => e.session),
  ]);
}

String? playlistSessionWorkName(
  AudioPathCoordinator paths,
  String trackPath,
  MusicTrack? track,
) {
  final folderName = paths.rootFolderName(trackPath, knownTrack: track);
  if (folderName.isNotEmpty) return folderName;
  if (track != null && !track.isSingle && track.groupTitle.trim().isNotEmpty) {
    return track.groupTitle;
  }
  return null;
}

class PlaylistSortValue {
  const PlaylistSortValue({
    required this.name,
    required this.libraryKey,
    required this.voiceActor,
    required this.releaseDate,
    required this.addedAt,
    required this.lastPlayedAt,
    this.workName,
  });

  final String name;
  final String? workName;
  final String? libraryKey;
  final String? voiceActor;
  final DateTime? releaseDate;
  final DateTime addedAt;
  final DateTime? lastPlayedAt;
}

PlaylistSortValue _playlistSortValue(
  PlaybackSessionSnapshot session,
  PlaylistSortCriterion criterion,
  bool groupByLibrary,
  AudioPathCoordinator paths,
  MusicTrack? Function(PlaybackSessionSnapshot session) trackForSession,
) {
  final queue = session.playbackQueue;
  final hasQueueName = queue?.name.trim().isNotEmpty == true;
  final needsDetail =
      criterion == PlaylistSortCriterion.voiceActor ||
      criterion == PlaylistSortCriterion.releaseDate;
  final needsTrack = groupByLibrary || needsDetail || !hasQueueName;
  final track = needsTrack
      ? trackForSession(session) ?? queue?.expandedTracks.firstOrNull
      : null;
  final detail = needsDetail && track != null
      ? _detailForTrack(track, paths.library)
      : null;
  final workName = criterion == PlaylistSortCriterion.name && !hasQueueName
      ? playlistSessionWorkName(paths, session.currentTrackPath, track)
      : null;
  final voiceActors = criterion == PlaylistSortCriterion.voiceActor
      ? detail?.voiceActors ??
            stringListFromSortMetadata(track?.remoteMetadata?['voiceActors'])
      : const <String>[];
  return PlaylistSortValue(
    name: hasQueueName
        ? queue!.name
        : track?.displayName ?? session.currentTrackPath,
    workName: workName,
    libraryKey: groupByLibrary && track != null
        ? paths.library.libraryRootForPath(track.path)
        : null,
    voiceActor: voiceActors.isEmpty ? null : voiceActors.join('\u0000'),
    releaseDate: criterion == PlaylistSortCriterion.releaseDate
        ? detail?.releaseDate ??
              dateTimeFromSortMetadata(track?.remoteMetadata?['releaseDate'])
        : null,
    addedAt: session.createdAt,
    lastPlayedAt: session.lastPlayedAt,
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
    PlaylistSortCriterion.name => compareNatural(
      left.workName ?? left.name,
      right.workName ?? right.name,
    ),
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
    PlaylistSortCriterion.playbackTime => comparePlaybackTimeSortValues(
      left.lastPlayedAt,
      right.lastPlayedAt,
      leftAddedAt: left.addedAt,
      rightAddedAt: right.addedAt,
    ),
  };
  final ordered = result == 0 && criterion == PlaylistSortCriterion.name
      ? compareNatural(left.name, right.name)
      : result;
  return ascending ? ordered : -ordered;
}
