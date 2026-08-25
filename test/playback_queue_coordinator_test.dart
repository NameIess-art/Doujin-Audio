import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/app/application/playback_queue_coordinator.dart';
import 'package:doujin_audio/app/application/audio_path_coordinator.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_cache_service.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/playback_time_segment_service.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  late AppRuntimeTestFixture fixture;
  late AppRuntimeGraph runtimeGraph;
  late PlaybackQueueCoordinator queueCoordinator;
  late PlaybackTimeSegmentService timeSegments;
  late AudioPathCoordinator paths;
  late PlaybackNotificationService notificationService;
  late Database db;

  setUp(() async {
    fixture = await AppRuntimeTestFixture.create();
    runtimeGraph = fixture.runtimeGraph;
    paths = AudioPathCoordinator(
      library: runtimeGraph.library,
      playback: runtimeGraph.playback,
    );
    queueCoordinator = PlaybackQueueCoordinator(
      playback: runtimeGraph.playback,
      paths: paths,
    );
    timeSegments = PlaybackTimeSegmentService(
      database: runtimeGraph.playback.databaseRepository,
      playback: runtimeGraph.playback,
      paths: paths,
    );
    notificationService = fixture.notificationService;
    db = fixture.database;
  });

  tearDown(() async {
    await timeSegments.dispose();
    await fixture.dispose(currentGraph: runtimeGraph);
  });

  group('playback queues', () {
    test('queue edit is visible before native preparation completes', () async {
      final prepareResult = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) {
            if (call.method == NativePlaybackMethod.prepareSession) {
              return prepareResult.future;
            }
            return Future<Object?>.value(<String, Object?>{
              'ok': true,
              'value': null,
            });
          });
      final track = MusicTrack(
        path: '/library/optimistic/01.mp3',
        displayName: '01',
        groupKey: '/library/optimistic',
        groupTitle: 'Optimistic',
        groupSubtitle: 'Optimistic',
        isSingle: false,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      final queueSession = runtimeGraph.playback.createPlaybackQueue('Queue 1');

      final addFuture = runtimeGraph.playback.addTrackToPlaybackQueue(
        queueSession.id,
        track,
      );
      await Future<void>.delayed(Duration.zero);

      final optimisticSession = runtimeGraph.playback.sessionById(
        queueSession.id,
      )!;
      expect(optimisticSession.playbackQueue?.entries, hasLength(1));
      expect(
        PathMatcher.equalsNormalized(
          optimisticSession.currentTrackPath,
          track.path,
        ),
        isFalse,
      );
      expect(prepareResult.isCompleted, isFalse);

      prepareResult.complete(<String, Object?>{'ok': true, 'value': null});
      await addFuture;
      expect(
        PathMatcher.equalsNormalized(
          optimisticSession.currentTrackPath,
          track.path,
        ),
        isTrue,
      );
    });

    test(
      'duplicate single-file entries reprepare at the next queue index',
      () async {
        final preparedQueueIndexes = <int>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              if (call.method == NativePlaybackMethod.prepareSession) {
                final arguments = call.arguments as Map<Object?, Object?>;
                preparedQueueIndexes.add(arguments['queueStartIndex'] as int);
              }
              return <String, Object?>{'ok': true, 'value': null};
            });
        final track = MusicTrack(
          path: '/imports/repeated.mp4',
          displayName: 'Repeated clip',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: 'Manually selected files',
          isSingle: true,
          isVideo: true,
        );
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        final queueSession = runtimeGraph.playback.createPlaybackQueue(
          'Queue 1',
        );

        await runtimeGraph.playback.addTrackToPlaybackQueue(
          queueSession.id,
          track,
        );
        await runtimeGraph.playback.addTrackToPlaybackQueue(
          queueSession.id,
          track,
        );
        await runtimeGraph.playback.seekSessionToNext(queueSession.id);

        expect(preparedQueueIndexes.last, 1);
        expect(queueSession.currentQueueIndex, 1);

        queueSession.setOptimisticPosition(const Duration(seconds: 5));
        await runtimeGraph.playback.seekSessionToPrev(queueSession.id);

        expect(preparedQueueIndexes.last, 0);
        expect(queueSession.currentQueueIndex, 0);
      },
    );

    test('queue supports duplicate track entries and removal', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            return <String, Object?>{'ok': true, 'value': null};
          });
      final track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );

      final queueSession = runtimeGraph.playback.createPlaybackQueue('Queue 1');
      expect(queueSession.isPlaybackQueue, isTrue);
      expect(queueSession.currentTrackPath, isEmpty);

      await runtimeGraph.playback.addTrackToPlaybackQueue(
        queueSession.id,
        track,
      );
      await runtimeGraph.playback.addTrackToPlaybackQueue(
        queueSession.id,
        track,
      );

      final updated = runtimeGraph.playback.sessionById(queueSession.id)!;
      expect(updated.playbackQueue?.entries, hasLength(2));
      expect(updated.customQueueTracks, hasLength(2));
      expect(
        PathMatcher.equalsNormalized(
          updated.currentTrackPath,
          runtimeGraph.library.trackByPath(track.path)!.path,
        ),
        isTrue,
      );

      await runtimeGraph.playback.removePlaybackQueueEntry(
        queueSession.id,
        updated.playbackQueue!.entries.first.id,
      );
      expect(
        runtimeGraph.playback.sessionById(queueSession.id)?.customQueueTracks,
        hasLength(1),
      );
    });

    test(
      'single files cannot expand into an imported-files work entry',
      () async {
        final selected = MusicTrack(
          path: '/imports/selected.mp3',
          displayName: 'Selected',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: 'Manually selected files',
          isSingle: true,
        );
        final other = MusicTrack(
          path: '/imports/other.mp3',
          displayName: 'Other',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: 'Manually selected files',
          isSingle: true,
        );
        runtimeGraph.library.addTracks(
          <MusicTrack>[selected, other],
          notify: false,
          persist: false,
        );
        final queueSession = runtimeGraph.playback.createPlaybackQueue(
          'Queue 1',
        );

        await queueCoordinator.addWork(queueSession.id, selected);

        final entry = runtimeGraph.playback
            .sessionById(queueSession.id)!
            .playbackQueue!
            .entries
            .single;
        expect(entry.kind, PlaybackQueueEntryKind.track);
        expect(entry.title, selected.displayName);
        expect(entry.tracks, <MusicTrack>[selected]);
      },
    );

    test('work entry stores all tracks as one queue entry', () async {
      final first = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      final second = MusicTrack(
        path: '/library/work/02.mp3',
        displayName: '02',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[first, second],
        notify: false,
        persist: false,
      );
      final queueSession = runtimeGraph.playback.createPlaybackQueue('Queue 1');
      final sourceTrack = runtimeGraph.library.library.firstWhere(
        (track) => track.displayName == first.displayName,
      );

      expect(sourceTrack.isSingle, isFalse);
      expect(sourceTrack.groupKey, isNotEmpty);
      expect(paths.trackByPath(sourceTrack.path), isNotNull);
      expect(paths.workRootForTrack(sourceTrack.path), isNotNull);
      expect(paths.tracksInSameWork(sourceTrack.path), hasLength(2));

      await queueCoordinator.addWork(queueSession.id, sourceTrack);

      final entry = runtimeGraph.playback
          .sessionById(queueSession.id)!
          .playbackQueue!
          .entries
          .single;
      expect(
        PathMatcher.equalsNormalized(entry.workRootPath!, '/library/work'),
        isTrue,
      );
      expect(entry.kind, PlaybackQueueEntryKind.work);
      expect(entry.title, 'Work');
      expect(entry.tracks, hasLength(2));
    });
  });

  group('time segment loop session isolation', () {
    test(
      'other audio seeks and track switches keep the original audio loop',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              return <String, Object?>{'ok': true, 'value': null};
            });
        final loopTrack = MusicTrack(
          path: 'https://example.com/loop.mp3',
          displayName: 'loop',
          groupKey: 'loop',
          groupTitle: 'Loop',
          groupSubtitle: 'Loop',
          isSingle: true,
        );
        final otherTrack = MusicTrack(
          path: 'https://example.com/other-01.mp3',
          displayName: 'other-01',
          groupKey: 'other',
          groupTitle: 'Other',
          groupSubtitle: 'Other',
          isSingle: false,
        );
        final otherNextTrack = MusicTrack(
          path: 'https://example.com/other-02.mp3',
          displayName: 'other-02',
          groupKey: 'other',
          groupTitle: 'Other',
          groupSubtitle: 'Other',
          isSingle: false,
        );

        await runtimeGraph.playback.spawnSession(loopTrack, autoPlay: false);
        await runtimeGraph.playback.spawnSessionWithQueue(<MusicTrack>[
          otherTrack,
          otherNextTrack,
        ], autoPlay: false);
        for (var i = 0; i < 50; i++) {
          if (runtimeGraph.playback.activeSessions.every(
            (session) => !session.isLoading,
          )) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final loopSession = runtimeGraph.playback.activeSessions.firstWhere(
          (session) => session.currentTrackPath == loopTrack.path,
        );
        final otherSession = runtimeGraph.playback.activeSessions.firstWhere(
          (session) => session.currentTrackPath == otherTrack.path,
        );
        await runtimeGraph.playback.toggleSessionPlayPause(otherSession.id);
        await runtimeGraph.playback.pendingSessionPreparation;
        final trackKey = timeSegments.trackKeyForTrack(loopTrack);
        final now = DateTime(2026, 6, 2);
        final label = TimeSegmentLabel(
          id: 'loop-segment',
          trackKey: trackKey,
          name: 'Loop segment',
          start: const Duration(seconds: 10),
          end: const Duration(seconds: 20),
          colorValue: kTimeSegmentLabelPalette.first,
          createdAt: now,
          updatedAt: now,
        );

        timeSegments.toggleLoop(sessionId: loopSession.id, label: label);
        await Future<void>.delayed(Duration.zero);

        expect(
          timeSegments.loopLabelIdForSession(
            loopSession.id,
            trackKey: trackKey,
          ),
          label.id,
        );

        const otherSeekPosition = Duration(seconds: 90);
        timeSegments.handleManualSeek(otherSession.id, otherSeekPosition);
        await runtimeGraph.playback.seekSession(
          otherSession.id,
          otherSeekPosition,
        );
        await runtimeGraph.playback.seekSessionToNext(otherSession.id);
        await runtimeGraph.playback.seekSessionToPrev(otherSession.id);

        expect(otherSession.currentTrackPath, otherTrack.path);
        expect(
          timeSegments.loopLabelIdForSession(
            loopSession.id,
            trackKey: trackKey,
          ),
          label.id,
        );
      },
    );
  });

  group('custom queue session restore', () {
    test('restores ASMR custom queues and exposes sibling tracks', () async {
      const sessionId = 'asmr_session';
      final coverFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'restored_asmr_cover_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      addTearDown(() async {
        if (await coverFile.exists()) await coverFile.delete();
      });
      await coverFile.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9]);
      const coverUrl = 'https://example.com/cover.jpg';
      final firstTrack = MusicTrack(
        path: 'https://example.com/asmr/01.mp3',
        displayName: '01',
        groupKey: 'asmr-work-1',
        groupTitle: 'ASMR Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteCoverUrl: coverUrl,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{
          'trackRelativePath': '01_mp3/01.mp3',
          'subtitleUrl': 'https://example.com/asmr/01.vtt',
          'subtitleExtension': '.vtt',
        },
      );
      final secondTrack = MusicTrack(
        path: 'https://example.com/asmr/02.mp3',
        displayName: '02',
        groupKey: 'asmr-work-1',
        groupTitle: 'ASMR Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteCoverUrl: coverUrl,
        remoteMetadataKind: 'asmr.one',
        remoteMetadata: <String, Object?>{'trackRelativePath': '01_mp3/02.mp3'},
      );

      final restoredRepository = TestPersistenceRepository(
        database: AppDatabase.test(db),
      );
      await restoredRepository.saveAllSessions(<PersistedPlaybackSession>[
        PersistedPlaybackSession(
          id: sessionId,
          trackPath: 'https://example.com/asmr/01.mp3',
          loopModeIndex: 1,
          volume: 1.0,
          positionMs: 0,
          durationMs: 0,
          customQueueTracks: <MusicTrack>[firstTrack, secondTrack],
          channelSwapEnabled: false,
          sortOrder: 0,
          createdAtMs: 1,
        ),
      ]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'session_order_v1': json.encode(<String>[sessionId]),
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
                  'value': <String, Object?>{'sessions': <Object?>[]},
                };
              default:
                return <String, Object?>{'ok': true};
            }
          });

      final restoredGraph = createTestRuntimeGraph(
        notificationService: notificationService,
        persistenceRepository: restoredRepository,
        coverArtworkCacheService: _RecordingCoverArtworkCacheService(
          expectedRemoteCoverUrl: coverUrl,
          coverPath: coverFile.path,
        ),
        skipPersistence: false,
        startRuntime: true,
      );

      for (var i = 0; i < 100; i++) {
        if (restoredGraph.playback.activeSessions.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(restoredGraph.playback.activeSessions, hasLength(1));
      expect(
        restoredGraph.playbackCommands
            .trackByPath('https://example.com/asmr/01.mp3')
            ?.toJson(),
        firstTrack.toJson(),
      );
      final siblings = AudioPathCoordinator(
        library: restoredGraph.library,
        playback: restoredGraph.playback,
      ).tracksInSameGroup('https://example.com/asmr/01.mp3');
      expect(siblings.map((track) => track.path), <String>[
        'https://example.com/asmr/01.mp3',
        'https://example.com/asmr/02.mp3',
      ]);
      final restoredTrack = restoredGraph.playbackCommands.trackByPath(
        'https://example.com/asmr/01.mp3',
      );
      final coverPath = await restoredGraph.notifications
          .coverPathFutureForTrack(restoredTrack);
      expect(coverPath, coverFile.path);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await restoredGraph.runtime.dispose();
    });

    test(
      'ASMR playback cache keeps custom queue metadata on cached paths',
      () async {
        const cachedPath = '/cache/asmr_playback_cache/cached_01.mp3';
        await runtimeGraph.runtime.dispose();
        runtimeGraph = createTestRuntimeGraph(
          notificationService: notificationService,
          persistenceRepository: TestPersistenceRepository(
            database: AppDatabase.test(db),
          ),
          asmrPlaybackCacheService: _FakeAsmrPlaybackCacheService(cachedPath),
        );
        paths = AudioPathCoordinator(
          library: runtimeGraph.library,
          playback: runtimeGraph.playback,
        );
        final firstTrack = MusicTrack(
          path: 'https://example.com/asmr/01.mp3',
          displayName: '01',
          groupKey: 'asmr-work-1',
          groupTitle: 'ASMR Work',
          groupSubtitle: 'RJ000001',
          isSingle: false,
          remoteCoverUrl: 'https://example.com/cover.jpg',
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: <String, Object?>{
            'playbackUrls': <String>['https://example.com/asmr/01.mp3'],
          },
        );
        final secondTrack = MusicTrack(
          path: 'https://example.com/asmr/02.mp3',
          displayName: '02',
          groupKey: 'asmr-work-1',
          groupTitle: 'ASMR Work',
          groupSubtitle: 'RJ000001',
          isSingle: false,
          remoteCoverUrl: 'https://example.com/cover.jpg',
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: <String, Object?>{
            'playbackUrls': <String>['https://example.com/asmr/02.mp3'],
          },
        );

        List<Object?>? preparedQueue;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              if (call.method == NativePlaybackMethod.prepareSession) {
                final args = call.arguments as Map<Object?, Object?>;
                preparedQueue = (args['queue'] as List<Object?>?)?.toList();
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{
                    'sessionId': args['sessionId'] as String,
                    'uri': args['uri'] as String,
                    'path': args['path'] as String,
                    'title': args['title'] as String,
                    'playing': false,
                    'playWhenReady': false,
                    'processingState': 'ready',
                    'positionMs': 0,
                    'bufferedPositionMs': 0,
                    'durationMs': 0,
                    'volume': 1.0,
                    'queueIndex': 0,
                  },
                };
              }
              return <String, Object?>{'ok': true, 'value': null};
            });

        await runtimeGraph.settings.setAsmrPlaybackCacheEnabled(true);
        await runtimeGraph.playback.spawnSessionWithQueue(<MusicTrack>[
          firstTrack,
          secondTrack,
        ], autoPlay: false);

        final session = runtimeGraph.playback.activeSessions.single;
        expect(preparedQueue, isNull);
        await runtimeGraph.playback.toggleSessionPlayPause(session.id);
        await runtimeGraph.playback.pendingSessionPreparation;
        final queueItems = preparedQueue!.cast<Map<Object?, Object?>>().toList(
          growable: false,
        );
        expect(queueItems, hasLength(2));
        expect(queueItems[0]['candidateUris'], <String>[
          'https://example.com/asmr/01.mp3',
        ]);
        expect(queueItems[1]['candidateUris'], <String>[
          'https://example.com/asmr/02.mp3',
        ]);
        for (var i = 0; i < 100; i++) {
          if (runtimeGraph.playbackCommands.trackByPath(cachedPath) != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(session.currentTrackPath, firstTrack.path);
        expect(
          runtimeGraph.playbackCommands.trackByPath(cachedPath)?.toJson(),
          firstTrack.toJson(),
        );
        expect(paths.trackByPath(cachedPath)?.toJson(), firstTrack.toJson());
        expect(
          runtimeGraph.playback.activeSessions.single.customQueueTracks,
          hasLength(2),
        );
        expect(
          paths.tracksInSameGroup(cachedPath).map((track) => track.path),
          <String>[
            'https://example.com/asmr/01.mp3',
            'https://example.com/asmr/02.mp3',
          ],
        );
      },
    );
  });

  // 鈹€鈹€ native snapshot isolation 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  // 鈹€鈹€ notification integration 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
}

class _RecordingCoverArtworkCacheService extends CoverArtworkCacheService {
  _RecordingCoverArtworkCacheService({
    required this.expectedRemoteCoverUrl,
    required this.coverPath,
  }) : super(libraryService: LibraryService());

  final String expectedRemoteCoverUrl;
  final String coverPath;

  @override
  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) async {
    return track?.remoteCoverUrl == expectedRemoteCoverUrl ? coverPath : null;
  }
}

class _FakeAsmrPlaybackCacheService extends AsmrPlaybackCacheService {
  _FakeAsmrPlaybackCacheService(this.cachedPath);

  final String cachedPath;

  @override
  Future<String?> cacheTrack(MusicTrack track, {String? playedPath}) async {
    return cachedPath;
  }
}
