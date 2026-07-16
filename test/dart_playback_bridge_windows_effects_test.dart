import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:nameless_audio/features/player/domain/audio_effects.dart';
import 'package:nameless_audio/features/player/application/dart_playback_bridge.dart';

void main() {
  test('Windows dart playback exposes fixed EQ capabilities', () {
    expect(dartPlaybackWindowsEqCapabilities.supported, isTrue);
    expect(dartPlaybackWindowsEqCapabilities.minGainDb, -12);
    expect(dartPlaybackWindowsEqCapabilities.maxGainDb, 12);
    expect(
      dartPlaybackWindowsEqCapabilities.bands.map((band) => band.frequencyHz),
      <int>[31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
    );
  });

  test('Windows dart playback builds filters for enabled effects', () {
    final filters = buildDartPlaybackAudioFiltersForTest(
      const NativeAudioEffects(
        state: AudioEffectsState(
          skipSilenceEnabled: true,
          noiseReductionEnabled: true,
          volumeNormalizationEnabled: true,
          eqEnabled: true,
          eqBandLevels: <int, double>{1000: 20, 123: 4},
          panning: -1.0,
        ),
        channelSwapEnabled: true,
      ),
    );

    expect(
      filters.any((filter) => filter.contains('@na_skip_silence')),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('silenceremove') &&
            filter.contains('stop_duration=0.25') &&
            filter.contains('stop_threshold=-60dB') &&
            filter.contains('detection=peak') &&
            filter.contains('timestamp=copy'),
      ),
      isTrue,
    );
    expect(
      filters.any((filter) => filter.contains('afftdn=nr=6:nf=-55')),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('dynaudnorm=f=500:g=5:p=0.6:m=3') &&
            filter.contains('alimiter=limit=0.95'),
      ),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('@na_panning') &&
            filter.contains('c0=1*c0') &&
            filter.contains('c1=0*c1'),
      ),
      isTrue,
    );
    expect(
      filters.any(
        (filter) =>
            filter.contains('@na_eq') &&
            filter.contains('f=1000') &&
            filter.contains('g=12') &&
            !filter.contains('f=123'),
      ),
      isTrue,
    );
    expect(
      filters.any((filter) => filter.contains('@na_channel_swap')),
      isTrue,
    );
    expect(filters.map((filter) => filter.split(':').first), <String>[
      '@na_skip_silence',
      '@na_noise_reduction',
      '@na_volume_norm',
      '@na_eq',
      '@na_panning',
      '@na_channel_swap',
    ]);
  });

  test('Windows dart playback omits neutral panning and flat EQ filters', () {
    final filters = buildDartPlaybackAudioFiltersForTest(
      const NativeAudioEffects(
        state: AudioEffectsState(eqEnabled: true),
        channelSwapEnabled: false,
      ),
    );

    expect(filters, isEmpty);
  });

  test(
    'Windows detects a silent MPV filter rejection and restores filters',
    () async {
      final platformPlayer = _FakePlatformPlayer();
      final activeFilters = <String, String>{};
      var rejectNoiseReduction = false;
      final bridge = DartPlaybackBridge(
        playerFactory: () => media.Player(platformPlayer: platformPlayer),
        mpvCommandRunner: (_, command) async {
          final operation = command[1];
          final value = command[2];
          if (operation == 'remove') {
            activeFilters.remove(value);
          } else if (operation == 'add') {
            final label = value.split(':').first;
            if (!(rejectNoiseReduction && label == '@na_noise_reduction')) {
              activeFilters[label] = value;
            }
          }
        },
        mpvFilterStateReader: (_) async => activeFilters.values.join(','),
      );
      addTearDown(bridge.dispose);
      await bridge.prepareSession(
        sessionId: 'session-1',
        uri: Uri.file('C:\\audio\\effects.mp3'),
        title: 'effects',
      );
      final initial = await bridge.setAudioEffects(
        'session-1',
        const NativeAudioEffects(
          state: AudioEffectsState(skipSilenceEnabled: true),
          channelSwapEnabled: false,
        ),
      );
      expect(initial.isOk, isTrue);
      rejectNoiseReduction = true;

      final rejected = await bridge.setAudioEffects(
        'session-1',
        const NativeAudioEffects(
          state: AudioEffectsState(noiseReductionEnabled: true),
          channelSwapEnabled: false,
        ),
      );

      expect(rejected.isFailure, isTrue);
      expect(activeFilters.keys, contains('@na_skip_silence'));
      expect(activeFilters.keys, isNot(contains('@na_noise_reduction')));
      final snapshot = await bridge.snapshot();
      expect(
        snapshot.valueOrNull!.sessions.single.audioEffects.skipSilenceEnabled,
        isTrue,
      );
      expect(
        snapshot
            .valueOrNull!
            .sessions
            .single
            .audioEffects
            .noiseReductionEnabled,
        isFalse,
      );
    },
  );

  test(
    'Windows prepare resets a playing session without issuing a late pause',
    () async {
      final platformPlayer = _FakePlatformPlayer();
      final bridge = DartPlaybackBridge(
        playerFactory: () => media.Player(platformPlayer: platformPlayer),
      );
      addTearDown(bridge.dispose);

      final first = await bridge.prepareSession(
        sessionId: 'session-1',
        uri: Uri.file('C:\\audio\\one.mp3'),
        title: 'one',
        autoPlay: true,
      );
      expect(first.valueOrNull?.playing, isTrue);
      expect(first.valueOrNull?.playWhenReady, isTrue);
      expect(platformPlayer.playCalls, 1);

      final second = await bridge.prepareSession(
        sessionId: 'session-1',
        uri: Uri.file('C:\\audio\\two.mp3'),
        title: 'two',
      );

      expect(second.valueOrNull?.playing, isFalse);
      expect(second.valueOrNull?.playWhenReady, isFalse);
      expect(second.valueOrNull?.duration, const Duration(minutes: 2));
      expect(platformPlayer.pauseCalls, 0);
      expect(platformPlayer.playCalls, 1);
      expect(platformPlayer.openPlayValues, <bool>[false, false]);
    },
  );

  test('Windows snapshots expose asynchronous media open failures', () async {
    final platformPlayer = _FakePlatformPlayer(failOpen: true);
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    final result = await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://example.com/broken.mp3'),
      title: 'broken',
    );

    expect(result.isFailure, isTrue);
    final snapshot = await bridge.snapshot();
    expect(snapshot.valueOrNull?.sessions.single.error, 'Failed to open media');
    expect(snapshot.valueOrNull?.sessions.single.processingState, 'idle');
  });

  test('Windows prepare does not wait for remote duration metadata', () async {
    final platformPlayer = _FakePlatformPlayer(withDurationOnOpen: false);
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);
    final stopwatch = Stopwatch()..start();

    final result = await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://example.com/slow-metadata.m4a'),
      title: 'slow metadata',
    );

    stopwatch.stop();
    expect(result.isOk, isTrue);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test(
    'Windows keeps restored position until native seek catches up',
    () async {
      final platformPlayer = _FakePlatformPlayer(updatePositionOnSeek: false);
      final bridge = DartPlaybackBridge(
        playerFactory: () => media.Player(platformPlayer: platformPlayer),
      );
      addTearDown(bridge.dispose);

      final result = await bridge.prepareSession(
        sessionId: 'session-1',
        uri: Uri.parse('https://example.com/track.m4a'),
        title: 'track',
        startPosition: const Duration(seconds: 42),
      );
      final snapshot = await bridge.snapshot();

      expect(result.valueOrNull?.position, const Duration(seconds: 42));
      expect(
        snapshot.valueOrNull?.sessions.single.position,
        const Duration(seconds: 42),
      );

      platformPlayer.emitPosition(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final afterLateZero = await bridge.snapshot();
      expect(
        afterLateZero.valueOrNull?.sessions.single.position,
        const Duration(seconds: 42),
      );
    },
  );

  test('Windows automatically retries after a load failure', () async {
    final platformPlayer = _FakePlatformPlayer(remainingOpenFailures: 1);
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    final result = await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://example.com/retry.m4a'),
      title: 'retry',
    );

    expect(result.isOk, isTrue);
    expect(platformPlayer.openedUris, hasLength(2));
    expect(result.valueOrNull?.error, isNull);
  });

  test(
    'Windows automatically retries a late asynchronous load failure',
    () async {
      final platformPlayer = _FakePlatformPlayer(
        delayedOpenFailure: const Duration(milliseconds: 200),
      );
      final bridge = DartPlaybackBridge(
        playerFactory: () => media.Player(platformPlayer: platformPlayer),
      );
      addTearDown(bridge.dispose);

      final result = await bridge.prepareSession(
        sessionId: 'session-1',
        uri: Uri.parse('https://example.com/low.m4a'),
        title: 'late retry',
        candidateUris: <Uri>[
          Uri.parse('https://example.com/low.m4a'),
          Uri.parse('https://example.com/high.m4a'),
        ],
        autoPlay: true,
      );
      expect(result.isOk, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      final snapshot = await bridge.snapshot();
      expect(platformPlayer.openedUris, <String>[
        'https://example.com/low.m4a',
        'https://example.com/high.m4a',
      ]);
      expect(platformPlayer.playCalls, 2);
      expect(snapshot.valueOrNull?.sessions.single.error, isNull);
      expect(snapshot.valueOrNull?.sessions.single.playing, isTrue);

      platformPlayer.emitError('Second late load failure');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final retriedSnapshot = await bridge.snapshot();
      expect(platformPlayer.openedUris, <String>[
        'https://example.com/low.m4a',
        'https://example.com/high.m4a',
        'https://example.com/low.m4a',
      ]);
      expect(platformPlayer.playCalls, 3);
      expect(retriedSnapshot.valueOrNull?.sessions.single.error, isNull);
      expect(retriedSnapshot.valueOrNull?.sessions.single.playing, isTrue);
    },
  );

  test('Windows tolerates a slow confirmed playback start', () async {
    final platformPlayer = _FakePlatformPlayer(
      playbackStartDelay: const Duration(milliseconds: 1200),
    );
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    final result = await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://example.com/slow-start.m4a'),
      title: 'slow start',
      autoPlay: true,
    );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull?.playing, isTrue);
    expect(platformPlayer.playCalls, 1);
  });

  test('Windows opens only the selected item in media_kit', () async {
    final platformPlayer = _FakePlatformPlayer();
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.file('C:\\audio\\two.mp3'),
      title: 'two',
      queue: <Map<String, Object?>>[
        <String, Object?>{
          'uri': Uri.file('C:\\audio\\one.mp3').toString(),
          'path': 'C:\\audio\\one.mp3',
          'title': 'one',
        },
        <String, Object?>{
          'uri': Uri.file('C:\\audio\\two.mp3').toString(),
          'path': 'C:\\audio\\two.mp3',
          'title': 'two',
        },
      ],
      queueStartIndex: 1,
    );

    expect(platformPlayer.openedPlaylists.single.medias, hasLength(1));
    expect(platformPlayer.openedPlaylists.single.index, 0);
    final snapshot = await bridge.snapshot();
    expect(snapshot.valueOrNull?.sessions.single.queueIndex, 1);
    expect(
      platformPlayer.openedPlaylists.single.medias.last.uri,
      contains('two.mp3'),
    );
  });

  test('Windows falls back through remote candidates for one track', () async {
    final platformPlayer = _FakePlatformPlayer(
      failingUris: <String>{'https://slow.example.com/track.m4a'},
    );
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    final result = await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://slow.example.com/track.m4a'),
      path: 'https://slow.example.com/track.m4a',
      title: 'track',
      candidateUris: <Uri>[
        Uri.parse('https://slow.example.com/track.m4a'),
        Uri.parse('https://fast.example.com/track.m4a'),
      ],
    );

    expect(result.isOk, isTrue);
    expect(platformPlayer.openedUris, <String>[
      'https://slow.example.com/track.m4a',
      'https://fast.example.com/track.m4a',
    ]);
    expect(result.valueOrNull?.path, 'https://slow.example.com/track.m4a');
    expect(result.valueOrNull?.error, isNull);
  });

  test('Windows falls back when playback fails after opening', () async {
    final platformPlayer = _FakePlatformPlayer(
      failingPlayUris: <String>{'https://slow.example.com/track.m4a'},
    );
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    final result = await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://slow.example.com/track.m4a'),
      title: 'track',
      autoPlay: true,
      candidateUris: <Uri>[
        Uri.parse('https://slow.example.com/track.m4a'),
        Uri.parse('https://fast.example.com/track.m4a'),
      ],
    );

    expect(result.isOk, isTrue);
    expect(platformPlayer.openedUris, <String>[
      'https://slow.example.com/track.m4a',
      'https://fast.example.com/track.m4a',
    ]);
    expect(platformPlayer.playCalls, 2);
    expect(result.valueOrNull?.playing, isTrue);
  });

  test('Windows gives errors priority over delayed completion', () async {
    final platformPlayer = _FakePlatformPlayer();
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);

    await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://example.com/track.m4a'),
      title: 'track',
      autoPlay: true,
    );
    platformPlayer.emitCompletion();
    platformPlayer.emitError('network failed');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final snapshot = await bridge.snapshot();
    expect(snapshot.valueOrNull?.sessions.single.error, 'network failed');
    expect(snapshot.valueOrNull?.sessions.single.processingState, 'idle');
  });

  test('Windows passes remote media URLs directly to media_kit', () async {
    final platformPlayer = _FakePlatformPlayer();
    final bridge = DartPlaybackBridge(
      playerFactory: () => media.Player(platformPlayer: platformPlayer),
    );
    addTearDown(bridge.dispose);
    await bridge.prepareSession(
      sessionId: 'session-1',
      uri: Uri.parse('https://fast.example.com/media/track.m4a'),
      title: 'track',
    );

    expect(
      platformPlayer.openedPlaylists.single.medias.single.uri,
      'https://fast.example.com/media/track.m4a',
    );
  });

  test('Windows resolves HTTP redirects to their final signed URI', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/api/media/stream/track') {
        await request.response.redirect(
          Uri.parse('/signed/audio.wav?verify=token'),
        );
      } else {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      }
    });
    final source = Uri.parse(
      'http://${server.address.host}:${server.port}/api/media/stream/track',
    );

    final resolved = await resolveDartPlaybackRedirectForTest(source);

    expect(resolved, source.resolve('/signed/audio.wav?verify=token'));
  });

  test(
    'Windows resolves ASMR media API URLs before opening media_kit',
    () async {
      final platformPlayer = _FakePlatformPlayer();
      final resolvedInputs = <Uri>[];
      final bridge = DartPlaybackBridge(
        playerFactory: () => media.Player(platformPlayer: platformPlayer),
        uriResolver: (uri) async {
          resolvedInputs.add(uri);
          return Uri.parse(
            'https://raw.kiko-play-niptan.one/audio.wav?verify=signed',
          );
        },
      );
      addTearDown(bridge.dispose);
      final source = Uri.parse(
        'https://api.asmr.one/api/media/stream/1605918/1875222',
      );

      final result = await bridge.prepareSession(
        sessionId: 'session-1',
        uri: source,
        title: 'track',
      );

      expect(result.isOk, isTrue);
      expect(resolvedInputs, <Uri>[source]);
      expect(platformPlayer.openedUris, <String>[
        'https://raw.kiko-play-niptan.one/audio.wav?verify=signed',
      ]);
    },
  );
}

