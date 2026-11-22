import 'dart:async';
import 'dart:convert';

import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WindowsPlaybackBridge bridge;
  late List<_FakePlatformPlayer> players;
  void Function(_FakePlatformPlayer)? configureNextPlayer;

  setUp(() {
    players = <_FakePlatformPlayer>[];
    configureNextPlayer = null;
    bridge = WindowsPlaybackBridge(
      idleReleaseDelay: Duration.zero,
      readNativePlaylist: (player) async => jsonEncode([
        for (final media in player.state.playlist.medias)
          {'id': identityHashCode(media), 'filename': media.uri},
      ]),
      createPlayer: () {
        final platform = _FakePlatformPlayer();
        configureNextPlayer?.call(platform);
        configureNextPlayer = null;
        players.add(platform);
        return Player(platformPlayer: platform);
      },
    )..startListening();
  });

  tearDown(() => bridge.dispose());

  group('WindowsPlaybackBridge regressions (#23, #46, #69)', () {
    test(
      'queued play does not supersede a newer concurrent prepareSession (#23)',
      () async {
        // Prepare session with deferred player creation (player == null).
        final initial = await bridge.prepareSession(
          sessionId: 'main',
          uri: Uri.parse('https://example.com/old.wav'),
          title: 'Old',
          deferPlayerCreation: true,
        );
        expect(initial.isOk, isTrue, reason: initial.errorOrNull);

        // Prepare another playing session with a gated pause so exclusive play()
        // yields in the queue before opening 'main'.
        final pauseStarted = Completer<void>();
        final pauseGate = Completer<void>();
        configureNextPlayer = (player) {
          player.pauseStarted = pauseStarted;
          player.pauseGate = pauseGate;
        };
        final other = await bridge.prepareSession(
          sessionId: 'other',
          uri: Uri.parse('https://example.com/other.wav'),
          title: 'Other',
          autoPlay: true,
        );
        expect(other.isOk, isTrue, reason: other.errorOrNull);

        final oldPlayFuture = bridge.play('main', exclusive: true);
        await pauseStarted.future;

        // Switch tracks on 'main' while oldPlayFuture is still waiting in queue.
        final newPrepareFuture = bridge.prepareSession(
          sessionId: 'main',
          uri: Uri.parse('https://example.com/new.wav'),
          title: 'New',
          autoPlay: true,
        );

        pauseGate.complete();
        final oldPlayResult = await oldPlayFuture;
        final newPrepareResult = await newPrepareFuture;

        expect(oldPlayResult.isOk, isTrue, reason: oldPlayResult.errorOrNull);
        expect(
          newPrepareResult.isOk,
          isTrue,
          reason: newPrepareResult.errorOrNull,
        );
        expect(
          newPrepareResult.valueOrNull!.uri,
          'https://example.com/new.wav',
        );
        // Only the new track should have been opened for 'main' (1 player for
        // 'other' + 1 player for 'main').
        expect(players, hasLength(2));
        expect(players.last.opens, 1);
        expect(
          players.last.state.playlist.medias.single.uri,
          'https://example.com/new.wav',
        );
      },
    );

    test(
      'prepareSession(autoPlay: false) followed immediately by play() succeeds (#23)',
      () async {
        final prepareFuture = bridge.prepareSession(
          sessionId: 'quick',
          uri: Uri.parse('https://example.com/quick.wav'),
          title: 'Quick',
        );
        final playFuture = bridge.play('quick');

        final prepared = await prepareFuture;
        final played = await playFuture;
        expect(prepared.isOk, isTrue, reason: prepared.errorOrNull);
        expect(played.isOk, isTrue, reason: played.errorOrNull);
        expect(played.valueOrNull!.playWhenReady, isTrue);
      },
    );

    test(
      'play(exclusive: true) and pauseAll() ignore concurrently removed sibling sessions (#46)',
      () async {
        final pauseStarted = Completer<void>();
        final pauseGate = Completer<void>();
        configureNextPlayer = (player) {
          player.pauseStarted = pauseStarted;
          player.pauseGate = pauseGate;
        };
        expect(
          (await bridge.prepareSession(
            sessionId: 'sibling',
            uri: Uri.parse('https://example.com/sibling.wav'),
            title: 'Sibling',
            autoPlay: true,
          )).isOk,
          isTrue,
        );
        expect(
          (await bridge.prepareSession(
            sessionId: 'target',
            uri: Uri.parse('https://example.com/target.wav'),
            title: 'Target',
            deferPlayerCreation: true,
          )).isOk,
          isTrue,
        );

        final playFuture = bridge.play('target', exclusive: true);
        await pauseStarted.future;
        final removeFuture = bridge.removeSession('sibling');
        pauseGate.complete();

        final playResult = await playFuture;
        await removeFuture;
        expect(playResult.isOk, isTrue, reason: playResult.errorOrNull);
        expect(playResult.valueOrNull!.error, isNull);
        expect(playResult.valueOrNull!.playWhenReady, isTrue);

        // Now test pauseAll() when a session is concurrently removed while pausing.
        final pauseAllStarted = Completer<void>();
        final pauseAllGate = Completer<void>();
        players.last.pauseStarted = pauseAllStarted;
        players.last.pauseGate = pauseAllGate;

        final pauseAllFuture = bridge.pauseAll();
        await pauseAllStarted.future;
        final removeTargetFuture = bridge.removeSession('target');
        pauseAllGate.complete();

        final pauseAllResult = await pauseAllFuture;
        await removeTargetFuture;
        expect(pauseAllResult.isOk, isTrue, reason: pauseAllResult.errorOrNull);
      },
    );

    test(
      'play() preserves monotonic transportCommandId when called with default 0 (#69)',
      () async {
        expect(
          (await bridge.prepareSession(
            sessionId: 'cmd',
            uri: Uri.parse('https://example.com/cmd.wav'),
            title: 'Cmd',
          )).isOk,
          isTrue,
        );

        final firstPlay = await bridge.play('cmd', transportCommandId: 7);
        expect(firstPlay.isOk, isTrue);
        expect(firstPlay.valueOrNull!.transportCommandId, 7);

        final paused = await bridge.pause('cmd');
        expect(paused.isOk, isTrue);
        expect(paused.valueOrNull!.transportCommandId, 7);

        final resumedWithoutId = await bridge.play('cmd');
        expect(resumedWithoutId.isOk, isTrue);
        expect(resumedWithoutId.valueOrNull!.transportCommandId, 7);
      },
    );
  });
}

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  int opens = 0;
  Completer<void>? pauseStarted;
  Completer<void>? pauseGate;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
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

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    if (pauseStarted?.isCompleted == false) pauseStarted!.complete();
    await pauseGate?.future;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
  }

  @override
  Future<void> setPlaylistMode(PlaylistMode mode) async {
    state = state.copyWith(playlistMode: mode);
  }

  @override
  Future<void> setShuffle(bool shuffle) async {
    state = state.copyWith(shuffle: shuffle);
  }
}
