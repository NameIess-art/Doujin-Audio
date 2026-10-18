import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/domain/audio_library_category.dart';
import 'package:doujin_audio/features/library/application/library_sorting.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';

import 'support/app_runtime_test_fixture.dart';

FolderNode _folder(String name, String path) {
  return FolderNode(name, path);
}

TrackNode _track(String name, String path) {
  return TrackNode(
    MusicTrack(
      path: path,
      displayName: name,
      groupKey: 'group',
      groupTitle: 'group',
      groupSubtitle: '',
      isSingle: true,
    ),
  );
}

class _LazyFolderNode extends FolderNode {
  _LazyFolderNode(super.name, super.path);

  @override
  List<MusicTrack> get allTracks => throw StateError('Unneeded track walk');

  @override
  MusicTrack? get firstTrack => throw StateError('Unneeded first track');

  @override
  Duration get totalDuration => throw StateError('Unneeded duration');
}

class _NoMetadataTrack extends MusicTrack {
  _NoMetadataTrack(String name, String path)
    : super(
        path: path,
        displayName: name,
        groupKey: path,
        groupTitle: name,
        groupSubtitle: '',
        isSingle: true,
      );

  @override
  Map<String, Object?>? get remoteMetadata =>
      throw StateError('Unneeded metadata');
}

