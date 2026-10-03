import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/audio_runtime_coordinator.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';

void main() {
  test('owns runtime subscriptions and lifecycle exactly once', () async {
    final snapshots = StreamController<NativePlaybackSnapshot>.broadcast(
      sync: true,
    );
    final progressUpdates =
        StreamController<NativePlaybackProgressUpdate>.broadcast(sync: true);
    addTearDown(snapshots.close);
    addTearDown(progressUpdates.close);

    var listeningStarts = 0;
    var listeningStops = 0;
    var starts = 0;
    var backgroundEntries = 0;
    var foregroundResumes = 0;
    var disposals = 0;
    final receivedSnapshots = <String>[];
    final receivedProgress = <Duration>[];

    final coordinator = AudioRuntimeCoordinator(
      snapshots: snapshots.stream,
      progressUpdates: progressUpdates.stream,
      startListening: () => listeningStarts++,
      stopListening: () async => listeningStops++,
      onSnapshot: (snapshot) => receivedSnapshots.add(snapshot.sessionId),
      onProgress: (progress) => receivedProgress.add(progress.position),
      onStart: () => starts++,
      onEnterBackground: () => backgroundEntries++,
      onResumeForeground: () => foregroundResumes++,
      onDispose: () => disposals++,
    );

    await coordinator.start();
    await coordinator.start();
    snapshots.add(_snapshot('session'));
    progressUpdates.add(
      const NativePlaybackProgressUpdate(
        sessionId: 'session',
        position: Duration(seconds: 3),
        bufferedPosition: Duration(seconds: 5),
        nativeElapsedRealtimeMs: 100,
      ),
    );
    await coordinator.enterBackground();
    await coordinator.resumeForeground();

    expect(listeningStarts, 2);
    expect(starts, 1);
    expect(receivedSnapshots, <String>['session']);
    expect(receivedProgress, <Duration>[const Duration(seconds: 3)]);
    expect(backgroundEntries, 1);
    expect(foregroundResumes, 1);

    await coordinator.dispose();
    await coordinator.dispose();
    snapshots.add(_snapshot('ignored'));
    progressUpdates.add(
      const NativePlaybackProgressUpdate(
        sessionId: 'ignored',
        position: Duration(seconds: 8),
        bufferedPosition: Duration(seconds: 8),
        nativeElapsedRealtimeMs: 200,
      ),
    );
    await coordinator.enterBackground();
    await coordinator.resumeForeground();

    expect(listeningStops, 1);
    expect(disposals, 1);
    expect(receivedSnapshots, <String>['session']);
    expect(receivedProgress, <Duration>[const Duration(seconds: 3)]);
    expect(backgroundEntries, 1);
    expect(foregroundResumes, 1);
  });

  test('failed startup can retry without duplicate subscriptions', () async {
    final snapshots = StreamController<NativePlaybackSnapshot>.broadcast(
      sync: true,
    );
    final progressUpdates =
        StreamController<NativePlaybackProgressUpdate>.broadcast(sync: true);
    addTearDown(snapshots.close);
    addTearDown(progressUpdates.close);
    var listeningStarts = 0;
    var listeningStops = 0;
    var attempts = 0;
    var backgroundEntries = 0;
    final coordinator = AudioRuntimeCoordinator(
      snapshots: snapshots.stream,
      progressUpdates: progressUpdates.stream,
      startListening: () => listeningStarts++,
      stopListening: () async => listeningStops++,
      onSnapshot: (_) {},
      onProgress: (_) {},
      onStart: () async {
        attempts++;
        if (attempts == 1) throw StateError('persistence unavailable');
      },
      onEnterBackground: () => backgroundEntries++,
      onResumeForeground: () {},
      onDispose: () {},
    );

    await expectLater(coordinator.start(), throwsStateError);
    await coordinator.enterBackground();
    await coordinator.start();
    await coordinator.enterBackground();

    expect(attempts, 2);
    expect(listeningStarts, 1);
    expect(backgroundEntries, 1);
    await coordinator.dispose();
    expect(listeningStops, 1);
  });

  for (final background in [true, false]) {
    final transition = background ? 'background' : 'foreground';
    test(
      'coalesces concurrent $transition requests and allows later calls',
      () async {
        final pending = Completer<void>();
        var transitions = 0;
        Future<void> action() async {
          transitions++;
          if (transitions == 1) await pending.future;
        }

        final coordinator = _lifecycleCoordinator(
          onEnterBackground: background ? action : () {},
          onResumeForeground: background ? () {} : action,
        );
        addTearDown(coordinator.dispose);
        await coordinator.start();
        final transitionAction = background
            ? coordinator.enterBackground
            : coordinator.resumeForeground;
        final first = transitionAction();
        final second = transitionAction();
        expect(second, same(first));
        await Future<void>.delayed(Duration.zero);
        expect(transitions, 1);
        pending.complete();
        await Future.wait([first, second]);
        await transitionAction();
        expect(transitions, 2);
      },
    );

    test('failed $transition request can retry', () async {
      final pending = Completer<void>();
      var transitions = 0;
      Future<void> action() async {
        transitions++;
        if (transitions == 1) await pending.future;
      }

      final coordinator = _lifecycleCoordinator(
        onEnterBackground: background ? action : () {},
        onResumeForeground: background ? () {} : action,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      final transitionAction = background
          ? coordinator.enterBackground
          : coordinator.resumeForeground;
      final first = transitionAction();
      expect(transitionAction(), same(first));
      final failure = expectLater(first, throwsStateError);
      pending.completeError(StateError('native runtime unavailable'));
      await failure;
      await transitionAction();
      expect(transitions, 2);
    });
  }

  test(
    'serializes opposite transitions without discarding later background',
    () async {
      final pending = Completer<void>();
      final events = <String>[];
      final coordinator = _lifecycleCoordinator(
        onEnterBackground: () async {
          events.add('background');
          if (events.length == 1) await pending.future;
        },
        onResumeForeground: () => events.add('foreground'),
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      final first = coordinator.enterBackground();
      final foreground = coordinator.resumeForeground();
      final last = coordinator.enterBackground();
      expect(last, isNot(same(first)));
      expect(coordinator.enterBackground(), same(last));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['background']);
      pending.complete();
      await Future.wait([first, foreground, last]);
      expect(events, ['background', 'foreground', 'background']);
    },
  );

  test('queued foreground still runs after background fails', () async {
    final pending = Completer<void>();
    var resumes = 0;
    final coordinator = _lifecycleCoordinator(
      onEnterBackground: () => pending.future,
      onResumeForeground: () => resumes++,
    );
    addTearDown(coordinator.dispose);
    await coordinator.start();
    final first = coordinator.enterBackground();
    final foreground = coordinator.resumeForeground();
    final failure = expectLater(first, throwsStateError);
    pending.completeError(StateError('persistence unavailable'));
    await failure;
    await foreground;
    expect(resumes, 1);
  });

  test('dispose skips queued foreground work', () async {
    final pending = Completer<void>();
    var resumes = 0;
    final coordinator = _lifecycleCoordinator(
      onEnterBackground: () => pending.future,
      onResumeForeground: () => resumes++,
    );
    await coordinator.start();
    final first = coordinator.enterBackground();
    await Future<void>.delayed(Duration.zero);
    final foreground = coordinator.resumeForeground();
    await coordinator.dispose();
    pending.complete();
    await Future.wait([first, foreground]);
    expect(resumes, 0);
  });
}

AudioRuntimeCoordinator _lifecycleCoordinator({
  required AudioRuntimeAction onEnterBackground,
  required AudioRuntimeAction onResumeForeground,
}) => AudioRuntimeCoordinator(
  snapshots: const Stream<NativePlaybackSnapshot>.empty(),
  progressUpdates: const Stream<NativePlaybackProgressUpdate>.empty(),
  startListening: () {},
  stopListening: () async {},
  onSnapshot: (_) {},
  onProgress: (_) {},
  onStart: () {},
  onEnterBackground: onEnterBackground,
  onResumeForeground: onResumeForeground,
  onDispose: () {},
);

NativePlaybackSnapshot _snapshot(String sessionId) {
  return NativePlaybackSnapshot(
    sessionId: sessionId,
    playing: false,
    playWhenReady: false,
    processingState: 'ready',
    position: Duration.zero,
    bufferedPosition: Duration.zero,
    volume: 1,
    boostGain: 1,
    channelSwapEnabled: false,
  );
}
