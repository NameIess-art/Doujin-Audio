import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/app/application/audio_path_coordinator.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/library/application/audio_detail_document_repository.dart';
import 'package:doujin_audio/features/library/data/audio_detail_json_codec.dart';
import 'package:doujin_audio/features/library/domain/audio_detail_store.dart';
import 'package:doujin_audio/features/library/application/library_scan_coordinator.dart';
import 'package:doujin_audio/features/library/application/library_scan_data_source.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_scanner_service.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  late AppRuntimeTestFixture fixture;
  late AppRuntimeGraph runtimeGraph;
  late PlaybackNotificationService notificationService;
  late Database db;

  setUp(() async {
    fixture = await AppRuntimeTestFixture.create();
    runtimeGraph = fixture.runtimeGraph;
    notificationService = fixture.notificationService;
    db = fixture.database;
  });

  tearDown(() async {
    await fixture.dispose(currentGraph: runtimeGraph);
  });

  test(
    'adding folders and libraries preserves every JSON file byte-for-byte',
    () async {
      const labels = LibraryScanLabels(
        chooseMusicFolder: 'folder',
        chooseLibraryFolder: 'library',
        chooseAudioFiles: 'files',
        importedFiles: 'imported',
        manuallySelectedFiles: 'selected',
      );
      final root = await Directory.systemTemp.createTemp(
        'library_scan_json_preservation_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final standalone = await Directory(
        path.join(root.path, 'standalone'),
      ).create();
      final library = await Directory(path.join(root.path, 'library')).create();
      final work = await Directory(path.join(library.path, 'work')).create();
      final dataSource = _JsonPreservationScanDataSource();
      final coordinator = LibraryScanCoordinator(
        scanner: LibraryScannerService(dataSource: dataSource),
      );
      addTearDown(coordinator.dispose);

      Future<Map<File, List<int>>> seedJsonFiles(Directory folder) async {
        final target = AudioDetailTarget.libraryRootFolder(folder.path);
        final files = <File, List<int>>{
          File(
            path.join(folder.path, audioDetailDocumentName),
          ): const AudioDetailJsonCodec().encodeNew(
            AudioDetail.empty(target).copyWith(workTitle: 'Original metadata'),
          ),
          File(path.join(folder.path, 'third-party.JSON')): utf8.encode(
            '{\r\n  "preserve": true\r\n}\r\n',
          ),
        };
        for (final entry in files.entries) {
          await entry.key.writeAsBytes(entry.value, flush: true);
        }
        return files;
      }

      Future<void> expectUnchanged(Map<File, List<int>> files) async {
        for (final entry in files.entries) {
          expect(await entry.key.readAsBytes(), entry.value);
        }
      }

      final standaloneJson = await seedJsonFiles(standalone);
      dataSource.configure(
        selectedPath: standalone.path,
        tracks: <ScannedTrack>[
          _scannedTrackForPath(path.join(standalone.path, 'track.mp3')),
        ],
      );
      await coordinator.importFolder(
        catalog: runtimeGraph.library,
        labels: labels,
      );
      await pumpEventQueue();
      await expectUnchanged(standaloneJson);

      final workJson = await seedJsonFiles(work);
      dataSource.configure(
        selectedPath: library.path,
        childFolders: <String>[work.path],
        tracks: <ScannedTrack>[
          _scannedTrackForPath(path.join(work.path, 'track.mp3')),
        ],
      );
      await coordinator.importLibrary(
        catalog: runtimeGraph.library,
        labels: labels,
      );
      await pumpEventQueue();
      await expectUnchanged(workJson);
    },
  );

  test('missing folder durations include every audio track', () async {
    final folder = await Directory.systemTemp.createTemp(
      'folder_duration_sum_',
    );
    addTearDown(() async {
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
    });
    final firstPath = path.join(folder.path, '01.mp3');
    final secondFolder = path.join(folder.path, 'disc-1');
    final thirdFolder = path.join(secondFolder, 'bonus');
    final secondPath = path.join(secondFolder, '02.flac');
    final thirdPath = path.join(thirdFolder, '03.mp4');
    final tracks = <MusicTrack>[
      MusicTrack(
        path: firstPath,
        displayName: '01',
        groupKey: folder.path,
        groupTitle: 'Work',
        groupSubtitle: folder.path,
        isSingle: false,
        duration: const Duration(minutes: 1),
      ),
      MusicTrack(
        path: secondPath,
        displayName: '02',
        groupKey: secondFolder,
        groupTitle: 'disc-1',
        groupSubtitle: secondFolder,
        isSingle: false,
      ),
      MusicTrack(
        path: thirdPath,
        displayName: '03',
        groupKey: thirdFolder,
        groupTitle: 'bonus',
        groupSubtitle: thirdFolder,
        isSingle: false,
        isVideo: true,
      ),
    ];
    runtimeGraph.library.addWatchedFolder(folder.path, notify: false);
    runtimeGraph.library.addTracks(tracks, notify: false, persist: false);

    final requestedPaths = <String>[];
    var activeDurationReads = 0;
    var peakDurationReads = 0;
    final duration = await runtimeGraph.library.calculateMissingLibraryDuration(
      folder.path,
      durationReader: (trackPath) async {
        requestedPaths.add(trackPath);
        activeDurationReads++;
        if (activeDurationReads > peakDurationReads) {
          peakDurationReads = activeDurationReads;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        activeDurationReads--;
        return trackPath == secondPath
            ? const Duration(minutes: 2)
            : const Duration(minutes: 3);
      },
    );

    expect(requestedPaths, <String>[secondPath, thirdPath]);
    expect(peakDurationReads, 2);
    expect(duration, const Duration(minutes: 6));
    expect(
      runtimeGraph.library.trackByPath(secondPath)?.duration,
      const Duration(minutes: 2),
    );
    expect(
      runtimeGraph.library.trackByPath(thirdPath)?.duration,
      const Duration(minutes: 3),
    );

    final unreadablePath = path.join(thirdFolder, '04.ogg');
    runtimeGraph.library.addTracks(
      <MusicTrack>[
        MusicTrack(
          path: unreadablePath,
          displayName: '04',
          groupKey: thirdFolder,
          groupTitle: 'bonus',
          groupSubtitle: thirdFolder,
          isSingle: false,
        ),
      ],
      notify: false,
      persist: false,
    );
    final retryPaths = <String>[];
    final incompleteDuration = await runtimeGraph.library
        .calculateMissingLibraryDuration(
          folder.path,
          durationReader: (trackPath) async {
            retryPaths.add(trackPath);
            return null;
          },
        );
    expect(retryPaths, <String>[unreadablePath]);
    expect(incompleteDuration, isNull);

    const contentRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic::Work';
    const contentTrackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic/'
        'document/primary%3AMusic%2FWork%2FDisc%2F05.m4a';
    runtimeGraph.library.addWatchedFolder(contentRoot, notify: false);
    runtimeGraph.library.addTracks(
      <MusicTrack>[
        MusicTrack(
          path: contentTrackPath,
          displayName: '05',
          groupKey: '$contentRoot/Disc',
          groupTitle: 'Disc',
          groupSubtitle: 'Work/Disc',
          isSingle: false,
        ),
      ],
      notify: false,
      persist: false,
    );
    final contentDuration = await runtimeGraph.library
        .calculateMissingLibraryDuration(
          contentRoot,
          durationReader: (trackPath) async =>
              trackPath == contentTrackPath ? const Duration(minutes: 5) : null,
        );
    expect(contentDuration, const Duration(minutes: 5));
  });

  test(
    'duration backfill keeps a richer local detail backup byte-identical',
    () async {
      final workFolder = await Directory.systemTemp.createTemp(
        'detail_duration_backup_race_',
      );
      addTearDown(() async {
        if (await workFolder.exists()) {
          await workFolder.delete(recursive: true);
        }
      });
      final trackPath = path.join(workFolder.path, '01.mp3');
      final target = AudioDetailTarget.libraryRootFolder(workFolder.path);
      runtimeGraph.library.addWatchedFolder(workFolder.path, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: workFolder.path,
            groupTitle: 'Work',
            groupSubtitle: workFolder.path,
            isSingle: false,
          ),
        ],
        notify: false,
        persist: false,
      );

      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target).copyWith(
          rjCode: 'RJ123456',
          workTitle: 'Original title',
          circleName: 'Original circle',
        ),
      );
      final backupFile = File(
        path.join(workFolder.path, audioDetailDocumentName),
      );
      final originalBackup = await backupFile.readAsString();
      final thirdPartyJson = File(
        path.join(workFolder.path, 'third-party.json'),
      );
      const originalThirdPartyJson = '{"keep":"this exact content"}\n';
      await thirdPartyJson.writeAsString(originalThirdPartyJson, flush: true);
      await db.delete('audio_details');
      await (runtimeGraph.library.databaseRepository as AudioDetailStore)
          .upsert(
            AudioDetail.empty(target).copyWith(
              createdAt: DateTime.utc(2026, 7, 26, 10),
              updatedAt: DateTime.utc(2026, 7, 26, 10, 1),
            ),
          );
      runtimeGraph.library.detailCacheService.clear();

      await runtimeGraph.library.backfillMissingLibraryDurations(
        durationReader: (_) async => const Duration(minutes: 2),
      );

      expect(await backupFile.readAsString(), originalBackup);
      expect(await thirdPartyJson.readAsString(), originalThirdPartyJson);
      expect(
        (await (runtimeGraph.library.databaseRepository as AudioDetailStore)
                .load(target))
            ?.duration,
        const Duration(minutes: 2),
      );
    },
  );

  test('missing duration is resolved for a single video file', () async {
    const videoPath = r'C:\library\standalone-video.mp4';
    runtimeGraph.library.addTracks(
      <MusicTrack>[
        MusicTrack(
          path: videoPath,
          displayName: 'standalone-video',
          groupKey: r'C:\library',
          groupTitle: 'standalone-video',
          groupSubtitle: r'C:\library',
          isSingle: true,
          isVideo: true,
        ),
      ],
      notify: false,
      persist: false,
    );

    final requestedPaths = <String>[];
    final duration = await runtimeGraph.library.calculateMissingLibraryDuration(
      videoPath.toUpperCase(),
      durationReader: (trackPath) async {
        requestedPaths.add(trackPath);
        return const Duration(minutes: 7, seconds: 12);
      },
    );

    expect(requestedPaths, const <String>[videoPath]);
    expect(duration, const Duration(minutes: 7, seconds: 12));
    expect(
      runtimeGraph.library.trackByPath(videoPath)?.duration,
      const Duration(minutes: 7, seconds: 12),
    );
  });

  test(
    'library duration backfill persists work and single details only to database',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'library_duration_backfill_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final workDir = await Directory(path.join(root.path, 'work')).create();
      final singlesDir = await Directory(
        path.join(root.path, 'singles'),
      ).create();
      final firstPath = path.join(workDir.path, '01.mp3');
      final secondPath = path.join(workDir.path, '02.flac');
      final singlePath = path.join(singlesDir.path, 'standalone.m4a');
      runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: firstPath,
            displayName: '01',
            groupKey: workDir.path,
            groupTitle: 'Work',
            groupSubtitle: workDir.path,
            isSingle: false,
          ),
          MusicTrack(
            path: secondPath,
            displayName: '02',
            groupKey: workDir.path,
            groupTitle: 'Work',
            groupSubtitle: workDir.path,
            isSingle: false,
          ),
          MusicTrack(
            path: singlePath,
            displayName: 'standalone',
            groupKey: singlesDir.path,
            groupTitle: 'standalone',
            groupSubtitle: singlesDir.path,
            isSingle: true,
          ),
        ],
        notify: false,
        persist: false,
      );

      await runtimeGraph.library.backfillMissingLibraryDurations(
        durationReader: (trackPath) async => switch (trackPath) {
          final value when value == firstPath => const Duration(minutes: 1),
          final value when value == secondPath => const Duration(minutes: 2),
          final value when value == singlePath => const Duration(seconds: 45),
          _ => null,
        },
      );

      final workTarget = AudioDetailTarget.libraryRootFolder(workDir.path);
      final singleTarget = AudioDetailTarget.singleAudioFile(singlePath);
      expect(
        (await runtimeGraph.library.loadAudioDetail(
          workTarget,
        )).detail.duration,
        const Duration(minutes: 3),
      );
      expect(
        (await runtimeGraph.library.loadAudioDetail(
          singleTarget,
        )).detail.duration,
        const Duration(seconds: 45),
      );

      final databaseRows = await db.query(
        'audio_details',
        columns: <String>['target_path', 'duration_ms'],
      );
      expect(
        databaseRows,
        contains(
          isA<Map<String, Object?>>()
              .having((row) => row['target_path'], 'target path', workDir.path)
              .having(
                (row) => row['duration_ms'],
                'duration',
                const Duration(minutes: 3).inMilliseconds,
              ),
        ),
      );
      expect(
        databaseRows,
        contains(
          isA<Map<String, Object?>>()
              .having((row) => row['target_path'], 'target path', singlePath)
              .having(
                (row) => row['duration_ms'],
                'duration',
                const Duration(seconds: 45).inMilliseconds,
              ),
        ),
      );

      expect(
        await File(path.join(workDir.path, audioDetailDocumentName)).exists(),
        isFalse,
      );
      expect(
        await File(
          path.join(singlesDir.path, audioDetailDocumentName),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'duration backfill fills track data without overwriting work duration',
    () async {
      final workDir = await Directory.systemTemp.createTemp(
        'library_duration_existing_detail_',
      );
      addTearDown(() async {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      });
      final trackPath = path.join(workDir.path, '01.mp3');
      runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: workDir.path,
            groupTitle: 'Work',
            groupSubtitle: workDir.path,
            isSingle: false,
          ),
        ],
        notify: false,
        persist: false,
      );
      final target = AudioDetailTarget.libraryRootFolder(workDir.path);
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(
          target,
        ).copyWith(duration: const Duration(minutes: 9)),
      );

      final requestedPaths = <String>[];
      await runtimeGraph.library.backfillMissingLibraryDurations(
        durationReader: (path) async {
          requestedPaths.add(path);
          return const Duration(minutes: 2);
        },
      );

      expect(requestedPaths, <String>[trackPath]);
      expect(
        runtimeGraph.library.trackByPath(trackPath)?.duration,
        const Duration(minutes: 2),
      );
      expect(
        (await runtimeGraph.library.loadAudioDetail(target)).detail.duration,
        const Duration(minutes: 9),
      );
    },
  );

  test(
    'missing-only detail import skips JSON when database detail exists',
    () async {
      final workDir = await Directory.systemTemp.createTemp(
        'library_detail_import_skip_',
      );
      addTearDown(() async {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      });
      final trackPath = path.join(workDir.path, '01.mp3');
      final target = AudioDetailTarget.libraryRootFolder(workDir.path);
      runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: workDir.path,
            groupTitle: 'Work',
            groupSubtitle: workDir.path,
            isSingle: false,
          ),
        ],
        notify: false,
        persist: false,
      );
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target).copyWith(workTitle: 'Database title'),
      );
      await File(
        path.join(workDir.path, audioDetailDocumentName),
      ).writeAsString('{invalid json');
      runtimeGraph.library.detailCacheService.clear();

      final result = await runtimeGraph.library.importAudioDetailBackups(
        onlyMissing: true,
      );

      expect(result.importedCount, 0);
      expect(result.failureCount, 0);
      expect(
        (await runtimeGraph.library.loadAudioDetail(target)).detail.workTitle,
        'Database title',
      );
    },
  );

  test(
    'missing-only detail import restores an absent database detail',
    () async {
      final workDir = await Directory.systemTemp.createTemp(
        'library_detail_import_missing_',
      );
      addTearDown(() async {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      });
      final trackPath = path.join(workDir.path, '01.mp3');
      final target = AudioDetailTarget.libraryRootFolder(workDir.path);
      runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: workDir.path,
            groupTitle: 'Work',
            groupSubtitle: workDir.path,
            isSingle: false,
          ),
        ],
        notify: false,
        persist: false,
      );
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(target).copyWith(workTitle: 'Backup title'),
      );
      await db.delete('audio_details');
      runtimeGraph.library.detailCacheService.clear();

      final result = await runtimeGraph.library.importAudioDetailBackups(
        onlyMissing: true,
      );

      expect(result.importedCount, 1);
      expect(
        (await runtimeGraph.library.loadAudioDetail(target)).detail.workTitle,
        'Backup title',
      );
    },
  );

  test('persisted state reset clears cached audio details', () async {
    final workDir = await Directory.systemTemp.createTemp(
      'library_detail_restore_cache_',
    );
    addTearDown(() async {
      if (await workDir.exists()) await workDir.delete(recursive: true);
    });
    final target = AudioDetailTarget.libraryRootFolder(workDir.path);
    await runtimeGraph.library.saveAudioDetail(
      AudioDetail.empty(target).copyWith(workTitle: 'Before restore'),
    );
    expect(
      (await runtimeGraph.library.loadAudioDetail(target)).detail.workTitle,
      'Before restore',
    );
    await (runtimeGraph.library.databaseRepository as AudioDetailStore).upsert(
      AudioDetail.empty(target).copyWith(
        workTitle: 'Restored database title',
        createdAt: DateTime.utc(2100),
        updatedAt: DateTime.utc(2100),
      ),
    );

    await runtimeGraph.library.resetPersistedState();
    final reloaded = await runtimeGraph.library.loadAudioDetail(target);

    expect(reloaded.detail.workTitle, 'Restored database title');
  });

  test('persisted state reset cancels stale duration detail writes', () async {
    final workDir = await Directory.systemTemp.createTemp(
      'library_detail_restore_race_',
    );
    addTearDown(() async {
      if (await workDir.exists()) await workDir.delete(recursive: true);
    });
    final target = AudioDetailTarget.libraryRootFolder(workDir.path);
    final trackPath = path.join(workDir.path, '01.mp3');
    runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
    runtimeGraph.library.addTracks(
      <MusicTrack>[
        MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: workDir.path,
          groupTitle: 'Work',
          groupSubtitle: workDir.path,
          isSingle: false,
        ),
      ],
      notify: false,
      persist: false,
    );
    await runtimeGraph.library.saveAudioDetail(
      AudioDetail.empty(target).copyWith(workTitle: 'Before restore'),
    );
    final durationReadStarted = Completer<void>();
    final releaseDurationRead = Completer<void>();
    final backfill = runtimeGraph.library.backfillMissingLibraryDurations(
      durationReader: (_) async {
        durationReadStarted.complete();
        await releaseDurationRead.future;
        return const Duration(minutes: 5);
      },
    );
    await durationReadStarted.future;

    await runtimeGraph.library.resetPersistedState();
    await (runtimeGraph.library.databaseRepository as AudioDetailStore).upsert(
      AudioDetail.empty(target).copyWith(
        workTitle: 'Restored database title',
        createdAt: DateTime.utc(2100),
        updatedAt: DateTime.utc(2100),
      ),
    );
    releaseDurationRead.complete();
    await backfill;

    final persisted =
        await (runtimeGraph.library.databaseRepository as AudioDetailStore)
            .load(target);
    expect(persisted?.workTitle, 'Restored database title');
    expect(persisted?.duration, isNull);
    expect(runtimeGraph.library.trackByPath(trackPath), isNull);
    expect(
      (await runtimeGraph.library.databaseRepository.loadAllTracks()).where(
        (track) => track.path == trackPath,
      ),
      isEmpty,
    );
  });

  // 鈹€鈹€ multi-session playback stability 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  group('library folder restore', () {
    test('scan generations reject stale progress and stale completion', () {
      final first = runtimeGraph.library.tryBeginScan(source: '/music/first');
      expect(first, greaterThan(0));
      expect(runtimeGraph.library.tryBeginScan(source: '/music/second'), 0);

      runtimeGraph.library.setScanProgress(
        generation: first + 1,
        foundCount: 99,
        stage: FolderScanStage.enumerating,
      );
      expect(runtimeGraph.library.scanFoundCount, 0);

      runtimeGraph.library.cancelScan();
      final second = runtimeGraph.library.tryBeginScan(source: '/music/second');
      expect(second, greaterThan(first));
      runtimeGraph.library.finishScan(first);
      expect(runtimeGraph.library.isScanGenerationActive(second), isTrue);

      runtimeGraph.library.finishScan(second);
      expect(runtimeGraph.library.isScanning, isFalse);
    });

    test(
      'background scan progress does not notify visible library UI',
      () async {
        final facade = runtimeGraph.library;
        var stateCount = 0;
        final subscription = facade.states.listen((_) => stateCount++);
        addTearDown(subscription.cancel);

        final backgroundGeneration = facade.tryBeginScan(
          source: 'background-folder',
          background: true,
        );
        await Future<void>.delayed(Duration.zero);
        final afterBackgroundStart = stateCount;

        facade.setScanProgress(
          generation: backgroundGeneration,
          currentFolder: 'background-folder',
          foundCount: 1,
          duplicateCount: 2,
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(stateCount, afterBackgroundStart);

        facade.finishScan(backgroundGeneration);
        final foregroundGeneration = facade.tryBeginScan(
          source: 'foreground-folder',
        );
        await Future<void>.delayed(Duration.zero);
        final afterForegroundStart = stateCount;

        facade.setScanProgress(
          generation: foregroundGeneration,
          currentFolder: 'foreground-folder',
          foundCount: 3,
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(stateCount, greaterThan(afterForegroundStart));

        facade.finishScan(foregroundGeneration);
      },
    );

    test(
      'background refresh commits changed tracks once after batch',
      () async {
        var notificationCount = 0;
        final subscription = runtimeGraph.library.states.listen((_) {
          notificationCount++;
        });
        addTearDown(subscription.cancel);

        final generation = runtimeGraph.library.tryBeginScan(
          source: 'background-folder',
          background: true,
        );
        await Future<void>.delayed(Duration.zero);
        final afterScanStart = notificationCount;
        runtimeGraph.library.beginLibraryBatch();
        runtimeGraph.library.addOrReplaceTracks(
          <MusicTrack>[
            MusicTrack(
              path: '/library/work/new.mp3',
              displayName: 'new',
              groupKey: '/library/work',
              groupTitle: 'work',
              groupSubtitle: '/library/work',
              isSingle: false,
            ),
          ],
          notify: false,
          persist: false,
        );
        runtimeGraph.library.setScanProgress(
          currentFolder: 'background-folder',
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(notificationCount, afterScanStart);

        await runtimeGraph.library.endLibraryBatch();
        await Future<void>.delayed(Duration.zero);
        runtimeGraph.library.finishScan(generation);

        expect(notificationCount, greaterThan(afterScanStart));
      },
    );

    test('library entry persistence is deferred until batch close', () async {
      await runtimeGraph.runtime.dispose();
      final countingRepository = _CountingTestPersistenceRepository(
        AppDatabase.test(db),
      );
      runtimeGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        persistenceRepository: countingRepository,
        skipPersistence: false,
      );

      const libraryPath = '/library/root';
      const trackPath = '/library/root/work/01.mp3';
      final firstTrack = MusicTrack(
        path: trackPath,
        displayName: '01',
        groupKey: '/library/root/work',
        groupTitle: 'work',
        groupSubtitle: '/library/root/work',
        isSingle: false,
        scannedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final renamedTrack = MusicTrack(
        path: trackPath,
        displayName: '01 renamed',
        groupKey: '/library/root/work',
        groupTitle: 'work',
        groupSubtitle: '/library/root/work',
        isSingle: false,
        scannedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );

      runtimeGraph.library.beginLibraryBatch();
      runtimeGraph.library.recordLibraryEntriesForTracks(
        libraryPath,
        <MusicTrack>[firstTrack],
      );
      runtimeGraph.library.recordLibraryEntriesForTracks(
        libraryPath,
        <MusicTrack>[renamedTrack],
      );

      expect(
        runtimeGraph.library.libraryEntriesForLibrary(libraryPath),
        isNotEmpty,
      );
      expect(countingRepository.upsertLibraryEntriesCallCount, 0);
      expect(await db.query('library_entries'), isEmpty);

      await runtimeGraph.library.endLibraryBatch();

      expect(countingRepository.upsertLibraryEntriesCallCount, 1);
      final rows = await db.query(
        'library_entries',
        where: 'kind = ?',
        whereArgs: [LibraryEntryKind.track.dbValue],
      );
      expect(rows, hasLength(1));
      expect(rows.single['display_name'], '01 renamed');
    });

    test(
      'unchanged watched folder refresh keeps library revision stable',
      () async {
        final folder = await Directory.systemTemp.createTemp(
          'library_noop_refresh_',
        );
        addTearDown(() async {
          if (await folder.exists()) {
            await folder.delete(recursive: true);
          }
        });

        final trackPath = '${folder.path}${Platform.pathSeparator}01.mp3';
        await File(trackPath).writeAsBytes(const <int>[1, 2, 3]);

        final normalizedFolderPath = path.normalize(folder.path);
        final track = MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: normalizedFolderPath,
          groupTitle: path.basename(normalizedFolderPath),
          groupSubtitle: normalizedFolderPath,
          isSingle: false,
          fileSizeBytes: 3,
          modifiedAt: (await File(trackPath).stat()).modified,
        );
        runtimeGraph.library.addWatchedFolder(
          normalizedFolderPath,
          notify: false,
        );
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        runtimeGraph.library.recordLibraryEntriesForTracks(
          normalizedFolderPath,
          <MusicTrack>[track],
          persist: false,
        );
        for (
          var i = 0;
          i < 100 && runtimeGraph.library.libraryTree.isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(runtimeGraph.library.libraryTree, isNotEmpty);

        final beforeRevision = runtimeGraph.library.contentRevision;
        final scanner = LibraryScannerService();
        await scanner.refreshWatchedFolders(
          provider: runtimeGraph.library,
          labels: const LibraryScanLabels(
            chooseMusicFolder: 'Choose music folder',
            chooseLibraryFolder: 'Choose library folder',
            chooseAudioFiles: 'Choose audio files',
            importedFiles: 'Imported Files',
            manuallySelectedFiles: 'Manually Selected Files',
          ),
        );

        final refreshedTrack = runtimeGraph.library.trackByPath(trackPath);
        expect(
          refreshedTrack,
          same(track),
          reason: 'before=${track.toJson()} after=${refreshedTrack?.toJson()}',
        );
        expect(runtimeGraph.library.contentRevision, beforeRevision);
      },
    );

    test('addOrReplaceTracks ignores unchanged rescan metadata', () async {
      final initialModifiedAt = DateTime.fromMillisecondsSinceEpoch(1000);
      final initialScannedAt = DateTime.fromMillisecondsSinceEpoch(2000);
      final refreshedScannedAt = DateTime.fromMillisecondsSinceEpoch(3000);
      const trackPath = '/library/work/01.mp3';

      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: '/library/work',
            groupTitle: 'work',
            groupSubtitle: '/library/work',
            isSingle: false,
            scannedAt: initialScannedAt,
            fileSizeBytes: 123,
            modifiedAt: initialModifiedAt,
          ),
        ],
        notify: false,
        persist: false,
      );

      final beforeRefresh = runtimeGraph.library.library.single;
      var notificationCount = 0;
      final subscription = runtimeGraph.library.states.listen((_) {
        notificationCount++;
      });
      addTearDown(subscription.cancel);

      runtimeGraph.library.addOrReplaceTracks(<MusicTrack>[
        MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: '/library/work',
          groupTitle: 'work',
          groupSubtitle: '/library/work',
          isSingle: false,
          scannedAt: refreshedScannedAt,
          fileSizeBytes: 123,
          modifiedAt: initialModifiedAt,
        ),
      ], persist: false);

      expect(notificationCount, 0);
      expect(runtimeGraph.library.library.single, same(beforeRefresh));

      runtimeGraph.library.addOrReplaceTracks(<MusicTrack>[
        MusicTrack(
          path: trackPath,
          displayName: '01 renamed',
          groupKey: '/library/work',
          groupTitle: 'work',
          groupSubtitle: '/library/work',
          isSingle: false,
          scannedAt: refreshedScannedAt,
          fileSizeBytes: 123,
          modifiedAt: initialModifiedAt,
        ),
      ], persist: false);
      await Future<void>.delayed(Duration.zero);

      expect(notificationCount, 1);
      expect(runtimeGraph.library.library.single.displayName, '01 renamed');
    });

    test('folder rescan prunes tracks and entries deleted from disk', () async {
      final libraryRoot = await Directory.systemTemp.createTemp(
        'library_prune_',
      );
      addTearDown(() async {
        if (await libraryRoot.exists()) {
          await libraryRoot.delete(recursive: true);
        }
      });

      final keptPath = '${libraryRoot.path}${Platform.pathSeparator}kept.mp3';
      final keptFolderPath =
          '${libraryRoot.path}${Platform.pathSeparator}kept_folder';
      final deletedFolderPath =
          '${libraryRoot.path}${Platform.pathSeparator}deleted_folder';
      final deletedPath =
          '$deletedFolderPath${Platform.pathSeparator}deleted.mp3';

      runtimeGraph.library.addWatchedLibrary(libraryRoot.path, notify: false);
      runtimeGraph.library.recordLibraryEntriesForTracks(
        libraryRoot.path,
        const <MusicTrack>[],
        folderPaths: <String>[keptFolderPath, deletedFolderPath],
        persist: false,
      );
      runtimeGraph.library.addTracks(<MusicTrack>[
        MusicTrack(
          path: keptPath,
          displayName: 'kept',
          groupKey: libraryRoot.path,
          groupTitle: 'library',
          groupSubtitle: libraryRoot.path,
          isSingle: false,
        ),
        MusicTrack(
          path: deletedPath,
          displayName: 'deleted',
          groupKey: libraryRoot.path,
          groupTitle: 'library',
          groupSubtitle: libraryRoot.path,
          isSingle: false,
        ),
      ], notify: false);

      runtimeGraph.library.removeTracksDeletedFromFolder(libraryRoot.path, {
        keptPath,
      });
      runtimeGraph.library.removeLibraryEntriesDeletedFromFolder(
        libraryRoot.path,
        libraryRoot.path,
        {keptPath, keptFolderPath},
      );

      expect(runtimeGraph.library.trackByPath(keptPath), isNotNull);
      expect(runtimeGraph.library.trackByPath(deletedPath), isNull);
      expect(
        runtimeGraph.library
            .libraryEntriesForLibrary(libraryRoot.path)
            .where((entry) => entry.path == deletedPath),
        isEmpty,
      );
      expect(
        runtimeGraph.library
            .libraryEntriesForLibrary(libraryRoot.path)
            .where((entry) => entry.path == deletedFolderPath),
        isEmpty,
      );
      expect(
        runtimeGraph.library
            .libraryEntriesForLibrary(libraryRoot.path)
            .where((entry) => entry.path == keptFolderPath),
        hasLength(1),
      );
    });

    test('content folder exclusion stores the canonical library child path',
        () async {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR';
      const childFolder = '$libraryRoot/document/primary%3AASMR%2FWorkA';
      const syntheticChildFolder = '$libraryRoot::WorkA';
      const trackPath =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2F01.mp3';

      runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
      runtimeGraph.library.addWatchedFolder(childFolder, notify: false);
      runtimeGraph.library.addTracks(<MusicTrack>[
        MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: syntheticChildFolder,
          groupTitle: 'WorkA',
          groupSubtitle: syntheticChildFolder,
          isSingle: false,
        ),
      ], notify: false);

      final result = await runtimeGraph.library.removeFolder(childFolder);

      expect(result, LibraryRemovalKind.libraryFolderRecoverable);
      expect(
        runtimeGraph.library.excludedFoldersForLibrary(libraryRoot),
        <String>[syntheticChildFolder],
      );
      expect(
        runtimeGraph.library
            .libraryEntriesForLibrary(libraryRoot)
            .where((entry) => entry.path == syntheticChildFolder),
        hasLength(1),
      );
      expect(
        runtimeGraph.library
            .libraryEntriesForLibrary(libraryRoot)
            .where((entry) => entry.path == syntheticChildFolder)
            .single
            .isExcluded,
        isTrue,
      );
    });

    group('unified removal routing', () {
      MusicTrack track({
        required String path,
        required String groupKey,
        bool isSingle = false,
      }) {
        return MusicTrack(
          path: path,
          displayName: '01',
          groupKey: groupKey,
          groupTitle: 'work',
          groupSubtitle: groupKey,
          isSingle: isSingle,
        );
      }

      test('permanently removes a standalone audio file', () async {
        final audio = track(
          path: '/single/01.mp3',
          groupKey: '__single_files__',
          isSingle: true,
        );
        runtimeGraph.library.addTracks(
          <MusicTrack>[audio],
          notify: false,
          persist: false,
        );

        final result = await runtimeGraph.library.removeTrack(audio.path);

        expect(result, LibraryRemovalKind.standaloneAudioPermanent);
        expect(runtimeGraph.library.trackByPath(audio.path), isNull);
        expect(
          runtimeGraph.library.excludedTracksForLibrary('/single'),
          isEmpty,
        );
      });

      test('permanently removes a standalone folder source', () async {
        const folderPath = '/standalone/work';
        final audio = track(path: '$folderPath/01.mp3', groupKey: folderPath);
        runtimeGraph.library
          ..addWatchedFolder(folderPath, notify: false)
          ..addTracks(<MusicTrack>[audio], notify: false, persist: false);

        final result = await runtimeGraph.library.removeFolder(folderPath);

        expect(result, LibraryRemovalKind.standaloneFolderPermanent);
        expect(runtimeGraph.library.watchedFolders, isEmpty);
        expect(runtimeGraph.library.trackByPath(audio.path), isNull);
      });

      test('keeps standalone folder audio removed until reimport', () async {
        const folderPath = '/standalone/work';
        final audio = track(path: '$folderPath/01.mp3', groupKey: folderPath);
        runtimeGraph.library
          ..addWatchedFolder(folderPath, notify: false)
          ..addTracks(<MusicTrack>[audio], notify: false, persist: false);

        final result = await runtimeGraph.library.removeTrack(audio.path);
        await pumpEventQueue();

        expect(result, LibraryRemovalKind.folderAudioPermanent);
        expect(
          runtimeGraph.library.excludedTracksForLibrary(folderPath),
          <String>[path.normalize(audio.path)],
        );
        expect(runtimeGraph.library.trackByPath(audio.path), isNull);

        runtimeGraph.library.clearLibraryExclusions(folderPath);
        await pumpEventQueue();
        expect(runtimeGraph.library.trackByPath(audio.path), isNotNull);
      });

      test('permanently removes a library root', () async {
        const libraryPath = '/library';
        const folderPath = '$libraryPath/work';
        final audio = track(path: '$folderPath/01.mp3', groupKey: folderPath);
        runtimeGraph.library
          ..addWatchedLibrary(libraryPath, notify: false)
          ..addWatchedFolder(folderPath, notify: false)
          ..addTracks(<MusicTrack>[audio], notify: false, persist: false);

        final result = await runtimeGraph.library.removeFolder(libraryPath);

        expect(result, LibraryRemovalKind.libraryPermanent);
        expect(runtimeGraph.library.watchedLibraries, isEmpty);
        expect(runtimeGraph.library.watchedFolders, isEmpty);
        expect(runtimeGraph.library.trackByPath(audio.path), isNull);
      });

      test('excludes and restores a library child folder', () async {
        const libraryPath = '/library';
        const folderPath = '$libraryPath/work';
        final audio = track(path: '$folderPath/01.mp3', groupKey: folderPath);
        runtimeGraph.library
          ..addWatchedLibrary(libraryPath, notify: false)
          ..addWatchedFolder(folderPath, notify: false)
          ..recordLibraryEntriesForTracks(
            libraryPath,
            <MusicTrack>[audio],
            folderPaths: const <String>[folderPath],
            persist: false,
          )
          ..addTracks(<MusicTrack>[audio], notify: false, persist: false);

        final result = await runtimeGraph.library.removeFolder(folderPath);
        await pumpEventQueue();

        expect(result, LibraryRemovalKind.libraryFolderRecoverable);
        expect(
          runtimeGraph.library.excludedFoldersForLibrary(libraryPath),
          <String>[path.normalize(folderPath)],
        );
        expect(runtimeGraph.library.trackByPath(audio.path), isNull);

        runtimeGraph.library.setLibraryFolderExcluded(
          libraryPath,
          folderPath,
          false,
        );
        await pumpEventQueue();
        expect(runtimeGraph.library.trackByPath(audio.path), isNotNull);
      });

      test('excludes and restores a library audio item', () async {
        const libraryPath = '/library';
        const folderPath = '$libraryPath/work';
        final audio = track(path: '$folderPath/01.mp3', groupKey: folderPath);
        runtimeGraph.library
          ..addWatchedLibrary(libraryPath, notify: false)
          ..recordLibraryEntriesForTracks(
            libraryPath,
            <MusicTrack>[audio],
            folderPaths: const <String>[folderPath],
            persist: false,
          )
          ..addTracks(<MusicTrack>[audio], notify: false, persist: false);

        final result = await runtimeGraph.library.removeTrack(audio.path);
        await pumpEventQueue();

        expect(result, LibraryRemovalKind.libraryAudioRecoverable);
        expect(
          runtimeGraph.library.excludedTracksForLibrary(libraryPath),
          <String>[path.normalize(audio.path)],
        );
        expect(runtimeGraph.library.trackByPath(audio.path), isNull);

        runtimeGraph.library.setLibraryTrackExcluded(
          libraryPath,
          audio.path,
          false,
        );
        await pumpEventQueue();
        expect(runtimeGraph.library.trackByPath(audio.path), isNotNull);
      });
    });

    test('legacy removed folders migrate to recoverable exclusions', () async {
      const libraryPath = '/legacy-library';
      const folderPath = '$libraryPath/work';
      addTearDown(() async {
        await AppPreferences.remove('removed_library_folders_v1');
        await AppPreferences.remove('library_exclusions_v1');
        await AppPreferences.remove('watched_libraries_v1');
      });
      await AppPreferences.setString(
        'watched_libraries_v1',
        json.encode(<String>[libraryPath]),
      );
      await AppPreferences.setString(
        'removed_library_folders_v1',
        json.encode(<String, List<String>>{
          libraryPath: <String>[folderPath],
        }),
      );

      await runtimeGraph.library.loadPersistedState();

      expect(
        runtimeGraph.library.excludedFoldersForLibrary(libraryPath),
        <String>[path.normalize(folderPath)],
      );
      expect(
        await AppPreferences.getString('removed_library_folders_v1'),
        isNull,
      );
      final exclusions =
          json.decode(
                (await AppPreferences.getString('library_exclusions_v1'))!,
              )
              as Map<String, dynamic>;
      expect(
        ((exclusions['folders'] as Map<String, dynamic>)[path.normalize(
                  libraryPath,
                )]
                as List)
            .cast<String>(),
        <String>[path.normalize(folderPath)],
      );
    });

    test('track removal waits for its persistent cleanup', () async {
      await runtimeGraph.runtime.dispose();
      final repository = _BlockingDeletionTestPersistenceRepository(
        AppDatabase.test(db),
      );
      addTearDown(repository.releaseAndWait);
      runtimeGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        persistenceRepository: repository,
        jsonDocumentStore: TestJsonDocumentStore(),
        skipPersistence: false,
      );

      final track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'work',
        groupSubtitle: '/library/work',
        isSingle: false,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await repository.upsertTracks(<MusicTrack>[track]);

      final removal = runtimeGraph.library.removeTrack(track.path);
      var completed = false;
      unawaited(removal.then((_) => completed = true));
      await repository.trackDeletionStarted;
      await Future<void>.delayed(Duration.zero);

      expect(runtimeGraph.library.trackByPath(track.path), isNull);
      expect(completed, isFalse);

      repository.releaseTrackDeletion();
      await removal;

      expect(await db.query('tracks'), isEmpty);
      expect(
        json.decode((await AppPreferences.getString('group_order_v1'))!),
        <Object?>[],
      );
    });

    test('folder removal waits for all persistent cleanup', () async {
      await runtimeGraph.runtime.dispose();
      final repository = _BlockingDeletionTestPersistenceRepository(
        AppDatabase.test(db),
      );
      addTearDown(repository.releaseAndWait);
      runtimeGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        persistenceRepository: repository,
        jsonDocumentStore: TestJsonDocumentStore(),
        skipPersistence: false,
      );

      const folderPath = '/library/work';
      final track = MusicTrack(
        path: '$folderPath/01.mp3',
        displayName: '01',
        groupKey: folderPath,
        groupTitle: 'work',
        groupSubtitle: folderPath,
        isSingle: false,
      );
      final detailTarget = AudioDetailTarget.libraryRootFolder(folderPath);
      runtimeGraph.library
        ..addWatchedFolder(folderPath, notify: false)
        ..recordLibraryEntriesForTracks(folderPath, <MusicTrack>[
          track,
        ], persist: false)
        ..addTracks(<MusicTrack>[track], notify: false, persist: false);
      await repository.upsertTracks(<MusicTrack>[track]);
      await repository.upsertLibraryEntries(
        runtimeGraph.library.libraryEntriesForLibrary(folderPath),
      );
      await runtimeGraph.library.saveAudioDetail(
        AudioDetail.empty(detailTarget),
      );

      final removal = runtimeGraph.library.removeFolder(folderPath);
      var completed = false;
      unawaited(removal.then((_) => completed = true));
      await repository.trackDeletionStarted;
      await repository.libraryEntryDeletionCompleted;
      await Future<void>.delayed(Duration.zero);

      expect(runtimeGraph.library.trackByPath(track.path), isNull);
      expect(runtimeGraph.library.watchedFolders, isEmpty);
      expect(completed, isFalse);

      repository.releaseTrackDeletion();
      await removal;

      expect(await db.query('tracks'), isEmpty);
      expect(await db.query('library_entries'), isEmpty);
      expect(await db.query('audio_details'), isEmpty);
      expect(
        json.decode((await AppPreferences.getString('watched_folders_v1'))!),
        <Object?>[],
      );
    });

    test('library removal waits for its whole persistent cleanup', () async {
      await runtimeGraph.runtime.dispose();
      final repository = _BlockingDeletionTestPersistenceRepository(
        AppDatabase.test(db),
      );
      addTearDown(repository.releaseAndWait);
      runtimeGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        persistenceRepository: repository,
        jsonDocumentStore: TestJsonDocumentStore(),
        skipPersistence: false,
      );

      const libraryPath = '/library';
      const workPath = '$libraryPath/work';
      const excludedPath = '$libraryPath/excluded';
      final track = MusicTrack(
        path: '$workPath/01.mp3',
        displayName: '01',
        groupKey: workPath,
        groupTitle: 'work',
        groupSubtitle: workPath,
        isSingle: false,
      );
      final rootDetail = AudioDetailTarget.libraryRootFolder(libraryPath);
      final workDetail = AudioDetailTarget.libraryRootFolder(workPath);
      runtimeGraph.library
        ..addWatchedLibrary(libraryPath, notify: false)
        ..addWatchedFolder(workPath, notify: false)
        ..setLibraryFolderExcluded(libraryPath, excludedPath, true)
        ..recordLibraryEntriesForTracks(
          libraryPath,
          <MusicTrack>[track],
          folderPaths: const <String>[workPath],
          persist: false,
        )
        ..addTracks(<MusicTrack>[track], notify: false, persist: false);
      await repository.upsertTracks(<MusicTrack>[track]);
      await repository.upsertLibraryEntries(
        runtimeGraph.library.libraryEntriesForLibrary(libraryPath),
      );
      await runtimeGraph.library.saveAudioDetail(AudioDetail.empty(rootDetail));
      await runtimeGraph.library.saveAudioDetail(AudioDetail.empty(workDetail));

      final removal = runtimeGraph.library.removeFolder(libraryPath);
      var completed = false;
      unawaited(removal.then((_) => completed = true));
      await repository.trackDeletionStarted;
      await Future<void>.delayed(Duration.zero);

      expect(runtimeGraph.library.watchedLibraries, isEmpty);
      expect(runtimeGraph.library.watchedFolders, isEmpty);
      expect(runtimeGraph.library.trackByPath(track.path), isNull);
      expect(
        runtimeGraph.library.libraryEntriesForLibrary(libraryPath),
        isEmpty,
      );
      expect(completed, isFalse);

      repository.releaseTrackDeletion();
      await removal;

      expect(await db.query('tracks'), isEmpty);
      expect(await db.query('library_entries'), isEmpty);
      expect(await db.query('audio_details'), isEmpty);
      expect(
        json.decode((await AppPreferences.getString('watched_folders_v1'))!),
        <Object?>[],
      );
      expect(
        json.decode((await AppPreferences.getString('watched_libraries_v1'))!),
        <Object?>[],
      );
      expect(
        json.decode((await AppPreferences.getString('library_exclusions_v1'))!)
            as Map<String, Object?>,
        <String, Object?>{
          'folders': <String, Object?>{},
          'tracks': <String, Object?>{},
        },
      );
    });

    test('same work uses a first-level folder inside the audio library', () {
      const libraryRoot = 'C:\\Audio\\Library';
      const workRoot = '$libraryRoot\\Work A';
      const firstFolder = '$workRoot\\Disc 1';
      const secondFolder = '$workRoot\\Disc 2';
      const outsideFolder = '$libraryRoot\\Work B';
      const firstPath = '$firstFolder\\01.mp3';
      const secondPath = '$secondFolder\\02.mp3';
      const outsidePath = '$outsideFolder\\03.mp3';

      runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
      runtimeGraph.library.addTracks(<MusicTrack>[
        MusicTrack(
          path: firstPath,
          displayName: '01',
          groupKey: firstFolder,
          groupTitle: 'Disc 1',
          groupSubtitle: firstFolder,
          isSingle: false,
        ),
        MusicTrack(
          path: secondPath,
          displayName: '02',
          groupKey: secondFolder,
          groupTitle: 'Disc 2',
          groupSubtitle: secondFolder,
          isSingle: false,
        ),
        MusicTrack(
          path: outsidePath,
          displayName: '03',
          groupKey: outsideFolder,
          groupTitle: 'Other',
          groupSubtitle: outsideFolder,
          isSingle: false,
        ),
      ], notify: false);

      final paths = AudioPathCoordinator(
        library: runtimeGraph.library,
        playback: runtimeGraph.playback,
      );

      expect(
        paths.tracksInSameWork(firstPath).map((track) => track.path).toSet(),
        <String>{firstPath, secondPath},
      );
      expect(paths.workRootForTrack(firstPath), workRoot);
      expect(paths.rootFolderName(firstPath), 'Work A');
    });

    test('cross-folder loop stays inside the current work root', () async {
      const libraryRoot = 'C:\\Audio\\Library';
      const workRoot = '$libraryRoot\\Work A';
      const firstPath = '$workRoot\\Disc 1\\01.mp3';
      const secondPath = '$workRoot\\Disc 2\\02.mp3';
      const outsidePath = '$libraryRoot\\Work B\\03.mp3';
      final preparedQueues = <List<String>>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.prepareSession) {
              final arguments = Map<String, Object?>.from(
                call.arguments as Map<Object?, Object?>,
              );
              final queue = (arguments['queue'] as List<dynamic>? ?? const [])
                  .whereType<Map<Object?, Object?>>()
                  .map((item) => item['path'] as String)
                  .toList(growable: false);
              preparedQueues.add(queue);
            }
            return <String, Object?>{'ok': true, 'value': null};
          });

      runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
      runtimeGraph.library.addTracks(<MusicTrack>[
        MusicTrack(
          path: firstPath,
          displayName: '01',
          groupKey: '$workRoot\\Disc 1',
          groupTitle: 'Disc 1',
          groupSubtitle: '$workRoot\\Disc 1',
          isSingle: false,
        ),
        MusicTrack(
          path: secondPath,
          displayName: '02',
          groupKey: '$workRoot\\Disc 2',
          groupTitle: 'Disc 2',
          groupSubtitle: '$workRoot\\Disc 2',
          isSingle: false,
        ),
        MusicTrack(
          path: outsidePath,
          displayName: '03',
          groupKey: '$libraryRoot\\Work B',
          groupTitle: 'Work B',
          groupSubtitle: '$libraryRoot\\Work B',
          isSingle: false,
        ),
      ], notify: false);

      await runtimeGraph.playback.spawnSession(
        runtimeGraph.library.trackByPath(secondPath)!,
        autoPlay: false,
      );
      final session = runtimeGraph.playback.activeSessions.single;
      for (var i = 0; i < 50 && session.isLoading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await runtimeGraph.playback.setSessionLoopMode(
        session.id,
        SessionLoopMode.crossSequential,
      );
      await runtimeGraph.playback.seekSessionToNext(session.id);

      expect(session.currentTrackPath, firstPath);
      expect(preparedQueues, isNotEmpty);
      expect(preparedQueues.last.toSet(), <String>{firstPath, secondPath});
    });

    test(
      'folder exclusion keeps entry tree and restores tracks from it',
      () async {
        final libraryRoot = await Directory.systemTemp.createTemp(
          'library_entries_',
        );
        addTearDown(() async {
          if (await libraryRoot.exists()) {
            await libraryRoot.delete(recursive: true);
          }
        });
        final folder = '${libraryRoot.path}${Platform.pathSeparator}work';
        final trackPath = '$folder${Platform.pathSeparator}01.mp3';

        runtimeGraph.library.addWatchedLibrary(libraryRoot.path, notify: false);
        runtimeGraph.library.addTracks(<MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: folder,
            groupTitle: 'work',
            groupSubtitle: folder,
            isSingle: false,
          ),
        ], notify: false);

        runtimeGraph.library.setLibraryFolderExcluded(
          libraryRoot.path,
          folder,
          true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(runtimeGraph.library.trackByPath(trackPath), isNull);
        expect(
          runtimeGraph.library
              .libraryEntriesForLibrary(libraryRoot.path)
              .where((entry) => entry.path == folder || entry.path == trackPath)
              .every((entry) => entry.isExcluded),
          isTrue,
        );

        runtimeGraph.library.setLibraryFolderExcluded(
          libraryRoot.path,
          folder,
          false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(runtimeGraph.library.trackByPath(trackPath), isNotNull);
        expect(
          runtimeGraph.library
              .libraryEntriesForLibrary(libraryRoot.path)
              .where((entry) => entry.path == folder || entry.path == trackPath)
              .every((entry) => entry.isActive),
          isTrue,
        );
      },
    );

    test('restoring an excluded content folder repopulates its tracks', () async {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR';
      const restoredFolder = '$libraryRoot::WorkA';
      const trackPath =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2F01.mp4';

      runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
      runtimeGraph.library.setLibraryFolderExcluded(
        libraryRoot,
        restoredFolder,
        true,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, (call) async {
            if (call.method != FileCacheMethod.scanFolder) {
              return null;
            }
            final arguments = call.arguments as Map<Object?, Object?>;
            if (arguments['folder'] != restoredFolder) {
              return <String, Object?>{'ok': true, 'value': const <Object?>[]};
            }
            return <String, Object?>{
              'ok': true,
              'value': <Object?>[
                <Object?, Object?>{
                  'path': trackPath,
                  'groupKey': restoredFolder,
                  'groupTitle': 'WorkA',
                  'groupSubtitle': 'WorkA',
                  'title': '01',
                  'isVideo': true,
                },
              ],
            };
          });

      runtimeGraph.library.setLibraryFolderExcluded(
        libraryRoot,
        restoredFolder,
        false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final restoredTrack = runtimeGraph.library.trackByPath(trackPath);
      expect(restoredTrack, isNotNull);
      expect(restoredTrack!.groupKey, restoredFolder);
      expect(restoredTrack.isVideo, isTrue);
    });

    test('standalone imported folder exclusions survive refresh semantics '
        'until cleared', () async {
      final folder = await Directory.systemTemp.createTemp(
        'standalone_folder_exclusion_',
      );
      addTearDown(() async {
        if (await folder.exists()) {
          await folder.delete(recursive: true);
        }
      });

      final trackPath = '${folder.path}${Platform.pathSeparator}01.mp3';
      await File(trackPath).writeAsBytes(const <int>[1, 2, 3]);

      runtimeGraph.library.addWatchedFolder(folder.path, notify: false);
      runtimeGraph.library.addTracks(<MusicTrack>[
        MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: folder.path,
          groupTitle: 'standalone',
          groupSubtitle: folder.path,
          isSingle: false,
        ),
      ], notify: false);

      runtimeGraph.library.setLibraryTrackExcluded(
        folder.path,
        trackPath,
        true,
      );

      expect(runtimeGraph.library.hasLibraryExclusions(folder.path), isTrue);
      expect(
        runtimeGraph.library.isLibraryPathExcluded(folder.path, trackPath),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runtimeGraph.library.trackByPath(trackPath), isNull);

      if (!runtimeGraph.library.isLibraryPathExcluded(folder.path, trackPath)) {
        runtimeGraph.library.addOrReplaceTracks(<MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: folder.path,
            groupTitle: 'standalone',
            groupSubtitle: folder.path,
            isSingle: false,
          ),
        ], notify: false);
      }

      expect(runtimeGraph.library.trackByPath(trackPath), isNull);

      runtimeGraph.library.clearLibraryExclusions(folder.path);

      expect(runtimeGraph.library.trackByPath(trackPath), isNotNull);
      expect(runtimeGraph.library.hasLibraryExclusions(folder.path), isFalse);
    });
  });
}

