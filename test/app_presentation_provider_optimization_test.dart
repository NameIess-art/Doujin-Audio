import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets(
    'scan progress and unrelated details do not re-sort the library',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.settingsRepository.syncSlice(isInitialized: true);
      fixture.library
        ..addWatchedFolder('/music/beta', notify: false)
        ..addWatchedFolder('/music/alpha', notify: false);
      fixture.library.addTracks(
        [
          testMusicTrack(
            name: 'Beta',
            path: '/music/beta.mp3',
            groupKey: '/music/beta',
            groupTitle: 'Beta',
            isSingle: true,
          ),
          testMusicTrack(
            name: 'Alpha',
            path: '/music/alpha.mp3',
            groupKey: '/music/alpha',
            groupTitle: 'Alpha',
            isSingle: true,
          ),
        ],
        notify: false,
        persist: false,
      );
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      await tester.runAsync(fixture.library.ensureCardSnapshot);

      List<LibraryNode>? sorted;
      await tester.pumpWidget(
        fixture.build(
          Consumer(
            builder: (context, ref, child) {
              sorted = ref.watch(librarySortedTreeUiProvider);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initial = sorted;
      expect(initial, hasLength(2));

      fixture.libraryService
        ..isScanning = true
        ..scanProcessed = 1
        ..syncSlice(
          isInitialized: true,
          detailRevision: 0,
          treeSnapshotRevision:
              fixture.library.snapshotCacheService.cardSnapshotRevision,
        );
      await tester.pump();
      await tester.pump();
      expect(identical(sorted, initial), isTrue);

      fixture.libraryService.syncSlice(
        isInitialized: true,
        detailRevision: 1,
        treeSnapshotRevision:
            fixture.library.snapshotCacheService.cardSnapshotRevision,
      );
      await tester.pump();
      await tester.pump();
      expect(identical(sorted, initial), isTrue);

      fixture.settingsRepository
        ..librarySortCriterion = LibrarySortCriterion.voiceActor
        ..syncSlice(isInitialized: true);
      await tester.pump();
      await tester.pump();
      final detailSorted = sorted;
      expect(identical(detailSorted, initial), isFalse);

      fixture.libraryService.syncSlice(
        isInitialized: true,
        detailRevision: 2,
        treeSnapshotRevision:
            fixture.library.snapshotCacheService.cardSnapshotRevision,
      );
      await tester.pump();
      await tester.pump();
      expect(identical(sorted, detailSorted), isFalse);
    },
  );

  testWidgets('playlist detail revision affects only detail-based sorting', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    fixture.settingsRepository.syncSlice(isInitialized: true);
    final tracks = [
      testMusicTrack(
        name: 'Beta',
        path: '/music/beta.mp3',
        groupKey: '/music/beta',
        groupTitle: 'Beta',
      ),
      testMusicTrack(
        name: 'Alpha',
        path: '/music/alpha.mp3',
        groupKey: '/music/alpha',
        groupTitle: 'Alpha',
      ),
    ];
    fixture.library.addTracks(tracks, notify: false, persist: false);
    final sessions = [
      for (final track in tracks) fixture.playback.createTrackSession(track),
    ];
    for (final session in sessions) {
      addTearDown(session.shutdown);
    }
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    fixture.playbackService.syncSlice(
      activeSessions: sessions,
      playingSessionCount: 0,
      focusedSessionId: sessions.first.id,
      coverGeneration: 0,
      isInitialized: true,
    );

    Object? sorted;
    await tester.pumpWidget(
      fixture.build(
        Consumer(
          builder: (context, ref, child) {
            sorted = ref.watch(playlistSortedEntriesUiProvider);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initial = sorted;
    expect(initial, hasLength(2));

    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 1);
    await tester.pump();
    await tester.pump();
    expect(identical(sorted, initial), isTrue);

    fixture.settingsRepository
      ..playlistSortCriterion = PlaylistSortCriterion.voiceActor
      ..syncSlice(isInitialized: true);
    await tester.pump();
    await tester.pump();
    final detailSorted = sorted;
    expect(identical(detailSorted, initial), isFalse);

    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 2);
    await tester.pump();
    await tester.pump();
    expect(identical(sorted, detailSorted), isFalse);
  });
}
