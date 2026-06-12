import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/services/app_database.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/library_scanner_service.dart';
import 'package:nameless_audio/services/native_playback_bridge.dart';
import 'package:nameless_audio/services/path_matcher.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:nameless_audio/services/platform_channels.dart';
import 'package:nameless_audio/services/ui_interaction_coordinator.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  const fileCacheChannel = MethodChannel(FileCacheChannel.name);
  const nativePlaybackChannel = MethodChannel(NativePlaybackChannel.name);
  const notificationsChannel = MethodChannel(NotificationsChannel.name);
  late AudioProvider provider;
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
    notificationService = PlaybackNotificationService();
    provider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: databaseRepository,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
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

    test(
      'channel swap keeps current playback state when native reports transient completion',
      () async {
        var setAudioEffectsCalls = 0;
        bool? lastChannelSwapEnabled;

        final tempDir = await Directory.systemTemp.createTemp(
          'channel_swap_state_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final trackFile = File(
          '${tempDir.path}${Platform.pathSeparator}track.mp3',
        );
        await trackFile.writeAsBytes(const <int>[1, 2, 3]);
        final track = MusicTrack(
          path: trackFile.path,
          displayName: 'track',
          groupKey: tempDir.path,
          groupTitle: 'Folder',
          groupSubtitle: tempDir.path,
          isSingle: false,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  return <String, Object?>{'ok': true, 'value': null};
                case NativePlaybackMethod.setAudioEffects:
                  setAudioEffectsCalls++;
                  final args = call.arguments as Map<Object?, Object?>;
                  final effects = args['effects'] as Map<Object?, Object?>;
                  lastChannelSwapEnabled =
                      effects['channelSwapEnabled'] as bool?;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
                      'uri': Uri.file(trackFile.path).toString(),
                      'path': trackFile.path,
                      'title': 'track',
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'completed',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': const Duration(minutes: 3).inMilliseconds,
                      'volume': 1.0,
                      'boostGain': 1.0,
                      'channelSwap': true,
                      'audioEffects': <String, Object?>{
                        'skipSilenceEnabled': false,
                        'noiseReductionEnabled': false,
                        'eqEnabled': false,
                        'eqBandLevels': <Object?>[],
                      },
                    },
                  };
                default:
                  return <String, Object?>{'ok': true, 'value': null};
              }
            });
        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
        await provider.spawnSession(track, autoPlay: false);

        final session = provider.activeSessions.single;
        for (var i = 0; i < 20; i++) {
          if (session.loadedPath != null && !session.isLoading) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        session.applyNativeSnapshot(
          NativePlaybackSnapshot(
            sessionId: session.id,
            uri: Uri.file(trackFile.path).toString(),
            path: trackFile.path,
            title: 'track',
            playing: true,
            playWhenReady: true,
            processingState: 'ready',
            position: const Duration(seconds: 42),
            bufferedPosition: const Duration(seconds: 45),
            duration: const Duration(minutes: 3),
            volume: 1.0,
            boostGain: 1.0,
            channelSwapEnabled: false,
          ),
        );
        await provider.setSessionChannelSwap(session.id, true);

        expect(setAudioEffectsCalls, 1);
        expect(lastChannelSwapEnabled, isTrue);
        expect(session.channelSwapEnabled, isTrue);
        expect(session.state.playing, isTrue);
        expect(session.state.processingState, ProcessingState.ready);
        expect(session.position, const Duration(seconds: 42));
      },
    );

    test('setSessionSpeed snaps to fixed options and calls native', () async {
      var setSpeedCalls = 0;
      double? lastNativeSpeed;

      const track = MusicTrack(
        path: 'https://example.com/speed.mp3',
        displayName: 'track',
        groupKey: 'speed',
        groupTitle: 'Speed',
        groupSubtitle: 'Speed',
        isSingle: false,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            switch (call.method) {
              case NativePlaybackMethod.prepareSession:
                return <String, Object?>{'ok': true, 'value': null};
              case NativePlaybackMethod.setSpeed:
                setSpeedCalls++;
                final args = call.arguments as Map<Object?, Object?>;
                lastNativeSpeed = (args['speed'] as num?)?.toDouble();
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{
                    'sessionId': args['sessionId'] as String,
                    'uri': track.path,
                    'path': track.path,
                    'title': 'track',
                    'playing': false,
                    'playWhenReady': false,
                    'processingState': 'ready',
                    'positionMs': 0,
                    'bufferedPositionMs': 0,
                    'durationMs': const Duration(minutes: 3).inMilliseconds,
                    'volume': 1.0,
                    'speed': lastNativeSpeed,
                    'boostGain': 1.0,
                    'channelSwap': false,
                  },
                };
              default:
                return <String, Object?>{'ok': true, 'value': null};
            }
          });

      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
      await provider.spawnSession(track, autoPlay: false);
      final session = provider.activeSessions.single;

      await provider.setSessionSpeed(session.id, 1.6);

      expect(setSpeedCalls, 1);
      expect(lastNativeSpeed, closeTo(1.5, 0.001));
      expect(session.speed, closeTo(1.5, 0.001));
    });

    test('session audio effects sync through unified native payload', () async {
      var setAudioEffectsCalls = 0;
      Map<Object?, Object?>? lastEffects;

      const track = MusicTrack(
        path: 'https://example.com/effects.mp3',
        displayName: 'track',
        groupKey: 'effects',
        groupTitle: 'Effects',
        groupSubtitle: 'Effects',
        isSingle: false,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            switch (call.method) {
              case NativePlaybackMethod.prepareSession:
                return <String, Object?>{'ok': true, 'value': null};
              case NativePlaybackMethod.setAudioEffects:
                setAudioEffectsCalls++;
                final args = call.arguments as Map<Object?, Object?>;
                lastEffects = args['effects'] as Map<Object?, Object?>;
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{
                    'sessionId': args['sessionId'] as String,
                    'uri': track.path,
                    'path': track.path,
                    'title': 'track',
                    'playing': false,
                    'playWhenReady': false,
                    'processingState': 'ready',
                    'positionMs': 0,
                    'bufferedPositionMs': 0,
                    'durationMs': const Duration(minutes: 3).inMilliseconds,
                    'volume': 1.0,
                    'speed': 1.0,
                    'boostGain': 1.0,
                    'channelSwap': lastEffects?['channelSwapEnabled'] as bool?,
                    'audioEffects': lastEffects,
                    'eqCapabilities': <String, Object?>{
                      'supported': true,
                      'minGainDb': -6.0,
                      'maxGainDb': 6.0,
                      'bands': <Object?>[
                        <String, Object?>{'frequencyHz': 60},
                        <String, Object?>{'frequencyHz': 170},
                        <String, Object?>{'frequencyHz': 1000},
                        <String, Object?>{'frequencyHz': 3000},
                        <String, Object?>{'frequencyHz': 6000},
                      ],
                    },
                  },
                };
              default:
                return <String, Object?>{'ok': true, 'value': null};
            }
          });

      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
      await provider.spawnSession(track, autoPlay: false);
      final session = provider.activeSessions.single;
      session.applyNativeSnapshot(
        NativePlaybackSnapshot(
          sessionId: session.id,
          playing: false,
          playWhenReady: false,
          processingState: 'ready',
          position: Duration.zero,
          bufferedPosition: Duration.zero,
          volume: 1,
          boostGain: 1,
          channelSwapEnabled: false,
          eqCapabilities: const EqCapabilities(
            supported: true,
            minGainDb: -6,
            maxGainDb: 6,
            bands: <EqBandInfo>[
              EqBandInfo(frequencyHz: 60),
              EqBandInfo(frequencyHz: 170),
              EqBandInfo(frequencyHz: 1000),
              EqBandInfo(frequencyHz: 3000),
              EqBandInfo(frequencyHz: 6000),
            ],
          ),
        ),
      );

      await provider.setSessionSkipSilence(session.id, true);
      expect(lastEffects?['skipSilenceEnabled'], isTrue);

      await provider.setSessionNoiseReduction(session.id, true);
      expect(lastEffects?['noiseReductionEnabled'], isTrue);

      await provider.setSessionEqBandLevel(session.id, 1000, 7);
      final manualLevels = lastEffects?['eqBandLevels'] as List<Object?>;
      final manualBand = manualLevels.cast<Map<Object?, Object?>>().firstWhere(
        (entry) => entry['frequencyHz'] == 1000,
      );
      expect(manualBand['gainDb'], 6.0);

      final voicePreset = AudioProvider.builtInEqPresets.firstWhere(
        (preset) => preset.id == 'voice_clear',
      );
      await provider.applySessionEqPreset(session.id, voicePreset);
      expect(lastEffects?['eqPresetId'], 'voice_clear');
      expect(lastEffects?['eqEnabled'], isTrue);
      expect(setAudioEffectsCalls, greaterThanOrEqualTo(4));
      expect(session.audioEffects.eqPresetId, 'voice_clear');

      await provider.applySessionEqPreset(
        session.id,
        AudioProvider.builtInEqPresets.first,
      );
      expect(session.audioEffects.eqPresetId, 'flat');
      expect(session.audioEffects.eqEnabled, isTrue);
      expect(session.audioEffects.eqBandLevels, isEmpty);
    });

    test(
      'audio effect toggles keep optimistic state when native omits effects',
      () async {
        const track = MusicTrack(
          path: 'https://example.com/effects-missing-payload.mp3',
          displayName: 'track',
          groupKey: 'effects-missing-payload',
          groupTitle: 'Effects',
          groupSubtitle: 'Effects',
          isSingle: false,
        );

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  return <String, Object?>{'ok': true, 'value': null};
                case NativePlaybackMethod.setAudioEffects:
                  final args = call.arguments as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
                      'uri': track.path,
                      'path': track.path,
                      'title': 'track',
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': const Duration(minutes: 3).inMilliseconds,
                      'volume': 1.0,
                      'speed': 1.0,
                      'boostGain': 1.0,
                      'channelSwap': false,
                    },
                  };
                default:
                  return <String, Object?>{'ok': true, 'value': null};
              }
            });

        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
        await provider.spawnSession(track, autoPlay: false);
        final session = provider.activeSessions.single;

        await provider.setSessionSkipSilence(session.id, true);
        await provider.setSessionNoiseReduction(session.id, true);
        await provider.setSessionEqEnabled(session.id, true);

        expect(session.audioEffects.skipSilenceEnabled, isTrue);
        expect(session.audioEffects.noiseReductionEnabled, isTrue);
        expect(session.audioEffects.eqEnabled, isTrue);
      },
    );

    test(
      'audio effects lazily prepare a restored session before native sync',
      () async {
        const firstSessionId = 'restored_first';
        const secondSessionId = 'restored_second';
        const firstTrack = MusicTrack(
          path: 'https://example.com/restored/first.mp3',
          displayName: 'first',
          groupKey: 'restored',
          groupTitle: 'Restored',
          groupSubtitle: 'Restored',
          isSingle: false,
        );
        const secondTrack = MusicTrack(
          path: 'https://example.com/restored/second.mp3',
          displayName: 'second',
          groupKey: 'restored',
          groupTitle: 'Restored',
          groupSubtitle: 'Restored',
          isSingle: false,
        );

        final restoredRepository = AudioDatabaseRepository(
          database: AppDatabase.test(db),
        );
        await restoredRepository.saveAllTracks(<MusicTrack>[
          firstTrack,
          secondTrack,
        ]);
        await restoredRepository.saveAllSessions(<PersistedSession>[
          const PersistedSession(
            id: firstSessionId,
            trackPath: 'https://example.com/restored/first.mp3',
            loopModeIndex: 1,
            volume: 1.0,
            positionMs: 0,
            durationMs: 0,
            customQueueTracks: null,
            channelSwapEnabled: false,
            sortOrder: 0,
            createdAtMs: 1,
          ),
          const PersistedSession(
            id: secondSessionId,
            trackPath: 'https://example.com/restored/second.mp3',
            loopModeIndex: 1,
            volume: 1.0,
            positionMs: 0,
            durationMs: 0,
            customQueueTracks: null,
            channelSwapEnabled: false,
            sortOrder: 1,
            createdAtMs: 2,
          ),
        ]);
        SharedPreferences.setMockInitialValues(<String, Object>{
          'session_order_v1': json.encode(<String>[
            firstSessionId,
            secondSessionId,
          ]),
        });

        final preparedSessionIds = <String>{};
        var secondPrepareCalls = 0;
        var setAudioEffectsCalls = 0;
        Map<Object?, Object?>? lastEffects;

        Map<String, Object?> snapshotFor(
          String sessionId, {
          Object? audioEffects,
        }) {
          final track = sessionId == firstSessionId ? firstTrack : secondTrack;
          return <String, Object?>{
            'sessionId': sessionId,
            'uri': track.path,
            'path': track.path,
            'title': track.displayName,
            'playing': false,
            'playWhenReady': false,
            'processingState': 'ready',
            'positionMs': 0,
            'bufferedPositionMs': 0,
            'durationMs': const Duration(minutes: 3).inMilliseconds,
            'volume': 1.0,
            'speed': 1.0,
            'boostGain': 1.0,
            'channelSwap': false,
            'audioEffects': audioEffects,
          };
        }

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  final args = call.arguments as Map<Object?, Object?>;
                  final sessionId = args['sessionId'] as String;
                  preparedSessionIds.add(sessionId);
                  if (sessionId == secondSessionId) {
                    secondPrepareCalls++;
                  }
                  return <String, Object?>{
                    'ok': true,
                    'value': snapshotFor(sessionId),
                  };
                case NativePlaybackMethod.setAudioEffects:
                  final args = call.arguments as Map<Object?, Object?>;
                  final sessionId = args['sessionId'] as String;
                  if (!preparedSessionIds.contains(sessionId)) {
                    return <String, Object?>{
                      'ok': false,
                      'error': 'Unknown session.',
                    };
                  }
                  setAudioEffectsCalls++;
                  lastEffects = args['effects'] as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': snapshotFor(sessionId, audioEffects: lastEffects),
                  };
                case NativePlaybackMethod.setForegroundEnabled:
                  return <String, Object?>{'ok': true, 'value': null};
                case NativePlaybackMethod.snapshot:
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{'sessions': <Object?>[]},
                  };
                default:
                  return <String, Object?>{'ok': true, 'value': null};
              }
            });

        final restoredProvider = AudioProvider(
          notificationService: notificationService,
          audioDatabaseRepository: restoredRepository,
        );
        addTearDown(restoredProvider.dispose);

        for (var i = 0; i < 100; i++) {
          if (restoredProvider.activeSessions.length == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        final secondSession = restoredProvider.sessionById(secondSessionId);
        expect(secondSession, isNotNull);
        expect(secondSession!.loadedPath, isNull);

        await restoredProvider.setSessionSkipSilence(secondSessionId, true);

        expect(secondPrepareCalls, 1);
        expect(setAudioEffectsCalls, greaterThanOrEqualTo(1));
        expect(lastEffects?['skipSilenceEnabled'], isTrue);
        expect(secondSession.loadedPath, secondTrack.path);
        expect(secondSession.audioEffects.skipSilenceEnabled, isTrue);
      },
    );
  });

  group('playback queues', () {
    test('queue supports duplicate track entries and removal', () async {
      const track = MusicTrack(
        path: '/library/work/01.mp3',
        displayName: '01',
        groupKey: '/library/work',
        groupTitle: 'Work',
        groupSubtitle: 'Work',
        isSingle: false,
      );
      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);

      final queueSession = provider.createPlaybackQueue('Queue 1');
      expect(queueSession.isPlaybackQueue, isTrue);
      expect(queueSession.currentTrackPath, isEmpty);

      await provider.addTrackToPlaybackQueue(queueSession.id, track);
      await provider.addTrackToPlaybackQueue(queueSession.id, track);

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

      await provider.removePlaybackQueueEntry(
        queueSession.id,
        updated.playbackQueue!.entries.first.id,
      );
      expect(
        provider.sessionById(queueSession.id)?.customQueueTracks,
        hasLength(1),
      );
    });

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
      final queueSession = provider.createPlaybackQueue('Queue 1');
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

        await provider.spawnSession(loopTrack, autoPlay: false);
        await provider.spawnSessionWithQueue(const <MusicTrack>[
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
        await provider.seekSession(otherSession.id, otherSeekPosition);
        await provider.seekSessionToNext(otherSession.id);
        await provider.seekSessionToPrev(otherSession.id);

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
        remoteCoverUrl: 'https://example.com/cover.jpg',
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

      final restoredProvider = AudioProvider(
        notificationService: notificationService,
        audioDatabaseRepository: restoredRepository,
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

      await Future<void>.delayed(const Duration(milliseconds: 200));
      restoredProvider.dispose();
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
    test('dismissing active playback keeps session playing', () async {
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            nativeCalls.add(call.method);
            if (call.method == NativePlaybackMethod.prepareSession ||
                call.method == NativePlaybackMethod.dismissNotifications) {
              return <String, Object?>{'ok': true, 'value': null};
            }
            if (call.method == NativePlaybackMethod.pauseAll) {
              return <String, Object?>{'ok': true, 'value': null};
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationsChannel, (call) async {
            return null;
          });

      await provider.spawnSession(
        const MusicTrack(
          path: '/music/keep-playing.mp3',
          displayName: 'Keep Playing',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        ),
        autoPlay: false,
      );
      final session = provider.activeSessions.single;
      session
        ..loadedPath = session.currentTrackPath
        ..setOptimisticState(playing: true);

      await provider.dismissNotificationsAfterPauseAll();

      expect(session.state.playing, isTrue);
      expect(nativeCalls, contains(NativePlaybackMethod.dismissNotifications));
      expect(nativeCalls, isNot(contains(NativePlaybackMethod.pauseAll)));
    });
  });

  // ── optimistic playback state dedup ───────────────────────────

  group('file-system cover discovery', () {
    test(
      'folder cover resolves recursively on Windows-style libraries',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'audio_provider_cover_',
        );
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
        provider.addWatchedFolder(workDir.path, notify: false);
        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);

        expect(
          await provider.coverPathFutureForFolder(workDir.path),
          coverPath,
        );
        expect(await provider.coverPathFutureForTrack(track), coverPath);
      },
    );
  });

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
    test('single video track cover resolves from generated frame', () async {
      const trackPath = '/library/video/scene.mp4';
      const framePath = '/cache/video_scene.jpg';
      final calls = <MethodCall>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, (call) async {
            calls.add(call);
            if (call.method == FileCacheMethod.resolveVideoFrame) {
              return framePath;
            }
            return null;
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

      expect(await provider.coverPathFutureForTrack(videoTrack), framePath);
      expect(
        calls.where((call) => call.method == FileCacheMethod.resolveVideoFrame),
        hasLength(1),
      );
    });

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

    test(
      'discoverImagesInFolder scans the selected folder recursively',
      () async {
        final rootDir = await Directory.systemTemp.createTemp('folder_cover_');
        addTearDown(() async {
          if (await rootDir.exists()) {
            await rootDir.delete(recursive: true);
          }
        });

        final childDir = Directory(
          '${rootDir.path}${Platform.pathSeparator}Disc1',
        );
        await childDir.create(recursive: true);
        final coverA = File(
          '${rootDir.path}${Platform.pathSeparator}cover_a.jpg',
        );
        final coverB = File(
          '${childDir.path}${Platform.pathSeparator}cover_b.png',
        );
        final ignored = File(
          '${rootDir.path}${Platform.pathSeparator}note.txt',
        );
        await coverA.writeAsBytes(const <int>[1, 2, 3]);
        await coverB.writeAsBytes(const <int>[4, 5, 6]);
        await ignored.writeAsString('ignore');

        final images = await provider.discoverImagesInFolder(rootDir.path);

        expect(images, hasLength(2));
        expect(images, containsAll(<String>[coverA.path, coverB.path]));
      },
    );

    test(
      'setFolderManualCover updates all tracks under the folder scope',
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
        await File(coverPath).writeAsBytes(const <int>[4, 5, 6]);

        provider.addWatchedFolder(workDir.path, notify: false);
        provider.addTracks(
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

        await provider.setFolderManualCover(workDir.path, coverPath);

        final updatedTrack = provider.trackByPath(trackPath);
        expect(updatedTrack?.manualCoverPath, coverPath);
        expect(
          await provider.coverPathFutureForFolder(workDir.path),
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

        provider.addWatchedFolder(source.path, notify: false);
        provider.addTracks(<MusicTrack>[
          MusicTrack(
            path: trackFile.path,
            displayName: '01',
            groupKey: source.path,
            groupTitle: 'Old Folder',
            groupSubtitle: source.path,
            isSingle: false,
          ),
        ], notify: false);
        provider.setLibraryTrackExcluded(source.path, trackFile.path, true);

        final result = await provider.renameAudioDetailTargetToName(
          AudioDetail.empty(AudioDetailTarget.libraryRootFolder(source.path)),
          'New Folder',
        );
        final newFolderPath = result.detail.target.targetPath;
        final newTrackPath = '$newFolderPath${Platform.pathSeparator}01.mp3';

        expect(provider.watchedFolders, contains(newFolderPath));
        expect(provider.watchedFolders, isNot(contains(source.path)));
        expect(provider.excludedTracksForLibrary(newFolderPath), <String>[
          newTrackPath,
        ]);
        expect(provider.excludedTracksForLibrary(source.path), isEmpty);
        expect(
          provider
              .libraryEntriesForLibrary(newFolderPath)
              .where((entry) => entry.path == newTrackPath),
          hasLength(1),
        );
        expect(provider.trackByPath(newTrackPath), isNull);

        provider.clearLibraryExclusions(newFolderPath);

        expect(provider.trackByPath(newTrackPath), isNotNull);
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
        final coverFile = File(
          '${source.path}${Platform.pathSeparator}cover.jpg',
        );
        await source.create();
        await trackFile.writeAsBytes(const <int>[1, 2, 3]);
        await coverFile.writeAsBytes(const <int>[4, 5, 6]);

        final track = MusicTrack(
          path: trackFile.path,
          displayName: '01',
          groupKey: source.path,
          groupTitle: 'Old Folder',
          groupSubtitle: source.path,
          isSingle: false,
          manualCoverPath: coverFile.path,
        );
        provider.addWatchedFolder(source.path, notify: false);
        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
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

        await provider.spawnSession(track, autoPlay: false);
        await Future<void>.delayed(Duration.zero);
        final session = provider.activeSessions.single;

        final result = await provider.renameAudioDetailTargetToName(
          AudioDetail.empty(AudioDetailTarget.libraryRootFolder(source.path)),
          'New Folder',
        );
        final newFolderPath = result.detail.target.targetPath;
        final newTrackPath = '$newFolderPath${Platform.pathSeparator}01.mp3';
        final newCoverPath = '$newFolderPath${Platform.pathSeparator}cover.jpg';

        expect(session.currentTrackPath, newTrackPath);

        await provider.setSessionChannelSwap(session.id, true);

        expect(session.currentTrackPath, newTrackPath);
        final resolvedTrack = provider.trackByPath(trackFile.path);
        expect(resolvedTrack, isNotNull);
        expect(resolvedTrack?.path, newTrackPath);
        expect(resolvedTrack?.displayName, '01');
        expect(provider.getRootFolderName(trackFile.path), 'New Folder');
        expect(
          provider.coverPathForTrack(resolvedTrack, trackPath: trackFile.path),
          newCoverPath,
        );
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

        final restoredProvider = AudioProvider(
          notificationService: notificationService,
          audioDatabaseRepository: restoredRepository,
        );
        addTearDown(restoredProvider.dispose);

        for (var i = 0; i < 100; i++) {
          if (restoredProvider.activeSessions.isNotEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(restoredProvider.activeSessions, hasLength(1));
        final restoredSession = restoredProvider.activeSessions.single;
        expect(restoredSession.currentTrackPath, newTrackPath);
        final restoredTrack = restoredProvider.trackByPath(
          restoredSession.currentTrackPath,
        );
        expect(restoredTrack, isNotNull);
        expect(restoredTrack?.displayName, '01');
        expect(
          restoredProvider.getRootFolderName(restoredSession.currentTrackPath),
          'New Folder',
        );
        expect(
          restoredProvider.coverPathForTrack(
            restoredTrack,
            trackPath: restoredSession.currentTrackPath,
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
        provider.addTracks(
          <MusicTrack>[track(firstPath, 'first')],
          notify: false,
          persist: false,
        );
        await provider.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(firstPath),
          ).copyWith(rjCode: 'RJ111111'),
        );
        final firstSnapshot = await provider.audioLibraryCategorySnapshot();
        expect(firstSnapshot.entries, hasLength(1));

        provider.addTracks(
          <MusicTrack>[track(secondPath, 'second')],
          notify: false,
          persist: false,
        );
        await provider.saveAudioDetail(
          AudioDetail.empty(
            AudioDetailTarget.singleAudioFile(secondPath),
          ).copyWith(rjCode: 'RJ222222'),
        );

        final refreshedSnapshot = await provider.audioLibraryCategorySnapshot();

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
      'initial card detail snapshot commits during app interaction',
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
          AudioDetail.empty(target).copyWith(rjCode: 'RJ333333'),
        );

        await provider.audioLibraryCategorySnapshot();

        expect(provider.audioLibraryCategorySnapshotSync, isNotNull);
        expect(
          provider.audioLibraryCategorySnapshotSync?.detailFor(target)?.rjCode,
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

  group('metadata apply scope', () {
    test(
      'missingOnly fills empty fields without overwriting existing data',
      () async {
        final target = AudioDetailTarget.libraryRootFolder('/library/work');
        final detail = AudioDetail.empty(target).copyWith(
          rjCode: 'RJ111111',
          workTitle: 'Existing title',
          voiceActors: const <String>['Existing voice'],
        );

        final result = await provider.applyDlsiteMetadata(
          detail,
          DlsiteMetadata(
            rjCode: 'RJ222222',
            workTitle: 'Fetched title',
            circleName: 'Fetched circle',
            voiceActors: const <String>['Fetched voice'],
            tags: const <String>['ASMR'],
            releaseDate: DateTime(2024, 5, 6),
            salesCount: 1234,
            rating: 4.5,
          ),
          saveCover: false,
          missingOnly: true,
        );

        expect(result.detail.rjCode, 'RJ111111');
        expect(result.detail.workTitle, 'Existing title');
        expect(result.detail.voiceActors, const <String>['Existing voice']);
        expect(result.detail.circleName, 'Fetched circle');
        expect(result.detail.tags, const <String>['ASMR']);
        expect(result.detail.releaseDate, DateTime(2024, 5, 6));
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

        final future = provider.coverPathFutureForFolder(missingFolder);

        expect(provider.isCoverPathLoadingForFolder(missingFolder), isTrue);
        expect(await future, isNull);
        expect(provider.isCoverPathLoadingForFolder(missingFolder), isFalse);
      },
    );
  });

  group('library folder restore', () {
    test(
      'background scan progress does not notify visible library UI',
      () async {
        var notificationCount = 0;
        provider.addListener(() {
          notificationCount++;
        });

        provider.setScanning(true, background: true, notify: false);

        provider.setScanProgress(
          currentFolder: 'background-folder',
          foundCount: 1,
          duplicateCount: 2,
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(notificationCount, 0);

        provider.setScanning(false, notify: false);
        provider.setScanning(true);
        final afterForegroundStart = notificationCount;

        provider.setScanProgress(
          currentFolder: 'foreground-folder',
          foundCount: 3,
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(notificationCount, greaterThan(afterForegroundStart));

        provider.setScanning(false);
      },
    );

    test(
      'background refresh commits changed tracks once after batch',
      () async {
        var notificationCount = 0;
        provider.addListener(() {
          notificationCount++;
        });

        provider.setScanning(true, background: true, notify: false);
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
        provider.setScanning(false, notify: false);

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
          modifiedAt: await File(trackPath).lastModified(),
        );
        provider.addWatchedFolder(normalizedFolderPath, notify: false);
        provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
        provider.recordLibraryEntriesForTracks(
          normalizedFolderPath,
          <MusicTrack>[track],
          persist: false,
        );

        final beforeRevision = provider.libraryContentRevision;
        var notificationCount = 0;
        provider.addListener(() {
          notificationCount++;
        });

        final scanner = LibraryScannerService();
        await scanner.refreshWatchedFolders(
          provider: provider,
          i18n: AppLanguageProvider(),
          showSnack: (_) {},
          silent: true,
        );

        expect(provider.libraryContentRevision, beforeRevision);
        expect(notificationCount, 0);
        expect(provider.trackByPath(trackPath), isNotNull);
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
