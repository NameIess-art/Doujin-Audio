import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/app/application/work_smart_status_coordinator.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/features/asmr/application/asmr_account_sync_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_api_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_auth_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/features/asmr/application/asmr_remote_catalog_service.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/domain/listening_activity.dart';
import 'package:doujin_audio/features/player/domain/playback_usage.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_listening_activity_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_persistence_repository.dart';

final class _NoopTokenStore implements AsmrTokenStore {
  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> writeToken(String value) async {}

  @override
  Future<void> clearToken() async {}

  @override
  Future<Map<String, String>?> readCredentials() async => null;

  @override
  Future<void> writeCredentials(String name, String password) async {}

  @override
  Future<void> clearCredentials() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'computeWorkMainlineCoverage collapses SEあり/SEなし and WAV/MP3 dual folders',
    () {
      final tracks = <MusicTrack>[
        MusicTrack(
          path: r'C:\Work\SEあり\01_導入（SEあり）.wav',
          displayName: '01_導入（SEあり）',
          groupKey: r'C:\Work\SEあり',
          groupTitle: 'SEあり',
          groupSubtitle: '',
          isSingle: false,
          duration: const Duration(minutes: 10),
        ),
        MusicTrack(
          path: r'C:\Work\SEあり\02_耳かき（SEあり）.wav',
          displayName: '02_耳かき（SEあり）',
          groupKey: r'C:\Work\SEあり',
          groupTitle: 'SEあり',
          groupSubtitle: '',
          isSingle: false,
          duration: const Duration(minutes: 20),
        ),
        MusicTrack(
          path: r'C:\Work\SEなし\01_導入（SEなし）.mp3',
          displayName: '01_導入（SEなし）',
          groupKey: r'C:\Work\SEなし',
          groupTitle: 'SEなし',
          groupSubtitle: '',
          isSingle: false,
          duration: const Duration(minutes: 10),
          lastPlayedPosition: const Duration(minutes: 9),
        ),
        MusicTrack(
          path: r'C:\Work\SEなし\02_耳かき（SEなし）.mp3',
          displayName: '02_耳かき（SEなし）',
          groupKey: r'C:\Work\SEなし',
          groupTitle: 'SEなし',
          groupSubtitle: '',
          isSingle: false,
          duration: const Duration(minutes: 20),
          lastPlayedPosition: const Duration(minutes: 18),
        ),
      ];

      final coverage = computeWorkMainlineCoverage(tracks);
      expect(coverage.totalLogicalTracks, 2);
      expect(coverage.completedLogicalTracks, 2);
      expect(coverage.mainlineDuration, const Duration(minutes: 30));
      expect(coverage.coverageRatio, 1.0);
    },
  );

  group('WorkSmartStatusCoordinator Scheme C lifecycle', () {
    late Directory tempDir;
    late Database db;
    late AppDatabase appDatabase;
    late LibraryFacade library;
    late AsmrLibraryController asmrController;
    late PlaybackFacade playback;
    late TimerFacade timer;
    late ListeningActivityService listeningActivity;
    late WorkSmartStatusCoordinator coordinator;
    late AsmrApiService api;
    late List<PlaybackUsageBatch> pendingBatches;
    late DateTime currentNow;
    var batchCounter = 0;

    Future<void> emitUsage({
      required MusicTrack track,
      required Duration duration,
    }) async {
      batchCounter++;
      final workKey = listeningWorkKey(track);
      final dayStr =
          '${currentNow.year.toString().padLeft(4, '0')}-'
          '${currentNow.month.toString().padLeft(2, '0')}-'
          '${currentNow.day.toString().padLeft(2, '0')}';
      pendingBatches.add(
        PlaybackUsageBatch(
          id: 'batch-$batchCounter',
          days: <PlaybackUsageDay>[
            PlaybackUsageDay(
              date: dayStr,
              totalMs: duration.inMilliseconds,
              works: <PlaybackUsageWork>[
                PlaybackUsageWork(
                  key: workKey,
                  milliseconds: duration.inMilliseconds,
                  lastPlayedAtMs: currentNow.millisecondsSinceEpoch,
                  path: track.path,
                  title: track.displayName,
                  descriptor: track.toJson(),
                ),
              ],
            ),
          ],
        ),
      );
      await listeningActivity.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      await AppPreferences.init();
      tempDir = await Directory.systemTemp.createTemp('smart_status_test_');
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchemaForTest(db);
      appDatabase = AppDatabase.test(db);

      currentNow = DateTime(2026, 11, 1, 20);
      pendingBatches = <PlaybackUsageBatch>[];
      batchCounter = 0;

      final persistence = TestPersistenceRepository(database: appDatabase);
      final libraryService = LibraryService()
        ..watchedLibraries.add(tempDir.path);
      library = LibraryFacade.create(
        databaseRepository: persistence,
        service: libraryService,
      );
      playback = PlaybackFacade.create(databaseRepository: persistence);
      timer = TimerFacade.create();

      final asmrRepo = SqliteAsmrRepository(database: appDatabase);
      final prefs = AsmrPreferencesStore(repository: asmrRepo);
      api = AsmrApiService();
      final auth = AsmrAuthService(
        apiService: api,
        tokenStore: _NoopTokenStore(),
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

      listeningActivity = ListeningActivityService(
        repository: SqliteListeningActivityRepository(database: appDatabase),
        readUsage: () async => List<PlaybackUsageBatch>.of(pendingBatches),
        acknowledgeUsage: (ids) async {
          pendingBatches.removeWhere((b) => ids.contains(b.id));
        },
        resolveTrack: (path) => library.trackByPath(path),
        recordInterests: ({required batchId, required contributions}) async {},
        now: () => currentNow,
      );

      coordinator = WorkSmartStatusCoordinator(
        library: library,
        asmrLibrary: asmrController,
        listeningActivity: listeningActivity,
        playback: playback,
        timer: timer,
        readPersistedState: () => appDatabase.loadAppSetting(
          WorkSmartStatusCoordinator.persistedSettingKey,
        ),
        writePersistedState: (json) => appDatabase.saveAppSetting(
          WorkSmartStatusCoordinator.persistedSettingKey,
          json,
        ),
        now: () => currentNow,
      );
      await coordinator.initializeAndSweepStale();
    });

    tearDown(() async {
      await coordinator.dispose();
      await listeningActivity.dispose();
      asmrController.dispose();
      await timer.dispose();
      await playback.dispose();
      await library.dispose();
      api.close();
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'debounces short previews, advances marked -> listening -> listened on SEなし set, supports undo lock, and promotes listened -> replay after 3-day cooldown',
      () async {
        final prompts = <WorkAutoListenedPrompt>[];
        final sub = coordinator.autoListenedPrompts.listen(prompts.add);
        addTearDown(sub.cancel);

        final workDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}RJ888888 Work',
        );
        final seOnDir = Directory(
          '${workDir.path}${Platform.pathSeparator}SEあり',
        );
        final seOffDir = Directory(
          '${workDir.path}${Platform.pathSeparator}SEなし',
        );
        await seOnDir.create(recursive: true);
        await seOffDir.create(recursive: true);

        final seOnPath = '${seOnDir.path}${Platform.pathSeparator}01_耳かき.wav';
        final seOffPath = '${seOffDir.path}${Platform.pathSeparator}01_耳かき.mp3';
        await File(seOnPath).writeAsBytes(const <int>[1]);
        await File(seOffPath).writeAsBytes(const <int>[1]);

        final seOnTrack = MusicTrack(
          path: seOnPath,
          displayName: '01_耳かき',
          groupKey: seOnDir.path,
          groupTitle: 'SEあり',
          groupSubtitle: seOnDir.path,
          isSingle: false,
          duration: const Duration(minutes: 20),
        );
        final seOffTrack = MusicTrack(
          path: seOffPath,
          displayName: '01_耳かき',
          groupKey: seOffDir.path,
          groupTitle: 'SEなし',
          groupSubtitle: seOffDir.path,
          isSingle: false,
          duration: const Duration(minutes: 20),
        );
        library.addTracks(<MusicTrack>[seOnTrack, seOffTrack], persist: false);

        final target = AudioDetailTarget.libraryRootFolder(workDir.path);
        await library.saveAudioDetail(
          AudioDetail.empty(
            target,
          ).copyWith(rjCode: 'RJ888888', workTitle: 'Healing Ear Cleaning'),
        );
        await library.saveAudioUserReview(
          target,
          listenStatus: WorkListenStatus.marked,
          userRating: null,
          reviewText: '',
          updatedAt: currentNow.toUtc(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // 1. Short 45s preview (< 3m threshold) keeps status as `marked`.
        await emitUsage(track: seOffTrack, duration: const Duration(seconds: 45));
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.marked,
        );

        // 2. Additional 2m30s (total 3m15s >= 3m) silently advances `marked -> listening`.
        await emitUsage(
          track: seOffTrack,
          duration: const Duration(minutes: 2, seconds: 30),
        );
        final afterListening = (await library.loadAudioDetail(target)).detail;
        expect(afterListening.listenStatus, WorkListenStatus.listening);
        expect(prompts, isEmpty);
        final jsonFile = File(
          '${workDir.path}${Platform.pathSeparator}doujin-audio.json',
        );
        expect(
          (jsonDecode(await jsonFile.readAsString()) as Map)['listenStatus'],
          'listening',
        );

        // 3. Completing the SEなし track (18m/20m = 90% >= 85%, SEあり untouched!)
        //    with >= 40% audible time advances `listening -> listened` and emits prompt.
        library.updatePlaybackHistory(
          trackPath: seOffPath,
          position: const Duration(minutes: 18),
          now: currentNow,
          updatePlayedAt: true,
        );
        await emitUsage(track: seOffTrack, duration: const Duration(minutes: 7));
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.listened,
        );
        expect(prompts, hasLength(1));
        expect(prompts.single.workTitle, 'Healing Ear Cleaning');
        expect(prompts.single.previousStatus, WorkListenStatus.listening);

        // 4. Undoing the auto-listened prompt reverts to `listening` and locks against re-trigger.
        await prompts.single.onUndo();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.listening,
        );
        await emitUsage(track: seOffTrack, duration: const Duration(minutes: 5));
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.listening,
        );
        expect(prompts, hasLength(1));

        // 5. Manually marking `listened` with 5★ rating, then re-listening same day (< 3d cooldown) stays `listened`.
        await library.saveAudioUserReview(
          target,
          listenStatus: WorkListenStatus.listened,
          userRating: 5,
          reviewText: 'Great track',
          updatedAt: currentNow.toUtc(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await emitUsage(track: seOffTrack, duration: const Duration(minutes: 6));
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.listened,
        );

        // 6. After 4 days (>= 3d cooldown), 5m of new audible re-listening promotes `listened -> replay` preserving 5★ & note.
        currentNow = currentNow.add(const Duration(days: 4));
        await emitUsage(track: seOffTrack, duration: const Duration(minutes: 5));
        final replayed = (await library.loadAudioDetail(target)).detail;
        expect(replayed.listenStatus, WorkListenStatus.replay);
        expect(replayed.userRating, 5);
        expect(replayed.reviewText, 'Great track');
      },
    );

    test(
      'sweeps local and ASMR works at 15 days and restores local listening on resume',
      () async {
        final workDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}StaleWork',
        );
        await workDir.create(recursive: true);
        final trackPath = '${workDir.path}${Platform.pathSeparator}01.mp3';
        await File(trackPath).writeAsBytes(const <int>[1]);

        final lastActive = currentNow.subtract(
          const Duration(days: 14, hours: 23, minutes: 59),
        );
        final track = MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: workDir.path,
          groupTitle: 'StaleWork',
          groupSubtitle: workDir.path,
          isSingle: false,
          duration: const Duration(minutes: 30),
          lastPlayedAt: lastActive,
        );
        library.addTracks(<MusicTrack>[track], persist: false);

        final target = AudioDetailTarget.libraryRootFolder(workDir.path);
        await library.saveAudioUserReview(
          target,
          listenStatus: WorkListenStatus.listening,
          userRating: 4,
          reviewText: 'Paused halfway',
          updatedAt: lastActive.toUtc(),
        );
        await asmrController.saveWorkReview(
          AsmrWork.fromJson(const {'id': 234567, 'title': 'ASMR work'}),
          listenStatus: WorkListenStatus.listening,
          userRating: 5,
          reviewText: 'ASMR note',
          updatedAt: lastActive.toUtc(),
        );

        await coordinator.initializeAndSweepStale();
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.listening,
        );
        expect(
          asmrController.reviewedWorks.single.listenStatus,
          WorkListenStatus.listening,
        );

        currentNow = currentNow.add(const Duration(minutes: 1));
        await coordinator.initializeAndSweepStale();
        final postponed = (await library.loadAudioDetail(target)).detail;
        expect(postponed.listenStatus, WorkListenStatus.postponed);
        expect(postponed.userRating, 4);
        expect(postponed.reviewText, 'Paused halfway');
        final asmrPostponed = asmrController.reviewedWorks.single;
        expect(asmrPostponed.listenStatus, WorkListenStatus.postponed);
        expect(asmrPostponed.userRating, 5);
        expect(asmrPostponed.reviewText, 'ASMR note');

        // Resuming for >= 3m restores `postponed -> listening`.
        await emitUsage(track: track, duration: const Duration(minutes: 3));
        expect(
          (await library.loadAudioDetail(target)).detail.listenStatus,
          WorkListenStatus.listening,
        );
      },
    );
  });

  testWidgets('showAppSnackBar supports both secondary rate action and undo action', (
    tester,
  ) async {
    var rateTapped = false;
    var undoTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showAppSnackBar(
                  context,
                  '已将「测试作品」标为听过',
                  tone: AppFeedbackTone.success,
                  isUndoAction: true,
                  actionLabel: '撤销',
                  onAction: () => undoTapped = true,
                  secondaryActionLabel: '评分',
                  onSecondaryAction: () => rateTapped = true,
                );
              },
              child: const Text('Show Toast'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show Toast'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('已将「测试作品」标为听过'), findsOneWidget);
    expect(find.text('评分'), findsOneWidget);
    expect(find.textContaining('撤销'), findsOneWidget);

    await tester.tap(find.text('评分'));
    await tester.pumpAndSettle();
    expect(rateTapped, isTrue);
    expect(undoTapped, isFalse);
  });
}
