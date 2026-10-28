import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/ui/warmup_scheduler.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:doujin_audio/features/library/presentation/library_cover_ui_controller.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_media_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets(
    'resizing admits cached rows without changing scroll offset',
    (tester) async {
      final cache = _RecordingCovers();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      final height = ValueNotifier<double>(300);
      final scroll = ScrollController();
      final futures = <int, Future<String?>>{};
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      addTearDown(height.dispose);
      addTearDown(scroll.dispose);
      final list = ScrollActivityGate(
        onMetricsChanged: covers.viewportChanged,
        child: ListView.builder(
          controller: scroll,
          itemExtent: 100,
          cacheExtent: 1000,
          itemCount: 20,
          itemBuilder: (_, index) => Builder(
            builder: (context) {
              futures[index] = covers.deferredRemoteCover(
                'https://cover/$index',
                context: context,
              );
              return const SizedBox(height: 100);
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
              valueListenable: height,
              child: list,
              builder: (_, value, child) =>
                  SizedBox(width: 300, height: value, child: child),
            ),
          ),
        ),
      );
      cache.release.complete();
      await tester.pump();
      await tester.pump();
      expect(cache.requests.toSet(), {'remote:0', 'remote:1', 'remote:2'});
      final pending = futures[5];
      expect(pending, isNotNull);
      height.value = 600;
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(scroll.offset, 0);
      expect(futures[5], same(pending));
      expect(cache.requests.toSet(), {for (var i = 0; i < 6; i++) 'remote:$i'});
      await tester.pumpWidget(const SizedBox.shrink());
      await covers.dispose();
      await Future.wait(futures.values);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'cold covers wait outside the viewport and start when scrolling exposes them',
    (tester) async {
      final cache = _RecordingCovers();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      final scroll = ScrollController();
      final futures = <int, Future<String?>>{};
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 300,
              child: ListView.builder(
                controller: scroll,
                itemExtent: 100,
                cacheExtent: 1000,
                itemCount: 20,
                itemBuilder: (_, index) => Builder(
                  builder: (context) {
                    futures[index] = covers.deferredRemoteCover(
                      'https://cover/$index',
                      context: context,
                    );
                    return const SizedBox(height: 100);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      cache.release.complete();
      await tester.pump();
      expect(futures.keys, contains(8));
      final pending = futures[8];
      expect(cache.requests.toSet(), {'remote:0', 'remote:1', 'remote:2'});
      scroll.jumpTo(600);
      await tester.pump();
      await tester.pump();
      expect(futures[8], same(pending));
      expect(cache.requests.toSet(), {
        'remote:0',
        'remote:1',
        'remote:2',
        'remote:6',
        'remote:7',
        'remote:8',
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await covers.dispose();
      await Future.wait(futures.values);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('paused cover discovery does not sort or submit new requests', (
    tester,
  ) async {
    final cache = _RecordingCovers(blockAll: true);
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: cache,
    );
    final scheduler = _CountingScheduler()..setPaused(true);
    final covers = LibraryCoverUiController(
      library: fixture.library,
      scheduler: scheduler,
    );
    addTearDown(fixture.dispose);
    addTearDown(covers.dispose);
    final futures = [
      for (var i = 0; i < 30; i++) covers.deferredFolderCover('/folder/$i'),
    ];
    await tester.pump();
    expect(scheduler.submissions, 0);
    expect(cache.requests, isEmpty);
    covers.setInteractionPaused(false);
    await tester.pump();
    expect(cache.requests, hasLength(1));
    cache.release.complete();
    await tester.pumpAndSettle();
    await Future.wait(futures);
    expect(cache.requests, hasLength(30));
  });

  testWidgets(
    'fast scrolling retires stale cover requests before I/O frees up',
    (tester) async {
      final cache = _RecordingCovers(blockAll: true);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(
        library: fixture.library,
        scheduler: WarmupScheduler(maxQueueSize: 2),
      );
      final scroll = ScrollController();
      final finished = <int>{};
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(
            child: ListView.builder(
              controller: scroll,
              itemExtent: 100,
              cacheExtent: 0,
              itemCount: 1000,
              itemBuilder: (context, index) => Builder(
                builder: (context) {
                  unawaited(
                    covers
                        .deferredFolderCover('/folder/$index', context: context)
                        .then((_) => finished.add(index)),
                  );
                  return const SizedBox(height: 100);
                },
              ),
            ),
          ),
        ),
      );
      final activeCount = cache.requests.length;
      expect(activeCount, 1);
      for (var i = 1; i <= 8; i++) {
        scroll.jumpTo(i * 3000);
        await tester.pump();
      }
      expect(
        finished.length,
        greaterThan(30),
        reason:
            'Offscreen requests must not accumulate behind slow artwork I/O.',
      );
      expect(cache.requests, hasLength(activeCount));
      await tester.pumpWidget(const SizedBox.shrink());
      cache.release.complete();
      await tester.pumpAndSettle();
      expect(cache.requests, hasLength(activeCount));
    },
  );

  testWidgets(
    'revisiting a queued cover reuses its request while artwork I/O is blocked',
    (tester) async {
      final cache = _RecordingCovers(blockAll: true);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(
        library: fixture.library,
        scheduler: WarmupScheduler(),
      );
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      final active = covers.deferredRemoteCover('https://cover/active');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!cache.release.isCompleted) cache.release.complete();
        await tester.pumpAndSettle();
      });
      await tester.pump();
      final futures = <String, Future<String?>>{};
      Widget page(String id) => MaterialApp(
        home: Builder(
          key: ValueKey(id),
          builder: (context) {
            futures[id] = covers.deferredRemoteCover(
              'https://cover/$id',
              context: context,
            );
            return const SizedBox.expand();
          },
        ),
      );

      await tester.pumpWidget(page('returning'));
      final returning = futures['returning']!;
      var completed = false;
      unawaited(returning.then((_) => completed = true));
      await tester.pumpWidget(page('other'));
      expect(cache.requests, ['remote:active']);
      // Dropping the queued request here leaves its key in the scheduler.
      // Revisiting it would then retry forever without yielding to I/O.
      expect(completed, isFalse);

      await tester.pumpWidget(page('returning'));
      expect(futures['returning'], same(returning));
      expect(cache.requests, ['remote:active']);
      cache.release.complete();
      await tester.pumpAndSettle();
      await Future.wait([active, ...futures.values]);
      expect(cache.requests, ['remote:active', 'remote:returning']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'single-track cover provider skips rows scrolled away while queued',
    (tester) async {
      final cache = _RecordingCovers(blockAll: true);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      final scroll = ScrollController();
      fixture.library.addTracks([
        for (var i = 0; i < 100; i++) _track(i),
      ], persist: false);
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        fixture.build(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 600,
              child: ListView.builder(
                controller: scroll,
                cacheExtent: 0,
                itemExtent: 100,
                itemCount: 100,
                itemBuilder: (_, index) => Consumer(
                  builder: (context, ref, _) {
                    final cover = ref.watch(
                      libraryCoverForTrackProvider((
                        trackPath: _track(index).path,
                        context: context,
                      )),
                    );
                    return SizedBox(
                      height: 100,
                      child: Text(cover.value ?? '$index'),
                    );
                  },
                ),
              ),
            ),
          ),
          overrides: [
            libraryCoverUiControllerProvider.overrideWithValue(covers),
          ],
        ),
      );
      final concurrent = defaultTargetPlatform == TargetPlatform.windows
          ? 4
          : 1;
      expect(cache.requests, hasLength(concurrent));
      scroll.jumpTo(3000);
      await tester.pump();
      expect(cache.requests, hasLength(concurrent));
      cache.release.complete();
      await tester.pumpAndSettle();
      final afterScroll = cache.requests.skip(concurrent).toList();
      expect(afterScroll, isNotEmpty);
      expect(
        afterScroll,
        everyElement(
          predicate<String>(
            (request) => int.parse(request.split(':').last) >= 30,
          ),
        ),
        reason: 'Disposed row providers must not keep cover discovery queued.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'playlist thumbnail discovery is bounded and skips rows removed while queued',
    (tester) async {
      final cache = _RecordingCovers(blockAll: true);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      await tester.pumpWidget(
        fixture.build(
          ListView(
            cacheExtent: 2000,
            children: [
              for (var i = 0; i < 30; i++)
                SessionCoverThumbnail(
                  sessionId: 'session-$i',
                  track: _track(i),
                  coverPath: null,
                  coverGeneration: 0,
                  coverCacheWidth: 64,
                ),
            ],
          ),
          overrides: [
            libraryCoverUiControllerProvider.overrideWithValue(covers),
          ],
        ),
      );
      final limit = defaultTargetPlatform == TargetPlatform.windows ? 4 : 1;
      expect(cache.requests, hasLength(limit));
      expect(cache.requests, everyElement(startsWith('playback:')));
      await tester.pumpWidget(const SizedBox.shrink());
      cache.release.complete();
      await tester.pumpAndSettle();
      // A fast fling can remove queued rows before their source lookup starts.
      expect(cache.requests, hasLength(limit));
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('warm playlist artwork bypasses a paused discovery queue', (
    tester,
  ) async {
    var downloads = 0;
    final service = LibraryService();
    final cache = CoverArtworkCacheService(
      libraryService: service,
      remoteCoverDownloader: (_) async {
        downloads++;
        return '/warm-playlist.png';
      },
    );
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: cache,
    );
    final covers = LibraryCoverUiController(library: fixture.library);
    addTearDown(service.dispose);
    addTearDown(fixture.dispose);
    addTearDown(covers.dispose);
    final track = MusicTrack(
      path: 'https://audio/track.mp3',
      displayName: 'Remote',
      groupKey: 'work',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
      remoteCoverUrl: 'https://cover/warm',
    );
    final first = covers.deferredPlaybackCover(track);
    expect(covers.deferredPlaybackCover(track), same(first));
    await tester.pump();
    expect(await first, '/warm-playlist.png');
    covers.setInteractionPaused(true);
    expect(await covers.deferredPlaybackCover(track), '/warm-playlist.png');
    expect(downloads, 1);
  });

  testWidgets(
    'Windows cover loading does not wait for a slow first download',
    (tester) async {
      final cache = _RecordingCovers(blockAll: true);
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      final futures = [
        for (var i = 0; i < 6; i++)
          covers.deferredRemoteCover('https://cover/$i'),
      ];
      expect(
        covers.deferredRemoteCover('https://cover/0'),
        same(futures.first),
      );
      await tester.pump();
      expect(
        cache.requests,
        hasLength(defaultTargetPlatform == TargetPlatform.windows ? 4 : 1),
      );
      cache.release.complete();
      await tester.pump();
      await Future.wait(futures);
      expect(cache.requests, hasLength(6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'known missing covers bypass paused queries when cards return',
    (tester) async {
      final service = LibraryService();
      final cache = CoverArtworkCacheService(
        libraryService: service,
        filesystemImageScanner: (_, _) async => [],
      );
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      addTearDown(service.dispose);
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      const folder = '/library/missing';
      await tester.runAsync(() => cache.futureForFolder(folder));
      covers.setInteractionPaused(true);
      await tester.pumpWidget(
        fixture.build(
          const LibraryCoverThumbnail(folderPath: folder),
          overrides: [
            libraryCoverUiControllerProvider.overrideWithValue(covers),
          ],
        ),
      );
      expect(find.byType(CoverLoadingArtwork), findsNothing);
      expect(find.byType(CoverFallbackArtwork), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        fixture.build(
          const LibraryCoverThumbnail(folderPath: folder),
          overrides: [
            libraryCoverUiControllerProvider.overrideWithValue(covers),
          ],
        ),
      );
      expect(find.byType(CoverLoadingArtwork), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'returning to a cached cover bypasses paused lookup and display queues',
    (tester) async {
      final interaction = UiInteractionCoordinator.instance;
      interaction.resetForTest();
      addTearDown(interaction.resetForTest);
      var downloads = 0;
      final service = LibraryService();
      final cache = CoverArtworkCacheService(
        libraryService: service,
        remoteCoverDownloader: (_) async {
          downloads++;
          return '/cached.png';
        },
      );
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final covers = LibraryCoverUiController(library: fixture.library);
      addTearDown(service.dispose);
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      const url = 'https://cover/cached';
      Widget page() => fixture.build(
        Builder(
          builder: (context) => AsyncCoverImage(
            future: covers.deferredRemoteCover(url, context: context),
            imageBuilder: (_, path) => Text(path),
            fallbackBuilder: (_) => const Text('fallback'),
            loadingBuilder: (_) => const Text('loading'),
          ),
        ),
        overrides: [libraryCoverUiControllerProvider.overrideWithValue(covers)],
      );

      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('/cached.png'), findsOneWidget);
      expect(downloads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      covers.setInteractionPaused(true);
      interaction.beginNavigation(Object());
      await tester.pumpWidget(page());
      expect(find.text('/cached.png'), findsOneWidget);
      expect(find.text('loading'), findsNothing);
      expect(downloads, 1);
      expect(interaction.pendingCommitCount, 0);

      // Invalidating the artwork must restore normal cold lookup scheduling.
      cache.invalidateAll();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(page());
      expect(find.text('/cached.png'), findsNothing);
      expect(find.text('loading'), findsOneWidget);
      expect(downloads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('resetting first-frame protection resumes queued cover queries', (
    tester,
  ) async {
    final interaction = UiInteractionCoordinator.instance;
    interaction.resetForTest();
    addTearDown(interaction.resetForTest);
    final cache = _RecordingCovers(result: '/reset.png');
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: cache,
    );
    final covers = LibraryCoverUiController(library: fixture.library);
    addTearDown(fixture.dispose);
    addTearDown(covers.dispose);
    interaction.beginInteraction(Object(), deferVisualUpdates: true);
    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => AsyncCoverImage(
            future: covers.deferredRemoteCover(
              'https://cover/reset',
              context: context,
            ),
            imageBuilder: (_, path) => Text(path),
            fallbackBuilder: (_) => const SizedBox(),
          ),
        ),
        overrides: [libraryCoverUiControllerProvider.overrideWithValue(covers)],
      ),
    );
    expect(cache.requests, isEmpty);
    expect(interaction.navigationAllowed.value, isTrue);
    interaction.resetForTest();
    await tester.pump();
    expect(interaction.isVisualUpdateDeferred, isFalse);
    expect(interaction.isInteracting, isFalse);
    expect(cache.requests, ['remote:reset']);
    cache.release.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('/reset.png'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      '$platform first-frame and navigation protection defer actual cover queries and commits',
      (tester) async {
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final cache = _RecordingCovers(result: '/cover.png');
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: cache,
        );
        final covers = LibraryCoverUiController(library: fixture.library);
        addTearDown(fixture.dispose);
        addTearDown(covers.dispose);
        final foreground = Object();
        final navigation = Object();
        final scroll = Object();
        interaction.beginInteraction(foreground, deferVisualUpdates: true);
        await tester.pumpWidget(
          fixture.build(
            Builder(
              builder: (context) => AsyncCoverImage(
                future: covers.deferredRemoteCover(
                  'https://cover/first',
                  context: context,
                ),
                imageBuilder: (_, path) => Text(path),
                fallbackBuilder: (_) => const Text('cached frame'),
              ),
            ),
            overrides: [
              libraryCoverUiControllerProvider.overrideWithValue(covers),
            ],
          ),
        );
        expect(cache.requests, isEmpty);
        expect(interaction.navigationAllowed.value, isTrue);
        interaction.beginInteraction(scroll);
        interaction.beginNavigation(navigation);
        interaction.endInteraction(foreground);
        await tester.pump(interaction.idleDelay);
        expect(cache.requests, isEmpty);
        interaction.cancelNavigation(navigation);
        await tester.pump();
        expect(cache.requests, ['remote:first']);
        // A query started before another restore can finish during its guard.
        interaction.beginInteraction(foreground, deferVisualUpdates: true);
        cache.release.complete();
        await tester.pump();
        expect(find.text('/cover.png'), findsNothing);
        interaction.endInteraction(foreground);
        await tester.pump(
          interaction.idleDelay - const Duration(milliseconds: 1),
        );
        expect(find.text('/cover.png'), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(find.text('/cover.png'), findsOneWidget);
        expect(interaction.isInteracting, isTrue);
        interaction.cancelInteraction(scroll);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );

    testWidgets(
      '$platform leaving a protected cover cancels its pending display result',
      (tester) async {
        final interaction = UiInteractionCoordinator.instance;
        interaction.resetForTest();
        addTearDown(interaction.resetForTest);
        final cache = _RecordingCovers(result: '/stale.png');
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: cache,
        );
        final covers = LibraryCoverUiController(library: fixture.library);
        addTearDown(fixture.dispose);
        addTearDown(covers.dispose);
        await tester.pumpWidget(
          fixture.build(
            AsyncCoverImage(
              future: covers.deferredRemoteCover('https://cover/removed'),
              imageBuilder: (_, path) => Text(path),
              fallbackBuilder: (_) => const SizedBox(),
            ),
            overrides: [
              libraryCoverUiControllerProvider.overrideWithValue(covers),
            ],
          ),
        );
        final foreground = Object();
        interaction.beginInteraction(foreground, deferVisualUpdates: true);
        cache.release.complete();
        await tester.pump();
        expect(interaction.pendingCommitCount, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        interaction.cancelInteraction(foreground);
        await tester.pump();
        expect(interaction.pendingCommitCount, 0);
        expect(find.text('/stale.png'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      '$platform loads the viewport center before cached rows',
      (tester) async {
        final cache = _RecordingCovers();
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: cache,
        );
        final scheduler = WarmupScheduler()..setPaused(true);
        final covers = LibraryCoverUiController(
          library: fixture.library,
          scheduler: scheduler,
        );
        final scroll = ScrollController(initialScrollOffset: 300);
        addTearDown(fixture.dispose);
        addTearDown(covers.dispose);
        addTearDown(scroll.dispose);
        final futures = <int, Future<String?>>{};
        final columns = platform == TargetPlatform.windows ? 3 : 1;

        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 300,
                child: ListView.builder(
                  controller: scroll,
                  cacheExtent: 500,
                  itemExtent: 100,
                  itemCount: 12,
                  itemBuilder: (_, row) => Row(
                    children: [
                      for (var column = 0; column < columns; column++)
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final index = row * columns + column;
                              futures[index] = covers.deferredRemoteCover(
                                'https://cover/$index',
                                context: context,
                              );
                              return const SizedBox(height: 100);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(cache.requests, isEmpty);
        covers.setInteractionPaused(false);
        await tester.pump();
        expect(cache.requests.first, 'remote:${4 * columns + columns ~/ 2}');
        cache.release.complete();
        await tester.pump();
        expect(cache.requests.take(3), everyElement(isNot('remote:0')));
        expect(
          cache.requests.toSet(),
          {
            for (var row = 3; row < 6; row++)
              for (var column = 0; column < columns; column++)
                'remote:${row * columns + column}',
          },
          reason: 'Cache-extent rows must not start artwork discovery.',
        );
        await covers.dispose();
        await Future.wait(futures.values);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'scrolling reprioritizes queued covers and displaced futures finish',
    (tester) async {
      final cache = _RecordingCovers();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      final scheduler = WarmupScheduler(maxQueueSize: 2);
      final covers = LibraryCoverUiController(
        library: fixture.library,
        scheduler: scheduler,
      );
      final scroll = ScrollController();
      final futures = <int, Future<String?>>{};
      addTearDown(fixture.dispose);
      addTearDown(covers.dispose);
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 300,
              child: ListView.builder(
                controller: scroll,
                cacheExtent: 500,
                itemExtent: 100,
                itemCount: 16,
                itemBuilder: (_, index) => Builder(
                  builder: (context) {
                    futures[index] = covers.deferredRemoteCover(
                      'https://cover/$index',
                      context: context,
                    );
                    return const SizedBox(height: 100);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(cache.requests, ['remote:1']);
      covers.setInteractionPaused(true);
      scroll.jumpTo(600);
      await tester.pump();
      expect(cache.requests, ['remote:1']);
      cache.release.complete();
      await tester.pump();
      expect(cache.requests, ['remote:1']);
      covers.setInteractionPaused(false);
      await tester.pump();
      expect(cache.requests[1], 'remote:7');
      expect(cache.requests.skip(1).toSet(), {
        'remote:6',
        'remote:7',
        'remote:8',
      });
      await covers.dispose();
      await Future.wait(futures.values);
      expect(scheduler.isIdle, true);
      expect(cache.requests.toSet(), hasLength(cache.requests.length));
    },
  );

  for (final trackCover in [false, true]) {
    testWidgets(
      '${trackCover ? 'track' : 'folder'} thumbnails pass viewport context',
      (tester) async {
        final cache = _RecordingCovers();
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: cache,
        );
        final covers = LibraryCoverUiController(library: fixture.library);
        addTearDown(fixture.dispose);
        addTearDown(covers.dispose);
        await tester.pumpWidget(
          fixture.build(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 300,
                child: ListView.builder(
                  cacheExtent: 500,
                  itemExtent: 100,
                  itemCount: 8,
                  itemBuilder: (_, index) => Align(
                    alignment: Alignment.topLeft,
                    child: trackCover
                        ? LibraryTrackCoverThumbnail(track: _track(index))
                        : LibraryCoverThumbnail(folderPath: '/folder/$index'),
                  ),
                ),
              ),
            ),
            overrides: [
              libraryCoverUiControllerProvider.overrideWithValue(covers),
            ],
          ),
        );
        expect(cache.requests.first, '${trackCover ? 'track' : 'folder'}:1');
        cache.release.complete();
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('unmounted queued request does not start cover I/O', (
    tester,
  ) async {
    final cache = _RecordingCovers();
    final fixture = AppRuntimeWidgetTestFixture(
      coverArtworkCacheService: cache,
    );
    final covers = LibraryCoverUiController(library: fixture.library);
    addTearDown(fixture.dispose);
    addTearDown(covers.dispose);
    final futures = <Future<String?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var i = 0; i < 2; i++)
              Builder(
                builder: (context) {
                  futures.add(
                    covers.deferredRemoteCover(
                      'https://cover/$i',
                      context: context,
                    ),
                  );
                  return const SizedBox(height: 100);
                },
              ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    cache.release.complete();
    await tester.pump();
    await Future.wait(futures);
    expect(cache.requests, hasLength(1));
  });

  for (final concurrency in [1, 4]) {
    testWidgets(
      'hidden queued covers wait and reuse their futures on return (concurrency=$concurrency)',
      (tester) async {
        final cache = _RecordingCovers(blockAll: true);
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: cache,
        );
        final scheduler = WarmupScheduler(maxConcurrent: concurrency);
        final covers = LibraryCoverUiController(
          library: fixture.library,
          scheduler: scheduler,
        );
        final visible = ValueNotifier<bool>(true);
        addTearDown(fixture.dispose);
        addTearDown(covers.dispose);
        addTearDown(visible.dispose);
        final futures = <Future<String?>>[];
        var queuedCompleted = false;
        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: Column(
                children: [
                  for (var i = 0; i < concurrency + 1; i++)
                    Builder(
                      builder: (context) {
                        futures.add(
                          covers.deferredRemoteCover(
                            'https://cover/$i',
                            context: context,
                          ),
                        );
                        return const SizedBox(height: 100);
                      },
                    ),
                ],
              ),
            ),
          ),
        );
        final activeRequests = [
          for (var i = 0; i < concurrency; i++) 'remote:$i',
        ];
        expect(cache.requests, activeRequests);
        unawaited(futures.last.then((_) => queuedCompleted = true));
        visible.value = false;
        await tester.pump();
        cache.release.complete();
        await tester.pump();
        expect(cache.requests, activeRequests);
        expect(queuedCompleted, isFalse);
        expect(scheduler.isIdle, isTrue);
        await scheduler.capacityAvailable;
        // Resuming interaction while hidden must not spin on queue capacity.
        covers.setInteractionPaused(false);
        await tester.pump();
        expect(cache.requests, activeRequests);
        visible.value = true;
        await tester.pump();
        covers.setInteractionPaused(false);
        await tester.pump();
        await Future.wait(futures);
        expect(cache.requests, [...activeRequests, 'remote:$concurrency']);
        expect(queuedCompleted, isTrue);
      },
    );
  }
}

MusicTrack _track(int index) => MusicTrack(
  path: '/track/$index',
  displayName: '$index',
  groupKey: '',
  groupTitle: '',
  groupSubtitle: '',
  isSingle: true,
);

class _CountingScheduler extends WarmupScheduler {
  int submissions = 0;

  @override
  bool schedule({
    required String key,
    required int priority,
    int Function()? priorityResolver,
    required int generation,
    void Function()? onDiscard,
    required Future<void> Function() task,
  }) {
    submissions++;
    return super.schedule(
      key: key,
      priority: priority,
      priorityResolver: priorityResolver,
      generation: generation,
      onDiscard: onDiscard,
      task: task,
    );
  }
}

class _RecordingCovers extends CoverArtworkCacheService {
  _RecordingCovers({this.result, this.blockAll = false})
    : super(libraryService: LibraryService());

  final String? result;
  final bool blockAll;

  final requests = <String>[];
  final release = Completer<void>();

  Future<String?> _record(String key) async {
    requests.add(key);
    if (blockAll || requests.length == 1) await release.future;
    return result;
  }

  @override
  Future<String?> futureForRemoteCover(String url) =>
      _record('remote:${url.split('/').last}');

  @override
  Future<String?> futureForFolder(String folderPath) =>
      _record('folder:${folderPath.split('/').last}');

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) =>
      _record('track:${(track?.path ?? trackPath!).split('/').last}');

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _record('playback:${(track?.path ?? trackPath!).split('/').last}');
}
