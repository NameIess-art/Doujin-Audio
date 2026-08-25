import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/core/platform/notifications_platform_service.dart';
import 'package:doujin_audio/core/media/path_matcher.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  late AppRuntimeTestFixture fixture;
  late AppRuntimeGraph runtimeGraph;
  late Database db;

  setUp(() async {
    fixture = await AppRuntimeTestFixture.create();
    runtimeGraph = fixture.runtimeGraph;
    db = fixture.database;
  });

  tearDown(() async {
    await fixture.dispose(currentGraph: runtimeGraph);
  });

  group('multi-session playback stability', () {
    test('initial state has no active sessions', () {
      expect(runtimeGraph.playback.activeSessions, isEmpty);
    });

    test(
      'runtime restore keeps a surviving native session authoritative',
      () async {
        final track = MusicTrack(
          path: '/music/native-survives.mp3',
          displayName: 'Native Survives',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        );
        final session = PlaybackSession(
          id: 'native-survives',
          currentTrackPath: track.path,
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 0.4,
          createdAt: DateTime(2026),
          state: PlayerState(false, ProcessingState.idle),
          customQueueTracks: <MusicTrack>[track],
        );
        runtimeGraph.playback.registerSession(session);
        var prepareCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              if (call.method == NativePlaybackMethod.prepareSession) {
                prepareCalls++;
              }
              if (call.method == NativePlaybackMethod.snapshot) {
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{
                    'focusedSessionId': session.id,
                    'sessions': <Object?>[
                      <String, Object?>{
                        'sessionId': session.id,
                        'path': track.path,
                        'playing': true,
                        'playWhenReady': true,
                        'processingState': 'ready',
                        'positionMs': 42000,
                        'bufferedPositionMs': 50000,
                        'volume': 0.8,
                        'speed': 1.25,
                        'boostGain': 1.0,
                        'channelSwap': false,
                        'queueIndex': 0,
                      },
                    ],
                  },
                };
              }
              return <String, Object?>{'ok': true, 'value': null};
            });

        await runtimeGraph.playbackCommands.restorePersistedRuntime(
          <PlaybackSession>[session],
          focusedSessionId: session.id,
        );

        expect(prepareCalls, 0);
        expect(session.state.playing, isTrue);
        expect(session.position, const Duration(seconds: 42));
        expect(session.volume, 0.8);
        expect(session.speed, 1.25);
        expect(runtimeGraph.notifications.focusedSessionId, session.id);
      },
    );

    test(
      'runtime restore prepares sessions missing from native snapshot',
      () async {
        final track = MusicTrack(
          path: '/music/native-missing.mp3',
          displayName: 'Native Missing',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        );
        final session = PlaybackSession(
          id: 'native-missing',
          currentTrackPath: track.path,
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026),
          state: PlayerState(false, ProcessingState.idle),
          customQueueTracks: <MusicTrack>[track],
        );
        runtimeGraph.playback.registerSession(session);
        var prepareCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              if (call.method == NativePlaybackMethod.snapshot) {
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{'sessions': const <Object?>[]},
                };
              }
              if (call.method == NativePlaybackMethod.prepareSession) {
                prepareCalls++;
                final arguments = call.arguments as Map<Object?, Object?>;
                return <String, Object?>{
                  'ok': true,
                  'value': <String, Object?>{
                    'sessionId': session.id,
                    'path': track.path,
                    'uri': arguments['uri'],
                    'playing': false,
                    'playWhenReady': false,
                    'processingState': 'ready',
                    'positionMs': 0,
                    'bufferedPositionMs': 0,
                    'volume': 1.0,
                    'boostGain': 1.0,
                    'channelSwap': false,
                  },
                };
              }
              return <String, Object?>{'ok': true, 'value': null};
            });

        await runtimeGraph.playbackCommands.restorePersistedRuntime(
          <PlaybackSession>[session],
          focusedSessionId: session.id,
        );

        expect(prepareCalls, 1);
        expect(session.loadedPath, track.path);
      },
    );

    test(
      'runtime restore does not prepare when native snapshot is unavailable',
      () async {
        final track = MusicTrack(
          path: '/music/native-snapshot-unavailable.mp3',
          displayName: 'Native Snapshot Unavailable',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        );
        final session = PlaybackSession(
          id: 'native-snapshot-unavailable',
          currentTrackPath: track.path,
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026),
          state: PlayerState(false, ProcessingState.idle),
          customQueueTracks: <MusicTrack>[track],
        );
        runtimeGraph.playback.registerSession(session);
        var prepareCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              if (call.method == NativePlaybackMethod.prepareSession) {
                prepareCalls++;
              }
              return <String, Object?>{
                'ok': false,
                'errorCode': 'service_unavailable',
                'error': 'Native playback service is not ready.',
              };
            });

        await runtimeGraph.playbackCommands.restorePersistedRuntime(
          <PlaybackSession>[session],
          focusedSessionId: session.id,
        );

        expect(prepareCalls, 0);
        expect(session.loadedPath, isNull);
      },
    );

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
      final track = MusicTrack(
        path: '/music/auto-play-setting.mp3',
        displayName: 'Auto Play Setting',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );

      await runtimeGraph.settings.setAutoPlayAddedSessions(false);
      await runtimeGraph.playback.spawnSession(track);
      await runtimeGraph.playback.pendingSessionPreparation;
      expect(prepareCalls, 0);
      expect(playCalls, 0);

      await runtimeGraph.settings.setAutoPlayAddedSessions(true);
      await runtimeGraph.playback.spawnSession(track);
      for (var i = 0; i < 20 && playCalls < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(prepareCalls, 1);
      expect(playCalls, 1);
    });

    test('ASMR.ONE playback cache setting is disabled by default', () async {
      expect(runtimeGraph.settings.asmrPlaybackCacheEnabled, isFalse);

      await runtimeGraph.settings.setAsmrPlaybackCacheEnabled(true);

      expect(runtimeGraph.settings.asmrPlaybackCacheEnabled, isTrue);
      expect(
        runtimeGraph.settings.slice.stream,
        emits(
          isA<SettingsState>().having(
            (state) => state.asmrPlaybackCacheEnabled,
            'asmr playback cache',
            isTrue,
          ),
        ),
      );
    });

    test('pausing during preparation cancels the pending autoplay', () async {
      final prepareStarted = Completer<void>();
      final prepareResponse = Completer<Object?>();
      var playCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
            if (call.method == NativePlaybackMethod.prepareSession) {
              if (!prepareStarted.isCompleted) prepareStarted.complete();
              return prepareResponse.future;
            }
            if (call.method == NativePlaybackMethod.pause) {
              return <String, Object?>{
                'ok': false,
                'error': 'Session is still preparing.',
              };
            }
            if (call.method == NativePlaybackMethod.play) {
              playCalls++;
            }
            return <String, Object?>{'ok': true, 'value': null};
          });
      final track = MusicTrack(
        path: '/music/cancel-preparation.mp3',
        displayName: 'Cancel Preparation',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );

      await runtimeGraph.playback.spawnSession(track, autoPlay: true);
      await prepareStarted.future;
      final session = runtimeGraph.playback.activeSessions.single;
      expect(session.playbackRequested, isTrue);
      expect(session.isPlaybackLoading, isTrue);

      await runtimeGraph.playback.toggleSessionPlayPause(session.id);
      expect(session.playbackRequested, isFalse);

      prepareResponse.complete(<String, Object?>{
        'ok': true,
        'value': <String, Object?>{
          'sessionId': session.id,
          'path': track.path,
          'uri': Uri.file(track.path).toString(),
          'playing': false,
          'playWhenReady': false,
          'processingState': 'ready',
          'positionMs': 0,
          'bufferedPositionMs': 0,
          'durationMs': 1000,
          'volume': 1.0,
          'channelSwap': false,
        },
      });
      await runtimeGraph.playback.pendingSessionPreparation;

      expect(session.playbackRequested, isFalse);
      expect(playCalls, 0);
    });

    test('toggling play-pause with unknown id does not throw', () {
      runtimeGraph.playback.toggleSessionPlayPause('non_existent_session');
      expect(runtimeGraph.playback.activeSessions, isEmpty);
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
      final firstTrack = MusicTrack(
        path: '/music/exclusive-first.mp3',
        displayName: 'First',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );
      final secondTrack = MusicTrack(
        path: '/music/exclusive-second.mp3',
        displayName: 'Second',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );

      await runtimeGraph.playback.spawnSession(firstTrack, autoPlay: false);
      await runtimeGraph.playback.spawnSession(secondTrack, autoPlay: false);
      final firstSession = runtimeGraph.playback.activeSessions.firstWhere(
        (session) => PathMatcher.equalsNormalized(
          session.currentTrackPath,
          firstTrack.path,
        ),
      );
      final secondSession = runtimeGraph.playback.activeSessions.firstWhere(
        (session) => PathMatcher.equalsNormalized(
          session.currentTrackPath,
          secondTrack.path,
        ),
      );
      firstSession.setOptimisticState(
        playing: true,
        processingState: ProcessingState.ready,
      );

      final toggle = runtimeGraph.playback.toggleSessionPlayPause(
        secondSession.id,
      );
      expect(firstSession.effectivePlaying, isTrue);
      expect(secondSession.playbackRequested, isTrue);
      await toggle;

      expect(firstSession.effectivePlaying, isFalse);
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
      final track = MusicTrack(
        path: '/music/rapid-toggle.mp3',
        displayName: 'Rapid Toggle',
        groupKey: '/music',
        groupTitle: 'Music',
        groupSubtitle: '',
        isSingle: true,
      );
      await runtimeGraph.playback.spawnSession(track, autoPlay: false);
      for (var i = 0; i < 100; i++) {
        if (runtimeGraph.playback.activeSessions.singleOrNull?.loadedPath !=
            null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final session = runtimeGraph.playback.activeSessions.single;

      final firstPlay = runtimeGraph.playback.toggleSessionPlayPause(
        session.id,
      );
      for (var i = 0; i < 20 && playCalls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(session.effectivePlaying, isTrue);

      final pause = runtimeGraph.playback.toggleSessionPlayPause(session.id);
      for (var i = 0; i < 20 && pauseCall == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(session.effectivePlaying, isFalse);

      final lastPlay = runtimeGraph.playback.toggleSessionPlayPause(session.id);
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

    test(
      'stale prepare cannot target a replacement session with the same id',
      () async {
        final oldTrack = MusicTrack(
          path: '/music/old-session.mp3',
          displayName: 'Old session',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        );
        final replacementTrack = MusicTrack(
          path: '/music/replacement-session.mp3',
          displayName: 'Replacement session',
          groupKey: '/music',
          groupTitle: 'Music',
          groupSubtitle: '',
          isSingle: true,
        );
        final prepareStarted = Completer<void>();
        final releasePrepare = Completer<void>();
        var playCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(nativePlaybackChannel, (call) async {
              final arguments = call.arguments as Map<Object?, Object?>?;
              if (call.method == NativePlaybackMethod.prepareSession) {
                if (!prepareStarted.isCompleted) prepareStarted.complete();
                await releasePrepare.future;
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
                    'volume': 1.0,
                    'channelSwap': false,
                  },
                };
              }
              if (call.method == NativePlaybackMethod.play) playCalls++;
              return <String, Object?>{'ok': true, 'value': null};
            });
        final oldSession = PlaybackSession(
          id: 'reused-session-id',
          currentTrackPath: oldTrack.path,
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026),
          state: PlayerState(false, ProcessingState.idle),
          customQueueTracks: <MusicTrack>[oldTrack],
        );
        runtimeGraph.playback.registerSession(oldSession);

        final prepareFuture = runtimeGraph.playbackCommands.prepareAndPlay(
          oldSession,
          nextPath: oldTrack.path,
        );
        await prepareStarted.future;
        final resetFuture = runtimeGraph.playback.resetPersistedState();
        expect(oldSession.isDisposed, isTrue);
        final replacementSession = PlaybackSession(
          id: oldSession.id,
          currentTrackPath: replacementTrack.path,
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026, 1, 2),
          state: PlayerState(false, ProcessingState.idle),
          customQueueTracks: <MusicTrack>[replacementTrack],
        );
        runtimeGraph.playback.registerSession(replacementSession);

        releasePrepare.complete();

        expect(await prepareFuture, isFalse);
        await resetFuture;
        expect(playCalls, 0);
        expect(replacementSession.currentTrackPath, replacementTrack.path);
        expect(replacementSession.loadedPath, isNull);
        expect(replacementSession.isLoading, isFalse);
      },
    );

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

        await tester.runAsync(runtimeGraph.runtime.dispose);
        runtimeGraph = createTestRuntimeGraph(
          notificationService: PlaybackNotificationService(
            notificationsPlatformService: NotificationsPlatformService(
              channel: notificationsChannel,
              isAndroidOverride: true,
              timeout: const Duration(milliseconds: 50),
            ),
          ),
          persistenceRepository: TestPersistenceRepository(
            database: AppDatabase.test(db),
          ),
        );
        fixture.bindRuntimeGraph(runtimeGraph);
        runtimeGraph.playback.configurePersistence(enabled: false);
        final track = MusicTrack(
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

        await runtimeGraph.playback.spawnSession(track, autoPlay: false);
        await tester.pump(const Duration(milliseconds: 140));
        expect(notificationSyncCalls, 0);

        coordinator.endInteraction(interactionSource);
        await tester.pump(const Duration(milliseconds: 170));
        await tester.pump();

        expect(notificationSyncCalls, 1);
        await tester.runAsync(runtimeGraph.runtime.dispose);
      },
    );

    test('sessionById returns null for unknown id', () {
      expect(runtimeGraph.playback.sessionById('nonexistent'), isNull);
    });

    test(
      'failed queue prepare restores the previous native track without committing target state',
      () async {
        runtimeGraph.playback.configurePersistence(enabled: true);
        final first = MusicTrack(
          path: 'https://example.com/transaction-a.mp3',
          displayName: 'A',
          groupKey: 'transaction',
          groupTitle: 'Transaction',
          groupSubtitle: 'Transaction',
          isSingle: false,
          duration: const Duration(minutes: 3),
        );
        final second = MusicTrack(
          path: 'https://example.com/transaction-b.mp3',
          displayName: 'B',
          groupKey: 'transaction',
          groupTitle: 'Transaction',
          groupSubtitle: 'Transaction',
          isSingle: false,
          duration: const Duration(minutes: 4),
        );
        final preparedPaths = <String>[];
        var restoreCalls = 0;

        Map<String, Object?> snapshot(
          String pathValue, {
          bool playing = false,
        }) {
          return <String, Object?>{
            'sessionId': runtimeGraph.playback.activeSessions.single.id,
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

        runtimeGraph.library.addTracks(
          <MusicTrack>[first, second],
          notify: false,
          persist: false,
        );
        await runtimeGraph.playback.spawnSessionWithQueue(<MusicTrack>[
          first,
          second,
        ], autoPlay: false);
        final session = runtimeGraph.playback.activeSessions.single;
        for (var i = 0; i < 50 && session.loadedPath == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        session.applyNativeSnapshot(
          NativePlaybackSnapshot.fromMap(snapshot(first.path, playing: true)),
        );

        await runtimeGraph.playback.switchSessionQueueTrack(session.id, 1);

        expect(session.currentTrackPath, first.path);
        expect(session.loadedPath, first.path);
        expect(session.position, const Duration(seconds: 47));
        expect(session.duration, first.duration);
        expect(session.currentQueueIndex, 0);
        expect(session.state.playing, isTrue);
        expect(session.playbackError, isNotNull);
        expect(restoreCalls, 1);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final persisted = (await TestPersistenceRepository(
          database: AppDatabase.test(db),
        ).loadAllSessions()).single;
        expect(persisted.trackPath, first.path);
      },
    );

    test('timer fallback records only sessions that actually paused', () async {
      final first = MusicTrack(
        path: 'https://example.com/timer-a.mp3',
        displayName: 'A',
        groupKey: 'timer',
        groupTitle: 'Timer',
        groupSubtitle: 'Timer',
        isSingle: false,
      );
      final second = MusicTrack(
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
              final session = runtimeGraph.playback.sessionById(sessionId)!;
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
      runtimeGraph.library.addTracks(
        <MusicTrack>[first, second],
        notify: false,
        persist: false,
      );
      await runtimeGraph.settings.setAllowDuplicateWorks(true);
      await runtimeGraph.playback.spawnSession(first, autoPlay: false);
      await runtimeGraph.playback.spawnSession(second, autoPlay: false);
      for (
        var i = 0;
        i < 50 && runtimeGraph.playback.activeSessions.length < 2;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final sessions = runtimeGraph.playback.activeSessions.toList(
        growable: false,
      );
      failingSessionId = sessions[1].id;
      for (final session in sessions) {
        session.state = PlayerState(true, ProcessingState.ready);
      }
      final future = DateTime.now().add(const Duration(minutes: 2));
      runtimeGraph.timer.setAutoResume(true, future.hour, future.minute);
      runtimeGraph.timer.configureTimer(
        TimerMode.manual,
        const Duration(milliseconds: 20),
      );
      runtimeGraph.timer.startCountdown();

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
        final first = MusicTrack(
          path: 'https://example.com/resume-a.mp3',
          displayName: 'A',
          groupKey: 'resume',
          groupTitle: 'Resume',
          groupSubtitle: 'Resume',
          isSingle: false,
        );
        final second = MusicTrack(
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
                final session = runtimeGraph.playback.sessionById(sessionId)!;
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
        runtimeGraph.library.addTracks(
          <MusicTrack>[first, second],
          notify: false,
          persist: false,
        );
        await runtimeGraph.settings.setAllowDuplicateWorks(true);
        await runtimeGraph.playback.spawnSession(first, autoPlay: false);
        await runtimeGraph.playback.spawnSession(second, autoPlay: false);
        final sessions = runtimeGraph.playback.activeSessions.toList(
          growable: false,
        );
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

        await runtimeGraph.timer.loadRuntimeFromSystem();

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
      expect(runtimeGraph.library.trackByPath('/nonexistent/path.mp3'), isNull);
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
        runtimeGraph.library.addTracks(
          <MusicTrack>[track],
          notify: false,
          persist: false,
        );
        await runtimeGraph.playback.spawnSession(track, autoPlay: false);

        final session = runtimeGraph.playback.activeSessions.single;
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
        await runtimeGraph.playback.setSessionChannelSwap(session.id, true);

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
      addTearDown(first.shutdown);
      addTearDown(second.shutdown);

      final secondStates = <PlayerState>[];
      second.stateStream.listen(secondStates.add);

      first.applyNativeSnapshot(
        NativePlaybackSnapshot(
          sessionId: 'native_1',
          uri: 'file:///audio/first.mp3',
          playing: true,
          playWhenReady: true,
          processingState: 'ready',
          position: const Duration(seconds: 5),
          bufferedPosition: const Duration(seconds: 10),
          duration: const Duration(minutes: 2),
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
      addTearDown(session.shutdown);

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
