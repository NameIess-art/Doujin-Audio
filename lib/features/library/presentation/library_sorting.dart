import '../../../core/media/audio_detail.dart';
import '../../../core/media/list_sorting_utils.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/music_track.dart';
import '../../settings/application/settings_state.dart';
import '../application/library_facade.dart';
import '../domain/library_node.dart';

List<LibraryNode> sortLibraryNodes({
  required List<LibraryNode> nodes,
  required LibrarySortCriterion criterion,
  required bool ascending,
  required bool groupByLibrary,
  required LibraryFacade library,
}) {
  if (nodes.length < 2) return nodes;
  final sorted = List<LibraryNode>.of(nodes);
  sorted.sort((left, right) {
    final leftValue = _librarySortValue(left, library);
    final rightValue = _librarySortValue(right, library);
    if (groupByLibrary) {
      final groupResult = compareGroupedSortStrings(
        leftValue.libraryKey,
        rightValue.libraryKey,
        ascending,
      );
      if (groupResult != 0) return groupResult;
    }
    final valueResult = compareLibrarySortValues(
      leftValue,
      rightValue,
      criterion,
      ascending,
    );
    if (valueResult != 0) return valueResult;
    final nameResult = compareNatural(leftValue.name, rightValue.name);
    if (nameResult != 0) return nameResult;
    return compareNatural(left.path, right.path, caseSensitive: true);
  });
  return List<LibraryNode>.unmodifiable(sorted);
}

class LibrarySortValue {
  const LibrarySortValue({
    required this.name,
    required this.libraryKey,
    required this.voiceActor,
    required this.duration,
    required this.releaseDate,
    required this.addedAt,
    required this.lastPlayedAt,
  });

  final String name;
  final String? libraryKey;
  final String? voiceActor;
  final Duration? duration;
  final DateTime? releaseDate;
  final DateTime? addedAt;
  final DateTime? lastPlayedAt;
}

LibrarySortValue _librarySortValue(LibraryNode node, LibraryFacade library) {
  final tracks = node is FolderNode
      ? node.allTracks
      : <MusicTrack>[(node as TrackNode).track];
  final firstTrack = tracks.firstOrNull;
  final detail = node is FolderNode
      ? _detailForTarget(
          AudioDetailTarget.libraryRootFolder(node.path),
          library,
        )
      : firstTrack == null
      ? null
      : _detailForTrack(firstTrack, library);
  final voiceActors =
      detail?.voiceActors ??
      stringListFromSortMetadata(firstTrack?.remoteMetadata?['voiceActors']);
  final addedAt = tracks
      .map((track) => track.scannedAt)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (oldest, value) {
        if (oldest == null || value.isBefore(oldest)) return value;
        return oldest;
      });
  final lastPlayedAt = tracks
      .map((track) => track.lastPlayedAt)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (latest, value) {
        if (latest == null || value.isAfter(latest)) return value;
        return latest;
      });
  return LibrarySortValue(
    name: node.name,
    libraryKey: library.libraryRootForPath(node.path),
    voiceActor: voiceActors.isEmpty ? null : voiceActors.join('\u0000'),
    duration: node is FolderNode ? node.totalDuration : firstTrack?.duration,
    releaseDate:
        detail?.releaseDate ??
        dateTimeFromSortMetadata(firstTrack?.remoteMetadata?['releaseDate']),
    addedAt: addedAt,
    lastPlayedAt: lastPlayedAt,
  );
}

AudioDetail? _detailForTrack(MusicTrack track, LibraryFacade library) {
  final target = library.audioDetailTargetForTrack(track);
  return _detailForTarget(target, library);
}

AudioDetail? _detailForTarget(AudioDetailTarget target, LibraryFacade library) {
  return library.resolvedAudioDetail(target) ??
      library.categorySnapshot?.detailFor(target);
}

int compareLibrarySortValues(
  LibrarySortValue left,
  LibrarySortValue right,
  LibrarySortCriterion criterion,
  bool ascending,
) {
  final result = switch (criterion) {
    LibrarySortCriterion.name => compareNatural(left.name, right.name),
    LibrarySortCriterion.voiceActor => compareOptionalSortStrings(
      left.voiceActor,
      right.voiceActor,
    ),
    LibrarySortCriterion.duration => compareOptionalSortValues(
      left.duration,
      right.duration,
      (a, b) => a.compareTo(b),
    ),
    LibrarySortCriterion.releaseDate => compareOptionalSortValues(
      left.releaseDate,
      right.releaseDate,
      (a, b) => a.compareTo(b),
    ),
    LibrarySortCriterion.addedAt => compareOptionalSortValues(
      left.addedAt,
      right.addedAt,
      (a, b) => a.compareTo(b),
    ),
    LibrarySortCriterion.playbackTime => comparePlaybackTimeSortValues(
      left.lastPlayedAt,
      right.lastPlayedAt,
      leftAddedAt: left.addedAt,
      rightAddedAt: right.addedAt,
    ),
  };
  return ascending ? result : -result;
}
