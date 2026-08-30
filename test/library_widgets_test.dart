import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/core/widgets/app_scroll_physics.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/library/application/library_entry_editor_service.dart';
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
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

  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  setUpAll(() async {
    testDatabase = await AppRuntimeTestFixture.installSharedDatabase();
  });

  tearDownAll(() async {
    await AppRuntimeTestFixture.disposeSharedDatabase(testDatabase);
  });

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
              collapseDistance: 56,
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
    final swipeCard = tester.widget<SwipeRevealCard>(
      find.ancestor(of: workTitle, matching: find.byType(SwipeRevealCard)),
    );
    expect(
      swipeCard.closedColor,
      Theme.of(tester.element(workTitle)).colorScheme.surface,
    );

    expect(runtimeGraph.library.categorySnapshot, isNull);
    await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
    expect(find.byType(LibraryLikeSkeletonCard), findsNothing);
    expect(runtimeGraph.library.state.isScanning, isTrue);

    runtimeGraph.library.finishScan(scanGeneration);
    await tester.pump();

    final libraryList = tester.widget<ListView>(
      find.byKey(const PageStorageKey<String>('library_list')),
    );
    final listPadding = libraryList.padding!.resolve(TextDirection.ltr);
    expect(listPadding.left, LibraryLikeCardMetrics.listHorizontalPadding);
    expect(listPadding.right, LibraryLikeCardMetrics.listHorizontalPadding);
    expect(listPadding.bottom, 148);
    final libraryCards = find.descendant(
      of: find.byKey(const PageStorageKey<String>('library_list')),
      matching: find.byType(SwipeRevealCard),
    );
    expect(libraryCards, findsNWidgets(2));
    expect(
      tester.getBottomLeft(libraryCards.at(0)).dy,
      closeTo(tester.getTopLeft(libraryCards.at(1)).dy, 0.01),
    );
    expect(libraryList.physics, isA<AlwaysScrollableScrollPhysics>());
    expect(libraryList.physics?.parent, isA<RefreshTopScrollPhysics>());

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
  });

  testWidgets('library cover lookups wait until scrolling becomes idle', (
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

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();

    expect(trackCoverLookups, 0);

    UiInteractionCoordinator.instance.cancelInteraction(interactionSource);
    for (var i = 0; i < 200 && trackCoverLookups == 0; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }

    expect(trackCoverLookups, greaterThan(0));
  });

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
    expect(find.byType(ExpansionTile), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('deep library folders collapse and restore visible descendants', (
    WidgetTester tester,
  ) async {
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
    await tester.tap(find.byType(ExpansionTile).first);
    await pumpUntilFound(tester, find.text('Disc', findRichText: true));
    await tester.pump(kAppMotionStandard);
    await tester.pump();
    await tester.tap(find.text('Disc', findRichText: true));
    await tester.pump(kAppMotionStandard);
    await tester.pump();
    expect(find.text('Chapter', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Chapter', findRichText: true));
    await pumpUntilFound(tester, find.text('Deep track', findRichText: true));

    await tester.tap(find.text('Disc', findRichText: true));
    await tester.pump();
    expect(find.text('Deep track', findRichText: true), findsOneWidget);
    final collapsingReveal = tester.widget<AnimatedTreeReveal>(
      find
          .ancestor(
            of: find.text('Deep track', findRichText: true),
            matching: find.byType(AnimatedTreeReveal),
          )
          .first,
    );
    expect(collapsingReveal.visible, isFalse);
    await tester.pump(kAppMotionStandard ~/ 2);
    expect(find.text('Deep track', findRichText: true), findsOneWidget);
    await tester.pump(kAppMotionStandard);
    await tester.pump();
    expect(find.text('Deep track', findRichText: true), findsNothing);
    await tester.tap(find.text('Disc', findRichText: true));
    await pumpUntilFound(tester, find.text('Chapter', findRichText: true));
    expect(find.text('Deep track', findRichText: true), findsOneWidget);
  });

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

    await tester.tap(find.byType(ExpansionTile).first);
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
    await tester.tap(find.byType(ExpansionTile).first);
    await pumpUntilFound(
      tester,
      find.text('Lazy track 0000', findRichText: true),
    );
    expansionStopwatch.stop();

    final builtRows = find.textContaining('Lazy track', findRichText: true);
    expect(
      builtRows.evaluate().length,
      lessThan(100),
      reason: 'Expanding a large folder must not build every track at once',
    );
    debugPrint(
      'large_folder_expand '
      'firstRowsMs=${expansionStopwatch.elapsedMilliseconds} '
      'builtRows=${builtRows.evaluate().length} totalRows=${tracks.length}',
    );

    await tester.scrollUntilVisible(
      find.text('Lazy track 1999', findRichText: true),
      600,
      scrollable: find
          .descendant(
            of: find.byKey(const PageStorageKey<String>('library_list')),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 400,
    );
    expect(find.text('Lazy track 1999', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large search results only build visible track rows', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const folderPath = '/library/search-large';
    final tracks = List<MusicTrack>.generate(
      2000,
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
    expect(find.text('Search track 1999', findRichText: true), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Search track 1999', findRichText: true),
      600,
      scrollable: find
          .descendant(
            of: find.byKey(
              const ValueKey<String>('library_search_results_all'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 400,
    );
    expect(find.text('Search track 1999', findRichText: true), findsOneWidget);
  });

  testWidgets('library search exposes retry and recovers after tree failure', (
    WidgetTester tester,
  ) async {
    var attempts = 0;
    var shouldFail = true;
    final fixture = AppRuntimeWidgetTestFixture(
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

  testWidgets(
    'removing a folder audio keeps the folder expanded and shows context',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final runtimeGraph = fixture.runtimeGraph;
      const folderPath = '/library/remove-folder-audio';
      final removedTrack = testMusicTrack(
        name: 'Remove this track',
        path: '$folderPath/remove.mp3',
        groupKey: folderPath,
        groupTitle: 'Remove folder audio',
      );
      final retainedTrack = testMusicTrack(
        name: 'Keep this track',
        path: '$folderPath/keep.mp3',
        groupKey: folderPath,
        groupTitle: 'Remove folder audio',
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

      final folderTile = find.byType(ExpansionTile).first;
      await tester.ensureVisible(folderTile);
      await tester.tap(folderTile);
      await pumpUntilFound(
        tester,
        find.text('Remove this track', findRichText: true),
      );
      final trackCard = find.ancestor(
        of: find.text('Remove this track', findRichText: true),
        matching: find.byType(SwipeRevealCard),
      );
      tester.widget<SwipeRevealCard>(trackCard.first).onRemove();

      final removedTrackFinder = find.text(
        'Remove this track',
        findRichText: true,
      );
      final retainedTrackFinder = find.text(
        'Keep this track',
        findRichText: true,
      );
      var removalCompleted = false;
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          retainedTrackFinder,
          findsOneWidget,
          reason: 'The expanded folder should not blank while refreshing',
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

      await pumpUntilFound(tester, find.text('已移除文件夹下该音频'));

      expect(find.text('Keep this track', findRichText: true), findsOneWidget);
      expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile).first)
            .controller!
            .isExpanded,
        isTrue,
      );
    },
  );

  testWidgets(
    'excluding a library audio keeps the folder expanded while refreshing',
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
      );
      final retainedTrack = testMusicTrack(
        name: 'Retain this track',
        path: '$libraryPath/retain.mp3',
        groupKey: libraryPath,
        groupTitle: 'Recoverable audio',
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

      final folderTile = find.byType(ExpansionTile).first;
      await tester.ensureVisible(folderTile);
      await tester.tap(folderTile);
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
          reason: 'Recoverable exclusion should not blank the open folder',
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
        find.text(fixture.languageProvider.tr('audio_excluded')),
      );
      expect(
        runtimeGraph.library.excludedTracksForLibrary(libraryPath),
        <String>[PathMatcher.normalize(removedTrack.path)],
      );
      expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile).first)
            .controller!
            .isExpanded,
        isTrue,
      );
    },
  );

  testWidgets('switching library categories collapses the element selector', (
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
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(
      () => runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(workPath),
        ).copyWith(
          tags: const <String>['sleep'],
          voiceActors: const <String>['Voice Actor'],
        ),
      ),
    );

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_search_button')),
    );
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
    await tester.tap(expandButton);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'app_search_category_AudioLibraryCategoryType.voiceActors',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('展开'), findsOneWidget);
    expect(find.text('收起'), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey<String>(
          'app_search_category_AudioLibraryCategoryType.tags',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('展开'), findsOneWidget);
    expect(find.text('收起'), findsNothing);
    expect(find.text(tagsLabel), findsOneWidget);
    expect(find.text(voiceActorsLabel), findsOneWidget);
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
    final swipeCard = find.descendant(
      of: entryCard,
      matching: find.byType(SwipeRevealCard),
    );
    tester.widget<SwipeRevealCard>(swipeCard).onRemove();

    await pumpUntilFound(
      tester,
      find.text(fixture.languageProvider.tr('audio_excluded')),
    );
    await pumpUntilNotFound(
      tester,
      find.text('Tagged library audio', findRichText: true),
    );
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
      findsNWidgets(2),
    );
    await settingsRepository.setUiBlurEffectEnabled(false);
    await tester.pump();
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
    final searchResultExpansionTiles = find.descendant(
      of: find.byKey(const ValueKey<String>('library_search_results_all')),
      matching: find.byType(ExpansionTile),
    );
    expect(searchResultExpansionTiles, findsOneWidget);
    final searchHeroMode = tester.widget<HeroMode>(
      find.byKey(const ValueKey<String>('library_search_hero_mode')),
    );
    expect(searchHeroMode.enabled, isFalse);
    expect(
      tester
          .widget<ExpansionTile>(searchResultExpansionTiles)
          .initiallyExpanded,
      isFalse,
    );
    expect(
      tester.getTopLeft(searchResultExpansionTiles).dy,
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
    expect(
      find.descendant(
        of: searchContentTransition,
        matching: find.byType(FadeTransition),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: searchContentTransition,
        matching: find.byType(LibraryLikeSkeletonCard),
      ),
      findsWidgets,
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.descendant(
        of: searchContentTransition,
        matching: find.byType(LibraryLikeSkeletonCard),
      ),
      findsWidgets,
    );
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

  testWidgets('library more menu opens formal library management only', (
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
    expect(
      find.byTooltip(languageProvider.tr('edit_library')),
      findsOneWidget,
    );
    expect(
      find.byTooltip(languageProvider.tr('batch_metadata')),
      findsOneWidget,
    );
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
        .descendant(of: rootFolderTile, matching: find.byType(ListTile))
        .first;
    final rootFolderHeaderHeight = tester.getSize(rootFolderHeader).height;
    final rootFolderCard = find.ancestor(
      of: rootFolderTile,
      matching: find.byType(Card),
    );
    expect(rootFolderCard, findsOneWidget);
    expect(
      ListTileTheme.of(tester.element(rootFolderHeader)).shape,
      tester.widget<Card>(rootFolderCard).shape,
    );
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
    expect(find.text(languageProvider.tr('restore')), findsOneWidget);
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
        .descendant(of: childFolderTile, matching: find.byType(ListTile))
        .first;
    final childFolderHeaderHeight = tester.getSize(childFolderHeader).height;
    expect(childFolderHeaderHeight, lessThan(rootFolderHeaderHeight));
    expect(childFolderHeaderHeight, closeTo(48, 0.001));
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
        matching: find.byType(ListTile),
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
      expect(tester.widget<ListTile>(tileFinder).isThreeLine, isNot(isTrue));
      expect(tester.widget<ListTile>(tileFinder).subtitle, isNull);
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
    await tester.pump(const Duration(milliseconds: 350));
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
}
