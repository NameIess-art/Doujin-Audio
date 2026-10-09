import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_category_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tree_list.dart';
import 'package:doujin_audio/app/application/browse_page_state_store.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_edit.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/file_tree_row.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_projection.dart';
import 'package:doujin_audio/features/library/presentation/library_edit_tree_tiles.dart';
import 'package:doujin_audio/core/widgets/glass_refresh_indicator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/application/library_entry_editor_service.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

class _QueuedEntryEditorService extends LibraryEntryEditorService {
  final List<Future<LibraryEntryDiskSnapshot>> responses;

  _QueuedEntryEditorService(this.responses);

  @override
  Future<LibraryEntryDiskSnapshot> loadDiskSnapshot(String libraryPath) {
    return responses.removeAt(0);
  }
}

class _ReadCountingTrackNode extends TrackNode {
  _ReadCountingTrackNode(super.track);
  int reads = 0;

  @override
  MusicTrack get track {
    reads++;
    return super.track;
  }
}

class _NoCoverArtworkCacheService extends CoverArtworkCacheService {
  _NoCoverArtworkCacheService() : super(libraryService: LibraryService());

  @override
  Future<String?> futureForFolder(String folderPath) =>
      SynchronousFuture<String?>(null);

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) =>
      SynchronousFuture<String?>(null);
}

Set<String> _selectedSortControls(WidgetTester tester) {
  final controls =
      tester.widget(
            find.byWidgetPredicate((widget) => widget is SegmentedButton),
          )
          as dynamic;
  return (controls.selected as Set<Object>)
      .map((value) => value.toString().split('.').last)
      .toSet();
}

