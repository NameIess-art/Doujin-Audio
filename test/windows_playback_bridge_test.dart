import 'dart:async';
import 'dart:convert';

import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart'
    as playback;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  late WindowsPlaybackBridge bridge;
  late List<_Player> players;
  late Duration elapsed;
  late int playlistReads;
  Future<String> Function(Player)? playlistGetter;
  void Function(_Player)? configureNextPlayer;
  setUp(() {
    players = [];
    configureNextPlayer = null;
    playlistGetter = null;
    playlistReads = 0;
    elapsed = Duration.zero;
    bridge = WindowsPlaybackBridge(
      monotonicElapsed: () => elapsed,
      readNativePlaylist: (player) async {
        playlistReads++;
        return playlistGetter?.call(player) ?? _playlistJson(player);
      },
      createPlayer: () {
        final platform = _Player();
        configureNextPlayer?.call(platform);
        configureNextPlayer = null;
        players.add(platform);
        return Player(platformPlayer: platform);
      },
    )..startListening();
  });
  tearDown(() => bridge.dispose());

  Future<void> prepare(
    String id, {
    bool deferred = false,
    Duration position = Duration.zero,
  }) async {
    final result = await bridge.prepareSession(
      sessionId: id,
      uri: Uri.parse('https://example.com/$id.wav'),
      title: id,
      deferPlayerCreation: deferred,
      autoPlay: !deferred,
      startPosition: position,
    );
    expect(result.isOk, true, reason: result.errorOrNull);
  }

  test('a single item prepare reads the whole native playlist once', () async {
    await prepare('one');
    expect(playlistReads, 1);
    expect(players.single.state.playing, true);
  });

  for (final raw in [
    'not JSON',
    '{}',
    '[{}]',
    '[{"id":"1"}]',
    '[{"id":1.5}]',
    '[{"id":1},{"id":1}]',
    '[]',
  ]) {
    test('invalid playlist $raw fails without starting playback', () async {
      playlistGetter = (_) async => raw;
      final result = await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/one.wav'),
        title: 'one',
        autoPlay: true,
      );
      expect(result.errorCodeOrNull, NativeErrorCode.playerError);
      expect(playlistReads, 1);
      expect(players.single.plays, 0);
    });
  }

  for (final action in ['replace', 'remove']) {
    test(
      '$action during native playlist read discards its old mapping',
      () async {
        final gate = Completer<String>();
        final started = Completer<void>();
        playlistGetter = (player) async {
          if (!started.isCompleted) {
            started.complete();
            return gate.future;
          }
          return _playlistJson(player);
        };
        final old = bridge.prepareSession(
          sessionId: 'one',
          uri: Uri.parse('https://example.com/old.wav'),
          title: 'old',
          autoPlay: true,
        );
        await started.future;
        final ids = _playlistJson(bridge.playerForSession('one')!);
        final next = action == 'replace'
            ? bridge.prepareSession(
                sessionId: 'one',
                uri: Uri.parse('https://example.com/new.wav'),
                title: 'new',
                autoPlay: true,
              )
            : bridge.removeSession('one');
        gate.complete(ids);
        expect((await old).isFailure, true);
        expect((await next).isOk, true);
        if (action == 'replace') {
          expect(players.single.opens, 2);
          expect(players.single.plays, 1);
          expect(
            (await bridge.snapshot()).valueOrNull!.sessions.single.title,
            'new',
          );
        } else {
          expect(bridge.playerForSession('one'), isNull);
          expect((await bridge.snapshot()).valueOrNull!.sessions, isEmpty);
        }
      },
    );
  }

  test(
    'failed live seek preserves position, playback intent and source error',
    () async {
      await prepare('one');
      final player = players.single;
      player.loaded();
      await bridge.seek('one', const Duration(seconds: 7));
      player.seekError = StateError('seek failed');
      final result = await bridge.seek('one', const Duration(seconds: 20));
      expect(result.errorCodeOrNull, NativeErrorCode.playerError);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.position, const Duration(seconds: 7));
      expect(snapshot.playing, true);
      expect(snapshot.playWhenReady, true);
      expect(snapshot.error, isNull);
      expect(player.disposed, false);
      player.seekError = null;
      expect(
        (await bridge.seek('one', const Duration(seconds: 30))).isOk,
        true,
      );
    },
  );

  test(
    'a live seek publishes its target only after the player succeeds',
    () async {
      await prepare('one');
      final player = players.single;
      player.loaded();
      await bridge.seek('one', const Duration(seconds: 7));
      player
        ..seekGate = Completer()
        ..seekStarted = Completer();
      final seek = bridge.seek('one', const Duration(seconds: 20));
      await player.seekStarted!.future;
      expect(
        (await bridge.snapshot()).valueOrNull!.sessions.single.position,
        const Duration(seconds: 7),
      );
      player.seekGate!.complete();
      expect((await seek).valueOrNull!.position, const Duration(seconds: 20));
    },
  );

  test('deferred sessions create a player only while playing', () async {
    await prepare('one', deferred: true);
    expect(players, isEmpty);
    expect(bridge.playerForSession('one'), isNull);
    await bridge.play('one', transportCommandId: 10);
    final first = bridge.playerForSession('one');
    await bridge.pause('one', transportCommandId: 11);
    await bridge.play('one', transportCommandId: 12);
    expect(bridge.playerForSession('one'), isNot(same(first)));
    expect(players.first.disposed, true);
    expect(players, hasLength(2));
    final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
    expect(snapshot.transportCommandId, 12);
    expect(snapshot.playing, true);
  });

  test('timer reset restores fade on a released Windows session', () async {
    await prepare('one');
    final graph = createTestRuntimeGraph(
      nativePlaybackRepository: NativePlaybackRepository(bridge: bridge),
    );
    addTearDown(graph.runtime.dispose);
    graph.playback.registerSession(
      PlaybackSession(
        id: 'one',
        currentTrackPath: 'https://example.com/one.wav',
        loopMode: playback.SessionLoopMode.single,
        nonSingleLoopMode: playback.SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime.now(),
        state: const playback.PlayerState(false, playback.ProcessingState.idle),
      ),
    );
    await bridge.setFadeMultiplier('one', 0);
    await bridge.pause('one');
    graph.playback.applyFadeMultiplierToPlayingSessions(1);
    await bridge.play('one');
    expect(players.last.state.volume, 100);
  });

  test(
    'track stop limits native queue without reloading the current decoder',
    () async {
      final queue = [
        for (final name in ['a', 'b', 'c'])
          <String, Object?>{
            'uri': 'https://example.com/$name.wav',
            'path': name,
          },
      ];
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse(queue[1]['uri']! as String),
        title: 'b',
        queue: queue,
        queueStartIndex: 1,
        repeatAll: true,
        autoPlay: true,
      );
      await bridge.seek('one', const Duration(seconds: 12));
      final result = await bridge.setStopAfterCurrentTrack('one', true);
      expect(result.isOk, true);
      expect(players.single.opens, 1);
      expect(players.single.state.playlist.medias, hasLength(1));
      expect(players.single.state.position, const Duration(seconds: 12));
      expect(players.single.state.playlistMode, PlaylistMode.none);
      expect(
        (await bridge.snapshot()).valueOrNull!.sessions.single.retainedUris,
        hasLength(3),
      );
      await bridge.setStopAfterCurrentTrack('one', false);
      expect(players.single.state.playlist.medias, hasLength(3));
      expect(players.single.state.playlist.index, 1);
      expect(players.single.opens, 1);
      expect(players.single.state.position, const Duration(seconds: 12));
      expect(players.single.state.playlistMode, PlaylistMode.loop);
    },
  );

  test(
    'sessions play concurrently and exclusive play pauses only others',
    () async {
      await prepare('one');
      await prepare('two');
      await bridge.play('one');
      await bridge.play('two');
      expect(players.every((p) => p.state.playing), true);
      await bridge.play('one', exclusive: true);
      expect(players[0].state.playing, true);
      expect(players[1].state.playing, false);
    },
  );

  test(
    'shuffle reordering preserves duplicate logical entries across track-stop cancellation',
    () async {
      configureNextPlayer = (player) => player.reorderOnShuffle = true;
      final queue = [
        for (final name in ['a', 'b', 'c'])
          <String, Object?>{
            'uri': 'https://example.com/same.wav',
            'path': name,
          },
      ];
      await bridge.prepareSession(
        sessionId: 'shuffle',
        uri: Uri.parse(queue[1]['uri'] as String),
        title: 'b',
        queue: queue,
        queueStartIndex: 1,
        autoPlay: true,
        shuffle: true,
        repeatAll: true,
      );
      await bridge.seek('shuffle', const Duration(seconds: 12));
      final decoder = bridge.playerForSession('shuffle');
      for (var cycle = 0; cycle < 2; cycle++) {
        expect(
          (await bridge.setStopAfterCurrentTrack('shuffle', true)).isOk,
          true,
        );
        expect(
          (await bridge.setStopAfterCurrentTrack('shuffle', false)).isOk,
          true,
        );
        await Future<void>.delayed(Duration.zero);
        final restored = (await bridge.snapshot()).valueOrNull!.sessions.single;
        expect(restored.queueIndex, 1);
        expect(restored.path, 'b');
        expect(restored.position, const Duration(seconds: 12));
        expect(bridge.playerForSession('shuffle'), same(decoder));
      }
      await bridge.setStopAfterCurrentTrack('shuffle', true);
      players.single.completeBeforePlayingEvent();
      await Future<void>.delayed(Duration.zero);
      final stopped = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(stopped.queueIndex, 1);
      expect(stopped.path, 'b');
    },
  );

  test(
    'queue edits reconcile shuffled duplicate entries without replacing the decoder',
    () async {
      configureNextPlayer = (player) => player.reorderOnShuffle = true;
      final queue = [
        for (final name in ['a', 'b', 'c', 'd'])
          <String, Object?>{
            'uri': 'https://example.com/same.wav',
            'path': name,
          },
      ];
      await bridge.prepareSession(
        sessionId: 'shuffle',
        uri: Uri.parse(queue[1]['uri'] as String),
        title: 'b',
        queue: queue.take(3).toList(),
        queueStartIndex: 1,
        autoPlay: true,
        shuffle: true,
      );
      await Future<void>.delayed(Duration.zero);
      await bridge.seek('shuffle', const Duration(seconds: 12));
      final player = players.single;
      final before = player.state.playlist;
      final decoder = before.medias[before.index];
      final third = before.medias.first;
      expect(
        (await bridge.updateQueue(
          'shuffle',
          queue: [queue[2], queue[1], queue[3]],
          queueRevision: 1,
          shuffle: true,
        )).isOk,
        true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(player.state.playlist.medias.first, same(third));
      expect(player.state.playlist.medias[1], same(decoder));
      final updated = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(updated.path, 'b');
      expect(updated.queueIndex, 1);
      expect(updated.position, const Duration(seconds: 12));
      player.advance(0);
      await Future<void>.delayed(Duration.zero);
      final advanced = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(advanced.path, 'c');
      expect(advanced.queueIndex, 0);
      expect(player.opens, 1);
    },
  );

  test(
    'gain fade and temporary speed preserve independent saved values',
    () async {
      await prepare('one');
      await prepare('two');
      await bridge.setVolume('one', 2.5);
      await bridge.setFadeMultiplier('one', 0.2);
      await bridge.setSpeed('one', 1.5);
      await bridge.setTemporarySpeed('one', 2);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.first;
      expect(snapshot.volume, 2.5);
      expect(snapshot.speed, 1.5);
      expect(players[0].state.volume, 50);
      expect(players[0].state.rate, 2);
      expect(players[1].state.volume, 100);
      await bridge.setTemporarySpeed('one', null);
      expect(players[0].state.rate, 1.5);
    },
  );

  test(
    'pause clears temporary speed before cold resume without affecting another session',
    () async {
      await prepare('one');
      await prepare('two');
      players.first.loaded();
      await bridge.seek('one', const Duration(seconds: 22));
      await bridge.setSpeed('one', 1.5);
      await bridge.setTemporarySpeed('one', 2);
      await bridge.setTemporarySpeed('two', 2);
      final other = bridge.playerForSession('two');
      await bridge.pause('one');
      expect(players.first.disposed, true);
      expect(bridge.playerForSession('one'), isNull);

      // A paused UI clears its gesture locally, so resume must not depend on
      // receiving a native temporary-speed reset after the decoder is gone.
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/one.wav'),
        title: 'one',
        speed: 1.5,
        startPosition: const Duration(seconds: 22),
      );
      expect(players, hasLength(2));
      await bridge.play('one');
      final resumed = players.last;
      resumed.loaded();
      await Future<void>.delayed(Duration.zero);
      await bridge.snapshot();
      expect(resumed.state.rate, 1.5);
      expect(resumed.seeks, [const Duration(seconds: 22)]);
      expect(resumed.state.playing, true);
      expect(bridge.playerForSession('two'), same(other));
      expect(players[1].state.rate, 2);
      expect(players[1].state.playing, true);
      expect(players[1].disposed, false);
    },
  );

  test('invalid exclusive play leaves other sessions playing', () async {
    await prepare('one');
    final result = await bridge.play('missing', exclusive: true);
    expect(result.errorCodeOrNull, NativeErrorCode.invalidArgument);
    expect(players.single.state.playing, true);
    expect(
      (await bridge.snapshot()).valueOrNull!.sessions.single.playWhenReady,
      true,
    );
  });

  test(
    'exclusive play reports a failed pause before starting its player',
    () async {
      await prepare('one', deferred: true);
      await prepare('two');
      players.single.pauseError = StateError('pause failed');
      final result = await bridge.play('one', exclusive: true);
      expect(result.errorCodeOrNull, NativeErrorCode.playerError);
      expect(result.errorOrNull, contains('pause failed'));
      expect(bridge.playerForSession('one'), isNull);
      expect(players.single.state.playing, true);
    },
  );

  test(
    'restore waits for loaded duration before seeking and playing',
    () async {
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/one.wav'),
        title: 'one',
        startPosition: const Duration(seconds: 45),
        autoPlay: true,
      );
      expect(players.single.seeks, isEmpty);
      expect(players.single.state.playing, false);
      players.single.loaded();
      await Future<void>.delayed(Duration.zero);
      await bridge.snapshot();
      expect(players.single.seeks, [const Duration(seconds: 45)]);
      expect(players.single.state.playing, true);
    },
  );

  test(
    'pause during load releases its player and restores pending seek on resume',
    () async {
      await prepare('one', position: const Duration(seconds: 22));
      await bridge.play('one');
      await bridge.pause('one');
      expect(players.single.seeks, isEmpty);
      expect(players.single.disposed, true);
      expect(bridge.playerForSession('one'), isNull);
      final paused = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(paused.position, const Duration(seconds: 22));
      expect(paused.processingState, 'idle');
      expect(paused.playWhenReady, false);
      await bridge.play('one');
      final resumed = players.last;
      expect(resumed.state.playing, false);
      resumed.loaded();
      await Future<void>.delayed(Duration.zero);
      await bridge.snapshot();
      expect(resumed.seeks, [const Duration(seconds: 22)]);
      expect(resumed.state.playing, true);
    },
  );

  test(
    'a superseded restore seek cannot autoplay the previous source',
    () async {
      await prepare('one', position: const Duration(seconds: 22));
      final player = players.single;
      final gate = Completer<void>();
      final started = Completer<void>();
      player.seekGate = gate;
      player.seekStarted = started;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      player.loaded();
      await started.future;
      final replacement = bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/replacement.wav'),
        title: 'replacement',
        startPosition: const Duration(seconds: 30),
        autoPlay: true,
      );
      gate.complete();
      expect((await replacement).isOk, true);
      expect(player.plays, 0);
      player.loaded();
      await Future<void>.delayed(Duration.zero);
      await bridge.setVolume('one', 1);
      expect(player.seeks, [
        const Duration(seconds: 22),
        const Duration(seconds: 30),
      ]);
      expect(player.plays, 1);
    },
  );

  test(
    'queue removal retains current media and position before advancing',
    () async {
      await prepare('one');
      await bridge.seek('one', const Duration(seconds: 12));
      await bridge.setRepeatOne(
        'one',
        false,
        repeatAll: true,
        shuffle: true,
        queue: [
          {'uri': 'https://example.com/two.wav', 'title': 'two'},
        ],
      );
      final player = players.single;
      expect(
        player.opens,
        1,
        reason: 'queue edits must not restart the current decoder',
      );
      expect(player.state.playlist.medias, hasLength(2));
      expect(
        player.state.playlist.medias.first.uri,
        'https://example.com/one.wav',
      );
      expect(player.state.playlistMode, PlaylistMode.loop);
      expect(player.state.shuffle, true);
      player.loaded();
      await Future<void>.delayed(Duration.zero);
      await bridge.snapshot();
      expect(player.seeks.last, const Duration(seconds: 12));
      player.advance(1);
      await Future<void>.delayed(Duration.zero);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.title, 'two');
      expect(snapshot.queueIndex, 0);
      expect(player.state.playlist.medias, hasLength(1));
    },
  );

  test('duplicate media URIs keep their distinct queue positions', () async {
    final result = await bridge.prepareSession(
      sessionId: 'one',
      uri: Uri.parse('https://example.com/repeated.wav'),
      title: 'first',
      autoPlay: true,
      queue: [
        {'uri': 'https://example.com/repeated.wav', 'title': 'first'},
        {'uri': 'https://example.com/repeated.wav', 'title': 'second'},
      ],
    );
    expect(result.isOk, true, reason: result.errorOrNull);

    players.single.advance(1);
    await Future<void>.delayed(Duration.zero);
    final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;

    expect(snapshot.queueIndex, 1);
    expect(snapshot.title, 'second');
  });

  test(
    'idle sessions retain data without players or periodic events',
    () async {
      final snapshots = <NativePlaybackSnapshot>[];
      final progress = <NativePlaybackProgressUpdate>[];
      final snapshotSub = bridge.snapshots.listen(snapshots.add);
      final progressSub = bridge.progressUpdates.listen(progress.add);
      addTearDown(snapshotSub.cancel);
      addTearDown(progressSub.cancel);
      for (var i = 0; i < 50; i++) {
        final result = await bridge.prepareSession(
          sessionId: 'idle-$i',
          uri: Uri.parse('https://example.com/$i.wav'),
          title: '$i',
        );
        expect(result.isOk, true);
      }
      await bridge.setVolume('idle-0', 1.5);
      await bridge.setSpeed('idle-0', 1.25);
      await Future<void>.delayed(Duration.zero);
      final eventCount = snapshots.length;
      await bridge.setVolume('idle-0', 1.5);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(players, isEmpty);
      expect(progress, isEmpty);
      expect(snapshots, hasLength(eventCount));
      expect((await bridge.snapshot()).valueOrNull!.sessions, hasLength(50));
    },
  );

  test('one blocked open does not delay another session transport', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    configureNextPlayer = (player) {
      player.openGate = gate;
      player.openStarted = started;
    };
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final opening = prepare('one');
    await started.future;
    await prepare('two').timeout(const Duration(seconds: 1));
    expect(
      (await bridge.pause('two').timeout(const Duration(seconds: 1))).isOk,
      true,
    );
    expect(
      (await bridge
              .seek('two', const Duration(seconds: 4))
              .timeout(const Duration(seconds: 1)))
          .isOk,
      true,
    );
    expect(players[1].state.playing, false);
    expect(players[1].seeks, isEmpty);
    expect(players[1].disposed, true);
    expect(
      (await bridge.snapshot()).valueOrNull!.sessions.last.position,
      const Duration(seconds: 4),
    );
    expect(gate.isCompleted, false);
    gate.complete();
    await opening;
  });

  test(
    'superseded open and pause during open cannot start stale audio',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      configureNextPlayer = (player) {
        player.openGate = gate;
        player.openStarted = started;
      };
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final opening = bridge.prepareSession(
        sessionId: 'one',
        title: 'old',
        uri: Uri.parse('https://example.com/old.wav'),
        autoPlay: true,
      );
      await started.future;
      final latest = bridge.prepareSession(
        sessionId: 'one',
        title: 'new',
        uri: Uri.parse('https://example.com/new.wav'),
        autoPlay: true,
      );
      final pausing = bridge.pause('one', transportCommandId: 7);
      gate.complete();
      expect((await opening).isFailure, true);
      expect((await latest).isOk, true);
      expect((await pausing).isOk, true);
      expect(players.single.plays, 0);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.title, 'new');
      expect(snapshot.playWhenReady, false);
    },
  );

  test(
    'pauseAll and clearAll dispatch to all session lanes concurrently',
    () async {
      await prepare('one');
      await prepare('two');
      final pauseGate = Completer<void>();
      final pauseStarted = Completer<void>();
      players[0].pauseGate = pauseGate;
      players[0].pauseStarted = pauseStarted;
      addTearDown(() {
        if (!pauseGate.isCompleted) pauseGate.complete();
      });
      final pausing = bridge.pauseAll();
      await pauseStarted.future;
      await bridge.setVolume('two', 1).timeout(const Duration(seconds: 1));
      expect(players[1].state.playing, false);
      expect(pauseGate.isCompleted, false);
      pauseGate.complete();
      expect((await pausing).isOk, true);

      await bridge.play('one');
      await bridge.play('two');
      final first = players.lastWhere(
        (player) =>
            player.state.playing &&
            player.state.playlist.medias.first.uri.endsWith('one.wav'),
      );
      final second = players.lastWhere(
        (player) =>
            player.state.playing &&
            player.state.playlist.medias.first.uri.endsWith('two.wav'),
      );
      final disposeGate = Completer<void>();
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      first.disposeGate = disposeGate;
      first.disposeStarted = firstStarted;
      second.disposeStarted = secondStarted;
      addTearDown(() {
        if (!disposeGate.isCompleted) disposeGate.complete();
      });
      final clearing = bridge.clearAll();
      await firstStarted.future;
      await secondStarted.future.timeout(const Duration(seconds: 1));
      expect(second.disposed, true);
      expect((await bridge.snapshot()).valueOrNull!.sessions, isEmpty);
      expect(disposeGate.isCompleted, false);
      disposeGate.complete();
      expect((await clearing).isOk, true);
    },
  );

  test('blocked queue edits and disposal stay within their session', () async {
    await prepare('one');
    await prepare('two');
    final first = players[0];
    final addGate = Completer<void>();
    final addStarted = Completer<void>();
    first.addGate = addGate;
    first.addStarted = addStarted;
    addTearDown(() {
      if (!addGate.isCompleted) addGate.complete();
    });
    final editing = bridge.updateQueue(
      'one',
      queue: [
        {'uri': 'https://example.com/one.wav', 'title': 'one'},
        {'uri': 'https://example.com/next.wav', 'title': 'next'},
      ],
      queueRevision: 1,
    );
    await addStarted.future;
    expect(
      (await bridge.pause('two').timeout(const Duration(seconds: 1))).isOk,
      true,
    );
    expect(addGate.isCompleted, false);
    addGate.complete();
    expect((await editing).isOk, true);

    final disposeGate = Completer<void>();
    final disposeStarted = Completer<void>();
    first.disposeGate = disposeGate;
    first.disposeStarted = disposeStarted;
    addTearDown(() {
      if (!disposeGate.isCompleted) disposeGate.complete();
    });
    final removing = bridge.removeSession('one');
    await disposeStarted.future;
    expect(
      (await bridge.play('two').timeout(const Duration(seconds: 1))).isOk,
      true,
    );
    expect(bridge.playerForSession('one'), isNull);
    expect(disposeGate.isCompleted, false);
    disposeGate.complete();
    expect((await removing).isOk, true);
  });

  test(
    'removal invalidates an open result before autoplay and emission',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      configureNextPlayer = (player) {
        player.openGate = gate;
        player.openStarted = started;
      };
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final snapshots = <NativePlaybackSnapshot>[];
      final sub = bridge.snapshots.listen(snapshots.add);
      addTearDown(sub.cancel);
      final opening = bridge.prepareSession(
        sessionId: 'one',
        title: 'one',
        uri: Uri.parse('https://example.com/one.wav'),
        autoPlay: true,
      );
      await started.future;
      final removing = bridge.removeSession('one');
      await prepare('two').timeout(const Duration(seconds: 1));
      gate.complete();
      expect((await opening).isFailure, true);
      expect((await removing).isOk, true);
      await Future<void>.delayed(Duration.zero);
      expect(players[0].plays, 0);
      expect(players[0].disposed, true);
      expect(
        snapshots.where((snapshot) => snapshot.sessionId == 'one'),
        isEmpty,
      );
    },
  );

  test(
    'pause releases even the focused player and preserves its data for resume',
    () async {
      await prepare('one');
      final first = bridge.playerForSession('one');
      players.single.loaded();
      await bridge.seek('one', const Duration(seconds: 45));
      await bridge.setVolume('one', 1.4);
      await bridge.setSpeed('one', 1.2);
      await bridge.pause('one');
      expect(bridge.playerForSession('one'), isNull);
      expect(players.single.disposed, true);
      final paused = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(paused.position, const Duration(seconds: 45));
      expect(paused.duration, const Duration(minutes: 5));
      expect(paused.volume, 1.4);
      expect(paused.speed, 1.2);
      expect(paused.queueIndex, 0);
      await prepare('two');
      await bridge.play('one');
      expect(players, hasLength(3));
      expect(bridge.playerForSession('one'), isNot(same(first)));
      players.last.loaded();
      await Future<void>.delayed(Duration.zero);
      expect(players.last.seeks, [const Duration(seconds: 45)]);
      expect(players.last.state.volume, 140);
      expect(players.last.state.rate, 1.2);
    },
  );

  test('paused video surfaces never create or retain a player', () async {
    await prepare('one', deferred: true);
    expect(bridge.videoControllerForSession('one'), isNull);
    expect(players, isEmpty);
    await bridge.play('one');
    await bridge.pause('one');
    expect(players.single.disposed, true);
    expect(bridge.videoControllerForSession('one'), isNull);
    await bridge.setVolume('one', 1);
    expect(players, hasLength(1));
    expect(bridge.playerForSession('one'), isNull);
  });

  test(
    'completed playback releases its decoder even before the playing event arrives',
    () async {
      await prepare('one');
      final player = players.single;
      player.loaded();
      await bridge.seek('one', const Duration(seconds: 45));
      player.completeBeforePlayingEvent();
      await Future<void>.delayed(Duration.zero);
      await bridge.setVolume('one', 1);
      expect(bridge.playerForSession('one'), isNull);
      expect(player.disposed, true);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.playing, false);
      expect(snapshot.playWhenReady, false);
      expect(snapshot.position, const Duration(seconds: 45));
    },
  );

  for (final oneShot in [true, false]) {
    test(
      oneShot
          ? 'completed one-shot remains completed through the runtime and replays from zero'
          : 'completed playback advances through the runtime without losing the completion event',
      () async {
        final database = await AppRuntimeTestFixture.installSharedDatabase();
        final graph = createTestRuntimeGraph(
          nativePlaybackRepository: NativePlaybackRepository(bridge: bridge),
        );
        addTearDown(() async {
          await graph.runtime.dispose();
          await AppRuntimeTestFixture.disposeSharedDatabase(database);
        });
        await graph.runtime.start();
        final tracks = [
          for (final name in ['first', 'second'])
            MusicTrack(
              path: 'https://example.com/$name.wav',
              displayName: name,
              groupKey: 'completion',
              groupTitle: 'Completion',
              groupSubtitle: 'Completion',
              isSingle: false,
            ),
        ];
        graph.library.addTracks(tracks, notify: false, persist: false);
        final session = graph.playback.createTrackSession(
          tracks.first,
          customQueueTracks: tracks,
          loopMode: oneShot
              ? playback.SessionLoopMode.folderOnce
              : playback.SessionLoopMode.folderSequential,
        );
        await graph.playback.toggleSessionPlayPause(session.id);
        final first = players.single;
        first.loaded();
        await Future<void>.delayed(Duration.zero);
        await graph.playback.seekSession(
          session.id,
          const Duration(minutes: 5),
        );
        final advancedPlayback = Completer<void>();
        if (!oneShot) {
          configureNextPlayer = (player) {
            unawaited(
              player.stream.playing
                  .firstWhere((playing) => playing)
                  .then((_) => advancedPlayback.complete()),
            );
          };
        }
        first.completeBeforePlayingEvent();

        if (oneShot) {
          await Future<void>.delayed(Duration.zero);
          await bridge.setVolume(session.id, 1);
          await Future<void>.delayed(Duration.zero);
          expect(first.disposed, true);
          expect(bridge.playerForSession(session.id), isNull);
          expect(session.loadedPath, isNull);
          expect(
            session.state.processingState,
            playback.ProcessingState.completed,
          );
          expect(session.position, const Duration(minutes: 5));
          expect(session.playbackRequested, false);
          await graph.playback.pauseAllSessions();
          await Future<void>.delayed(Duration.zero);
          expect(
            session.state.processingState,
            playback.ProcessingState.completed,
          );
          await graph.playback.toggleSessionPlayPause(session.id);
          expect(players, hasLength(2));
          expect(players.last.state.playing, true);
          expect(players.last.seeks, isEmpty);
          expect(session.position, Duration.zero);
          expect(
            (await bridge.snapshot()).valueOrNull!.sessions.single.position,
            Duration.zero,
          );
        } else {
          await graph.playback
              .sessionStates(session.id)
              .firstWhere(
                (state) =>
                    state?.currentTrackPath == tracks.last.path &&
                    state!.effectivePlaying,
              )
              .timeout(const Duration(seconds: 2));
          await advancedPlayback.future.timeout(const Duration(seconds: 2));
          expect(first.disposed, true);
          expect(players, hasLength(2));
          expect(players.last.state.playlist.index, 1);
          expect(players.last.state.playing, true);
          expect(session.currentQueueIndex, 1);
          expect(session.isAdvancingAfterCompletion, false);
        }
      },
    );
  }

  test(
    'paused preparation releases an existing decoder without reopening it',
    () async {
      await prepare('one');
      final player = players.single;
      final result = await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/replacement.wav'),
        title: 'replacement',
        startPosition: const Duration(seconds: 7),
      );
      expect(result.isOk, true);
      expect(player.disposed, true);
      expect(player.opens, 1);
      expect(bridge.playerForSession('one'), isNull);
      expect(result.valueOrNull!.title, 'replacement');
      expect(result.valueOrNull!.position, const Duration(seconds: 7));
      expect(result.valueOrNull!.processingState, 'idle');
    },
  );

  test(
    'blocked pause disposal cannot block another session or invalidate new preparation',
    () async {
      await prepare('one');
      await prepare('two', deferred: true);
      final first = players.single;
      final gate = Completer<void>();
      final started = Completer<void>();
      first.disposeGate = gate;
      first.disposeStarted = started;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final pausing = bridge.pause('one');
      await started.future;
      expect(bridge.playerForSession('one'), isNull);
      final replacing = bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/new.wav'),
        title: 'new',
        startPosition: const Duration(seconds: 20),
      );
      expect(
        (await bridge.play('two').timeout(const Duration(seconds: 1))).isOk,
        true,
      );
      expect(
        (await bridge.setVolume('two', 0.7).timeout(const Duration(seconds: 1)))
            .isOk,
        true,
      );
      expect(gate.isCompleted, false);
      gate.complete();
      expect((await pausing).isOk, true);
      expect((await replacing).isOk, true);
      expect(bridge.playerForSession('one'), isNull);
      await bridge.play('one');
      final resumed = players.last;
      expect(
        resumed.state.playlist.medias.single.uri,
        'https://example.com/new.wav',
      );
      resumed.loaded();
      await Future<void>.delayed(Duration.zero);
      expect(resumed.seeks, [const Duration(seconds: 20)]);
      expect(resumed.state.playing, true);
    },
  );

  test(
    'resume while pause is in flight keeps the latest playback intent',
    () async {
      await prepare('one');
      final player = players.single;
      final gate = Completer<void>();
      final started = Completer<void>();
      player.pauseGate = gate;
      player.pauseStarted = started;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final pausing = bridge.pause('one', transportCommandId: 4);
      await started.future;
      final resuming = bridge.play('one', transportCommandId: 5);
      gate.complete();
      expect((await pausing).isOk, true);
      expect((await resuming).isOk, true);
      expect(player.disposed, false);
      expect(player.state.playing, true);
      expect(players, hasLength(1));
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.transportCommandId, 5);
      expect(snapshot.playWhenReady, true);
    },
  );

  test(
    'structure events deduplicate and carry retained URIs only on edits',
    () async {
      final snapshots = <NativePlaybackSnapshot>[];
      final sub = bridge.snapshots.listen(snapshots.add);
      addTearDown(sub.cancel);
      await prepare('one', deferred: true);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.single.hasRetainedUrisPayload, true);
      final retained =
          (await bridge.snapshot()).valueOrNull!.sessions.single.retainedUris;
      expect(
        (await bridge.snapshot()).valueOrNull!.sessions.single.retainedUris,
        same(retained),
      );
      await bridge.setVolume('one', 2);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last.hasRetainedUrisPayload, false);
      final count = snapshots.length;
      await bridge.setVolume('one', 2);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(count));
      await bridge.updateQueue(
        'one',
        queue: [
          {'uri': 'https://example.com/one.wav', 'title': 'one'},
          {'uri': 'https://example.com/next.wav', 'title': 'next'},
        ],
        queueRevision: 1,
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last.hasRetainedUrisPayload, true);
      expect(snapshots.last.retainedUris, hasLength(2));
    },
  );

  test(
    'queue edits reuse unchanged entries and invalidate stale revisions',
    () async {
      final original = [
        {'uri': 'https://example.com/one.wav', 'title': 'one'},
        {'uri': 'https://example.com/two.wav', 'title': 'two'},
        {'uri': 'https://example.com/three.wav', 'title': 'three'},
      ];
      await bridge.prepareSession(
        sessionId: 'one',
        title: 'one',
        uri: Uri.parse('https://example.com/one.wav'),
        queue: original,
        autoPlay: true,
      );
      final player = players.single;
      await bridge.updateQueue(
        'one',
        queue: [original[0], original[2]],
        queueRevision: 2,
      );
      expect(player.opens, 1);
      expect(player.removes, 1);
      expect(player.adds, 0);
      expect(player.moves, 0);
      await bridge.updateQueue('one', queue: original, queueRevision: 1);
      expect(player.state.playlist.medias, hasLength(2));
      expect(player.adds, 0);
    },
  );

  test(
    'long queue tail edits retain the decoder and untouched prefix',
    () async {
      final original = [
        for (var i = 0; i < 10000; i++)
          {'uri': 'https://example.com/$i.wav', 'path': '/$i', 'title': '$i'},
      ];
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse(original[5000]['uri']!),
        path: original[5000]['path'],
        title: '5000',
        queue: original,
        queueStartIndex: 5000,
        autoPlay: true,
      );
      final player = players.single;
      expect(playlistReads, 1);
      player.loaded();
      await bridge.seek('one', const Duration(seconds: 17));
      final added = {'uri': 'https://example.com/last.wav', 'path': '/last'};
      expect(
        (await bridge.updateQueue(
          'one',
          queue: [...original, added],
          queueRevision: 1,
        )).isOk,
        true,
      );
      expect(player.adds, 1);
      expect(player.moves, 0);
      expect(player.removes, 0);
      expect(playlistReads, 3);
      expect(
        (await bridge.updateQueue(
          'one',
          queue: original,
          queueRevision: 2,
        )).isOk,
        true,
      );
      expect(player.opens, 1);
      expect(player.removes, 1);
      expect(player.moves, 0);
      expect(playlistReads, 5);
      expect(
        player.state.playlist.medias.map((item) => item.uri),
        original.map((item) => item['uri']),
      );
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.queueIndex, 5000);
      expect(snapshot.position, const Duration(seconds: 17));
      expect(snapshot.path, '/5000');
    },
  );

  test(
    'many repeated queue entries preserve the selected occurrence',
    () async {
      final original = [
        for (var i = 0; i < 3000; i++)
          {
            'uri': 'https://example.com/repeated.wav',
            'path': '/same',
            'title': '$i',
          },
      ];
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse(original.first['uri']!),
        path: '/same',
        title: '1500',
        queue: original,
        queueStartIndex: 1500,
        autoPlay: true,
      );
      final result = await bridge.updateQueue(
        'one',
        queue: [...original, original.first],
        queueRevision: 1,
      );
      expect(result.isOk, true, reason: result.errorOrNull);
      final player = players.single;
      expect(player.opens, 1);
      expect(player.adds, 1);
      expect(player.moves, 0);
      expect(player.removes, 0);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.queueIndex, 1500);
      expect(snapshot.title, '1500');
      expect(snapshot.retainedUris, hasLength(3001));
    },
  );

  test(
    'retained current media is removed after advancing to an equal URI',
    () async {
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/shared.wav'),
        title: 'old',
        path: '/old',
        autoPlay: true,
      );
      await bridge.setRepeatOne(
        'one',
        false,
        queue: [
          {
            'uri': 'https://example.com/shared.wav',
            'path': '/new',
            'title': 'new',
          },
        ],
      );

      players.single.advance(1);
      await Future<void>.delayed(Duration.zero);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;

      expect(snapshot.title, 'new');
      expect(snapshot.queueIndex, 0);
      expect(players.single.state.playlist.medias, hasLength(1));
    },
  );

  test(
    'late retained-item advancement cleans cold data without using a disposed player',
    () async {
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.parse('https://example.com/shared.wav'),
        title: 'old',
        path: '/old',
        autoPlay: true,
      );
      await bridge.updateQueue(
        'one',
        queue: [
          {
            'uri': 'https://example.com/shared.wav',
            'path': '/new',
            'title': 'new',
          },
        ],
        queueRevision: 1,
      );
      final player = players.single;
      final gate = Completer<void>();
      final started = Completer<void>();
      player.pauseGate = gate;
      player.pauseStarted = started;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final pausing = bridge.pause('one');
      await started.future;
      player.advance(1);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect((await pausing).isOk, true);
      await bridge.setVolume('one', 1);
      expect(player.disposed, true);
      expect(player.removes, 0);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.title, 'new');
      expect(snapshot.queueIndex, 0);
      expect(snapshot.retainedUris, ['https://example.com/shared.wav']);
      expect(snapshot.processingState, 'idle');
    },
  );

  test('queue edits can retry after a native add fails midway', () async {
    final current = {
      'uri': 'https://example.com/current.wav',
      'title': 'current',
    };
    await bridge.prepareSession(
      sessionId: 'one',
      uri: Uri.parse(current['uri']!),
      title: 'current',
      autoPlay: true,
      queue: [
        current,
        {'uri': 'https://example.com/old-1.wav'},
        {'uri': 'https://example.com/old-2.wav'},
      ],
    );
    final player = players.single;
    player.addError = StateError('add failed');
    final replacement = [
      current,
      {'uri': 'https://example.com/next.wav', 'title': 'next'},
    ];
    final failed = await bridge.updateQueue(
      'one',
      queue: replacement,
      queueRevision: 1,
    );
    expect(failed.errorCodeOrNull, NativeErrorCode.playerError);
    final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
    expect(snapshot.retainedUris, [current['uri']]);
    expect(snapshot.queueIndex, 0);
    expect(player.state.playlist.medias, hasLength(1));

    final retried = await bridge.updateQueue(
      'one',
      queue: replacement,
      queueRevision: 1,
    );
    expect(retried.isOk, true, reason: retried.errorOrNull);
    expect(player.state.playlist.medias.map((media) => media.uri), [
      current['uri'],
      replacement.last['uri'],
    ]);
    expect(player.opens, 1);
    expect(bridge.playerForSession('one')!.platform, same(player));
  });

  test(
    'repeat modes map to one native queue without a second player',
    () async {
      await prepare('one');
      for (final repeatOne in [false, true]) {
        for (final repeatAll in [false, true]) {
          await bridge.setRepeatOne('one', repeatOne, repeatAll: repeatAll);
          expect(
            players.single.state.playlistMode,
            repeatOne
                ? PlaylistMode.single
                : repeatAll
                ? PlaylistMode.loop
                : PlaylistMode.none,
          );
        }
      }
    },
  );

  test('errors retry next candidate and preserve source position', () async {
    await bridge.prepareSession(
      sessionId: 'one',
      title: 'one',
      uri: Uri.parse('https://example.com/bad.wav'),
      autoPlay: true,
      candidateUris: [
        Uri.parse('https://example.com/bad.wav'),
        Uri.parse('https://example.com/good.wav'),
      ],
    );
    await bridge.seek('one', const Duration(seconds: 9));
    players.single.emitError('connection reset');
    await Future<void>.delayed(const Duration(milliseconds: 550));
    await bridge.snapshot();
    expect(players.single.opens, 2);
    expect(
      players.single.state.playlist.medias.single.uri,
      'https://example.com/good.wav',
    );
    players.single.loaded();
    await Future<void>.delayed(Duration.zero);
    await bridge.snapshot();
    expect(players.single.seeks.last, const Duration(seconds: 9));
  });

  test('pause cancels scheduled network retry', () async {
    await prepare('one');
    await bridge.play('one');
    players.single.emitError('connection reset');
    await Future<void>.delayed(Duration.zero);
    await bridge.pause('one');
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(players.single.opens, 1);
  });

  test('network recovery timeout releases only the failed session', () async {
    await prepare('one');
    await prepare('two');
    final failed = players.first;
    final otherPlayer = bridge.playerForSession('two');
    final events = <NativePlaybackSnapshot>[];
    final subscription = bridge.snapshots.listen(events.add);
    addTearDown(subscription.cancel);

    failed.emitError('connection reset');
    await Future<void>.delayed(Duration.zero);
    var snapshot = (await bridge.snapshot()).valueOrNull!.sessions.singleWhere(
      (session) => session.sessionId == 'one',
    );
    expect(snapshot.playWhenReady, isTrue);
    elapsed = const Duration(minutes: 10);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    failed.emitError('connection reset');
    await Future<void>.delayed(Duration.zero);
    snapshot = (await bridge.snapshot()).valueOrNull!.sessions.singleWhere(
      (session) => session.sessionId == 'one',
    );

    expect(snapshot.playWhenReady, isFalse);
    expect(snapshot.error, 'connection reset');
    expect(bridge.playerForSession('one'), isNull);
    expect(bridge.playerForSession('two'), same(otherPlayer));
    expect(
      events.lastWhere((event) => event.sessionId == 'one').playWhenReady,
      isFalse,
    );
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(failed.opens, 2);

    await bridge.play('one');
    final restarted = players.last;
    restarted.emitError('connection reset');
    await Future<void>.delayed(Duration.zero);
    expect(bridge.playerForSession('one'), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(restarted.opens, 2);
  });

  test(
    'unrecoverable local error clears playback intent and decoder',
    () async {
      await bridge.prepareSession(
        sessionId: 'one',
        uri: Uri.file('C:/audio/one.wav'),
        title: 'one',
        autoPlay: true,
      );
      await prepare('two');
      final otherPlayer = bridge.playerForSession('two');
      players.first.emitError('file unavailable');
      await Future<void>.delayed(Duration.zero);
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions
          .singleWhere((session) => session.sessionId == 'one');
      expect(snapshot.playWhenReady, isFalse);
      expect(snapshot.error, 'file unavailable');
      expect(bridge.playerForSession('one'), isNull);
      expect(bridge.playerForSession('two'), same(otherPlayer));
    },
  );

  test(
    'queue replacement cancels retries bound to the previous queue',
    () async {
      await prepare('one');
      players.single.emitError('connection reset');
      await Future<void>.delayed(Duration.zero);
      await bridge.updateQueue(
        'one',
        queue: [
          {'uri': 'https://example.com/one.wav', 'title': 'one'},
          {'uri': 'https://example.com/next.wav', 'title': 'next'},
        ],
        queueRevision: 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 550));
      expect(players.single.opens, 1);
      expect(players.single.state.playlist.medias, hasLength(2));
    },
  );

  test('device disconnect follows the configured preference', () async {
    final repository = NativePlaybackRepository(bridge: bridge);
    await prepare('one');
    await bridge.play('one');
    await bridge.setPlaybackBehavior(
      pauseOnAudioDeviceDisconnect: false,
      requestAudioFocus: false,
      pauseOnTransientAudioFocusLoss: false,
      resumeAfterTransientAudioFocusGain: false,
    );
    await repository.handleDeviceDisconnected();
    expect(players.single.state.playing, true);
    await bridge.setPlaybackBehavior(
      pauseOnAudioDeviceDisconnect: true,
      requestAudioFocus: false,
      pauseOnTransientAudioFocusLoss: false,
      resumeAfterTransientAudioFocusGain: false,
    );
    await repository.handleDeviceDisconnected();
    expect(players.single.state.playing, false);
  });

  test('invalid transport arguments fail without creating a player', () async {
    final missing = await bridge.play('missing');
    expect(missing.errorCodeOrNull, NativeErrorCode.invalidArgument);
    final invalid = await bridge.prepareSession(
      sessionId: '',
      title: 'one',
      uri: Uri.parse('file:///one.wav'),
    );
    expect(invalid.errorCodeOrNull, NativeErrorCode.invalidArgument);
    expect(players, isEmpty);
  });

  test(
    'removing session closes player and empties retained URI snapshot',
    () async {
      await prepare('one');
      await bridge.removeSession('one');
      expect(players.single.disposed, true);
      expect(bridge.playerForSession('one'), isNull);
      expect((await bridge.snapshot()).valueOrNull!.sessions, isEmpty);
    },
  );

  test(
    'audio filters compose EQ normalization denoise and channel balance',
    () {
      expect(windowsEqCapabilities.minGainDb, -18);
      expect(windowsEqCapabilities.maxGainDb, 18);
      final filter = windowsAudioFilter(
        NativeAudioEffects(
          channelSwapEnabled: true,
          state: AudioEffectsState(
            eqEnabled: true,
            eqBandLevels: {1000: 3},
            noiseReductionEnabled: true,
            volumeNormalizationEnabled: true,
            panning: 0.5,
          ),
        ),
      );
      expect(filter, contains('afftdn=nf=-25'));
      expect(filter, contains('equalizer=f=1000:t=o:w=1:g=3.0'));
      expect(
        windowsAudioFilter(
          NativeAudioEffects(
            channelSwapEnabled: false,
            state: AudioEffectsState(
              eqEnabled: true,
              eqBandLevels: {1000: 18, 3000: -18},
            ),
          ),
        ),
        allOf(contains('g=18.0'), contains('g=-18.0')),
      );
      expect(filter, contains('dynaudnorm'));
      expect(filter, contains('pan=args=stereo|c0=0.5*c1|c1=1.0*c0'));
      expect(
        windowsAudioFilter(
          NativeAudioEffects(
            state: AudioEffectsState.flat,
            channelSwapEnabled: false,
          ),
        ),
        '',
      );
    },
  );
}

