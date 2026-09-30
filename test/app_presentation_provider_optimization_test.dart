import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  testWidgets('global subtitles switch by target state and ignore parameters', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final sessions = [
      for (final name in ['A', 'B'])
        fixture.playback.createTrackSession(
          testMusicTrack(
            name: name,
            path: '/music/$name.mp3',
            groupKey: '/music',
            groupTitle: 'Music',
          ),
        ),
    ];
    for (final session in sessions) {
      addTearDown(session.shutdown);
    }
    sessions.first.setOptimisticState(playing: true);
    fixture.playback.publishSessionState(sessions.first.id);
    final subtitleSettings = SubtitleSettingsNotifier(
      loadState: () async => SubtitleSettingsState(
        globalSubtitlesMap: {for (final session in sessions) session.id: true},
      ),
    );
    String? selected;
    var builds = 0;
    await tester.pumpWidget(
      fixture.build(
        Consumer(
          builder: (context, ref, _) {
            selected = ref
                .watch(globalSubtitleOverlaySessionProvider)
                ?.session
                .id;
            builds++;
            return const SizedBox.shrink();
          },
        ),
        overrides: [
          subtitleSettingsProvider.overrideWith(() => subtitleSettings),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, sessions.first.id);
    final initialBuilds = builds;
    sessions.first.volume = 0.3;
    fixture.playback.publishSessionState(sessions.first.id);
    sessions.first.setOptimisticPosition(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(builds, initialBuilds);

    sessions.first.setOptimisticState(playing: false);
    sessions.last.setOptimisticState(playing: true);
    fixture.playback
      ..publishSessionState(sessions.first.id)
      ..publishSessionState(sessions.last.id);
    await tester.pumpAndSettle();
    expect(selected, sessions.last.id);
    expect(fixture.playback.aggregateState.playingSessionCount, 1);

    sessions.last.setOptimisticState(playing: false);
    fixture.playback.publishSessionState(sessions.last.id);
    await tester.pumpAndSettle();
    expect(selected, fixture.playback.catalogState.sessions.first.id);
  });

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