ScannedTrack _scannedTrackForPath(String trackPath) {
  final folder = path.dirname(trackPath);
  return ScannedTrack(
    path: trackPath,
    groupKey: folder,
    groupTitle: path.basename(folder),
    groupSubtitle: folder,
    isSingle: false,
    isVideo: false,
  );
}

class _JsonPreservationScanDataSource implements LibraryScanDataSource {
  String _selectedPath = '';
  List<String> _childFolders = const <String>[];
  List<ScannedTrack> _tracks = const <ScannedTrack>[];

  void configure({
    required String selectedPath,
    List<String> childFolders = const <String>[],
    required List<ScannedTrack> tracks,
  }) {
    _selectedPath = selectedPath;
    _childFolders = childFolders;
    _tracks = tracks;
  }

  @override
  Future<bool> ensureReadPermissionForSources(Iterable<String> sources) async =>
      true;

  @override
  Future<LibraryChildFolderListing> listImmediateChildFolders(
    String folderPath,
  ) async => (folders: _childFolders, complete: true);

  @override
  Future<String?> pickAudioFolder({required String dialogTitle}) async =>
      _selectedPath;

  @override
  Future<List<PickedAudioFile>?> pickAudioFiles({
    required String dialogTitle,
  }) async => const <PickedAudioFile>[];

