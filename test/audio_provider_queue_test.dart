import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/features/asmr/application/asmr_playback_cache_service.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
      const track = MusicTrack(
        path: '/library/optimistic/01.mp3',
        displayName: '01',
        groupKey: '/library/optimistic',
        groupTitle: 'Optimistic',
        groupSubtitle: 'Optimistic',
        isSingle: false,
      );
      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
      final queueSession = provider.playbackFacade.createPlaybackQueue(
        'Queue 1',
      );

      final addFuture = provider.playbackFacade.addTrackToPlaybackQueue(
        queueSession.id,
        track,
      );
      await Future<void>.delayed(Duration.zero);

      final optimisticSession = provider.sessionById(queueSession.id)!;
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
        const track = MusicTrack(
          path: '/imports/repeated.mp4',
          displayName: 'Repeated clip',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: 'Manually selected files',
          isSingle: true,
          isVideo: true,
        );
        provider.addTracks(
          const <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        final queueSession = provider.playbackFacade.createPlaybackQueue(
          'Queue 1',
        );

        await provider.playbackFacade.addTrackToPlaybackQueue(
          queueSession.id,
          track,
        );
        await provider.playbackFacade.addTrackToPlaybackQueue(
          queueSession.id,
          track,
        );
        await provider.playbackFacade.seekSessionToNext(queueSession.id);

        expect(preparedQueueIndexes.last, 1);
        expect(queueSession.currentQueueIndex, 1);

        queueSession.setOptimisticPosition(const Duration(seconds: 5));
        await provider.playbackFacade.seekSessionToPrev(queueSession.id);

        expect(preparedQueueIndexes.last, 0);
        expect(queueSession.currentQueueIndex, 0);
      },
    );

    test('queue supports duplicate track entries and removal', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            return <String, Object?>{'ok': true, 'value': null};
          });
      const track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);

      final queueSession = provider.playbackFacade.createPlaybackQueue(
        'Queue 1',
      );
      expect(queueSession.isPlaybackQueue, isTrue);
      expect(queueSession.currentTrackPath, isEmpty);

      await provider.playbackFacade.addTrackToPlaybackQueue(
        queueSession.id,
        track,
      );
      await provider.playbackFacade.addTrackToPlaybackQueue(
        queueSession.id,
        track,
      );

      final updated = provider.sessionById(queueSession.id)!;
      expect(updated.playbackQueue?.entries, hasLength(2));
      expect(updated.customQueueTracks, hasLength(2));
      expect(
        PathMatcher.equalsNormalized(
          updated.currentTrackPath,
          provider.trackByPath(track.path)!.path,
        ),
        isTrue,
      );

      await provider.playbackFacade.removePlaybackQueueEntry(
        queueSession.id,
        updated.playbackQueue!.entries.first.id,
      );
      expect(
        provider.sessionById(queueSession.id)?.customQueueTracks,
        hasLength(1),
      );
    });

    test(
      'single files cannot expand into an imported-files work entry',
      () async {
        const selected = MusicTrack(
          path: '/imports/selected.mp3',
          displayName: 'Selected',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: 'Manually selected files',
          isSingle: true,
        );
        const other = MusicTrack(
          path: '/imports/other.mp3',
          displayName: 'Other',
          groupKey: '__single_files__',
          groupTitle: 'Imported files',
          groupSubtitle: 'Manually selected files',
          isSingle: true,
        );
        provider.addTracks(
          const <MusicTrack>[selected, other],
          notify: false,
          persist: false,
        );
        final queueSession = provider.playbackFacade.createPlaybackQueue(
          'Queue 1',
        );

        await provider.addWorkToPlaybackQueue(queueSession.id, selected);

        final entry = provider
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
      const first = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      const second = MusicTrack(
        path: '/library/work/02.mp3',
        displayName: '02',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      provider.addTracks(
        const <MusicTrack>[first, second],
        notify: false,
        persist: false,
      );
      final queueSession = provider.playbackFacade.createPlaybackQueue(
        'Queue 1',
      );
      final sourceTrack = provider.library.firstWhere(
        (track) => track.displayName == first.displayName,
      );

      await provider.addWorkToPlaybackQueue(queueSession.id, sourceTrack);

      final entry = provider
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
        const loopTrack = MusicTrack(
          path: 'https://example.com/loop.mp3',
          displayName: 'loop',
          groupKey: 'loop',
          groupTitle: 'Loop',
          groupSubtitle: 'Loop',
          isSingle: true,
        );
        const otherTrack = MusicTrack(
          path: 'https://example.com/other-01.mp3',
          displayName: 'other-01',
          groupKey: 'other',
          groupTitle: 'Other',
          groupSubtitle: 'Other',
          isSingle: false,
        );
        const otherNextTrack = MusicTrack(
          path: 'https://example.com/other-02.mp3',
          displayName: 'other-02',
          groupKey: 'other',
          groupTitle: 'Other',
          groupSubtitle: 'Other',
          isSingle: false,
        );

        await provider.playbackFacade.spawnSession(loopTrack, autoPlay: false);
        await provider.playbackFacade.spawnSessionWithQueue(const <MusicTrack>[
          otherTrack,
          otherNextTrack,
        ], autoPlay: false);
        for (var i = 0; i < 50; i++) {
          if (provider.activeSessions.every((session) => !session.isLoading)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final loopSession = provider.activeSessions.firstWhere(
          (session) => session.currentTrackPath == loopTrack.path,
        );
        final otherSession = provider.activeSessions.firstWhere(
          (session) => session.currentTrackPath == otherTrack.path,
        );
        final trackKey = provider.timeSegmentTrackKeyForTrack(loopTrack);
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

        provider.toggleTimeSegmentLoop(sessionId: loopSession.id, label: label);
        await Future<void>.delayed(Duration.zero);

        expect(
          provider.timeSegmentLoopLabelIdForSession(
            loopSession.id,
            trackKey: trackKey,
          ),
          label.id,
        );

        const otherSeekPosition = Duration(seconds: 90);
        provider.handleTimeSegmentManualSeek(
          otherSession.id,
          otherSeekPosition,
        );
        await provider.playbackFacade.seekSession(
          otherSession.id,
          otherSeekPosition,
        );
        await provider.playbackFacade.seekSessionToNext(otherSession.id);
        await provider.playbackFacade.seekSessionToPrev(otherSession.id);

        expect(otherSession.currentTrackPath, otherTrack.path);
        expect(
          provider.timeSegmentLoopLabelIdForSession(
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
      const firstTrack = MusicTrack(
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
      const secondTrack = MusicTrack(
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

      final restoredRepository = AudioDatabaseRepository(
        database: AppDatabase.test(db),
      );
      await restoredRepository.saveAllSessions(<PersistedSession>[
        const PersistedSession(
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

      final restoredProvider = AudioProvider.test(
        notificationService: notificationService,
        audioDatabaseRepository: restoredRepository,
        coverArtworkCacheService: _RecordingCoverArtworkCacheService(
          expectedRemoteCoverUrl: coverUrl,
          coverPath: coverFile.path,
        ),
        skipPersistence: false,
        startRuntime: true,
      );

      for (var i = 0; i < 100; i++) {
        if (restoredProvider.activeSessions.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(restoredProvider.activeSessions, hasLength(1));
      expect(
        restoredProvider
            .trackByPath('https://example.com/asmr/01.mp3')
            ?.toJson(),
        firstTrack.toJson(),
      );
      final siblings = restoredProvider.tracksInSameGroup(
        'https://example.com/asmr/01.mp3',
      );
      expect(siblings.map((track) => track.path), <String>[
        'https://example.com/asmr/01.mp3',
        'https://example.com/asmr/02.mp3',
      ]);
      final restoredTrack = restoredProvider.trackByPath(
        'https://example.com/asmr/01.mp3',
      );
      final coverPath = await restoredProvider.coverPathFutureForTrack(
        restoredTrack,
      );
      expect(coverPath, coverFile.path);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      restoredProvider.dispose();
    });

    test(
      'ASMR playback cache keeps custom queue metadata on cached paths',
      () async {
        const cachedPath = '/cache/asmr_playback_cache/cached_01.mp3';
        provider.dispose();
        provider = AudioProvider.test(
          notificationService: notificationService,
          audioDatabaseRepository: AudioDatabaseRepository(
            database: AppDatabase.test(db),
          ),
          asmrPlaybackCacheService: const _FakeAsmrPlaybackCacheService(
            cachedPath,
          ),
        );
        const firstTrack = MusicTrack(
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
        const secondTrack = MusicTrack(
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

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              if (call.method == NativePlaybackMethod.prepareSession) {
                final args = call.arguments as Map<Object?, Object?>;
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

        await provider.setAsmrPlaybackCacheEnabled(true);
        await provider.playbackFacade.spawnSessionWithQueue(const <MusicTrack>[
          firstTrack,
          secondTrack,
        ], autoPlay: false);

        final session = provider.activeSessions.single;
        for (var i = 0; i < 100; i++) {
          if (provider.trackByPath(cachedPath) != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(session.currentTrackPath, firstTrack.path);
        expect(provider.trackByPath(cachedPath)?.toJson(), firstTrack.toJson());
        expect(
          provider.tracksInSameGroup(cachedPath).map((track) => track.path),
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
  const _FakeAsmrPlaybackCacheService(this.cachedPath);

  final String cachedPath;

  @override
  Future<String?> cacheTrack(MusicTrack track, {String? playedPath}) async {
    return cachedPath;
  }
}
