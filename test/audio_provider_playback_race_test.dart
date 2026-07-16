import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/core/platform/notifications_platform_service.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/audio_provider_test_fixture.dart';

void main() {
  AudioProviderTestFixture.initialize();

  late AudioProviderTestFixture fixture;
  late AudioProvider provider;
  late Database db;

  setUp(() async {
    fixture = await AudioProviderTestFixture.create();
    provider = fixture.provider;
    db = fixture.database;
  });

  tearDown(() async {
    await fixture.dispose(currentProvider: provider);
  });

  group('multi-session playback stability', () {
    test('initial state has no active sessions', () {
      expect(provider.activeSessions, isEmpty);
    });

    test('added sessions follow the auto-play setting', () async {
      var prepareCalls = 0;
      var playCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.prepareSession) {
              prepareCalls++;
            } else if (call.method == NativePlaybackMethod.play) {
              playCalls++;
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      const track = MusicTrack(
        path: '/music/auto-play-setting.mp3',
        displayName: 'Auto Play Setting',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );

      await provider.settingsRepository.setAutoPlayAddedSessions(false);
      await provider.playbackFacade.spawnSession(track);
      for (var i = 0; i < 20 && prepareCalls < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(prepareCalls, 1);
      expect(playCalls, 0);

      await provider.settingsRepository.setAutoPlayAddedSessions(true);
      await provider.playbackFacade.spawnSession(track);
      for (var i = 0; i < 20 && playCalls < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(prepareCalls, 2);
      expect(playCalls, 1);
    });

    test('ASMR.ONE playback cache setting is disabled by default', () async {
      expect(provider.asmrPlaybackCacheEnabled, isFalse);

      await provider.settingsRepository.setAsmrPlaybackCacheEnabled(true);

      expect(provider.asmrPlaybackCacheEnabled, isTrue);
      expect(
        provider.settingsStateStream,
        emits(
          isA<SettingsState>().having(
            (state) => state.asmrPlaybackCacheEnabled,
            'asmr playback cache',
            isTrue,
          ),
        ),
      );
    });

    test('toggling play-pause with unknown id does not throw', () {
      provider.playbackFacade.toggleSessionPlayPause('non_existent_session');
      expect(provider.activeSessions, isEmpty);
    });

    test('single-thread playback uses one exclusive native play', () async {
      Map<Object?, Object?>? playArguments;
      var pauseCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            final arguments = call.arguments as Map<Object?, Object?>?;
            if (call.method == NativePlaybackMethod.pause) {
              pauseCalls++;
            }
            if (call.method == NativePlaybackMethod.play) {
              playArguments = arguments;
            }
            if (call.method == NativePlaybackMethod.prepareSession ||
                call.method == NativePlaybackMethod.play) {
              final sessionId = arguments?['sessionId'] as String;
              final path = arguments?['path'] as String? ?? '';
              final commandId = arguments?['transportCommandId'] as int?;
              return <String, Object?>{
                'ok': true,
                'value': <String, Object?>{
                  'sessionId': sessionId,
                  'path': path,
                  'uri': arguments?['uri'] as String?,
                  'playing': call.method == NativePlaybackMethod.play,
                  'playWhenReady': call.method == NativePlaybackMethod.play,
                  'processingState': 'ready',
                  'positionMs': 0,
                  'bufferedPositionMs': 0,
                  'durationMs': 1000,
                  'volume': 1.0,
                  'channelSwap': false,
                  'transportCommandId': commandId,
                },
              };
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      const firstTrack = MusicTrack(
        path: '/music/exclusive-first.mp3',
        displayName: 'First',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );
      const secondTrack = MusicTrack(
        path: '/music/exclusive-second.mp3',
        displayName: 'Second',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );

      await provider.playbackFacade.spawnSession(firstTrack, autoPlay: false);
      await provider.playbackFacade.spawnSession(secondTrack, autoPlay: false);
      for (var i = 0; i < 100; i++) {
        if (provider.activeSessions.length == 2 &&
            provider.activeSessions.every(
              (session) => session.loadedPath != null && !session.isLoading,
            )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final firstSession = provider.activeSessions.firstWhere(
        (session) => PathMatcher.equalsNormalized(
          session.currentTrackPath,
          firstTrack.path,
        ),
      );
      final secondSession = provider.activeSessions.firstWhere(
        (session) => PathMatcher.equalsNormalized(
          session.currentTrackPath,
          secondTrack.path,
        ),
      );
      firstSession.setOptimisticState(
        playing: true,
        processingState: ProcessingState.ready,
      );

      final toggle = provider.playbackFacade.toggleSessionPlayPause(
        secondSession.id,
      );
      expect(firstSession.effectivePlaying, isFalse);
      expect(secondSession.effectivePlaying, isTrue);
      await toggle;

      expect(pauseCalls, 0);
      expect(playArguments?['exclusive'], isTrue);
      expect(playArguments?['transportCommandId'], isPositive);
    });

    test('rapid play pause play keeps the latest intent', () async {
      final playCalls = <Map<Object?, Object?>>[];
      final playResponses = <Completer<Object?>>[];
      Map<Object?, Object?>? pauseCall;
      final pauseResponse = Completer<Object?>();

      Map<String, Object?> snapshotFor(
        Map<Object?, Object?> arguments, {
        required bool playing,
      }) {
        return <String, Object?>{
          'sessionId': arguments['sessionId'] as String,
          'playing': playing,
          'playWhenReady': playing,
          'processingState': 'ready',
          'positionMs': 0,
          'bufferedPositionMs': 0,
          'durationMs': 1000,
          'volume': 1.0,
          'channelSwap': false,
          'transportCommandId': arguments['transportCommandId'] as int,
        };
      }

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            final arguments = call.arguments as Map<Object?, Object?>?;
            if (call.method == NativePlaybackMethod.prepareSession) {
              return <String, Object?>{
                'ok': true,
                'value': <String, Object?>{
                  'sessionId': arguments?['sessionId'] as String,
                  'path': arguments?['path'] as String,
                  'uri': arguments?['uri'] as String,
                  'playing': false,
                  'playWhenReady': false,
                  'processingState': 'ready',
                  'positionMs': 0,
                  'bufferedPositionMs': 0,
                  'durationMs': 1000,
                  'volume': 1.0,
                  'channelSwap': false,
                },
              };
            }
            if (call.method == NativePlaybackMethod.play) {
              final completer = Completer<Object?>();
              playCalls.add(arguments!);
              playResponses.add(completer);
              return completer.future;
            }
            if (call.method == NativePlaybackMethod.pause) {
              pauseCall = arguments;
              return pauseResponse.future;
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      const track = MusicTrack(
        path: '/music/rapid-toggle.mp3',
        displayName: 'Rapid Toggle',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );
      await provider.playbackFacade.spawnSession(track, autoPlay: false);
      for (var i = 0; i < 100; i++) {
        if (provider.activeSessions.singleOrNull?.loadedPath != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final session = provider.activeSessions.single;

      final firstPlay = provider.playbackFacade.toggleSessionPlayPause(
        session.id,
      );
      for (var i = 0; i < 20 && playCalls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(session.effectivePlaying, isTrue);

      final pause = provider.playbackFacade.toggleSessionPlayPause(session.id);
      for (var i = 0; i < 20 && pauseCall == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(session.effectivePlaying, isFalse);

      final lastPlay = provider.playbackFacade.toggleSessionPlayPause(
        session.id,
      );
      for (var i = 0; i < 20 && playCalls.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(session.effectivePlaying, isTrue);

      final firstPlayCall = playCalls.first;
      final lastPlayCall = playCalls.last;
      playResponses.last.complete(<String, Object?>{
        'ok': true,
        'value': snapshotFor(lastPlayCall, playing: true),
      });
      pauseResponse.complete(<String, Object?>{
        'ok': true,
        'value': snapshotFor(pauseCall!, playing: false),
      });
      playResponses.first.complete(<String, Object?>{
        'ok': true,
        'value': snapshotFor(firstPlayCall, playing: true),
      });
      await Future.wait([firstPlay, pause, lastPlay]);

      expect(
        (firstPlayCall['transportCommandId'] as int) <
            (pauseCall!['transportCommandId'] as int),
        isTrue,
      );
      expect(
        (pauseCall!['transportCommandId'] as int) <
            (lastPlayCall['transportCommandId'] as int),
        isTrue,
      );
      expect(session.effectivePlaying, isTrue);
      expect(session.state.playing, isTrue);
    });

    testWidgets(
      'defers playback notification sync while scrolling interaction is active',
      (tester) async {
        var notificationSyncCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(notificationsChannel, (call) async {
              if (call.method ==
                  NotificationsMethod.syncUnifiedPlaybackNotifications) {
                notificationSyncCalls++;
              }
              return null;
            });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              return <String, Object?>{'ok': true, 'value': null};
            });

        provider.dispose();
        provider = AudioProvider.test(
          notificationService: PlaybackNotificationService(
            notificationsPlatformService: NotificationsPlatformService(
              channel: notificationsChannel,
              isAndroidOverride: true,
              timeout: const Duration(milliseconds: 50),
            ),
          ),
          audioDatabaseRepository: AudioDatabaseRepository(
            database: AppDatabase.test(db),
          ),
        );
        const track = MusicTrack(
          path: '/music/notification-scroll.mp3',
          displayName: 'Notification Scroll',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        );

        final interactionSource = Object();
        final coordinator = UiInteractionCoordinator.instance;
        coordinator.beginInteraction(interactionSource);
        addTearDown(() => coordinator.cancelInteraction(interactionSource));

        await provider.playbackFacade.spawnSession(track, autoPlay: false);
        await tester.pump(const Duration(milliseconds: 140));
        expect(notificationSyncCalls, 0);

        coordinator.endInteraction(interactionSource);
        await tester.pump(const Duration(milliseconds: 170));
        await tester.pump();

        expect(notificationSyncCalls, 1);
      },
    );

    test('sessionById returns null for unknown id', () {
      expect(provider.sessionById('nonexistent'), isNull);
    });

    test(
      'failed queue prepare restores the previous native track without committing target state',
      () async {
        const first = MusicTrack(
          path: 'https://example.com/transaction-a.mp3',
          displayName: 'A',
          groupKey: 'transaction',
          groupTitle: 'Transaction',
          groupSubtitle: 'Transaction',
          isSingle: false,
          duration: Duration(minutes: 3),
        );
        const second = MusicTrack(
          path: 'https://example.com/transaction-b.mp3',
          displayName: 'B',
          groupKey: 'transaction',
          groupTitle: 'Transaction',
          groupSubtitle: 'Transaction',
          isSingle: false,
          duration: Duration(minutes: 4),
        );
        final preparedPaths = <String>[];
        var restoreCalls = 0;

        Map<String, Object?> snapshot(
          String pathValue, {
          bool playing = false,
        }) {
          return <String, Object?>{
            'sessionId': provider.activeSessions.single.id,
            'uri': pathValue,
            'path': pathValue,
            'title': pathValue == first.path ? 'A' : 'B',
            'playing': playing,
            'playWhenReady': playing,
            'processingState': 'ready',
            'positionMs': pathValue == first.path
                ? const Duration(seconds: 47).inMilliseconds
                : 0,
            'bufferedPositionMs': 0,
            'durationMs': pathValue == first.path
                ? first.duration.inMilliseconds
                : second.duration.inMilliseconds,
            'volume': 1.0,
            'speed': 1.0,
            'boostGain': 1.0,
            'channelSwap': false,
            'queueIndex': pathValue == first.path ? 0 : 1,
          };
        }

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              final args =
                  (call.arguments as Map<Object?, Object?>?) ?? const {};
              switch (call.method) {
                case NativePlaybackMethod.prepareSession:
                  final requestedPath = args['path'] as String;
                  preparedPaths.add(requestedPath);
                  if (requestedPath == second.path) {
                    return <String, Object?>{
                      'ok': false,
                      'error': 'injected prepare failure',
                    };
                  }
                  if (preparedPaths.length > 1) restoreCalls++;
                  return <String, Object?>{
                    'ok': true,
                    'value': snapshot(first.path),
                  };
                case NativePlaybackMethod.play:
                  return <String, Object?>{
                    'ok': true,
                    'value': <String, Object?>{
                      ...snapshot(first.path, playing: true),
                      'transportCommandId': args['transportCommandId'],
                    },
                  };
                default:
                  return <String, Object?>{'ok': true, 'value': null};
              }
            });

        provider.addTracks(
          <MusicTrack>[first, second],
          notify: false,
          persist: false,
        );
        await provider.playbackFacade.spawnSessionWithQueue(const <MusicTrack>[
          first,
          second,
        ], autoPlay: false);
        final session = provider.activeSessions.single;
        for (var i = 0; i < 50 && session.loadedPath == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        session.applyNativeSnapshot(
          NativePlaybackSnapshot.fromMap(snapshot(first.path, playing: true)),
        );

        await provider.playbackFacade.switchSessionQueueTrack(session.id, 1);

        expect(session.currentTrackPath, first.path);
        expect(session.loadedPath, first.path);
        expect(session.position, const Duration(seconds: 47));
        expect(session.duration, first.duration);
        expect(session.currentQueueIndex, 0);
        expect(session.state.playing, isTrue);
        expect(session.playbackError, isNotNull);
        expect(restoreCalls, 1);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final persisted = (await AudioDatabaseRepository(
          database: AppDatabase.test(db),
        ).loadAllSessions()).single;
        expect(persisted.trackPath, first.path);
      },
    );

    test('timer fallback records only sessions that actually paused', () async {
      const first = MusicTrack(
        path: 'https://example.com/timer-a.mp3',
        displayName: 'A',
        groupKey: 'timer',
        groupTitle: 'Timer',
        groupSubtitle: 'Timer',
        isSingle: false,
      );
      const second = MusicTrack(
        path: 'https://example.com/timer-b.mp3',
        displayName: 'B',
        groupKey: 'timer',
        groupTitle: 'Timer',
        groupSubtitle: 'Timer',
        isSingle: false,
      );
      String? failingSessionId;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            final args = (call.arguments as Map<Object?, Object?>?) ?? const {};
            if (call.method == NativePlaybackMethod.pause &&
                args['sessionId'] == failingSessionId) {
              return <String, Object?>{
                'ok': false,
                'error': 'injected pause failure',
              };
            }
            if (call.method == NativePlaybackMethod.pause) {
              final sessionId = args['sessionId'] as String;
              final session = provider.sessionById(sessionId)!;
              return <String, Object?>{
                'ok': true,
                'value': <String, Object?>{
                  'sessionId': sessionId,
                  'path': session.currentTrackPath,
                  'uri': session.currentTrackPath,
                  'playing': false,
                  'playWhenReady': false,
                  'processingState': 'ready',
                  'positionMs': 0,
                  'bufferedPositionMs': 0,
                  'volume': 1.0,
                  'speed': 1.0,
                  'boostGain': 1.0,
                  'channelSwap': false,
                  'transportCommandId': args['transportCommandId'],
                },
              };
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      provider.addTracks(
        <MusicTrack>[first, second],
        notify: false,
        persist: false,
      );
      await provider.playbackFacade.spawnSession(first, autoPlay: false);
      await provider.playbackFacade.spawnSession(second, autoPlay: false);
      for (var i = 0; i < 50 && provider.activeSessions.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final sessions = provider.activeSessions.toList(growable: false);
      failingSessionId = sessions[1].id;
      for (final session in sessions) {
        session.state = PlayerState(true, ProcessingState.ready);
      }
      final future = DateTime.now().add(const Duration(minutes: 2));
      provider.timerFacade.setAutoResume(true, future.hour, future.minute);
      provider.timerFacade.configureTimer(
        TimerMode.manual,
        const Duration(milliseconds: 20),
      );
      provider.timerFacade.startCountdown();

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(sessions[0].state.playing, isFalse);
      expect(sessions[1].state.playing, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final runtime =
          json.decode(prefs.getString('timer_runtime_v1')!)
              as Map<String, dynamic>;
      expect(runtime['pausedSessionIds'], <Object?>[sessions[0].id]);
    });

    test(
      'overdue auto-resume retains only sessions that failed to restart',
      () async {
        const first = MusicTrack(
          path: 'https://example.com/resume-a.mp3',
          displayName: 'A',
          groupKey: 'resume',
          groupTitle: 'Resume',
          groupSubtitle: 'Resume',
          isSingle: false,
        );
        const second = MusicTrack(
          path: 'https://example.com/resume-b.mp3',
          displayName: 'B',
          groupKey: 'resume',
          groupTitle: 'Resume',
          groupSubtitle: 'Resume',
          isSingle: false,
        );
        String? failingSessionId;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              final args =
                  (call.arguments as Map<Object?, Object?>?) ?? const {};
              if (call.method == NativePlaybackMethod.play &&
                  args['sessionId'] == failingSessionId) {
                return <String, Object?>{
                  'ok': false,
                  'error': 'injected play failure',
                };
              }
              if (call.method == NativePlaybackMethod.play) {
                final sessionId = args['sessionId'] as String;
                final session = provider.sessionById(sessionId)!;
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{
                    'sessionId': sessionId,
                    'path': session.currentTrackPath,
                    'uri': session.currentTrackPath,
                    'playing': true,
                    'playWhenReady': true,
                    'processingState': 'ready',
                    'positionMs': 0,
                    'bufferedPositionMs': 0,
                    'volume': 1.0,
                    'speed': 1.0,
                    'boostGain': 1.0,
                    'channelSwap': false,
                    'transportCommandId': args['transportCommandId'],
                  },
                };
              }
              return <String, Object?>{'ok': true, 'value': null};
            });
        provider.addTracks(
          <MusicTrack>[first, second],
          notify: false,
          persist: false,
        );
        await provider.playbackFacade.spawnSession(first, autoPlay: false);
        await provider.playbackFacade.spawnSession(second, autoPlay: false);
        final sessions = provider.activeSessions.toList(growable: false);
        failingSessionId = sessions[1].id;
        for (final session in sessions) {
          session.state = PlayerState(false, ProcessingState.ready);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'timer_runtime_v1',
          json.encode(<String, Object?>{
            'timerMode': TimerMode.manual.index,
            'timerDurationMs': 1000,
            'timerWaitingForPlayback': false,
            'timerEndsAtWallClockMs': null,
            'autoResumeEnabled': true,
            'autoResumeHour': 7,
            'autoResumeMinute': 0,
            'autoResumeAtMs': DateTime.now()
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch,
            'pausedSessionIds': sessions.map((session) => session.id).toList(),
            'generation': 9,
          }),
        );

        await provider.timerFacade.loadRuntimeFromSystem();

        expect(sessions[0].state.playing, isTrue);
        expect(sessions[1].state.playing, isFalse);
        final runtime =
            json.decode(prefs.getString('timer_runtime_v1')!)
                as Map<String, dynamic>;
        expect(runtime['pausedSessionIds'], <Object?>[sessions[1].id]);
        expect(runtime['autoResumeAtMs'], isNotNull);
      },
    );

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
          for (var attempt = 0; attempt < 6; attempt++) {
            if (!await tempDir.exists()) return;
            try {
              await tempDir.delete(recursive: true);
              return;
            } on FileSystemException {
              if (attempt == 5) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
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
          isSingle: true,
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
        await provider.playbackFacade.spawnSession(track, autoPlay: false);

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
        await provider.playbackFacade.setSessionChannelSwap(session.id, true);

        expect(setAudioEffectsCalls, 1);
        expect(lastChannelSwapEnabled, isTrue);
        expect(session.channelSwapEnabled, isTrue);
        expect(session.state.playing, isTrue);
        expect(session.state.processingState, ProcessingState.ready);
        expect(session.position, const Duration(seconds: 42));
      },
    );
  });

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
}