  @override
  Future<String> resolveRestorablePath(String source) async => source;

  @override
  Future<NativeScanResult> scanFileSystemFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk,
  ) => scanFolderChunked(folderPath, onChunk);

  @override
  Future<NativeScanResult> scanFolder(String folderPath) async =>
      _resultForCurrentTracks();

  @override
  Future<NativeScanResult> scanFolderChunked(
    String folderPath,
    FutureOr<bool> Function(FolderScanChunk chunk) onChunk, {
    FutureOr<void> Function(FolderScanSessionEvent event)? onProgress,
  }) async {
    final paths = _tracks.map((track) => track.path).toSet();
    await onChunk(FolderScanChunk(tracks: _tracks, paths: paths));
    return _resultForCurrentTracks();
  }

  @override
  Future<bool> sourceExists(String source) async => true;

  NativeScanResult _resultForCurrentTracks() => NativeScanResult.success(
    _tracks,
    _tracks.map((track) => track.path).toSet(),
    completenessKnown: true,
  );
}

class _CountingTestPersistenceRepository extends TestPersistenceRepository {
  _CountingTestPersistenceRepository(AppDatabase database)
    : super(database: database);

  int upsertLibraryEntriesCallCount = 0;

  @override
  Future<void> upsertLibraryEntries(
    List<LibraryEntry> entries, {
    int? scanGeneration,
  }) {
    upsertLibraryEntriesCallCount++;
    return super.upsertLibraryEntries(entries, scanGeneration: scanGeneration);
  }

