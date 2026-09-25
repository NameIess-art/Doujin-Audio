import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_sorting.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryFacade library;

  setUp(() {
    final graph = createTestRuntimeGraph();
    library = graph.library;
  });

  test('sortLibraryNodes moves single pinned node to top', () {
    final f1 = _folder('Alpha', '/music/alpha');
    final f2 = _folder('Beta', '/music/beta');
    final f3 = _folder('Gamma', '/music/gamma');

    // Normally Alpha, Beta, Gamma in alphabetical order
    final normal = sortLibraryNodes(
      nodes: [f3, f1, f2],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
      pinnedPaths: {},
    );
    expect(normal.map((n) => n.name).toList(), ['Alpha', 'Beta', 'Gamma']);

    // When Gamma is pinned, it should appear first even though it is last alphabetically
    final pinned = sortLibraryNodes(
      nodes: [f3, f1, f2],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
      pinnedPaths: {'/music/gamma'},
    );
    expect(pinned.map((n) => n.name).toList(), ['Gamma', 'Alpha', 'Beta']);
  });

  test('sortLibraryNodes sorts multiple pinned nodes by sort criterion', () {
    final f1 = _folder('A', '/music/a');
    final f2 = _folder('B', '/music/b');
    final f3 = _folder('C', '/music/c');
    final f4 = _folder('D', '/music/d');

    // Pin B and D. They should both be at the top, sorted among themselves by criterion
    final pinnedAsc = sortLibraryNodes(
      nodes: [f1, f2, f3, f4],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
      pinnedPaths: {'/music/b', '/music/d'},
    );
    expect(pinnedAsc.map((n) => n.name).toList(), ['B', 'D', 'A', 'C']);

    final pinnedDesc = sortLibraryNodes(
      nodes: [f1, f2, f3, f4],
      criterion: LibrarySortCriterion.name,
      ascending: false,
      groupByLibrary: false,
      library: library,
      pinnedPaths: {'/music/b', '/music/d'},
    );
    expect(pinnedDesc.map((n) => n.name).toList(), ['D', 'B', 'C', 'A']);
  });

  test('sortLibraryNodes works with mixed FolderNode and TrackNode and normalized paths', () {
    final f1 = _folder('Folder 1', 'C:\\Music\\Folder1');
    final t1 = _track('Track 1', 'C:/Music/Track1.mp3');
    final f2 = _folder('Folder 2', 'C:/Music/Folder2');

    // Pin Track 1 with backslashes in pinnedPaths set to verify normalization
    final pinned = sortLibraryNodes(
      nodes: [f1, t1, f2],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
      pinnedPaths: {'C:\\Music\\Track1.mp3'},
    );
    expect(pinned.map((n) => n.name).toList(), ['Track 1', 'Folder 1', 'Folder 2']);
  });

  test('name sorting skips folder track walks and track metadata', () {
    final sortedFolders = sortLibraryNodes(
      nodes: [_LazyFolderNode('Beta', '/b'), _LazyFolderNode('Alpha', '/a')],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
    );
    expect(sortedFolders.map((node) => node.name), ['Alpha', 'Beta']);

    final sortedTracks = sortLibraryNodes(
      nodes: [
        TrackNode(_NoMetadataTrack('Beta', '/b.mp3')),
        TrackNode(_NoMetadataTrack('Alpha', '/a.mp3')),
      ],
      criterion: LibrarySortCriterion.name,
      ascending: true,
      groupByLibrary: false,
      library: library,
    );
    expect(sortedTracks.map((node) => node.name), ['Alpha', 'Beta']);
  });

  test('voice actor detail changes reorder library nodes', () {
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

    List<String> sortedNames() => sortLibraryNodes(
      nodes: [first, second],
      criterion: LibrarySortCriterion.voiceActor,
      ascending: true,
      groupByLibrary: false,
      library: library,
    ).map((node) => node.name).toList();

    updateDetail(first, 'Zeta');
    updateDetail(second, 'Alpha');
    expect(sortedNames(), ['Second', 'First']);

    updateDetail(first, 'Alpha');
    updateDetail(second, 'Zeta');
    expect(sortedNames(), ['First', 'Second']);
  });
}
