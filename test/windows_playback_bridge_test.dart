import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/windows_playback_bridge.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  late WindowsPlaybackBridge bridge;
  late List<_Player> players;
  setUp(() {
    players = [];
    bridge = WindowsPlaybackBridge(
      createPlayer: () {
        final platform = _Player();
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
      startPosition: position,
    );
    expect(result.isOk, true, reason: result.errorOrNull);
  }

  test(
    'deferred sessions create one player on play and share it with video',
    () async {
      await prepare('one', deferred: true);
      expect(players, isEmpty);
      expect(bridge.playerForSession('one'), isNull);
      await bridge.play('one', transportCommandId: 10);
      final first = bridge.playerForSession('one');
      await bridge.pause('one', transportCommandId: 11);
      await bridge.play('one', transportCommandId: 12);
      expect(bridge.playerForSession('one'), same(first));
      expect(players, hasLength(1));
      final snapshot = (await bridge.snapshot()).valueOrNull!.sessions.single;
      expect(snapshot.transportCommandId, 12);
      expect(snapshot.playing, true);
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
    'pause during load retains pending seek without starting audio',
    () async {
      await prepare('one', position: const Duration(seconds: 22));
      await bridge.play('one');
      await bridge.pause('one');
      players.single.loaded();
      await Future<void>.delayed(Duration.zero);
      await bridge.snapshot();
      expect(players.single.seeks, [const Duration(seconds: 22)]);
      expect(players.single.state.playing, false);
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

  test('device disconnect follows the configured preference', () async {
    await prepare('one');
    await bridge.play('one');
    await bridge.setPlaybackBehavior(
      pauseOnAudioDeviceDisconnect: false,
      requestAudioFocus: false,
      pauseOnTransientAudioFocusLoss: false,
      resumeAfterTransientAudioFocusGain: false,
    );
    await bridge.handleDeviceDisconnected();
    expect(players.single.state.playing, true);
    await bridge.setPlaybackBehavior(
      pauseOnAudioDeviceDisconnect: true,
      requestAudioFocus: false,
      pauseOnTransientAudioFocusLoss: false,
      resumeAfterTransientAudioFocusGain: false,
    );
    await bridge.handleDeviceDisconnected();
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
  int opens = 0;
  bool disposed = false;
  final seeks = <Duration>[];
  @override
  Future<void> add(Media media) async {
    state = state.copyWith(
      playlist: Playlist([
        ...state.playlist.medias,
        media,
      ], index: state.playlist.index),
    );
  }

  @override
  Future<void> remove(int index) async {
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
    final items = [...state.playlist.medias];
    final item = items.removeAt(from);
    items.insert(to, item);
    state = state.copyWith(playlist: Playlist(items, index: to));
  }

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
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
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
  Future<void> setShuffle(bool shuffle) async =>
      state = state.copyWith(shuffle: shuffle);
  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}