  @override
  Future<void> saveAllSessions(List<PersistedPlaybackSession> sessions) async {}
}

class _BlockingDeletionTestPersistenceRepository
    extends TestPersistenceRepository {
  _BlockingDeletionTestPersistenceRepository(AppDatabase database)
    : super(database: database);

  final Completer<void> _trackDeletionStarted = Completer<void>();
  final Completer<void> _releaseTrackDeletion = Completer<void>();
  final Completer<void> _trackDeletionCompleted = Completer<void>();
  final Completer<void> _libraryEntryDeletionCompleted = Completer<void>();

  Future<void> get trackDeletionStarted => _trackDeletionStarted.future;
  Future<void> get libraryEntryDeletionCompleted =>
      _libraryEntryDeletionCompleted.future;

  void releaseTrackDeletion() {
    if (!_releaseTrackDeletion.isCompleted) {
      _releaseTrackDeletion.complete();
    }
  }

  Future<void> releaseAndWait() async {
    releaseTrackDeletion();
    if (_trackDeletionStarted.isCompleted) {
      await _trackDeletionCompleted.future;
    }
  }

  @override
  Future<void> deleteTracks(List<String> paths) async {
    if (!_trackDeletionStarted.isCompleted) {
      _trackDeletionStarted.complete();
    }
    await _releaseTrackDeletion.future;
    try {
      await super.deleteTracks(paths);
    } finally {
      if (!_trackDeletionCompleted.isCompleted) {
        _trackDeletionCompleted.complete();
      }
    }
  }

  @override
  Future<void> deleteLibraryEntriesForLibrary(String libraryPath) async {
    await super.deleteLibraryEntriesForLibrary(libraryPath);
    if (!_libraryEntryDeletionCompleted.isCompleted) {
      _libraryEntryDeletionCompleted.complete();
    }
  }
}