Future<List<LibraryNode>> sortLibraryNodes({
  required List<LibraryNode> nodes,
  required LibrarySortCriterion criterion,
  required bool ascending,
  required bool groupByLibrary,
  List<String> roots = const <String>[],
  List<AudioDetail> details = const <AudioDetail>[],
  AudioLibraryCategorySnapshot? categorySnapshot,
  WorkNameDisplay workNameDisplay = WorkNameDisplay.workTitle,
  Set<String> pinnedPaths = const <String>{},
}) async {
  final indices = buildLibrarySortedIndices(
    await LibrarySortRequest(
      nodes: nodes,
      criterion: criterion,
      ascending: ascending,
      groupByLibrary: groupByLibrary,
      roots: roots,
      details: details,
      categorySnapshot: categorySnapshot,
      workNameDisplay: workNameDisplay,
      pinnedPaths: pinnedPaths,
    ).toPayload(),
  );
  return List<LibraryNode>.unmodifiable(indices.map((index) => nodes[index]));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryFacade library;

  setUp(() {
    final graph = createTestRuntimeGraph();
    library = graph.library;
  });

  test(
    'large sorting preparation lets pending input run before completion',
    () async {
      final nodes = [
        for (var index = 0; index < 10000; index++)
          _track('Track $index', '/library/$index.mp3'),
      ];
      var completed = false;
      final inputTurn = Future<bool>(() => completed);
      final preparation =
          LibrarySortRequest(
            nodes: nodes,
            criterion: LibrarySortCriterion.name,
            ascending: true,
            groupByLibrary: false,
          ).toPayload().then((payload) {
            completed = true;
            return payload;
          });
      final completedBeforeInput = await inputTurn;
      final payload = await preparation;
      expect(completedBeforeInput, isFalse);
      expect(payload.items, hasLength(nodes.length));
      expect(payload.items.last.path, nodes.last.path);
      expect(() => payload.items.clear(), throwsUnsupportedError);
    },
  );

  test(
    'sort worker receives stable date summaries without walking folders',
    () async {
      final early = DateTime(2025);
      final late = DateTime(2026);
      final first = _LazyFolderNode('First', '/first')
        ..cacheTreeMetrics(
          totalTrackCount: 10000,
          leafFolderCount: 1,
          firstTrack: null,
          trackDatesCached: true,
          earliestScannedAt: early,
          latestPlayedAt: early,
        );
      final second = _LazyFolderNode('Second', '/second')
        ..cacheTreeMetrics(
          totalTrackCount: 10000,
          leafFolderCount: 1,
          firstTrack: null,
          trackDatesCached: true,
          earliestScannedAt: late,
          latestPlayedAt: late,
        );
      final payload = await LibrarySortRequest(
        nodes: [first, second],
        criterion: LibrarySortCriterion.playbackTime,
        ascending: true,
        groupByLibrary: false,
      ).toPayload();
      // Subsequent owner mutations must not affect a worker already in flight.
      first.addChild(_track('Added', '/first/added.mp3'));
      expect(await compute(buildLibrarySortedIndices, payload), [1, 0]);
      expect(payload.items.first.value.lastPlayedAt, early);
    },
  );

  test(
    'card preparation caches oldest scan and newest playback per folder',
    () {
      final early = DateTime(2025);
      final late = DateTime(2026);
      MusicTrack track(String name, DateTime scannedAt, DateTime playedAt) =>
          MusicTrack(
            path: '/library/work/$name.mp3',
            displayName: name,
            groupKey: '/library/work',
            groupTitle: 'Work',
            groupSubtitle: '',
            isSingle: false,
            scannedAt: scannedAt,
            lastPlayedAt: playedAt,
          );
      final cards = const LibraryOrganizer().buildCardTree(
        tracks: [track('One', late, early), track('Two', early, late)],
        watchedFolders: ['/library/work'],
      );
      final folder = cards.tree.single as FolderNode;
      expect(folder.earliestScannedAt, early);
      expect(folder.latestPlayedAt, late);
    },
  );

  test(
    'sort worker keeps library grouping direction and pin precedence',
    () async {
      final nodes = [
        _track('Alpha', r'E:\Library\B\01.mp3'),
        _track('Zulu', r'E:\Library\A\01.mp3'),
      ];
      Future<List<int>> sorted(
        bool ascending, {
        Set<String> pins = const {},
      }) async => compute(
        buildLibrarySortedIndices,
        await LibrarySortRequest(
          nodes: nodes,
          criterion: LibrarySortCriterion.name,
          ascending: ascending,
          groupByLibrary: true,
          roots: ['e:/library/b', 'e:/library/a'],
          pinnedPaths: pins,
        ).toPayload(),
      );
      expect(await sorted(true), [1, 0]);
      expect(await sorted(false), [0, 1]);
      expect(await sorted(true, pins: {nodes.first.path}), [0, 1]);
    },
  );

  test('sortLibraryNodes moves single pinned node to top', () async {
    final f1 = _folder('Alpha', '/music/alpha');
    final f2 = _folder('Beta', '/music/beta');
    final f3 = _folder('Gamma', '/music/gamma');

    // Normally Alpha, Beta, Gamma in alphabetical order
    final normal = await sortLibraryNodes(
      nodes: [f3, f1, f2],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      roots: [...library.watchedLibraries, ...library.watchedFolders],
      details: library.detailCacheService.resolvedDetails,
      categorySnapshot: library.categorySnapshot,
      pinnedPaths: {},
    );
    expect(normal.map((n) => n.name).toList(), ['Alpha', 'Beta', 'Gamma']);

    // When Gamma is pinned, it should appear first even though it is last alphabetically
    final pinned = await sortLibraryNodes(
      nodes: [f3, f1, f2],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      roots: [...library.watchedLibraries, ...library.watchedFolders],
      details: library.detailCacheService.resolvedDetails,
      categorySnapshot: library.categorySnapshot,
      pinnedPaths: {'/music/gamma'},
    );
    expect(pinned.map((n) => n.name).toList(), ['Gamma', 'Alpha', 'Beta']);
  });

  test(
    'sortLibraryNodes sorts multiple pinned nodes by sort criterion',
    () async {
      final f1 = _folder('A', '/music/a');
      final f2 = _folder('B', '/music/b');
      final f3 = _folder('C', '/music/c');
      final f4 = _folder('D', '/music/d');

      // Pin B and D. They should both be at the top, sorted among themselves by criterion
      final pinnedAsc = await sortLibraryNodes(
        nodes: [f1, f2, f3, f4],
        criterion: LibrarySortCriterion.name,
        ascending: true,
        groupByLibrary: false,
        roots: [...library.watchedLibraries, ...library.watchedFolders],
        details: library.detailCacheService.resolvedDetails,
        categorySnapshot: library.categorySnapshot,
        pinnedPaths: {'/music/b', '/music/d'},
      );
      expect(pinnedAsc.map((n) => n.name).toList(), ['B', 'D', 'A', 'C']);

      final pinnedDesc = await sortLibraryNodes(
        nodes: [f1, f2, f3, f4],
        criterion: LibrarySortCriterion.name,
        ascending: false,
        groupByLibrary: false,
        roots: [...library.watchedLibraries, ...library.watchedFolders],
        details: library.detailCacheService.resolvedDetails,
        categorySnapshot: library.categorySnapshot,
        pinnedPaths: {'/music/b', '/music/d'},
      );
      expect(pinnedDesc.map((n) => n.name).toList(), ['D', 'B', 'C', 'A']);
    },
  );

  test(
    'sortLibraryNodes works with mixed FolderNode and TrackNode and normalized paths',
    () async {
      final f1 = _folder('Folder 1', 'C:\\Music\\Folder1');
      final t1 = _track('Track 1', 'C:/Music/Track1.mp3');
      final f2 = _folder('Folder 2', 'C:/Music/Folder2');

      // Pin Track 1 with backslashes in pinnedPaths set to verify normalization
      final pinned = await sortLibraryNodes(
        nodes: [f1, t1, f2],
        criterion: LibrarySortCriterion.name,
        ascending: true,
        groupByLibrary: false,
        roots: [...library.watchedLibraries, ...library.watchedFolders],
        details: library.detailCacheService.resolvedDetails,
        categorySnapshot: library.categorySnapshot,
        pinnedPaths: {'C:\\Music\\Track1.mp3'},
      );
      expect(pinned.map((n) => n.name).toList(), [
        'Track 1',
        'Folder 1',
        'Folder 2',
      ]);
    },
  );

  test('name sorting skips folder track walks and track metadata', () async {
    final sortedFolders = await sortLibraryNodes(
      nodes: [_LazyFolderNode('Beta', '/b'), _LazyFolderNode('Alpha', '/a')],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      roots: [...library.watchedLibraries, ...library.watchedFolders],
      details: library.detailCacheService.resolvedDetails,
      categorySnapshot: library.categorySnapshot,
    );
    expect(sortedFolders.map((node) => node.name), ['Alpha', 'Beta']);

    final sortedTracks = await sortLibraryNodes(
      nodes: [
        TrackNode(_NoMetadataTrack('Beta', '/b.mp3')),
        TrackNode(_NoMetadataTrack('Alpha', '/a.mp3')),
      ],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      roots: [...library.watchedLibraries, ...library.watchedFolders],
      details: library.detailCacheService.resolvedDetails,
      categorySnapshot: library.categorySnapshot,
    );
    expect(sortedTracks.map((node) => node.name), ['Alpha', 'Beta']);
  });

  test('voice actor detail changes reorder library nodes', () async {
    final first = _track('First', '/first.mp3');
    final second = _track('Second', '/second.mp3');

    void updateDetail(TrackNode node, String voiceActor) {
      library.detailCacheService.markChanged(
        AudioDetail(
          target: library.audioDetailTargetForTrack(node.track),
          rjCode: '',
          workTitle: '',
          circleName: '',
          voiceActors: [voiceActor],
          tags: const [],
        ),
      );
    }

    Future<List<String>> sortedNames() async => (await sortLibraryNodes(
      nodes: [first, second],
      criterion: LibrarySortCriterion.voiceActor,
      ascending: true,
      groupByLibrary: false,
      roots: [...library.watchedLibraries, ...library.watchedFolders],
      details: library.detailCacheService.resolvedDetails,
      categorySnapshot: library.categorySnapshot,
    )).map((node) => node.name).toList();

    updateDetail(first, 'Zeta');
    updateDetail(second, 'Alpha');
    expect(await sortedNames(), ['Second', 'First']);

    updateDetail(first, 'Alpha');
    updateDetail(second, 'Zeta');
    expect(await sortedNames(), ['First', 'Second']);
  });

  test(
    'name sorting follows work name display and natural title order',
    () async {
      final first = _LazyFolderNode('RJ100', '/music/RJ100');
      final second = _LazyFolderNode('RJ200', '/music/RJ200');
      final third = _LazyFolderNode('RJ300', '/music/RJ300');
      for (final (folder, title) in [
        (first, 'Zulu'),
        (second, '  Alpha 10  '),
        (third, 'Alpha 2'),
      ]) {
        library.detailCacheService.markChanged(
          AudioDetail.empty(
            AudioDetailTarget.libraryRootFolder(folder.path),
          ).copyWith(workTitle: title),
        );
      }

      Future<List<LibraryNode>> sorted(
        WorkNameDisplay display,
        bool ascending,
      ) => sortLibraryNodes(
        nodes: [first, second, third],
        criterion: LibrarySortCriterion.name,
        ascending: ascending,
        groupByLibrary: false,
        roots: [...library.watchedLibraries, ...library.watchedFolders],
        details: library.detailCacheService.resolvedDetails,
        categorySnapshot: library.categorySnapshot,
        workNameDisplay: display,
      );

      expect(await sorted(WorkNameDisplay.workTitle, true), [
        third,
        second,
        first,
      ]);
      expect(await sorted(WorkNameDisplay.workTitle, false), [
        first,
        second,
        third,
      ]);
      expect(await sorted(WorkNameDisplay.folderName, true), [
        first,
        second,
        third,
      ]);
      expect(await sorted(WorkNameDisplay.folderName, false), [
        third,
        second,
        first,
      ]);
      expect(
        await sortLibraryNodes(
          nodes: [first, second, third],
          criterion: LibrarySortCriterion.name,
          ascending: true,
          groupByLibrary: false,
          roots: [...library.watchedLibraries, ...library.watchedFolders],
          details: library.detailCacheService.resolvedDetails,
          categorySnapshot: library.categorySnapshot,
          pinnedPaths: {first.path},
        ),
        [first, third, second],
      );
    },
  );

  test('name sorting falls back to visible folder and track names', () async {
    final missing = _folder('Alpha', '/missing');
    final blank = _folder('Beta', '/blank');
    final nested = FolderNode('Delta', '/nested', depth: 1);
    final track = TrackNode(_NoMetadataTrack('Gamma', '/gamma.mp3'));
    library.detailCacheService
      ..markChanged(
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(blank.path),
        ).copyWith(workTitle: '   '),
      )
      ..markChanged(
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(nested.path),
        ).copyWith(workTitle: 'A hidden title'),
      );
    expect(
      await sortLibraryNodes(
        nodes: [track, nested, blank, missing],
        criterion: LibrarySortCriterion.name,
        ascending: true,
        groupByLibrary: false,
        roots: [...library.watchedLibraries, ...library.watchedFolders],
        details: library.detailCacheService.resolvedDetails,
        categorySnapshot: library.categorySnapshot,
      ),
      [missing, blank, nested, track],
    );
  });
}
