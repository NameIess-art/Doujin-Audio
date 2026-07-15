import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';

void main() {
  test('PlaybackFacade owns session registration and reorder commands', () {
    final library = LibraryFacade.create();
    final playback = PlaybackFacade.create(
      databaseRepository: library.databaseRepository,
    );
    final first = _session('first');
    final second = _session('second');
    addTearDown(() async {
      first.dispose();
      second.dispose();
      await playback.dispose();
      await library.dispose();
    });
    final registered = <String>[];
    var reorderCount = 0;
    playback.attachSessionRuntime(
      onSessionRegistered: (session) => registered.add(session.id),
      onSessionsReordered: () => reorderCount++,
    );

    playback
      ..registerSession(first)
      ..registerSession(second);

    expect(registered, <String>['first', 'second']);
    expect(
      playback.service.activeSessions.map((session) => session.id),
      <String>['second', 'first'],
    );

    playback.reorderSessions(0, 2);
    expect(
      playback.service.activeSessions.map((session) => session.id),
      <String>['first', 'second'],
    );
    expect(reorderCount, 1);

    playback.reorderSessions(-1, 0);
    expect(reorderCount, 1);
  });

  test('PlaybackFacade normalizes native snapshots after a path retarget', () {
    final library = LibraryFacade.create();
    final playback = PlaybackFacade.create(
      databaseRepository: library.databaseRepository,
    );
    final session = _session('retargeted')
      ..currentTrackPath = '/new/work/track.mp3';
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..registerSession(session)
      ..rememberRetargetedPath('/old/work', '/new/work');

    final application = playback.applyNativeSnapshot(
      const NativePlaybackSnapshot(
        sessionId: 'retargeted',
        path: '/old/work/track.mp3',
        playing: true,
        playWhenReady: true,
        processingState: 'ready',
        position: Duration(seconds: 2),
        bufferedPosition: Duration(seconds: 4),
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
        transportCommandId: 9,
      ),
      hasLibraryTrack: (_) => false,
    );

    expect(application.applied, isTrue);
    expect(
      PathMatcher.equalsNormalized(
        application.snapshot.path!,
        '/new/work/track.mp3',
      ),
      isTrue,
    );
    expect(
      PathMatcher.equalsNormalized(
        session.currentTrackPath,
        '/new/work/track.mp3',
      ),
      isTrue,
    );
    expect(session.state.playing, isTrue);
    expect(playback.nextTransportCommandId(), 10);
  });

  test(
    'PlaybackFacade owns debounced session persistence scheduling',
    () async {
      final library = LibraryFacade.create();
      final playback = PlaybackFacade.create(
        databaseRepository: library.databaseRepository,
      );
      addTearDown(() async {
        await playback.dispose();
        await library.dispose();
      });
      var stateSaves = 0;
      var orderSaves = 0;
      playback
        ..attachSessionStatePersistence(() async => stateSaves++)
        ..attachSessionOrderPersistence(() async => orderSaves++)
        ..scheduleSessionStatePersistence(
          delay: const Duration(milliseconds: 5),
        )
        ..scheduleSessionStatePersistence(
          delay: const Duration(milliseconds: 5),
        )
        ..scheduleSessionOrderPersistence(
          delay: const Duration(milliseconds: 5),
        );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(stateSaves, 1);
      expect(orderSaves, 1);

      playback.scheduleSessionStatePersistence(
        delay: const Duration(minutes: 1),
      );
      await playback.flushSessionStatePersistence();
      expect(stateSaves, 2);
    },
  );
}

PlaybackSession _session(String id) {
  return PlaybackSession(
    id: id,
    currentTrackPath: '/tracks/$id.mp3',
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.folderSequential,
    volume: 1,
    createdAt: DateTime(2026),
    state: PlayerState(false, ProcessingState.idle),
  );
}
