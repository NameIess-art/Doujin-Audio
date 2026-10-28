import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/subtitle_settings_provider.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/library_providers.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

class _WorkDetailRepository extends TestPersistenceRepository {
  final ready = Completer<void>();
  final details = <String, AudioDetail>{};
  final requestedTargets = <AudioDetailTarget>[];
  int singleReads = 0;
  int batchReads = 0;
  int batchFailuresRemaining = 0;

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
    final requested = targets.toList(growable: false);
    requestedTargets.addAll(requested);
    await ready.future;
    if (batchFailuresRemaining > 0) {
      batchFailuresRemaining--;
      throw StateError('Temporary detail query failure');
    }
    return [
      for (final target in requested)
        if (details[PathMatcher.normalize(target.targetPath)]
            case final detail?)
          detail.copyWith(target: target),
    ];
  }
}

Future<void> _waitForSort(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Asynchronous library sorting did not complete');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  test('cached card details are available on the first synchronous read', () {
    final fixture = AppRuntimeWidgetTestFixture();
    final container = ProviderContainer(
      overrides: [libraryFacadeProvider.overrideWithValue(fixture.library)],
    );
    addTearDown(fixture.dispose);
    addTearDown(container.dispose);
    final target = AudioDetailTarget.libraryRootFolder('/library/cached');
    final detail = AudioDetail.empty(target).copyWith(workTitle: 'Cached work');
    fixture.library.detailCacheService.markChanged(detail);
    final provider = libraryDetailForTargetProvider(target);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    expect(container.read(provider).isLoading, false);
    expect(container.read(provider).requireValue.workTitle, 'Cached work');
  });

  testWidgets(
    'a thousand local works keep cards stable while scrolling in both directions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = defaultTargetPlatform == TargetPlatform.windows
          ? const Size(1280, 800)
          : const Size(450, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final tracks = List.generate(
        1000,
        (index) => testMusicTrack(
          name: 'Work ${index.toString().padLeft(4, '0')}',
          path: '/library/scroll/$index.mp3',
          groupKey: '/library/scroll/$index.mp3',
          groupTitle: 'Work $index',
          isSingle: true,
        ),
      );
      fixture.library.addTracks(tracks, persist: false);
      for (final track in tracks) {
        fixture.library.detailCacheService.markChanged(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(track.path),
          ).copyWith(workTitle: track.displayName),
        );
      }
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      fixture.settingsRepository.syncSlice(isInitialized: true);
      await tester.runAsync(fixture.library.ensureCardSnapshot);
      await tester.pumpWidget(fixture.build(const LibraryTab()));
      await pumpUntilLibraryTreeReady(tester, fixture.library);
      final list = find.byKey(const PageStorageKey<String>('library_list'));
      await pumpUntilFound(tester, list);
      await pumpAndSettleWithAsync(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LibraryTab)),
      );
      final snapshot = container.read(librarySortedSnapshotUiProvider).nodes;
      final initialCards = find
          .byType(LibraryLikeSingleAudioCardContent)
          .evaluate()
          .toSet();
      expect(initialCards.length, inInclusiveRange(1, 60));
      var existingBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (builtOnce && initialCards.contains(element)) existingBuilds++;
      };
      try {
        final controller = tester.widget<ScrollView>(list).controller!;
        for (final delta in [-600.0, -900.0, 600.0, 900.0]) {
          final before = controller.offset;
          await tester.drag(list, Offset(0, delta));
          await tester.pumpAndSettle();
          expect(
            controller.offset,
            delta < 0 ? greaterThan(before) : lessThan(before),
          );
          expect(
            find.byType(LibraryLikeSingleAudioCardContent).evaluate().length,
            lessThan(60),
          );
          expect(
            container.read(librarySortedSnapshotUiProvider).nodes,
            same(snapshot),
          );
        }
        expect(existingBuilds, 0);
        expect(tester.takeException(), isNull);
      } finally {
        debugOnRebuildDirtyWidget = previous;
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('paused library sorting retains results until it resumes', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    fixture.settingsRepository.syncSlice(isInitialized: true);
    fixture.library.addTracks([
      for (final name in ['Beta', 'Alpha'])
        testMusicTrack(
          name: name,
          path: '/music/$name.mp3',
          groupKey: '/music/$name.mp3',
          groupTitle: name,
          isSingle: true,
        ),
    ], persist: false);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(fixture.library.ensureCardSnapshot);
    late ProviderContainer container;
    await tester.pumpWidget(
      fixture.build(
        Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final subscription = container.listen(
      librarySortedSnapshotUiProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    subscription.pause();
    await tester.pump();
    expect(container.read(librarySortedSnapshotUiProvider).nodes, isEmpty);
    subscription.resume();
    await _waitForSort(
      tester,
      () => container.read(librarySortedSnapshotUiProvider).nodes.length == 2,
    );
    final initial = container.read(librarySortedSnapshotUiProvider).nodes;
    expect(initial.first.name, 'Alpha');
    fixture.settingsRepository
      ..librarySortAscending = false
      ..syncSlice(isInitialized: true);
    await tester.pump();
    // Start preparation, then hide the consumer before the isolate replies.
    UiInteractionCoordinator.instance.flushPendingCommitsForTest();
    subscription.pause();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(
      container.read(librarySortedSnapshotUiProvider).nodes,
      same(initial),
    );
    subscription.resume();
    await _waitForSort(
      tester,
      () =>
          container.read(librarySortedSnapshotUiProvider).nodes.first.name ==
          'Beta',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final criterion in [
    LibrarySortCriterion.name,
    LibrarySortCriterion.voiceActor,
    LibrarySortCriterion.releaseDate,
  ]) {
    testWidgets(
      'library $criterion sorting reads only required card metadata without categories',
      (tester) async {
        final repository = _WorkDetailRepository()..ready.complete();
        final fixture = AppRuntimeWidgetTestFixture(
          providedPersistenceRepository: repository,
        );
        addTearDown(fixture.dispose);
        fixture.settingsRepository
          ..librarySortCriterion = criterion
          ..syncSlice(isInitialized: true);
        for (final (name, title, voice, year) in [
          ('RJ100', 'Zulu', 'Beta', 2025),
          ('RJ200', 'Alpha', 'Alpha', 2026),
        ]) {
          final root = '/music/$name';
          repository.details[PathMatcher.normalize(
            root,
          )] = AudioDetail.empty(AudioDetailTarget.libraryRootFolder(root))
              .copyWith(
                workTitle: title,
                voiceActors: [voice],
                releaseDate: DateTime(year),
              );
          fixture.library.addWatchedFolder(root, notify: false);
          fixture.library.addTracks([
            testMusicTrack(
              name: 'Track',
              path: '$root/track.mp3',
              groupKey: root,
              groupTitle: name,
            ),
          ], persist: false);
        }
        const singlePath = '/single.mp3';
        repository.details[PathMatcher.normalize(
          singlePath,
        )] = AudioDetail.empty(AudioDetailTarget.singleAudioFile(singlePath))
            .copyWith(
              workTitle: 'A title unused by single-file name sorting',
              voiceActors: ['Zulu'],
              releaseDate: DateTime(2024),
            );
        fixture.library.addTracks([
          testMusicTrack(
            name: 'Single',
            path: singlePath,
            groupKey: singlePath,
            groupTitle: 'Single',
            isSingle: true,
          ),
        ], persist: false);
        fixture.libraryService.syncSlice(
          isInitialized: true,
          detailRevision: 0,
        );
        await tester.runAsync(fixture.library.ensureCardSnapshot);
        List<LibraryNode> sorted = const [];
        await tester.pumpWidget(
          fixture.build(
            Consumer(
              builder: (context, ref, _) {
                sorted = ref.watch(librarySortedTreeUiProvider);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await _waitForSort(tester, () => sorted.length == 3);
        expect(sorted.map((node) => node.name), switch (criterion) {
          LibrarySortCriterion.name => ['RJ200', 'Single', 'RJ100'],
          LibrarySortCriterion.voiceActor => ['RJ200', 'RJ100', 'Single'],
          _ => ['Single', 'RJ100', 'RJ200'],
        });
        expect(repository.singleReads, 0);
        expect(repository.batchReads, 1);
        expect(
          repository.requestedTargets.map((target) => target.targetPath),
          unorderedEquals(
            [
              '/music/RJ100',
              '/music/RJ200',
              if (criterion != LibrarySortCriterion.name) singlePath,
            ].map(PathMatcher.normalize),
          ),
        );
        expect(fixture.library.categorySnapshot, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'detail changes refresh only their target and reset refreshes all',
    (tester) async {
      final repository = _WorkDetailRepository()..ready.complete();
      final fixture = AppRuntimeWidgetTestFixture(
        providedPersistenceRepository: repository,
      );
      addTearDown(fixture.dispose);
      final first = AudioDetailTarget.libraryRootFolder('/library/one');
      final second = AudioDetailTarget.libraryRootFolder('/library/two');
      fixture.library.detailCacheService
        ..markChanged(AudioDetail.empty(first).copyWith(workTitle: 'One'))
        ..markChanged(AudioDetail.empty(second).copyWith(workTitle: 'Two'));
      final container = ProviderContainer(
        overrides: [libraryFacadeProvider.overrideWithValue(fixture.library)],
      );
      addTearDown(container.dispose);
      final firstProvider = libraryDetailForTargetProvider(first);
      final secondProvider = libraryDetailForTargetProvider(second);
      final firstSubscription = container.listen(firstProvider, (_, _) {});
      final secondSubscription = container.listen(secondProvider, (_, _) {});
      addTearDown(firstSubscription.close);
      addTearDown(secondSubscription.close);
      await container.read(firstProvider.future);
      await container.read(secondProvider.future);
      await tester.pump();
      final firstRead = container.read(firstProvider.future);
      fixture.library.detailCacheService.markChanged(
        AudioDetail.empty(second).copyWith(workTitle: 'Updated two'),
      );
      await tester.pump();
      await tester.pump();
      expect(container.read(firstProvider.future), same(firstRead));
      expect(
        (await container.read(secondProvider.future)).workTitle,
        'Updated two',
      );
      fixture.library.detailCacheService.clear();
      await tester.pump();
      await tester.pump();
      expect(
        identical(container.read(firstProvider.future), firstRead),
        isFalse,
      );
      await _waitForSort(
        tester,
        () =>
            !container.read(firstProvider).isLoading &&
            !container.read(secondProvider).isLoading,
      );
      expect(container.read(firstProvider).hasValue, isTrue);
      expect(container.read(secondProvider).hasValue, isTrue);
      await tester.pump();
    },
  );

  test(
    'library scan progress publishes during motion without structural work',
    () async {
      final fixture = AppRuntimeWidgetTestFixture();
      final container = ProviderContainer(
        overrides: [libraryFacadeProvider.overrideWithValue(fixture.library)],
      );
      addTearDown(fixture.dispose);
      addTearDown(container.dispose);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      final subscription = container.listen(libraryStateProvider, (_, _) {});
      await container.read(libraryStateProvider.future);
      final interaction = UiInteractionCoordinator.instance;
      final motion = Object();
      interaction.beginInteraction(motion, deferVisualUpdates: true);
      fixture.libraryService
        ..isScanning = true
        ..scanProcessed = 8
        ..scanFoundCount = 6
        ..syncSlice(isInitialized: true, detailRevision: 0);
      await Future<void>.delayed(Duration.zero);
      final state = container.read(libraryStateProvider).requireValue;
      expect(state.scanProcessed, 8);
      expect(state.scanFoundCount, 6);
      expect(state.isScanning, isTrue);
      expect(interaction.isVisualUpdateDeferred, isTrue);
      expect(interaction.pendingCommitCount, 0);
      interaction.cancelInteraction(motion);
      subscription.close();
    },
  );

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
      final repository = _WorkDetailRepository()..ready.complete();
      final fixture = AppRuntimeWidgetTestFixture(
        providedPersistenceRepository: repository,
      );
      addTearDown(fixture.dispose);
      fixture.settingsRepository.syncSlice(isInitialized: true);
      fixture.library
        ..addWatchedFolder('/music/beta', notify: false)
        ..addWatchedFolder('/music/alpha', notify: false);
      fixture.library.addTracks([
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
      ], persist: false);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      await tester.runAsync(fixture.library.ensureCardSnapshot);

      List<LibraryNode>? sorted;
      Object? sortingError;
      await tester.pumpWidget(
        fixture.build(
          Consumer(
            builder: (context, ref, child) {
              sorted = ref.watch(librarySortedTreeUiProvider);
              sortingError = ref.watch(librarySortedSnapshotUiProvider).error;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _waitForSort(tester, () => sorted?.length == 2);
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
      await _waitForSort(tester, () {
        expect(sortingError, isNull);
        return !identical(sorted, initial);
      });
      final detailSorted = sorted;
      expect(identical(detailSorted, initial), isFalse);
      expect(repository.batchReads, 1);
      expect(repository.singleReads, 0);

      fixture.libraryService.syncSlice(
        isInitialized: true,
        detailRevision: 2,
        treeSnapshotRevision:
            fixture.library.snapshotCacheService.cardSnapshotRevision,
      );
      await tester.pump();
      await tester.pump();
      expect(identical(sorted, detailSorted), isTrue);
    },
  );

  testWidgets('failed sorting details retain the list and retry as one batch', (
    tester,
  ) async {
    final repository = _WorkDetailRepository()
      ..ready.complete()
      ..batchFailuresRemaining = 1;
    final fixture = AppRuntimeWidgetTestFixture(
      providedPersistenceRepository: repository,
    );
    addTearDown(fixture.dispose);
    fixture.settingsRepository
      ..workNameDisplay = WorkNameDisplay.folderName
      ..syncSlice(isInitialized: true);
    for (final (folder, title) in [('RJ100', 'Zulu'), ('RJ200', 'Alpha')]) {
      final root = '/music/$folder';
      repository.details[PathMatcher.normalize(root)] = AudioDetail.empty(
        AudioDetailTarget.libraryRootFolder(root),
      ).copyWith(workTitle: title);
      fixture.library.addWatchedFolder(root, notify: false);
      fixture.library.addTracks([
        testMusicTrack(
          name: 'Track',
          path: '$root/track.mp3',
          groupKey: root,
          groupTitle: folder,
        ),
      ], persist: false);
    }
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    await tester.runAsync(fixture.library.ensureCardSnapshot);
    late ProviderContainer container;
    await tester.pumpWidget(
      fixture.build(
        Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            ref.watch(librarySortedSnapshotUiProvider);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await _waitForSort(
      tester,
      () => container.read(librarySortedSnapshotUiProvider).nodes.length == 2,
    );
    final previous = container.read(librarySortedSnapshotUiProvider).nodes;
    expect(previous.map((node) => node.name), ['RJ100', 'RJ200']);
    expect(repository.batchReads, 0);
    fixture.settingsRepository
      ..workNameDisplay = WorkNameDisplay.workTitle
      ..syncSlice(isInitialized: true);
    await _waitForSort(
      tester,
      () => container.read(librarySortedSnapshotUiProvider).error != null,
    );
    final failed = container.read(librarySortedSnapshotUiProvider);
    expect(failed.nodes, same(previous));
    expect(failed.error, isStateError);
    expect(repository.batchReads, 1);
    expect(repository.singleReads, 0);
    expect(fixture.library.categorySnapshot, isNull);

    container.invalidate(librarySortedSnapshotUiProvider);
    await tester.pump();
    expect(
      container.read(librarySortedSnapshotUiProvider).nodes,
      same(previous),
    );
    await _waitForSort(tester, () {
      final state = container.read(librarySortedSnapshotUiProvider);
      return state.error == null && state.nodes.first.name == 'RJ200';
    });
    expect(repository.batchReads, 2);
    expect(repository.singleReads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('library name sort reacts to loaded titles and display settings', (
    tester,
  ) async {
    final repository = _WorkDetailRepository();
    addTearDown(() {
      if (!repository.ready.isCompleted) repository.ready.complete();
    });
    final fixture = AppRuntimeWidgetTestFixture(
      providedPersistenceRepository: repository,
    );
    addTearDown(fixture.dispose);
    fixture.settingsRepository
      ..workNameDisplay = WorkNameDisplay.folderName
      ..syncSlice(isInitialized: true);
    for (final (folder, title) in [('RJ100', 'Zulu'), ('RJ200', 'Alpha')]) {
      final root = '/music/$folder';
      repository.details[PathMatcher.normalize(root)] = AudioDetail.empty(
        AudioDetailTarget.libraryRootFolder(root),
      ).copyWith(workTitle: title);
      fixture.library.addWatchedFolder(root, notify: false);
      fixture.library.addTracks([
        testMusicTrack(
          name: 'Track',
          path: '$root/track.mp3',
          groupKey: root,
          groupTitle: folder,
        ),
      ], persist: false);
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
    await _waitForSort(tester, () => sorted?.firstOrNull?.name == 'RJ100');
    expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);
    expect(repository.singleReads, 0);
    expect(repository.batchReads, 0);

    final navigation = Object();
    final interaction = UiInteractionCoordinator.instance;
    interaction.beginNavigation(navigation);
    fixture.settingsRepository
      ..workNameDisplay = WorkNameDisplay.workTitle
      ..syncSlice(isInitialized: true);
    await tester.pump();
    final beforeBatch = sorted;
    final buildsBeforeBatch = builds;
    var snapshotReady = false;
    final snapshot = fixture.library.audioLibraryCategorySnapshot().then((
      value,
    ) {
      snapshotReady = true;
      return value;
    });
    repository.ready.complete();
    await _waitForSort(tester, () => snapshotReady);
    await snapshot;
    await tester.pump();
    expect(identical(sorted, beforeBatch), isTrue);
    expect(builds, buildsBeforeBatch);
    interaction.endNavigation(navigation);
    await tester.pump(const Duration(milliseconds: 161));
    await tester.pumpAndSettle();
    await _waitForSort(tester, () => sorted?.firstOrNull?.name == 'RJ200');
    expect(sorted!.map((node) => node.name), ['RJ200', 'RJ100']);
    expect(builds, buildsBeforeBatch + 1);
    expect(repository.batchReads, 1);

    fixture.settingsRepository
      ..workNameDisplay = WorkNameDisplay.folderName
      ..syncSlice(isInitialized: true);
    await tester.pumpAndSettle();
    await _waitForSort(tester, () => sorted?.firstOrNull?.name == 'RJ100');
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
    await _waitForSort(tester, () => sorted?.firstOrNull?.name == 'RJ100');
    expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);

    fixture.library.detailCacheService.markChanged(
      repository.details[PathMatcher.normalize('/music/RJ100')]!.copyWith(
        workTitle: 'Zulu',
      ),
    );
    fixture.library.syncPresentationState();
    await tester.pumpAndSettle();
    await _waitForSort(tester, () => sorted?.firstOrNull?.name == 'RJ200');
    expect(sorted!.map((node) => node.name), ['RJ200', 'RJ100']);

    // Sorting reloads its metadata after the detail cache is cleared.
    fixture.library.detailCacheService.clear();
    fixture.settingsRepository
      ..librarySortAscending = false
      ..syncSlice(isInitialized: true);
    await tester.pumpAndSettle();
    await _waitForSort(tester, () => sorted?.firstOrNull?.name == 'RJ100');
    expect(sorted!.map((node) => node.name), ['RJ100', 'RJ200']);
  });

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
          fixture.library.addTracks([
            testMusicTrack(
              name: 'Track',
              path: '$root/track.mp3',
              groupKey: root,
              groupTitle: folder,
            ),
          ], persist: false);
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
          await _waitForSort(
            tester,
            () =>
                ProviderScope.containerOf(
                  tester.element(find.byType(LibraryTab)),
                ).read(librarySortedSnapshotUiProvider).nodes.length ==
                24,
          );
          expect(fixture.library.categorySnapshot, isNull);
          // Check the sorting commit directly; cover discovery and startup
          // refresh can wait on I/O while widget fake time keeps advancing.
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

  testWidgets('playlist ignores artwork changes and observes sorting inputs', (
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
    fixture.library.addTracks(tracks, persist: false);
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
    List<String> sortedIds = const [];
    var displayedCoverGeneration = -1;
    await tester.pumpWidget(
      fixture.build(
        Consumer(
          builder: (context, ref, child) {
            final entries = ref.watch(playlistSortedEntriesUiProvider);
            sorted = entries;
            sortedIds = entries.map((entry) => entry.sessionId).toList();
            displayedCoverGeneration = ref
                .watch(playlistStructureUiProvider)
                .coverGeneration;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initial = sorted;
    expect(initial, hasLength(2));
    final initialCoverGeneration = displayedCoverGeneration;

    fixture.library.coverArtworkCacheService.invalidateAll();
    await tester.pump();
    await tester.pump();
    expect(displayedCoverGeneration, greaterThan(initialCoverGeneration));
    expect(identical(sorted, initial), isTrue);

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

    final beforePin = sorted;
    fixture.settingsRepository
      ..pinnedPlaylistSessionIds = [sessions.first.id]
      ..syncSlice(isInitialized: true);
    await tester.pump();
    await tester.pump();
    expect(identical(sorted, beforePin), isFalse);
    expect(sortedIds.first, sessions.first.id);
  });
}
