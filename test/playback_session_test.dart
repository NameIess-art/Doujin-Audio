import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/services/native_playback_bridge.dart';

void main() {
  test(
    'native snapshots update only their matching playback session',
    () async {
      final first = PlaybackSession(
        id: 'session_1',
        currentTrackPath: '/audio/one.mp3',
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 0.7,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.idle),
      );
      final second = PlaybackSession(
        id: 'session_2',
        currentTrackPath: '/audio/two.mp3',
        loopMode: SessionLoopMode.folderRandom,
        nonSingleLoopMode: SessionLoopMode.folderRandom,
        volume: 0.5,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(false, ProcessingState.idle),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      final firstStates = <PlayerState>[];
      final secondStates = <PlayerState>[];
      first.stateStream.listen(firstStates.add);
      second.stateStream.listen(secondStates.add);

      first.applyNativeSnapshot(
        const NativePlaybackSnapshot(
          sessionId: 'session_1',
          uri: 'file:///audio/one.mp3',
          playing: true,
          playWhenReady: true,
          processingState: 'ready',
          position: Duration(seconds: 12),
          bufferedPosition: Duration(seconds: 20),
          duration: Duration(minutes: 3),
          volume: 0.42,
          speed: 1.5,
          boostGain: 1.0,
          channelSwapEnabled: false,
          queueIndex: 3,
          audioEffects: AudioEffectsState(
            skipSilenceEnabled: true,
            noiseReductionEnabled: true,
            eqEnabled: true,
            eqPresetId: 'voice_clear',
            eqBandLevels: <int, double>{1000: 2.0},
          ),
          eqCapabilities: EqCapabilities(
            supported: true,
            minGainDb: -10,
            maxGainDb: 10,
            bands: <EqBandInfo>[EqBandInfo(frequencyHz: 1000)],
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.state.playing, isTrue);
      expect(first.state.processingState, ProcessingState.ready);
      expect(first.position, const Duration(seconds: 12));
      expect(first.duration, const Duration(minutes: 3));
      expect(first.bufferedPosition, const Duration(seconds: 20));
      expect(first.volume, closeTo(0.42, 0.001));
      expect(first.speed, closeTo(1.5, 0.001));
      expect(first.audioEffects.skipSilenceEnabled, isTrue);
      expect(first.audioEffects.noiseReductionEnabled, isTrue);
      expect(first.audioEffects.eqBandLevels[1000], 2.0);
      expect(first.eqCapabilities.supported, isTrue);
      expect(first.eqCapabilities.bands.single.frequencyHz, 1000);
      expect(first.loadedPath, '/audio/one.mp3');
      expect(first.currentQueueIndex, 3);
      expect(firstStates, hasLength(1));

      expect(second.state.playing, isFalse);
      expect(second.position, Duration.zero);
      expect(secondStates, isEmpty);
    },
  );

  test('optimistic updates do not emit duplicate playback states', () async {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
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
    session.setOptimisticState(
      playing: true,
      processingState: ProcessingState.ready,
    );
    await Future<void>.delayed(Duration.zero);

    expect(states, hasLength(1));
    expect(session.state.playing, isTrue);
    expect(session.state.processingState, ProcessingState.ready);
  });

  test('native progress updates only numeric playback streams', () async {
    final session =
        PlaybackSession(
            id: 'session_1',
            currentTrackPath: '/audio/one.mp3',
            loopMode: SessionLoopMode.folderSequential,
            nonSingleLoopMode: SessionLoopMode.folderSequential,
            volume: 0.7,
            createdAt: DateTime(2026),
            state: PlayerState(true, ProcessingState.ready),
          )
          ..loadedPath = '/audio/one.mp3'
          ..audioEffects = const AudioEffectsState(skipSilenceEnabled: true)
          ..currentQueueIndex = 4;
    addTearDown(session.dispose);

    final positions = <Duration>[];
    final durations = <Duration?>[];
    final buffers = <Duration>[];
    final states = <PlayerState>[];
    session.positionStream.listen(positions.add);
    session.durationStream.listen(durations.add);
    session.bufferedPositionStream.listen(buffers.add);
    session.stateStream.listen(states.add);

    session.applyNativeProgress(
      const NativePlaybackProgressUpdate(
        sessionId: 'session_1',
        position: Duration(seconds: 9),
        bufferedPosition: Duration(seconds: 15),
        duration: Duration(minutes: 2),
        nativeElapsedRealtimeMs: 9000,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(positions, [const Duration(seconds: 9)]);
    expect(durations, [const Duration(minutes: 2)]);
    expect(buffers, [const Duration(seconds: 15)]);
    expect(states, isEmpty);
    expect(session.state.playing, isTrue);
    expect(session.currentTrackPath, '/audio/one.mp3');
    expect(session.loadedPath, '/audio/one.mp3');
    expect(session.currentQueueIndex, 4);
    expect(session.audioEffects.skipSilenceEnabled, isTrue);
  });

  test('full snapshot recalibrates position after progress heartbeat', () {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(true, ProcessingState.ready),
    );
    addTearDown(session.dispose);

    session.applyNativeProgress(
      const NativePlaybackProgressUpdate(
        sessionId: 'session_1',
        position: Duration(seconds: 10),
        bufferedPosition: Duration(seconds: 20),
        nativeElapsedRealtimeMs: 10000,
      ),
    );
    session.applyNativeSnapshot(
      const NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: false,
        playWhenReady: false,
        processingState: 'ready',
        position: Duration(seconds: 8),
        bufferedPosition: Duration(seconds: 18),
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
      ),
    );

    expect(session.position, const Duration(seconds: 8));
    expect(session.bufferedPosition, const Duration(seconds: 18));
    expect(session.state.playing, isFalse);
  });

  test('playback errors are stored and cleared by authoritative snapshots', () {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.idle),
    );
    addTearDown(session.dispose);

    session.applyNativeSnapshot(
      const NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: false,
        playWhenReady: false,
        processingState: 'idle',
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
        error: 'network failed',
      ),
    );
    expect(session.playbackError, 'network failed');

    session.applyNativeSnapshot(
      const NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: true,
        playWhenReady: true,
        processingState: 'ready',
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
      ),
    );
    expect(session.playbackError, isNull);
  });
}
