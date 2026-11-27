import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/app/application/work_review_sync_runtime_binding.dart';
import 'package:doujin_audio/app/localization/app_language_zh.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/widgets/work_review_panel.dart';
import 'package:doujin_audio/features/asmr/application/asmr_account_sync_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_work_detail_sheet.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_library_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

AsmrWork _asmrWork(
  int id, {
  String? sourceId,
  String? title,
  bool isFavorite = false,
  WorkListenStatus? listenStatus,
  int? userRating,
  String reviewText = '',
  DateTime? reviewUpdatedAt,
}) {
  return AsmrWork(
    id: id,
    title: title ?? 'Work $id',
    circleName: 'Circle',
    sourceId: sourceId ?? 'RJ${id.toString().padLeft(6, '0')}',
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
    rating: 4.7,
    isFavorite: isFavorite,
    listenStatus: listenStatus,
    userRating: userRating,
    reviewText: reviewText,
    reviewUpdatedAt: reviewUpdatedAt,
    voiceActors: const <String>['CV A'],
    tags: const <String>['Tag A'],
  );
}

final class _MemoryAsmrTokenStore implements AsmrTokenStore {
  _MemoryAsmrTokenStore([this.token]);

  String? token;
  Map<String, String>? credentials;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async {
    token = value;
  }

  @override
  Future<void> clearToken() async {
    token = null;
  }

  @override
  Future<Map<String, String>?> readCredentials() async => credentials;

  @override
  Future<void> writeCredentials(String name, String password) async {
    credentials = {'name': name, 'password': password};
  }

  @override
  Future<void> clearCredentials() async {
    credentials = null;
  }
}

typedef _RecordedPutReview = ({
  int workId,
  WorkListenStatus? progress,
  int? userRating,
  String? reviewText,
  bool starOnly,
  bool progressOnly,
});

final class _FakeReviewApiService extends AsmrApiService {
  final Map<String?, List<AsmrReviewRecord>> reviewsByFilter =
      <String?, List<AsmrReviewRecord>>{};
  final List<_RecordedPutReview> putReviewCalls = <_RecordedPutReview>[];
  final List<(int workId, String progress)> putProgressCalls =
      <(int, String)>[];
  final List<int> deletedWorkIds = <int>[];
  final Set<int> notFoundWorkIds = <int>{};
  final Set<int> uncollected500WorkIds = <int>{};
  final List<int> workCollectedLookups = <int>[];

