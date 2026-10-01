import 'package:doujin_audio/app/application/audio_runtime_coordinator.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/test_persistence_repository.dart';

void main() {
  testWidgets(
    'native progress, volume and speed isolate session state and persistence',
    (tester) async {
      final harness = (await tester.runAsync(
        () async => _PlaybackIsolationHarness(),
      ))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _disposeRuntime(tester, harness.dispose);
      });
      await tester.runAsync(harness.start);
      final first = (await tester.runAsync(
        () async => harness.addSession('first', loaded: true),
      ))!;
      final second = (await tester.runAsync(
        () async => harness.addSession('second', loaded: true),
      ))!;
      await tester.runAsync(
        harness.graph.playback.flushSessionStatePersistence,
      );
      await tester.runAsync(harness.graph.library.ensureCardSnapshot);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();
      final buildsBefore = Map<String, int>.of(harness.builds);
      final sortedBefore = harness.sorted;
      final readsBefore = second.positionReads;
      harness.database.writtenSessionIds.clear();

      await tester.runAsync(
        () => harness.emit(<String, Object?>{
          'eventType': 'progress',
          'updates': <Object?>[
            <String, Object?>{
              'sessionId': first.id,
              'positionMs': 6000,
              'bufferedPositionMs': 8000,
              'nativeElapsedRealtimeMs': 6000,
            },
          ],
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      await tester.runAsync(
        () => harness.graph.playback.flushSessionStatePersistence(
          sessionId: first.id,
        ),
      );
      expect(first.lastKnownPosition, const Duration(seconds: 6));
      expect(harness.database.writtenSessionIds, <String>[first.id]);
      expect(
        harness.builds['progress:first'],
        greaterThan(buildsBefore['progress:first']!),
      );
      expect(harness.builds['session:first'], buildsBefore['session:first']);

      for (final parameters in <({double volume, double speed})>[
        (volume: 0.6, speed: 1),
        (volume: 0.6, speed: 1.5),
      ]) {
        await tester.runAsync(
          () => harness.emit(<String, Object?>{
            'sessionId': first.id,
            'path': first.currentTrackPath,
            'playing': false,
            'playWhenReady': false,
            'processingState': 'ready',
            'positionMs': 6000,
            'bufferedPositionMs': 8000,
            'volume': parameters.volume,
            'speed': parameters.speed,
            'boostGain': 1,
            'channelSwap': false,
          }),
        );
        await tester.pump();
        await tester.pump();
        expect(first.volume, parameters.volume);
        expect(first.speed, parameters.speed);
      }
      expect(
        harness.builds['session:first'],
        greaterThan(buildsBefore['session:first']!),
      );

      await tester.runAsync(() async {
        await harness.graph.playback.setSessionVolume(first.id, 0.7);
        await harness.graph.playback.setSessionSpeed(first.id, 1.75);
      });
      await tester.pump();
      await tester.pump();
      expect(harness.database.writtenSessionIds, <String>[
        first.id,
        first.id,
        first.id,
      ]);
      expect(second.positionReads, readsBefore);
      expect(identical(harness.sorted, sortedBefore), isTrue);
      for (final key in <String>[
        'session:second',
        'progress:second',
        'directory',
        'header',
        'overlay',
        'library',
        'settings',
      ]) {
        expect(harness.builds[key], buildsBefore[key], reason: key);
      }
    },
  );

  for (final sessionCount in <int>[1, 2, 3, 4, 5, 50]) {
    testWidgets(
      '$sessionCount paused sessions do no periodic work for sixty seconds',
      (tester) async {
        final harness = (await tester.runAsync(
          () async => _PlaybackIsolationHarness(),
        ))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await _disposeRuntime(tester, harness.dispose);
        });
        await tester.runAsync(harness.start);
        for (var index = 0; index < sessionCount; index++) {
          await tester.runAsync(() async {
            harness.addSession('paused-$index');
          });
        }
        await tester.runAsync(
          harness.graph.playback.flushSessionStatePersistence,
        );
        await tester.runAsync(harness.graph.library.ensureCardSnapshot);
        await tester.pumpWidget(harness.build());
        await tester.pumpAndSettle();
        final buildsBefore = Map<String, int>.of(harness.builds);
        final readsBefore = harness.sessions
            .map((s) => s.positionReads)
            .toList();
        final nativeCallsBefore = harness.nativeCalls;
        final writesBefore = harness.database.writtenSessionIds.length;
        final orderWritesBefore = harness.database.orderWrites;

        for (var second = 0; second < 60; second++) {
          await tester.pump(const Duration(seconds: 1));
        }

        expect(harness.sessions.map((s) => s.positionReads), readsBefore);
        expect(harness.nativeCalls, nativeCallsBefore);
        expect(harness.database.writtenSessionIds.length, writesBefore);
        expect(harness.database.orderWrites, orderWritesBefore);
        expect(harness.builds, buildsBefore);
        expect(harness.sessions.every((s) => s.loadedPath == null), isTrue);
        expect(
          harness.graph.playback.hasScheduledSessionStatePersistence,
          isFalse,
        );
        expect(
          harness.graph.playback.hasScheduledSessionOrderPersistence,
          isFalse,
        );
      },
    );
  }
}