class _Player extends PlatformPlayer {
  _Player() : super(configuration: const PlayerConfiguration());
  void emitError(String error) => errorController.add(error);
  void completeBeforePlayingEvent() {
    state = state.copyWith(completed: true);
    completedController.add(true);
  }

  int opens = 0, plays = 0, adds = 0, removes = 0, moves = 0;
  Object? pauseError, addError, seekError;
  Completer<void>? pauseGate, pauseStarted;
  Completer<void>? openGate,
      openStarted,
      addGate,
      addStarted,
      seekGate,
      seekStarted,
      disposeGate,
      disposeStarted;
  bool disposed = false;
  bool reorderOnShuffle = false;
  List<Media>? _unshuffledMedias;
  final seeks = <Duration>[];
  @override
  Future<void> add(Media media) async {
    adds++;
    if (addStarted?.isCompleted == false) addStarted!.complete();
    await addGate?.future;
    final error = addError;
    addError = null;
    if (error != null) throw error;
    state = state.copyWith(
      playlist: Playlist([
        ...state.playlist.medias,
        media,
      ], index: state.playlist.index),
    );
  }

  @override
  Future<void> remove(int index) async {
    removes++;
    final items = [...state.playlist.medias]..removeAt(index);
    state = state.copyWith(
      playlist: Playlist(
        items,
        index: state.playlist.index - (index < state.playlist.index ? 1 : 0),
      ),
    );
  }