  @override
  Future<bool> isWorkCollected(
    int workId, {
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    workCollectedLookups.add(workId);
    return !notFoundWorkIds.contains(workId) &&
        !uncollected500WorkIds.contains(workId);
  }

  @override
  Future<AsmrAuthSession?> checkSession(String token) async =>
      AsmrAuthSession(token: token, userName: 'tester');

  @override
  Future<List<AsmrTrackFile>> fetchTrackTree(
    int id, {
    String? token,
    AsmrRequestCancellationToken? cancellationToken,
  }) async => const [];

  @override
  Future<List<AsmrReviewRecord>> fetchReviews({
    required String token,
    String? filter,
    int page = 1,
    String order = 'updated_at',
    String sort = 'desc',
    AsmrContentLanguage language = AsmrContentLanguage.zh,
    AsmrRequestCancellationToken? cancellationToken,
  }) async {
    if (page > 1) return const <AsmrReviewRecord>[];
    return filter == null
        ? reviewsByFilter.values.expand((records) => records).toList()
        : reviewsByFilter[filter] ?? const <AsmrReviewRecord>[];
  }

  @override
  Future<void> putReview({
    required String token,
    required int workId,
    WorkListenStatus? progress,
    int? userRating,
    String? reviewText,
    bool starOnly = false,
    bool progressOnly = false,
  }) async {
    if (notFoundWorkIds.contains(workId)) {
      throw const AsmrApiException('Work not found', statusCode: 404);
    }
    if (uncollected500WorkIds.contains(workId)) {
      throw const AsmrApiException(
        'ASMR API server error (500).',
        statusCode: 500,
      );
    }
    putReviewCalls.add((
      workId: workId,
      progress: progress,
      userRating: userRating,
      reviewText: reviewText,
      starOnly: starOnly,
      progressOnly: progressOnly,
    ));
  }

  @override
  Future<void> putReviewProgress({
    required int workId,
    required String progress,
    required String token,
  }) async {
    if (notFoundWorkIds.contains(workId)) {
      throw const AsmrApiException('Work not found', statusCode: 404);
    }
    putProgressCalls.add((workId, progress));
  }

  @override
  Future<void> deleteReview({
    required int workId,
    required String token,
  }) async {
    if (notFoundWorkIds.contains(workId)) {
      throw const AsmrApiException('Work not found', statusCode: 404);
    }
    deletedWorkIds.add(workId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('ASMR detail discards the old note after its review is cleared', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);
    final api = _FakeReviewApiService();
    addTearDown(api.close);
    final work = _asmrWork(100001);
    final controller = (await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await AppDatabase.createSchemaForTest(db);
      final repository = SqliteAsmrRepository(database: AppDatabase.test(db));
      final preferences = AsmrPreferencesStore(repository: repository);
      final controller = AsmrLibraryController(
        preferencesStore: preferences,
        remoteCatalogService: AsmrRemoteCatalogService(
          apiService: api,
          persistenceRepository: repository,
        ),
        accountSyncService: AsmrAccountSyncService(
          authService: AsmrAuthService(
            apiService: api,
            tokenStore: _MemoryAsmrTokenStore(),
          ),
          apiService: api,
          preferencesStore: preferences,
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.saveWorkReview(
        work,
        listenStatus: null,
        userRating: null,
        reviewText: 'Review to clear',
      );
      return controller;
    }))!;

    await tester.pumpWidget(
      fixture.build(
        buildAsmrWorkDetailPage(work: controller.reviewedWorks.single),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    final review = find.byType(WorkUserReviewSection);
    await pumpUntilFound(tester, review);
    expect(
      tester.widget<WorkUserReviewSection>(review).reviewText,
      'Review to clear',
    );

    await tester.runAsync(
      () => controller.saveWorkReview(
        work,
        listenStatus: null,
        userRating: null,
        reviewText: '',
      ),
    );
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is WorkUserReviewSection && widget.reviewText.isEmpty,
      ),
    );
    expect(tester.widget<WorkUserReviewSection>(review).reviewText, isEmpty);
    final noteButton = find.byKey(const ValueKey('work_review_note_button'));
    await tester.ensureVisible(noteButton);
    await tester.tap(noteButton);
    final input = find.byKey(const ValueKey('work_review_panel_note_input'));
    await pumpUntilFound(tester, input);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
  });

  group('SQLite v21 user review persistence & migration', () {
    late Database db;
    late AppDatabase appDatabase;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      appDatabase = AppDatabase.test(db);
    });

    tearDown(() => db.close());

    test(
      'migrates pre-v21 database and persists audio_details & asmr review states',
      () async {
        for (final column in [
          'listen_status',
          'user_rating',
          'review_text',
          'review_updated_at_ms',
        ]) {
          await db.execute('ALTER TABLE audio_details DROP COLUMN $column');
          await db.execute('ALTER TABLE asmr_works DROP COLUMN $column');
        }
        for (final column in [
          'progress',
          'user_rating',
          'review_text',
          'has_review_payload',
        ]) {
          await db.execute(
            'ALTER TABLE asmr_sync_operations DROP COLUMN $column',
          );
        }
        await db.setVersion(20);

        await AppDatabase.upgradeSchemaForTest(
          db,
          20,
          AppDatabase.schemaVersion,
        );

        final libraryRepo = SqliteLibraryRepository(database: appDatabase);
        final target = AudioDetailTarget.libraryRootFolder(r'C:\Audio\RJ123456');
        final reviewTime = DateTime.utc(2026, 8, 10, 14);
        await libraryRepo.upsert(
          AudioDetail.empty(target).copyWith(
            rjCode: 'RJ123456',
            workTitle: 'Local Work',
            listenStatus: WorkListenStatus.replay,
            userRating: 5,
            reviewText: 'Binaural masterpiece',
            reviewUpdatedAt: reviewTime,
          ),
        );
        final loadedDetail = await libraryRepo.load(target);
        expect(loadedDetail?.listenStatus, WorkListenStatus.replay);
        expect(loadedDetail?.userRating, 5);
        expect(loadedDetail?.reviewText, 'Binaural masterpiece');
        expect(loadedDetail?.reviewUpdatedAt?.toUtc(), reviewTime);

        final asmrRepo = SqliteAsmrRepository(database: appDatabase);
        final work = _asmrWork(
          123456,
          listenStatus: WorkListenStatus.listened,
          userRating: 4,
          reviewText: 'Solid voice acting',
          reviewUpdatedAt: reviewTime,
        );
        final op = AsmrSyncOperation(
          type: AsmrSyncOperationType.reviewUpsert,
          workId: 123456,
          sourceId: 'RJ123456',
          createdAt: reviewTime,
          progress: 'listened',
          userRating: 4,
          reviewText: 'Solid voice acting',
          hasReviewPayload: true,
        );
        await asmrRepo.saveReviewState(
          work: work,
          favorite: false,
          reviewed: true,
          operation: op,
        );

        final reviewed = await asmrRepo.loadWorkList('reviewed');
        expect(reviewed, hasLength(1));
        expect(reviewed.single.listenStatus, WorkListenStatus.listened);
        expect(reviewed.single.userRating, 4);
        expect(reviewed.single.reviewText, 'Solid voice acting');

        final operations = await asmrRepo.loadSyncOperations();
        expect(operations, hasLength(1));
        expect(operations.single.type, AsmrSyncOperationType.reviewUpsert);
        expect(operations.single.progress, 'listened');
        expect(operations.single.userRating, 4);
        expect(operations.single.reviewText, 'Solid voice acting');
        expect(operations.single.hasReviewPayload, isTrue);
      },
    );
  });

  group('AsmrAccountSyncService full review sync', () {
    late Database db;
    late AppDatabase appDatabase;
    late SqliteAsmrRepository asmrRepo;
    late AsmrPreferencesStore prefs;
    late _FakeReviewApiService api;
    late AsmrAccountSyncService sync;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      appDatabase = AppDatabase.test(db);
      asmrRepo = SqliteAsmrRepository(database: appDatabase);
      prefs = AsmrPreferencesStore(repository: asmrRepo);
      api = _FakeReviewApiService();
      final auth = AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore('token-tester'),
      );
      sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );
      await sync.initialize();
      await sync.restoreSession();
    });

    tearDown(() async {
      api.close();
      await db.close();
    });

    test(
      'favoriting keeps the queued rating and note in SQLite and uploads them',
      () async {
        final work = _asmrWork(100001);
        await sync.saveWorkReview(
          work,
          listenStatus: WorkListenStatus.listened,
          userRating: 5,
          reviewText: 'Pending note',
        );

        await sync.setFavorites([work], favorite: true);

        final pending = (await prefs.loadSyncOperations()).single;
        expect(pending.type, AsmrSyncOperationType.reviewUpsert);
        expect(pending.progress, 'marked');
        expect(pending.userRating, 5);
        expect(pending.reviewText, 'Pending note');
        // A stale pull can read the updated status without the new review fields.
        api.reviewsByFilter['marked'] = [
          AsmrReviewRecord(
            work: work,
            progress: 'marked',
            updatedAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
        ];
        final result = await sync.synchronize(
          language: AsmrContentLanguage.zh,
          cancellationToken: AsmrRequestCancellationToken(),
        );
        expect(result.succeeded, isTrue);
        expect(api.putProgressCalls, isEmpty);
        final uploaded = api.putReviewCalls.single;
        expect(uploaded.progress, WorkListenStatus.marked);
        expect(uploaded.userRating, 5);
        expect(uploaded.reviewText, 'Pending note');
        expect(result.snapshot.reviewedWorks.single.reviewText, 'Pending note');
        expect(
          (await prefs.loadReviewedWorks()).single.reviewText,
          'Pending note',
        );
      },
    );

    test(
      'full pull includes reviews without status and reuses unchanged indexes',
      () async {
        final work = _asmrWork(200002);
        api.reviewsByFilter[null] = [
          AsmrReviewRecord(
            work: work,
            progress: '',
            updatedAt: DateTime.utc(2026, 11, 26),
            userRating: 4,
            reviewText: 'Rated without status',
          ),
        ];

        final result = await sync.synchronize(
          language: AsmrContentLanguage.zh,
          cancellationToken: AsmrRequestCancellationToken(),
        );

        expect(result.succeeded, isTrue);
        expect(result.snapshot.favoriteWorks, isEmpty);
        expect(result.snapshot.historyWorks, isEmpty);
        final persisted = (await prefs.loadReviewedWorks()).single;
        expect(persisted.listenStatus, isNull);
        expect(persisted.userRating, 4);
        expect(persisted.reviewText, 'Rated without status');
        final afterHistory = await sync.recordHistory(_asmrWork(300003));
        expect(
          afterHistory.reviewedByWorkKey,
          same(result.snapshot.reviewedByWorkKey),
        );
        expect(
          afterHistory.reviewedByRjCode,
          same(result.snapshot.reviewedByRjCode),
        );
      },
    );

    test(
      'saves 5 statuses + rating + note, preserves rating/note on unfavorite, and drops 404 local RJ ops',
      () async {
        final work = _asmrWork(100001);
        final markedReview = await sync.saveWorkReview(
          work,
          listenStatus: WorkListenStatus.marked,
          userRating: 5,
          reviewText: 'Must listen weekend',
        );
        expect(markedReview.favoriteIds, contains(work.workKey));
        expect(markedReview.reviewedWorks.single.userRating, 5);
        expect(
          markedReview.reviewedWorks.single.reviewText,
          'Must listen weekend',
        );

        // Unfavoriting a marked work clears `marked` status without wiping rating/note.
        final afterUnfavorite = await sync.setFavorites(
          <AsmrWork>[markedReview.reviewedWorks.single],
          favorite: false,
        );
        expect(afterUnfavorite.favoriteWorks, isEmpty);
        expect(afterUnfavorite.reviewedWorks, hasLength(1));
        expect(afterUnfavorite.reviewedWorks.single.listenStatus, isNull);
        expect(afterUnfavorite.reviewedWorks.single.userRating, 5);
        expect(
          afterUnfavorite.reviewedWorks.single.reviewText,
          'Must listen weekend',
        );

        // Queue local-only RJ works returning 404 and real-world Kikoeru FK 500.
        api.notFoundWorkIds.add(999999);
        api.uncollected500WorkIds.add(888888);
        await sync.saveWorkReview(
          _asmrWork(999999),
          listenStatus: WorkListenStatus.postponed,
          userRating: 2,
          reviewText: 'Local DLsite-only work',
        );
        await sync.saveWorkReview(
          _asmrWork(888888),
          listenStatus: WorkListenStatus.marked,
          userRating: 5,
          reviewText: 'Uncollected local favorite',
        );
        await sync.saveWorkReview(
          work,
          listenStatus: WorkListenStatus.listened,
          userRating: 5,
          reviewText: 'Finished and loved it',
        );

        api.reviewsByFilter['listened'] = <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: _asmrWork(
              100001,
              listenStatus: WorkListenStatus.listened,
              userRating: 5,
              reviewText: 'Finished and loved it',
              reviewUpdatedAt: DateTime.utc(2026, 9),
            ),
            progress: 'listened',
            userRating: 5,
            reviewText: 'Finished and loved it',
            updatedAt: DateTime.utc(2026, 9),
          ),
        ];
        api.reviewsByFilter['replay'] = <AsmrReviewRecord>[
          AsmrReviewRecord(
            work: _asmrWork(
              200002,
              listenStatus: WorkListenStatus.replay,
              userRating: 4,
              reviewText: 'Remote replay note',
              reviewUpdatedAt: DateTime.utc(2026, 9, 2),
            ),
            progress: 'replay',
            userRating: 4,
            reviewText: 'Remote replay note',
            updatedAt: DateTime.utc(2026, 9, 2),
          ),
        ];

        final synced = await sync.synchronize(
          language: AsmrContentLanguage.zh,
          cancellationToken: AsmrRequestCancellationToken(),
        );
        expect(synced.failure, isNull);
        expect(synced.snapshot.pendingOperations, isEmpty);
        expect(api.workCollectedLookups, [888888]);
        expect(
          synced.snapshot.reviewedByRjCode['RJ888888']?.reviewText,
          'Uncollected local favorite',
        );
        expect(synced.snapshot.favoriteIds, contains('code:RJ888888'));
        expect(api.putReviewCalls, hasLength(1));
        expect(api.putReviewCalls.single.workId, 100001);
        expect(api.putReviewCalls.single.progress, WorkListenStatus.listened);
        expect(api.putReviewCalls.single.userRating, 5);
        expect(api.putReviewCalls.single.reviewText, 'Finished and loved it');
        expect(api.putReviewCalls.single.starOnly, isFalse);

        final remoteReplay = synced.snapshot.reviewedByRjCode['RJ200002'];
        expect(remoteReplay?.listenStatus, WorkListenStatus.replay);
        expect(remoteReplay?.userRating, 4);
        expect(remoteReplay?.reviewText, 'Remote replay note');

        // Clearing review enqueues and flushes DELETE /api/review.
        api.reviewsByFilter['listened'] = const <AsmrReviewRecord>[];
        await sync.saveWorkReview(
          work,
          listenStatus: null,
          userRating: null,
          reviewText: '',
        );
        final afterDelete = await sync.synchronize(
          language: AsmrContentLanguage.zh,
          cancellationToken: AsmrRequestCancellationToken(),
        );
        expect(api.deletedWorkIds, contains(100001));
        expect(afterDelete.snapshot.reviewedByRjCode['RJ100001'], isNull);
      },
    );
  });

  group('WorkReviewSyncRuntimeBinding bidirectional RJ reconciliation', () {
    late Directory tempDir;
    late Database db;
    late AppDatabase appDatabase;
    late LibraryFacade library;
    late AsmrLibraryController asmrController;
    late WorkReviewSyncRuntimeBinding binding;
    late _FakeReviewApiService api;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rj_review_sync_');
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      appDatabase = AppDatabase.test(db);

      final persistence = TestPersistenceRepository(database: appDatabase);
      final libraryService = LibraryService()
        ..watchedLibraries.add(tempDir.path);
      library = LibraryFacade.create(
        databaseRepository: persistence,
        service: libraryService,
      );

      final asmrRepo = SqliteAsmrRepository(database: appDatabase);
      final prefs = AsmrPreferencesStore(repository: asmrRepo);
      api = _FakeReviewApiService();
      final auth = AsmrAuthService(
        apiService: api,
        tokenStore: _MemoryAsmrTokenStore(),
      );
      final sync = AsmrAccountSyncService(
        authService: auth,
        apiService: api,
        preferencesStore: prefs,
      );
      asmrController = AsmrLibraryController(
        preferencesStore: prefs,
        remoteCatalogService: AsmrRemoteCatalogService(
          apiService: api,
          persistenceRepository: asmrRepo,
        ),
        accountSyncService: sync,
        backgroundSyncDebounce: Duration.zero,
      );
      await asmrController.initialize();
      binding = WorkReviewSyncRuntimeBinding(
        library: library,
        asmrLibrary: asmrController,
      );
    });

    tearDown(() async {
      await binding.dispose();
      asmrController.dispose();
      await library.dispose();
      api.close();
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'syncs local AudioDetail review <-> ASMR controller by RJ code and updates doujin-audio.json',
      () async {
        final workDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}RJ123456 Work',
        );
        await workDir.create(recursive: true);
        final trackPath = '${workDir.path}${Platform.pathSeparator}01.mp3';
        await File(trackPath).writeAsBytes(const <int>[1, 2, 3]);

        library.addTracks(<MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: workDir.path,
            groupTitle: 'RJ123456 Work',
            groupSubtitle: workDir.path,
            isSingle: false,
          ),
        ], persist: false);

        final target = AudioDetailTarget.libraryRootFolder(workDir.path);
        await library.saveAudioDetail(
          AudioDetail.empty(
            target,
          ).copyWith(rjCode: 'RJ123456', workTitle: 'Synced Work'),
        );

        final t1 = DateTime.utc(2026, 10, 1, 12);
        await library.saveAudioUserReview(
          target,
          listenStatus: WorkListenStatus.listening,
          userRating: 4,
          reviewText: 'Local listening note',
          updatedAt: t1,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final syncedAsmr = asmrController.reviewForRjCode('RJ123456');
        expect(syncedAsmr, isNotNull);
        expect(syncedAsmr?.listenStatus, WorkListenStatus.listening);
        expect(syncedAsmr?.userRating, 4);
        expect(syncedAsmr?.reviewText, 'Local listening note');

        // Newer ASMR side review updates local AudioDetail and doujin-audio.json.
        final t2 = DateTime.utc(2026, 10, 2, 12);
        await asmrController.saveWorkReview(
          syncedAsmr!,
          listenStatus: WorkListenStatus.listened,
          userRating: 5,
          reviewText: 'Updated from ASMR side',
          updatedAt: t2,
          enqueueSync: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));

        final updatedLocal = await library.loadAudioDetail(target);
        expect(updatedLocal.detail.listenStatus, WorkListenStatus.listened);
        expect(updatedLocal.detail.userRating, 5);
        expect(updatedLocal.detail.reviewText, 'Updated from ASMR side');

        final jsonFile = File(
          '${workDir.path}${Platform.pathSeparator}doujin-audio.json',
        );
        final jsonMap =
            jsonDecode(await jsonFile.readAsString()) as Map<String, Object?>;
        expect(jsonMap['listenStatus'], 'listened');
        expect(jsonMap['userRating'], 5);
        expect(jsonMap['reviewText'], 'Updated from ASMR side');

        // Explicit local clear clears ASMR side too.
        await library.saveAudioUserReview(
          target,
          listenStatus: null,
          userRating: null,
          reviewText: '',
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(asmrController.reviewForRjCode('RJ123456'), isNull);
      },
    );
  });

  group('WorkUserReviewSection & showWorkReviewEditPanel UI', () {
    String tr(String key) => appLanguageZh[key] ?? key;

    testWidgets(
      'toggles status capsules, star ratings, and saves/clears notes via modal panel',
      (tester) async {
        WorkListenStatus? status;
        int? rating;
        var note = '';

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: StatefulBuilder(
              builder: (context, setState) {
                return Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: WorkUserReviewSection(
                      listenStatus: status,
                      userRating: rating,
                      reviewText: note,
                      translate: tr,
                      onStatusChanged: (next) => setState(() => status = next),
                      onRatingChanged: (next) => setState(() => rating = next),
                      onOpenNoteEditor: () async {
                        final draft = await showWorkReviewEditPanel(
                          context: context,
                          workTitle: 'RJ123456',
                          initialStatus: status,
                          initialUserRating: rating,
                          initialReviewText: note,
                          syncsWithCloud: true,
                          translate: tr,
                        );
                        if (draft != null) {
                          setState(() {
                            status = draft.listenStatus;
                            rating = draft.userRating;
                            note = draft.reviewText;
                          });
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('work_review_status_listened')),
        );
        await tester.pumpAndSettle();
        expect(status, WorkListenStatus.listened);

        await tester.tap(find.byKey(const ValueKey<String>('work_review_star_4')));
        await tester.pumpAndSettle();
        expect(rating, 4);

        await tester.tap(find.byKey(const ValueKey<String>('work_review_star_4')));
        await tester.pumpAndSettle();
        expect(rating, isNull);

        await tester.tap(
          find.byKey(const ValueKey<String>('work_review_note_button')),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr('work_review_sync_hint_cloud')), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('work_review_panel_star_5')),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('work_review_panel_note_input')),
          'Private impression note',
        );
        await tester.tap(find.text(tr('save')));
        await tester.pumpAndSettle();

        expect(status, WorkListenStatus.listened);
        expect(rating, 5);
        expect(note, 'Private impression note');
        expect(find.text('Private impression note'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey<String>('work_review_note_card')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(tr('work_review_clear')));
        await tester.pumpAndSettle();

        expect(status, isNull);
        expect(rating, isNull);
        expect(note, isEmpty);
      },
    );
  });
}
