import 'dart:async';

import 'support/test_playback_commands.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session_launcher.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MusicTrack track(String name) => MusicTrack(
    path: '/tracks/$name.mp3',
    displayName: name,
    groupKey: '/tracks',
    groupTitle: 'Tracks',
    groupSubtitle: '',
    isSingle: true,
  );

  test(
    'direct playback reuses one temporary session and persists its latest track',
    () async {
      final repository = _RecordingRepository();
      final facade = PlaybackFacade.create(databaseRepository: repository);
      addTearDown(facade.dispose);
      var preparations = 0;
      facade.attachPlaybackCommands(
        prepareSession:
            (
              session, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async {
              preparations++;
              session.currentTrackPath = nextPath;
              session.loadedPath = nextPath;
              return true;
            },
        pauseSession: (_) async {},
        startSession: (_, {required shouldStartTriggerCountdown}) async => true,
        resolveAdvance: (_, {required forward}) => null,
        hasAdjacent: (_, {required forward}) => false,
      );
      await facade.playDirect([track('a'), track('b')]);
      final first = facade.sessions.values.single;
      await facade.playDirect([track('b')]);
      expect(identical(first, facade.sessions.values.single), isTrue);
      expect(first.currentTrackPath, track('b').path);
      expect(first.isTemporary, isTrue);
      await facade.savePersistedState();
      expect(repository.saved.single.id, first.id);
      expect(repository.saved.single.trackPath, track('b').path);
      expect(repository.saved.single.isTemporary, isTrue);
      first.lastKnownPosition = const Duration(seconds: 12);
      await facade.addTrackToPlaylist(track('b'));
      expect(first.isTemporary, isTrue);
      expect(preparations, 2);
      expect(first.position, const Duration(seconds: 12));
      await facade.addTrackToPlaylist(track('b'));
      expect(facade.sessions, hasLength(2));
      await facade.savePersistedState();
      expect(repository.saved, hasLength(2));
      expect(
        repository.saved.singleWhere((item) => item.isTemporary).id,
        first.id,
      );
      await facade.playDirect([track('other-work')]);
      expect(
        facade.sessions.values.where((s) => s.isTemporary).single,
        same(first),
      );
      expect(first.currentTrackPath, track('other-work').path);
      expect(
        facade.sessions.values
            .where((s) => !s.isTemporary)
            .single
            .currentTrackPath,
        track('b').path,
      );
    },
  );

  test(
    'late direct playback resolution cannot replace the latest selection',
    () async {
      final facade = PlaybackFacade.create(
        databaseRepository: _RecordingRepository(),
      );
      addTearDown(facade.dispose);
      final delayed = Completer<List<MusicTrack>>();
      final first = facade.playDirect(delayed.future);
      expect(await facade.playDirect([track('latest')]), isTrue);
      delayed.complete([track('old')]);
      expect(await first, isFalse);
      expect(
        facade.sessions.values.single.currentTrackPath,
        track('latest').path,
      );
    },
  );

  test('restart restores the last direct playback entry paused', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final repository = _RecordingRepository();
    final original = PlaybackFacade.create(databaseRepository: repository);
    addTearDown(original.dispose);
    original.attachPlaybackCommands(
      prepareSession:
          (
            session, {
            required nextPath,
            autoPlay = true,
            forceStartAtZero = false,
            showLoading = true,
            targetQueueIndex,
          }) async {
            session.currentTrackPath = nextPath;
            return true;
          },
      pauseSession: (_) async {},
      startSession: (_, {required shouldStartTriggerCountdown}) async => true,
      resolveAdvance: (_, {required forward}) => null,
      hasAdjacent: (_, {required forward}) => false,
    );
    await original.playDirect([track('a'), track('b')], startIndex: 1);
    await original.savePersistedState();
    final savedId = repository.saved.single.id;

    final restarted = PlaybackFacade.create(databaseRepository: repository);
    addTearDown(restarted.dispose);
    restarted.attachPersistenceRuntime(
      trackByPath: (_) => null,
      recordPlaybackProgress: () => true,
      restoreRuntime: (_, {required focusedSessionId}) async {},
      updatePlaybackHistory:
          ({
            required trackPath,
            required position,
            required now,
            required updatePlayedAt,
          }) => null,
      onFocusChanged: (_) {},
    );
    await restarted.loadPersistedState();

    final restored = restarted.activeSessions.single;
    expect(restored.id, savedId);
    expect(restored.currentTrackPath, track('b').path);
    expect(restored.isTemporary, isTrue);
    expect(restored.state.playing, isFalse);
    expect(restored.customQueueTracks?.map((item) => item.path), [
      track('a').path,
      track('b').path,
    ]);
  });

  test('restart retains an ordinary playing entry without autoplay', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final repository = _RecordingRepository();
    final original = PlaybackFacade.create(databaseRepository: repository);
    addTearDown(original.dispose);
    final playing = original.createTrackSession(track('ordinary'));
    playing.state = const PlayerState(true, ProcessingState.ready);
    await original.savePersistedState();
    expect(repository.saved.single.retainInNowPlaying, isTrue);

    final restarted = PlaybackFacade.create(databaseRepository: repository);
    addTearDown(restarted.dispose);
    restarted.attachPersistenceRuntime(
      trackByPath: (_) => track('ordinary'),
      recordPlaybackProgress: () => true,
      restoreRuntime: (_, {required focusedSessionId}) async {},
      updatePlaybackHistory:
          ({
            required trackPath,
            required position,
            required now,
            required updatePlayedAt,
          }) => null,
      onFocusChanged: (_) {},
    );
    await restarted.loadPersistedState();

    final restored = restarted.activeSessions.single;
    expect(restored.id, playing.id);
    expect(restored.retainInNowPlaying, isTrue);
    expect(restored.playbackRequested, isFalse);
  });

  test('direct playback keeps an added playlist item independent', () async {
    final facade = PlaybackFacade.create(
      databaseRepository: _RecordingRepository(),
    );
    addTearDown(facade.dispose);
    await facade.addTrackToPlaylist(track('a'));
    final added = facade.sessions.values.single;
    expect(added.loadedPath, isNull);
    expect(added.playbackRequested, isFalse);
    await facade.playDirect([track('a')]);
    expect(facade.sessions, hasLength(2));
    expect(
      facade.sessions.values.where((s) => s.isTemporary).single,
      isNot(same(added)),
    );
    expect(added.loadedPath, isNull);
    expect(added.playbackRequested, isFalse);
    expect(added.isTemporary, isFalse);
  });

  test('direct playback leaves an existing playlist queue unchanged', () async {
    final facade = PlaybackFacade.create(
      databaseRepository: _RecordingRepository(),
    );
    addTearDown(facade.dispose);
    final queue = facade.createPlaybackQueue('Queue');
    queue.playbackQueue = PlaybackQueueDefinition(
      name: 'Queue',
      entries: [
        PlaybackQueueEntry(
          id: 'entry',
          kind: PlaybackQueueEntryKind.work,
          title: 'Work',
          tracks: [track('a'), track('b')],
        ),
      ],
    );
    var selectedIndex = -1;
    facade.attachPlaybackCommands(
      prepareSession:
          (
            session, {
            required nextPath,
            autoPlay = true,
            forceStartAtZero = false,
            showLoading = true,
            targetQueueIndex,
          }) async {
            selectedIndex = targetQueueIndex!;
            return true;
          },
      pauseSession: (_) async {},
      startSession: (_, {required shouldStartTriggerCountdown}) async => true,
      resolveAdvance: (_, {required forward}) => null,
      hasAdjacent: (_, {required forward}) => false,
    );
    await facade.playDirect([track('b')]);
    expect(facade.sessions, hasLength(2));
    expect(
      facade.sessions.values.where((s) => s.isTemporary).single,
      isNot(same(queue)),
    );
    expect(queue.loadedPath, isNull);
    expect(queue.playbackRequested, isFalse);
    expect(selectedIndex, 0);
  });

  test('signed URL changes preserve ASMR playlist identity', () async {
    final facade = PlaybackFacade.create(
      databaseRepository: _RecordingRepository(),
    );
    addTearDown(facade.dispose);
    MusicTrack remote(String token) => MusicTrack(
      path: 'https://example.com/a.mp3?token=$token',
      displayName: 'Audio',
      groupKey: 'work',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
      remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
      remoteMetadata: {'id': 12, 'trackRelativePath': 'disc/audio.mp3'},
    );
    expect(await facade.addTrackToPlaylist(remote('first')), isTrue);
    expect(await facade.addTrackToPlaylist(remote('second')), isFalse);
    await facade.playDirect([remote('third')]);
    expect(facade.sessions, hasLength(2));
    expect(facade.sessions.values.where((s) => s.isTemporary), hasLength(1));
  });

  test(
    'a stale remote failure does not surface after a newer direct request',
    () async {
      final facade = PlaybackFacade.create(
        databaseRepository: _RecordingRepository(),
      );
      addTearDown(facade.dispose);
      final delayed = Completer<List<MusicTrack>>();
      final stale = facade.playDirect(delayed.future);
      await facade.playDirect([track('latest')]);
      delayed.completeError(StateError('expired request'));
      expect(await stale, isFalse);
      expect(
        facade.sessions.values.single.currentTrackPath,
        track('latest').path,
      );
    },
  );

  test('facade launcher forwards queues through the playback owner', () async {
    final facade = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
    );
    addTearDown(facade.dispose);
    final launcher = PlaybackFacadeSessionLauncher(facade);
    var prepared = false;

    facade.attachPlaybackCommands(
      prepareSession:
          (
            session, {
            required nextPath,
            autoPlay = true,
            forceStartAtZero = false,
            showLoading = true,
            targetQueueIndex,
          }) async {
            prepared = true;
            return true;
          },
      pauseSession: (_) async {},
      startSession: (_, {required shouldStartTriggerCountdown}) async => true,
      resolveAdvance: (_, {required forward}) => null,
      hasAdjacent: (_, {required forward}) => false,
    );

    await launcher.launchQueue(
      [
        MusicTrack(
          path: '/tracks/launcher.mp3',
          displayName: 'Launcher',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: true,
        ),
      ],
      autoPlay: true,
      loopMode: SessionLoopMode.crossSequential,
    );
    await facade.pendingSessionPreparation;
    expect(prepared, isTrue);
    expect(
      facade.ordinarySessions.single.loopMode,
      SessionLoopMode.crossSequential,
    );
  });
}

class _RecordingRepository extends TestPersistenceRepository {
  List<PersistedPlaybackSession> saved = [];

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() async => saved;

  @override
  Future<void> saveAllSessions(List<PersistedPlaybackSession> sessions) async {
    saved = sessions;
  }
}
