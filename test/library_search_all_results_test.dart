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
  }) => Offstage(
    offstage: !active,
    child: TickerMode(
      enabled: active,
      child: LibrarySearchAllResults(
        isActive: () => active,
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
      ),
    ),
  );

  testWidgets(
    'cached empty tree displays immediately without starting a build',
    (tester) async {
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
      expect(
        find.byKey(const ValueKey('library_search_empty')),
        findsOneWidget,
      );
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      expect(builds, 0);
    },
  );

  testWidgets('cached root cards display without building the full tree', (
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
    final track = testMusicTrack(
      name: 'Nested audio',
      path: '/work/01.mp3',
      groupKey: '/work',
      groupTitle: 'Cached work',
    );
    fixture.library.addTracks([track], persist: false);
    final card = FolderNode('Cached work', '/work');
    fixture.library.snapshotCacheService.adoptCardSnapshot(
      LibraryTreeSnapshot(tree: [card], leafFolderCount: 1),
    );
    await tester.runAsync(fixture.library.coverArtworkCacheService.initialize);
    await tester.runAsync(
      () => fixture.library.detailCacheService.load(
        AudioDetailTarget.libraryRootFolder(card.path),
      ),
    );
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final published = <List<LibraryNode>>[];
    await tester.pumpWidget(
      fixture.build(
        results(
          fixture: fixture,
          scrollController: controller,
          query: '',
          onTreeChanged: published.add,
        ),
      ),
    );
    expect(find.text('Cached work', findRichText: true), findsWidgets);
    expect(find.byType(LibraryLoadingSkeleton), findsNothing);
    expect(published.last.single, same(card));
    expect(builds, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      fixture.build(
        results(
          fixture: fixture,
          scrollController: controller,
          query: '',
          onTreeChanged: published.add,
        ),
      ),
    );
    expect(find.text('Cached work', findRichText: true), findsWidgets);
    expect(find.byType(LibraryLoadingSkeleton), findsNothing);
    expect(published.last.single, same(card));
    expect(builds, 0);
  });

  testWidgets('empty search rebuilds only cards after structure invalidation', (
    tester,
  ) async {
    var cardBuilds = 0;
    var treeBuilds = 0;
    final fixture = AppRuntimeWidgetTestFixture(
      libraryCardSnapshotBuilder: (payload) async {
        cardBuilds++;
        return LibraryTreeSnapshot(
          tree: payload.tracks.map(TrackNode.new).toList(),
          leafFolderCount: 0,
        );
      },
      libraryTreeSnapshotBuilder: (_) async {
        treeBuilds++;
        return LibraryTreeSnapshot(tree: const [], leafFolderCount: 0);
      },
    );
    addTearDown(fixture.dispose);
    final original = testMusicTrack(
      name: 'Original audio',
      path: '/original.mp3',
      groupKey: '/original.mp3',
      groupTitle: 'Original audio',
      isSingle: true,
    );
    fixture.library.addTracks([original], persist: false);
    final cachedNode = TrackNode(original);
    fixture.library.snapshotCacheService.adoptCardSnapshot(
      LibraryTreeSnapshot(tree: [cachedNode], leafFolderCount: 0),
    );
    await tester.runAsync(fixture.library.coverArtworkCacheService.initialize);
    await tester.runAsync(
      () => fixture.library.detailCacheService.load(
        AudioDetailTarget.singleAudioFile(original.path),
      ),
    );
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final revision = ValueNotifier(0);
    addTearDown(revision.dispose);
    final published = <List<LibraryNode>>[];
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (_, _, _) => results(
            fixture: fixture,
            scrollController: controller,
            query: '',
            onTreeChanged: published.add,
          ),
        ),
      ),
    );
    expect(published.last.single, same(cachedNode));
    expect(cardBuilds, 0);
    expect(treeBuilds, 0);

    fixture.library.addTracks(
      [
        testMusicTrack(
          name: 'Added audio',
          path: '/added.mp3',
          groupKey: '/added.mp3',
          groupTitle: 'Added audio',
          isSingle: true,
        ),
      ],
      persist: false,
    );
    await tester.runAsync(
      () => fixture.library.detailCacheService.load(
        AudioDetailTarget.singleAudioFile('/added.mp3'),
      ),
    );
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Added audio', findRichText: true), findsWidgets);
    expect(published.last, hasLength(2));
    expect(cardBuilds, 1);
    expect(treeBuilds, 0);

    revision.value++;
    await tester.pumpAndSettle();
    expect(cardBuilds, 1);
    expect(treeBuilds, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'warm search reopens immediately at the top without rebuilding the tree',
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
      await tester.tap(find.text('Open search'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Warm audio 0', findRichText: true), findsWidgets);
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      final firstFrameItems = find.byType(LibraryTreeItem, skipOffstage: false);
      final bodyHeight = tester
          .getSize(find.byKey(const ValueKey('app_search_body_layer')))
          .height;
      expect(
        tester.getTopLeft(firstFrameItems.last).dy,
        lessThan(bodyHeight + 140),
        reason: 'Opening search should only prebuild about one extra row',
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('library_search_results_all')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      final firstList = tester.widget<ListView>(
        find.byKey(const ValueKey('library_search_results_all')),
      );
      expect(firstList.controller!.offset, greaterThan(0));
      Navigator.of(tester.element(find.byType(LibrarySearchPage))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open search'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Warm audio 0', findRichText: true), findsWidgets);
      final reopened = tester.widget<ListView>(
        find.byKey(const ValueKey('library_search_results_all')),
      );
      expect(reopened.controller!.offset, 0);
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
      final fixture = AppRuntimeWidgetTestFixture(
        libraryTreeSnapshotBuilder: (_) => pending.future,
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
      final query = ValueNotifier((query: '', revision: 0));
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
      query.value = (query: 'Ocean', revision: 1);
      selectionTree = const [];
      await tester.pump();
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      expect(tester.element(listFinder), same(initialList));
      expect(
        tester.element(find.byKey(const ValueKey('search_/library/Ocean.mp3'))),
        same(initialRow),
      );
      expect(SearchHighlightScope.termsOf(tester.element(listFinder)), isEmpty);
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
      query.value = (query: '', revision: 4);
      await tester.pump();
      UiInteractionCoordinator.instance.cancelInteraction(interaction);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryLoadingSkeleton), findsNothing);
      expect(find.text('Ocean audio', findRichText: true), findsWidgets);
      expect(find.text('Rain audio', findRichText: true), findsWidgets);
      expect(selectionTree, nodes);
      expect(tester.element(listFinder), same(initialList));
      expect(SearchHighlightScope.termsOf(tester.element(listFinder)), isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('empty-state labels change only when search results commit', (
    tester,
  ) async {
    final pending = Completer<LibraryTreeSnapshot>();
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) => pending.future,
    );
    addTearDown(fixture.dispose);
    final track = testMusicTrack(
      name: 'Ocean audio',
      path: '/library/Ocean.mp3',
      groupKey: '/library/Ocean.mp3',
      groupTitle: 'Ocean audio',
      isSingle: true,
    );
    fixture.library.addTracks([track], persist: false);
    fixture.library.snapshotCacheService.adoptCardSnapshot(
      LibraryTreeSnapshot(tree: const [], leafFolderCount: 0),
    );
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final query = ValueNotifier('');
    addTearDown(query.dispose);
    await tester.pumpWidget(
      fixture.build(
        ValueListenableBuilder<String>(
          valueListenable: query,
          builder: (_, value, _) => results(
            fixture: fixture,
            scrollController: controller,
            query: value,
            onTreeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final noFiles = fixture.languageProvider.tr('no_audio_files');
    final noMatches = fixture.languageProvider.tr('no_search_results');
    expect(find.text(noFiles), findsOneWidget);
    query.value = 'Missing';
    await tester.pump();
    expect(find.byType(LibraryLoadingSkeleton), findsNothing);
    expect(find.text(noFiles), findsOneWidget);
    expect(find.text(noMatches), findsNothing);
    pending.complete(
      LibraryTreeSnapshot(tree: [TrackNode(track)], leafFolderCount: 0),
    );
    await tester.pumpAndSettle();
    expect(find.text(noFiles), findsNothing);
    expect(find.text(noMatches), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
      libraryCardSnapshotBuilder: (_) async {
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
    await tester.runAsync(fixture.library.coverArtworkCacheService.initialize);
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
    fixture.library.addTracks([track], persist: false);
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

    expect(node.reads, 0);
    expect(published, isEmpty);
    input.value = (query: 'First', revision: 2, active: true);
    await tester.pumpAndSettle();
    expect(published.last.single, same(node));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'folder expansion survives category switches and clears when search reopens',
    (tester) async {
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
      fixture.library.addTracks([track], persist: false);
      await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
      await fixture.library.loadLibraryTree();
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
      expect(scrollController.positions, hasLength(1));
      active.value = true;
      await tester.pumpAndSettle();

      expect(requests, loadedRequests);
      expect(find.text('Nested audio', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        fixture.build(
          results(
            fixture: fixture,
            scrollController: scrollController,
            query: '',
            onTreeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nested audio', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
