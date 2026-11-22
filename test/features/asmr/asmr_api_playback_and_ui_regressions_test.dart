import 'dart:async';

import 'package:doujin_audio/core/app_language.dart';
import 'package:doujin_audio/core/immutable_collections.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_coordinator.dart';
import 'package:doujin_audio/features/asmr/application/japanese_asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/app_runtime_test_fixture.dart';
import '../../support/asmr_controller_test_fixture.dart';

AsmrWork _work(int id, {String? title}) => AsmrWork(
  id: id,
  title: title ?? 'Work $id',
  circleName: 'Circle',
  sourceId: 'RJ${id.toString().padLeft(6, '0')}',
  sourceType: 'asmr-one',
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
  resources: [
    AsmrWorkResource(
      source: AsmrCatalogSource.japaneseAsmr,
      id: id,
      code: 'RJ${id.toString().padLeft(6, '0')}',
      pageUrl: 'https://japaneseasmr.com/$id/',
    ),
  ],
);

MusicTrack _track(String path) => MusicTrack(
  path: path,
  displayName: path,
  groupKey: 'group',
  groupTitle: 'Work',
  groupSubtitle: '',
  isSingle: false,
);

class _FakePlaybackSource implements AsmrPlaybackSource {
  _FakePlaybackSource({this.loadTracks});

  Future<List<MusicTrack>> Function(AsmrWork work)? loadTracks;
  final List<AsmrWork> recordedWorks = <AsmrWork>[];

  @override
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work) =>
      loadTracks?.call(work) ?? Future<List<MusicTrack>>.value(const []);

  @override
  Future<List<MusicTrack>> loadPlayableTracksStartingAt(
    AsmrWork work,
    AsmrTrackFile target,
  ) async => const <MusicTrack>[];

  @override
  Future<void> recordHistory(AsmrWork work) async {
    recordedWorks.add(work);
  }
}

/// Mirrors `PlaybackQueuePathCoordinator.playDirect` revision semantics so
/// tests can simulate a local library `playDirect` superseding a pending remote
/// ASMR direct play.
class _RevisionPlaybackLauncher implements PlaybackSessionLauncher {
  int _revision = 0;

  @override
  Future<bool> playDirect(
    FutureOr<List<MusicTrack>> tracks, {
    int startIndex = 0,
    SessionLoopMode loopMode = SessionLoopMode.folderSequential,
  }) async {
    final revision = ++_revision;
    final List<MusicTrack> resolved;
    try {
      resolved = tracks is List<MusicTrack> ? tracks : await tracks;
    } catch (_) {
      if (revision != _revision) return false;
      rethrow;
    }
    if (revision != _revision || resolved.isEmpty) return false;
    return true;
  }

  @override
  Future<bool> addTrackToPlaylist(
    MusicTrack track, {
    List<MusicTrack>? workTracks,
  }) async => true;

  @override
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) async => true;
}

class _PaginatedTestController extends AsmrLibraryController
    with TestAsmrCategoryViewOverrides {
  _PaginatedTestController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );

  List<AsmrWork> works = <AsmrWork>[];
  Object paginationToken = Object();
  ({Object token, int length})? appendedTo;
  bool hasMore = true;
  int revision = 0;

  void appendPage(List<AsmrWork> additions) {
    appendedTo = (token: paginationToken, length: works.length);
    paginationToken = Object();
    works = immutableList([...works, ...additions]);
    revision++;
    notifyListeners();
  }

  @override
  bool get initialized => true;

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: const [AsmrCategoryType.release],
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: revision,
  );

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {}

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  bool hasLoadedCategory(AsmrCategoryType category) => true;

  @override
  Future<void> ensureCategoryLoaded(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) async {}

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
    bool searchSession = false,
  }) => AsmrCategoryViewState(
    category: category,
    works: works,
    isLoading: false,
    isLoadingMore: false,
    isRefreshing: false,
    isStale: false,
    hasAttemptedLoad: true,
    hasMore: hasMore,
    needsLoadMoreRetry: false,
    totalCount: works.length + (hasMore ? 10 : 0),
    activeQuery: searchQuery,
    lastError: null,
    operationError: null,
    revision: revision,
    paginationToken: paginationToken,
    appendedTo: appendedTo,
  );
}

