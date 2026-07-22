import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/application/audio_path_coordinator.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/core/app_language.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  late AppRuntimeTestFixture fixture;
  late AppRuntimeGraph runtimeGraph;
  late AudioPathCoordinator pathCoordinator;
  late PlaybackNotificationService notificationService;
  late Database db;

  setUp(() async {
    fixture = await AppRuntimeTestFixture.create();
    runtimeGraph = fixture.runtimeGraph;
    pathCoordinator = AudioPathCoordinator(
      library: runtimeGraph.library,
      playback: runtimeGraph.playback,
    );
    notificationService = fixture.notificationService;
    db = fixture.database;
  });

  tearDown(() async {
    await fixture.dispose(currentGraph: runtimeGraph);
  });

  group('folder image selection', () {
    test(
      'work card selects a nested image without assigning it to the track',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('library_cover_');
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final workDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}work',
        );
        final audioDir = Directory(
          '${workDir.path}${Platform.pathSeparator}audio',
        );
        final imageDir = Directory(
          '${workDir.path}${Platform.pathSeparator}extras',
        );
        await audioDir.create(recursive: true);
        await imageDir.create(recursive: true);
        final coverPath = '${imageDir.path}${Platform.pathSeparator}cover.jpg';
        await File(coverPath).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);

        final track = MusicTrack(
          path: '${audioDir.path}${Platform.pathSeparator}track.wav',
          displayName: 'track',
          groupKey: audioDir.path,
          groupTitle: 'audio',
          groupSubtitle: audioDir.path,
          isSingle: false,
        );
        runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );

        expect(
          await runtimeGraph.notifications.coverPathFutureForFolder(
            workDir.path,
          ),
          coverPath,
        );
        expect(
          await runtimeGraph.notifications.coverPathFutureForTrack(track),
          isNull,
        );
      },
    );

    test('work card prefers a root image over nested images', () async {
      final workDir = await Directory.systemTemp.createTemp(
        'library_root_cover_',
      );
      addTearDown(() async {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      });
      final nestedDir = Directory(
        '${workDir.path}${Platform.pathSeparator}Disc1',
      );
      await nestedDir.create(recursive: true);
      final rootCover = '${workDir.path}${Platform.pathSeparator}cover.jpg';
      final nestedCover =
          '${nestedDir.path}${Platform.pathSeparator}folder.jpg';
      await File(rootCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      await File(nestedCover).writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);

      expect(
        await runtimeGraph.notifications.coverPathFutureForFolder(workDir.path),
        rootCover,
      );
    });
  });

  group('cover scope consistency', () {
    test('single video track cover resolves from generated frame', () async {
      const trackPath = '/library/video/scene.mp4';
      const framePath = '/cache/video_scene.jpg';
      final calls = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, (call) async {
            calls.add(call);
            if (call.method == FileCacheMethod.resolveVideoFrame) {
              return <String, Object?>{'ok': true, 'value': framePath};
            }
            return <String, Object?>{'ok': true, 'value': null};
          });

      const videoTrack = MusicTrack(
        path: trackPath,
        displayName: 'scene',
        groupKey: '__single_files__',
        groupTitle: 'Single files',
        groupSubtitle: 'Manual import',
        isSingle: true,
        isVideo: true,
      );

      expect(
        await runtimeGraph.notifications.coverPathFutureForTrack(videoTrack),
        framePath,
      );
      expect(
        calls.where((call) => call.method == FileCacheMethod.resolveVideoFrame),
        hasLength(1),
      );
    });

    test('content track cover resolves only against the media file', () async {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR';
      const groupKey = '$libraryRoot::WorkA/Disc1';
      const trackPath =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2FDisc1%2F01.mp3';

      runtimeGraph.library.addWatchedLibrary(libraryRoot, notify: false);
      runtimeGraph.library.addTracks(
        const <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: groupKey,
            groupTitle: 'Disc1',
            groupSubtitle: 'WorkA/Disc1',
            isSingle: false,
          ),
        ],
        notify: false,
        persist: false,
      );

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, (call) async {
            calls.add(call);
            return <String, Object?>{'ok': true, 'value': null};
          });

      await runtimeGraph.notifications.coverPathFutureForTrack(
        runtimeGraph.library.trackByPath(trackPath),
      );

      expect(
        calls.any((call) {
          if (call.method != FileCacheMethod.resolveTrackCover) {
            return false;
          }
          final arguments = call.arguments as Map<Object?, Object?>;
          return arguments['path'] == trackPath &&
              arguments['groupKey'] == groupKey &&
              arguments['rootFolder'] == null;
        }),
        isTrue,
      );
    });

    test('folder card cover resolves against its own folder scope', () async {
      const workScope =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR::WorkA';

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, (call) async {
            calls.add(call);
            return <String, Object?>{'ok': true, 'value': const <String>[]};
          });

      await runtimeGraph.notifications.coverPathFutureForFolder(workScope);

      expect(
        calls.any((call) {
          if (call.method != FileCacheMethod.discoverRootImages) {
            return false;
          }
          final arguments = call.arguments as Map<Object?, Object?>;
          return arguments['path'] == workScope &&
              arguments['rootFolder'] == workScope &&
              arguments['recursive'] == false;
        }),
        isTrue,
      );
    });

    test(
      'work card auto-resolves a cover from a track in a child folder',
      () async {
        final workDir = await Directory.systemTemp.createTemp(
          'library_work_cover_',
        );
        addTearDown(() async {
          if (await workDir.exists()) await workDir.delete(recursive: true);
        });
        final audioDir = Directory(
          '${workDir.path}${Platform.pathSeparator}Disc1',
        );
        await audioDir.create(recursive: true);
        final trackPath = '${audioDir.path}${Platform.pathSeparator}01.mp3';
        const generatedCover = '/cache/embedded-work-cover.jpg';

        runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[
            MusicTrack(
              path: trackPath,
              displayName: '01',
              groupKey: audioDir.path,
              groupTitle: 'Disc1',
              groupSubtitle: 'Work/Disc1',
              isSingle: false,
            ),
          ],
          notify: false,
          persist: false,
        );

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(fileCacheChannel, (call) async {
              if (call.method == FileCacheMethod.resolveTrackCover) {
                return <String, Object?>{'ok': true, 'value': generatedCover};
              }
              return <String, Object?>{'ok': true, 'value': null};
            });

        expect(
          await runtimeGraph.notifications.coverPathFutureForFolder(
            workDir.path,
          ),
          generatedCover,
        );
        final rows = await db.query(
          'audio_details',
          where: 'target_type = ? AND target_path = ?',
          whereArgs: <Object>['libraryRootFolder', workDir.path],
        );
        expect(rows.single['card_cover_path'], generatedCover);
      },
    );

    test(
      'filesystem track does not inherit an image from its work folder',
      () async {
        final workDir = await Directory.systemTemp.createTemp('cover_scope_');
        addTearDown(() async {
          if (await workDir.exists()) {
            await workDir.delete(recursive: true);
          }
        });

        final nestedDir = Directory(
          '${workDir.path}${Platform.pathSeparator}Disc1',
        );
        await nestedDir.create(recursive: true);
        final coverFile = File(
          '${nestedDir.path}${Platform.pathSeparator}zzz_promo.jpg',
        );
        await coverFile.writeAsBytes(const <int>[1, 2, 3]);
        final trackPath = '${nestedDir.path}${Platform.pathSeparator}01.mp3';
        await File(trackPath).writeAsBytes(const <int>[4, 5, 6]);

        runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[
            MusicTrack(
              path: trackPath,
              displayName: '01',
              groupKey: nestedDir.path,
              groupTitle: 'Disc1',
              groupSubtitle: 'Disc1',
              isSingle: false,
            ),
          ],
          notify: false,
          persist: false,
        );

        final resolved = await runtimeGraph.notifications
            .coverPathFutureForTrack(
              runtimeGraph.library.trackByPath(trackPath),
            );

        expect(resolved, isNull);
        expect(
          await runtimeGraph.notifications.coverPathFutureForFolder(
            workDir.path,
          ),
          coverFile.path,
        );
        expect(
          await runtimeGraph.notifications.coverPathFutureForFolder(
            nestedDir.path,
          ),
          coverFile.path,
        );
      },
    );

    test('folder cover does not read a track manual-cover field', () async {
      final workDir = await Directory.systemTemp.createTemp('scope_cache_');
      addTearDown(() async {
        if (await workDir.exists()) {
          await workDir.delete(recursive: true);
        }
      });

      final externalDir = await Directory.systemTemp.createTemp(
        'scope_cache_external_',
      );
      addTearDown(() async {
        if (await externalDir.exists()) {
          await externalDir.delete(recursive: true);
        }
      });
      final cover = File(
        '${externalDir.path}${Platform.pathSeparator}manual.jpg',
      );
      await cover.writeAsBytes(const <int>[1, 2, 3]);
      final trackPath = '${workDir.path}${Platform.pathSeparator}01.mp3';
      await File(trackPath).writeAsBytes(const <int>[4, 5, 6]);

      runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
      runtimeGraph.library.addTracks(
        <MusicTrack>[
          MusicTrack(
            path: trackPath,
            displayName: '01',
            groupKey: workDir.path,
            groupTitle: 'Work',
            groupSubtitle: 'Work',
            isSingle: false,
            manualCoverPath: cover.path,
          ),
        ],
        notify: false,
        persist: false,
      );

      final resolved = await runtimeGraph.notifications
          .coverPathFutureForFolder(workDir.path);
      expect(resolved, isNull);
    });

    test(
      'setFolderManualCover syncs the folder card cover to audio covers',
      () async {
        final workDir = await Directory.systemTemp.createTemp('folder_manual_');
        addTearDown(() async {
          if (await workDir.exists()) {
            await workDir.delete(recursive: true);
          }
        });

        final discDir = Directory(
          '${workDir.path}${Platform.pathSeparator}Disc1',
        );
        await discDir.create(recursive: true);
        final trackPath = '${discDir.path}${Platform.pathSeparator}01.mp3';
        await File(trackPath).writeAsBytes(const <int>[1, 2, 3]);
        final coverPath = '${workDir.path}${Platform.pathSeparator}folder.jpg';
        final replacementCoverPath =
            '${workDir.path}${Platform.pathSeparator}folder-2.jpg';
        await File(coverPath).writeAsBytes(const <int>[4, 5, 6]);
        await File(replacementCoverPath).writeAsBytes(const <int>[7, 8, 9]);

        runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[
            MusicTrack(
              path: trackPath,
              displayName: '01',
              groupKey: discDir.path,
              groupTitle: 'Disc1',
              groupSubtitle: 'Disc1',
              isSingle: false,
            ),
          ],
          notify: false,
          persist: false,
        );

        await runtimeGraph.library.setFolderManualCover(
          workDir.path,
          coverPath,
        );

        final backupFile = File(
          '${workDir.path}${Platform.pathSeparator}'
          '${AudioDetailRepository.backupFileName}',
        );
        final selectedCoverBackup =
            json.decode(await backupFile.readAsString())
                as Map<String, dynamic>;
        expect(selectedCoverBackup['cardCoverRelativePath'], 'folder.jpg');
        expect(selectedCoverBackup['cardCoverSelected'], isTrue);

        final updatedTrack = runtimeGraph.library.trackByPath(trackPath);
        expect(updatedTrack?.manualCoverPath, isNull);
        expect(
          await runtimeGraph.notifications.coverPathFutureForFolder(
            workDir.path,
          ),
          coverPath,
        );
        expect(
          await runtimeGraph.notifications.coverPathFutureForTrack(
            updatedTrack,
          ),
          coverPath,
        );
        expect(
          await runtimeGraph.notifications.playbackCoverPathFutureForTrack(
            updatedTrack,
          ),
          coverPath,
        );
        expect(
          runtimeGraph.notifications.coverPathForTrack(updatedTrack),
          coverPath,
        );

        await runtimeGraph.library.setFolderManualCover(
          workDir.path,
          replacementCoverPath,
        );

        final replacementCoverBackup =
            json.decode(await backupFile.readAsString())
                as Map<String, dynamic>;
        expect(replacementCoverBackup['cardCoverRelativePath'], 'folder-2.jpg');

        expect(
          runtimeGraph.notifications.coverPathForTrack(
            runtimeGraph.library.trackByPath(trackPath),
          ),
          replacementCoverPath,
        );
        expect(
          await runtimeGraph.notifications.playbackCoverPathFutureForTrack(
            runtimeGraph.library.trackByPath(trackPath),
          ),
          replacementCoverPath,
        );
      },
    );

    test(
      'removed folder restores its selected cover from JSON when re-added',
      () async {
        final workDir = await Directory.systemTemp.createTemp(
          'folder_cover_reimport_',
        );
        addTearDown(() => workDir.delete(recursive: true));

        final trackPath = '${workDir.path}${Platform.pathSeparator}01.mp3';
        final coverPath = '${workDir.path}${Platform.pathSeparator}cover.jpg';
        await File(trackPath).writeAsBytes(const <int>[1, 2, 3]);
        await File(coverPath).writeAsBytes(const <int>[4, 5, 6]);
        final track = MusicTrack(
          path: trackPath,
          displayName: '01',
          groupKey: workDir.path,
          groupTitle: 'Work',
          groupSubtitle: workDir.path,
          isSingle: false,
        );

        runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await runtimeGraph.library.setFolderManualCover(
          workDir.path,
          coverPath,
        );

        final backupFile = File(
          '${workDir.path}${Platform.pathSeparator}'
          '${AudioDetailRepository.backupFileName}',
        );
        expect(await backupFile.exists(), isTrue);
        final backup =
            json.decode(await backupFile.readAsString())
                as Map<String, dynamic>;
        expect(backup['cardCoverRelativePath'], 'cover.jpg');
        expect(backup['cardCoverEmbedded'], isNull);
        await runtimeGraph.library.removeFolderFromLibrary(workDir.path);
        expect(await db.query('audio_details'), isEmpty);

        await db.delete(
          'app_kv_settings',
          where: 'key = ?',
          whereArgs: const <Object>['folder_cover_selections_v1'],
        );
        await runtimeGraph.runtime.dispose();
        runtimeGraph = createTestRuntimeGraph(
          notificationService: notificationService,
          audioDatabaseRepository: AudioDatabaseRepository(
            database: AppDatabase.test(db),
          ),
        );
        runtimeGraph.library.addWatchedFolder(workDir.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );

        expect(
          await runtimeGraph.notifications.coverPathFutureForTrack(track),
          coverPath,
        );
        expect(
          await runtimeGraph.notifications.coverPathFutureForFolder(
            workDir.path,
          ),
          coverPath,
        );
        expect(
          await runtimeGraph.notifications.playbackCoverPathFutureForTrack(
            track,
          ),
          coverPath,
        );
      },
    );
  });

  group('audio detail rename target name', () {
    test(
      'renames a single audio file while preserving its extension',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'detail_file_rename_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final source = File('${tempDir.path}${Platform.pathSeparator}old.mp3');
        await source.writeAsBytes(const <int>[1, 2, 3]);
        final detail = AudioDetail.empty(
          AudioDetailTarget.singleAudioFile(source.path),
        );

        final result = await pathCoordinator.renameAudioDetailTargetToName(
          detail,
          'New Title',
        );

        expect(result.detail.target.targetPath, endsWith('New Title.mp3'));
        expect(await File(result.detail.target.targetPath).exists(), isTrue);
        expect(await source.exists(), isFalse);
      },
    );

    test('renames a folder target with the provided folder name', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'detail_folder_rename_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final source = Directory(
        '${tempDir.path}${Platform.pathSeparator}Old Folder',
      );
      await source.create();
      final detail = AudioDetail.empty(
        AudioDetailTarget.libraryRootFolder(source.path),
      );

      final result = await pathCoordinator.renameAudioDetailTargetToName(
        detail,
        'New Folder',
      );

      expect(result.detail.target.targetPath, endsWith('New Folder'));
      expect(await Directory(result.detail.target.targetPath).exists(), isTrue);
      expect(await source.exists(), isFalse);
    });

    test(
      'renaming an imported folder retargets watched roots and exclusions',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'detail_folder_retarget_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final source = Directory(
          '${tempDir.path}${Platform.pathSeparator}Old Folder',
        );
        final trackFile = File('${source.path}${Platform.pathSeparator}01.mp3');
        await source.create();
        await trackFile.writeAsBytes(const <int>[1, 2, 3]);

        runtimeGraph.library.addWatchedFolder(source.path, notify: false);
        runtimeGraph.library.addTracks(<MusicTrack>[
          MusicTrack(
            path: trackFile.path,
            displayName: '01',
            groupKey: source.path,
            groupTitle: 'Old Folder',
            groupSubtitle: source.path,
            isSingle: false,
          ),
        ], notify: false);
        runtimeGraph.library.setLibraryTrackExcluded(
          source.path,
          trackFile.path,
          true,
        );

        final result = await pathCoordinator.renameAudioDetailTargetToName(
          AudioDetail.empty(AudioDetailTarget.libraryRootFolder(source.path)),
          'New Folder',
        );
        final newFolderPath = result.detail.target.targetPath;
        final newTrackPath = '$newFolderPath${Platform.pathSeparator}01.mp3';

        expect(runtimeGraph.library.watchedFolders, contains(newFolderPath));
        expect(
          runtimeGraph.library.watchedFolders,
          isNot(contains(source.path)),
        );
        expect(
          runtimeGraph.library.excludedTracksForLibrary(newFolderPath),
          <String>[newTrackPath],
        );
        expect(
          runtimeGraph.library.excludedTracksForLibrary(source.path),
          isEmpty,
        );
        expect(
          runtimeGraph.library
              .libraryEntriesForLibrary(newFolderPath)
              .where((entry) => entry.path == newTrackPath),
          hasLength(1),
        );
        expect(runtimeGraph.library.trackByPath(newTrackPath), isNull);

        runtimeGraph.library.clearLibraryExclusions(newFolderPath);

        expect(runtimeGraph.library.trackByPath(newTrackPath), isNotNull);
      },
    );

    test(
      'renaming an active folder keeps playlist track lookups after stale native paths',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'detail_folder_playlist_rename_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final source = Directory(
          '${tempDir.path}${Platform.pathSeparator}Old Folder',
        );
        final trackFile = File('${source.path}${Platform.pathSeparator}01.mp3');
        await source.create();

        final track = MusicTrack(
          path: trackFile.path,
          displayName: '01',
          groupKey: source.path,
          groupTitle: 'Old Folder',
          groupSubtitle: source.path,
          isSingle: false,
        );
        runtimeGraph.library.addWatchedFolder(source.path, notify: false);
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );

        final prepareStarted = Completer<void>();
        final releasePrepare = Completer<void>();

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  if (!prepareStarted.isCompleted) {
                    prepareStarted.complete();
                  }
                  await releasePrepare.future;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId':
                          (call.arguments as Map<Object?, Object?>)['sessionId']
                              as String,
                      'uri': Uri.file(trackFile.path).toString(),
                      'path': trackFile.path,
                      'title': '01',
                      'subtitle': 'Old Folder',
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': 1000,
                      'volume': 1.0,
                      'boostGain': 1.0,
                      'channelSwap': false,
                    },
                  };
                case NativePlaybackMethod.setAudioEffects:
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId':
                          (call.arguments as Map<Object?, Object?>)['sessionId']
                              as String,
                      'uri': Uri.file(trackFile.path).toString(),
                      'path': trackFile.path,
                      'title': '01',
                      'subtitle': 'Old Folder',
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': 1000,
                      'volume': 1.0,
                      'boostGain': 1.0,
                      'channelSwap':
                          call.method == NativePlaybackMethod.setAudioEffects,
                    },
                  };
                default:
                  return <String, Object?>{'ok': true};
              }
            });

        await runtimeGraph.playback.spawnSession(track, autoPlay: false);
        await prepareStarted.future;
        final session = runtimeGraph.playback.service.activeSessions.single;

        final result = await pathCoordinator.renameAudioDetailTargetToName(
          AudioDetail.empty(AudioDetailTarget.libraryRootFolder(source.path)),
          'New Folder',
        );
        final newFolderPath = result.detail.target.targetPath;
        final newTrackPath = '$newFolderPath${Platform.pathSeparator}01.mp3';

        expect(session.currentTrackPath, newTrackPath);

        final preparationApplied = session.stateStream.firstWhere(
          (state) => state.processingState == ProcessingState.ready,
        );
        releasePrepare.complete();
        await preparationApplied;

        await runtimeGraph.playback.setSessionChannelSwap(session.id, true);

        expect(session.currentTrackPath, newTrackPath);
        final resolvedTrack = runtimeGraph.playbackCommands.trackByPath(
          trackFile.path,
        );
        expect(resolvedTrack, isNotNull);
        expect(resolvedTrack?.path, newTrackPath);
        expect(resolvedTrack?.displayName, '01');
        expect(pathCoordinator.rootFolderName(trackFile.path), 'New Folder');
        expect(
          runtimeGraph.notifications.coverPathForTrack(
            resolvedTrack,
            trackPath: trackFile.path,
          ),
          isNull,
        );
        await fixture.dispose(currentGraph: runtimeGraph);
      },
    );

    test(
      'restored session keeps renamed folder metadata when native snapshot still reports the old path',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'detail_folder_playlist_restore_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final newFolder = Directory(
          '${tempDir.path}${Platform.pathSeparator}New Folder',
        );
        await newFolder.create();
        final newTrackPath = '${newFolder.path}${Platform.pathSeparator}01.mp3';
        final newCoverPath =
            '${newFolder.path}${Platform.pathSeparator}cover.jpg';
        await File(newTrackPath).writeAsBytes(const <int>[1, 2, 3]);
        await File(newCoverPath).writeAsBytes(const <int>[4, 5, 6]);

        const restoredSessionId = 'restored_session';
        final oldTrackPath =
            '${tempDir.path}${Platform.pathSeparator}Old Folder${Platform.pathSeparator}01.mp3';

        final restoredRepository = AudioDatabaseRepository(
          database: AppDatabase.test(db),
        );
        await restoredRepository.saveAllTracks(<MusicTrack>[
          MusicTrack(
            path: newTrackPath,
            displayName: '01',
            groupKey: newFolder.path,
            groupTitle: 'New Folder',
            groupSubtitle: newFolder.path,
            isSingle: false,
            manualCoverPath: newCoverPath,
          ),
        ]);
        await restoredRepository.saveAllSessions(<PersistedSession>[
          PersistedSession(
            id: restoredSessionId,
            trackPath: newTrackPath,
            loopModeIndex: SessionLoopMode.folderSequential.index,
            volume: 1.0,
            positionMs: 0,
            durationMs: 1000,
            customQueueTracks: null,
            channelSwapEnabled: false,
            sortOrder: 0,
            createdAtMs: DateTime(2026).millisecondsSinceEpoch,
          ),
        ]);
        SharedPreferences.setMockInitialValues(<String, Object>{
          'watched_folders_v1': json.encode(<String>[newFolder.path]),
          'session_order_v1': json.encode(<String>[restoredSessionId]),
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                case NativePlaybackMethod.setForegroundEnabled:
                  return <String, Object?>{'ok': true, 'value': null};
                case NativePlaybackMethod.snapshot:
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessions': <Map<String, Object?>>[
                        <String, Object?>{
                          'sessionId': restoredSessionId,
                          'uri': Uri.file(oldTrackPath).toString(),
                          'path': oldTrackPath,
                          'title': '01',
                          'subtitle': 'Old Folder',
                          'playing': false,
                          'playWhenReady': false,
                          'processingState': 'ready',
                          'positionMs': 0,
                          'bufferedPositionMs': 0,
                          'durationMs': 1000,
                          'volume': 1.0,
                          'boostGain': 1.0,
                          'channelSwap': false,
                        },
                      ],
                    },
                  };
                default:
                  return <String, Object?>{'ok': true};
              }
            });

        final restoredGraph = createTestRuntimeGraph(
          notificationService: notificationService,
          audioDatabaseRepository: restoredRepository,
          skipPersistence: false,
        );
        addTearDown(restoredGraph.runtime.dispose);
        await restoredGraph.runtime.start();

        expect(restoredGraph.playback.service.activeSessions, hasLength(1));
        final restoredSession =
            restoredGraph.playback.service.activeSessions.single;
        expect(restoredSession.currentTrackPath, newTrackPath);
        final restoredTrack = restoredGraph.library.trackByPath(
          restoredSession.currentTrackPath,
        );
        expect(restoredTrack, isNotNull);
        expect(restoredTrack?.displayName, '01');
        expect(
          AudioPathCoordinator(
            library: restoredGraph.library,
            playback: restoredGraph.playback,
          ).rootFolderName(restoredSession.currentTrackPath),
          'New Folder',
        );
        expect(
          await restoredGraph.notifications.playbackCoverPathFutureForTrack(
            restoredTrack,
            trackPath: restoredSession.currentTrackPath,
          ),
          newCoverPath,
        );
        expect(
          restoredGraph.notifications.coverPathForTrack(
            restoredTrack,
            trackPath: restoredSession.currentTrackPath,
          ),
          newCoverPath,
        );
        expect(
          await restoredGraph.notifications.coverPathFutureForFolder(
            newFolder.path,
          ),
          newCoverPath,
        );
      },
    );
  });

  group('library card detail loading', () {
    test(
      'category details wait for the current background tree snapshot',
      () async {
        MusicTrack track(String path, String name) => MusicTrack(
          path: path,
          displayName: name,
          groupKey: path,
          groupTitle: name,
          groupSubtitle: path,
          isSingle: true,
        );

        const firstPath = '/library/first.mp3';
        const secondPath = '/library/second.mp3';
        runtimeGraph.library.addTracks(
          <MusicTrack>[track(firstPath, 'first')],
          notify: false,
          persist: false,
        );
        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(firstPath),
          ).copyWith(rjCode: 'RJ111111'),
        );
        final firstSnapshot = await runtimeGraph.library
            .audioLibraryCategorySnapshot();
        expect(firstSnapshot.entries, hasLength(1));

        runtimeGraph.library.addTracks(
          <MusicTrack>[track(secondPath, 'second')],
          notify: false,
          persist: false,
        );
        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(secondPath),
          ).copyWith(rjCode: 'RJ222222'),
        );

        final refreshedSnapshot = await runtimeGraph.library
            .audioLibraryCategorySnapshot();

        expect(refreshedSnapshot.entries, hasLength(2));
        expect(
          refreshedSnapshot
              .detailFor(AudioDetailTarget.singleAudioFile(secondPath))
              ?.rjCode,
          'RJ222222',
        );
      },
    );

    test(
      'initial card detail snapshot commits after app interaction',
      () async {
        final interactionSource = Object();
        final coordinator = UiInteractionCoordinator.instance;
        coordinator.beginInteraction(interactionSource);
        addTearDown(() => coordinator.cancelInteraction(interactionSource));
        final tempDir = await Directory.systemTemp.createTemp(
          'initial_library_card_detail_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final source = File('${tempDir.path}${Platform.pathSeparator}work.mp3');
        await source.writeAsBytes(const <int>[1, 2, 3]);
        final target = AudioDetailTarget.singleAudioFile(source.path);
        runtimeGraph.library.addTracks(
          <MusicTrack>[
            MusicTrack(
              path: source.path,
              displayName: 'work',
              groupKey: source.path,
              groupTitle: 'work',
              groupSubtitle: source.path,
              isSingle: true,
            ),
          ],
          notify: false,
          persist: false,
        );
        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(target).copyWith(rjCode: 'RJ333333'),
        );

        await runtimeGraph.library.audioLibraryCategorySnapshot();

        expect(runtimeGraph.library.categorySnapshot, isNull);

        coordinator.cancelInteraction(interactionSource);
        coordinator.flushPendingCommitsForTest();
        expect(
          runtimeGraph.library.categorySnapshot?.detailFor(target)?.rjCode,
          'RJ333333',
        );
      },
    );

    test(
      'keeps the previous detail snapshot while a refresh is pending',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'detail_snapshot_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final source = File('${tempDir.path}${Platform.pathSeparator}work.mp3');
        await source.writeAsBytes(const <int>[1, 2, 3]);
        runtimeGraph.library.addTracks(
          <MusicTrack>[
            MusicTrack(
              path: source.path,
              displayName: 'work',
              groupKey: source.path,
              groupTitle: 'work',
              groupSubtitle: source.path,
              isSingle: true,
            ),
          ],
          notify: false,
          persist: false,
        );

        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(source.path),
          ).copyWith(rjCode: 'RJ111111'),
        );
        final firstSnapshot = await runtimeGraph.library
            .audioLibraryCategorySnapshot();
        expect(
          firstSnapshot
              .detailFor(AudioDetailTarget.singleAudioFile(source.path))
              ?.rjCode,
          'RJ111111',
        );

        await runtimeGraph.library.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(source.path),
          ).copyWith(rjCode: 'RJ222222'),
        );

        final refreshedSyncSnapshot = runtimeGraph.library.categorySnapshot;
        expect(refreshedSyncSnapshot, isNotNull);
        expect(refreshedSyncSnapshot, isNot(same(firstSnapshot)));
        expect(
          refreshedSyncSnapshot
              ?.detailFor(AudioDetailTarget.singleAudioFile(source.path))
              ?.rjCode,
          'RJ222222',
        );

        final refreshedSnapshot = await runtimeGraph.library
            .audioLibraryCategorySnapshot();
        expect(
          refreshedSnapshot
              .detailFor(AudioDetailTarget.singleAudioFile(source.path))
              ?.rjCode,
          'RJ222222',
        );
      },
    );
  });

  group('metadata apply scope', () {
    test(
      'missingOnly fills empty fields without overwriting existing data',
      () async {
        final target = AudioDetailTarget.libraryRootFolder('/library/work');
        final detail = AudioDetail.empty(target).copyWith(
          rjCode: 'RJ111111',
          workTitle: 'Existing title',
          voiceActors: const <String>['Existing voice'],
          duration: const Duration(minutes: 30),
        );

        final result = await runtimeGraph.library.applyDlsiteMetadata(
          detail,
          DlsiteMetadata(
            rjCode: 'RJ222222',
            workTitle: 'Fetched title',
            circleName: 'Fetched circle',
            voiceActors: const <String>['Fetched voice'],
            tags: const <String>['ASMR'],
            releaseDate: DateTime(2024, 5, 6),
            duration: const Duration(hours: 2),
            salesCount: 1234,
            rating: 4.5,
          ),
          saveCover: false,
          language: AppLanguage.zh,
          missingOnly: true,
        );

        expect(result.detail.rjCode, 'RJ111111');
        expect(result.detail.workTitle, 'Existing title');
        expect(result.detail.voiceActors, const <String>['Existing voice']);
        expect(result.detail.circleName, 'Fetched circle');
        expect(result.detail.tags, const <String>['ASMR']);
        expect(result.detail.releaseDate, DateTime(2024, 5, 6));
        expect(result.detail.duration, const Duration(minutes: 30));
        expect(result.detail.salesCount, 1234);
        expect(result.detail.rating, 4.5);
      },
    );
  });

  group('cover loading state', () {
    test(
      'reports a folder cover lookup as loading only while in flight',
      () async {
        final missingFolder =
            '${Directory.systemTemp.path}'
            '${Platform.pathSeparator}missing_cover_lookup';

        final future = runtimeGraph.notifications.coverPathFutureForFolder(
          missingFolder,
        );

        expect(
          runtimeGraph.notifications.isCoverPathLoadingForFolder(missingFolder),
          isTrue,
        );
        expect(await future, isNull);
        expect(
          runtimeGraph.notifications.isCoverPathLoadingForFolder(missingFolder),
          isFalse,
        );
      },
    );

    test('playlist cover warmup skips resolved and duplicate tracks', () async {
      await runtimeGraph.runtime.dispose();
      final cache = _PlaybackCoverWarmupRecordingCacheService(
        resolvedPaths: const <String>{'/library/resolved.flac'},
      );
      runtimeGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        audioDatabaseRepository: AudioDatabaseRepository(
          database: AppDatabase.test(db),
        ),
        coverArtworkCacheService: cache,
      );
      const unresolved = MusicTrack(
        path: '/library/unresolved.flac',
        displayName: 'Unresolved',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'Library',
        isSingle: false,
      );
      const duplicate = MusicTrack(
        path: '/library/unresolved.flac',
        displayName: 'Duplicate',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'Library',
        isSingle: false,
      );
      const resolved = MusicTrack(
        path: '/library/resolved.flac',
        displayName: 'Resolved',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'Library',
        isSingle: false,
      );

      runtimeGraph.warmup.warmupPlaybackCovers(<MusicTrack?>[
        unresolved,
        duplicate,
        resolved,
        null,
      ]);
      for (var i = 0; i < 10 && cache.requestedPaths.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(cache.requestedPaths, <String>[unresolved.path]);
    });

    test('library cover warmup pauses during UI interaction', () async {
      await runtimeGraph.runtime.dispose();
      final cache = _PlaybackCoverWarmupRecordingCacheService();
      runtimeGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        audioDatabaseRepository: AudioDatabaseRepository(
          database: AppDatabase.test(db),
        ),
        coverArtworkCacheService: cache,
      );
      const track = MusicTrack(
        path: '/library/paused.flac',
        displayName: 'Paused',
        groupKey: '/library',
        groupTitle: 'Library',
        groupSubtitle: 'Library',
        isSingle: false,
      );
      final interactionSource = Object();
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.beginInteraction(interactionSource);

      runtimeGraph.library.warmupCoversForTracks(const <MusicTrack?>[track]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cache.requestedPaths, isEmpty);

      coordinator.cancelInteraction(interactionSource);
      for (var i = 0; i < 10 && cache.requestedPaths.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cache.requestedPaths, <String>[track.path]);
    });
  });
}

class _PlaybackCoverWarmupRecordingCacheService
    extends CoverArtworkCacheService {
  _PlaybackCoverWarmupRecordingCacheService({
    this.resolvedPaths = const <String>{},
  }) : super(libraryService: LibraryService());

  final Set<String> resolvedPaths;
  final List<String> requestedPaths = <String>[];

  @override
  String? resolvedForTrack(MusicTrack? track, {String? trackPath}) {
    final path = track?.path ?? trackPath;
    return path != null && resolvedPaths.contains(path)
        ? '/resolved.image'
        : null;
  }

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) async {
    final path = track?.path ?? trackPath;
    if (path != null) requestedPaths.add(path);
    return path == null ? null : '/cover.image';
  }

  @override
  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) {
    final path = track?.path ?? trackPath;
    return path != null && resolvedPaths.contains(path)
        ? '/resolved.image'
        : null;
  }

  @override
  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async {
    final path = track?.path ?? trackPath;
    if (path != null) requestedPaths.add(path);
    return path == null ? null : '/cover.image';
  }
}
