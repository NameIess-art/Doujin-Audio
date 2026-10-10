import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

class _WorkDetailRepository extends TestPersistenceRepository {
  final ready = Completer<void>();
  final details = <String, AudioDetail>{};
  int singleReads = 0;
  int batchReads = 0;

  @override
  Future<AudioDetail?> load(AudioDetailTarget target) async {
    singleReads++;
    await ready.future;
    return details[PathMatcher.normalize(target.targetPath)]?.copyWith(
      target: target,
    );
  }

  @override
  Future<List<AudioDetail>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async {
    batchReads++;
    await ready.future;
    return [
      for (final target in targets)
        if (details[PathMatcher.normalize(target.targetPath)]
            case final detail?)
          detail.copyWith(target: target),
    ];
  }
}

void main() {
  setUp(UiInteractionCoordinator.instance.resetForTest);
  tearDown(UiInteractionCoordinator.instance.resetForTest);
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

  testWidgets(
    'library name sort reacts to loaded titles and display settings',
    (tester) async {
      final repository = _WorkDetailRepository();
      addTearDown(() {
        if (!repository.ready.isCompleted) repository.ready.complete();
      });
      final fixture = AppRuntimeWidgetTestFixture(
        providedPersistenceRepository: repository,
      );
      addTearDown(fixture.dispose);
      fixture.settingsRepository.syncSlice(isInitialized: true);
      for (final (folder, title) in [('RJ100', 'Zulu'), ('RJ200', 'Alpha')]) {
        final root = '/music/$folder';
        repository.details[PathMatcher.normalize(root)] = AudioDetail.empty(
          AudioDetailTarget.libraryRootFolder(root),
        ).copyWith(workTitle: title);
        fixture.library.addWatchedFolder(root, notify: false);
        fixture.library.addTracks(
          [
            testMusicTrack(
              name: 'Track',
              path: '$root/track.mp3',
              groupKey: root,
              groupTitle: folder,
            ),
          ],
          notify: false,
          persist: false,
        );
      }
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      await tester.runAsync(fixture.library.ensureCardSnapshot);

      List<LibraryNode>? sorted;
      var builds = 0;
      await tester.pumpWidget(
        fixture.build(
          Consumer(
            builder: (context, ref, child) {
              sorted = ref.watch(librarySortedTreeUiProvider);
              builds++;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);
      expect(repository.singleReads, 0);
      expect(repository.batchReads, 0);

      final navigation = Object();
      final interaction = UiInteractionCoordinator.instance;
      interaction.beginNavigation(navigation);
      final beforeBatch = sorted;
      final buildsBeforeBatch = builds;
      final snapshot = fixture.library.audioLibraryCategorySnapshot();
      repository.ready.complete();
      await tester.runAsync(() => snapshot);
      await tester.pump();
      expect(identical(sorted, beforeBatch), isTrue);
      expect(builds, buildsBeforeBatch);
      interaction.endNavigation(navigation);
      await tester.pump(const Duration(milliseconds: 161));
      await tester.pumpAndSettle();
      expect(sorted!.map((node) => node.name), ['RJ200', 'RJ100']);
      expect(builds, buildsBeforeBatch + 1);
      expect(repository.batchReads, 1);

      fixture.settingsRepository
        ..workNameDisplay = WorkNameDisplay.folderName
        ..syncSlice(isInitialized: true);
      await tester.pumpAndSettle();
      expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);
      final folderSorted = sorted;
      fixture.library.detailCacheService.markChanged(
        repository.details[PathMatcher.normalize('/music/RJ100')]!.copyWith(
          workTitle: 'Aardvark',
        ),
      );
      fixture.library.syncPresentationState();
      await tester.pumpAndSettle();
      expect(identical(sorted, folderSorted), isTrue);

      fixture.settingsRepository
        ..workNameDisplay = WorkNameDisplay.workTitle
        ..syncSlice(isInitialized: true);
      await tester.pumpAndSettle();
      expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);

      fixture.library.detailCacheService.markChanged(
        repository.details[PathMatcher.normalize('/music/RJ100')]!.copyWith(
          workTitle: 'Zulu',
        ),
      );
      fixture.library.syncPresentationState();
      await tester.pumpAndSettle();
      expect(sorted!.map((node) => node.name), ['RJ200', 'RJ100']);

      // The shared category snapshot retains titles after detail cache eviction.
      fixture.library.detailCacheService.clear();
      fixture.settingsRepository
        ..librarySortAscending = false
        ..syncSlice(isInitialized: true);
      await tester.pumpAndSettle();
      expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);
    },
  );

  for (final disposeWhileHidden in [false, true]) {
    testWidgets(
      'library batches sorting details after idle and cancels '
      '${disposeWhileHidden ? 'disposed' : 'hidden'} preparation',
      (tester) async {
        final repository = _WorkDetailRepository()..ready.complete();
        final fixture = AppRuntimeWidgetTestFixture(
          providedPersistenceRepository: repository,
        );
        final active = ValueNotifier<int>(0);
        addTearDown(fixture.dispose);
        addTearDown(active.dispose);
        fixture.settingsRepository.syncSlice(isInitialized: true);
        for (var index = 0; index < 24; index++) {
          final folder = 'RJ${100 + index}';
          final root = '/music/$folder';
          repository.details[PathMatcher.normalize(root)] = AudioDetail.empty(
            AudioDetailTarget.libraryRootFolder(root),
          ).copyWith(workTitle: folder);
          fixture.library.addWatchedFolder(root, notify: false);
          fixture.library.addTracks(
            [
              testMusicTrack(
                name: 'Track',
                path: '$root/track.mp3',
                groupKey: root,
                groupTitle: folder,
              ),
            ],
            notify: false,
            persist: false,
          );
        }
        fixture.libraryService.syncSlice(
          isInitialized: true,
          detailRevision: 0,
        );
        await tester.runAsync(fixture.library.ensureCardSnapshot);
        final interaction = UiInteractionCoordinator.instance;
        final navigation = Object();
        interaction.beginNavigation(navigation);
        await tester.pumpWidget(
          fixture.build(
            ValueListenableBuilder<int>(
              valueListenable: active,
              child: LibraryTab(tabIndex: 0, activeTabIndexListenable: active),
              builder: (context, index, child) => Offstage(
                offstage: index != 0,
                child: TickerMode(enabled: index == 0, child: child!),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(repository.batchReads, 0);
        active.value = 1;
        await tester.pump();
        if (disposeWhileHidden) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        interaction.endNavigation(navigation);
        await tester.pump(const Duration(milliseconds: 161));
        await tester.pump();
        expect(repository.batchReads, 0);
        if (!disposeWhileHidden) {
          active.value = 0;
          await tester.pump();
          await pumpUntilLibraryTreeReady(
            tester,
            fixture.library,
            waitForCategorySnapshot: true,
          );
          // Startup refresh on Windows waits for real file-system futures.
          // Finish it before settling frames; fake time alone cannot do that.
          await tester.pump(const Duration(seconds: 2));
          bool refreshBusy() =>
              fixture.uiOperationService.isBusy(UiOperationScope.libraryRefresh) ||
              fixture.library.state.isScanning;
          for (var i = 0; i < 100 && refreshBusy(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(refreshBusy(), isFalse);
          await tester.pumpAndSettle();
          expect(repository.batchReads, 1);
          await tester.pump();
          expect(repository.batchReads, 1);
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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