  @override
  Future<void> move(int from, int to) async {
    moves++;
    final items = [...state.playlist.medias];
    final item = items.removeAt(from);
    items.insert(to, item);
    final previous = state.playlist.index;
    final next = previous == from
        ? to
        : from < previous && to >= previous
        ? previous - 1
        : from > previous && to <= previous
        ? previous + 1
        : previous;
    state = state.copyWith(playlist: Playlist(items, index: next));
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    if (openStarted?.isCompleted == false) openStarted!.complete();
    await openGate?.future;
    state = state.copyWith(
      playlist: playable as Playlist,
      playing: play,
      position: Duration.zero,
      completed: false,
      duration: Duration.zero,
    );
    playlistController.add(state.playlist);
    durationController.add(Duration.zero);
  }

  void loaded() {
    state = state.copyWith(duration: const Duration(minutes: 5));
    durationController.add(state.duration);
  }

  void advance(int index) {
    state = state.copyWith(
      playlist: Playlist(state.playlist.medias, index: index),
    );
    playlistController.add(state.playlist);
  }

  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    if (pauseStarted?.isCompleted == false) pauseStarted!.complete();
    await pauseGate?.future;
    if (pauseError != null) throw pauseError!;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (seekStarted?.isCompleted == false) seekStarted!.complete();
    await seekGate?.future;
    if (seekError != null) throw seekError!;
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  Future<void> setVolume(double volume) async =>
      state = state.copyWith(volume: volume);
  @override
  Future<void> setRate(double rate) async => state = state.copyWith(rate: rate);
  @override
  Future<void> setPlaylistMode(PlaylistMode mode) async =>
      state = state.copyWith(playlistMode: mode);
  @override
  Future<void> setShuffle(bool shuffle) async {
    if (reorderOnShuffle && shuffle != state.shuffle) {
      final items = state.playlist.medias;
      final current = items[state.playlist.index];
      final List<Media> reordered;
      if (shuffle) {
        _unshuffledMedias = [...items];
        reordered = [items.last, ...items.take(items.length - 1)];
      } else {
        reordered = [
          for (final media in _unshuffledMedias ?? items)
            if (items.any((item) => identical(item, media))) media,
          for (final media in items)
            if (!(_unshuffledMedias ?? items).any(
              (item) => identical(item, media),
            ))
              media,
        ];
      }
      state = state.copyWith(
        playlist: Playlist(
          reordered,
          index: reordered.indexWhere((item) => identical(item, current)),
        ),
        shuffle: shuffle,
      );
      playlistController.add(state.playlist);
    } else {
      state = state.copyWith(shuffle: shuffle);
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (disposeStarted?.isCompleted == false) disposeStarted!.complete();
    await disposeGate?.future;
    await super.dispose();
  }
}

String _playlistJson(Player player) => jsonEncode([
  for (final media in player.state.playlist.medias)
    {'id': identityHashCode(media), 'filename': media.uri},
]);
