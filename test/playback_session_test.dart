import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';

void main() {
  PlaybackSession createSession() => PlaybackSession(
    id: 'state-transitions',
    currentTrackPath: '/audio/one.mp3',
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.folderSequential,
    volume: 1,
    createdAt: DateTime(2026),
    state: const PlayerState(false, ProcessingState.idle),
  );

  test(
    'preparation generations preserve flags and reject stale completion',
    () async {
      final session = createSession();
      addTearDown(session.shutdown);
      final states = <PlayerState>[];
      session.stateStream.listen(states.add);
      final first = session.beginPreparation(showLoading: true, autoPlay: true);
      expect(first.changed, isTrue);
      final second = session.beginPreparation(
        showLoading: false,
        autoPlay: false,
      );
      expect(second.generation, first.generation + 1);
      expect(second.changed, isFalse);
      expect(session.isLoading, isTrue);
      expect(session.isPlaybackStarting, isTrue);
      session.markNativePreparation(second.generation, '/new.mp3');
      for (final prepared in [true, false]) {
        expect(
          session.finishPreparation(
            first.generation,
            prepared: prepared,
            autoPlay: true,
            error: 'old failure',
          ),
          isFalse,
        );
      }
      expect(
        session.markNativePreparation(first.generation, '/old.mp3'),
        isFalse,
      );
      expect(session.cancelPlaybackStart(first.generation), isFalse);
      expect(session.pendingNativeTrackPath, '/new.mp3');
      expect(session.isLoading, isTrue);
      expect(session.isPlaybackStarting, isTrue);
      expect(session.playbackError, isNull);
      expect(
        session.finishPreparation(
          second.generation,
          prepared: false,
          autoPlay: true,
          error: 'current failure',
        ),
        isTrue,
      );
      expect(session.pendingNativeTrackPath, isNull);
      expect(session.isLoading, isFalse);
      expect(session.isPlaybackStarting, isFalse);
      expect(session.playbackError, 'current failure');
      expect(
        session.finishPreparation(
          second.generation,
          prepared: false,
          autoPlay: true,
          error: 'current failure',
        ),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(states, isEmpty);
    },
  );

  test(
    'successful preparation keeps autoplay until transport confirmation',
    () {
      final session = createSession();
      addTearDown(session.shutdown);
      final preparation = session.beginPreparation(
        showLoading: true,
        autoPlay: true,
      );
      session.finishPreparation(
        preparation.generation,
        prepared: true,
        autoPlay: true,
      );
      expect(session.isLoading, isFalse);
      expect(session.playbackRequested, isTrue);
      session.beginTransportCommand(commandId: 1, playing: false);
      expect(session.playbackRequested, isFalse);
      expect(session.loadGeneration, preparation.generation);
    },
  );

  test('completion cleanup requires both generations and advances once', () {
    final session = createSession();
    addTearDown(session.shutdown);
    expect(
      session.beginCompletionAdvance(commandGeneration: 0, markHandled: true),
      isTrue,
    );
    expect(
      session.finishCompletionAdvance(
        commandGeneration: 0,
        preparationGeneration: 0,
      ),
      isTrue,
    );
    expect(
      session.beginCompletionAdvance(commandGeneration: 0, markHandled: true),
      isFalse,
    );
    final preparation = session.beginPreparation(
      showLoading: true,
      autoPlay: true,
    );
    expect(
      session.finishCompletionAdvance(
        commandGeneration: 0,
        preparationGeneration: 0,
        error: 'old completion',
      ),
      isFalse,
    );
    session.beginTransportCommand(commandId: 2, playing: false);
    expect(
      session.finishCompletionAdvance(
        commandGeneration: 0,
        preparationGeneration: preparation.generation,
        error: 'old command',
      ),
      isFalse,
    );
    expect(session.isLoading, isTrue);
    expect(session.playbackError, isNull);
  });

  test(
    'shutdown invalidates preparation and refuses later state transitions',
    () async {
      final session = createSession();
      final preparation = session.beginPreparation(
        showLoading: true,
        autoPlay: true,
      );
      session.markNativePreparation(preparation.generation, '/new.mp3');
      await session.shutdown();
      final generation = session.loadGeneration;
      expect(session.isPreparationCurrent(preparation.generation), isFalse);
      expect(session.pendingNativeTrackPath, isNull);
      expect(session.isLoading, isFalse);
      expect(
        session.beginPreparation(showLoading: true, autoPlay: true).changed,
        isFalse,
      );
      expect(session.loadGeneration, generation);
      expect(session.markNativePreparation(generation, '/late.mp3'), isFalse);
      expect(
        session.finishPreparation(
          generation,
          prepared: false,
          autoPlay: true,
          error: 'late failure',
        ),
        isFalse,
      );
      expect(
        session.beginTransportCommand(commandId: 3, playing: true),
        isFalse,
      );
      expect(session.failTransportCommand(0), isFalse);
      expect(session.beginCompletionAdvance(commandGeneration: 0), isFalse);
      expect(
        session.finishCompletionAdvance(
          commandGeneration: 0,
          preparationGeneration: generation,
          error: 'late completion',
        ),
        isFalse,
      );
      expect(session.reconcilePlaybackState(), isFalse);
      expect(session.confirmPaused(), isFalse);
      expect(session.playbackError, isNull);
    },
  );

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
        state: const PlayerState(false, ProcessingState.idle),
      );
      final second = PlaybackSession(
        id: 'session_2',
        currentTrackPath: '/audio/two.mp3',
        loopMode: SessionLoopMode.folderRandom,
        nonSingleLoopMode: SessionLoopMode.folderRandom,
        volume: 0.5,
        createdAt: DateTime(2026, 1, 2),
        state: const PlayerState(false, ProcessingState.idle),
      );
      addTearDown(first.shutdown);
      addTearDown(second.shutdown);

      final firstStates = <PlayerState>[];
      final secondStates = <PlayerState>[];
      first.stateStream.listen(firstStates.add);
      second.stateStream.listen(secondStates.add);

      first.applyNativeSnapshot(
        NativePlaybackSnapshot(
          sessionId: 'session_1',
          uri: 'file:///audio/one.mp3',
          playing: true,
          playWhenReady: true,
          processingState: 'ready',
          position: const Duration(seconds: 12),
          bufferedPosition: const Duration(seconds: 20),
          duration: const Duration(minutes: 3),
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
            bands: <EqBandInfo>[const EqBandInfo(frequencyHz: 1000)],
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
      state: const PlayerState(false, ProcessingState.idle),
    );
    addTearDown(session.shutdown);

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

  test('loading threshold delays transient playback state', () async {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(true, ProcessingState.ready),
    );
    addTearDown(session.shutdown);

    session.beginLoadingIndicatorThreshold(
      threshold: const Duration(milliseconds: 20),
    );
    session.beginPreparation(showLoading: false, autoPlay: true);
    session.setOptimisticState(processingState: ProcessingState.buffering);

    expect(session.isPlaybackLoading, isFalse);

    await session.stateStream.first;

    expect(session.isPlaybackLoading, isTrue);
  });

  test('transport changes include loading threshold visibility', () {
    final session = createSession();
    addTearDown(session.shutdown);
    session.beginTransportCommand(
      commandId: 1,
      playing: true,
      threshold: Duration.zero,
    );
    expect(session.isPlaybackLoading, isTrue);
    expect(session.beginTransportCommand(commandId: 1, playing: true), isTrue);
    expect(session.isPlaybackLoading, isFalse);
    expect(
      session.beginTransportCommand(
        commandId: 1,
        playing: true,
        threshold: Duration.zero,
      ),
      isTrue,
    );
    expect(session.isPlaybackLoading, isTrue);
  });

  test('transport intent is immediate and stale snapshots are ignored', () {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.shutdown);

    session.beginTransportCommand(commandId: 2, playing: true);
    expect(session.effectivePlaying, isTrue);
    expect(session.state.playing, isFalse);

    final staleApplied = session.applyNativeSnapshot(
      NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: false,
        playWhenReady: false,
        processingState: 'ready',
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
        transportCommandId: 1,
      ),
    );
    expect(staleApplied, isFalse);
    expect(session.effectivePlaying, isTrue);

    session.applyNativeSnapshot(
      NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: false,
        playWhenReady: true,
        processingState: 'buffering',
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
        transportCommandId: 2,
      ),
    );
    expect(session.effectivePlaying, isTrue);

    session.applyNativeSnapshot(
      NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: true,
        playWhenReady: true,
        processingState: 'ready',
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
        transportCommandId: 2,
      ),
    );
    expect(session.pendingPlayingIntent, isNull);
    expect(session.effectivePlaying, isTrue);
  });

  test('only the current failed transport command rolls back intent', () {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(true, ProcessingState.ready),
    );
    addTearDown(session.shutdown);

    session.beginTransportCommand(commandId: 3, playing: false);
    session.beginTransportCommand(commandId: 4, playing: true);

    expect(session.failTransportCommand(3), isFalse);
    expect(session.effectivePlaying, isTrue);
    expect(session.failTransportCommand(4), isTrue);
    expect(session.effectivePlaying, isTrue);
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
            state: const PlayerState(true, ProcessingState.ready),
          )
          ..loadedPath = '/audio/one.mp3'
          ..audioEffects = AudioEffectsState(skipSilenceEnabled: true)
          ..currentQueueIndex = 4;
    addTearDown(session.shutdown);

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

  test('partial native snapshots keep existing console audio settings', () {
    final session =
        PlaybackSession(
            id: 'session_1',
            currentTrackPath: '/audio/one.mp3',
            loopMode: SessionLoopMode.folderSequential,
            nonSingleLoopMode: SessionLoopMode.folderSequential,
            volume: 0.7,
            createdAt: DateTime(2026),
            state: const PlayerState(true, ProcessingState.ready),
          )
          ..channelSwapEnabled = true
          ..audioEffects = AudioEffectsState(
            skipSilenceEnabled: true,
            noiseReductionEnabled: true,
            volumeNormalizationEnabled: true,
            eqEnabled: true,
            eqPresetId: 'voice_clear',
            eqBandLevels: <int, double>{1000: 2.5},
            panning: -0.4,
          );
    addTearDown(session.shutdown);

    final snapshot = NativePlaybackSnapshot.fromMap(<String, Object?>{
      'sessionId': 'session_1',
      'uri': 'file:///audio/one.mp3',
      'playing': true,
      'playWhenReady': true,
      'processingState': 'ready',
      'positionMs': 12000,
      'bufferedPositionMs': 18000,
      'volume': 0.8,
      'speed': 1.5,
      'boostGain': 1.0,
    });
    expect(snapshot.hasAudioEffectsPayload, isFalse);
    expect(snapshot.hasChannelSwapPayload, isFalse);

    session.applyNativeSnapshot(snapshot);

    expect(session.volume, closeTo(0.8, 0.001));
    expect(session.speed, closeTo(1.5, 0.001));
    expect(session.channelSwapEnabled, isTrue);
    expect(session.audioEffects.skipSilenceEnabled, isTrue);
    expect(session.audioEffects.noiseReductionEnabled, isTrue);
    expect(session.audioEffects.volumeNormalizationEnabled, isTrue);
    expect(session.audioEffects.eqEnabled, isTrue);
    expect(session.audioEffects.eqPresetId, 'voice_clear');
    expect(session.audioEffects.eqBandLevels[1000], 2.5);
    expect(session.audioEffects.panning, closeTo(-0.4, 0.001));
  });

  test('full snapshot recalibrates position after progress heartbeat', () {
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(true, ProcessingState.ready),
    );
    addTearDown(session.shutdown);

    session.applyNativeProgress(
      const NativePlaybackProgressUpdate(
        sessionId: 'session_1',
        position: Duration(seconds: 10),
        bufferedPosition: Duration(seconds: 20),
        nativeElapsedRealtimeMs: 10000,
      ),
    );
    session.applyNativeSnapshot(
      NativePlaybackSnapshot(
        sessionId: 'session_1',
        playing: false,
        playWhenReady: false,
        processingState: 'ready',
        position: const Duration(seconds: 8),
        bufferedPosition: const Duration(seconds: 18),
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
      state: const PlayerState(false, ProcessingState.idle),
    );
    addTearDown(session.shutdown);

    session.applyNativeSnapshot(
      NativePlaybackSnapshot(
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
      NativePlaybackSnapshot(
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

  test('shutdown awaits subscriptions and closes every stream once', () async {
    final cancellationStarted = Completer<void>();
    final allowCancellation = Completer<void>();
    final source = StreamController<void>(
      onCancel: () async {
        cancellationStarted.complete();
        await allowCancellation.future;
      },
    );
    final session = PlaybackSession(
      id: 'session_1',
      currentTrackPath: '/audio/one.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.idle),
    );
    session.subscriptions.add(source.stream.listen((_) {}));

    final streamsDone = Future.wait<void>(<Future<void>>[
      session.stateStream.drain<void>(),
      session.positionStream.drain<void>(),
      session.durationStream.drain<void>(),
      session.bufferedPositionStream.drain<void>(),
    ]);
    final firstShutdown = session.shutdown();
    final secondShutdown = session.shutdown();

    expect(identical(firstShutdown, secondShutdown), isTrue);
    expect(session.isDisposed, isTrue);
    await cancellationStarted.future;
    var completed = false;
    unawaited(firstShutdown.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    allowCancellation.complete();
    await firstShutdown;
    await streamsDone;
    expect(session.subscriptions, isEmpty);
    await source.close();
  });

  test(
    'shutdown closes every stream when subscription cancellation fails',
    () async {
      final source = StreamController<void>(
        onCancel: () => Future<void>.error(StateError('cancel failed')),
      );
      final session = PlaybackSession(
        id: 'session_1',
        currentTrackPath: '/audio/one.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.idle),
      );
      session.subscriptions.add(source.stream.listen((_) {}));
      final streamsDone = Future.wait<void>(<Future<void>>[
        session.stateStream.drain<void>(),
        session.positionStream.drain<void>(),
        session.durationStream.drain<void>(),
        session.bufferedPositionStream.drain<void>(),
      ]);

      await expectLater(session.shutdown(), throwsStateError);
      await streamsDone;
      expect(session.subscriptions, isEmpty);
      await source.close();
    },
  );

  test(
    'immutable snapshots detect runtime changes without a revision',
    () async {
      final session = PlaybackSession(
        id: 'session_1',
        currentTrackPath: '/audio/one.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: const PlayerState(false, ProcessingState.idle),
      );
      addTearDown(session.shutdown);
      final before = PlaybackSessionSnapshot.fromRuntime(session);

      session
        ..volume = 0.5
        ..setOptimisticState(
          playing: true,
          processingState: ProcessingState.ready,
        );
      final after = PlaybackSessionSnapshot.fromRuntime(session);

      expect(after, isNot(before));
      expect(before.volume, 1);
      expect(before.state.playing, isFalse);
      expect(after.volume, 0.5);
      expect(after.state.playing, isTrue);
      expect(after.state.processing, PlaybackProcessingStatus.ready);
    },
  );
}
