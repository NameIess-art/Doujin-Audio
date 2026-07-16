import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/core/app_language.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:path/path.dart' as path;
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

  group('multi-session playback stability', () {
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
      await provider.playbackFacade.spawnSession(track, autoPlay: false);
      final session = provider.activeSessions.single;

      await provider.playbackFacade.setSessionSpeed(session.id, 1.6);

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
      await provider.playbackFacade.spawnSession(track, autoPlay: false);
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

      await provider.playbackFacade.setSessionSkipSilence(session.id, true);
      expect(lastEffects?['skipSilenceEnabled'], isTrue);

      await provider.playbackFacade.setSessionNoiseReduction(session.id, true);
      expect(lastEffects?['noiseReductionEnabled'], isTrue);

      await provider.playbackFacade.setSessionEqBandLevel(session.id, 1000, 7);
      final manualLevels = lastEffects?['eqBandLevels'] as List<Object?>;
      final manualBand = manualLevels.cast<Map<Object?, Object?>>().firstWhere(
        (entry) => entry['frequencyHz'] == 1000,
      );
      expect(manualBand['gainDb'], 6.0);

      final voicePreset = builtInEqPresets.firstWhere(
        (preset) => preset.id == 'voice_clear',
      );
      await provider.playbackFacade.applySessionEqPreset(
        session.id,
        voicePreset,
      );
      expect(lastEffects?['eqPresetId'], 'voice_clear');
      expect(lastEffects?['eqEnabled'], isTrue);
      expect(setAudioEffectsCalls, greaterThanOrEqualTo(4));
      expect(session.audioEffects.eqPresetId, 'voice_clear');

      await provider.playbackFacade.applySessionEqPreset(
        session.id,
        builtInEqPresets.first,
      );
      expect(session.audioEffects.eqPresetId, 'flat');
      expect(session.audioEffects.eqEnabled, isTrue);
      expect(session.audioEffects.eqBandLevels, isEmpty);
    });

    test('failed audio effect update restores state and persistence', () async {
      provider.playbackFacade.configurePersistence(enabled: true);
      const track = MusicTrack(
        path: 'https://example.com/effects-rollback.mp3',
        displayName: 'track',
        groupKey: 'effects-rollback',
        groupTitle: 'Effects',
        groupSubtitle: 'Effects',
        isSingle: false,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.setAudioEffects) {
              return <String, Object?>{
                'ok': false,
                'error': 'injected filter rejection',
              };
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
      await provider.playbackFacade.spawnSession(track, autoPlay: false);
      final session = provider.activeSessions.single;
      for (var i = 0; i < 50 && session.loadedPath == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await provider.playbackFacade.setSessionNoiseReduction(session.id, true);

      expect(session.audioEffects.noiseReductionEnabled, isFalse);
      final persisted = (await AudioDatabaseRepository(
        database: AppDatabase.test(db),
      ).loadAllSessions()).single;
      expect(persisted.audioEffects.noiseReductionEnabled, isFalse);
    });

    test('skip silence preparation preserves active playback intent', () async {
      var playCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.play) {
              playCalls++;
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      const track = MusicTrack(
        path: '/music/skip-silence-playing.mp3',
        displayName: 'Playing track',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: 'Music',
        isSingle: false,
      );
      provider.addTracks(<MusicTrack>[track], notify: false, persist: false);
      await provider.playbackFacade.spawnSession(track, autoPlay: false);
      await Future<void>.delayed(Duration.zero);
      final session = provider.activeSessions.single;
      session
        ..loadedPath = null
        ..state = PlayerState(true, ProcessingState.ready);

      await provider.playbackFacade.setSessionSkipSilence(session.id, true);

      expect(playCalls, 1);
      expect(session.audioEffects.skipSilenceEnabled, isTrue);
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
        await provider.playbackFacade.spawnSession(track, autoPlay: false);
        final session = provider.activeSessions.single;

        await provider.playbackFacade.setSessionSkipSilence(session.id, true);
        await provider.playbackFacade.setSessionNoiseReduction(
          session.id,
          true,
        );
        await provider.playbackFacade.setSessionEqEnabled(session.id, true);

        expect(session.audioEffects.skipSilenceEnabled, isTrue);
        expect(session.audioEffects.noiseReductionEnabled, isTrue);
        expect(session.audioEffects.eqEnabled, isTrue);
      },
    );

    test(
      'console settings stay scoped to their session and do not become defaults',
      () async {
        provider.playbackFacade.configurePersistence(enabled: true);
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        const track = MusicTrack(
          path: 'https://example.com/remembered-console.mp3',
          displayName: 'track',
          groupKey: 'remembered-console',
          groupTitle: 'Remembered Console',
          groupSubtitle: 'Remembered Console',
          isSingle: false,
        );
        const secondTrack = MusicTrack(
          path: 'https://example.com/independent-console.mp3',
          displayName: 'second track',
          groupKey: 'independent-console',
          groupTitle: 'Independent Console',
          groupSubtitle: 'Independent Console',
          isSingle: false,
        );

        Map<Object?, Object?>? lastEffects;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  final args = call.arguments as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
                      'uri': track.path,
                      'path': track.path,
                      'title': track.displayName,
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': const Duration(minutes: 3).inMilliseconds,
                      'volume': (args['volume'] as num?)?.toDouble() ?? 1.0,
                      'speed': (args['speed'] as num?)?.toDouble() ?? 1.0,
                      'boostGain': 1.0,
                      'channelSwap':
                          ((args['audioEffects']
                                  as Map<
                                    Object?,
                                    Object?
                                  >?)?['channelSwapEnabled']
                              as bool?) ??
                          false,
                      'audioEffects': args['audioEffects'],
                    },
                  };
                case NativePlaybackMethod.setVolume:
                  final args = call.arguments as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
                      'uri': track.path,
                      'path': track.path,
                      'title': track.displayName,
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': const Duration(minutes: 3).inMilliseconds,
                      'volume': (args['volume'] as num?)?.toDouble() ?? 1.0,
                      'speed': 1.0,
                      'boostGain': 1.0,
                      'channelSwap':
                          lastEffects?['channelSwapEnabled'] as bool? ?? false,
                      'audioEffects': lastEffects,
                    },
                  };
                case NativePlaybackMethod.setSpeed:
                  final args = call.arguments as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
                      'uri': track.path,
                      'path': track.path,
                      'title': track.displayName,
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': const Duration(minutes: 3).inMilliseconds,
                      'volume': 1.25,
                      'speed': (args['speed'] as num?)?.toDouble() ?? 1.0,
                      'boostGain': 1.0,
                      'channelSwap':
                          lastEffects?['channelSwapEnabled'] as bool? ?? false,
                      'audioEffects': lastEffects,
                    },
                  };
                case NativePlaybackMethod.setAudioEffects:
                  final args = call.arguments as Map<Object?, Object?>;
                  lastEffects = args['effects'] as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
                      'uri': track.path,
                      'path': track.path,
                      'title': track.displayName,
                      'playing': false,
                      'playWhenReady': false,
                      'processingState': 'ready',
                      'positionMs': 0,
                      'bufferedPositionMs': 0,
                      'durationMs': const Duration(minutes: 3).inMilliseconds,
                      'volume': 1.25,
                      'speed': 1.5,
                      'boostGain': 1.0,
                      'channelSwap':
                          lastEffects?['channelSwapEnabled'] as bool?,
                      'audioEffects': lastEffects,
                    },
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

        provider.addTracks(
          <MusicTrack>[track, secondTrack],
          notify: false,
          persist: false,
        );
        await provider.playbackFacade.spawnSession(track, autoPlay: false);
        final session = provider.activeSessions.single;

        await provider.playbackFacade.setSessionVolume(session.id, 1.25);
        await provider.playbackFacade.setSessionSpeed(session.id, 1.6);
        await provider.playbackFacade.setSessionSkipSilence(session.id, true);
        await provider.playbackFacade.setSessionNoiseReduction(
          session.id,
          true,
        );
        await provider.playbackFacade.setSessionVolumeNormalization(
          session.id,
          true,
        );
        await provider.playbackFacade.setSessionPanning(session.id, -0.4);
        await provider.playbackFacade.setSessionEqBandLevel(
          session.id,
          1000,
          2.5,
        );
        await provider.playbackFacade.setSessionChannelSwap(session.id, true);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('playback_settings_v1'), isNull);

        final persistedSession = (await AudioDatabaseRepository(
          database: AppDatabase.test(db),
        ).loadAllSessions()).single;
        expect(persistedSession.volume, 1.25);
        expect(persistedSession.speed, 1.5);
        expect(persistedSession.audioEffects.skipSilenceEnabled, isTrue);
        expect(persistedSession.audioEffects.noiseReductionEnabled, isTrue);
        expect(
          persistedSession.audioEffects.volumeNormalizationEnabled,
          isTrue,
        );
        expect(persistedSession.audioEffects.eqEnabled, isTrue);
        expect(persistedSession.audioEffects.eqBandLevels[1000], 2.5);
        expect(persistedSession.audioEffects.panning, -0.4);
        expect(persistedSession.channelSwapEnabled, isTrue);

        await provider.playbackFacade.spawnSession(
          secondTrack,
          autoPlay: false,
        );
        final secondSession = provider.activeSessions.singleWhere(
          (candidate) => candidate.currentTrackPath == secondTrack.path,
        );
        expect(secondSession.volume, 1.0);
        expect(secondSession.speed, 1.0);
        expect(secondSession.audioEffects, AudioEffectsState.flat);
        expect(secondSession.channelSwapEnabled, isFalse);

        final restartDbDir = await Directory.systemTemp.createTemp(
          'remembered_console_restart_',
        );
        addTearDown(() async {
          if (await restartDbDir.exists()) {
            await restartDbDir.delete(recursive: true);
          }
        });
        final restartDb = await databaseFactoryFfi.openDatabase(
          path.join(restartDbDir.path, 'restart.db'),
        );
        addTearDown(() => restartDb.close());
        await AppDatabase.createSchemaForTest(restartDb);
        final restartProvider = AudioProvider.test(
          notificationService: notificationService,
          audioDatabaseRepository: AudioDatabaseRepository(
            database: AppDatabase.test(restartDb),
          ),
          skipPersistence: false,
          startRuntime: true,
        );
        addTearDown(restartProvider.dispose);
        await restartProvider.playbackStateStream.firstWhere(
          (state) => state.isInitialized,
        );
        restartProvider.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await restartProvider.playbackFacade.spawnSession(
          track,
          autoPlay: false,
        );

        final restoredSession = restartProvider.activeSessions.single;
        expect(restoredSession.volume, 1.0);
        expect(restoredSession.speed, 1.0);
        expect(restoredSession.audioEffects, AudioEffectsState.flat);
        expect(restoredSession.channelSwapEnabled, isFalse);
      },
    );

    test(
      'failed paused console updates roll back and stay rolled back after restart',
      () async {
        provider.playbackFacade.configurePersistence(enabled: true);
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        const track = MusicTrack(
          path: 'https://example.com/paused-console.mp3',
          displayName: 'paused track',
          groupKey: 'paused-console',
          groupTitle: 'Paused Console',
          groupSubtitle: 'Paused Console',
          isSingle: false,
        );
        final repository = AudioDatabaseRepository(
          database: AppDatabase.test(db),
        );
        await repository.saveAllTracks(const <MusicTrack>[track]);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              final args = call.arguments as Map<Object?, Object?>?;
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  final audioEffects =
                      args!['audioEffects'] as Map<Object?, Object?>;
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      'sessionId': args['sessionId'] as String,
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
                      'channelSwap': audioEffects['channelSwapEnabled'] as bool,
                      'audioEffects': audioEffects,
                    },
                  };
                case NativePlaybackMethod.setAudioEffects:
                  return <String, Object?>{
                    'ok': false,
                    'error': 'Unknown session.',
                  };
                case NativePlaybackMethod.snapshot:
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{'sessions': <Object?>[]},
                  };
                case NativePlaybackMethod.setForegroundEnabled:
                  return <String, Object?>{'ok': true, 'value': null};
                default:
                  return <String, Object?>{'ok': true, 'value': null};
              }
            });

        provider.addTracks(
          const <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await provider.playbackFacade.spawnSession(track, autoPlay: false);
        final session = provider.activeSessions.single;
        expect(session.state.playing, isFalse);

        await provider.playbackFacade.setSessionSkipSilence(session.id, true);
        await provider.playbackFacade.setSessionChannelSwap(session.id, true);

        final persisted = (await repository.loadAllSessions()).single;
        expect(persisted.audioEffects.skipSilenceEnabled, isFalse);
        expect(persisted.channelSwapEnabled, isFalse);

        provider.dispose();
        notificationService = PlaybackNotificationService();
        provider = AudioProvider.test(
          notificationService: notificationService,
          audioDatabaseRepository: repository,
          skipPersistence: false,
          startRuntime: true,
        );
        await provider.playbackStateStream.firstWhere(
          (state) => state.isInitialized,
        );

        final restored = provider.activeSessions.single;
        expect(restored.state.playing, isFalse);
        expect(restored.audioEffects.skipSilenceEnabled, isFalse);
        expect(restored.channelSwapEnabled, isFalse);
      },
    );

    test(
      'restored sessions register natively without eagerly creating players',
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
        bool? firstDeferredPlayerCreation;
        bool? secondDeferredPlayerCreation;
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
                  final deferred = args['deferPlayerCreation'] as bool?;
                  if (sessionId == secondSessionId) {
                    secondPrepareCalls++;
                    secondDeferredPlayerCreation = deferred;
                  } else {
                    firstDeferredPlayerCreation = deferred;
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

        final restoredProvider = AudioProvider.test(
          notificationService: notificationService,
          audioDatabaseRepository: restoredRepository,
          skipPersistence: false,
          startRuntime: true,
        );
        addTearDown(restoredProvider.dispose);

        for (var i = 0; i < 100; i++) {
          if (restoredProvider.activeSessions.length == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        final secondSession = restoredProvider.sessionById(secondSessionId);
        expect(secondSession, isNotNull);
        expect(firstDeferredPlayerCreation, isFalse);
        expect(secondDeferredPlayerCreation, isTrue);
        expect(secondPrepareCalls, 1);
        expect(secondSession!.loadedPath, secondTrack.path);

        await restoredProvider.playbackFacade.setSessionSkipSilence(
          secondSessionId,
          true,
        );

        expect(secondPrepareCalls, 1);
        expect(setAudioEffectsCalls, greaterThanOrEqualTo(1));
        expect(lastEffects?['skipSilenceEnabled'], isTrue);
        expect(secondSession.loadedPath, secondTrack.path);
        expect(secondSession.audioEffects.skipSilenceEnabled, isTrue);
      },
    );

    test(
      'reload after backup restore replaces stale library and sessions',
      () async {
        const oldTrack = MusicTrack(
          path: 'https://example.com/old.mp3',
          displayName: 'old',
          groupKey: 'old',
          groupTitle: 'Old',
          groupSubtitle: 'Old',
          isSingle: false,
        );
        const restoredSessionId = 'backup_restored_session';
        const restoredTrack = MusicTrack(
          path: 'https://example.com/restored-after-backup.mp3',
          displayName: 'restored',
          groupKey: 'restored',
          groupTitle: 'Restored',
          groupSubtitle: 'Restored',
          isSingle: false,
        );

        final preparedPaths = <String>[];
        var clearAllCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  final args = call.arguments as Map<Object?, Object?>;
                  preparedPaths.add(args['path'] as String);
                  return <String, Object?>{'ok': true, 'value': null};
                case NativePlaybackMethod.clearAll:
                  clearAllCalls++;
                  return <String, Object?>{'ok': true, 'value': null};
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

        provider.addTracks(
          <MusicTrack>[oldTrack],
          notify: false,
          persist: false,
        );
        await provider.playbackFacade.spawnSession(oldTrack, autoPlay: false);
        await provider.settingsRepository.setAutoPlayAddedSessions(false);

        final databaseRepository = AudioDatabaseRepository(
          database: AppDatabase.test(db),
        );
        await databaseRepository.saveAllTracks(<MusicTrack>[restoredTrack]);
        await databaseRepository.saveAllSessions(<PersistedSession>[
          const PersistedSession(
            id: restoredSessionId,
            trackPath: 'https://example.com/restored-after-backup.mp3',
            loopModeIndex: 1,
            volume: 1.0,
            positionMs: 0,
            durationMs: 0,
            customQueueTracks: null,
            channelSwapEnabled: false,
            sortOrder: 0,
            createdAtMs: 1,
          ),
        ]);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('playback_settings_v1');
        await prefs.setString(
          'session_order_v1',
          json.encode(<String>[restoredSessionId]),
        );
        await prefs.setString(
          'watched_folders_v1',
          json.encode(<String>['restored']),
        );

        final coverGenerationBeforeReload = provider.coverGeneration;
        await provider.persistenceCoordinator.reloadPersistedState();

        expect(clearAllCalls, greaterThanOrEqualTo(1));
        expect(
          provider.coverGeneration,
          greaterThan(coverGenerationBeforeReload),
        );
        expect(provider.trackByPath(oldTrack.path), isNull);
        expect(provider.trackByPath(restoredTrack.path), isNotNull);
        expect(provider.watchedFolders, <String>['restored']);
        expect(provider.autoPlayAddedSessions, isTrue);
        expect(provider.activeSessions, hasLength(1));
        expect(provider.activeSessions.single.id, restoredSessionId);
        expect(
          provider.activeSessions.single.currentTrackPath,
          restoredTrack.path,
        );
        expect(preparedPaths, contains(restoredTrack.path));
      },
    );
  });

  group('playback notification integration', () {
    test('passes ASMR remote cover to native session and queue', () async {
      Map<Object?, Object?>? prepareArguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.prepareSession) {
              prepareArguments = call.arguments as Map<Object?, Object?>;
            }
            return <String, Object?>{'ok': true, 'value': null};
          });

      const track = MusicTrack(
        path: 'https://example.com/asmr/01.mp3',
        displayName: '01',
        groupKey: 'asmr-work',
        groupTitle: 'ASMR Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteCoverUrl: 'https://example.com/cover.jpg',
        remoteMetadataKind: 'asmr.one',
      );
      provider.addTracks(
        const <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await provider.playbackFacade.spawnSession(track, autoPlay: false);

      for (var i = 0; i < 20 && prepareArguments == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(prepareArguments?['artUri'], track.remoteCoverUrl);
      final queue = prepareArguments?['queue'] as List<Object?>?;
      expect(queue, isNotEmpty);
      expect(
        (queue!.first as Map<Object?, Object?>)['artUri'],
        track.remoteCoverUrl,
      );
    });

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

      await provider.playbackFacade.spawnSession(
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

      await provider.notificationFacade.dismissAfterPauseAll();

      expect(session.state.playing, isTrue);
      expect(nativeCalls, contains(NativePlaybackMethod.dismissNotifications));
      expect(nativeCalls, isNot(contains(NativePlaybackMethod.pauseAll)));
    });
  });

  // 鈹€鈹€ optimistic playback state dedup 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  group('settings persistence', () {
    test('startup page is saved with playback settings', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});

      await provider.settingsRepository.setStartupPage(StartupPage.playlist);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prefs = await SharedPreferences.getInstance();
      final settings =
          json.decode(prefs.getString('playback_settings_v1')!)
              as Map<String, dynamic>;
      expect(settings['startupPage'], StartupPage.playlist.name);
    });

    test('DLsite language preference persists follow page selection', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});

      await provider.settingsRepository.setDlsiteMetadataLanguage(
        ContentLanguagePreference.en,
      );
      await provider.settingsRepository.setDlsiteMetadataLanguage(
        ContentLanguagePreference.followPage,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prefs = await SharedPreferences.getInstance();
      final settings =
          json.decode(prefs.getString('playback_settings_v1')!)
              as Map<String, dynamic>;
      expect(
        settings['dlsiteMetadataLanguage'],
        ContentLanguagePreference.followPage.name,
      );
    });
  });
}
