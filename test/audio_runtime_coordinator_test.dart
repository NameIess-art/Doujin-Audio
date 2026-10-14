import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/audio_runtime_coordinator.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  test(
    'shutdown keeps playback state alive for a pending native reconciliation',
    () async {
      final repository = _DelayedSnapshotRepository();
      final graph = createTestRuntimeGraph(
        nativePlaybackRepository: repository,
      );
      final coordinator = AudioRuntimeCoordinator(
        snapshots: repository.snapshots,
        progressUpdates: repository.progressUpdates,
        startListening: repository.startListening,
        stopListening: repository.stopListening,
        onSnapshot: (_) {},
        onProgress: (_) {},
        onStart: () => graph.playback.replaceNativeRetainedContentUris([]),
        onEnterBackground: () {},
        onResumeForeground: graph.playbackCommands.reconcileNativeRuntime,
        onDispose: graph.runtime.dispose,
      );
      await coordinator.start();
      final resume = coordinator.resumeForeground();
      await repository.started.future;
      final shutdown = coordinator.dispose();
      repository.reply.complete(
        NativeSuccess(
          NativePlaybackBundleSnapshot(
            sessions: [
              _snapshot('native-retained').copyWith(
                retainedUris: ['content://media/external/audio/media/42'],
              ),
            ],
          ),
        ),
      );
      await resume;
      await shutdown;
    },
  );
  for (final fail in [false, true]) {
    test(
      'startup shares its Future and shutdown drains it (failure: $fail)',
      () async {
        final pending = Completer<void>();
        var starts = 0;
        var disposals = 0;
        var transitions = 0;
        final coordinator = AudioRuntimeCoordinator(
          snapshots: const Stream<NativePlaybackSnapshot>.empty(),
          progressUpdates: const Stream<NativePlaybackProgressUpdate>.empty(),
          startListening: () {},
          stopListening: () async {},
          onSnapshot: (_) {},
          onProgress: (_) {},
          onStart: () {
            starts++;
            return pending.future;
          },
          onEnterBackground: () => transitions++,
          onResumeForeground: () => transitions++,
          onDispose: () => disposals++,
        );
        final start = coordinator.start();
        expect(coordinator.start(), same(start));
        final startupResult = fail
            ? expectLater(start, throwsStateError)
            : start;
        final shutdown = coordinator.dispose();
        expect(coordinator.dispose(), same(shutdown));
        await Future<void>.delayed(Duration.zero);
        expect(starts, 1);
        expect(disposals, 0);
        if (fail) {
          pending.completeError(StateError('restore failed'));
        } else {
          pending.complete();
        }
        await startupResult;
        await shutdown;
        await coordinator.enterBackground();
        await coordinator.resumeForeground();
        expect(disposals, 1);
        expect(transitions, 0);
      },
    );
  }

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

  test(
    'dispose drains started work and skips queued foreground work',
    () async {
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
      var disposed = false;
      final shutdown = coordinator.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      pending.complete();
      await Future.wait([first, foreground]);
      await shutdown;
      expect(disposed, isTrue);
      expect(resumes, 0);
    },
  );

  for (final fail in [false, true]) {
    test(
      'shutdown drains a native reply before closing state (failure: $fail)',
      () async {
        final reply = Completer<void>();
        final state = StreamController<void>();
        final events = <String>[];
        final coordinator = AudioRuntimeCoordinator(
          snapshots: const Stream<NativePlaybackSnapshot>.empty(),
          progressUpdates: const Stream<NativePlaybackProgressUpdate>.empty(),
          startListening: () {},
          stopListening: () async {},
          onSnapshot: (_) {},
          onProgress: (_) {},
          onStart: () {},
          onEnterBackground: () {},
          onResumeForeground: () async {
            await reply.future;
            state.add(null);
            events.add('reply');
            if (fail) throw StateError('native reply failed');
          },
          onDispose: () async {
            await state.close();
            events.add('dispose');
          },
        );
        // Consume the controller so its close Future can finish.
        final subscription = state.stream.listen((_) {});
        await coordinator.start();
        final resume = coordinator.resumeForeground();
        final result = fail ? expectLater(resume, throwsStateError) : resume;
        await Future<void>.delayed(Duration.zero);
        final shutdown = coordinator.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(state.isClosed, isFalse);
        reply.complete();
        await result;
        await shutdown;
        expect(events, ['reply', 'dispose']);
        await subscription.cancel();
      },
    );
  }
}

class _DelayedSnapshotRepository extends NativePlaybackRepository {
  final started = Completer<void>();
  final reply = Completer<NativeResult<NativePlaybackBundleSnapshot>>();

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() {
    started.complete();
    return reply.future;
  }

  @override
  Stream<NativePlaybackSnapshot> get snapshots => const Stream.empty();
  @override
  Stream<NativePlaybackProgressUpdate> get progressUpdates =>
      const Stream.empty();
  @override
  void startListening() {}
  @override
  Future<void> stopListening() async {}
  @override
  Future<void> dispose() async {}
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
