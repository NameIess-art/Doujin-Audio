import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'support/asmr_controller_test_fixture.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/core/immutable_collections.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/operation_feedback.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_coordinator.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets(
      'ASMR appended page fades once from its data commit, reduce motion $reduceMotion',
      (tester) async {
        final coordinator = UiInteractionCoordinator.instance;
        coordinator.resetForTest();
        addTearDown(coordinator.resetForTest);
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        tester.view.physicalSize = const Size(600, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        await fixture.languageProvider.setLanguage(AppLanguage.zh);
        final activeTab = ValueNotifier(0);
        addTearDown(activeTab.dispose);
        final oldWork = _work(id: 1, title: 'Loaded work');
        final controller = _LoadedTabAsmrController(createTestAsmrServices(), [
          oldWork,
        ]);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          fixture.build(
            MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: AsmrTab(activeTabIndexListenable: activeTab),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('收藏'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(coordinator.idleDelay);
        await tester.pump();
        expect(coordinator.isInteracting, false);
        controller.hasMore = true;
        controller.updateFavorites([oldWork]);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();

        final footer = find.byKey(
          const ValueKey<String>('asmr_load_more_footer'),
        );
        final footerState = tester.state(footer);
        final oldCard = find.byKey(const ValueKey<String>('asmr-work-1'));
        final oldCardElement = tester.element(oldCard);
        final progress = find.byKey(
          const ValueKey<String>('asmr_load_more_progress'),
          skipOffstage: false,
        );
        double footerOpacity() => tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: progress,
                    matching: find.byType(FadeTransition, skipOffstage: false),
                  )
                  .first,
            )
            .opacity
            .value;
        expect(progress, findsOneWidget);
        expect(footerOpacity(), 1);
        final finalWork = _work(id: 0, title: 'Final pagination work');
        controller.hasMore = false;
        controller.updateFavorites([oldWork, finalWork]);
        await tester.pump();
        await tester.pump();
        expect(tester.state(footer), same(footerState));
        expect(tester.element(oldCard), same(oldCardElement));
        if (reduceMotion) {
          expect(progress, findsNothing);
        } else {
          expect(footerOpacity(), 1);
          await tester.pump(const Duration(milliseconds: 150));
          expect(
            footerOpacity(),
            closeTo(Curves.easeInOutCubic.transform(0.5), 0.01),
          );
          await tester.pump(const Duration(milliseconds: 150));
          expect(footerOpacity(), closeTo(0, 0.000001));
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump();
          expect(progress, findsNothing);
        }
        controller.hasMore = true;
        controller.updateFavorites([oldWork, finalWork]);
        await tester.pump();
        await tester.pump();

        double opacityFor(int id) => tester
            .widget<FadeTransition>(
              find.byKey(ValueKey<String>('asmr-work-$id')),
            )
            .opacity
            .value;

        final nextPage = [
          oldWork,
          finalWork,
          for (var id = 2; id <= 35; id++)
            _work(id: id, title: 'New page work $id'),
        ];
        controller.updateFavorites(nextPage);
        await tester.pump();
        await tester.pump();
        expect(opacityFor(1), 1);
        expect(opacityFor(2), reduceMotion ? 1 : 0);
        expect(tester.element(oldCard), same(oldCardElement));
        await tester.pump(const Duration(milliseconds: 150));
        expect(opacityFor(1), 1);
        expect(
          opacityFor(2),
          closeTo(
            reduceMotion ? 1 : Curves.easeInOutCubic.transform(0.5),
            0.01,
          ),
        );
        controller.updateFavorites([
          ...nextPage,
          _work(id: 36, title: 'Next batch work'),
        ]);
        await tester.pump();
        await tester.pump();
        expect(
          opacityFor(2),
          closeTo(
            reduceMotion ? 1 : Curves.easeInOutCubic.transform(0.5),
            0.01,
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        expect(opacityFor(2), 1);

        final list = tester.widget<ListView>(find.byType(ListView));
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pump();
        expect(opacityFor(35), 1);
        expect(
          opacityFor(36),
          closeTo(
            reduceMotion ? 1 : Curves.easeInOutCubic.transform(0.5),
            0.01,
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();
        expect(opacityFor(36), 1);
        list.controller!.jumpTo(0);
        await tester.pump();
        expect(opacityFor(2), 1);
        await tester.pump(const Duration(milliseconds: 400));
        activeTab.value = 1;
        await tester.pump();
        controller.updateFavorites([
          ...controller.favoriteWorks,
          _work(id: 37, title: 'Loaded while inactive'),
        ]);
        await tester.pump(const Duration(milliseconds: 400));
        activeTab.value = 0;
        await tester.pump();
        await tester.pump();
        expect(opacityFor(2), 1);
        final restoredList = tester.widget<ListView>(find.byType(ListView));
        restoredList.controller!.jumpTo(
          restoredList.controller!.position.maxScrollExtent,
        );
        await tester.pump();
        expect(opacityFor(37), 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'ASMR tab loads covers nearest the viewport focus before cached offscreen cards',
    (tester) async {
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      addTearDown(coordinator.resetForTest);
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = _RecordingTabCoverCache();
      final fixture = AppRuntimeWidgetTestFixture(
        coverArtworkCacheService: cache,
      );
      addTearDown(fixture.dispose);
      addTearDown(cache.releaseAll);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final controller = _LoadedTabAsmrController(createTestAsmrServices(), [
        for (var id = 1; id <= 30; id++)
          _work(
            id: id,
            title: 'Favorite $id',
            coverUrl: 'https://example.com/cover-$id.png',
          ),
      ]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      if (coordinator.isInteracting) {
        expect(cache.started, isEmpty);
      }
      await tester.pump(coordinator.idleDelay);
      await tester.pumpAndSettle();

      String nearestVisibleCover({Set<String> excluded = const {}}) {
        final viewport = tester.getRect(find.byType(ListView));
        final covers = find.byType(AsyncRemoteCoverImage).evaluate().where((
          element,
        ) {
          final widget = element.widget as AsyncRemoteCoverImage;
          return !excluded.contains(widget.url) &&
              tester.getRect(find.byWidget(widget)).overlaps(viewport);
        }).toList();
        covers.sort((left, right) {
          final leftRect = tester.getRect(find.byWidget(left.widget));
          final rightRect = tester.getRect(find.byWidget(right.widget));
          return (leftRect.center - viewport.center).distance.compareTo(
            (rightRect.center - viewport.center).distance,
          );
        });
        expect(covers, isNotEmpty);
        return (covers.first.widget as AsyncRemoteCoverImage).url;
      }

      final firstFocus = nearestVisibleCover();
      expect(
        firstFocus,
        isNot(
          tester
              .widget<AsyncRemoteCoverImage>(
                find.byType(AsyncRemoteCoverImage).first,
              )
              .url,
        ),
      );
      expect(cache.started, [firstFocus]);

      final list = tester.widget<ListView>(find.byType(ListView));
      list.controller!.jumpTo(600);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final nextFocus = nearestVisibleCover(excluded: {firstFocus});
      expect(nextFocus, isNot(firstFocus));
      cache.pending[firstFocus]!.complete(null);
      await tester.pump();
      await tester.pump();
      expect(cache.started, [firstFocus, nextFocus]);

      cache.releaseAll();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final resolution in CoverImageResolution.values) {
    testWidgets(
      'ASMR covers share one cache across all surfaces at ${resolution.name}',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize =
            defaultTargetPlatform == TargetPlatform.windows
            ? const Size(2560, 1600)
            : const Size(1000, 1800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(releaseRetainedCoverImages);
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('shared_asmr_cover_'),
        ))!;
        final cover = File(
          '${directory.path}${Platform.pathSeparator}cover.png',
        );
        await tester.runAsync(
          () => cover.writeAsBytes(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
              '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
          ),
        );
        addTearDown(() async {
          PaintingBinding.instance.imageCache
            ..clear()
            ..clearLiveImages();
          await directory.delete(recursive: true);
        });
        var downloads = 0;
        final cache = CoverArtworkCacheService(
          libraryService: LibraryService(),
          remoteCoverDownloader: (_) async {
            downloads++;
            return cover.path;
          },
        );
        final fixture = AppRuntimeWidgetTestFixture(
          coverArtworkCacheService: cache,
          configureSettingsRepository: (settings) {
            settings.coverImageResolution = resolution;
            settings.syncSlice();
          },
        );
        addTearDown(fixture.dispose);
        await fixture.languageProvider.setLanguage(AppLanguage.zh);
        const url = 'https://example.com/asmr-cover.png';
        final work = _work(coverUrl: ' $url ', mainCoverUrl: ' ');
        final controller = _LoadedTabAsmrController(createTestAsmrServices(), [
          work,
        ]);
        addTearDown(controller.dispose);
        await tester.runAsync(() => cache.futureForRemoteCover(url));

        Future<Object> imageKey(Finder surface) => tester
            .widget<RetryingImage>(
              find
                  .descendant(of: surface, matching: find.byType(RetryingImage))
                  .first,
            )
            .imageProviderBuilder()
            .obtainKey(ImageConfiguration.empty);

        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('收藏'));
        await tester.pumpAndSettle();
        final card = find.byType(AsyncRemoteCoverImage).first;
        expect(
          tester.widget<AsyncRemoteCoverImage>(card).initialPath,
          cover.path,
        );
        final sharedKey = await imageKey(card);
        expect(
          sharedKey,
          await resizeFileImageIfNeeded(
            path: cover.path,
            cacheWidth: coverCacheWidthForResolution(resolution),
            useDefaultCacheWidth: false,
          ).obtainKey(ImageConfiguration.empty),
        );

        unawaited(
          showAsmrWorkDetailSheet(tester.element(find.byType(AsmrTab)), work),
        );
        await tester.pumpAndSettle();
        final detail = find.descendant(
          of: find.byType(WorkDetailPage),
          matching: find.byType(AsyncRemoteCoverImage),
        );
        expect(detail, findsOneWidget);
        expect(
          tester.widget<AsyncRemoteCoverImage>(detail).initialPath,
          cover.path,
        );
        expect(await imageKey(detail), sharedKey);
        Navigator.of(tester.element(find.byType(WorkDetailPage))).pop();
        await tester.pumpAndSettle();

        final track =
            testMusicTrack(
              name: work.title,
              path: 'https://example.com/track.mp3',
              groupKey: 'asmr:${work.id}',
              groupTitle: work.title,
            ).copyWith(
              remoteCoverUrl: work.preferredCoverUrl,
              remoteMetadataKind: 'asmr.one',
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
        final playbackCover = fixture.runtimeGraph.library
            .playbackCoverPathFutureForTrack(track);
        var playbackCoverReady = false;
        unawaited(playbackCover.then((_) => playbackCoverReady = true));
        // Page lookups started in the fake clock zone. Deliver disk events in
        // runAsync, then pump their continuations before awaiting shared work.
        for (var tick = 0; tick < 100 && !playbackCoverReady; tick++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(playbackCoverReady, isTrue);
        expect(await playbackCover, cover.path);
        await tester.pumpWidget(
          fixture.build(
            const PlaylistTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final playlistCover = find.byType(AsyncLocalCoverImage).first;
        expect(
          tester.widget<AsyncLocalCoverImage>(playlistCover).initialPath,
          cover.path,
        );
        expect(await imageKey(playlistCover), sharedKey);
        unawaited(
          Navigator.of(
            tester.element(find.byType(PlaylistTab)),
          ).push(buildSessionDetailRoute(sessionId: session.id)),
        );
        await tester.pumpAndSettle();
        expect(
          await imageKey(find.byKey(ValueKey<String>('artwork_${session.id}'))),
          sharedKey,
        );
        expect(
          await imageKey(
            find.byKey(
              const ValueKey<String>('session_detail_background_blur'),
            ),
          ),
          sharedKey,
        );
        Navigator.of(
          tester.element(find.byKey(ValueKey<String>('artwork_${session.id}'))),
        ).pop();
        await tester.pumpAndSettle();

        await tester.pumpWidget(
          fixture.build(
            ActiveSessionCarousel(
              sessions: [PlaybackSessionSnapshot.fromRuntime(session)],
              onOpenSession: (_) {},
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        for (
          var tick = 0;
          tick < 100 &&
              PaintingBinding.instance.imageCache.pendingImageCount > 0;
          tick++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(PaintingBinding.instance.imageCache.pendingImageCount, 0);
        expect(
          await imageKey(find.byType(AsyncLocalCoverImage).first),
          sharedKey,
        );
        expect(downloads, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 6));
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'ASMR category switching keeps scroll offset and cached empty results',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final controller = _LoadedTabAsmrController(createTestAsmrServices(), [
        for (var id = 1; id <= 30; id++) _work(id: id, title: 'Favorite $id'),
      ]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      final originalList = tester.widget<ListView>(find.byType(ListView));
      final scrollController = originalList.controller!;
      scrollController.jumpTo(400);
      await tester.pump();
      await tester.tap(find.text('推荐'));
      await tester.pump();
      expect(find.byType(ListView), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsOneWidget);
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller,
        same(scrollController),
      );
      expect(scrollController.offset, closeTo(400, 1));
      expect(controller.refreshRequests, isEmpty);
    },
  );

  testWidgets('hidden ASMR tab waits until visible to refresh its language', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await fixture.languageProvider.setLanguage(AppLanguage.zh);
    final activeTab = ValueNotifier<int>(1);
    addTearDown(activeTab.dispose);
    final controller = _LoadedTabAsmrController(createTestAsmrServices(), []);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      fixture.build(
        AsmrTab(tabIndex: 2, activeTabIndexListenable: activeTab),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await fixture.languageProvider.setLanguage(AppLanguage.en);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.refreshRequests, isEmpty);
    expect(controller.pageLanguage, AppLanguage.zh);
    expect(controller.ensureLanguages, isEmpty);
    activeTab.value = 2;
    await tester.pumpAndSettle();
    expect(controller.pageLanguage, AppLanguage.en);
    expect(controller.refreshRequests, isEmpty);
    expect(controller.ensureLanguages, contains(AppLanguage.en));
  });

  testWidgets(
    'ASMR search reopens empty at the top without resetting the root',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final controller = _LoadedTabAsmrController(createTestAsmrServices(), [
        for (var id = 1; id <= 30; id++)
          _work(id: id, title: 'Shared work $id'),
      ]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      final rootScroll = tester
          .widget<ListView>(find.byType(ListView))
          .controller!;
      rootScroll.jumpTo(320);
      await tester.pump();
      final rootLoads = controller.ensureLanguages.length;
      await tester.tap(
        find.byKey(const ValueKey<String>('asmr_search_button')),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('asmr_search_favorites')),
          matching: find.text('Shared work 1'),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(controller.ensureLanguages, hasLength(rootLoads));
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      Future<void> query(String value) async {
        await tester.enterText(find.byType(TextField), value);
        await tester.pump(const Duration(milliseconds: 260));
        await tester.pumpAndSettle();
      }

      await query('shared');
      final searchScroll = tester
          .widget<ListView>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('asmr_search_favorites')),
              matching: find.byKey(
                const PageStorageKey(AsmrCategoryType.favorites),
              ),
            ),
          )
          .controller!;
      searchScroll.jumpTo(480);
      await tester.pump();
      await query('work');
      expect(searchScroll.offset, closeTo(0, 1));
      searchScroll.jumpTo(760);
      await tester.pump();
      await query('shared');
      expect(searchScroll.offset, closeTo(0, 1));
      await query('work');
      expect(searchScroll.offset, closeTo(0, 1));
      Navigator.of(tester.element(find.byType(TextField))).pop();
      await tester.pumpAndSettle();
      expect(rootScroll.offset, closeTo(320, 1));
      expect(controller.refreshRequests, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey<String>('asmr_search_button')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      final reopenedScroll = tester
          .widget<ListView>(
            find.descendant(
              of: find.byKey(const ValueKey<String>('asmr_search_favorites')),
              matching: find.byKey(
                const PageStorageKey(AsmrCategoryType.favorites),
              ),
            ),
          )
          .controller!;
      expect(reopenedScroll.offset, 0);
      expect(controller.ensureLanguages, hasLength(rootLoads));
    },
  );

  testWidgets(
    'Windows metadata copies with right click only',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAsmrWorkDetailSheet(context, _work()),
              child: const Text('Open detail'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open detail'));
      await tester.pumpAndSettle();
      final text = find.text('Test circle');
      await tester.ensureVisible(text);
      await tester.longPress(text);
      expect(copied, isEmpty);
      final click = await tester.startGesture(
        tester.getCenter(text),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.up();
      await tester.pumpAndSettle();
      expect(copied, ['Test circle']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('WorkDetailPage renders ASMR work detail header and actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAsmrWorkDetailSheet(context, _work()),
            child: const Text('Open detail'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('asmr_work_detail_download')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('asmr_work_detail_favorite')),
      findsOneWidget,
    );
    expect(find.text('Test work'), findsOneWidget);
    expect(find.text('RJ000123'), findsOneWidget);
    expect(find.text('Test circle'), findsOneWidget);
  });

  testWidgets('work metadata capsules copy their values on tap', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAsmrWorkDetailSheet(
              context,
              _work(
                voiceActors: const <String>['Voice A'],
                tags: const <String>['Tag A'],
              ),
            ),
            child: const Text('Open detail'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    final voiceActor = find.byKey(
      const ValueKey<String>('work_detail_voice_actor_Voice A'),
    );
    expect(voiceActor, findsOneWidget);
    final tag = find.byKey(const ValueKey<String>('work_detail_tag_#Tag A'));
    expect(tag, findsOneWidget);
    expect(tester.getSize(voiceActor).height, tester.getSize(tag).height);
    for (final key in <String>[
      'work_detail_voice_actor_edge_fade',
      'work_detail_tag_edge_fade',
    ]) {
      final fade = find.byKey(ValueKey<String>(key));
      expect(fade, findsOneWidget);
      final mask = tester.widget<ShaderMask>(fade);
      expect(mask.blendMode, BlendMode.dstIn);
      final shader = mask.shaderCallback(const Rect.fromLTWH(0, 0, 320, 28));
      expect(shader, isA<Shader>());
    }
    for (final key in <String>[
      'work_detail_voice_actor_edge_fade',
      'work_detail_tag_edge_fade',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
    }
    await tester.tap(voiceActor);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('work_detail_rj_copy')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('work_detail_circle_copy')),
    );
    await tester.pump();

    expect(copied, const <String>['Voice A', 'RJ000123', 'Test circle']);
  });

  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final count in <int>[100, 1000, 5000]) {
    testWidgets(
      'selection and updated rows stay visible for $count ASMR works',
      (tester) async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        await fixture.languageProvider.setLanguage(AppLanguage.zh);
        final controller = _TestFavoritesAsmrLibraryController(
          createTestAsmrServices(),
          const [],
        );
        controller.favoriteWorks = immutableList(
          List.generate(
            count,
            (index) => _work(id: index, title: 'Work $index'),
          ),
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('收藏'));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('Work 0'));
        await tester.pumpAndSettle();

        expect(find.text('已选择 1 项'), findsOneWidget);
        await tester.tap(find.text('Work 1'));
        await tester.pumpAndSettle();
        expect(find.text('已选择 2 项'), findsOneWidget);
        expect(find.text('Work 0'), findsOneWidget);
        expect(find.text('Work 1'), findsOneWidget);
        expect(find.text('Work ${count - 1}'), findsNothing);

        controller.updateFavorites(<AsmrWork>[
          _work(id: count, title: 'New work'),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('New work'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('detail download button opens the work download page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await fixture.languageProvider.setLanguage(AppLanguage.en);
    final work = _work();

    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAsmrWorkDetailSheet(context, work),
            child: const Text('Open detail'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open detail'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('asmr_work_detail_download')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AsmrDownloadPage), findsOneWidget);
    expect(find.byType(TopPageHeader), findsOneWidget);
    expect(find.byType(HeaderFloatingSurface), findsWidgets);
    expect(
      tester.widget<AsmrDownloadPage>(find.byType(AsmrDownloadPage)).work!.id,
      work.id,
    );
    expect(find.text('Work details'), findsNothing);
    expect(find.textContaining('/'), findsNothing);
  });

  testWidgets(
    'download page shows batch progress when multiple works are being downloaded',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final work = _work();

      await tester.pumpWidget(
        fixture.build(
          AsmrDownloadPage(work: work, batchIndex: 2, batchTotal: 5),
        ),
      );
      await tester.pump();

      expect(find.byType(AsmrDownloadPage), findsOneWidget);
      expect(find.text('2/5'), findsOneWidget);
    },
  );

  testWidgets('download skeletons fade out for 300ms as data arrives', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final workResult = Completer<AsmrWork?>();
    final trackTree = Completer<List<AsmrTrackFile>>();
    final controller = _TestFavoritesAsmrLibraryController(
      createTestAsmrServices(),
      const <AsmrWork>[],
    )..pendingTrackTree = trackTree.future;
    final downloads = AsmrDownloadManager(persistTasks: false);
    addTearDown(controller.dispose);
    addTearDown(downloads.dispose);

    await tester.pumpWidget(
      fixture.build(
        const AsmrDownloadPage(initialRjCode: 'RJ000123'),
        overrides: [
          asmrWorkFinderProvider.overrideWithValue(
            (_, {required language}) => workResult.future,
          ),
          asmrLibraryControllerProvider.overrideWithValue(controller),
          asmrDownloadManagerProvider.overrideWithValue(downloads),
        ],
      ),
    );
    await tester.pump();
    final summarySkeleton = find.byKey(
      const ValueKey<String>('asmr_download_summary_skeleton'),
    );
    expect(summarySkeleton, findsOneWidget);
    expect(find.byType(OperationSkeletonList), findsOneWidget);

    workResult.complete(_work());
    await tester.pump();
    await tester.pump();
    expect(summarySkeleton, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('asmr_download_summary')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(summarySkeleton, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 149));
    expect(summarySkeleton, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(summarySkeleton, findsNothing);

    trackTree.complete(const <AsmrTrackFile>[]);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<PlaceholderContentTransition>(
            find.byType(PlaceholderContentTransition),
          )
          .duration,
      kPlaceholderContentTransitionDuration,
    );
    expect(find.byType(OperationSkeletonList), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(OperationSkeletonList), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(OperationSkeletonList), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('asmr_download_file_list')),
      findsOneWidget,
    );
  });

  testWidgets(
    'detail sheet shows download and favorite buttons and allows undoing unfavorite',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);

      final work = _work();
      final controller = _TestFavoritesAsmrLibraryController(
        createTestAsmrServices(),
        <AsmrWork>[work],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAsmrWorkDetailSheet(context, work),
              child: const Text('Open detail'),
            ),
          ),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.tap(find.text('Open detail'));
      await tester.pumpAndSettle();

      final favoriteButtonFinder = find.byKey(
        const ValueKey<String>('asmr_work_detail_favorite'),
      );
      final downloadButtonFinder = find.byKey(
        const ValueKey<String>('asmr_work_detail_download'),
      );

      expect(favoriteButtonFinder, findsOneWidget);
      expect(downloadButtonFinder, findsOneWidget);

      final downloadRight = tester.getTopRight(downloadButtonFinder).dx;
      final favoriteLeft = tester.getTopLeft(favoriteButtonFinder).dx;
      expect(downloadRight, lessThanOrEqualTo(favoriteLeft));

      expect(controller.isFavorite(work.id), isTrue);

      await tester.tap(favoriteButtonFinder);
      await tester.pump();

      expect(controller.isFavorite(work.id), isFalse);

      expect(find.text('已取消收藏。'), findsOneWidget);
      final undoButtonFinder = find.text('撤销 (5s)');
      expect(undoButtonFinder, findsOneWidget);

      await tester.tap(undoButtonFinder);
      await tester.pump();

      expect(controller.isFavorite(work.id), isTrue);
    },
  );

  testWidgets('wide ASMR category lays cards out from left to right', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    await fixture.languageProvider.setLanguage(AppLanguage.zh);
    final controller = _TestFavoritesAsmrLibraryController(
      createTestAsmrServices(),
      <AsmrWork>[
        _work(id: 91, title: 'First wide ASMR work'),
        _work(id: 92, title: 'Second wide ASMR work'),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      fixture.build(
        const AsmrTab(),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();

    final first = find.byKey(const ValueKey<String>('asmr-work-91'));
    final second = find.byKey(const ValueKey<String>('asmr-work-92'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(
      tester.getTopLeft(first).dy,
      closeTo(tester.getTopLeft(second).dy, 1),
    );
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(second).dx));
  });

  testWidgets(
    'unfavoriting a work in favorites category animates card collapse and shifts items below upward',
    (WidgetTester tester) async {
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      addTearDown(coordinator.resetForTest);
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);

      final work1 = _work(id: 101, title: 'First Favorite Work');
      final work2 = _work(id: 102, title: 'Second Favorite Work');
      final controller = _TestFavoritesAsmrLibraryController(
        createTestAsmrServices(),
        <AsmrWork>[work1, work2],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.pump(coordinator.idleDelay);
      await tester.pumpAndSettle();

      expect(find.text('First Favorite Work'), findsOneWidget);
      expect(find.text('Second Favorite Work'), findsOneWidget);

      final work2InitialTop = tester
          .getTopLeft(find.text('Second Favorite Work'))
          .dy;

      controller.updateFavorites(<AsmrWork>[work2]);
      await tester.pump();

      expect(find.text('First Favorite Work'), findsOneWidget);
      expect(find.text('Second Favorite Work'), findsOneWidget);

      final sizeTransitionFinder = find.ancestor(
        of: find.byKey(const ValueKey<String>('asmr-work-101')),
        matching: find.byType(SizeTransition),
      );
      expect(sizeTransitionFinder, findsOneWidget);
      final sizeTransition = tester.widget<SizeTransition>(
        sizeTransitionFinder,
      );
      expect(sizeTransition.sizeFactor.value, 1.0);

      await tester.pump(const Duration(milliseconds: 130));
      expect(sizeTransition.sizeFactor.value, lessThan(1.0));
      expect(sizeTransition.sizeFactor.value, greaterThan(0.0));

      final work2MidTop = tester
          .getTopLeft(find.text('Second Favorite Work'))
          .dy;
      expect(work2MidTop, lessThan(work2InitialTop));

      await tester.pumpAndSettle();

      expect(find.text('First Favorite Work'), findsNothing);
      expect(find.text('Second Favorite Work'), findsOneWidget);

      final work2FinalTop = tester
          .getTopLeft(find.text('Second Favorite Work'))
          .dy;
      expect(work2FinalTop, lessThan(work2MidTop));
    },
  );

  testWidgets(
    'ASMR work card left-swipe reveals favorite and download actions and tapping opens WorkDetailPage',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);

      final work = _work(id: 201, title: 'Swipe Test Work');
      final controller = _TestFavoritesAsmrLibraryController(
        createTestAsmrServices(),
        <AsmrWork>[work],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();

      final card = find.byKey(const ValueKey<String>('asmr-work-201'));
      expect(card, findsOneWidget);
      final swipeCard = find.descendant(
        of: card,
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

      await tester.drag(card, const Offset(-180, 0));
      await tester.pumpAndSettle();

      // Swiping left reveals favorite and download actions
      expect(find.byTooltip('取消收藏'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      expect(find.byTooltip('查看作品详细信息'), findsNothing);
      expect(find.text('查看文档/文本'), findsNothing);
      expect(find.byIcon(Icons.description_outlined), findsNothing);

      // Close swipe by dragging right
      await tester.drag(card, const Offset(180, 0));
      await tester.pumpAndSettle();

      // Tapping card opens WorkDetailPage
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(WorkDetailPage), findsOneWidget);
      expect(find.text('Swipe Test Work'), findsOneWidget);
    },
  );

  for (final inSearch in <bool>[false, true]) {
    final page = inSearch ? 'search' : 'main';
    final keyPrefix = inSearch ? 'asmr_search' : 'asmr';

    testWidgets('$page batch add shows feedback and exits selection', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final work = _work(id: 301, title: 'Batch work');
      final controller = _BatchAsmrLibraryController(createTestAsmrServices(), [
        work,
      ]);
      addTearDown(controller.dispose);
      final coordinator = AsmrPlaybackCoordinator(
        source: controller,
        launcher: PlaybackFacadeSessionLauncher(fixture.playback),
      );
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
            asmrPlaybackCoordinatorProvider.overrideWithValue(coordinator),
          ],
        ),
      );
      await tester.pumpAndSettle();
      if (inSearch) {
        await tester.tap(
          find.byKey(const ValueKey<String>('asmr_search_button')),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Batch work'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey<String>('${keyPrefix}_batch_selection_header')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(ValueKey<String>('${keyPrefix}_batch_add_button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已添加 1 个作品至播放列表'), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('${keyPrefix}_batch_selection_header')),
        findsNothing,
      );
      expect(fixture.playback.sessions, hasLength(1));
    });

    testWidgets('$page batch unfavorite can be undone', (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await fixture.languageProvider.setLanguage(AppLanguage.zh);
      final work = _work(id: 302, title: 'Favorite batch work');
      final controller = _BatchAsmrLibraryController(createTestAsmrServices(), [
        work,
      ]);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pumpAndSettle();
      if (inSearch) {
        await tester.tap(
          find.byKey(const ValueKey<String>('asmr_search_button')),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Favorite batch work'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(ValueKey<String>('${keyPrefix}_batch_favorite_button')),
      );
      await tester.pumpAndSettle();
      expect(controller.favoriteWorks, isEmpty);
      expect(find.text('已取消收藏。'), findsOneWidget);
      await tester.tap(find.textContaining('撤销').first);
      await tester.pumpAndSettle();
      expect(controller.favoriteWorks.map((work) => work.id), contains(302));
    });
  }
}

class _TestFavoritesAsmrLibraryController extends AsmrLibraryController {
  _TestFavoritesAsmrLibraryController(
    TestAsmrServices services,
    List<AsmrWork> initialWorks,
  ) : favoriteWorks = List.of(initialWorks),
      super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  List<AsmrWork> favoriteWorks;
  Future<List<AsmrTrackFile>>? pendingTrackTree;
  int _revision = 0;
  bool hasMore = false;

  @override
  Future<List<AsmrTrackFile>> ensureTrackTree(
    AsmrWork work, {
    bool forceRefresh = false,
  }) =>
      pendingTrackTree ??
      super.ensureTrackTree(work, forceRefresh: forceRefresh);

  void updateFavorites(List<AsmrWork> next) {
    favoriteWorks = List.of(next);
    _revision++;
    notifyListeners();
  }

  @override
  bool isFavorite(int workId) => favoriteWorks.any((w) => w.id == workId);

  @override
  Future<void> toggleFavorite(AsmrWork work) async {
    final contains = favoriteWorks.any((w) => w.id == work.id);
    if (contains) {
      favoriteWorks.removeWhere((w) => w.id == work.id);
    } else {
      favoriteWorks.add(work.copyWith(isFavorite: true));
    }
    _revision++;
    notifyListeners();
  }

  @override
  Future<AsmrWorkDetail> loadWorkDetail(AsmrWork work) async {
    return AsmrWorkDetail(
      work: work,
      description: 'Test description',
      ageCategory: 'general',
      languageEditionLabels: const <String>[],
      userRating: null,
    );
  }

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}
  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {}

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}

  @override
  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: _revision,
  );

  @override
  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      category == AsmrCategoryType.favorites
      ? favoriteWorks
      : const <AsmrWork>[];

  @override
  List<AsmrWork> filteredWorksFor(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => categoryViewState(
    category,
    searchQuery: searchQuery,
    searchSession: searchSession,
  ).works;

  @override
  int totalCountFor(AsmrCategoryType category) => worksFor(category).length;

  @override
  String activeQueryFor(AsmrCategoryType category) => '';

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) {
    final works = worksFor(category);
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: false,
      isLoadingMore: false,
      isRefreshing: false,
      isStale: false,
      hasAttemptedLoad: true,
      hasMore: hasMore,
      needsLoadMoreRetry: false,
      totalCount: works.length,
      activeQuery: searchQuery,
      lastError: null,
      operationError: null,
      revision: _revision,
    );
  }
}

class _RecordingTabCoverCache extends CoverArtworkCacheService {
  _RecordingTabCoverCache() : super(libraryService: LibraryService());

  final started = <String>[];
  final pending = <String, Completer<String?>>{};
  bool _released = false;

  @override
  Future<String?> futureForRemoteCover(String url) {
    if (_released) return Future<String?>.value();
    started.add(url);
    return (pending[url] = Completer<String?>()).future;
  }

  void releaseAll() {
    _released = true;
    for (final completer in pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
  }
}

class _LoadedTabAsmrController extends _TestFavoritesAsmrLibraryController {
  _LoadedTabAsmrController(super.services, super.initialWorks);

  final refreshRequests = <AsmrCategoryType>[];
  final ensureLanguages = <AppLanguage>[];

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    ensureLanguages.add(pageLanguage);
  }

  @override
  bool get initialized => true;

  @override
  bool hasLoadedCategory(AsmrCategoryType category) => true;

  @override
  bool setPageLanguage(AppLanguage language) {
    final changed = pageLanguage != language;
    super.setPageLanguage(language);
    return changed;
  }

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {
    refreshRequests.add(category);
  }
}

class _BatchAsmrLibraryController extends _TestFavoritesAsmrLibraryController {
  _BatchAsmrLibraryController(super.services, super.initialWorks);

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) async => [
    testMusicTrack(
      name: work.title,
      path: '/asmr/${work.id}.mp3',
      groupKey: '/asmr/${work.id}',
      groupTitle: work.title,
    ),
  ];

  @override
  Future<void> recordHistory(AsmrWork work) async {}
}

AsmrWork _work({
  int id = 123,
  String title = 'Test work',
  List<String> voiceActors = const <String>[],
  List<String> tags = const <String>[],
  String coverUrl = '',
  String mainCoverUrl = '',
}) => AsmrWork(
  id: id,
  title: title,
  circleName: 'Test circle',
  sourceId: 'RJ000$id',
  sourceType: 'asmr',
  sourceUrl: '',
  coverUrl: coverUrl,
  thumbnailUrl: '',
  mainCoverUrl: mainCoverUrl,
  releaseDate: null,
  createDate: null,
  duration: Duration.zero,
  dlCount: 0,
  reviewCount: 0,
  rating: 0,
  voiceActors: voiceActors,
  tags: tags,
  isFavorite: true,
);
