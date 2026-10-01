import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/library/presentation/library_search_all_results.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

class _ReadCountingTrackNode extends TrackNode {
  _ReadCountingTrackNode(super.track);

  int reads = 0;

  @override
  MusicTrack get track {
    reads++;
    return super.track;
  }
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database database;

  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  Widget results({
    required AppRuntimeWidgetTestFixture fixture,
    required ScrollController scrollController,
    required String query,
    required ValueChanged<List<LibraryNode>> onTreeChanged,
    bool active = true,
    int queryRevision = 0,
  }) => LibrarySearchAllResults(
    active: active,
    query: query,
    queryRevision: queryRevision,
    structureRevision: fixture.library.structureRevision,
    detailRevision: fixture.library.detailCacheService.revision,
    scrollController: scrollController,
    topPadding: 0,
    isSelectionMode: false,
    selectedPaths: const {},
    onEnterSelectionMode: (_) {},
    onToggleSelection: (_) {},
    onTreeChanged: onTreeChanged,
  );

  testWidgets('late earlier query cannot replace the latest result', (
    tester,
  ) async {
    final first = Completer<LibraryTreeSnapshot>();
    final second = Completer<LibraryTreeSnapshot>();
    var requests = 0;
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) =>
          ++requests == 1 ? first.future : second.future,
    );
    addTearDown(fixture.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final query = ValueNotifier((query: 'Earlier', revision: 0));
    addTearDown(query.dispose);
    final earlier = testMusicTrack(
      name: 'Earlier audio',
      path: '/library/earlier.mp3',
      groupKey: '/library/earlier.mp3',
      groupTitle: 'earlier',
      isSingle: true,
    );
    final latest = testMusicTrack(
      name: 'Latest audio',
      path: '/library/latest.mp3',
      groupKey: '/library/latest.mp3',
      groupTitle: 'latest',
      isSingle: true,
    );
    fixture.library.addTracks([earlier], notify: false, persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    final published = <List<LibraryNode>>[];
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<({String query, int revision})>(
          valueListenable: query,
          builder: (_, value, _) => results(
            fixture: fixture,
            scrollController: scrollController,
            query: value.query,
            queryRevision: value.revision,
            onTreeChanged: published.add,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(requests, 1);

    fixture.library.addTracks([latest], notify: false, persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    query.value = (query: 'Latest', revision: 1);
    await tester.pump();
    await tester.pump();
    expect(requests, 2);

    second.complete(
      LibraryTreeSnapshot(tree: [TrackNode(latest)], leafFolderCount: 0),
    );
    await tester.pumpAndSettle();
    expect(published.last.single.path, latest.path);
    final commitCount = published.length;
    final oldNode = _ReadCountingTrackNode(earlier);
    first.complete(LibraryTreeSnapshot(tree: [oldNode], leafFolderCount: 0));
    await tester.pumpAndSettle();

    expect(published.length, commitCount);
    expect(oldNode.reads, 0);
    expect(find.text('Latest audio', findRichText: true), findsWidgets);
    expect(find.text('Earlier audio', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing an already empty query retries its previous error', (
    tester,
  ) async {
    var requests = 0;
    final track = testMusicTrack(
      name: 'Recovered audio',
      path: '/library/recovered.mp3',
      groupKey: '/library/recovered.mp3',
      groupTitle: 'Recovered audio',
      isSingle: true,
    );
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) async {
        if (++requests == 1) throw StateError('First tree request failed');
        return LibraryTreeSnapshot(
          tree: [TrackNode(track)],
          leafFolderCount: 0,
        );
      },
    );
    addTearDown(fixture.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final queryRevision = ValueNotifier(0);
    addTearDown(queryRevision.dispose);
    fixture.library.addTracks([track], notify: false, persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<int>(
          valueListenable: queryRevision,
          builder: (_, revision, _) => results(
            fixture: fixture,
            scrollController: scrollController,
            query: '',
            queryRevision: revision,
            onTreeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library_search_error')), findsOneWidget);

    queryRevision.value++;
    await tester.pumpAndSettle();

    expect(requests, 2);
    expect(find.byKey(const ValueKey('library_search_error')), findsNothing);
    expect(find.text('Recovered audio', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed results ignore a pending tree and publish no result', (
    tester,
  ) async {
    final pending = Completer<LibraryTreeSnapshot>();
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) => pending.future,
    );
    addTearDown(fixture.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final track = testMusicTrack(
      name: 'Pending audio',
      path: '/library/pending.mp3',
      groupKey: '/library/pending.mp3',
      groupTitle: 'pending',
      isSingle: true,
    );
    fixture.library.addTracks([track], notify: false, persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    final published = <List<LibraryNode>>[];
    await tester.pumpWidget(
      fixture.build(
        results(
          fixture: fixture,
          scrollController: scrollController,
          query: 'Pending',
          onTreeChanged: published.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    final node = _ReadCountingTrackNode(track);
    pending.complete(LibraryTreeSnapshot(tree: [node], leafFolderCount: 0));
    await tester.pumpAndSettle();

    expect(published, isEmpty);
    expect(node.reads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning to the same query rejects its earlier request', (
    tester,
  ) async {
    final pending = Completer<LibraryTreeSnapshot>();
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) => pending.future,
    );
    addTearDown(fixture.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final input = ValueNotifier((query: 'First', revision: 0, active: true));
    addTearDown(input.dispose);
    final track = testMusicTrack(
      name: 'First audio',
      path: '/library/first.mp3',
      groupKey: '/library/first.mp3',
      groupTitle: 'First audio',
      isSingle: true,
    );
    fixture.library.addTracks([track], notify: false, persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    final published = <List<LibraryNode>>[];
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<({String query, int revision, bool active})>(
          valueListenable: input,
          builder: (_, value, _) => results(
            fixture: fixture,
            scrollController: scrollController,
            query: value.query,
            queryRevision: value.revision,
            active: value.active,
            onTreeChanged: published.add,
          ),
        ),
      ),
    );
    await tester.pump();
    input.value = (query: 'Second', revision: 1, active: true);
    await tester.pump();
    input.value = (query: 'First', revision: 2, active: true);
    await tester.pump();
    input.value = (query: 'First', revision: 2, active: false);
    await tester.pump();
    final node = _ReadCountingTrackNode(track);
    pending.complete(LibraryTreeSnapshot(tree: [node], leafFolderCount: 0));
    await tester.pumpAndSettle();

    // The hidden result does not render rows. Only its latest request filters
    // the shared tree, even though the first request had the same query key.
    expect(node.reads, 1);
    expect(published.single.single, same(node));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive categories retain result and folder expansion', (
    tester,
  ) async {
    final track = testMusicTrack(
      name: 'Nested audio',
      path: '/library/work/nested.mp3',
      groupKey: '/library/work',
      groupTitle: 'Work',
    );
    final folder = FolderNode('Work', '/library/work')
      ..addChildren([TrackNode(track)]);
    var requests = 0;
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) async {
        requests++;
        return LibraryTreeSnapshot(tree: [folder], leafFolderCount: 1);
      },
    );
    addTearDown(fixture.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    fixture.library.addTracks([track], notify: false, persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, value, _) => results(
            fixture: fixture,
            scrollController: scrollController,
            active: value,
            query: '',
            onTreeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nested audio', findRichText: true), findsNothing);
    final folderTile = tester.widget<LibraryTreeItem>(
      find.byType(LibraryTreeItem).first,
    );
    folderTile.onFolderExpansionChanged!(folder, true);
    await tester.pumpAndSettle();
    expect(find.text('Nested audio', findRichText: true), findsWidgets);
    final loadedRequests = requests;

    active.value = false;
    await tester.pumpAndSettle();
    expect(scrollController.positions, isEmpty);
    active.value = true;
    await tester.pumpAndSettle();

    expect(requests, loadedRequests);
    expect(find.text('Nested audio', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
