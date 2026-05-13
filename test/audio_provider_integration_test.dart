import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/services/app_database.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/native_playback_bridge.dart';
import 'package:nameless_audio/services/playback_notification_handler.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:nameless_audio/services/platform_channels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  const fileCacheChannel = MethodChannel(FileCacheChannel.name);
  late AudioProvider provider;
  late PlaybackNotificationHandler handler;
  late PlaybackNotificationService notificationService;
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchemaForTest(db);
    final databaseRepository = AudioDatabaseRepository(
      database: AppDatabase.test(db),
    );
    handler = PlaybackNotificationHandler();
    notificationService = PlaybackNotificationService(handler);
    provider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: databaseRepository,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, null);
    provider.dispose();
    await db.close();
  });

  // ── multi-session playback stability ──────────────────────────

  group('multi-session playback stability', () {
    test('initial state has no active sessions', () {
      expect(provider.activeSessions, isEmpty);
    });

    test('toggling play-pause with unknown id does not throw', () {
      provider.toggleSessionPlayPause('non_existent_session');
      expect(provider.activeSessions, isEmpty);
    });

    test('sessionById returns null for unknown id', () {
      expect(provider.sessionById('nonexistent'), isNull);
    });

    test('trackByPath returns null for unknown path', () {
      expect(provider.trackByPath('/nonexistent/path.mp3'), isNull);
    });
  });

  // ── native snapshot isolation ──────────────────────────────────

  group('native bridge session isolation', () {
    test('native snapshot updates only its target session', () async {
      final first = PlaybackSession(
        id: 'native_1',
        currentTrackPath: '/audio/first.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1.0,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.idle),
      );
      final second = PlaybackSession(
        id: 'native_2',
        currentTrackPath: '/audio/second.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.5,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(false, ProcessingState.idle),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      final secondStates = <PlayerState>[];
      second.stateStream.listen(secondStates.add);

      first.applyNativeSnapshot(
        const NativePlaybackSnapshot(
          sessionId: 'native_1',
          uri: 'file:///audio/first.mp3',
          playing: true,
          playWhenReady: true,
          processingState: 'ready',
          position: Duration(seconds: 5),
          bufferedPosition: Duration(seconds: 10),
          duration: Duration(minutes: 2),
          volume: 0.8,
          boostGain: 1.0,
          channelSwapEnabled: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.state.playing, isTrue);
      expect(first.volume, closeTo(0.8, 0.001));
      expect(second.state.playing, isFalse);
      expect(secondStates, isEmpty);
    });
  });

  // ── notification integration ───────────────────────────────────

  group('playback notification integration', () {
    test('notification state initializes with idle controls', () {
      final state = handler.playbackState.value;
      expect(state.playing, isFalse);
      expect(state.processingState, AudioProcessingState.idle);
    });

    test('notification snapshot populates queue and media item', () {
      handler.updateSnapshot(
        const PlaybackNotificationSnapshot(
          queue: <MediaItem>[MediaItem(id: 's1', title: 'One')],
          queueIndex: 0,
          mediaItem: MediaItem(id: 's1', title: 'One'),
          playing: false,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          speed: 1.0,
          hasPrevious: false,
          hasNext: false,
        ),
      );

      expect(handler.queue.value, hasLength(1));
      expect(handler.mediaItem.value!.id, 's1');
    });

    test('notification delete invokes callback', () async {
      var called = false;
      handler.bindCallbacks(
        onNotificationDeleted: () async {
          called = true;
        },
      );
      await handler.onNotificationDeleted();
      expect(called, isTrue);
    });

    test('clearing notification resets to empty idle state', () {
      handler.updateSnapshot(
        const PlaybackNotificationSnapshot(
          queue: <MediaItem>[MediaItem(id: 's1', title: 'One')],
          queueIndex: 0,
          mediaItem: MediaItem(id: 's1', title: 'One'),
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration(seconds: 1),
          bufferedPosition: Duration(seconds: 2),
          speed: 1.0,
          hasPrevious: false,
          hasNext: false,
        ),
      );
      handler.updateSnapshot(null);

      expect(handler.queue.value, isEmpty);
      expect(handler.mediaItem.value, isNull);
      expect(
        handler.playbackState.value.controls.single.action,
        MediaAction.play,
      );
    });
  });

  // ── optimistic playback state dedup ───────────────────────────

  group('optimistic playback state dedup', () {
    test('setOptimisticState only emits when values differ', () async {
      final session = PlaybackSession(
        id: 'opt_1',
        currentTrackPath: '/audio/opt.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1.0,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.idle),
      );
      addTearDown(session.dispose);

      final states = <PlayerState>[];
      session.stateStream.listen(states.add);

      session.setOptimisticState(
        playing: true,
        processingState: ProcessingState.ready,
      );
      // Identical values should not produce a second emission.
      session.setOptimisticState(
        playing: true,
        processingState: ProcessingState.ready,
      );
      await Future<void>.delayed(Duration.zero);

      expect(states, hasLength(1));
      expect(session.state.playing, isTrue);
      expect(session.state.processingState, ProcessingState.ready);

      // A genuinely different processing state should emit.
      session.setOptimisticState(
        playing: true,
        processingState: ProcessingState.completed,
      );
      await Future<void>.delayed(Duration.zero);

      expect(states, hasLength(2));
      expect(session.state.processingState, ProcessingState.completed);
    });
  });

  group('cover scope consistency', () {
    test('content track cover resolves against its work folder scope', () async {
      const libraryRoot =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR';
      const workScope = '$libraryRoot::WorkA';
      const groupKey = '$libraryRoot::WorkA/Disc1';
      const trackPath =
          'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2FDisc1%2F01.mp3';

      provider.addWatchedLibrary(libraryRoot, notify: false);
      provider.addTracks(
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
            return null;
          });

      await provider.coverPathFutureForTrack(provider.trackByPath(trackPath));

      expect(
        calls.any((call) {
          if (call.method != FileCacheMethod.resolveTrackCover) {
            return false;
          }
          final arguments = call.arguments as Map<Object?, Object?>;
          return arguments['path'] == trackPath &&
              arguments['groupKey'] == groupKey &&
              arguments['rootFolder'] == workScope;
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
            return null;
          });

      await provider.coverPathFutureForFolder(workScope);

      expect(
        calls.any((call) {
          if (call.method != FileCacheMethod.resolveTrackCover) {
            return false;
          }
          final arguments = call.arguments as Map<Object?, Object?>;
          return arguments['path'] == workScope &&
              arguments['rootFolder'] == workScope;
        }),
        isTrue,
      );
    });

    test(
      'filesystem track cover scans recursively inside work folder only',
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

        provider.addWatchedFolder(workDir.path, notify: false);
        provider.addTracks(
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

        final resolved = await provider.coverPathFutureForTrack(
          provider.trackByPath(trackPath),
        );

        expect(resolved, coverFile.path);
      },
    );

    test(
      'discoverImagesInRoot uses cache until cover generation changes',
      () async {
        final workDir = await Directory.systemTemp.createTemp('discover_root_');
        addTearDown(() async {
          if (await workDir.exists()) {
            await workDir.delete(recursive: true);
          }
        });

        final coverA = File(
          '${workDir.path}${Platform.pathSeparator}cover_a.jpg',
        );
        await coverA.writeAsBytes(const <int>[1, 2, 3]);
        final trackPath = '${workDir.path}${Platform.pathSeparator}01.mp3';
        await File(trackPath).writeAsBytes(const <int>[4, 5, 6]);

        provider.addWatchedFolder(workDir.path, notify: false);
        provider.addTracks(
          <MusicTrack>[
            MusicTrack(
              path: trackPath,
              displayName: '01',
              groupKey: workDir.path,
              groupTitle: 'Work',
              groupSubtitle: 'Work',
              isSingle: false,
            ),
          ],
          notify: false,
          persist: false,
        );

        final first = await provider.discoverImagesInRoot(trackPath);
        expect(first, contains(coverA.path));

        await coverA.delete();
        final second = await provider.discoverImagesInRoot(trackPath);
        expect(second, contains(coverA.path));

        await provider.setTrackManualCover(trackPath, null);
        final third = await provider.discoverImagesInRoot(trackPath);
        expect(third, isNot(contains(coverA.path)));
      },
    );

    test('folder cover resolves from manual-cover scope cache', () async {
      final workDir = await Directory.systemTemp.createTemp('scope_cache_');
      addTearDown(() async {
        if (await workDir.exists()) {
          await workDir.delete(recursive: true);
        }
      });

      final cover = File('${workDir.path}${Platform.pathSeparator}manual.jpg');
      await cover.writeAsBytes(const <int>[1, 2, 3]);
      final trackPath = '${workDir.path}${Platform.pathSeparator}01.mp3';
      await File(trackPath).writeAsBytes(const <int>[4, 5, 6]);

      provider.addWatchedFolder(workDir.path, notify: false);
      provider.addTracks(
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

      final resolved = await provider.coverPathFutureForFolder(workDir.path);
      expect(resolved, cover.path);
    });
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

        final result = await provider.renameAudioDetailTargetToName(
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

      final result = await provider.renameAudioDetailTargetToName(
        detail,
        'New Folder',
      );

      expect(result.detail.target.targetPath, endsWith('New Folder'));
      expect(await Directory(result.detail.target.targetPath).exists(), isTrue);
      expect(await source.exists(), isFalse);
    });
  });

  group('library card detail loading', () {
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
        provider.addTracks(
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

        await provider.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(source.path),
          ).copyWith(rjCode: 'RJ111111'),
        );
        final firstSnapshot = await provider.audioLibraryCategorySnapshot();
        expect(
          firstSnapshot
              .detailFor(AudioDetailTarget.singleAudioFile(source.path))
              ?.rjCode,
          'RJ111111',
        );

        await provider.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(source.path),
          ).copyWith(rjCode: 'RJ222222'),
        );

        final refreshedSyncSnapshot = provider.audioLibraryCategorySnapshotSync;
        expect(refreshedSyncSnapshot, isNotNull);
        expect(refreshedSyncSnapshot, isNot(same(firstSnapshot)));
        expect(
          refreshedSyncSnapshot
              ?.detailFor(AudioDetailTarget.singleAudioFile(source.path))
              ?.rjCode,
          'RJ222222',
        );

        final refreshedSnapshot = await provider.audioLibraryCategorySnapshot();
        expect(
          refreshedSnapshot
              .detailFor(AudioDetailTarget.singleAudioFile(source.path))
              ?.rjCode,
          'RJ222222',
        );
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

        final future = provider.coverPathFutureForFolder(missingFolder);

        expect(provider.isCoverPathLoadingForFolder(missingFolder), isTrue);
        expect(await future, isNull);
        expect(provider.isCoverPathLoadingForFolder(missingFolder), isFalse);
      },
    );
  });

  group('library folder restore', () {
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
              return const <Object?>[];
            }
            return <Object?>[
              <Object?, Object?>{
                'path': trackPath,
                'groupKey': restoredFolder,
                'groupTitle': 'WorkA',
                'groupSubtitle': 'WorkA',
                'title': '01',
                'isVideo': true,
              },
            ];
          });

      provider.setLibraryFolderExcluded(libraryRoot, restoredFolder, false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final restoredTrack = provider.trackByPath(trackPath);
      expect(restoredTrack, isNotNull);
      expect(restoredTrack!.groupKey, restoredFolder);
      expect(restoredTrack.isVideo, isTrue);
    });
  });
}
