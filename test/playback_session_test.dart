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
          boostGain: 1.0,
          channelSwapEnabled: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.state.playing, isTrue);
      expect(first.state.processingState, ProcessingState.ready);
      expect(first.position, const Duration(seconds: 12));
      expect(first.duration, const Duration(minutes: 3));
      expect(first.bufferedPosition, const Duration(seconds: 20));
      expect(first.volume, closeTo(0.42, 0.001));
      expect(first.loadedPath, '/audio/one.mp3');
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
}
