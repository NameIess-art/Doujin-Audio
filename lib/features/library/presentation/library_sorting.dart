import '../../../core/media/audio_detail.dart';
import '../../../core/media/list_sorting_utils.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../settings/application/settings_state.dart';
import '../application/library_facade.dart';
import '../domain/library_node.dart';

List<LibraryNode> sortLibraryNodes({
  required List<LibraryNode> nodes,
  required LibrarySortCriterion criterion,
  required bool ascending,
  required bool groupByLibrary,
  required LibraryFacade library,
  Set<String> pinnedPaths = const <String>{},
}) {
  if (nodes.length < 2) return nodes;
  final normalizedPinned = pinnedPaths.isEmpty
      ? const <String>{}
      : pinnedPaths.map(PathMatcher.normalize).toSet();
  final items = [
    for (final node in nodes)
      (
        node: node,
        value: _librarySortValue(node, criterion, groupByLibrary, library),
        pinned: normalizedPinned.contains(PathMatcher.normalize(node.path)),
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
    final valueResult = compareLibrarySortValues(
      leftValue,
      rightValue,
      criterion,
      ascending,
    );
    if (valueResult != 0) return valueResult;
    final nameResult = compareNatural(leftValue.name, rightValue.name);
    if (nameResult != 0) return nameResult;
    return compareNatural(left.node.path, right.node.path, caseSensitive: true);
  });
  return List<LibraryNode>.unmodifiable(items.map((e) => e.node));
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

LibrarySortValue _librarySortValue(
  LibraryNode node,
  LibrarySortCriterion criterion,
  bool groupByLibrary,
  LibraryFacade library,
) {
  final needsDetail = criterion == LibrarySortCriterion.voiceActor ||
      criterion == LibrarySortCriterion.releaseDate;
  final needsTrackDates = criterion == LibrarySortCriterion.addedAt ||
      criterion == LibrarySortCriterion.playbackTime;
  List<MusicTrack> tracks = const <MusicTrack>[];
  if (needsTrackDates) {
    tracks = node is FolderNode
        ? node.allTracks
        : <MusicTrack>[(node as TrackNode).track];
  }
  MusicTrack? firstTrack;
  if (node is TrackNode) {
    firstTrack = node.track;
  } else if (needsDetail && node is FolderNode) {
    firstTrack = node.firstTrack;
  }
  AudioDetail? detail;
  if (needsDetail && node is FolderNode) {
    detail = _detailForTarget(
      AudioDetailTarget.libraryRootFolder(node.path),
      library,
    );
  } else if (needsDetail && firstTrack != null) {
    detail = _detailForTrack(firstTrack, library);
  }
  final voiceActors = criterion == LibrarySortCriterion.voiceActor
      ? detail?.voiceActors ??
          stringListFromSortMetadata(firstTrack?.remoteMetadata?['voiceActors'])
      : const <String>[];
  final addedAt = needsTrackDates
      ? tracks
          .map((track) => track.scannedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (oldest, value) {
            if (oldest == null || value.isBefore(oldest)) return value;
            return oldest;
          })
      : null;
  final lastPlayedAt = criterion == LibrarySortCriterion.playbackTime
      ? tracks
          .map((track) => track.lastPlayedAt)
          .whereType<DateTime>()
          .fold<DateTime?>(null, (latest, value) {
            if (latest == null || value.isAfter(latest)) return value;
            return latest;
          })
      : null;
  return LibrarySortValue(
    name: node.name,
    libraryKey: groupByLibrary ? library.libraryRootForPath(node.path) : null,
    voiceActor: voiceActors.isEmpty ? null : voiceActors.join('\u0000'),
    duration: criterion == LibrarySortCriterion.duration
        ? node is FolderNode
            ? node.totalDuration
            : firstTrack?.duration
        : null,
    releaseDate: criterion == LibrarySortCriterion.releaseDate
        ? detail?.releaseDate ??
            dateTimeFromSortMetadata(firstTrack?.remoteMetadata?['releaseDate'])
        : null,
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
