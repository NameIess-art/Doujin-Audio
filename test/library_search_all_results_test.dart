import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/search_highlight.dart';
import 'package:doujin_audio/features/library/presentation/library_search_all_results.dart';
import 'package:doujin_audio/features/library/presentation/library_search_page.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_empty_scan.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_view_models.dart';

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

  test('search result cache invalidates structure and detail revisions', () {
    final index = LibrarySearchIndex();
    final result = FilteredLibraryTreeResult(tree: const [], matchCount: 0);
    index.storeResult(
      query: 'Ocean',
      structureRevision: 1,
      detailRevision: 2,
      result: result,
    );
    expect(
      index.cachedResult(
        query: 'Ocean',
        structureRevision: 1,
        detailRevision: 2,
      ),
      same(result),
    );
    expect(
      index.cachedResult(
        query: 'Ocean',
        structureRevision: 1,
        detailRevision: 3,
      ),
      isNull,
    );
    index.storeResult(
      query: 'Ocean',
      structureRevision: 1,
      detailRevision: 3,
      result: result,
    );
    expect(
      index.cachedResult(
        query: 'Ocean',
        structureRevision: 2,
        detailRevision: 3,
      ),
      isNull,
    );
  });

  test('search result cache retains only twelve recently used queries', () {
    final index = LibrarySearchIndex();
    final result = FilteredLibraryTreeResult(tree: const [], matchCount: 0);
    void store(int query) => index.storeResult(
      query: '$query',
      structureRevision: 1,
      detailRevision: 1,
      result: result,
    );
    FilteredLibraryTreeResult? cached(int query) => index.cachedResult(
      query: '$query',
      structureRevision: 1,
      detailRevision: 1,
    );
    for (var i = 0; i < 12; i++) {
      store(i);
    }
    expect(cached(0), same(result));
    store(12);
    expect(cached(1), isNull);
    expect(cached(0), same(result));
    expect(cached(12), same(result));
  });

  Widget results({
    required AppRuntimeWidgetTestFixture fixture,
    required ScrollController scrollController,
    required String query,
    required ValueChanged<List<LibraryNode>> onTreeChanged,
    int queryRevision = 0,
  }) => LibrarySearchAllResults(
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

  testWidgets(
    'returning to a prior search reuses its result until the library changes',
    (tester) async {
      final tracks = [
        for (final name in ['Ocean', 'Rain'])
          testMusicTrack(
            name: '$name audio',
            path: '/library/$name.mp3',
            groupKey: '/library/$name.mp3',
            groupTitle: '$name audio',
            isSingle: true,
          ),
      ];
      final fixture = AppRuntimeWidgetTestFixture(
        libraryTreeSnapshotBuilder: (payload) async => LibraryTreeSnapshot(
          tree: payload.tracks.map(TrackNode.new).toList(),
          leafFolderCount: 0,
        ),
      );
      addTearDown(fixture.dispose);
      fixture.library.addTracks(tracks, persist: false);
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      await tester.runAsync(
        fixture.library.coverArtworkCacheService.initialize,
      );
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final query = ValueNotifier((query: 'Ocean', revision: 0));
      addTearDown(query.dispose);
      List<LibraryNode> published = const [];
      await tester.pumpWidget(
        fixture.build(
          ValueListenableBuilder<({String query, int revision})>(
            valueListenable: query,
            builder: (_, value, _) => results(
              fixture: fixture,
              scrollController: controller,
              query: value.query,
              queryRevision: value.revision,
              onTreeChanged: (tree) => published = tree,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstResult = published;
      expect(firstResult.single.path, tracks.first.path);
      query.value = (query: 'Rain', revision: 1);
      await tester.pumpAndSettle();
      expect(published.single.path, tracks.last.path);
      query.value = (query: 'Ocean', revision: 2);
      await tester.pumpAndSettle();
      expect(published, same(firstResult));

      fixture.library.addTracks([
        testMusicTrack(
          name: 'Ocean added',
          path: '/library/added.mp3',
          groupKey: '/library/added.mp3',
          groupTitle: 'Ocean added',
          isSingle: true,
        ),
      ], persist: false);
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      query.value = (query: 'Ocean', revision: 3);
      await tester.pumpAndSettle();
      expect(published, isNot(same(firstResult)));
      expect(published, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('empty query starts no search and displays no works', (
    tester,
  ) async {
    var builds = 0;
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) async {
        builds++;
        return LibraryTreeSnapshot(tree: const [], leafFolderCount: 0);
      },
    );
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        results(
          fixture: fixture,
          scrollController: controller,
          query: '',
          onTreeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LibraryTreeItem), findsNothing);
    expect(find.byType(LibraryLoadingSkeleton), findsNothing);
    expect(builds, 0);
  });

  testWidgets(
    'reopening search shows suggestions until a new confirmation',
    (tester) async {
      var builds = 0;
      final tracks = List.generate(
        40,
        (index) => testMusicTrack(
          name: 'Warm audio $index',
          path: '/library/$index.mp3',
          groupKey: '/library/$index.mp3',
          groupTitle: 'Warm audio $index',
          isSingle: true,
        ),
      );
      final fixture = AppRuntimeWidgetTestFixture(
        libraryTreeSnapshotBuilder: (_) async {
          builds++;
          return LibraryTreeSnapshot(
            tree: tracks.map(TrackNode.new).toList(),
            leafFolderCount: 0,
          );
        },
      );
      addTearDown(fixture.dispose);
      fixture.library.addTracks(tracks, persist: false);
      await tester.runAsync(
        () => fixture.library.detailCacheService.loadMany(
          tracks.map((track) => AudioDetailTarget.singleAudioFile(track.path)),
        ),
      );
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      await fixture.library.loadLibraryTree();
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  buildAppPageRoute<void>(
                    context: context,
                    duration: Duration.zero,
                    child: const LibrarySearchPage(),
                  ),
                ),
                child: const Text('Open search'),
              ),
            ),
          ),
        ),
      );
      Future<void> openAndConfirm() async {
        await tester.tap(find.text('Open search'));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryTreeItem), findsNothing);
        expect(
          find.byKey(const ValueKey('library_search_suggestions')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('app_search_field')),
          'Warm',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('Warm audio 0', findRichText: true), findsWidgets);
        final list = tester.widget<ListView>(
          find.byKey(const ValueKey('library_search_results_all')),
        );
        expect(list.controller!.offset, 0);
      }

      await openAndConfirm();
      await tester.drag(
        find.byKey(const ValueKey('library_search_results_all')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListView>(
              find.byKey(const ValueKey('library_search_results_all')),
            )
            .controller!
            .offset,
        greaterThan(0),
      );
      Navigator.of(tester.element(find.byType(LibrarySearchPage))).pop();
      await tester.pumpAndSettle();
      await openAndConfirm();
      expect(builds, 1);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'pending searches retain mounted results and their committed highlights',
    (tester) async {
      final pending = Completer<LibraryTreeSnapshot>();
      final tracks = [
        for (final name in ['Ocean', 'Rain'])
          testMusicTrack(
            name: '$name audio',
            path: '/library/$name.mp3',
            groupKey: '/library/$name.mp3',
            groupTitle: '$name audio',
            isSingle: true,
          ),
      ];
      final nodes = tracks.map(TrackNode.new).toList();
      var builds = 0;
      final fixture = AppRuntimeWidgetTestFixture(
        libraryTreeSnapshotBuilder: (_) => ++builds == 1
            ? Future.value(LibraryTreeSnapshot(tree: nodes, leafFolderCount: 0))
            : pending.future,
      );
      addTearDown(fixture.dispose);
      fixture.library.addTracks(tracks, persist: false);
      fixture.library.snapshotCacheService.adoptCardSnapshot(
        LibraryTreeSnapshot(tree: nodes, leafFolderCount: 0),
      );
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      await tester.runAsync(
        fixture.library.coverArtworkCacheService.initialize,
      );
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final query = ValueNotifier((query: 'audio', revision: 0));
      addTearDown(query.dispose);
      List<LibraryNode> selectionTree = const [];
      await tester.pumpWidget(
        fixture.build(
          ValueListenableBuilder<({String query, int revision})>(
            valueListenable: query,
            builder: (_, value, _) => results(
              fixture: fixture,
              scrollController: controller,
              query: value.query,
              queryRevision: value.revision,
              onTreeChanged: (tree) => selectionTree = tree,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final listFinder = find.byKey(
        const ValueKey('library_search_results_all'),
      );
      final initialList = tester.element(listFinder);
      final initialRow = tester.element(
        find.byKey(const ValueKey('search_/library/Ocean.mp3')),
      );
      fixture.library.addTracks([
        testMusicTrack(
          name: 'Other',
          path: '/other.mp3',
          groupKey: '/other.mp3',
          groupTitle: 'Other',
          isSingle: true,
        ),
      ], persist: false);
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      query.value = (query: 'Ocean', revision: 1);
      selectionTree = const [];
      await tester.pump();
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      expect(tester.element(listFinder), same(initialList));
      expect(
        tester.element(find.byKey(const ValueKey('search_/library/Ocean.mp3'))),
        same(initialRow),
      );
      expect(SearchHighlightScope.termsOf(tester.element(listFinder)), [
        'audio',
      ]);
      expect(selectionTree, nodes);

      pending.complete(LibraryTreeSnapshot(tree: nodes, leafFolderCount: 0));
      await tester.pumpAndSettle();
      expect(find.text('Ocean audio', findRichText: true), findsWidgets);
      expect(find.text('Rain audio', findRichText: true), findsNothing);
      expect(selectionTree.single.path, tracks.first.path);
      expect(tester.element(listFinder), same(initialList));
      expect(SearchHighlightScope.termsOf(tester.element(listFinder)), [
        'Ocean',
      ]);

      final interaction = Object();
      UiInteractionCoordinator.instance.beginInteraction(interaction);
      query.value = (query: 'Rain', revision: 2);
      await tester.pump();
      await tester.pump();
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      expect(find.text('Ocean audio', findRichText: true), findsWidgets);
      expect(SearchHighlightScope.termsOf(tester.element(listFinder)), [
        'Ocean',
      ]);
      query.value = (query: 'Missing', revision: 3);
      await tester.pump();
      await tester.pump();
      query.value = (query: 'audio', revision: 4);
      await tester.pump();
      UiInteractionCoordinator.instance.cancelInteraction(interaction);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      expect(find.text('Ocean audio', findRichText: true), findsWidgets);
      expect(find.text('Rain audio', findRichText: true), findsWidgets);
      expect(selectionTree, nodes);
      expect(tester.element(listFinder), same(initialList));
      expect(SearchHighlightScope.termsOf(tester.element(listFinder)), [
        'audio',
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
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
    fixture.library.addTracks([earlier], persist: false);
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

    fixture.library.addTracks([latest], persist: false);
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

  testWidgets(
    'resubmitting a failed confirmed query retries its previous error',
    (tester) async {
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
          if (++requests == 1) throw StateError('First card request failed');
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
      fixture.library.addTracks([track], persist: false);
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      await tester.runAsync(
        fixture.library.coverArtworkCacheService.initialize,
      );
      await tester.pumpWidget(
        fixture.build(
          ValueListenableBuilder<int>(
            valueListenable: queryRevision,
            builder: (_, revision, _) => results(
              fixture: fixture,
              scrollController: scrollController,
              query: 'Recovered',
              queryRevision: revision,
              onTreeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library_search_error')),
        findsOneWidget,
      );

      queryRevision.value++;
      await tester.pumpAndSettle();

      expect(requests, 2);
      expect(find.byKey(const ValueKey('library_search_error')), findsNothing);
      expect(find.text('Recovered audio', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editing a confirmed page cancels its pending result', (
    tester,
  ) async {
    final pending = Completer<LibraryTreeSnapshot>();
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) => pending.future,
    );
    addTearDown(fixture.dispose);
    final track = testMusicTrack(
      name: 'Pending audio',
      path: '/pending.mp3',
      groupKey: '/pending.mp3',
      groupTitle: 'Pending audio',
      isSingle: true,
    );
    fixture.library.addTracks([track], persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    await tester.pumpWidget(fixture.build(const LibrarySearchPage()));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('app_search_field'));
    await tester.enterText(field, 'Pending');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.byType(LibrarySearchAllResults), findsOneWidget);
    await tester.enterText(field, 'Other');
    await tester.pumpAndSettle();
    final node = _ReadCountingTrackNode(track);
    pending.complete(LibraryTreeSnapshot(tree: [node], leafFolderCount: 0));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library_search_suggestions')),
      findsOneWidget,
    );
    expect(find.byType(LibrarySearchAllResults), findsNothing);
    expect(find.byType(LibraryTreeItem), findsNothing);
    expect(node.reads, 0);
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
    fixture.library.addTracks([track], persist: false);
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

  testWidgets('folder expansion resets on reopening submitted results', (
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
    fixture.library.addTracks([track], persist: false);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    await fixture.library.loadLibraryTree();
    await tester.pumpWidget(
      fixture.build(
        results(
          fixture: fixture,
          scrollController: scrollController,
          query: 'Work',
          onTreeChanged: (_) {},
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
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      fixture.build(
        results(
          fixture: fixture,
          scrollController: scrollController,
          query: 'Work',
          onTreeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nested audio', findRichText: true), findsNothing);
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });
}