class _FakePlatformPlayer extends media.PlatformPlayer {
  _FakePlatformPlayer({
    this.failOpen = false,
    this.failingUris = const <String>{},
    this.failingPlayUris = const <String>{},
    this.withDurationOnOpen = true,
    this.updatePositionOnSeek = true,
    this.playbackStartDelay = Duration.zero,
    this.remainingOpenFailures = 0,
    this.delayedOpenFailure,
  }) : super(configuration: const media.PlayerConfiguration());

  final bool failOpen;
  final Set<String> failingUris;
  final Set<String> failingPlayUris;
  final bool withDurationOnOpen;
  final bool updatePositionOnSeek;
  final Duration playbackStartDelay;
  int remainingOpenFailures;
  Duration? delayedOpenFailure;
  int playCalls = 0;
  int pauseCalls = 0;
  final List<bool> openPlayValues = <bool>[];
  final List<media.Playlist> openedPlaylists = <media.Playlist>[];
  final List<String> openedUris = <String>[];

  void emitCompletion() => completedController.add(true);

  void emitError(String message) => errorController.add(message);

  void emitPosition(Duration position) => positionController.add(position);

  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    openPlayValues.add(play);
    final playlist = playable is media.Playlist
        ? playable
        : media.Playlist(<media.Media>[playable as media.Media]);
    openedPlaylists.add(playlist);
    openedUris.add(playlist.medias.single.uri);
    state = state.copyWith(
      playlist: playlist,
      playing: play,
      completed: false,
      position: Duration.zero,
      duration: withDurationOnOpen ? const Duration(minutes: 2) : Duration.zero,
      buffer: const Duration(seconds: 30),
      buffering: false,
    );
    if (failOpen ||
        remainingOpenFailures-- > 0 ||
        failingUris.contains(playlist.medias.single.uri)) {
      state = state.copyWith(duration: Duration.zero);
      Future<void>.delayed(const Duration(milliseconds: 10), () {
        errorController.add('Failed to open media');
      });
    } else if (delayedOpenFailure != null) {
      final delay = delayedOpenFailure!;
      delayedOpenFailure = null;
      Future<void>.delayed(delay, () {
        errorController.add('Late load failure');
      });
    }
  }

  @override
  Future<void> play() async {
    playCalls++;
    if (openedUris.isNotEmpty && failingPlayUris.contains(openedUris.last)) {
      throw StateError('Failed to start playback');
    }
    if (playbackStartDelay > Duration.zero) {
      Future<void>.delayed(playbackStartDelay, () {
        state = state.copyWith(playing: true, completed: false);
        playingController.add(true);
      });
      return;
    }
    state = state.copyWith(playing: true, completed: false);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> stop() async {
    state = const media.PlayerState();
  }

  @override
  Future<void> seek(Duration duration) async {
    if (updatePositionOnSeek) {
      state = state.copyWith(position: duration);
      positionController.add(duration);
    }
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
  Future<void> setPlaylistMode(media.PlaylistMode playlistMode) async {
    state = state.copyWith(playlistMode: playlistMode);
  }

  @override
  Future<void> setShuffle(bool shuffle) async {
    state = state.copyWith(shuffle: shuffle);
  }
}
