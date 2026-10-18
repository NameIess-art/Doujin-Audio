import 'dart:collection';

import '../../../core/media/audio_detail.dart';
import '../../../core/media/list_sorting_utils.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';

class LibrarySortRequest {
  const LibrarySortRequest({
    required this.nodes,
    required this.criterion,
    required this.ascending,
    required this.groupByLibrary,
    this.workNameDisplay = WorkNameDisplay.workTitle,
    this.pinnedPaths = const <String>{},
    this.roots = const <String>[],
    this.details = const <AudioDetail>[],
    this.categorySnapshot,
  });

  final List<LibraryNode> nodes;
  final LibrarySortCriterion criterion;
  final bool ascending;
  final bool groupByLibrary;
  final WorkNameDisplay workNameDisplay;
  final Set<String> pinnedPaths;
  final List<String> roots;
  final List<AudioDetail> details;
  final AudioLibraryCategorySnapshot? categorySnapshot;

  Future<LibrarySortPayload> toPayload() async {
    final needsDetails =
        criterion == LibrarySortCriterion.voiceActor ||
        criterion == LibrarySortCriterion.releaseDate ||
        (criterion == LibrarySortCriterion.name &&
            workNameDisplay == WorkNameDisplay.workTitle);
    final stopwatch = Stopwatch()..start();
    final byTarget = <String, AudioDetail>{};
    if (needsDetails) {
      for (final detail in details) {
        byTarget[_detailKey(detail.target)] = detail;
        if (stopwatch.elapsedMicroseconds >= 1000) {
          await Future<void>.delayed(Duration.zero);
          stopwatch.reset();
        }
      }
    }
    final normalizedPinned = <String>{};
    for (final path in pinnedPaths) {
      normalizedPinned.add(PathMatcher.normalize(path));
      if (stopwatch.elapsedMicroseconds >= 1000) {
        await Future<void>.delayed(Duration.zero);
        stopwatch.reset();
      }
    }
    final items = <LibrarySortItem>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      items.add((
        index: index,
        path: node.path,
        value: _librarySortValue(node, this, byTarget),
        pinned: normalizedPinned.contains(PathMatcher.normalize(node.path)),
      ));
      // Summaries preserve node identity, but preparing a large catalog must
      // still give input and playback callbacks a turn before sorting starts.
      if (stopwatch.elapsedMicroseconds >= 1000) {
        await Future<void>.delayed(Duration.zero);
        stopwatch.reset();
      }
    }
    return LibrarySortPayload._(
      criterion: criterion,
      ascending: ascending,
      groupByLibrary: groupByLibrary,
      roots: groupByLibrary ? roots : const <String>[],
      items: UnmodifiableListView(items),
    );
  }
}

typedef LibrarySortItem = ({
  int index,
  String path,
  LibrarySortValue value,
  bool pinned,
});

// Only scalar summaries cross the isolate boundary; folder graphs, tracks and
// category snapshots remain with their existing owners on the UI isolate.
class LibrarySortPayload {
  LibrarySortPayload._({
    required this.criterion,
    required this.ascending,
    required this.groupByLibrary,
    required List<String> roots,
    required this.items,
  }) : roots = List<String>.unmodifiable(roots),
       assert(items is UnmodifiableListView<LibrarySortItem>);

  final LibrarySortCriterion criterion;
  final bool ascending;
  final bool groupByLibrary;
  final List<String> roots;
  final List<LibrarySortItem> items;
}

// Return positions so the UI retains the original nodes and their row state.
List<int> buildLibrarySortedIndices(LibrarySortPayload request) {
  final criterion = request.criterion;
  final ascending = request.ascending;
  final groupByLibrary = request.groupByLibrary;
  final items = List<LibrarySortItem>.of(request.items);
  final libraryKeys = <int, String?>{
    if (groupByLibrary)
      for (final item in items)
        item.index: request.roots
            .where((root) => PathMatcher.isWithinOrEqual(item.path, root))
            .firstOrNull,
  };
  items.sort((left, right) {
    if (left.pinned != right.pinned) {
      return left.pinned ? -1 : 1;
    }
    final leftValue = left.value;
    final rightValue = right.value;
    if (groupByLibrary) {
      final groupResult = compareGroupedSortStrings(
        libraryKeys[left.index],
        libraryKeys[right.index],
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
  return items.map((item) => item.index).toList(growable: false);
}

class LibrarySortValue {
  const LibrarySortValue({
    required this.name,
    required this.voiceActor,
    required this.duration,
    required this.releaseDate,
    required this.addedAt,
    required this.lastPlayedAt,
  });

  final String name;
  final String? voiceActor;
  final Duration? duration;
  final DateTime? releaseDate;
  final DateTime? addedAt;
  final DateTime? lastPlayedAt;
}

LibrarySortValue _librarySortValue(
  LibraryNode node,
  LibrarySortRequest request,
  Map<String, AudioDetail> details,
) {
  final criterion = request.criterion;
  final workNameDisplay = request.workNameDisplay;
  final needsDetail =
      criterion == LibrarySortCriterion.voiceActor ||
      criterion == LibrarySortCriterion.releaseDate;
  final needsWorkTitle =
      criterion == LibrarySortCriterion.name &&
      workNameDisplay == WorkNameDisplay.workTitle &&
      node is FolderNode &&
      node.isModuleNode;
  final needsTrackDates =
      criterion == LibrarySortCriterion.addedAt ||
      criterion == LibrarySortCriterion.playbackTime;
  MusicTrack? firstTrack;
  if (node is TrackNode) {
    firstTrack = node.track;
  } else if (needsDetail && node is FolderNode) {
    firstTrack = node.firstTrack;
  }
  AudioDetail? detail;
  if ((needsDetail || needsWorkTitle) && node is FolderNode) {
    final target = AudioDetailTarget.libraryRootFolder(node.path);
    detail =
        details[_detailKey(target)] ??
        request.categorySnapshot?.detailFor(target);
  } else if (needsDetail && firstTrack != null) {
    final target = AudioDetailTarget.singleAudioFile(firstTrack.path);
    detail =
        details[_detailKey(target)] ??
        request.categorySnapshot?.detailFor(target);
  }
  final voiceActors = criterion == LibrarySortCriterion.voiceActor
      ? detail?.voiceActors ??
            stringListFromSortMetadata(
              firstTrack?.remoteMetadata?['voiceActors'],
            )
      : const <String>[];
  final addedAt = needsTrackDates
      ? node is FolderNode
            ? node.earliestScannedAt
            : firstTrack?.scannedAt
      : null;
  final lastPlayedAt = criterion == LibrarySortCriterion.playbackTime
      ? node is FolderNode
            ? node.latestPlayedAt
            : firstTrack?.lastPlayedAt
      : null;
  final workTitle = needsWorkTitle ? detail?.workTitle.trim() ?? '' : '';
  return LibrarySortValue(
    name: workTitle.isNotEmpty ? workTitle : node.name,
    voiceActor: voiceActors.isEmpty ? null : voiceActors.join('\u0000'),
    duration: criterion == LibrarySortCriterion.duration
        ? node is FolderNode
              ? node.totalDuration
              : firstTrack?.duration
        : null,
    releaseDate: criterion == LibrarySortCriterion.releaseDate
        ? detail?.releaseDate ??
              dateTimeFromSortMetadata(
                firstTrack?.remoteMetadata?['releaseDate'],
              )
        : null,
    addedAt: addedAt,
    lastPlayedAt: lastPlayedAt,
  );
}

String _detailKey(AudioDetailTarget target) =>
    '${target.targetType.dbValue}|${PathMatcher.equivalenceKey(target.targetPath)}';

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
