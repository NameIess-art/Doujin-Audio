import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/audio_runtime_coordinator.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';

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

    expect(listeningStarts, 1);
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
}

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
