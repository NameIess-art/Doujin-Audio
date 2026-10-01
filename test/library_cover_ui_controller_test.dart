import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/ui/warmup_scheduler.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/presentation/library_card_artwork.dart';
import 'package:doujin_audio/features/library/presentation/library_cover_ui_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
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
}

MusicTrack _track(int index) => MusicTrack(
  path: '/track/$index',
  displayName: '$index',
  groupKey: '',
  groupTitle: '',
  groupSubtitle: '',
  isSingle: true,
);

class _RecordingCovers extends CoverArtworkCacheService {
  _RecordingCovers() : super(libraryService: LibraryService());

  final requests = <String>[];
  final release = Completer<void>();

  Future<String?> _record(String key) async {
    requests.add(key);
    if (requests.length == 1) await release.future;
    return null;
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
}