void main() {
  AppRuntimeTestFixture.initialize();
  late Database testDatabase;

  Future<void> finishLibraryTest(
    WidgetTester tester,
    AppRuntimeWidgetTestFixture fixture,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // SQLite completions need real I/O and the widget test's microtask queue.
    var drained = false;
    final drain = fixture.undoableRemovalService.commitPending()
        .then((failures) {
          expect(failures, 0);
          return fixture.runtimeGraph.library.detailCacheService.suspendAndWait();
        })
        .then((_) => fixture.runtimeGraph.library.flushPendingPersistence())
        .then((_) => testDatabase.rawQuery('SELECT 1'))
        .then((_) => drained = true);
    for (var i = 0; i < 2000 && !drained; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(drained, isTrue);
    await drain;
  }

  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

  testWidgets(
    'loaded folder rows share the content fade and do not replay when scrolled',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: _NoCoverArtworkCacheService(),
      );
      addTearDown(fixture.dispose);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      const rootPath = '/library/loading-batch';
      final root = FolderNode('Loading batch', rootPath);
      final loaded = FolderNode('Loading batch', rootPath);
      loaded.addChildren(List.generate(40, (index) => TrackNode(testMusicTrack(
        name: 'Batch track $index',
        path: '$rootPath/$index.mp3',
        groupKey: rootPath,
        groupTitle: 'Loading batch',
      ))));
      var result = Completer<FolderNode?>();
      var listKey = const ValueKey('visible-folder-load');
      final browseState = BrowsePageStateStore()
        ..update('library', {'expanded': [PathMatcher.normalize(rootPath)]});
      var loads = 0;
      Widget buildList() => fixture.build(
        LibraryTreeList(
          key: listKey,
          tree: [root],
          structureRevision: 1,
          selectedPaths: const {},
          isSelectionMode: false,
          scrollController: scroll,
          i18n: fixture.languageProvider,
          topPadding: 0,
          bottomPadding: 0,
          cacheExtent: 0,
          physics: null,
          loadFolder: (_) { loads++; return result.future; },
          currentStructureRevision: () => 1,
          onLongPress: (_) {},
          onToggleSelect: (_) {},
        ),
        overrides: [browsePageStateStoreProvider.overrideWithValue(browseState)],
      );
      await tester.pumpWidget(buildList());
      await tester.pump();
      expect(loads, 1);
      expect(find.text('Batch track 0'), findsNothing);
      result.complete(loaded);
      await tester.pump();
      await tester.pump();
      Finder rowFade() => find.descendant(
        of: find.byType(LibraryTreeList, skipOffstage: false),
        matching: find.ancestor(
          of: find.text('Batch track 0', skipOffstage: false),
          matching: find.byType(FadeTransition, skipOffstage: false),
        ),
        skipOffstage: false,
      );
      expect(tester.widget<FadeTransition>(rowFade()).opacity.value, 0);
      final rowElement = tester.element(find.text('Batch track 0'));
      void expectCompletedFade(Finder finder) {
        final opacity = tester.widget<FadeTransition>(finder).opacity;
        expect(opacity.value, 1);
        expect(opacity, isA<AlwaysStoppedAnimation<double>>());
      }
      final halfFadeDuration = kPlaceholderContentTransitionDuration ~/ 2;
      await tester.pump(halfFadeDuration);
      expect(
        tester.widget<FadeTransition>(rowFade()).opacity.value,
        closeTo(0.5, 0.05),
      );
      await tester.pump(
        kPlaceholderContentTransitionDuration - halfFadeDuration +
            const Duration(milliseconds: 1),
      );
      expectCompletedFade(rowFade());
      expect(tester.element(find.text('Batch track 0')), same(rowElement));
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      scroll.jumpTo(0);
      await tester.pump();
      expect(find.text('Batch track 0'), findsOneWidget);
      expectCompletedFade(rowFade());
      await tester.pumpWidget(buildList());
      expect(loads, 1);
      expectCompletedFade(rowFade());

      result = Completer<FolderNode?>();
      listKey = const ValueKey('covered-folder-load');
      await tester.pumpWidget(buildList());
      await tester.pump();
      expect(loads, 2);
      final navigator = Navigator.of(tester.element(find.byType(LibraryTreeList)));
      unawaited(navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Covering page')),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      result.complete(loaded);
      await tester.pump();
      navigator.pop();
      await tester.pump();
      expectCompletedFade(rowFade());
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Batch track 0'), findsOneWidget);
      expectCompletedFade(rowFade());
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Windows scrollbar starts below the page header',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      void expectTrackBelowHeader() {
        final headerBottom = tester
            .getBottomLeft(find.byType(TopPageHeader))
            .dy;
        final paints = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter is ScrollbarPainter,
        );
        expect(paints, findsWidgets);
        for (final element in paints.evaluate()) {
          final painter =
              (element.widget as CustomPaint).foregroundPainter!
                  as ScrollbarPainter;
          final top = tester.getTopLeft(find.byWidget(element.widget)).dy;
          expect(
            top + painter.padding.resolve(TextDirection.ltr).top,
            greaterThanOrEqualTo(headerBottom),
          );
        }
      }

      expectTrackBelowHeader();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('top page header tolerates transient multiple scroll positions', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;
    final controller = ScrollController();

    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: Stack(
          children: [
            ListView(controller: controller, children: const [SizedBox()]),
            ListView(controller: controller, children: const [SizedBox()]),
            TopPageHeader(title: 'Library', collapseController: controller),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('top page header expands after reverse scroll away from top', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;
    final controller = ScrollController();
    var additionalChildBuilds = 0;

    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: Stack(
          children: [
            ListView.builder(
              controller: controller,
              itemCount: 80,
              itemBuilder: (context, index) => const SizedBox(height: 48),
            ),
            TopPageHeader(
              title: 'Library',
              subtitle: '198 audio',
              trailing: IconButton(
                key: const ValueKey('top_page_header_trailing'),
                onPressed: () {},
                icon: const Icon(Icons.more_horiz),
              ),
              collapseController: controller,
              floatingReveal: true,
              floatingRevealDistance: 40,
              floatingRevealTriggerDistance: 40,
              additionalChild: Builder(
                builder: (context) {
                  additionalChildBuilds++;
                  return const SizedBox(height: 20);
                },
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    controller.jumpTo(120);
    await tester.pump();
    final collapsedHeight = tester.getSize(find.byType(TopPageHeader)).height;
    final collapsedTrailing = find.byKey(
      const ValueKey('top_page_header_trailing'),
    );
    final collapsedOpacity = tester.widget<Opacity>(
      find
          .ancestor(of: collapsedTrailing, matching: find.byType(Opacity))
          .first,
    );
    expect(collapsedOpacity.opacity, 0);

    controller.jumpTo(104);
    await tester.pump();
    final beforeThresholdHeight = tester
        .getSize(find.byType(TopPageHeader))
        .height;

    controller.jumpTo(40);
    await tester.pump();
    final revealedHeight = tester.getSize(find.byType(TopPageHeader)).height;
    final revealedOpacity = tester.widget<Opacity>(
      find
          .ancestor(of: collapsedTrailing, matching: find.byType(Opacity))
          .first,
    );
    expect(revealedOpacity.opacity, greaterThan(0));

    expect(additionalChildBuilds, 1);

    expect(beforeThresholdHeight, collapsedHeight);
    expect(revealedHeight, greaterThan(collapsedHeight));
  });

  testWidgets('top page header with topCapsule only hides capsule on scroll', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: fixture.runtimeGraph,
        persistenceRepository: fixture.persistenceRepository,
        nativePlaybackRepository: fixture.nativePlaybackRepository,
        playbackCommandRunner:
            AppRuntimeWidgetTestFixture.playbackCommandRunner,
        libraryService: fixture.libraryService,
        playbackService: fixture.playbackService,
        timerService: fixture.timerService,
        notificationCoordinatorService: fixture.notificationCoordinatorService,
        settingsRepository: fixture.settings,
        languageProvider: fixture.languageProvider,
        child: Stack(
          children: [
            ListView.builder(
              controller: controller,
              itemCount: 80,
              itemBuilder: (context, index) => const SizedBox(height: 48),
            ),
            TopPageHeader(
              topCapsuleTitle: 'Library',
              topCapsuleData: '10 works  20 tracks',
              title: 'Library Title',
              trailing: IconButton(
                key: const ValueKey('top_page_header_trailing'),
                onPressed: () {},
                icon: const Icon(Icons.more_horiz),
              ),
              collapseController: controller,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final initialHeaderHeight = tester
        .getSize(find.byType(TopPageHeader))
        .height;
    expect(find.byType(HeaderTopCapsule), findsOneWidget);
    expect(find.text('Library Title'), findsOneWidget);
    final trailingBeforeScroll = tester.getRect(
      find.byKey(const ValueKey('top_page_header_trailing')),
    );

    controller.jumpTo(100);
    await tester.pump();

    final scrolledHeaderHeight = tester
        .getSize(find.byType(TopPageHeader))
        .height;
    expect(scrolledHeaderHeight, lessThan(initialHeaderHeight));

    final capsuleOpacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(HeaderTopCapsule),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(capsuleOpacity.opacity, 0.0);

    expect(find.text('Library Title'), findsOneWidget);
    final trailingAfterScroll = tester.getRect(
      find.byKey(const ValueKey('top_page_header_trailing')),
    );
    expect(trailingAfterScroll.size, trailingBeforeScroll.size);
  });

  testWidgets('unloaded library reuses ASMR-style skeleton cards', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();

    final skeletonCards = find.byType(LibraryLikeSkeletonCard);
    expect(skeletonCards, findsAtLeastNWidgets(1));
    expect(
      tester.getSize(skeletonCards.first).height,
      LibraryLikeCardMetrics.rootTileHeight,
    );
    expect(find.byType(PlaceholderContentTransition), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('library and ASMR skeleton cards omit expand placeholders', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: kResponsiveLibraryCardMinWidth,
              child: LibraryLikeSkeletonCard(),
            ),
          ),
        ),
      ),
    );
    final card = find.byType(LibraryLikeSkeletonCard);
    final playPlaceholder = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 25 &&
            widget.height == 25,
      ),
    );
    final expandPlaceholder = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ShimmerContainer &&
            widget.width == 16 &&
            widget.height == 16,
      ),
    );
    expect(playPlaceholder, findsNothing);
    expect(expandPlaceholder, findsNothing);
  });

  testWidgets('empty library card is centered in the available content area', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await tester.pump();

    final headerBottom = tester.getBottomLeft(find.byType(TopPageHeader)).dy;
    final emptyCardRect = tester.getRect(
      find.byKey(const ValueKey('library_empty_state_card')),
    );
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final topGap = emptyCardRect.top - headerBottom;
    final bottomGap = viewportHeight - 16 - emptyCardRect.bottom;
    expect(topGap, greaterThanOrEqualTo(0));
    expect(topGap, closeTo(bottomGap + 4, 1));
  });

  testWidgets('library shows persisted cards before startup scan completes', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          return <String, Object?>{'ok': true, 'value': null};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, null),
    );
    runtimeGraph.library.addWatchedFolder('/library', notify: false);
    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'Partially loaded work',
          path: '/library/work/track.mp3',
          groupKey: '/library/work/track.mp3',
          groupTitle: 'Partially loaded work',
          isSingle: true,
        ),
        testMusicTrack(
          name: 'Second loaded work',
          path: '/library/work-2/track.mp3',
          groupKey: '/library/work-2/track.mp3',
          groupTitle: 'Second loaded work',
          isSingle: true,
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    final scanGeneration = runtimeGraph.library.tryBeginScan(source: 'Music');
    runtimeGraph.library.setScanProgress(
      generation: scanGeneration,
      stage: FolderScanStage.enumerating,
      processed: 1,
      total: 10,
      foundCount: 1,
    );

    await tester.pumpWidget(
      fixture.build(
        const MobileOverlayInset(bottomInset: 132, child: LibraryTab()),
      ),
    );
    await tester.pump();

    await pumpUntilFound(
      tester,
      find.text('Partially loaded work', findRichText: true),
    );

    final workTitle = find.text('Partially loaded work', findRichText: true);
    final workCard = tester.widget<Card>(
      find.ancestor(of: workTitle, matching: find.byType(Card)).first,
    );
    expect(workCard.color, Colors.transparent);
    expect(workCard.elevation, 0);
    expect(workCard.shadowColor, Colors.transparent);
    expect(workCard.surfaceTintColor, Colors.transparent);
    expect((workCard.shape as RoundedRectangleBorder).side, BorderSide.none);
    final libraryList = tester.widget<ListView>(
      find.byKey(const PageStorageKey<String>('library_list')),
    );
    final listPadding = libraryList.padding!.resolve(TextDirection.ltr);
    expect(listPadding.left, LibraryLikeCardMetrics.listHorizontalPadding);
    expect(listPadding.right, LibraryLikeCardMetrics.listHorizontalPadding);
    expect(listPadding.bottom, 148);
    final libraryCards = find.descendant(
      of: find.byKey(const PageStorageKey<String>('library_list')),
      matching: find.byType(Card),
    );
    expect(libraryCards, findsNWidgets(2));
    expect(
      tester.getBottomLeft(libraryCards.at(0)).dy,
      closeTo(tester.getTopLeft(libraryCards.at(1)).dy, 0.01),
    );
    expect(libraryList.physics, isA<AlwaysScrollableScrollPhysics>());
    expect(
      libraryList.physics?.parent,
      isA<GlassRefreshIndicatorScrollPhysics>(),
    );
    expect(
      tester.widget<GlassRefreshIndicator>(
        find.byType(GlassRefreshIndicator),
      ).lockChildWhileRefreshing,
      isTrue,
    );

    await tester.pump(const Duration(milliseconds: 450));
    final cardTop = tester.getTopLeft(libraryCards.at(0)).dy;
    // The scan progress overlay covers the middle of these compact cards.
    final pull = await tester.startGesture(
      tester.getTopRight(libraryCards.first) + const Offset(-2, 24),
    );
    await pull.moveBy(const Offset(0, 20));
    await tester.pump();
    await pull.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(tester.getTopLeft(libraryCards.at(0)).dy, cardTop);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    await pull.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(tester.getTopLeft(libraryCards.at(0)).dy, cardTop);
    expect(libraryList.controller?.offset, 0);
    await pull.up();
    await tester.pump(const Duration(milliseconds: 500));

    final refreshGeneration = runtimeGraph.library.tryBeginScan(
      source: 'Pull to refresh',
    );
    runtimeGraph.library.setScanProgress(
      generation: refreshGeneration,
      stage: FolderScanStage.enumerating,
      processed: 1,
      total: 10,
      foundCount: 1,
    );
    await tester.pump();

    expect(find.byType(LibraryLikeSkeletonCard), findsNothing);
    expect(
      find.text('Partially loaded work', findRichText: true),
      findsOneWidget,
    );
    runtimeGraph.library.finishScan(refreshGeneration);
    await finishLibraryTest(tester, fixture);
  });

  testWidgets('wide library lays cards out from left to right', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    runtimeGraph.library.addWatchedFolder('/library', notify: false);
    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'First wide work',
          path: '/library/first/track.mp3',
          groupKey: '/library/first/track.mp3',
          groupTitle: 'First wide work',
          isSingle: true,
        ),
        testMusicTrack(
          name: 'Second wide work',
          path: '/library/second/track.mp3',
          groupKey: '/library/second/track.mp3',
          groupTitle: 'Second wide work',
          isSingle: true,
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await pumpUntilFound(
      tester,
      find.text('First wide work', findRichText: true),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(
      const ValueKey<String>('/library/first/track.mp3'),
    );
    final second = find.byKey(
      const ValueKey<String>('/library/second/track.mp3'),
    );
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(
      tester.getTopLeft(first).dy,
      closeTo(tester.getTopLeft(second).dy, 1),
    );
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(second).dx));
    await finishLibraryTest(tester, fixture);
  });

  testWidgets('library cover lookups continue while scrolling', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final interactionSource = Object();
    addTearDown(() {
      UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, null);
    });

    const folderPath = '/library/deferred-cover';
    runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'Deferred cover',
          path: '$folderPath/track.mp3',
          groupKey: '$folderPath/track.mp3',
          groupTitle: 'Deferred cover',
          isSingle: true,
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(
      () => runtimeGraph.library.snapshotCacheService.cardSnapshot(
        onCommitted: () {},
      ),
    );
    UiInteractionCoordinator.instance.beginInteraction(interactionSource);

    var trackCoverLookups = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          if (call.method == FileCacheMethod.resolveTrackCover) {
            trackCoverLookups++;
          }
          return <String, Object?>{'ok': true, 'value': null};
        });

    await tester.pumpWidget(
      fixture.build(
        LibraryTrackCoverThumbnail(track: runtimeGraph.library.library.single),
      ),
    );
    for (var i = 0; i < 200 && trackCoverLookups == 0; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }

    expect(trackCoverLookups, greaterThan(0));
    expect(UiInteractionCoordinator.instance.isInteracting, isTrue);
    UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
  });

  testWidgets(
    'known library and session covers defer cold decode and reuse warm images',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('interaction_card_cover_'),
      ))!;
      addTearDown(() async {
        releaseRetainedCoverImages();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } on FileSystemException {
          // Windows can briefly retain file handles in the image decoder.
        }
      });
      final coverPath = '${directory.path}${Platform.pathSeparator}cover.png';
      final track = testMusicTrack(
        name: 'Known cover',
        path: '${directory.path}${Platform.pathSeparator}track.mp3',
        groupKey: directory.path,
        groupTitle: 'Known cover',
      );
      await tester.runAsync(() async {
        await File(coverPath).writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
            '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
        await fixture.runtimeGraph.library.setFolderManualCover(
          directory.path,
          coverPath,
        );
      });
      final session = fixture.runtimeGraph.playback.createTrackSession(
        track,
        customQueueTracks: [track],
      );
      addTearDown(session.shutdown);
      final surfaces = <Widget>[
        LibraryCoverThumbnail(folderPath: directory.path),
        LibraryTrackCoverThumbnail(track: track),
        SessionCoverThumbnail(
          sessionId: session.id,
          track: track,
          coverPath: coverPath,
          coverGeneration: 0,
          coverCacheWidth: 600,
        ),
        SessionHeroArtwork(
          session: PlaybackSessionSnapshot.fromRuntime(session),
          height: 180,
          track: track,
          coverPathFuture: SynchronousFuture(coverPath),
        ),
      ];
      final coverProvider = resizeFileImageIfNeeded(
        path: coverPath,
        cacheWidth: 600,
        useDefaultCacheWidth: false,
      );
      final imageKey = await coverProvider.obtainKey(ImageConfiguration.empty);
      final coverImage = find.byWidgetPredicate(
        (widget) => widget is Image && widget.image == coverProvider,
      );
      final decodedCover = find.descendant(
        of: coverImage,
        matching: find.byType(RawImage),
      );
      final interaction = Object();
      addTearDown(() {
        UiInteractionCoordinator.instance.cancelNavigation(interaction);
      });
      for (final surface in surfaces) {
        releaseRetainedCoverImages();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        UiInteractionCoordinator.instance.beginNavigation(interaction);
        Widget page() =>
            fixture.build(SizedBox(width: 240, height: 180, child: surface));
        await tester.pumpWidget(page());
        await tester.pump();
        expect(
          tester
              .widget<AsyncLocalCoverImage>(find.byType(AsyncLocalCoverImage))
              .initialPath,
          coverPath,
          reason: '${surface.runtimeType} must exercise a known file path',
        );
        expect(coverImage, findsNothing);
        expect(
          PaintingBinding.instance.imageCache.statusForKey(imageKey).tracked,
          isFalse,
        );
        UiInteractionCoordinator.instance.cancelNavigation(interaction);
        for (var tick = 0; tick < 100; tick++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          // The loading artwork also contains a decoded RawImage (app icon).
          // Wait for the requested cover rather than accepting that placeholder.
          if (PaintingBinding.instance.imageCache
              .statusForKey(imageKey)
              .keepAlive) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(tester.widget<RawImage>(decodedCover).image, isNotNull);
        await tester.pumpWidget(const SizedBox.shrink());
        UiInteractionCoordinator.instance.beginNavigation(interaction);
        await tester.pumpWidget(page());
        await tester.pump();
        expect(
          decodedCover,
          findsOneWidget,
          reason: '${surface.runtimeType} must reuse the decoded cover on return',
        );
        expect(tester.widget<RawImage>(decodedCover).image, isNotNull);
        UiInteractionCoordinator.instance.cancelNavigation(interaction);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      releaseRetainedCoverImages();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await finishLibraryTest(tester, fixture);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'library card and work detail share a decoded cover',
    (WidgetTester tester) async {
      addTearDown(releaseRetainedCoverImages);
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1000, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('shared_library_cover_'),
      ))!;
      addTearDown(() async {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        if (await folder.exists()) await folder.delete(recursive: true);
      });
      final trackPath = '${folder.path}${Platform.pathSeparator}track.mp3';
      final coverPath = '${folder.path}${Platform.pathSeparator}cover.png';
      final track = testMusicTrack(
        name: 'Shared cover',
        path: trackPath,
        groupKey: folder.path,
        groupTitle: 'Shared cover',
      );
      await tester.runAsync(() async {
        await File(trackPath).writeAsBytes(const <int>[1]);
        await File(coverPath).writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
            '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
        fixture.runtimeGraph.library.addWatchedFolder(
          folder.path,
          notify: false,
        );
        fixture.runtimeGraph.library.addTracks(
          [track],
          notify: false,
          persist: false,
        );
        await fixture.runtimeGraph.library.setFolderManualCover(
          folder.path,
          coverPath,
        );
        await fixture.runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.libraryRootFolder(folder.path),
          ).copyWith(workTitle: 'Metadata Work Title'),
        );
      });
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await pumpUntilFound(tester, find.text('Metadata Work Title'));
      await tester.runAsync(
        () => fixture.settings.setWorkNameDisplay(WorkNameDisplay.folderName),
      );
      await tester.pump();
      expect(
        find.text(folder.path.split(Platform.pathSeparator).last),
        findsOneWidget,
      );
      await tester.runAsync(
        () => fixture.settings.setWorkNameDisplay(WorkNameDisplay.workTitle),
      );
      await tester.pump();
      expect(find.text('Metadata Work Title'), findsOneWidget);
      final card = tester.widget<AsyncLocalCoverImage>(
        find.byType(AsyncLocalCoverImage).first,
      );
      expect(card.initialPath, isNotNull);
      final cardKey = await resizeFileImageIfNeeded(
        path: card.initialPath!,
        cacheWidth: card.cacheWidth,
        cacheHeight: card.cacheHeight,
        useDefaultCacheWidth: card.useDefaultCacheWidth,
      ).obtainKey(ImageConfiguration.empty);

      await tester.tap(find.byType(ListTile).first);
      await pumpUntilFound(tester, find.byType(WorkDetailPage));
      await pumpUntilNotFound(
        tester,
        find.byKey(const ValueKey('work_detail_entries_skeleton')),
      );
      await tester.pumpAndSettle();
      final detail = tester.widget<LocalCoverImage>(
        find.byType(LocalCoverImage).first,
      );
      expect(detail.path, card.initialPath);
      final detailKey = await resizeFileImageIfNeeded(
        path: detail.path!,
        cacheWidth: coverCacheWidth(
          resolution: fixture.settings.coverImageResolution,
          cacheWidth: detail.cacheWidth,
          useDefaultCacheWidth: detail.useDefaultCacheWidth,
        ),
        cacheHeight: detail.cacheHeight,
        useDefaultCacheWidth: false,
      ).obtainKey(ImageConfiguration.empty);
      expect(detailKey, cardKey);
      Navigator.of(tester.element(find.byType(WorkDetailPage))).pop();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AsyncLocalCoverImage).first,
          matching: find.byType(RawImage),
        ),
        findsOneWidget,
      );

      final session = fixture.runtimeGraph.playback.createTrackSession(
        track,
        customQueueTracks: [track],
      );
      addTearDown(session.shutdown);
      fixture.playbackService.syncSlice(
        activeSessions: [session],
        playingSessionCount: 0,
        focusedSessionId: session.id,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(fixture.build(const PlaylistTab()));
      await tester.pumpAndSettle();
      final playlistCard = tester.widget<AsyncLocalCoverImage>(
        find.byType(AsyncLocalCoverImage).first,
      );
      expect(playlistCard.initialPath, card.initialPath);
      final playlistKey = await resizeFileImageIfNeeded(
        path: playlistCard.initialPath!,
        cacheWidth: playlistCard.cacheWidth,
        cacheHeight: playlistCard.cacheHeight,
        useDefaultCacheWidth: playlistCard.useDefaultCacheWidth,
      ).obtainKey(ImageConfiguration.empty);
      expect(playlistKey, cardKey);
      await tester.pumpWidget(const SizedBox.shrink());
      if (defaultTargetPlatform == TargetPlatform.windows) {
        PaintingBinding.instance.imageCache.clear();
      }
      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(AsyncLocalCoverImage).first,
          matching: find.byType(RawImage),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Windows library thumbnails use the shared cover decode size',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1000, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.runtimeGraph.library.addTracks(
        [
          testMusicTrack(
            name: 'Windows cover',
            path: 'C:/music/track.mp3',
            groupKey: 'C:/music',
            groupTitle: 'Windows cover',
          ),
        ],
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
      final cover = tester.widget<AsyncLocalCoverImage>(
        find.byType(AsyncLocalCoverImage).first,
      );
      expect(cover.cacheWidth, 600);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('library folder expansion does not collide with list storage', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final libraryService = fixture.libraryService;

    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'Stored track',
          path: '/library/root/stored.mp3',
          groupKey: '/library/root',
          groupTitle: 'Root',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ListTile), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'deep library folders navigate through hierarchy in WorkDetailPage',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const rootPath = '/library/deep';
      fixture.runtimeGraph.library.addWatchedFolder(rootPath, notify: false);
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[
          testMusicTrack(
            name: 'Deep track',
            path: '$rootPath/Disc/Chapter/deep.mp3',
            groupKey: rootPath,
            groupTitle: 'Deep work',
          ),
        ],
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.tap(find.byType(ListTile).first);
      await pumpUntilFound(tester, find.byType(WorkDetailPage));
      await pumpUntilNotFound(
        tester,
        find.byKey(const ValueKey('work_detail_entries_skeleton')),
      );
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('Disc', findRichText: true));
      await tester.tap(find.text('Disc', findRichText: true));
      await pumpUntilFound(tester, find.text('Chapter', findRichText: true));
      await tester.tap(find.text('Chapter', findRichText: true));
      await pumpUntilFound(tester, find.text('Deep track', findRichText: true));
      expect(find.text('Deep track', findRichText: true), findsOneWidget);
    },
  );

  testWidgets('content URI roots lazily expose their audio rows', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const rootPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const trackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR/'
        'document/primary%3AASMR%2Fcontent-track.mp3';
    fixture.runtimeGraph.library.addWatchedFolder(rootPath, notify: false);
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[
        testMusicTrack(
          name: 'Content track',
          path: trackPath,
          groupKey: rootPath,
          groupTitle: 'Content work',
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
    await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
    expect(find.text('Content track', findRichText: true), findsNothing);

    await tester.tap(find.byType(ListTile).first);
    await pumpUntilFound(tester, find.byType(WorkDetailPage));
    await pumpUntilFound(
      tester,
      find.text('Content track', findRichText: true),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large expanded folders only build visible track rows', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    const folderPath = '/library/large-folder';
    final tracks = List<MusicTrack>.generate(
      2000,
      (index) => testMusicTrack(
        name: 'Lazy track ${index.toString().padLeft(4, '0')}',
        path: '$folderPath/track-$index.mp3',
        groupKey: folderPath,
        groupTitle: 'Large folder',
      ),
      growable: false,
    );
    runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
    runtimeGraph.library.addTracks(tracks, notify: false, persist: false);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));

    final expansionStopwatch = Stopwatch()..start();
    await tester.tap(find.byType(ListTile).first);
    await pumpUntilFound(tester, find.byType(WorkDetailPage));
    await pumpUntilFound(
      tester,
      find.text('Lazy track 0000', findRichText: true),
    );
    expansionStopwatch.stop();

    final builtRows = find.textContaining('Lazy track', findRichText: true);
    expect(
      builtRows.evaluate().length,
      lessThan(100),
      reason: 'Opening a large folder must not build every track at once',
    );
    debugPrint(
      'large_folder_expand '
      'firstRowsMs=${expansionStopwatch.elapsedMilliseconds} '
      'builtRows=${builtRows.evaluate().length} totalRows=${tracks.length}',
    );

    final detailScrollable = find.descendant(
      of: find.byType(WorkDetailPage),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Lazy track 1999', findRichText: true),
      600,
      scrollable: detailScrollable,
      maxScrolls: 400,
    );
    expect(find.text('Lazy track 1999', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search stops filtering after leaving while the tree loads', (
    tester,
  ) async {
    final pending = Completer<LibraryTreeSnapshot>();
    final fixture = AppRuntimeWidgetTestFixture(
      libraryTreeSnapshotBuilder: (_) => pending.future,
    );
    addTearDown(fixture.dispose);
    final track = testMusicTrack(
      name: 'Search track',
      path: '/library/track.mp3',
      isSingle: true,
      groupKey: '/library/track.mp3',
      groupTitle: 'Search track',
    );
    fixture.library.addTracks([track], notify: false, persist: false);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    // Finish category I/O first so the search waits specifically on the tree.
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 550));
    await tester.enterText(
      find.byKey(const ValueKey<String>('app_search_field')),
      'Search',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox.shrink());
    final node = _ReadCountingTrackNode(track);
    pending.complete(LibraryTreeSnapshot(tree: [node], leafFolderCount: 0));
    await tester.pumpAndSettle();
    expect(node.reads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library search reopens with an empty query at the top', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final tracks = List.generate(
      30,
      (index) => testMusicTrack(
        name: 'Search audio $index',
        path: '/library/search-$index.mp3',
        groupKey: '/library/search-$index.mp3',
        groupTitle: 'Search audio $index',
        isSingle: true,
      ),
    );
    fixture.library.addTracks(tracks, notify: false, persist: false);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(fixture.library.audioLibraryCategorySnapshot);
    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, fixture.library);
    Future<void> openSearch() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('library_search_button')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('app_search_field')),
      );
      await tester.pumpAndSettle();
    }

    await openSearch();
    final field = find.byKey(const ValueKey<String>('app_search_field'));
    await tester.enterText(field, 'Search');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    final list = find.byKey(
      const ValueKey<String>('library_search_results_all'),
    );
    tester.widget<ListView>(list).controller!.jumpTo(500);
    await tester.pump();
    Navigator.of(tester.element(field)).pop();
    await tester.pumpAndSettle();
    await openSearch();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<ListView>(list).controller!.offset, 0);
    expect(tester.takeException(), isNull);
  });

  for (final count in [100, 1000, 5000]) {
    testWidgets('$count search results only build visible track rows', (
      WidgetTester tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const folderPath = '/library/search-large';
      final tracks = List<MusicTrack>.generate(
        count,
        (index) => testMusicTrack(
          name: 'Search track ${index.toString().padLeft(4, '0')}',
          path: '$folderPath/track-$index.mp3',
          groupKey: folderPath,
          groupTitle: 'Search folder',
        ),
        growable: false,
      );
      fixture.runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
      fixture.runtimeGraph.library.addTracks(
        tracks,
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
      await tester.tap(
        find.byKey(const ValueKey<String>('library_search_button')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('app_search_field')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('app_search_field')),
        'Search track',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await pumpUntilFound(
        tester,
        find.text('Search track 0000', findRichText: true),
      );

      final builtRows = find.textContaining('Search track', findRichText: true);
      expect(builtRows.evaluate().length, lessThan(100));
      final lastTrack =
          'Search track ${(count - 1).toString().padLeft(4, '0')}';
      expect(find.text(lastTrack, findRichText: true), findsNothing);

      await tester.scrollUntilVisible(
        find.text(lastTrack, findRichText: true),
        600,
        scrollable: find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('library_search_results_all'),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: count,
      );
      expect(find.text(lastTrack, findRichText: true), findsOneWidget);
    });
  }

  testWidgets('library search exposes retry and recovers after tree failure', (
    WidgetTester tester,
  ) async {
    var attempts = 0;
    var shouldFail = true;
    final fixture = AppRuntimeWidgetTestFixture(
      libraryCardSnapshotBuilder: (payload) async {
        attempts++;
        if (shouldFail) throw StateError('synthetic tree failure');
        return const LibraryOrganizer().buildTree(
          tracks: payload.tracks,
          watchedFolders: payload.watchedFolders,
          watchedLibraries: payload.watchedLibraries,
        );
      },
      libraryTreeSnapshotBuilder: (payload) async {
        attempts++;
        if (shouldFail) throw StateError('synthetic tree failure');
        return const LibraryOrganizer().buildTree(
          tracks: payload.tracks,
          watchedFolders: payload.watchedFolders,
          watchedLibraries: payload.watchedLibraries,
        );
      },
    );
    addTearDown(fixture.dispose);
    const folderPath = '/library/retry-search';
    fixture.runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[
        testMusicTrack(
          name: 'Recovered track',
          path: '$folderPath/track.mp3',
          groupKey: folderPath,
          groupTitle: 'Retry folder',
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('app_search_field')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_search_error')),
    );
    await tester.pumpAndSettle();

    shouldFail = false;
    await tester.tap(find.text(fixture.languageProvider.tr('retry')));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_search_results_all')),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('app_search_field')),
      'Recovered',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await pumpUntilFound(
      tester,
      find.text('Recovered track', findRichText: true),
    );

    expect(attempts, greaterThanOrEqualTo(2));
    expect(
      find.byKey(const ValueKey<String>('library_search_error')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('library search results support multi-selection mode', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const folderPath = '/library/search-selection';
    fixture.runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[
        testMusicTrack(
          name: 'Selectable search work',
          path: '$folderPath/track.mp3',
          groupKey: folderPath,
          groupTitle: 'Selectable search work',
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('app_search_field')),
    );
    await pumpUntilFound(
      tester,
      find.text('search-selection', findRichText: true),
    );
    await tester.pumpAndSettle();

    final searchFolder = find.byKey(
      const ValueKey<String>('search_/library/search-selection'),
    );
    final searchFolderTitle = find.descendant(
      of: searchFolder,
      matching: find.text('search-selection', findRichText: true),
    );
    await tester.longPress(searchFolderTitle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('library_search_batch_selection_header'),
      ),
      findsOneWidget,
    );
    final batchAddButton = find.byKey(
      const ValueKey<String>('library_search_batch_add_button'),
    );
    expect(batchAddButton, findsOneWidget);
    expect(tester.widget<IconButton>(batchAddButton).iconSize, 20);
    final batchPinButton = find.byKey(
      const ValueKey<String>('library_search_batch_pin_button'),
    );
    expect(batchPinButton, findsOneWidget);
    expect(tester.widget<IconButton>(batchPinButton).iconSize, 20);
    expect(
      tester.widget<IconButton>(batchPinButton).tooltip,
      fixture.languageProvider.tr('pin_to_top'),
    );

    await tester.tap(batchPinButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('library_search_batch_selection_header'),
      ),
      findsNothing,
    );
    expect(
      fixture.settingsRepository.pinnedLibraryPaths,
      contains(PathMatcher.normalize(folderPath)),
    );

    await tester.longPress(searchFolderTitle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('library_search_batch_selection_header'),
      ),
      findsOneWidget,
    );
    final batchUnpinButton = find.byKey(
      const ValueKey<String>('library_search_batch_pin_button'),
    );
    expect(batchUnpinButton, findsOneWidget);
    expect(
      tester.widget<IconButton>(batchUnpinButton).tooltip,
      fixture.languageProvider.tr('unpin_from_top'),
    );

    await tester.tap(batchUnpinButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('library_search_batch_selection_header'),
      ),
      findsNothing,
    );
    expect(
      fixture.settingsRepository.pinnedLibraryPaths,
      isNot(contains(PathMatcher.normalize(folderPath))),
    );
    await finishLibraryTest(tester, fixture);
  });

  testWidgets('removing a library audio shows undo and retains other audios', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    const folderPath = '/library/remove-folder-audio';
    final removedTrack = testMusicTrack(
      name: 'Remove this track',
      path: '$folderPath/remove.mp3',
      groupKey: folderPath,
      groupTitle: 'Remove folder audio',
      isSingle: true,
    );
    final retainedTrack = testMusicTrack(
      name: 'Keep this track',
      path: '$folderPath/keep.mp3',
      groupKey: folderPath,
      groupTitle: 'Remove folder audio',
      isSingle: true,
    );
    runtimeGraph.library.addWatchedFolder(folderPath, notify: false);
    runtimeGraph.library.addTracks(
      <MusicTrack>[removedTrack, retainedTrack],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
    await tester.pump(const Duration(milliseconds: 350));

    final removedTrackFinder = find.text(
      'Remove this track',
      findRichText: true,
    );
    final retainedTrackFinder = find.text(
      'Keep this track',
      findRichText: true,
    );
    await pumpUntilFound(tester, removedTrackFinder);
    final trackCard = find.ancestor(
      of: removedTrackFinder,
      matching: find.byType(SwipeRevealCard),
    );
    tester.widget<SwipeRevealCard>(trackCard.first).onRemove();

    var removalCompleted = false;
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        retainedTrackFinder,
        findsOneWidget,
        reason: 'The remaining track should not blank while refreshing',
      );
      if (removedTrackFinder.evaluate().isEmpty) {
        removalCompleted = true;
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(removalCompleted, isTrue);

    await pumpUntilFound(
      tester,
      find.textContaining(fixture.languageProvider.tr('audio_removed')),
    );
    expect(
      find.textContaining(fixture.languageProvider.tr('undo')),
      findsOneWidget,
    );

    await tester.tap(find.textContaining(fixture.languageProvider.tr('undo')));
    await pumpUntilFound(tester, removedTrackFinder);

    expect(find.text('Keep this track', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'excluding a library audio keeps the view stable while refreshing',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const libraryPath = '/library/recoverable-audio';
      final removedTrack = testMusicTrack(
        name: 'Exclude this track',
        path: '$libraryPath/exclude.mp3',
        groupKey: libraryPath,
        groupTitle: 'Recoverable audio',
        isSingle: true,
      );
      final retainedTrack = testMusicTrack(
        name: 'Retain this track',
        path: '$libraryPath/retain.mp3',
        groupKey: libraryPath,
        groupTitle: 'Recoverable audio',
        isSingle: true,
      );
      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          removedTrack,
          retainedTrack,
        ], persist: false)
        ..addTracks(
          <MusicTrack>[removedTrack, retainedTrack],
          notify: false,
          persist: false,
        );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.pump(const Duration(milliseconds: 350));

      final removedTrackFinder = find.text(
        'Exclude this track',
        findRichText: true,
      );
      final retainedTrackFinder = find.text(
        'Retain this track',
        findRichText: true,
      );
      await pumpUntilFound(tester, removedTrackFinder);
      final trackCard = find.ancestor(
        of: removedTrackFinder,
        matching: find.byType(SwipeRevealCard),
      );
      tester.widget<SwipeRevealCard>(trackCard.first).onRemove();

      var removalCompleted = false;
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          retainedTrackFinder,
          findsOneWidget,
          reason: 'Recoverable exclusion should not blank the view',
        );
        if (removedTrackFinder.evaluate().isEmpty) {
          removalCompleted = true;
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }

      expect(removalCompleted, isTrue);
      expect(
        find.textContaining(fixture.languageProvider.tr('undo')),
        findsOneWidget,
      );
      expect(
        runtimeGraph.library.excludedTracksForLibrary(libraryPath),
        isEmpty,
      );
      for (var i = 0; i < 65; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        if (runtimeGraph.library
            .excludedTracksForLibrary(libraryPath)
            .isNotEmpty) {
          break;
        }
      }
      expect(
        runtimeGraph.library.excludedTracksForLibrary(libraryPath),
        <String>[PathMatcher.normalize(removedTrack.path)],
      );
    },
  );

  testWidgets('switching library categories preserves the element selector', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final libraryService = fixture.libraryService;
    final languageProvider = fixture.languageProvider;
    const workPath = '/library/category-work';
    const tagsPreferenceKey = 'library_category_terms_expanded_tags';
    const voiceActorsPreferenceKey =
        'library_category_terms_expanded_voiceActors';

    addTearDown(() async {
      await AppPreferences.remove(tagsPreferenceKey);
      await AppPreferences.remove(voiceActorsPreferenceKey);
    });
    await AppPreferences.setBool(tagsPreferenceKey, false);
    await AppPreferences.setBool(voiceActorsPreferenceKey, true);

    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'Categorized work',
          path: '$workPath/track.mp3',
          groupKey: workPath,
          groupTitle: 'Categorized work',
        ),
        for (var i = 0; i < 20; i++)
          testMusicTrack(
            name: 'Categorized audio $i',
            path: '/imports/category_$i.mp3',
            groupKey: '__single_files__',
            groupTitle: 'Imported files',
            isSingle: true,
          ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(() async {
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(workPath),
        ).copyWith(
          tags: const <String>['sleep'],
          voiceActors: const <String>['Voice Actor'],
        ),
      );
      for (var i = 0; i < 20; i++) {
        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile('/imports/category_$i.mp3'),
          ).copyWith(tags: const ['sleep'], workTitle: 'Categorized audio $i'),
        );
      }
    });

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 200));
    final tagsLabel = languageProvider.tr('library_category_tags');
    final voiceActorsLabel = languageProvider.tr(
      'library_category_voice_actors',
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'app_search_category_AudioLibraryCategoryType.tags',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_category_tags')),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.byKey(const ValueKey<String>('library_category_tags')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListView>(
            find.byKey(const ValueKey<String>('library_category_tags')),
          )
          .physics,
      isA<ClampingScrollPhysics>(),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('app_search_field')),
      'Categorized',
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('展开'), findsOneWidget);
    final expandButton = find.ancestor(
      of: find.text('展开'),
      matching: find.byType(ActionChip),
    );
    await tester.ensureVisible(expandButton);
    await tester.pump(const Duration(milliseconds: 500));
    tester.widget<ActionChip>(expandButton).onPressed!();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('收起'), findsOneWidget);
    final tagsSelector = find.byType(LibraryCategoryTermBox).evaluate().single;
    final outgoingScroll = tester
        .widget<ListView>(
          find.byKey(const ValueKey<String>('library_category_tags')),
        )
        .controller!;
    expect(outgoingScroll.position.maxScrollExtent, greaterThan(80));
    const savedOffset = 40.0;
    outgoingScroll.jumpTo(savedOffset);
    unawaited(
      outgoingScroll.animateTo(
        savedOffset + 10,
        duration: const Duration(seconds: 1),
        curve: Curves.linear,
      ),
    );
    expect(outgoingScroll.position.isScrollingNotifier.value, isTrue);
    final outgoingOffset = outgoingScroll.offset;

    tester.widget<InkWell>(
      find.byKey(const ValueKey<String>(
        'app_search_category_AudioLibraryCategoryType.voiceActors',
      )),
    ).onTap!();
    expect(outgoingScroll.position.isScrollingNotifier.value, isFalse);
    expect(outgoingScroll.offset, outgoingOffset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('展开'), findsOneWidget);
    expect(find.text('收起'), findsNothing);
    expect(
      find
          .byType(LibraryCategoryTermBox, skipOffstage: false)
          .evaluate()
          .firstWhere(
            (element) =>
                (element.widget as LibraryCategoryTermBox).categoryType ==
                AudioLibraryCategoryType.tags,
          ),
      same(tagsSelector),
    );

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'app_search_category_AudioLibraryCategoryType.tags',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('展开'), findsNothing);
    expect(
      find.byType(LibraryCategoryTermBox).evaluate().single,
      same(tagsSelector),
    );
    expect(find.descendant(
      of: find.byKey(const ValueKey<String>(
        'app_search_category_AudioLibraryCategoryType.tags',
      )),
      matching: find.text(tagsLabel),
    ), findsOneWidget);
    expect(find.descendant(
      of: find.byKey(const ValueKey<String>(
        'app_search_category_AudioLibraryCategoryType.voiceActors',
      )),
      matching: find.text(voiceActorsLabel),
    ), findsOneWidget);
  });

  testWidgets('category removal uses recoverable library audio semantics', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    const libraryPath = '/library/category-removal';
    const trackPath = '$libraryPath/tagged.mp3';
    final taggedTrack = testMusicTrack(
      name: 'Tagged library audio',
      path: trackPath,
      groupKey: libraryPath,
      groupTitle: 'Tagged library audio',
      isSingle: true,
    );
    runtimeGraph.library
      ..addWatchedLibrary(libraryPath, notify: false)
      ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
        taggedTrack,
      ], persist: false)
      ..addTracks(<MusicTrack>[taggedTrack], notify: false, persist: false);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(
      () => runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          AudioDetailTarget.singleAudioFile(trackPath),
        ).copyWith(tags: const <String>['removable']),
      ),
    );

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_search_results_all')),
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'app_search_category_AudioLibraryCategoryType.tags',
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_category_tags')),
    );
    final entryCard = find.byKey(const ValueKey<String>('category_$trackPath'));
    await pumpUntilFound(tester, entryCard);
    await tester.ensureVisible(entryCard);
    await tester.pumpAndSettle();
    final swipeCard = find.descendant(
      of: entryCard,
      matching: find.byType(SwipeRevealCard),
    );
    tester.widget<SwipeRevealCard>(swipeCard).onRemove();

    await pumpUntilFound(
      tester,
      find.textContaining(fixture.languageProvider.tr('undo')),
    );
    await pumpUntilNotFound(
      tester,
      find.text('Tagged library audio', findRichText: true),
    );
    expect(runtimeGraph.library.excludedTracksForLibrary(libraryPath), isEmpty);
    for (var i = 0; i < 55; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (runtimeGraph.library
          .excludedTracksForLibrary(libraryPath)
          .isNotEmpty) {
        break;
      }
    }
    expect(runtimeGraph.library.excludedTracksForLibrary(libraryPath), <String>[
      PathMatcher.normalize(trackPath),
    ]);
  });

  testWidgets('library search filters asynchronously and clears to content', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'Soft Rain',
          path: '/library/rain/soft_rain.mp3',
          groupKey: '/library/rain/soft_rain.mp3',
          groupTitle: 'Soft Rain',
          isSingle: true,
        ),
        testMusicTrack(
          name: 'Ocean Waves',
          path: '/library/rain/ocean_waves.mp3',
          groupKey: '/library/rain/ocean_waves.mp3',
          groupTitle: 'Ocean Waves',
          isSingle: true,
        ),
        testMusicTrack(
          name: 'Folder Track One',
          path: '/library/folder/one.mp3',
          groupKey: '/library/folder',
          groupTitle: 'Folder Work',
        ),
        testMusicTrack(
          name: 'Folder Track Two',
          path: '/library/folder/two.mp3',
          groupKey: '/library/folder',
          groupTitle: 'Folder Work',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const LibraryTab(),
      ),
    );
    await tester.pump();
    expect(runtimeGraph.library.snapshotCacheService.treeSnapshotRevision, -1);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('library_search_button')),
      findsOneWidget,
    );

    final scanGeneration = runtimeGraph.library.tryBeginScan(source: 'Music');
    runtimeGraph.library.setScanProgress(
      generation: scanGeneration,
      stage: FolderScanStage.enumerating,
      processed: 120,
      total: 500,
      foundCount: 120,
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      find.byKey(const ValueKey('library_scan_progress_card')),
      findsOneWidget,
    );
    final progress = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('library_scan_progress_card')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progress.value, closeTo(0.24, 0.001));
    expect(
      find.text(
        languageProvider.tr('scan_processed_total', {
          'processed': 120,
          'total': 500,
        }),
      ),
      findsOneWidget,
    );
    runtimeGraph.library.finishScan(scanGeneration);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 200));
    final searchField = find.byKey(const ValueKey<String>('app_search_field'));
    expect(searchField, findsOneWidget);
    final searchControls = find.byKey(
      const ValueKey<String>('app_search_controls_overlay'),
    );
    expect(
      find.descendant(
        of: searchControls,
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_search_results_all')),
    );
    expect(
      tester
          .widget<ListView>(
            find.byKey(const ValueKey<String>('library_search_results_all')),
          )
          .physics,
      isA<ClampingScrollPhysics>(),
    );
    final searchContentTransition = find.descendant(
      of: find.byKey(const ValueKey<String>('app_search_body_layer')),
      matching: find.byType(PlaceholderContentTransition),
    );
    expect(searchContentTransition, findsOneWidget);
    final searchResultTiles = find.descendant(
      of: find.byKey(const ValueKey<String>('library_search_results_all')),
      matching: find.byType(ListTile),
    );
    expect(searchResultTiles, findsOneWidget);
    final searchHeroMode = tester.widget<HeroMode>(
      find.byKey(const ValueKey<String>('library_search_hero_mode')),
    );
    expect(searchHeroMode.enabled, isFalse);
    expect(
      tester.getTopLeft(searchResultTiles).dy,
      greaterThanOrEqualTo(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey<String>('app_search_category_shell')),
            )
            .dy,
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('recent_search_list')),
      findsNothing,
    );

    await tester.enterText(searchField, 'ocean');
    await tester.pump(const Duration(milliseconds: 250));
    await pumpUntilFound(tester, find.text('Ocean Waves', findRichText: true));
    final transition = tester.widget<PlaceholderContentTransition>(
      searchContentTransition,
    );
    expect(
      find.descendant(
        of: searchContentTransition,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is FadeTransition &&
              (identical(widget.child, transition.placeholder) ||
                  identical(widget.child, transition.content)),
        ),
      ),
      findsNWidgets(2),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntilNotFound(tester, find.text('Soft Rain', findRichText: true));

    expect(find.text('Soft Rain', findRichText: true), findsNothing);
    expect(find.text('Ocean Waves', findRichText: true), findsOneWidget);
    expect(
      runtimeGraph.library.snapshotCacheService.treeSnapshotRevision,
      libraryService.structureRevision,
    );

    await tester.tap(find.byKey(const ValueKey<String>('app_search_close')));
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_search_results_all')),
    );

    await pumpUntilFound(tester, find.text('Soft Rain', findRichText: true));
    expect(find.text('Ocean Waves', findRichText: true), findsOneWidget);
    expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  });

  testWidgets('expanding a library folder keeps its resolved cover visible', (
    WidgetTester tester,
  ) async {
    Future<String?> coverFuture = SynchronousFuture<String?>('cover-path');

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: StatefulBuilder(
            builder: (context, setState) => ExpansionTile(
              onExpansionChanged: (expanded) {
                if (!expanded) return;
                setState(() {
                  coverFuture = SynchronousFuture<String?>(null);
                });
              },
              title: SizedBox(
                width: 80,
                height: 64,
                child: AsyncCoverImage(
                  requestKey: 'library-folder',
                  initialPath: 'cover-path',
                  future: coverFuture,
                  retryFutureBuilder: () => SynchronousFuture<String?>(null),
                  imageBuilder: (_, _) => const ColoredBox(
                    key: ValueKey('resolved-cover'),
                    color: Colors.blue,
                  ),
                  fallbackBuilder: (_) =>
                      const SizedBox(key: ValueKey('cover-fallback')),
                ),
              ),
              children: const [SizedBox(height: 40)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('resolved-cover')), findsOneWidget);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('resolved-cover')), findsOneWidget);
    expect(find.byKey(const ValueKey('cover-fallback')), findsNothing);
  });

  testWidgets(
    'library tab shows localized empty state when search has no matches',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final persistenceRepository = fixture.persistenceRepository;
      final nativePlaybackRepository = fixture.nativePlaybackRepository;
      const playbackCommandRunner =
          AppRuntimeWidgetTestFixture.playbackCommandRunner;
      final libraryService = fixture.libraryService;
      final playbackService = fixture.playbackService;
      final timerService = fixture.timerService;
      final notificationCoordinatorService =
          fixture.notificationCoordinatorService;
      final settingsRepository = fixture.settings;
      final languageProvider = fixture.languageProvider;

      runtimeGraph.library.addTracks(
        [
          testMusicTrack(
            name: 'Soft Rain',
            path: '/library/rain/soft_rain.mp3',
            groupKey: '/library/rain',
            groupTitle: 'Rain Pack',
          ),
        ],
        notify: false,
        persist: false,
      );
      libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(
        buildAppRuntimeTestApp(
          runtimeGraph: runtimeGraph,
          persistenceRepository: persistenceRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: const LibraryTab(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        runtimeGraph.library.snapshotCacheService.treeSnapshotRevision,
        -1,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('library_search_button')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(
        find.byKey(const ValueKey<String>('app_search_field')),
        'forest',
      );
      await tester.pump(const Duration(milliseconds: 260));
      await pumpUntilFound(
        tester,
        find.text(languageProvider.tr('no_search_results')),
      );

      expect(
        find.text(languageProvider.tr('no_search_results')),
        findsOneWidget,
      );
      expect(
        runtimeGraph.library.snapshotCacheService.treeSnapshotRevision,
        libraryService.structureRevision,
      );
    },
  );

  testWidgets('library edit button opens imported library management', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    const libraryRoot = '/library/root';
    const childFolder = '/library/root/child';
    const standaloneFolder = '/library/standalone';
    runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
    runtimeGraph.library.addWatchedFolder(childFolder, notify: false);
    runtimeGraph.library.addWatchedFolder(standaloneFolder, notify: false);
    runtimeGraph.library.recordLibraryEntriesForTracks(
      standaloneFolder,
      const <MusicTrack>[],
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const LibraryTab(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip(languageProvider.tr('add')), findsOneWidget);
    expect(find.byTooltip(languageProvider.tr('sort_by')), findsOneWidget);
    await tester.tap(find.byTooltip(languageProvider.tr('sort_by')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(languageProvider.tr('sort_by_title')), findsOneWidget);
    expect(find.text(languageProvider.tr('sort_duration')), findsOneWidget);
    expect(
      find.text(languageProvider.tr('sort_group_by_library')),
      findsOneWidget,
    );
    final sortControls =
        tester.widget(
              find.byWidgetPredicate((widget) => widget is SegmentedButton),
            )
            as dynamic;
    expect(sortControls.segments, hasLength(3));
    expect(sortControls.multiSelectionEnabled, isTrue);
    expect(find.text(languageProvider.tr('cancel')), findsOneWidget);
    expect(find.text(languageProvider.tr('confirm')), findsOneWidget);
    final viewportSize =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    final cancelRect = tester.getRect(
      find.byKey(const ValueKey('sort_options_cancel')),
    );
    final confirmRect = tester.getRect(
      find.byKey(const ValueKey('sort_options_confirm')),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('sort_options_confirm'))),
      isA<TextButton>(),
    );
    expect(confirmRect.bottom, lessThanOrEqualTo(viewportSize.height));
    expect(cancelRect.center.dx, greaterThan(viewportSize.width / 2));
    expect(confirmRect.left, greaterThan(cancelRect.right));
    expect(confirmRect.center.dy, closeTo(cancelRect.center.dy, 0.01));
    expect(confirmRect.width, lessThan(120));
    await tester.ensureVisible(
      find.text(languageProvider.tr('sort_descending')),
    );
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_descending')));
    await tester.pump();
    await tester.ensureVisible(
      find.text(languageProvider.tr('sort_group_by_library')),
    );
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_group_by_library')));
    await tester.pump();
    tester
        .widget<RadioGroup<LibrarySortCriterion>>(
          find.byType(RadioGroup<LibrarySortCriterion>),
        )
        .onChanged(LibrarySortCriterion.duration);
    await tester.pump();
    expect(settingsRepository.librarySortAscending, isTrue);
    expect(settingsRepository.libraryGroupByLibrary, isFalse);
    expect(settingsRepository.librarySortCriterion, LibrarySortCriterion.name);
    await tester.tap(find.text(languageProvider.tr('cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip(languageProvider.tr('sort_by')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<RadioGroup<LibrarySortCriterion>>(
            find.byType(RadioGroup<LibrarySortCriterion>),
          )
          .groupValue,
      LibrarySortCriterion.name,
    );
    expect(_selectedSortControls(tester), <String>{'ascending'});
    tester
        .widget<RadioGroup<LibrarySortCriterion>>(
          find.byType(RadioGroup<LibrarySortCriterion>),
        )
        .onChanged(LibrarySortCriterion.duration);
    await tester.ensureVisible(
      find.text(languageProvider.tr('sort_descending')),
    );
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_descending')));
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('sort_group_by_library')));
    await tester.pump();
    await tester.tap(find.text(languageProvider.tr('confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(settingsRepository.librarySortAscending, isFalse);
    expect(settingsRepository.libraryGroupByLibrary, isTrue);
    expect(
      settingsRepository.librarySortCriterion,
      LibrarySortCriterion.duration,
    );
    expect(find.byTooltip(languageProvider.tr('edit_library')), findsOneWidget);
    expect(
      find.byTooltip(languageProvider.tr('batch_metadata')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip(languageProvider.tr('batch_metadata')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final batchHeader = find.widgetWithText(
      TopPageHeader,
      languageProvider.tr('batch_metadata'),
    );
    final batchHeaderFade = find.descendant(
      of: batchHeader,
      matching: find.byType(Opacity),
    ).first;
    expect(
      tester.widget<Opacity>(batchHeaderFade).opacity,
      inExclusiveRange(0, 1),
    );
    final headerLeft = tester.getRect(batchHeaderFade).left;
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(batchHeaderFade).opacity, 1);
    await tester.tap(
      find.descendant(of: batchHeader, matching: find.byType(BackButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 225));
    expect(
      tester.widget<Opacity>(batchHeaderFade).opacity,
      inExclusiveRange(0, 1),
    );
    expect(tester.getRect(batchHeaderFade).left, closeTo(headerLeft, 0.01));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(batchHeader, findsNothing);
    expect(
      find.byTooltip(languageProvider.tr('video_to_audio')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip(languageProvider.tr('add')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(languageProvider.tr('import_folder')), findsOneWidget);
    expect(find.text(languageProvider.tr('import_file')), findsOneWidget);
    expect(find.text(languageProvider.tr('choose_library')), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byTooltip(languageProvider.tr('edit_library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('root'), findsOneWidget);
    expect(find.text('standalone'), findsNothing);
    expect(find.text('child'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
  });
  testWidgets('library edit keeps restored content folder visible', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const childFolder = '$libraryRoot/document/primary%3AASMR%2FWorkA';
    const syntheticChildFolder = '$libraryRoot::WorkA';
    const nestedFolder = '$libraryRoot::WorkA/Disc1';
    const trackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2FDisc1%2F01.mp3';

    runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
    runtimeGraph.library.addWatchedFolder(childFolder, notify: false);
    runtimeGraph.library.recordLibraryEntriesForTracks(
      libraryRoot,
      const <MusicTrack>[],
      folderPaths: const <String>[childFolder],
      persist: false,
    );
    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: '01',
          path: trackPath,
          groupKey: nestedFolder,
          groupTitle: 'Disc1',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const LibraryEditPage(libraryPath: libraryRoot),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(
      libraryService
          .libraryEntriesForLibrary(libraryRoot)
          .where((entry) => entry.path == syntheticChildFolder),
      hasLength(1),
    );
    expect(
      find.text('1 \u9996\u97f3\u9891', findRichText: true),
      findsOneWidget,
    );

    final rootFolderTile = find.byKey(
      const PageStorageKey<String>(
        'library-edit-folder:$libraryRoot:$syntheticChildFolder',
      ),
    );
    final rootFolderHeader = find
        .descendant(of: rootFolderTile, matching: find.byType(FileTreeRow))
        .first;
    final rootFolderHeaderHeight = tester.getSize(rootFolderHeader).height;
    final rootFolderCard = find.ancestor(
      of: rootFolderTile,
      matching: find.byType(Card),
    );
    expect(rootFolderCard, findsNothing);
    expect(rootFolderHeaderHeight, closeTo(64, 0.001));
    final folderIcon = find
        .descendant(of: rootFolderHeader, matching: find.byType(Icon))
        .first;
    expect(
      tester.widget<Icon>(folderIcon).color,
      AppDesignTokens.folderIconColor,
    );
    final folderSurface = tester.widget<Material>(
      find.byKey(
        const ValueKey('library-edit-folder-surface:$syntheticChildFolder'),
      ),
    );
    expect(folderSurface.borderRadius, FileTreeRow.borderRadius);
    expect(folderSurface.color, Colors.transparent);
    final rootExcludeButton = find
        .descendant(
          of: rootFolderTile,
          matching: find.widgetWithText(
            TextButton,
            languageProvider.tr('exclude'),
          ),
        )
        .first;
    expect(tester.getSize(rootExcludeButton).height, greaterThanOrEqualTo(44));
    final rootButtonHighlight = find.descendant(
      of: rootExcludeButton,
      matching: find.byType(InkWell),
    );
    expect(rootButtonHighlight, findsOneWidget);
    expect(tester.getSize(rootButtonHighlight).height, closeTo(36, 0.001));

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('exclude')).first,
    );
    await tester.pump();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(find.text('Disc1', findRichText: true), findsNothing);
    expect(
      tester.widget<Expansible>(rootFolderTile).controller.isExpanded,
      isFalse,
    );
    expect(find.text(languageProvider.tr('restore')), findsOneWidget);
    expect(
      tester.widget<Icon>(folderIcon).color,
      Theme.of(tester.element(rootFolderHeader)).colorScheme.onSurfaceVariant,
    );
    expect(find.text(languageProvider.tr('excluded')), findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, languageProvider.tr('restore')),
          )
          .style,
      isNull,
    );

    await tester.tap(find.text('WorkA', findRichText: true).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Disc1', findRichText: true), findsOneWidget);
    final childFolderTile = find.byKey(
      const PageStorageKey<String>(
        'library-edit-folder:$libraryRoot:$nestedFolder',
      ),
    );
    final childFolderHeader = find
        .descendant(of: childFolderTile, matching: find.byType(FileTreeRow))
        .first;
    final childFolderHeaderHeight = tester.getSize(childFolderHeader).height;
    expect(childFolderHeaderHeight, lessThan(rootFolderHeaderHeight));
    expect(childFolderHeaderHeight, closeTo(48, 0.001));
    expect(tester.widget<FileTreeRow>(childFolderHeader).titleMaxLines, 1);
    expect(tester.widget<FileTreeRow>(childFolderHeader).subtitleMaxLines, 1);
    final disabledChildActions = tester
        .widgetList<TextButton>(
          find.widgetWithText(TextButton, languageProvider.tr('exclude')),
        )
        .where((button) => button.onPressed == null);
    expect(disabledChildActions, isNotEmpty);

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('restore')).first,
    );
    await tester.pump();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(find.text('1 \u9996\u97f3\u9891', findRichText: true), findsWidgets);

    expect(find.text('Disc1', findRichText: true), findsOneWidget);
    expect(find.text(languageProvider.tr('exclude')), findsWidgets);
  });

  testWidgets(
    'library edit defers scans and their results during page transitions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const root = '/deferred-edit';
      final track = testMusicTrack(
        name: 'Retained during transition',
        path: '$root/old.mp3',
        groupKey: root,
        groupTitle: 'Library',
      );
      fixture.runtimeGraph.library.addWatchedFolder(root, notify: false);
      fixture.runtimeGraph.library.addTracks(
        [track],
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      final scan = Completer<LibraryEntryDiskSnapshot>();
      final service = _QueuedEntryEditorService([scan.future]);
      final coordinator = UiInteractionCoordinator.instance;
      final transition = Object();
      coordinator.beginInteraction(transition);
      await tester.pumpWidget(
        fixture.build(
          LibraryEditPage(libraryPath: root, entryEditorService: service),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(service.responses, hasLength(1));
      final loadingRegion = find.byType(PlaceholderContentTransition);
      final skeleton = find.byKey(
        const ValueKey('library_edit_entries_skeleton'),
      );
      expect(skeleton, findsOneWidget);
      final skeletonRow = find
          .descendant(of: skeleton, matching: find.byType(ShimmerLoader))
          .first;
      expect(tester.getSize(skeletonRow).height, 64.0);
      final skeletonBounds = tester.getRect(skeleton);
      expect(skeletonBounds.bottom, greaterThanOrEqualTo(1000 - 24));
      expect(skeletonBounds.bottom, lessThan(1000 - 24 + 64));
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      await tester.pump();
      final resizedSkeletonBounds = tester.getRect(skeleton);
      expect(resizedSkeletonBounds.height, greaterThan(skeletonBounds.height));
      expect(resizedSkeletonBounds.bottom, greaterThanOrEqualTo(1200 - 24));
      expect(resizedSkeletonBounds.bottom, lessThan(1200 - 24 + 64));
      expect(tester.getSize(skeletonRow).height, 64.0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<PlaceholderContentTransition>(loadingRegion)
          .showPlaceholder, isTrue);
      coordinator.endInteraction(transition);
      await tester.pump(const Duration(milliseconds: 161));
      await tester.pump();
      expect(service.responses, isEmpty);
      coordinator.beginInteraction(transition);
      scan.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const [],
          scannedFolderPaths: const {},
          authoritative: true,
        ),
      );
      await tester.pump();
      expect(fixture.runtimeGraph.library.trackByPath(track.path), same(track));
      coordinator.endInteraction(transition);
      await tester.pump(const Duration(milliseconds: 161));
      await tester.pump();
      expect(fixture.runtimeGraph.library.trackByPath(track.path), isNull);
      expect(tester.widget<PlaceholderContentTransition>(loadingRegion)
          .showPlaceholder, isFalse);
      final contentFade = find.descendant(
        of: loadingRegion,
        matching: find.byType(FadeTransition),
      ).last;
      final placeholderFade = find.ancestor(
        of: skeleton,
        matching: find.byType(FadeTransition),
      ).first;
      expect(tester.widget<FadeTransition>(placeholderFade).opacity.value, 1);
      expect(tester.widget<FadeTransition>(contentFade).opacity.value, 0);
      final halfFadeDuration = kPlaceholderContentTransitionDuration ~/ 2;
      await tester.pump(halfFadeDuration);
      expect(skeleton, findsOneWidget);
      expect(
        tester.widget<FadeTransition>(placeholderFade).opacity.value,
        closeTo(0.5, 0.05),
      );
      expect(
        tester.widget<FadeTransition>(contentFade).opacity.value,
        closeTo(0.5, 0.05),
      );
      await tester.pump(
        kPlaceholderContentTransitionDuration - halfFadeDuration +
            const Duration(milliseconds: 1),
      );
      expect(skeleton, findsNothing);
      expect(tester.widget<FadeTransition>(contentFade).opacity.value, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'covered library edit postpones resume scan until returning',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final snapshot = LibraryEntryDiskSnapshot(
        audioFilePaths: const [],
        scannedFolderPaths: const {},
        authoritative: true,
      );
      final service = _QueuedEntryEditorService([
        Future.value(snapshot),
        Future.value(snapshot),
      ]);
      await tester.pumpWidget(
        fixture.build(
          LibraryEditPage(
            libraryPath: '/covered-edit',
            entryEditorService: service,
          ),
        ),
      );
      await tester.pump();
      final navigator = Navigator.of(
        tester.element(find.byType(LibraryEditPage)),
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(service.responses, hasLength(1));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(service.responses, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'standalone library edit retries failure and ignores exit callbacks',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const libraryRoot = '/library-edit-retry';
      final track = testMusicTrack(
        name: 'Retained track',
        path: '$libraryRoot/retained.mp3',
        groupKey: libraryRoot,
        groupTitle: 'Library',
      );
      fixture.runtimeGraph.library.addWatchedFolder(libraryRoot, notify: false);
      fixture.runtimeGraph.library.addTracks(
        [track],
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      final initial = Completer<LibraryEntryDiskSnapshot>();
      final retry = Completer<LibraryEntryDiskSnapshot>();
      final afterExit = Completer<LibraryEntryDiskSnapshot>();
      final service = _QueuedEntryEditorService([
        initial.future,
        retry.future,
        afterExit.future,
      ]);
      await tester.pumpWidget(
        fixture.build(
          LibraryEditPage(
            libraryPath: libraryRoot,
            entryEditorService: service,
          ),
        ),
      );
      initial.completeError(StateError('disk snapshot failed'));
      await tester.pump();
      final retryButton = find.widgetWithText(
        FilledButton,
        fixture.languageProvider.tr('retry'),
      );
      expect(retryButton, findsOneWidget);
      expect(fixture.runtimeGraph.library.trackByPath(track.path), same(track));
      await tester.tap(retryButton);
      retry.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: [track.path],
          scannedFolderPaths: const {},
          authoritative: true,
        ),
      );
      await tester.pump();
      expect(retryButton, findsNothing);
      expect(find.text('Retained track', findRichText: true), findsOneWidget);
      expect(service.responses, hasLength(1));

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(service.responses, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      afterExit.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const [],
          scannedFolderPaths: const {},
          authoritative: true,
        ),
      );
      await tester.pump();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(fixture.runtimeGraph.library.trackByPath(track.path), same(track));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library edit ignores stale scans and preserves tree on failure',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const libraryRoot = '/library';
      final first = Completer<LibraryEntryDiskSnapshot>();
      final second = Completer<LibraryEntryDiskSnapshot>();
      final third = Completer<LibraryEntryDiskSnapshot>();
      final fourth = Completer<LibraryEntryDiskSnapshot>();
      final service = _QueuedEntryEditorService(
        <Future<LibraryEntryDiskSnapshot>>[
          first.future,
          second.future,
          third.future,
          fourth.future,
        ],
      );
      final oldTrack = testMusicTrack(
        name: 'Old track',
        path: '$libraryRoot/old.mp3',
        groupKey: libraryRoot,
        groupTitle: 'Library',
      );
      fixture.runtimeGraph.library.addWatchedFolder(libraryRoot, notify: false);
      fixture.runtimeGraph.library.addTracks(
        <MusicTrack>[oldTrack],
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(
        fixture.build(
          LibraryEditPage(
            libraryPath: libraryRoot,
            entryEditorService: service,
          ),
        ),
      );
      first.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: <String>[oldTrack.path],
          scannedFolderPaths: const <String>{},
          authoritative: true,
        ),
      );
      await tester.pump();
      expect(find.text('Old track', findRichText: true), findsOneWidget);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      third.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const <String>['/library/new.mp3'],
          scannedFolderPaths: const <String>{},
          authoritative: true,
        ),
      );
      await tester.pump();
      second.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: <String>[oldTrack.path],
          scannedFolderPaths: const <String>{},
          authoritative: true,
        ),
      );
      await tester.pump();
      expect(find.text('new', findRichText: true), findsOneWidget);

      final retainedTrack = testMusicTrack(
        name: 'new',
        path: '$libraryRoot/new.mp3',
        groupKey: libraryRoot,
        groupTitle: 'Library',
      );
      fixture.runtimeGraph.library.addTracks([retainedTrack], persist: false);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      fourth.complete(
        LibraryEntryDiskSnapshot(
          audioFilePaths: const <String>[],
          scannedFolderPaths: const <String>{},
          authoritative: false,
        ),
      );
      await tester.pump();
      expect(find.text('new', findRichText: true), findsOneWidget);
      expect(
        fixture.runtimeGraph.library.trackByPath(retainedTrack.path),
        same(retainedTrack),
      );
      expect(
        fixture.runtimeGraph.library.libraryEntriesForLibrary(libraryRoot)
            .map((entry) => entry.path),
        contains(retainedTrack.path),
      );
      expect(
        find.text(fixture.languageProvider.tr('scan_failed_next_step')),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('library edit keeps excluded tracks compact on a narrow screen', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final persistenceRepository = fixture.persistenceRepository;
    final nativePlaybackRepository = fixture.nativePlaybackRepository;
    const playbackCommandRunner =
        AppRuntimeWidgetTestFixture.playbackCommandRunner;
    final libraryService = fixture.libraryService;
    final playbackService = fixture.playbackService;
    final timerService = fixture.timerService;
    final notificationCoordinatorService =
        fixture.notificationCoordinatorService;
    final settingsRepository = fixture.settings;
    final languageProvider = fixture.languageProvider;

    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const firstTrackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2F%E3%82%8C%E3%81%84%E3%81%8D%E3%82%89%E8%80%B3%E8%88%90%E3%82%81.mp3';
    const secondTrackPath = '$libraryRoot::second-track.mp3';
    const firstTitle = '#羊娘めめ 20260326 nico 【限定ASMR｜睡眠導入】';
    const secondTitle = '陽向葵ゆか_2026_05_09_【全編無料_両耳舐めコラボ】';

    runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: firstTitle,
          path: firstTrackPath,
          groupKey: libraryRoot,
          groupTitle: 'ASMR',
        ),
        testMusicTrack(
          name: secondTitle,
          path: secondTrackPath,
          groupKey: libraryRoot,
          groupTitle: 'ASMR',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        persistenceRepository: persistenceRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const LibraryEditPage(libraryPath: libraryRoot),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final surfacePaths = <String>[firstTrackPath, secondTrackPath];
    final initialSurfaceHeights = <String, double>{
      for (final path in surfacePaths)
        path: tester
            .getSize(find.byKey(ValueKey('library-edit-track-surface:$path')))
            .height,
    };
    for (final path in surfacePaths) {
      final surface = find.byKey(ValueKey('library-edit-track-surface:$path'));
      final icon = find
          .descendant(of: surface, matching: find.byType(Icon))
          .first;
      expect(
        tester.widget<Icon>(icon).color,
        Theme.of(tester.element(surface)).colorScheme.primary,
      );
    }

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('exclude')).first,
    );
    await tester.pump();

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('exclude')).first,
    );
    await tester.pump();

    expect(find.text(firstTitle), findsOneWidget);
    expect(find.text(secondTitle), findsOneWidget);
    expect(find.textContaining('primary%3A'), findsNothing);
    expect(find.text(languageProvider.tr('restore')), findsNWidgets(2));
    expect(find.text(languageProvider.tr('excluded')), findsNothing);
    expect(tester.takeException(), isNull);

    final tileRects = <Rect>[];
    for (final title in <String>[firstTitle, secondTitle]) {
      final tileFinder = find.ancestor(
        of: find.text(title),
        matching: find.byType(FileTreeRow),
      );
      final restoreFinder = find.descendant(
        of: tileFinder,
        matching: find.widgetWithText(
          TextButton,
          languageProvider.tr('restore'),
        ),
      );
      expect(tileFinder, findsOneWidget);
      expect(restoreFinder, findsOneWidget);
      expect(tester.widget<FileTreeRow>(tileFinder).titleMaxLines, 2);
      expect(tester.widget<FileTreeRow>(tileFinder).subtitle, isNull);
      expect(tester.getSize(tileFinder).height, 48);
      final audioIcon = find
          .descendant(of: tileFinder, matching: find.byType(Icon))
          .first;
      expect(
        tester.widget<Icon>(audioIcon).color,
        Theme.of(tester.element(tileFinder)).colorScheme.onSurfaceVariant,
      );
      expect(tester.widget<TextButton>(restoreFinder).style, isNull);
      expect(tester.getSize(restoreFinder).height, greaterThanOrEqualTo(44));
      final restoreHighlight = find.descendant(
        of: restoreFinder,
        matching: find.byType(InkWell),
      );
      expect(restoreHighlight, findsOneWidget);
      expect(tester.getSize(restoreHighlight).height, closeTo(36, 0.001));

      final path = title == firstTitle ? firstTrackPath : secondTrackPath;
      final surfaceFinder = find.byKey(
        ValueKey('library-edit-track-surface:$path'),
      );
      expect(surfaceFinder, findsOneWidget);

      final tileRect = tester.getRect(surfaceFinder);
      final titleRect = tester.getRect(find.text(title));
      final restoreRect = tester.getRect(restoreFinder);
      expect(tileRect.height, initialSurfaceHeights[path]);
      expect(titleRect.right, lessThanOrEqualTo(restoreRect.left));
      expect(restoreRect.right, lessThanOrEqualTo(tileRect.right));
      expect(restoreRect.bottom, lessThanOrEqualTo(tileRect.bottom));
      tileRects.add(tileRect);
    }
    tileRects.sort((first, second) => first.top.compareTo(second.top));
    expect(tileRects.first.bottom, lessThanOrEqualTo(tileRects.last.top));
    expect(tester.takeException(), isNull);
  });

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'library edit animates deep folders and preserves actions with large text ($reduceMotion)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        const libraryRoot = '/library';
        const folderPath = '$libraryRoot/work';
        const trackPath = '$folderPath/long.mp3';
        const title =
            'A long audio title that needs two lines at large text size';
        fixture.runtimeGraph.library.addWatchedLibrary(
          libraryRoot,
          notify: false,
        );
        fixture.runtimeGraph.library.addTracks(
          [
            testMusicTrack(
              name: title,
              path: trackPath,
              groupKey: folderPath,
              groupTitle: 'work',
            ),
          ],
          notify: false,
          persist: false,
        );
        fixture.libraryService.syncSlice(
          isInitialized: true,
          detailRevision: 0,
        );
        final folder = LibraryEditFolderTreeNode(
          folderPath: folderPath,
          depth: 20,
          children: [LibraryEditTrackTreeNode(trackPath)],
        );
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: reduceMotion,
                ),
                child: ListView(
                  children: [
                    LibraryEditTreeNodeWidget(
                      libraryPath: libraryRoot,
                      node: folder,
                      initiallyExpanded: false,
                      onRememberFolder: (_, _) {},
                    ),
                    const SizedBox(height: 1600),
                  ],
                ),
              ),
            ),
          ),
        );
        final expansible = find.byKey(
          const PageStorageKey<String>(
            'library-edit-folder:$libraryRoot:$folderPath',
          ),
        );
        final collapsedHeight = tester.getSize(expansible).height;
        expect(collapsedHeight, greaterThanOrEqualTo(48));
        expect(find.text(title), findsNothing);
        await tester.tap(find.text('work'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 55));
        final partialHeight = tester.getSize(expansible).height;
        await tester.pump(const Duration(milliseconds: 250));
        final expandedHeight = tester.getSize(expansible).height;
        expect(expandedHeight, greaterThan(collapsedHeight));
        if (reduceMotion) {
          expect(partialHeight, expandedHeight);
        } else {
          expect(partialHeight, greaterThan(collapsedHeight));
          expect(partialHeight, lessThan(expandedHeight));
        }
        final row = find.ancestor(
          of: find.text(title),
          matching: find.byType(FileTreeRow),
        );
        final textRect = tester.getRect(find.text(title));
        final trackSurface = find.byKey(
          const ValueKey('library-edit-track-surface:$trackPath'),
        );
        final surfaceRect = tester.getRect(trackSurface);
        expect(tester.widget<Text>(find.text(title)).maxLines, 2);
        expect(tester.getSize(row).height, greaterThan(48));
        expect(tester.getSize(row).height, lessThan(collapsedHeight));
        final folderRow = find.byType(FileTreeRow).first;
        expect(tester.getRect(row).top, tester.getRect(folderRow).bottom);
        expect(surfaceRect.width, 240);
        expect(textRect.width, greaterThan(20));
        expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
        final parentButton = find.descendant(
          of: find.byKey(
            const ValueKey('library-edit-folder-surface:$folderPath'),
          ),
          matching: find.byType(TextButton),
        );
        await tester.tap(parentButton);
        await tester.pump();
        expect(
          tester.widget<Expansible>(expansible).controller.isExpanded,
          isTrue,
        );
        final trackButton = find.descendant(
          of: trackSurface,
          matching: find.byType(TextButton),
        );
        expect(tester.widget<TextButton>(trackButton).onPressed, isNull);
        await tester.tap(parentButton);
        await tester.pump();
        expect(tester.widget<TextButton>(trackButton).onPressed, isNotNull);
        await tester.tap(find.text('work'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 55));
        if (!reduceMotion) {
          final shrinkingHeight = tester.getSize(expansible).height;
          expect(shrinkingHeight, greaterThan(collapsedHeight));
          expect(shrinkingHeight, lessThan(expandedHeight));
        }
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text(title), findsNothing);
        expect(tester.getSize(expansible).height, collapsedHeight);
        await tester.tap(find.text('work'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 55));
        await tester.tap(find.text('work'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        await tester.tap(find.text('work'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Expansible>(expansible).controller.isExpanded,
          isTrue,
        );
        await tester.drag(find.byType(ListView), const Offset(0, -700));
        await tester.pumpAndSettle();
        expect(find.text('work'), findsNothing);
        await tester.drag(find.byType(ListView), const Offset(0, 700));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Expansible>(expansible).controller.isExpanded,
          isTrue,
        );
        expect(find.text(title), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'library edit builds large root file lists lazily',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      const root = '/large-edit';
      final tracks = List.generate(
        2000,
        (index) => testMusicTrack(
          name: 'Audio $index',
          path: '$root/$index.mp3',
          groupKey: root,
          groupTitle: 'Library',
        ),
      );
      fixture.runtimeGraph.library.addWatchedLibrary(root, notify: false);
      fixture.runtimeGraph.library.addTracks(
        tracks,
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      final service = _QueuedEntryEditorService([
        Future.value(
          LibraryEntryDiskSnapshot(
            audioFilePaths: tracks.map((track) => track.path).toList(),
            scannedFolderPaths: const {},
            authoritative: true,
          ),
        ),
      ]);
      await tester.pumpWidget(
        fixture.build(
          LibraryEditPage(libraryPath: root, entryEditorService: service),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(FileTreeRow).evaluate().length, lessThan(40));
      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.byType(FileTreeRow).evaluate().length, lessThan(40));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'library edit page renders search bar in header second row capsule and filters tree',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final libraryService = fixture.libraryService;
      final languageProvider = fixture.languageProvider;

      const libraryRoot = '/library';
      final firstTrack = testMusicTrack(
        name: 'First Song',
        path: '$libraryRoot/first.mp3',
        groupKey: libraryRoot,
        groupTitle: 'Library',
      );
      final secondTrack = testMusicTrack(
        name: 'Second Track',
        path: '$libraryRoot/second.mp3',
        groupKey: libraryRoot,
        groupTitle: 'Library',
      );

      runtimeGraph.library.addWatchedFolder(libraryRoot, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[firstTrack, secondTrack],
        notify: false,
        persist: false,
      );
      libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      final service = _QueuedEntryEditorService([
        Future.value(
          LibraryEntryDiskSnapshot(
            audioFilePaths: <String>[firstTrack.path, secondTrack.path],
            scannedFolderPaths: const <String>{},
            authoritative: true,
          ),
        ),
      ]);

      await tester.pumpWidget(
        fixture.build(
          LibraryEditPage(
            libraryPath: libraryRoot,
            entryEditorService: service,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('First Song', findRichText: true), findsOneWidget);
      expect(find.text('Second Track', findRichText: true), findsOneWidget);

      final searchField = find.byType(TextField);
      expect(searchField, findsOneWidget);

      // Verify search field is inside a HeaderFloatingSurface within TopPageHeader
      final headerFinder = find.byType(TopPageHeader);
      expect(headerFinder, findsOneWidget);
      final searchInHeader = find.descendant(
        of: headerFinder,
        matching: find.byType(TextField),
      );
      expect(searchInHeader, findsOneWidget);

      // Filter by "First"
      await tester.enterText(searchField, 'First');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('First Song', findRichText: true), findsOneWidget);
      expect(find.text('Second Track', findRichText: true), findsNothing);

      final firstSong = tester.widget<RichText>(
        find.text('First Song', findRichText: true),
      );
      expect(
        (firstSong.text as TextSpan).children!.first.style!.fontWeight,
        FontWeight.w900,
      );

      // Filter by non-matching text
      await tester.enterText(searchField, 'Nonexistent');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('First Song', findRichText: true), findsNothing);
      expect(find.text('Second Track', findRichText: true), findsNothing);
      expect(
        find.text(languageProvider.tr('no_search_results')),
        findsOneWidget,
      );

      // Clear search using clear button
      final clearButton = find.byIcon(Icons.clear_rounded);
      expect(clearButton, findsOneWidget);
      await tester.tap(clearButton);
      await tester.pump();

      expect(find.text('First Song', findRichText: true), findsOneWidget);
      expect(find.text('Second Track', findRichText: true), findsOneWidget);
      expect(find.text(languageProvider.tr('no_search_results')), findsNothing);
    },
  );

  testWidgets(
    'library search expands matched work folders and collapses back',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      final libraryService = fixture.libraryService;

      runtimeGraph.library.addTracks(
        [
          testMusicTrack(
            name: 'Ocean Chapter',
            path: '/library/work/ocean_chapter.mp3',
            groupKey: '/library/work',
            groupTitle: 'Rain Work',
          ),
          testMusicTrack(
            name: 'Quiet Chapter',
            path: '/library/work/quiet_chapter.mp3',
            groupKey: '/library/work',
            groupTitle: 'Rain Work',
          ),
        ],
        notify: false,
        persist: false,
      );
      libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('library_search_button')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('library_search_results_all')),
      );
      expect(find.text('Ocean Chapter', findRichText: true), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey<String>('app_search_field')),
        'ocean',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await pumpUntilFound(
        tester,
        find.text('Ocean Chapter', findRichText: true),
      );
      expect(find.text('Quiet Chapter', findRichText: true), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey<String>('app_search_field')),
        '',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await pumpUntilNotFound(
        tester,
        find.text('Ocean Chapter', findRichText: true),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    },
  );

  testWidgets('library category page requires every text and element term', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final libraryService = fixture.libraryService;
    const healingPath = '/library/healing-work';
    const whisperPath = '/library/whisper-work';

    runtimeGraph.library.addTracks(
      [
        testMusicTrack(
          name: 'Healing track',
          path: '$healingPath/track.mp3',
          groupKey: healingPath,
          groupTitle: 'Healing work',
        ),
        testMusicTrack(
          name: 'Whisper track',
          path: '$whisperPath/track.mp3',
          groupKey: whisperPath,
          groupTitle: 'Whisper work',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(() async {
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(healingPath),
        ).copyWith(tags: const <String>['healing', 'whisper']),
      );
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(whisperPath),
        ).copyWith(tags: const <String>['whisper']),
      );
    });

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'app_search_category_AudioLibraryCategoryType.tags',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('library_category_tags')),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('healing-work', findRichText: true), findsOneWidget);
    expect(find.text('whisper-work', findRichText: true), findsOneWidget);

    // Element search with two keywords keeps only the entry carrying both tags.
    await tester.enterText(
      find.byKey(
        const ValueKey<String>('library_category_term_search_field_tags'),
      ),
      'healing whisper',
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('healing-work', findRichText: true), findsOneWidget);
    expect(find.text('whisper-work', findRichText: true), findsNothing);

    // The text query applies on top of the element filter, not instead of it.
    await tester.enterText(
      find.byKey(const ValueKey<String>('app_search_field')),
      'healing',
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('healing-work', findRichText: true), findsOneWidget);

    // Multi-term text queries require every term to match.
    await tester.enterText(
      find.byKey(const ValueKey<String>('app_search_field')),
      'healing,ocean',
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('healing-work', findRichText: true), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  });

  testWidgets(
    'child folder tile height in library tree is exactly 44 and uses rounded border',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const libraryPath = '/library/tree-height';
      final rootTrack = MusicTrack(
        path: '/library/tree-height/disc/audio.mp3',
        displayName: 'audio.mp3',
        groupKey: libraryPath,
        groupTitle: 'tree-height',
        groupSubtitle: '',
        isSingle: false,
        duration: const Duration(minutes: 1),
      );
      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          rootTrack,
        ], persist: false)
        ..addTracks(<MusicTrack>[rootTrack], notify: false, persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      final childFolder = FolderNode(
        'disc',
        '/library/tree-height/disc',
        depth: 1,
      );
      childFolder.addChild(TrackNode(rootTrack));

      await tester.pumpWidget(
        fixture.build(
          Material(
            child: SingleChildScrollView(
              child: LibraryTreeItem(node: childFolder),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final discFolderFinder = find.text('disc', findRichText: true);
      expect(discFolderFinder, findsOneWidget);

      final childExpansionTileFinder = find.ancestor(
        of: discFolderFinder,
        matching: find.byType(ExpansionTile),
      );
      expect(childExpansionTileFinder, findsOneWidget);

      final childExpansionTile = tester.widget<ExpansionTile>(
        childExpansionTileFinder,
      );
      expect(childExpansionTile.shape, isA<RoundedRectangleBorder>());
      expect(childExpansionTile.collapsedShape, isA<RoundedRectangleBorder>());
      final shape = childExpansionTile.shape as RoundedRectangleBorder;
      expect(shape.borderRadius, isA<BorderRadius>());
      expect((shape.borderRadius as BorderRadius).topLeft.x, 8.0);

      final childListTileFinder = find.ancestor(
        of: discFolderFinder,
        matching: find.byType(ListTile),
      );
      final size = tester.getSize(childListTileFinder);
      expect(size.height, 44.0);

      expect(
        find.descendant(
          of: childExpansionTileFinder,
          matching: find.byIcon(Icons.add_circle_rounded),
        ),
        findsNothing,
      );
      final childFolderSwipeCardFinder = find.ancestor(
        of: discFolderFinder,
        matching: find.byType(SwipeRevealCard),
      );
      expect(childFolderSwipeCardFinder, findsOneWidget);

      final swipeCard = tester.widget<SwipeRevealCard>(
        childFolderSwipeCardFinder,
      );
      expect(swipeCard.actionLabel, fixture.languageProvider.tr('remove'));
      await tester.drag(discFolderFinder, const Offset(-200, 0));
      await tester.pumpAndSettle();
      final removeButtonFinder = find.byTooltip(
        fixture.languageProvider.tr('remove_audio_folder'),
      );
      expect(removeButtonFinder, findsOneWidget);

      await tester.tap(removeButtonFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining(fixture.languageProvider.tr('undo')),
        findsOneWidget,
      );
      expect(
        find.text(fixture.languageProvider.tr('folder_removed')),
        findsOneWidget,
      );

      await finishLibraryTest(tester, fixture);
    },
  );

  testWidgets(
    'root folder card supports swipe pin and displays pin badge on cover',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const libraryPath = '/library/RJ123456-pinned-test';
      final rootTrack = MusicTrack(
        path: '$libraryPath/audio.mp3',
        displayName: 'audio.mp3',
        groupKey: libraryPath,
        groupTitle: 'pinned-test',
        groupSubtitle: '',
        isSingle: false,
        duration: const Duration(minutes: 1),
      );
      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          rootTrack,
        ], persist: false)
        ..addTracks(<MusicTrack>[rootTrack], notify: false, persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.pump(const Duration(milliseconds: 350));

      final rootFolderFinder = find.text(
        'RJ123456-pinned-test',
        findRichText: true,
      );
      final swipeCardFinder = find.ancestor(
        of: rootFolderFinder,
        matching: find.byType(SwipeRevealCard),
      );
      expect(swipeCardFinder, findsOneWidget);

      final swipeCard = tester.widget<SwipeRevealCard>(swipeCardFinder);
      expect(swipeCard.onLeadingAction, isNotNull);
      expect(
        swipeCard.leadingActionLabel,
        fixture.languageProvider.tr('pin_to_top'),
      );
      expect(swipeCard.leadingActionIcon, Icons.push_pin_rounded);
      expect(swipeCard.onSecondaryAction, isNotNull);
      expect(
        swipeCard.secondaryActionLabel,
        fixture.languageProvider.tr('download'),
      );

      // Pin badge not shown initially
      expect(
        find.byKey(
          ValueKey<String>(
            'library_pinned_${PathMatcher.normalize(libraryPath)}',
          ),
        ),
        findsNothing,
      );

      // Toggle pin
      swipeCard.onLeadingAction!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Pin badge is now shown on cover
      expect(
        fixture.settings.pinnedLibraryPaths,
        contains(PathMatcher.normalize(libraryPath)),
      );
      expect(
        find.byKey(
          ValueKey<String>(
            'library_pinned_${PathMatcher.normalize(libraryPath)}',
          ),
        ),
        findsOneWidget,
      );
      final rjPosition = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.text('RJ123456'),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(rjPosition.left, 4);
      expect(rjPosition.top, 4);
      expect(rjPosition.right, isNull);
      final pinPosition = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byKey(
                ValueKey<String>(
                  'library_pinned_${PathMatcher.normalize(libraryPath)}',
                ),
              ),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(pinPosition.right, -2);
      expect(pinPosition.top, -2);
      expect(pinPosition.left, isNull);

      final updatedSwipeCard = tester.widget<SwipeRevealCard>(swipeCardFinder);
      expect(
        updatedSwipeCard.leadingActionLabel,
        fixture.languageProvider.tr('unpin_from_top'),
      );
      expect(updatedSwipeCard.leadingActionIconWidget, isA<PushPinOffIcon>());

      await finishLibraryTest(tester, fixture);
    },
  );

  testWidgets(
    'root folder card swipe download action finds ASMR work and navigates to AsmrDownloadPage',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const libraryPath = '/library/Works/RJ123456_Work';
      final rootTrack = MusicTrack(
        path: '/library/Works/RJ123456_Work/audio.mp3',
        displayName: 'audio.mp3',
        groupKey: libraryPath,
        groupTitle: 'RJ123456_Work',
        groupSubtitle: '',
        isSingle: false,
        duration: const Duration(minutes: 1),
      );
      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          rootTrack,
        ], persist: false)
        ..addTracks(<MusicTrack>[rootTrack], notify: false, persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      final testWork = AsmrWork(
        id: 123456,
        title: 'Remote ASMR Title',
        circleName: 'Circle Name',
        sourceId: 'RJ123456',
        sourceType: 'asmr',
        sourceUrl: '',
        coverUrl: '',
        thumbnailUrl: '',
        mainCoverUrl: '',
        releaseDate: null,
        createDate: null,
        duration: Duration.zero,
        dlCount: 0,
        reviewCount: 0,
        rating: 0,
        voiceActors: const <String>[],
        tags: const <String>[],
      );

      final workCompleter = Completer<AsmrWork?>();

      await tester.pumpWidget(
        fixture.build(
          const LibraryTab(),
          overrides: [
            asmrWorkFinderProvider.overrideWithValue(
              (rjCode, {required language}) =>
                  rjCode == 'RJ123456' ? workCompleter.future : Future.value(),
            ),
          ],
        ),
      );
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.pump(const Duration(milliseconds: 350));

      final rootFolderFinder = find.text('RJ123456_Work', findRichText: true);
      final swipeCardFinder = find.ancestor(
        of: rootFolderFinder,
        matching: find.byType(SwipeRevealCard),
      );
      expect(swipeCardFinder, findsOneWidget);

      final swipeCard = tester.widget<SwipeRevealCard>(swipeCardFinder);
      expect(swipeCard.onSecondaryAction, isNotNull);
      expect(
        swipeCard.secondaryActionLabel,
        fixture.languageProvider.tr('download'),
      );

      swipeCard.onSecondaryAction!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final downloadPage = find.byType(AsmrDownloadPage);
      expect(downloadPage, findsOneWidget);

      final pageWidget = tester.widget<AsmrDownloadPage>(downloadPage);
      expect(pageWidget.initialRjCode, 'RJ123456');
      expect(
        PathMatcher.normalize(pageWidget.customDestinationRoot!),
        PathMatcher.normalize('/library/Works'),
      );
      expect(pageWidget.customWorkFolderName, 'RJ123456_Work');
      expect(find.byType(OperationSkeletonList), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('asmr_download_summary_skeleton')),
        findsOneWidget,
      );

      workCompleter.complete(testWork);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Remote ASMR Title'), findsOneWidget);

      await finishLibraryTest(tester, fixture);
    },
  );

  for (final kind in ['audio', 'covered audio', 'video']) {
    testWidgets(
      'single $kind card plays temporarily on tap and edits from its menu',
      (tester) async {
        var prepareCalls = 0;
        var playCalls = 0;
        Map<String, Object?>? snapshot;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(nativePlaybackChannel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>?;
          if (call.method == NativePlaybackMethod.prepareSession) {
            prepareCalls++;
            expect(arguments!['isTemporary'], isTrue);
            snapshot = {
              'sessionId': arguments['sessionId'],
              'path': arguments['path'],
              'uri': arguments['uri'],
              'playing': false,
              'playWhenReady': false,
              'processingState': 'ready',
              'positionMs': 0,
              'bufferedPositionMs': 0,
              'volume': 1.0,
            };
            return {'ok': true, 'value': snapshot};
          }
          if (call.method == NativePlaybackMethod.play) {
            playCalls++;
            return {
              'ok': true,
              'value': {
                ...snapshot!,
                'playing': true,
                'playWhenReady': true,
                'transportCommandId': arguments!['transportCommandId'],
              },
            };
          }
          return {'ok': true, 'value': null};
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(nativePlaybackChannel, null),
        );
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: kind == 'covered audio'
              ? null
              : _NoCoverArtworkCacheService(),
          providedNativePlaybackRepository: NativePlaybackRepository(
            bridge: NativePlaybackBridge.instance,
          ),
        );
        addTearDown(fixture.dispose);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('single_card_'),
        ))!;
        addTearDown(() => directory.delete(recursive: true));
        final track = MusicTrack(
          path: '${directory.path}/selected.${kind == 'video' ? 'mp4' : 'mp3'}',
          displayName: 'Selected $kind',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: '',
          isSingle: true,
          isVideo: kind == 'video',
          duration: const Duration(seconds: 30),
        );
        final target = AudioDetailTarget.singleAudioFile(track.path);
        fixture.library.addTracks([track], notify: false, persist: false);
        String? cover;
        if (kind == 'covered audio') {
          cover = '${directory.path}/cover.png';
          await tester.runAsync(
            () => File(cover!).writeAsBytes(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
          );
        }
        await tester.runAsync(
          () => fixture.library.saveAudioDetail(
            AudioDetail.empty(target).copyWith(
              duration: track.duration,
              cardCoverPath: cover,
              cardCoverSelected: cover != null,
            ),
          ),
        );
        fixture.libraryService.syncSlice(
          isInitialized: true,
          detailRevision: 0,
        );
        await tester.pumpWidget(fixture.build(const LibraryTab()));
        await pumpUntilLibraryTreeReady(tester, fixture.library);
        await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
        await tester.pump(const Duration(milliseconds: 350));
        final title = find.text(track.displayName, findRichText: true);
        expect(title, findsOneWidget);
        final content = find.ancestor(
          of: title,
          matching: find.byType(SwipeRevealCard),
        );
        final actions = tester.widget<LibraryLikeCardActions>(
          find.descendant(of: content, matching: find.byType(LibraryLikeCardActions)),
        );
        expect(actions.onAdd, isNotNull);
        expect(actions.onPlay, isNotNull);
        expect(
          tester.getSize(content).height,
          lessThanOrEqualTo(LibraryLikeCardMetrics.rootTileHeight),
        );
        await tester.tap(title);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        for (var attempt = 0; attempt < 50 && playCalls == 0; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(prepareCalls, 1);
        expect(playCalls, 1);
        expect(find.byType(WorkDetailPage), findsNothing);
        expect(
          PathMatcher.normalize(
            fixture.playback.activeSessions.single.currentTrackPath,
          ),
          PathMatcher.normalize(track.path),
        );
        final temporarySession = fixture.playback.activeSessions.single;
        expect(temporarySession.isTemporary, isTrue);
        actions.onPlay!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.playback.activeSessions.single, same(temporarySession));
        expect(
          fixture.playback.activeSessions.where(
            (session) => !session.isTemporary,
          ),
          isEmpty,
        );
        expect(
          find.text(
            fixture.languageProvider.tr('session_created', {
              'name': track.displayName,
            }),
          ),
          findsNothing,
        );
        await tester.tap(title);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(fixture.playback.activeSessions.single, same(temporarySession));
        final card = find.ancestor(
          of: title,
          matching: find.byType(SwipeRevealCard),
        );
        final editLabel = fixture.languageProvider.tr('audio_detail_edit_info');
        expect(
          tester.widget<SwipeRevealCard>(card).secondaryActionLabel,
          editLabel,
        );
        if (defaultTargetPlatform == TargetPlatform.windows) {
          await tester.tap(
            card,
            buttons: kSecondaryMouseButton,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(editLabel));
        } else {
          await tester.drag(card, const Offset(-250, 0));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip(editLabel));
        }
        await pumpUntilFound(tester, find.byType(DlsiteMetadataReviewPage));
        await tester.pumpAndSettle();
        expect(find.byType(WorkDetailPage), findsNothing);
        final durationField = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('metadata_edit_card_info_duration')),
            matching: find.byType(TextField),
          ),
        );
        expect(durationField.controller!.text, '00:00:30');
        await tester.enterText(
          find.byKey(const ValueKey('metadata_edit_audio_detail_work_title')),
          'Edited title',
        );
        await tester.tap(find.byKey(const ValueKey('dlsite_review_confirm')));
        await pumpUntilNotFound(tester, find.byType(DlsiteMetadataReviewPage));
        expect(
          (await tester.runAsync(
            () => fixture.library.loadAudioDetail(target),
          ))!.detail.workTitle,
          'Edited title',
        );
        await finishLibraryTest(tester, fixture);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final kind in ['plain', 'covered', 'video']) {
    for (final pinned in [false, true]) {
      testWidgets(
        'single audio selection keeps content and indicators visible (kind: $kind, pinned: $pinned)',
        (WidgetTester tester) async {
          final fixture = AppRuntimeWidgetTestFixture(
            coverArtworkCacheService: _NoCoverArtworkCacheService(),
          );
          addTearDown(fixture.dispose);
          final runtimeGraph = fixture.runtimeGraph;
          const libraryPath = '/library/single-track-test';
          final singleTrack = MusicTrack(
            path: '/library/single-track-test/single.mp3',
            displayName: 'single.mp3',
            groupKey: libraryPath,
            groupTitle: 'single-track-test',
            groupSubtitle: '',
            isSingle: true,
            duration: const Duration(minutes: 2),
            manualCoverPath: kind == 'covered' ? '/test/cover.png' : null,
            isVideo: kind == 'video',
          );
          runtimeGraph.library
            ..addWatchedLibrary(libraryPath, notify: false)
            ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
              singleTrack,
            ], persist: false)
            ..addTracks(
              <MusicTrack>[singleTrack],
              notify: false,
              persist: false,
            );
          fixture.libraryService.syncSlice(
            isInitialized: true,
            detailRevision: 0,
          );

          if (pinned) {
            await fixture.settings.toggleLibraryPathPinned(singleTrack.path);
          }

          await tester.pumpWidget(fixture.build(const LibraryTab()));
          await tester.pump();
          await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
          await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
          await tester.pump(const Duration(milliseconds: 350));

          final pinBadge = find.byKey(
            ValueKey<String>(
              'library_pinned_${PathMatcher.normalize(singleTrack.path)}',
            ),
          );
          expect(pinBadge, pinned ? findsOneWidget : findsNothing);
          expect(tester.takeException(), isNull);

          // Long press on single track to enter multi-select
          final trackFinder = find.text('single.mp3', findRichText: true);
          await tester.longPress(trackFinder);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(trackFinder, findsOneWidget);
          final selectionBadge = find.byKey(
            ValueKey<String>(
              'library_selection_indicator_${PathMatcher.normalize(singleTrack.path)}',
            ),
          );
          expect(selectionBadge, findsOneWidget);
          expect(pinBadge, pinned ? findsOneWidget : findsNothing);
          final cardFinder = find
              .ancestor(of: trackFinder, matching: find.byType(Card))
              .first;
          final cardRect = tester.getRect(cardFinder);
          final titleRect = tester.getRect(trackFinder);
          final selectionRect = tester.getRect(selectionBadge);
          expect(selectionRect.left, lessThanOrEqualTo(titleRect.left));
          expect(selectionRect.top, greaterThanOrEqualTo(titleRect.bottom));
          expect(cardRect.contains(selectionRect.topLeft), isTrue);
          expect(cardRect.contains(selectionRect.bottomRight), isTrue);
          if (pinned) {
            final pinRect = tester.getRect(pinBadge);
            if (kind == 'plain') {
              expect(pinRect.right, lessThan(titleRect.left));
              expect(pinRect.top, titleRect.top - 2);
            } else {
              final position = tester.widget<Positioned>(
                find
                    .ancestor(
                      of: pinBadge,
                      matching: find.byType(Positioned),
                    )
                    .first,
              );
              expect(position.top, -2);
              expect(position.right, -2);
            }
          }
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.byKey(const ValueKey('library_exit_selection_button')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(trackFinder, findsOneWidget);
          expect(selectionBadge, findsNothing);
          expect(tester.takeException(), isNull);

          await finishLibraryTest(tester, fixture);
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.windows,
        }),
      );
    }
  }

  testWidgets(
    'single track without cover stays unhighlighted without entry buttons',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const libraryPath = '/library/single-track-active-test';
      final singleTrack = MusicTrack(
        path: '$libraryPath/single.mp3',
        displayName: 'single.mp3',
        groupKey: libraryPath,
        groupTitle: 'single-track-active-test',
        groupSubtitle: '',
        isSingle: true,
      );

      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          singleTrack,
        ], persist: false)
        ..addTracks(<MusicTrack>[singleTrack], notify: false, persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byIcon(Icons.add_circle_rounded), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      final cardFinder = find.ancestor(
        of: find.text('single.mp3', findRichText: true),
        matching: find.byType(Card),
      );
      final card = tester.widget<Card>(cardFinder.first);
      expect(card.color, Colors.transparent);
      expect(runtimeGraph.playback.activeSessions, isEmpty);

      await finishLibraryTest(tester, fixture);
    },
  );

  for (final kind in ['folder', 'category folder', 'category audio']) {
    testWidgets(
      '$kind card adds to playlist and plays temporarily from its compact actions',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: _NoCoverArtworkCacheService(),
        );
        addTearDown(fixture.dispose);
        fixture.playback.detachCommandPort();
        const root = '/library/compact-actions';
        final isFolder = kind != 'category audio';
        final tracks = [
          for (var i = 0; i < (isFolder ? 2 : 1); i++)
            MusicTrack(
              path: '$root/track$i.mp3',
              displayName: 'Compact action track $i',
              groupKey: isFolder ? root : '__single_files__',
              groupTitle: 'Compact actions',
              groupSubtitle: '',
              isSingle: !isFolder,
            ),
        ];
        fixture.library.addWatchedFolder(root, notify: false);
        fixture.library.addTracks(tracks, notify: false, persist: false);
        fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
        final target = isFolder
            ? AudioDetailTarget.libraryRootFolder(root)
            : AudioDetailTarget.singleAudioFile(tracks.first.path);
        final detail = AudioDetail.empty(target).copyWith(rating: 4.5);
        final folder = FolderNode('Compact actions', root)
          ..addChildren(tracks.map(TrackNode.new));
        Widget buildCard(bool selectionMode) => kind == 'folder'
            ? LibraryFolderNodeWidget(
                folder: folder,
                initiallyExpanded: false,
                searchQuery: '',
                isSelectionMode: selectionMode,
              )
            : AudioLibraryCategoryEntryCard(
                entry: AudioLibraryCategoryEntry(
                  target: target,
                  title: 'Compact actions',
                  path: target.targetPath,
                  isFolder: isFolder,
                  detail: detail,
                  tracks: tracks,
                ),
                folder: null,
                secondaryIcon: Icons.sell_outlined,
                secondaryText: 'Tag',
                isSelectionMode: selectionMode,
                isSelected: selectionMode,
              );
        await tester.pumpWidget(fixture.build(buildCard(false)));
        await tester.pump(const Duration(milliseconds: 350));
        final actionsFinder = find.byType(LibraryLikeCardActions);
        final actions = tester.widget<LibraryLikeCardActions>(actionsFinder);
        expect(actions.onAdd, isNotNull);
        expect(actions.onPlay, isNotNull);
        await tester.tap(find.descendant(
          of: actionsFinder,
          matching: find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
        ));
        for (var attempt = 0;
            attempt < 50 && fixture.playback.activeSessions.isEmpty;
            attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        final temporary = fixture.playback.activeSessions.single;
        expect(temporary.isTemporary, isTrue);
        expect(temporary.customQueueTracks, hasLength(tracks.length));
        expect(find.byType(WorkDetailPage), findsNothing);
        await tester.tap(find.descendant(
          of: actionsFinder,
          matching: find.widgetWithIcon(IconButton, Icons.add_circle_rounded),
        ));
        await tester.pump();
        expect(fixture.playback.activeSessions, hasLength(2));
        expect(
          fixture.playback.activeSessions.where((session) => !session.isTemporary),
          hasLength(1),
        );
        expect(fixture.playback.activeSessions.contains(temporary), isTrue);
        await tester.pumpWidget(fixture.build(buildCard(true)));
        await tester.pump(const Duration(milliseconds: 350));
        final disabled = tester.widget<LibraryLikeCardActions>(actionsFinder);
        expect(disabled.onAdd, isNull);
        expect(disabled.onPlay, isNull);
        await finishLibraryTest(tester, fixture);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'root folder card tap opens WorkDetailPage and does not expand folder tree inline',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const libraryPath = '/library/Works/Work_A';
      final track1 = MusicTrack(
        path: '/library/Works/Work_A/Disc1/track1.mp3',
        displayName: 'track1.mp3',
        groupKey: libraryPath,
        groupTitle: 'Work_A',
        groupSubtitle: '',
        isSingle: false,
        duration: const Duration(minutes: 2),
      );

      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          track1,
        ], persist: false)
        ..addTracks(<MusicTrack>[track1], notify: false, persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.pump(const Duration(milliseconds: 350));

      final rootFolderFinder = find.text('Work_A', findRichText: true);
      expect(rootFolderFinder, findsOneWidget);
      final card = find.ancestor(
        of: rootFolderFinder,
        matching: find.byType(SwipeRevealCard),
      );
      expect(card, findsOneWidget);
      expect(
        find.ancestor(of: card, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        find.descendant(of: card, matching: find.byType(InkWell)),
        findsWidgets,
      );

      // Card is not an ExpansionTile
      final expansionTileFinder = find.ancestor(
        of: rootFolderFinder,
        matching: find.byType(ExpansionTile),
      );
      expect(expansionTileFinder, findsNothing);

      // Tap card
      await tester.tap(rootFolderFinder);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Navigated to WorkDetailPage
      expect(find.byType(WorkDetailPage), findsOneWidget);
      await finishLibraryTest(tester, fixture);
    },
  );
}