Future<void> _disposeRuntime(
  WidgetTester tester,
  Future<void> Function() dispose,
) async {
  var done = false;
  final pending = dispose().whenComplete(() => done = true);
  // The native channel and widgets deliver callbacks in different test zones.
  for (var attempt = 0; !done && attempt < 100; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  await tester.runAsync(() => pending.timeout(const Duration(seconds: 5)));
}

final class _PlaybackIsolationHarness {
  _PlaybackIsolationHarness() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativePlaybackChannel, (_) async {
      nativeCalls++;
      return <String, Object?>{'ok': true, 'value': null};
    });
    messenger.setMockMethodCallHandler(notificationsChannel, (_) async => null);
    messenger.setMockStreamHandler(
      _eventChannel,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          events = sink;
        },
      ),
    );
    final native = NativePlaybackRepository(
      bridge: NativePlaybackBridge.instance,
    );
    graph = createTestRuntimeGraph(
      persistenceRepository: database,
      nativePlaybackRepository: native,
      skipPersistence: false,
    );
    graph.settings.syncSlice(isInitialized: true);
    runtime = AudioRuntimeCoordinator(
      snapshots: native.snapshots,
      progressUpdates: native.progressUpdates,
      startListening: native.startListening,
      stopListening: native.stopListening,
      onSnapshot: graph.playbackCommands.handleNativeSnapshot,
      onProgress: graph.playback.applyNativeProgress,
      onStart: () {},
      onEnterBackground: graph.runtime.enterBackground,
      onResumeForeground: graph.runtime.resumeForeground,
      onDispose: graph.runtime.dispose,
    );
  }

  static const _eventChannel = EventChannel(NativePlaybackChannel.eventName);
  final database = _IsolationPersistenceRepository();
  final sessions = <_CountedPlaybackSession>[];
  final builds = <String, int>{};
  late final AppRuntimeGraph graph;
  late final AudioRuntimeCoordinator runtime;
  MockStreamHandlerEventSink? events;
  Object? sorted;
  int nativeCalls = 0;

  Future<void> emit(Map<String, Object?> event) async {
    events!.success(event);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  Future<void> start() async {
    await NativePlaybackBridge.instance.stopListening();
    await runtime.start();
  }

  _CountedPlaybackSession addSession(String id, {bool loaded = false}) {
    final session = _CountedPlaybackSession(id, loaded: loaded);
    sessions.add(session);
    graph.library.addTracks(
      <MusicTrack>[
        testMusicTrack(
          name: id,
          path: session.currentTrackPath,
          groupKey: id,
          groupTitle: id,
          isSingle: true,
        ),
      ],
      notify: false,
      persist: false,
    );
    graph.playback.registerSession(session);
    return session;
  }

  Widget _observe(String key, void Function(WidgetRef) read) => Consumer(
    builder: (_, ref, _) {
      builds.update(key, (count) => count + 1, ifAbsent: () => 1);
      read(ref);
      return const SizedBox.shrink();
    },
  );

  Widget build() => ProviderScope(
    overrides: createAppRuntimeOverrides(
      persistence: graph.persistence,
      runtime: graph.runtime,
      warmup: graph.warmup,
      playbackCommands: graph.playbackCommands,
      keepAlive: graph.keepAlive,
      library: graph.library,
      playback: graph.playback,
      subtitles: graph.subtitles,
      timer: graph.timer,
      notifications: graph.notifications,
      settings: graph.settings,
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: <Widget>[
          for (final session in sessions) ...<Widget>[
            _observe('session:${session.id}', (ref) {
              ref.watch(playlistSessionCardStateProvider(session.id));
              ref.watch(sessionDetailUiProvider(session.id));
            }),
            StreamBuilder<Duration>(
              stream: session.positionStream,
              builder: (_, _) {
                builds.update(
                  'progress:${session.id}',
                  (count) => count + 1,
                  ifAbsent: () => 1,
                );
                return const SizedBox.shrink();
              },
            ),
          ],
          _observe(
            'directory',
            (ref) => sorted = ref.watch(playlistSortedEntriesUiProvider),
          ),
          _observe('header', (ref) => ref.watch(playlistHeaderUiProvider)),
          _observe('overlay', (ref) => ref.watch(mainOverlayUiProvider)),
          _observe('library', (ref) {
            ref.watch(librarySortedTreeUiProvider);
            ref.watch(libraryHeaderUiProvider);
          }),
          _observe('settings', (ref) => ref.watch(settingsStateProvider)),
        ],
      ),
    ),
  );

  Future<void> dispose() async {
    await runtime.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockStreamHandler(_eventChannel, null);
    messenger.setMockMethodCallHandler(nativePlaybackChannel, null);
    messenger.setMockMethodCallHandler(notificationsChannel, null);
  }
}

final class _CountedPlaybackSession extends PlaybackSession {
  _CountedPlaybackSession(String id, {required bool loaded})
    : super(
        id: id,
        currentTrackPath: 'https://example.com/$id.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: PlayerState(
          false,
          loaded ? ProcessingState.ready : ProcessingState.idle,
        ),
      ) {
    if (loaded) loadedPath = currentTrackPath;
  }

  int positionReads = 0;

  @override
  Duration get position {
    positionReads++;
    return super.position;
  }
}

final class _IsolationPersistenceRepository extends TestPersistenceRepository {
  final writtenSessionIds = <String>[];
  int orderWrites = 0;

  @override
  Future<void> upsertTracks(List<MusicTrack> tracks) async {}

  @override
  Future<void> upsertSession(
    PersistedPlaybackSession session, {
    bool includeQueue = true,
    bool includeEffects = true,
  }) async {
    writtenSessionIds.add(session.id);
  }

  @override
  Future<void> upsertSessionPlaybackState(
    PersistedPlaybackSession session,
  ) async {
    writtenSessionIds.add(session.id);
  }

  @override
  Future<void> updateSessionOrder(List<String> sessionIds) async {
    orderWrites++;
  }
}
