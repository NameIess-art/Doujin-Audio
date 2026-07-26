import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/features/library/presentation/library_tab.dart';
import 'package:nameless_audio/core/widgets/app_transitions.dart';
import 'package:nameless_audio/core/widgets/async_cover_image.dart';
import 'package:nameless_audio/core/widgets/library_like_cards.dart';
import 'package:nameless_audio/core/widgets/top_page_header.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/features/library/application/library_entry_editor_service.dart';
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
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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
    expect(skeletonCards, findsNWidgets(5));
    expect(tester.getSize(skeletonCards.first).height, 158);
    expect(find.byType(PlaceholderContentTransition), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
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

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();

    await pumpUntilFound(
      tester,
      find.text('Partially loaded work', findRichText: true),
    );

    expect(runtimeGraph.library.categorySnapshot, isNotNull);
    await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
    expect(find.byType(LibraryLikeSkeletonCard), findsNothing);
    expect(runtimeGraph.library.state.isScanning, isTrue);

    runtimeGraph.library.finishScan(scanGeneration);
    await tester.pump();

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
    await pumpUntilLibraryTreeReady(
      tester,
      runtimeGraph.library,
      waitForCategorySnapshot: true,
    );
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

  testWidgets('library tab search submits asynchronously and removes misses', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      buildAppRuntimeTestApp(
        runtimeGraph: runtimeGraph,
        audioDatabaseRepository: audioDatabaseRepository,
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
    expect(find.byType(TextField), findsOneWidget);

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

    await tester.enterText(find.byType(TextField), 'ocean');
    await tester.pump(const Duration(milliseconds: 250));
    await pumpUntilFound(tester, find.text('Ocean Waves', findRichText: true));
    await pumpUntilNotFound(tester, find.text('Soft Rain', findRichText: true));

    expect(find.text('Soft Rain', findRichText: true), findsNothing);
    expect(find.text('Ocean Waves', findRichText: true), findsOneWidget);
    expect(
      runtimeGraph.library.snapshotCacheService.treeSnapshotRevision,
      libraryService.structureRevision,
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
      final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
          audioDatabaseRepository: audioDatabaseRepository,
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

      await tester.enterText(find.byType(TextField), 'forest');
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
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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

    expect(find.byTooltip(languageProvider.tr('more_actions')), findsOneWidget);
    expect(find.byTooltip(languageProvider.tr('import_audio')), findsOneWidget);
    expect(find.byTooltip(languageProvider.tr('edit_library')), findsNothing);
    await tester.tap(find.byTooltip(languageProvider.tr('more_actions')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(languageProvider.tr('edit_library')), findsOneWidget);
    expect(find.text(languageProvider.tr('batch_metadata')), findsOneWidget);
    expect(
      find.text(languageProvider.tr('fixed_card_positions')),
      findsOneWidget,
    );
    await tester.tap(find.text(languageProvider.tr('edit_library')));
    await tester.pumpAndSettle();

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
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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

  testWidgets('library edit ignores stale scans and preserves tree on failure', (
    WidgetTester tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    const libraryRoot = '/library';
    final first = Completer<LibraryEntryDiskSnapshot>();
    final second = Completer<LibraryEntryDiskSnapshot>();
    final third = Completer<LibraryEntryDiskSnapshot>();
    final fourth = Completer<LibraryEntryDiskSnapshot>();
    final service = _QueuedEntryEditorService(<Future<LibraryEntryDiskSnapshot>>[
      first.future,
      second.future,
      third.future,
      fourth.future,
    ]);
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
  });

  testWidgets('library edit keeps excluded tracks compact on a narrow screen', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final runtimeGraph = fixture.runtimeGraph;
    final audioDatabaseRepository = fixture.audioDatabaseRepository;
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
        audioDatabaseRepository: audioDatabaseRepository,
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
}
