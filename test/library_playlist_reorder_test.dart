import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/widgets/animated_reorder.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  AppRuntimeTestFixture.initialize();
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
              ..addTracks(tracks, notify: false, persist: false);
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
            final first = find.text('Audio 0', findRichText: true);
            final moved = find.text('Audio 2', findRichText: true);
            final firstY = tester.getTopLeft(first).dy;
            final before = tester.getTopLeft(moved).dy;
            expect(before, greaterThan(firstY));
            if (pin) {
              if (libraryPage) {
                await fixture.settingsRepository.toggleLibraryPathPinned(
                  tracks.last.path,
                );
              } else {
                await fixture.settingsRepository.togglePlaylistSessionPinned(
                  sessions.last.id,
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
            await tester.pump(kAppMotionSlow ~/ 2);
            final during = tester.getTopLeft(moved).dy;
            expect(during, lessThan(before));
            expect(during, greaterThan(firstY));
            await tester.pumpAndSettle();
            expect(tester.getTopLeft(moved).dy, closeTo(firstY, 0.01));
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
