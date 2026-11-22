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

    test(
      'onLoadHooks resets chapter start/end to none on normal tracks and guards out-of-bounds index',
      () async {
        final nativePlayers = <_FakeNativePlatformPlayer>[];
        final nativeBridge = WindowsPlaybackBridge(
          idleReleaseDelay: Duration.zero,
          readNativePlaylist: (player) async => jsonEncode([
            for (final media in player.state.playlist.medias)
              {'id': identityHashCode(media), 'filename': media.uri},
          ]),
          createPlayer: () {
            final platform = _FakeNativePlatformPlayer();
            nativePlayers.add(platform);
            return Player(platformPlayer: platform);
          },
        )..startListening();
        addTearDown(nativeBridge.dispose);

        final queue = <Map<String, Object?>>[
          {
            'uri': 'https://example.com/album.m3u8',
            'path': 'https://example.com/album.m3u8#eara-chapter=10000,25000',
            'title': 'Chapter 1',
            'clipStartMs': 10000,
            'clipEndMs': 25000,
          },
          {
            'uri': 'https://example.com/album.m3u8',
            'path': 'https://example.com/album.m3u8#eara-chapter=30000',
            'title': 'Open-ended Chapter',
            'clipStartMs': 30000,
          },
          {
            'uri': 'https://example.com/normal.wav',
            'path': '/normal.wav',
            'title': 'Normal Track',
          },
        ];
        final prepared = await nativeBridge.prepareSession(
          sessionId: 'hooks',
          uri: Uri.parse('https://example.com/album.m3u8'),
          title: 'Chapter 1',
          queue: queue,
          autoPlay: true,
        );
        expect(prepared.isOk, isTrue, reason: prepared.errorOrNull);
        final platform = nativePlayers.single;
        expect(platform.onLoadHooks, isNotEmpty);

        // Chapter 0 sets both start and end.
        platform.playlistPos = '0';
        for (final hook in platform.onLoadHooks) {
          await hook();
        }
        expect(platform.properties['start'], '10.0');
        expect(platform.properties['end'], '25.0');

        // Chapter 1 with null endMs sets start and explicitly resets end to none.
        platform.playlistPos = '1';
        for (final hook in platform.onLoadHooks) {
          await hook();
        }
        expect(platform.properties['start'], '30.0');
        expect(platform.properties['end'], 'none');

        // Normal track 2 explicitly resets both start and end to none.
        platform.playlistPos = '2';
        for (final hook in platform.onLoadHooks) {
          await hook();
        }
        expect(platform.properties['start'], 'none');
        expect(platform.properties['end'], 'none');

        // Out-of-bounds playlist-pos must return cleanly without RangeError.
        platform.playlistPos = '99';
        for (final hook in platform.onLoadHooks) {
          await hook();
        }
      },
    );

    test(
      'detaching mounted video surface while paused releases video player and video init error does not mark audio error',
      () async {
        final prepared = await bridge.prepareSession(
          sessionId: 'video',
          uri: Uri.parse('https://example.com/clip.mp4'),
          title: 'Clip',
          autoPlay: true,
        );
        expect(prepared.isOk, isTrue, reason: prepared.errorOrNull);
        final platform = players.single;

        bridge.attachVideoSurface('video');
        final controller = bridge.videoControllerForSession('video');
        expect(controller, isNotNull);
        // Simulate video controller initialization failure; audio session error must stay null.
        platform.videoControllerCompleter.completeError(
          StateError('texture init failed'),
        );
        await bridge.setVolume('video', 1.0);
        expect(
          (await bridge.snapshot()).valueOrNull!.sessions.single.error,
          isNull,
        );

        // Pausing while surface is mounted keeps the video player alive.
        expect((await bridge.pause('video')).isOk, isTrue);
        expect(bridge.playerForSession('video'), isNotNull);
        expect(platform.disposed, isFalse);

        // Detaching the mounted surface while paused allows idle release.
        bridge.detachVideoSurface('video');
        await bridge.setVolume('video', 1.0);
        expect(bridge.playerForSession('video'), isNull);
        expect(platform.disposed, isTrue);
      },
    );
  });
}

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  int opens = 0;
  bool disposed = false;
  Completer<void>? pauseStarted;
  Completer<void>? pauseGate;

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!videoControllerCompleter.isCompleted) {
      videoControllerCompleter.complete();
    }
    await super.dispose();
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

class _FakeNativePlatformPlayer extends Fake implements NativePlayer {
  final _delegate = _FakePlatformPlayer();

  @override
  final List<Future<void> Function()> onLoadHooks = <Future<void> Function()>[];

  @override
  List<Media> current = <Media>[];

  final Map<String, String> properties = <String, String>{};
  String playlistPos = '0';

  @override
  PlayerState get state => _delegate.state;

  @override
  set state(PlayerState value) => _delegate.state = value;

  @override
  PlayerStream get stream => _delegate.stream;

  @override
  Future<void> get waitForVideoControllerInitializationIfAttached =>
      _delegate.waitForVideoControllerInitializationIfAttached;

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) => _delegate.open(playable, play: play);

  @override
  Future<void> play({bool synchronized = true}) => _delegate.play();

  @override
  Future<void> pause({bool synchronized = true}) => _delegate.pause();

  @override
  Future<void> seek(Duration duration, {bool synchronized = true}) =>
      _delegate.seek(duration);

  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) =>
      _delegate.setVolume(volume);

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) =>
      _delegate.setRate(rate);

  @override
  Future<void> setPlaylistMode(
    PlaylistMode playlistMode, {
    bool synchronized = true,
  }) => _delegate.setPlaylistMode(playlistMode);

  @override
  Future<void> setShuffle(bool shuffle, {bool synchronized = true}) =>
      _delegate.setShuffle(shuffle);

  @override
  Future<void> dispose({bool synchronized = true}) => _delegate.dispose();

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    if (property == 'playlist-pos') return playlistPos;
    if (property.startsWith('playlist/') && property.endsWith('/id')) {
      final rawIdx = property.substring('playlist/'.length, property.length - 3);
      final idx = int.tryParse(rawIdx) ?? -1;
      if (idx >= 0 && idx < state.playlist.medias.length) {
        return '${identityHashCode(state.playlist.medias[idx])}';
      }
      return '-1';
    }
    if (property == 'playlist') {
      return jsonEncode([
        for (final media in state.playlist.medias)
          {'id': identityHashCode(media), 'filename': media.uri},
      ]);
    }
    return properties[property] ?? '';
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    properties[property] = value;
  }

  @override
  Future<void> command(
    List<String> command, {
    bool waitForInitialization = true,
  }) async {}
}