void main() {
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  group('#75 direct work play distinguishes local superseding from failure', () {
    test(
      'playDirectWorkWithStatus returns superseded when local playDirect overrides a pending remote work',
      () async {
        final gate = Completer<List<MusicTrack>>();
        final source = _FakePlaybackSource(loadTracks: (_) => gate.future);
        final launcher = _RevisionPlaybackLauncher();
        final coordinator = AsmrPlaybackCoordinator(
          source: source,
          launcher: launcher,
        );

        final remotePlay = coordinator.playDirectWorkWithStatus(_work(1));
        final epochBeforeLocal = coordinator.directPlayEpoch;

        // Simulate local library play directly calling launcher.playDirect.
        expect(await launcher.playDirect([_track('local.mp3')]), isTrue);
        expect(coordinator.directPlayEpoch, epochBeforeLocal);

        gate.complete([_track('remote.mp3')]);
        expect(await remotePlay, AsmrDirectPlayResult.superseded);
        expect(source.recordedWorks, isEmpty);
      },
    );

    test(
      'playDirectWorkWithStatus returns empty when non-superseded work has no tracks, and superseded when errored load is overridden',
      () async {
        final emptySource = _FakePlaybackSource();
        final launcher = _RevisionPlaybackLauncher();
        final coordinator = AsmrPlaybackCoordinator(
          source: emptySource,
          launcher: launcher,
        );

        expect(
          await coordinator.playDirectWorkWithStatus(_work(2)),
          AsmrDirectPlayResult.empty,
        );

        // Supersede a failing remote load with local playback.
        final gate = Completer<List<MusicTrack>>();
        final slowFailingCoordinator = AsmrPlaybackCoordinator(
          source: _FakePlaybackSource(loadTracks: (_) => gate.future),
          launcher: launcher,
        );
        final remotePlay = slowFailingCoordinator.playDirectWorkWithStatus(
          _work(3),
        );
        expect(await launcher.playDirect([_track('local2.mp3')]), isTrue);
        gate.completeError(StateError('network_error'));
        expect(await remotePlay, AsmrDirectPlayResult.superseded);
      },
    );

    testWidgets(
      'AsmrWorkTreeCard does not show error snackbar when superseded by local playback',
      (tester) async {
        final gate = Completer<List<MusicTrack>>();
        final source = _FakePlaybackSource(loadTracks: (_) => gate.future);
        final launcher = _RevisionPlaybackLauncher();
        final playback = AsmrPlaybackCoordinator(
          source: source,
          launcher: launcher,
        );
        final controller = _PaginatedTestController(createTestAsmrServices())
          ..works = [_work(7501, title: 'Remote Work')]
          ..hasMore = false;
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);

        await tester.pumpWidget(
          fixture.build(
            const AsmrTab(),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              asmrPlaybackCoordinatorProvider.overrideWithValue(playback),
            ],
          ),
        );
        await pumpUntilFound(tester, find.text('Remote Work'));

        final actions = tester.widget<LibraryLikeCardActions>(
          find.byType(LibraryLikeCardActions).first,
        );
        actions.onPlay!.call();
        await tester.pump();

        // Local library play supersedes the pending remote request.
        expect(await launcher.playDirect([_track('local.mp3')]), isTrue);
        gate.complete([_track('remote.mp3')]);
        await tester.pumpAndSettle();

        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  testWidgets(
    '#73 pagination load animations detach FadeTransition and dispose controllers safely after completion',
    (tester) async {
      final controller = _PaginatedTestController(createTestAsmrServices())
        ..works = [
          for (var i = 1; i <= 3; i++) _work(i, title: 'Page1 Work $i'),
        ]
        ..hasMore = true;
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(controller.dispose);
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await pumpUntilFound(tester, find.text('Page1 Work 1'));

      // Append multiple pages and let each fade batch complete + post-frame dispose.
      controller.appendPage([_work(4, title: 'Page2 Work 4')]);
      await pumpUntilFound(tester, find.text('Page2 Work 4'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      controller.appendPage([_work(5, title: 'Page3 Work 5')]);
      await pumpUntilFound(tester, find.text('Page3 Work 5'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      // Completed cards must be detached back to AlwaysStoppedAnimation(1) so
      // no mounted FadeTransition holds a disposed AnimationController.
      final fade = tester.widget<FadeTransition>(
        find.byKey(const ValueKey<String>('asmr-work-code:RJ000004')),
      );
      expect(fade.opacity, isA<AlwaysStoppedAnimation<double>>());
      expect(fade.opacity.value, 1.0);

      // Unmounting must not throw any disposed-controller or active-ticker error.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  test(
    'ensureTrackTree caps repeated epoch-change retries instead of recursing forever',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      addTearDown(db.close);
      late AsmrLibraryController controller;
      var fetchCalls = 0;
      final jpApi = _EpochBumpingJapaneseApi(
        onFetchTree: () {
          fetchCalls++;
          // Flip page language on every fetch so _contentEpoch advances mid-flight.
          controller.setPageLanguage(
            fetchCalls.isOdd ? AppLanguage.ja : AppLanguage.zh,
          );
        },
      );
      final services = createTestAsmrServices(
        persistenceRepository: SqliteAsmrRepository(
          database: AppDatabase.test(db),
        ),
        japaneseApiService: jpApi,
      );
      controller = AsmrLibraryController(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      );
      addTearDown(controller.dispose);
      await controller.initializeForVisiblePage();
      expect(controller.supportsVersionedSnapshots, isTrue);

      await expectLater(
        controller.ensureTrackTree(_work(99)),
        throwsA(isA<StateError>()),
      );
      // Initial attempt + 4 retries = 5 total fetches, then bounded failure.
      expect(fetchCalls, 5);
    },
  );
}

final class _EpochBumpingJapaneseApi extends JapaneseAsmrApiService {
  _EpochBumpingJapaneseApi({required this.onFetchTree});

  final void Function() onFetchTree;

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    AsmrWork work, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    onFetchTree();
    return <AsmrTrackFile>[
      AsmrTrackFile.fromJson(const <String, dynamic>{
        'type': 'audio',
        'title': '01.mp3',
        'mediaStreamUrl': 'https://example.test/01.mp3',
      }),
    ];
  }
}
