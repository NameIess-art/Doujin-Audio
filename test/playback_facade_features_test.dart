import 'package:nameless_audio/features/player/domain/playback_persistence_repository.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/core/app_language.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'support/test_persistence_repository.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
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

  Future<PlaybackSession> addAudioEffectsSession(String trackPath) async {
    final track = MusicTrack(
      path: trackPath,
      displayName: path.basename(trackPath),
      groupKey: 'effects-race',
      groupTitle: 'Effects race',
      groupSubtitle: 'Effects race',
      isSingle: false,
    );
    runtimeGraph.library.addTracks(
      <MusicTrack>[track],
      notify: false,
      persist: false,
    );
    await runtimeGraph.playback.spawnSession(track, autoPlay: false);
    final session = runtimeGraph.playback.activeSessions.singleWhere(
      (candidate) => candidate.currentTrackPath == trackPath,
    );
    session.loadedPath = trackPath;
    return session;
  }

  group('duplicate work sessions', () {
    final first = MusicTrack(
      path: 'https://example.com/work/01.mp3',
      displayName: '01',
      groupKey: 'work-42',
      groupTitle: 'Work 42',
      groupSubtitle: 'Work 42',
      isSingle: false,
    );
    final second = MusicTrack(
      path: 'https://example.com/work/02.mp3',
      displayName: '02',
      groupKey: 'work-42',
      groupTitle: 'Work 42',
      groupSubtitle: 'Work 42',
      isSingle: false,
    );

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            return <String, Object?>{'ok': true, 'value': null};
          });
      runtimeGraph.library.addTracks(
        <MusicTrack>[first, second],
        notify: false,
        persist: false,
      );
    });

    test('new audio replaces an existing session from the same work', () async {
      await runtimeGraph.playback.spawnSession(first, autoPlay: false);
      await runtimeGraph.playback.spawnSession(second, autoPlay: false);
      await runtimeGraph.playback.pendingSessionPreparation;

      expect(runtimeGraph.playback.activeSessions, hasLength(1));
      expect(
        runtimeGraph.playback.activeSessions.single.currentTrackPath,
        second.path,
      );
    });

    test('duplicate works can be explicitly allowed', () async {
      await runtimeGraph.settings.setAllowDuplicateWorks(true);

      await runtimeGraph.playback.spawnSession(first, autoPlay: false);
      await runtimeGraph.playback.spawnSession(second, autoPlay: false);
      await runtimeGraph.playback.pendingSessionPreparation;

      expect(runtimeGraph.playback.activeSessions, hasLength(2));
    });
  });

  group('multi-session playback stability', () {
    test('setSessionSpeed snaps to fixed options and calls native', () async {
      var setSpeedCalls = 0;
      double? lastNativeSpeed;

      final track = MusicTrack(
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

      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await runtimeGraph.playback.spawnSession(track, autoPlay: false);
      final session = runtimeGraph.playback.activeSessions.single;

      await runtimeGraph.playback.setSessionSpeed(session.id, 1.6);

      expect(setSpeedCalls, 1);
      expect(lastNativeSpeed, closeTo(1.5, 0.001));
      expect(session.speed, closeTo(1.5, 0.001));
    });

    test('session audio effects sync through unified native payload', () async {
      var setAudioEffectsCalls = 0;
      Map<Object?, Object?>? lastEffects;

      final track = MusicTrack(
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

      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await runtimeGraph.playback.spawnSession(track, autoPlay: false);
      final session = runtimeGraph.playback.activeSessions.single;
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
          eqCapabilities: EqCapabilities(
            supported: true,
            minGainDb: -6,
            maxGainDb: 6,
            bands: <EqBandInfo>[
              const EqBandInfo(frequencyHz: 60),
              const EqBandInfo(frequencyHz: 170),
              const EqBandInfo(frequencyHz: 1000),
              const EqBandInfo(frequencyHz: 3000),
              const EqBandInfo(frequencyHz: 6000),
            ],
          ),
        ),
      );

      await runtimeGraph.playback.setSessionSkipSilence(session.id, true);
      expect(lastEffects?['skipSilenceEnabled'], isTrue);

      await runtimeGraph.playback.setSessionNoiseReduction(session.id, true);
      expect(lastEffects?['noiseReductionEnabled'], isTrue);

      await runtimeGraph.playback.setSessionEqBandLevel(session.id, 1000, 7);
      final manualLevels = lastEffects?['eqBandLevels'] as List<Object?>;
      final manualBand = manualLevels.cast<Map<Object?, Object?>>().firstWhere(
        (entry) => entry['frequencyHz'] == 1000,
      );
      expect(manualBand['gainDb'], 6.0);

      final voicePreset = builtInEqPresets.firstWhere(
        (preset) => preset.id == 'voice_clear',
      );
      await runtimeGraph.playback.applySessionEqPreset(session.id, voicePreset);
      expect(lastEffects?['eqPresetId'], 'voice_clear');
      expect(lastEffects?['eqEnabled'], isTrue);
      expect(setAudioEffectsCalls, greaterThanOrEqualTo(4));
      expect(session.audioEffects.eqPresetId, 'voice_clear');

      await runtimeGraph.playback.applySessionEqPreset(
        session.id,
        builtInEqPresets.first,
      );
      expect(session.audioEffects.eqPresetId, 'flat');
      expect(session.audioEffects.eqEnabled, isTrue);
      expect(session.audioEffects.eqBandLevels, isEmpty);
    });

    test(
      'same-session audio effects serialize and send the latest full state',
      () async {
        final native = _ControlledAudioEffectsNative();
        native.install();
        final session = await addAudioEffectsSession(
          'https://example.com/effects-race.mp3',
        );

        final noiseFuture = runtimeGraph.playback.setSessionNoiseReduction(
          session.id,
          true,
        );
        await native.waitForCallCount(1);
        final channelFuture = runtimeGraph.playback.setSessionChannelSwap(
          session.id,
          true,
        );
        final panningFuture = runtimeGraph.playback.setSessionPanning(
          session.id,
          0.6,
        );
        await Future<void>.delayed(Duration.zero);

        expect(native.maxActiveCalls, 1);
        expect(native.calls, hasLength(1));
        expect(session.audioEffects.noiseReductionEnabled, isTrue);
        expect(session.audioEffects.panning, 0.6);
        expect(session.channelSwapEnabled, isTrue);

        session.applyNativeSnapshot(
          _nativeSnapshot(
            session,
            audioEffects: AudioEffectsState.flat,
            channelSwapEnabled: false,
          ),
        );
        expect(session.audioEffects.noiseReductionEnabled, isTrue);
        expect(session.audioEffects.panning, 0.6);
        expect(session.channelSwapEnabled, isTrue);

        native.completeSuccess(0);
        await native.waitForCallCount(2);
        final latestPayload = native.calls[1].effects;
        expect(latestPayload['noiseReductionEnabled'], isTrue);
        expect(latestPayload['panning'], 0.6);
        expect(latestPayload['channelSwapEnabled'], isTrue);
        native.completeSuccess(1);

        await Future.wait(<Future<void>>[
          noiseFuture,
          channelFuture,
          panningFuture,
        ]);
        expect(native.maxActiveCalls, 1);
      },
    );

    test('stale failure does not roll back a newer optimistic state', () async {
      final native = _ControlledAudioEffectsNative();
      native.install();
      final session = await addAudioEffectsSession(
        'https://example.com/effects-stale-failure.mp3',
      );

      final noiseFuture = runtimeGraph.playback.setSessionNoiseReduction(
        session.id,
        true,
      );
      await native.waitForCallCount(1);
      final eqFuture = runtimeGraph.playback.setSessionEqEnabled(
        session.id,
        true,
      );

      native.completeFailure(0);
      await native.waitForCallCount(2);
      native.completeFailure(1);
      await native.waitForCallCount(3);
      expect(session.audioEffects.noiseReductionEnabled, isTrue);
      expect(session.audioEffects.eqEnabled, isTrue);

      native.completeSuccess(2);
      await Future.wait(<Future<void>>[noiseFuture, eqFuture]);
      expect(session.audioEffects.noiseReductionEnabled, isTrue);
      expect(session.audioEffects.eqEnabled, isTrue);
    });

    test(
      'latest failure rolls back to the most recent confirmed state',
      () async {
        runtimeGraph.playback.configurePersistence(enabled: true);
        final native = _ControlledAudioEffectsNative();
        native.install();
        final session = await addAudioEffectsSession(
          'https://example.com/effects-latest-failure.mp3',
        );

        final confirmedFuture = runtimeGraph.playback.setSessionNoiseReduction(
          session.id,
          true,
        );
        await native.waitForCallCount(1);
        native.completeSuccess(0);
        await confirmedFuture;

        final panningFuture = runtimeGraph.playback.setSessionPanning(
          session.id,
          0.4,
        );
        await native.waitForCallCount(2);
        final channelFuture = runtimeGraph.playback.setSessionChannelSwap(
          session.id,
          true,
        );
        native.completeSuccess(1);
        await native.waitForCallCount(3);
        native.completeFailure(2);
        await native.waitForCallCount(4);
        native.completeFailure(3);
        await Future.wait(<Future<void>>[panningFuture, channelFuture]);

        expect(session.audioEffects.noiseReductionEnabled, isTrue);
        expect(session.audioEffects.panning, 0.4);
        expect(session.channelSwapEnabled, isFalse);
        final persisted = (await TestPersistenceRepository(
          database: AppDatabase.test(db),
        ).loadAllSessions()).singleWhere((entry) => entry.id == session.id);
        expect(persisted.audioEffects.noiseReductionEnabled, isTrue);
        expect(persisted.audioEffects.panning, 0.4);
        expect(persisted.channelSwapEnabled, isFalse);
      },
    );

    test('different sessions synchronize audio effects concurrently', () async {
      await runtimeGraph.settings.setAllowDuplicateWorks(true);
      final native = _ControlledAudioEffectsNative();
      native.install();
      final first = await addAudioEffectsSession(
        'https://example.com/effects-session-a.mp3',
      );
      final second = await addAudioEffectsSession(
        'https://example.com/effects-session-b.mp3',
      );

      final firstFuture = runtimeGraph.playback.setSessionNoiseReduction(
        first.id,
        true,
      );
      final secondFuture = runtimeGraph.playback.setSessionEqEnabled(
        second.id,
        true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.id, isNot(second.id));
      expect(native.calls, hasLength(2));
      expect(native.activeCalls, 2);
      expect(native.maxActiveCalls, 2);
      native.completeSuccess(0);
      native.completeSuccess(1);
      await Future.wait(<Future<void>>[firstFuture, secondFuture]);
    });

    test('removed session ignores a pending audio-effects response', () async {
      final native = _ControlledAudioEffectsNative();
      native.install();
      final session = await addAudioEffectsSession(
        'https://example.com/effects-removed-session.mp3',
      );

      final updateFuture = runtimeGraph.playback.setSessionNoiseReduction(
        session.id,
        true,
      );
      await native.waitForCallCount(1);
      await runtimeGraph.playback.removeSession(session.id);
      native.completeSuccess(
        0,
        audioEffects: AudioEffectsState.flat,
        channelSwapEnabled: false,
      );
      await updateFuture;

      expect(runtimeGraph.playback.sessions, isNot(contains(session.id)));
      expect(session.audioEffects.noiseReductionEnabled, isTrue);
    });

    test('failed audio effect update restores state and persistence', () async {
      runtimeGraph.playback.configurePersistence(enabled: true);
      final track = MusicTrack(
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
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await runtimeGraph.playback.spawnSession(track, autoPlay: false);
      final session = runtimeGraph.playback.activeSessions.single;
      for (var i = 0; i < 50 && session.loadedPath == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      await runtimeGraph.playback.setSessionNoiseReduction(session.id, true);

      expect(session.audioEffects.noiseReductionEnabled, isFalse);
      final persisted = (await TestPersistenceRepository(
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
      final track = MusicTrack(
        path: '/music/skip-silence-playing.mp3',
        displayName: 'Playing track',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: 'Music',
        isSingle: false,
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await runtimeGraph.playback.spawnSession(track, autoPlay: false);
      await Future<void>.delayed(Duration.zero);
      final session = runtimeGraph.playback.activeSessions.single;
      session
        ..loadedPath = null
        ..state = PlayerState(true, ProcessingState.ready);

      await runtimeGraph.playback.setSessionSkipSilence(session.id, true);

      expect(playCalls, 1);
      expect(session.audioEffects.skipSilenceEnabled, isTrue);
    });

    test(
      'audio effect toggles keep optimistic state when native omits effects',
      () async {
        final track = MusicTrack(
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

        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await runtimeGraph.playback.spawnSession(track, autoPlay: false);
        final session = runtimeGraph.playback.activeSessions.single;

        await runtimeGraph.playback.setSessionSkipSilence(session.id, true);
        await runtimeGraph.playback.setSessionNoiseReduction(session.id, true);
        await runtimeGraph.playback.setSessionEqEnabled(session.id, true);

        expect(session.audioEffects.skipSilenceEnabled, isTrue);
        expect(session.audioEffects.noiseReductionEnabled, isTrue);
        expect(session.audioEffects.eqEnabled, isTrue);
      },
    );

    test(
      'console settings stay scoped to their session and do not become defaults',
      () async {
        runtimeGraph.playback.configurePersistence(enabled: true);
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final track = MusicTrack(
          path: 'https://example.com/remembered-console.mp3',
          displayName: 'track',
          groupKey: 'remembered-console',
          groupTitle: 'Remembered Console',
          groupSubtitle: 'Remembered Console',
          isSingle: false,
        );
        final secondTrack = MusicTrack(
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

        runtimeGraph.library.addTracks(
          <MusicTrack>[track, secondTrack],
          notify: false,
          persist: false,
        );
        await runtimeGraph.playback.spawnSession(track, autoPlay: false);
        final session = runtimeGraph.playback.activeSessions.single;

        await runtimeGraph.playback.setSessionVolume(session.id, 1.25);
        await runtimeGraph.playback.setSessionSpeed(session.id, 1.6);
        await runtimeGraph.playback.setSessionSkipSilence(session.id, true);
        await runtimeGraph.playback.setSessionNoiseReduction(session.id, true);
        await runtimeGraph.playback.setSessionVolumeNormalization(
          session.id,
          true,
        );
        await runtimeGraph.playback.setSessionPanning(session.id, -0.4);
        await runtimeGraph.playback.setSessionEqBandLevel(
          session.id,
          1000,
          2.5,
        );
        await runtimeGraph.playback.setSessionChannelSwap(session.id, true);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('playback_settings_v1'), isNull);

        final persistedSession = (await TestPersistenceRepository(
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

        await runtimeGraph.playback.spawnSession(secondTrack, autoPlay: false);
        final secondSession = runtimeGraph.playback.activeSessions.singleWhere(
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
        final restartGraph = createTestRuntimeGraph(
          notificationService: notificationService,
          persistenceRepository: TestPersistenceRepository(
            database: AppDatabase.test(restartDb),
          ),
          skipPersistence: false,
          startRuntime: true,
        );
        addTearDown(restartGraph.runtime.dispose);
        await restartGraph.playback.states.firstWhere(
          (state) => state.isInitialized,
        );
        restartGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await restartGraph.playback.spawnSession(track, autoPlay: false);

        final restoredSession = restartGraph.playback.activeSessions.single;
        expect(restoredSession.volume, 1.0);
        expect(restoredSession.speed, 1.0);
        expect(restoredSession.audioEffects, AudioEffectsState.flat);
        expect(restoredSession.channelSwapEnabled, isFalse);
      },
    );

    test(
      'failed paused console updates roll back and stay rolled back after restart',
      () async {
        runtimeGraph.playback.configurePersistence(enabled: true);
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final track = MusicTrack(
          path: 'https://example.com/paused-console.mp3',
          displayName: 'paused track',
          groupKey: 'paused-console',
          groupTitle: 'Paused Console',
          groupSubtitle: 'Paused Console',
          isSingle: false,
        );
        final repository = TestPersistenceRepository(
          database: AppDatabase.test(db),
        );
        await repository.saveAllTracks(<MusicTrack>[track]);

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

        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await runtimeGraph.playback.spawnSession(track, autoPlay: false);
        final session = runtimeGraph.playback.activeSessions.single;
        expect(session.state.playing, isFalse);

        await runtimeGraph.playback.setSessionSkipSilence(session.id, true);
        await runtimeGraph.playback.setSessionChannelSwap(session.id, true);

        final persisted = (await repository.loadAllSessions()).single;
        expect(persisted.audioEffects.skipSilenceEnabled, isFalse);
        expect(persisted.channelSwapEnabled, isFalse);

        await runtimeGraph.runtime.dispose();
        notificationService = PlaybackNotificationService();
        runtimeGraph = createTestRuntimeGraph(
          notificationService: notificationService,
          persistenceRepository: repository,
          skipPersistence: false,
          startRuntime: true,
        );
        await runtimeGraph.playback.states.firstWhere(
          (state) => state.isInitialized,
        );

        final restored = runtimeGraph.playback.activeSessions.single;
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
        final firstTrack = MusicTrack(
          path: 'https://example.com/restored/first.mp3',
          displayName: 'first',
          groupKey: 'restored',
          groupTitle: 'Restored',
          groupSubtitle: 'Restored',
          isSingle: false,
        );
        final secondTrack = MusicTrack(
          path: 'https://example.com/restored/second.mp3',
          displayName: 'second',
          groupKey: 'restored',
          groupTitle: 'Restored',
          groupSubtitle: 'Restored',
          isSingle: false,
        );

        final restoredRepository = TestPersistenceRepository(
          database: AppDatabase.test(db),
        );
        await restoredRepository.saveAllTracks(<MusicTrack>[
          firstTrack,
          secondTrack,
        ]);
        await restoredRepository.saveAllSessions(<PersistedPlaybackSession>[
          PersistedPlaybackSession(
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
          PersistedPlaybackSession(
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

        final restoredGraph = createTestRuntimeGraph(
          notificationService: notificationService,
          persistenceRepository: restoredRepository,
          skipPersistence: false,
          startRuntime: true,
        );
        addTearDown(restoredGraph.runtime.dispose);

        for (var i = 0; i < 100; i++) {
          if (restoredGraph.playback.activeSessions.length == 2) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        final secondSession = restoredGraph.playback.sessionById(
          secondSessionId,
        );
        expect(secondSession, isNotNull);
        expect(firstDeferredPlayerCreation, isFalse);
        expect(secondDeferredPlayerCreation, isTrue);
        expect(secondPrepareCalls, 1);
        expect(secondSession!.loadedPath, secondTrack.path);

        await restoredGraph.playback.setSessionSkipSilence(
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
        final oldTrack = MusicTrack(
          path: 'https://example.com/old.mp3',
          displayName: 'old',
          groupKey: 'old',
          groupTitle: 'Old',
          groupSubtitle: 'Old',
          isSingle: false,
        );
        const restoredSessionId = 'backup_restored_session';
        final restoredTrack = MusicTrack(
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

        runtimeGraph.library.addTracks(
          <MusicTrack>[oldTrack],
          notify: false,
          persist: false,
        );
        await runtimeGraph.playback.spawnSession(oldTrack, autoPlay: false);
        await runtimeGraph.settings.setAutoPlayAddedSessions(false);

        final databaseRepository = TestPersistenceRepository(
          database: AppDatabase.test(db),
        );
        await databaseRepository.saveAllTracks(<MusicTrack>[restoredTrack]);
        await databaseRepository.saveAllSessions(<PersistedPlaybackSession>[
          PersistedPlaybackSession(
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

        final coverGenerationBeforeReload =
            runtimeGraph.library.coverArtworkCacheService.generation;
        await runtimeGraph.persistence.reloadPersistedState();

        expect(clearAllCalls, greaterThanOrEqualTo(1));
        expect(
          runtimeGraph.library.coverArtworkCacheService.generation,
          greaterThan(coverGenerationBeforeReload),
        );
        expect(runtimeGraph.library.trackByPath(oldTrack.path), isNull);
        expect(runtimeGraph.library.trackByPath(restoredTrack.path), isNotNull);
        expect(runtimeGraph.library.watchedFolders, <String>['restored']);
        expect(runtimeGraph.settings.autoPlayAddedSessions, isTrue);
        expect(runtimeGraph.playback.activeSessions, hasLength(1));
        expect(
          runtimeGraph.playback.activeSessions.single.id,
          restoredSessionId,
        );
        expect(
          runtimeGraph.playback.activeSessions.single.currentTrackPath,
          restoredTrack.path,
        );
        expect(preparedPaths, contains(restoredTrack.path));
      },
    );
  });

  group('playback notification integration', () {
    test(
      'ordinary work session keeps the complete library switcher scope',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              return <String, Object?>{'ok': true, 'value': null};
            });
        final first = MusicTrack(
          path: r'C:\Audio\Work\01.mp3',
          displayName: '01',
          groupKey: r'C:\Audio\Work',
          groupTitle: 'Work',
          groupSubtitle: r'C:\Audio\Work',
          isSingle: false,
        );
        final second = MusicTrack(
          path: r'C:\Audio\Work\02.mp3',
          displayName: '02',
          groupKey: r'C:\Audio\Work',
          groupTitle: 'Work',
          groupSubtitle: r'C:\Audio\Work',
          isSingle: false,
        );
        runtimeGraph.library.addTracks(
          <MusicTrack>[first, second],
          notify: false,
          persist: false,
        );

        await runtimeGraph.playback.spawnSession(first, autoPlay: false);
        await runtimeGraph.playback.pendingSessionPreparation;

        final session = runtimeGraph.playback.ordinarySessions.single;
        expect(session.customQueueTracks, isNull);
        expect(
          runtimeGraph.audioPaths
              .tracksForSessionSwitcher(session.id)
              .map((track) => track.path),
          <String>[first.path, second.path],
        );
      },
    );

    test('passes ASMR remote cover to native session and queue', () async {
      Map<Object?, Object?>? prepareArguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.prepareSession) {
              prepareArguments = call.arguments as Map<Object?, Object?>;
            }
            return <String, Object?>{'ok': true, 'value': null};
          });

      final track = MusicTrack(
        path: 'https://example.com/asmr/01.mp3',
        displayName: '01',
        groupKey: 'asmr-work',
        groupTitle: 'ASMR Work',
        groupSubtitle: 'RJ000001',
        isSingle: false,
        remoteCoverUrl: 'https://example.com/cover.jpg',
        remoteMetadataKind: 'asmr.one',
      );
      runtimeGraph.library.addTracks(
        <MusicTrack>[track],
        notify: false,
        persist: false,
      );
      await runtimeGraph.playback.spawnSession(track, autoPlay: false);

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

      await runtimeGraph.playback.spawnSession(
        MusicTrack(
          path: '/music/keep-playing.mp3',
          displayName: 'Keep Playing',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        ),
        autoPlay: false,
      );
      final session = runtimeGraph.playback.activeSessions.single;
      session
        ..loadedPath = session.currentTrackPath
        ..setOptimisticState(playing: true);

      await runtimeGraph.notifications.dismissAfterPauseAll();

      expect(session.state.playing, isTrue);
      expect(nativeCalls, contains(NativePlaybackMethod.dismissNotifications));
      expect(nativeCalls, isNot(contains(NativePlaybackMethod.pauseAll)));
    });
  });

  // 鈹€鈹€ optimistic playback state dedup 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

  group('settings persistence', () {
    test('startup page is saved with playback settings', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});

      await runtimeGraph.settings.setStartupPage(StartupPage.playlist);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final prefs = await SharedPreferences.getInstance();
      final settings =
          json.decode(prefs.getString('playback_settings_v1')!)
              as Map<String, dynamic>;
      expect(settings['startupPage'], StartupPage.playlist.name);
    });

    test('DLsite language preference persists follow page selection', () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});

      await runtimeGraph.settings.setDlsiteMetadataLanguage(
        ContentLanguagePreference.en,
      );
      await runtimeGraph.settings.setDlsiteMetadataLanguage(
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

NativePlaybackSnapshot _nativeSnapshot(
  PlaybackSession session, {
  required AudioEffectsState audioEffects,
  required bool channelSwapEnabled,
}) {
  return NativePlaybackSnapshot(
    sessionId: session.id,
    path: session.currentTrackPath,
    playing: false,
    playWhenReady: false,
    processingState: 'ready',
    position: Duration.zero,
    bufferedPosition: Duration.zero,
    volume: 1,
    boostGain: 1,
    channelSwapEnabled: channelSwapEnabled,
    audioEffects: audioEffects,
  );
}

class _ControlledAudioEffectsCall {
  _ControlledAudioEffectsCall(this.arguments);

  final Map<Object?, Object?> arguments;
  final Completer<Object?> response = Completer<Object?>();

  Map<Object?, Object?> get effects =>
      arguments['effects']! as Map<Object?, Object?>;
}

class _ControlledAudioEffectsNative {
  final List<_ControlledAudioEffectsCall> calls =
      <_ControlledAudioEffectsCall>[];
  Completer<void>? _callAdded;
  int activeCalls = 0;
  int maxActiveCalls = 0;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
          if (call.method != NativePlaybackMethod.setAudioEffects) {
            return <String, Object?>{'ok': true, 'value': null};
          }
          final pending = _ControlledAudioEffectsCall(
            call.arguments! as Map<Object?, Object?>,
          );
          calls.add(pending);
          activeCalls++;
          if (activeCalls > maxActiveCalls) maxActiveCalls = activeCalls;
          _callAdded?.complete();
          _callAdded = null;
          try {
            return await pending.response.future;
          } finally {
            activeCalls--;
          }
        });
  }

  Future<void> waitForCallCount(int count) async {
    while (calls.length < count) {
      final signal = Completer<void>();
      _callAdded = signal;
      if (calls.length >= count) {
        _callAdded = null;
        return;
      }
      await signal.future;
    }
  }

  void completeSuccess(
    int index, {
    AudioEffectsState? audioEffects,
    bool? channelSwapEnabled,
  }) {
    final call = calls[index];
    final effects =
        audioEffects?.toPlatformMap(
          channelSwapEnabled:
              channelSwapEnabled ??
              call.effects['channelSwapEnabled'] as bool? ??
              false,
        ) ??
        call.effects;
    call.response.complete(<String, Object?>{
      'ok': true,
      'value': <String, Object?>{
        'sessionId': call.arguments['sessionId'] as String,
        'path': call.arguments['path'] as String?,
        'playing': false,
        'playWhenReady': false,
        'processingState': 'ready',
        'positionMs': 0,
        'bufferedPositionMs': 0,
        'volume': 1.0,
        'speed': 1.0,
        'boostGain': 1.0,
        'channelSwap':
            channelSwapEnabled ??
            effects['channelSwapEnabled'] as bool? ??
            false,
        'audioEffects': effects,
      },
    });
  }

  void completeFailure(int index) {
    calls[index].response.complete(<String, Object?>{
      'ok': false,
      'error': 'injected audio-effects rejection',
    });
  }
}
