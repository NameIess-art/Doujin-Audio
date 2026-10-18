import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/animated_reorder.dart';
import 'package:doujin_audio/features/library/presentation/library_tab_tree_widgets.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);
  late Database database;
  setUpAll(() async {
    database = await AppRuntimeTestFixture.installSharedDatabase();
  });
  tearDownAll(() => AppRuntimeTestFixture.disposeSharedDatabase(database));

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final libraryPage in [true, false]) {
      for (final pin in [true, false]) {
        testWidgets(
          '${platform.name} ${libraryPage ? 'library' : 'playlist'} animates ${pin ? 'pin' : 'playback time'} reorder',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = platform == TargetPlatform.windows
                ? const Size(1000, 800)
                : const Size(450, 950);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            final fixture = AppRuntimeWidgetTestFixture();
            addTearDown(fixture.dispose);
            final tracks = List.generate(
              3,
              (index) => testMusicTrack(
                name: 'Audio $index',
                path: PathMatcher.normalize(
                  '/library/reorder/Audio $index.mp3',
                ),
                groupKey: PathMatcher.normalize('/library/reorder'),
                groupTitle: 'Reorder',
                isSingle: true,
              ),
            );
            final library = fixture.runtimeGraph.library;
            library
              ..addWatchedLibrary('/library/reorder', notify: false)
              ..recordLibraryEntriesForTracks(
                '/library/reorder',
                tracks,
                persist: false,
              )
              ..addTracks(tracks, persist: false);
            fixture.libraryService.syncSlice(
              isInitialized: true,
              detailRevision: 0,
            );
            final sessions = [
              for (var i = 0; i < tracks.length; i++)
                PlaybackSession(
                  id: 'reorder-$i',
                  currentTrackPath: tracks[i].path,
                  loopMode: SessionLoopMode.folderSequential,
                  nonSingleLoopMode: SessionLoopMode.folderSequential,
                  volume: 1,
                  createdAt: DateTime(2026),
                  state: const PlayerState(false, ProcessingState.ready),
                ),
            ];
            for (final session in sessions) {
              fixture.playbackService.registerSession(session);
            }
            void publishSessions() => fixture.playbackService.syncSlice(
              activeSessions: sessions,
              playingSessionCount: 0,
              focusedSessionId: sessions.first.id,
              coverGeneration: 0,
              isInitialized: true,
            );
            publishSessions();
            if (!pin) {
              await fixture.settingsRepository.setLibrarySortOptions(
                criterion: LibrarySortCriterion.playbackTime,
                ascending: true,
                groupByLibrary: false,
              );
              await fixture.settingsRepository.setPlaylistSortOptions(
                criterion: PlaylistSortCriterion.playbackTime,
                ascending: true,
                groupByLibrary: false,
              );
            }
            await tester.pumpWidget(
              fixture.build(
                libraryPage ? const LibraryTab() : const PlaylistTab(),
              ),
            );
            if (libraryPage) await pumpUntilLibraryTreeReady(tester, library);
            await tester.pumpAndSettle();
            await pumpUntilUiIdle(tester);
            final first = find.text('Audio 0', findRichText: true);
            final moved = find.text('Audio 2', findRichText: true);
            final firstY = tester.getTopLeft(first).dy;
            final before = tester.getTopLeft(moved).dy;
            expect(before, greaterThan(firstY));
            final pinBadge = find.descendant(
              of: find.byWidgetPredicate(
                (widget) => libraryPage
                    ? widget is LibraryPinnedIndicator &&
                          widget.path == tracks.last.path
                    : widget is PlaylistPinnedIndicator &&
                          widget.sessionId == sessions.last.id,
              ),
              matching: find.byIcon(Icons.push_pin_rounded),
            );
            if (pin) {
              if (platform == TargetPlatform.android) {
                await tester.drag(moved, const Offset(180, 0));
                await tester.pumpAndSettle();
                await tester.tap(
                  find.byTooltip(fixture.languageProvider.tr('pin_to_top')),
                );
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 110));
                expect(tester.getTopLeft(moved).dy, before);
                expect(pinBadge, findsNothing);
                expect(
                  libraryPage
                      ? fixture.settings.pinnedLibraryPaths
                      : fixture.settings.pinnedPlaylistSessionIds,
                  isEmpty,
                );
                await tester.pump(const Duration(milliseconds: 111));
              } else {
                await tester.tap(moved, buttons: 2);
                await tester.pumpAndSettle();
                await tester.tap(
                  find.text(fixture.languageProvider.tr('pin_to_top')),
                );
              }
            } else if (libraryPage) {
              library.addOrReplaceTracks(
                [tracks.last.copyWith(lastPlayedAt: DateTime(2026, 10, 5))],
                persist: false,
                mergeExistingState: false,
              );
              await tester.runAsync(() => library.ensureCardSnapshot());
            } else {
              sessions.last.lastPlayedAt = DateTime(2026, 10, 5);
              publishSessions();
            }
            final movedId = libraryPage
                ? PathMatcher.equivalenceKey(tracks.last.path)
                : sessions.last.id;
            for (var i = 0; i < 100; i++) {
              await tester.pump();
              if (tester
                      .widget<AnimatedReorder>(find.byType(AnimatedReorder))
                      .order
                      .first ==
                  movedId) {
                break;
              }
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
            }
            expect(
              tester
                  .widget<AnimatedReorder>(find.byType(AnimatedReorder))
                  .order
                  .first,
              movedId,
            );
            expect(tester.getTopLeft(moved).dy, closeTo(before, 0.01));
            if (pin) expect(pinBadge, findsNothing);
            await tester.pump(kAppMotionSlow ~/ 2);
            final during = tester.getTopLeft(moved).dy;
            expect(during, lessThan(before));
            expect(during, greaterThan(firstY));
            if (pin) expect(pinBadge, findsNothing);
            await tester.pump(kAppMotionSlow);
            expect(tester.getTopLeft(moved).dy, closeTo(firstY, 0.01));
            if (pin) {
              double pinOpacity() => tester
                  .widgetList<FadeTransition>(
                    find.ancestor(
                      of: pinBadge,
                      matching: find.byType(FadeTransition),
                    ),
                  )
                  .fold(1.0, (value, fade) => value * fade.opacity.value);
              expect(pinBadge, findsOneWidget);
              expect(pinOpacity(), 0);
              await tester.pump(kAppFadeDuration ~/ 2);
              expect(
                pinOpacity(),
                closeTo(kAppFadeCurve.transform(0.5), 0.001),
              );
              expect(tester.getTopLeft(moved).dy, closeTo(firstY, 0.01));
              await tester.pumpAndSettle();
              expect(pinOpacity(), 1);
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            var drained = false;
            final drain = library.detailCacheService
                .suspendAndWait()
                .then((_) => library.flushPendingPersistence())
                .then((_) => database.rawQuery('SELECT 1'))
                .then((_) => drained = true);
            for (var i = 0; i < 2000 && !drained; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 5)),
              );
              await tester.pump(const Duration(milliseconds: 5));
            }
            expect(drained, isTrue);
            await drain;
          },
          variant: TargetPlatformVariant({platform}),
        );
      }
    }
  }
}
