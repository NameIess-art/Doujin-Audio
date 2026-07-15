import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/application/library_scanner_service.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/audio_provider_test_fixture.dart';

void main() {
  AudioProviderTestFixture.initialize();

  late AudioProviderTestFixture fixture;
  late AudioProvider provider;
  late PlaybackNotificationService notificationService;
  late Database db;

  setUp(() async {
    fixture = await AudioProviderTestFixture.create();
    provider = fixture.provider;
    notificationService = fixture.notificationService;
    db = fixture.database;
  });

  tearDown(() async {
    await fixture.dispose(currentProvider: provider);
  });

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
    provider.addWatchedFolder(folder.path, notify: false);
    provider.addTracks(tracks, notify: false, persist: false);

    final requestedPaths = <String>[];
    var activeDurationReads = 0;
    var peakDurationReads = 0;
    final duration = await provider.calculateMissingLibraryDuration(
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
      provider.trackByPath(secondPath)?.duration,
      const Duration(minutes: 2),
    );
    expect(
      provider.trackByPath(thirdPath)?.duration,
      const Duration(minutes: 3),
    );

    final unreadablePath = path.join(thirdFolder, '04.ogg');
    provider.addTracks(
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
    final incompleteDuration = await provider.calculateMissingLibraryDuration(
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
    provider.addWatchedFolder(contentRoot, notify: false);
    provider.addTracks(
      const <MusicTrack>[
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
    final contentDuration = await provider.calculateMissingLibraryDuration(
      contentRoot,
      durationReader: (trackPath) async =>
          trackPath == contentTrackPath ? const Duration(minutes: 5) : null,
    );
    expect(contentDuration, const Duration(minutes: 5));
  });

  test('missing duration is resolved for a single video file', () async {
    const videoPath = r'C:\library\standalone-video.mp4';
    provider.addTracks(
      const <MusicTrack>[
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
    final duration = await provider.calculateMissingLibraryDuration(
      videoPath.toUpperCase(),
      durationReader: (trackPath) async {
        requestedPaths.add(trackPath);
        return const Duration(minutes: 7, seconds: 12);
      },
    );

    expect(requestedPaths, const <String>[videoPath]);
    expect(duration, const Duration(minutes: 7, seconds: 12));
    expect(
      provider.trackByPath(videoPath)?.duration,
      const Duration(minutes: 7, seconds: 12),
    );
  });

  test(
    'library duration backfill persists work and single details to database and JSON',
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
      provider.addWatchedFolder(workDir.path, notify: false);
      provider.addTracks(
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

      await provider.backfillMissingLibraryDurations(
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
        (await provider.loadAudioDetail(workTarget)).detail.duration,
        const Duration(minutes: 3),
      );
      expect(
        (await provider.loadAudioDetail(singleTarget)).detail.duration,
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

      final workBackup =
          json.decode(
                await File(
                  path.join(workDir.path, AudioDetailRepository.backupFileName),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(
        workBackup['durationMs'],
        const Duration(minutes: 3).inMilliseconds,
      );
      final singleBackups =
          json.decode(
                await File(
                  path.join(
                    singlesDir.path,
                    AudioDetailRepository.backupFileName,
                  ),
                ).readAsString(),
              )
              as List<dynamic>;
      expect(singleBackups, hasLength(1));
      expect(
        (singleBackups.single as Map<String, dynamic>)['durationMs'],
        const Duration(seconds: 45).inMilliseconds,
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
      provider.addWatchedFolder(workDir.path, notify: false);
      provider.addTracks(
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
      await provider.saveAudioDetail(
        AudioDetail.empty(
          target,
        ).copyWith(duration: const Duration(minutes: 9)),
      );

      final requestedPaths = <String>[];
      await provider.backfillMissingLibraryDurations(
        durationReader: (path) async {
          requestedPaths.add(path);
          return const Duration(minutes: 2);
        },
      );

      expect(requestedPaths, <String>[trackPath]);
      expect(
        provider.trackByPath(trackPath)?.duration,
        const Duration(minutes: 2),
      );
      expect(
        (await provider.loadAudioDetail(target)).detail.duration,
        const Duration(minutes: 9),
      );
    },
  );

  // 鈹€鈹€ multi-session playback stability 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  group('library folder restore', () {
    test('scan generations reject stale progress and stale completion', () {
      final first = provider.tryBeginScan(source: '/music/first');
      expect(first, greaterThan(0));
      expect(provider.tryBeginScan(source: '/music/second'), 0);

      provider.setScanProgress(
        generation: first + 1,
        foundCount: 99,
        stage: FolderScanStage.enumerating,
      );
      expect(provider.scanFoundCount, 0);

      provider.cancelScan();
      final second = provider.tryBeginScan(source: '/music/second');
      expect(second, greaterThan(first));
      provider.finishScan(first);
      expect(provider.isScanGenerationActive(second), isTrue);

      provider.finishScan(second);
      expect(provider.isScanning, isFalse);
    });

    test(
      'background scan progress does not notify visible library UI',
      () async {
        final facade = provider.libraryFacade;
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
        provider.addListener(() {
          notificationCount++;
        });

        final generation = provider.libraryFacade.tryBeginScan(
          source: 'background-folder',
          background: true,
        );
        provider.beginLibraryBatch();
        provider.addOrReplaceTracks(
          <MusicTrack>[
            const MusicTrack(
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
        provider.setScanProgress(currentFolder: 'background-folder');
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(notificationCount, 0);

        await provider.endLibraryBatch();
        await Future<void>.delayed(Duration.zero);
        provider.libraryFacade.finishScan(generation);

        expect(notificationCount, 1);
      },
    );

    test('library entry persistence is deferred until batch close', () async {
      provider.dispose();
      final countingRepository = _CountingAudioDatabaseRepository(
        AppDatabase.test(db),
      );
      provider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: countingRepository,
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

      provider.beginLibraryBatch();
      provider.recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
        firstTrack,
      ]);
      provider.recordLibraryEntriesForTracks(libraryPath, <MusicTrack>[
        renamedTrack,
      ]);

      expect(provider.libraryEntriesForLibrary(libraryPath), isNotEmpty);
      expect(countingRepository.upsertLibraryEntriesCallCount, 0);
      expect(await db.query('library_entries'), isEmpty);

      await provider.endLibraryBatch();

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
        provider.addWatchedFolder(normalizedFolderPath, notify: false);
        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
        provider.recordLibraryEntriesForTracks(
          normalizedFolderPath,
          <MusicTrack>[track],
          persist: false,
        );
        for (var i = 0; i < 100 && provider.libraryTree.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(provider.libraryTree, isNotEmpty);

        final beforeRevision = provider.libraryContentRevision;
        var notificationCount = 0;
        provider.addListener(() {
          notificationCount++;
        });

        final scanner = LibraryScannerService();
        await scanner.refreshWatchedFolders(
          provider: provider.libraryFacade.catalog,
          labels: const LibraryScanLabels(
            chooseMusicFolder: 'Choose music folder',
            chooseLibraryFolder: 'Choose library folder',
            chooseAudioFiles: 'Choose audio files',
            importedFiles: 'Imported Files',
            manuallySelectedFiles: 'Manually Selected Files',
          ),
        );

        final refreshedTrack = provider.trackByPath(trackPath);
        expect(
          refreshedTrack,
          same(track),
          reason: 'before=${track.toJson()} after=${refreshedTrack?.toJson()}',
        );
        expect(provider.libraryContentRevision, beforeRevision);
        expect(notificationCount, 0);
      },
    );

    test('addOrReplaceTracks ignores unchanged rescan metadata', () async {
      final initialModifiedAt = DateTime.fromMillisecondsSinceEpoch(1000);
      final initialScannedAt = DateTime.fromMillisecondsSinceEpoch(2000);
      final refreshedScannedAt = DateTime.fromMillisecondsSinceEpoch(3000);
      const trackPath = '/library/work/01.mp3';

      provider.addTracks(
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

      final beforeRefresh = provider.library.single;
      var notificationCount = 0;
      provider.addListener(() {
        notificationCount++;
      });

      provider.addOrReplaceTracks(<MusicTrack>[
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
      expect(provider.library.single, same(beforeRefresh));

      provider.addOrReplaceTracks(<MusicTrack>[
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
      expect(provider.library.single.displayName, '01 renamed');
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

      provider.addWatchedLibrary(libraryRoot.path, notify: false);
      provider.recordLibraryEntriesForTracks(
        libraryRoot.path,
        const <MusicTrack>[],
        folderPaths: <String>[keptFolderPath, deletedFolderPath],
        persist: false,
      );
      provider.addTracks(<MusicTrack>[
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

      provider.removeTracksDeletedFromFolder(libraryRoot.path, {keptPath});
      provider.removeLibraryEntriesDeletedFromFolder(
        libraryRoot.path,
        libraryRoot.path,
        {keptPath, keptFolderPath},
      );

      expect(provider.trackByPath(keptPath), isNotNull);
      expect(provider.trackByPath(deletedPath), isNull);
      expect(
        provider
            .libraryEntriesForLibrary(libraryRoot.path)
            .where((entry) => entry.path == deletedPath),
        isEmpty,
      );
      expect(
        provider
            .libraryEntriesForLibrary(libraryRoot.path)
            .where((entry) => entry.path == deletedFolderPath),
        isEmpty,
      );
      expect(
        provider
            .libraryEntriesForLibrary(libraryRoot.path)
            .where((entry) => entry.path == keptFolderPath),
        hasLength(1),
      );
    });

    test('content folder exclusion stores the canonical library child path', () {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR';
      const childFolder = '$libraryRoot/document/primary%3AASMR%2FWorkA';
      const syntheticChildFolder = '$libraryRoot::WorkA';
      const trackPath =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2F01.mp3';

      provider.addWatchedLibrary(libraryRoot, notify: false);
      provider.addWatchedFolder(childFolder, notify: false);
      provider.addTracks(<MusicTrack>[
        const MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: syntheticChildFolder,
          groupTitle: 'WorkA',
          groupSubtitle: syntheticChildFolder,
          isSingle: false,
        ),
      ], notify: false);

      provider.setLibraryFolderExcluded(libraryRoot, childFolder, true);

      expect(provider.excludedFoldersForLibrary(libraryRoot), <String>[
        syntheticChildFolder,
      ]);
      expect(
        provider
            .libraryEntriesForLibrary(libraryRoot)
            .where((entry) => entry.path == syntheticChildFolder),
        hasLength(1),
      );
      expect(
        provider
            .libraryEntriesForLibrary(libraryRoot)
            .where((entry) => entry.path == syntheticChildFolder)
            .single
            .isExcluded,
        isTrue,
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

      provider.addWatchedLibrary(libraryRoot, notify: false);
      provider.addTracks(<MusicTrack>[
        const MusicTrack(
          path: firstPath,
          displayName: '01',
          groupKey: firstFolder,
          groupTitle: 'Disc 1',
          groupSubtitle: firstFolder,
          isSingle: false,
        ),
        const MusicTrack(
          path: secondPath,
          displayName: '02',
          groupKey: secondFolder,
          groupTitle: 'Disc 2',
          groupSubtitle: secondFolder,
          isSingle: false,
        ),
        const MusicTrack(
          path: outsidePath,
          displayName: '03',
          groupKey: outsideFolder,
          groupTitle: 'Other',
          groupSubtitle: outsideFolder,
          isSingle: false,
        ),
      ], notify: false);

      expect(
        provider.tracksInSameWork(firstPath).map((track) => track.path).toSet(),
        <String>{firstPath, secondPath},
      );
      expect(provider.workRootForTrack(firstPath), workRoot);
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

      provider.addWatchedLibrary(libraryRoot, notify: false);
      provider.addTracks(<MusicTrack>[
        const MusicTrack(
          path: firstPath,
          displayName: '01',
          groupKey: '$workRoot\\Disc 1',
          groupTitle: 'Disc 1',
          groupSubtitle: '$workRoot\\Disc 1',
          isSingle: false,
        ),
        const MusicTrack(
          path: secondPath,
          displayName: '02',
          groupKey: '$workRoot\\Disc 2',
          groupTitle: 'Disc 2',
          groupSubtitle: '$workRoot\\Disc 2',
          isSingle: false,
        ),
        const MusicTrack(
          path: outsidePath,
          displayName: '03',
          groupKey: '$libraryRoot\\Work B',
          groupTitle: 'Work B',
          groupSubtitle: '$libraryRoot\\Work B',
          isSingle: false,
        ),
      ], notify: false);

      await provider.spawnSession(
        provider.trackByPath(secondPath)!,
        autoPlay: false,
      );
      final session = provider.activeSessions.single;
      for (var i = 0; i < 50 && session.isLoading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await provider.setSessionLoopMode(
        session.id,
        SessionLoopMode.crossSequential,
      );
      await provider.seekSessionToNext(session.id);

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

        provider.addWatchedLibrary(libraryRoot.path, notify: false);
        provider.addTracks(<MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: folder,
            groupTitle: 'work',
            groupSubtitle: folder,
            isSingle: false,
          ),
        ], notify: false);

        provider.setLibraryFolderExcluded(libraryRoot.path, folder, true);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(provider.trackByPath(trackPath), isNull);
        expect(
          provider
              .libraryEntriesForLibrary(libraryRoot.path)
              .where((entry) => entry.path == folder || entry.path == trackPath)
              .every((entry) => entry.isExcluded),
          isTrue,
        );

        provider.setLibraryFolderExcluded(libraryRoot.path, folder, false);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(provider.trackByPath(trackPath), isNotNull);
        expect(
          provider
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

      provider.addWatchedLibrary(libraryRoot, notify: false);
      provider.setLibraryFolderExcluded(libraryRoot, restoredFolder, true);

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

      provider.setLibraryFolderExcluded(libraryRoot, restoredFolder, false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final restoredTrack = provider.trackByPath(trackPath);
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

      provider.addWatchedFolder(folder.path, notify: false);
      provider.addTracks(<MusicTrack>[
        MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: folder.path,
          groupTitle: 'standalone',
          groupSubtitle: folder.path,
          isSingle: false,
        ),
      ], notify: false);

      provider.setLibraryTrackExcluded(folder.path, trackPath, true);

      expect(provider.trackByPath(trackPath), isNull);
      expect(provider.hasLibraryExclusions(folder.path), isTrue);
      expect(provider.isLibraryPathExcluded(folder.path, trackPath), isTrue);

      if (!provider.isLibraryPathExcluded(folder.path, trackPath)) {
        provider.addOrReplaceTracks(<MusicTrack>[
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

      expect(provider.trackByPath(trackPath), isNull);

      provider.clearLibraryExclusions(folder.path);

      expect(provider.trackByPath(trackPath), isNotNull);
      expect(provider.hasLibraryExclusions(folder.path), isFalse);
    });
  });
}

class _CountingAudioDatabaseRepository extends AudioDatabaseRepository {
  _CountingAudioDatabaseRepository(AppDatabase database)
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
  Future<void> saveAllSessions(List<PersistedSession> sessions) async {}
}
