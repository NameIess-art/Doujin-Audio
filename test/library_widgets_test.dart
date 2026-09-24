import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
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
import 'package:doujin_audio/features/library/application/library_organizer.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

class _ReadCountingTrackNode extends TrackNode {
  _ReadCountingTrackNode(super.track);
  int reads = 0;

  @override
  MusicTrack get track {
    reads++;
    return super.track;
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
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
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

  testWidgets('library card and work detail share a decoded cover', (
    WidgetTester tester,
  ) async {
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
      await File(coverPath).writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
        '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ));
      fixture.runtimeGraph.library.addWatchedFolder(folder.path, notify: false);
      fixture.runtimeGraph.library.addTracks(
        [track],
        notify: false,
        persist: false,
      );
      await fixture.runtimeGraph.library.setFolderManualCover(
        folder.path,
        coverPath,
      );
    });
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(fixture.build(const LibraryTab()));
    await tester.pump();
    await pumpUntilLibraryTreeReady(tester, fixture.runtimeGraph.library);
    await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
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
    await tester.pump();
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
      findsNWidgets(3),
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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
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

      final childAddButtonFinder = find.descendant(
        of: childExpansionTileFinder,
        matching: find.byType(IconButton),
      );
      expect(childAddButtonFinder, findsOneWidget);
      final childIconButton = tester.widget<IconButton>(childAddButtonFinder);
      expect(
        childIconButton.tooltip,
        fixture.languageProvider.tr('add_to_playlist'),
      );
      final iconWidget = tester.widget<Icon>(
        find.descendant(of: childAddButtonFinder, matching: find.byType(Icon)),
      );
      expect(iconWidget.icon, Icons.add_circle_rounded);
      expect(iconWidget.size, 25.0);

      // Verify child folder is wrapped in SwipeRevealCard and swiping left reveals remove button
      final childFolderSwipeCardFinder = find.ancestor(
        of: discFolderFinder,
        matching: find.byType(SwipeRevealCard),
      );
      expect(childFolderSwipeCardFinder, findsOneWidget);

      final swipeCard = tester.widget<SwipeRevealCard>(
        childFolderSwipeCardFinder,
      );
      expect(swipeCard.actionLabel, fixture.languageProvider.tr('remove'));
      expect(
        swipeCard.removeTooltip,
        fixture.languageProvider.tr('remove_audio_folder'),
      );

      await tester.drag(discFolderFinder, const Offset(-200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

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

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
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
      expect(swipeCard.leadingActionIconWidget, isNull);
      expect(swipeCard.onSecondaryLeadingAction, isNull);
      expect(swipeCard.secondaryLeadingActionLabel, isNull);
      expect(swipeCard.onSecondaryAction, isNotNull);
      expect(
        swipeCard.secondaryActionLabel,
        fixture.languageProvider.tr('download'),
      );
      expect(swipeCard.secondaryActionIcon, Icons.download_rounded);

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
      expect(pinPosition.right, 4);
      expect(pinPosition.top, 4);
      expect(pinPosition.left, isNull);

      // Swipe card now shows unpin
      final updatedSwipeCard = tester.widget<SwipeRevealCard>(swipeCardFinder);
      expect(
        updatedSwipeCard.leadingActionLabel,
        fixture.languageProvider.tr('unpin_from_top'),
      );
      expect(updatedSwipeCard.leadingActionIconWidget, isA<PushPinOffIcon>());

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    },
  );

  testWidgets(
    'root folder card left-swipe download action finds ASMR work and navigates to AsmrDownloadPage',
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
            asmrWorkFinderOverrideProvider.overrideWithValue(
              (rjCode) =>
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

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    },
  );

  testWidgets(
    'single track without cover shows pin in leading indicator and checkmark at bottom-left when selected',
    (WidgetTester tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
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
      );
      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
          singleTrack,
        ], persist: false)
        ..addTracks(<MusicTrack>[singleTrack], notify: false, persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

      // Pre-pin the single track
      await fixture.settings.toggleLibraryPathPinned(singleTrack.path);

      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await tester.pump();
      await pumpUntilLibraryTreeReady(tester, runtimeGraph.library);
      await pumpUntilNotFound(tester, find.byType(LibraryLikeSkeletonCard));
      await tester.pump(const Duration(milliseconds: 350));

      // Pin indicator should be inside _LibraryLeadingIndicators
      final pinBadge = find.byKey(
        ValueKey<String>(
          'library_pinned_${PathMatcher.normalize(singleTrack.path)}',
        ),
      );
      expect(pinBadge, findsOneWidget);

      // Long press on single track to enter multi-select
      final trackFinder = find.text('single.mp3', findRichText: true);
      await tester.longPress(trackFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Selection checkmark should be displayed
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    },
  );

  testWidgets(
    'single track without cover added to playlist is not highlighted',
    (WidgetTester tester) async {
      var prepareCalls = 0;
      Map<String, Object?>? preparedSnapshot;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(nativePlaybackChannel, (call) async {
        if (call.method == NativePlaybackMethod.prepareSession) {
          prepareCalls++;
          final arguments = call.arguments as Map<Object?, Object?>;
          preparedSnapshot = <String, Object?>{
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
          return <String, Object?>{'ok': true, 'value': preparedSnapshot};
        }
        if (call.method == NativePlaybackMethod.play) {
          final arguments = call.arguments as Map<Object?, Object?>;
          return <String, Object?>{
            'ok': true,
            'value': <String, Object?>{
              ...preparedSnapshot!,
              'playing': true,
              'playWhenReady': true,
              'transportCommandId': arguments['transportCommandId'],
            },
          };
        }
        return <String, Object?>{'ok': true, 'value': null};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(nativePlaybackChannel, null),
      );
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

      final addButton = find.byIcon(Icons.add_circle_rounded);
      expect(addButton, findsOneWidget);
      await tester.tap(addButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final cardFinder = find.ancestor(
        of: find.text('single.mp3', findRichText: true),
        matching: find.byType(Card),
      );
      final card = tester.widget<Card>(cardFinder.first);
      expect(card.color, Colors.transparent);
      expect(prepareCalls, 0);
      expect(
        PathMatcher.normalize(
          runtimeGraph.playback.activeSessions.single.currentTrackPath,
        ),
        PathMatcher.normalize(singleTrack.path),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    },
  );

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
      final swipeCard = find.ancestor(
        of: rootFolderFinder,
        matching: find.byType(SwipeRevealCard),
      );
      expect(swipeCard, findsOneWidget);
      // The card tap surface must live inside the swipe card surface. An
      // InkWell outside of it paints its highlight and ripple below the opaque
      // closed background, so presses looked different from playlist rows.
      expect(
        find.ancestor(of: swipeCard, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        find.descendant(of: swipeCard, matching: find.byType(InkWell)),
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
      await tester.pump(const Duration(milliseconds: 300));

      // Navigated to WorkDetailPage
      expect(find.byType(WorkDetailPage), findsOneWidget);
    },
  );
}
