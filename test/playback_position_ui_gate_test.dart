import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/core/media/subtitle_parser.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:nameless_audio/features/player/presentation/playback_position_ui_gate.dart';

PlaybackSession _session(String id) {
  return PlaybackSession(
    id: id,
    currentTrackPath: '/audio/$id.mp3',
    loopMode: SessionLoopMode.folderSequential,
    nonSingleLoopMode: SessionLoopMode.folderSequential,
    volume: 1,
    createdAt: DateTime(2026),
    state: PlayerState(true, ProcessingState.ready),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'throttles frequent position notifications but keeps latest value',
    (tester) async {
      final session = _session('one');
      final coordinator = UiInteractionCoordinator();
      final gate = PlaybackPositionUiGate(
        session: session,
        interactionCoordinator: coordinator,
        minUpdateInterval: const Duration(hours: 1),
      );
      addTearDown(gate.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(session.dispose);

      var notifications = 0;
      gate.addListener(() => notifications++);

      session.setOptimisticPosition(const Duration(seconds: 1));
      await tester.pump();
      expect(notifications, 1);
      expect(gate.value.position, const Duration(seconds: 1));

      session.setOptimisticPosition(const Duration(seconds: 2));
      await tester.pump();
      expect(notifications, 1);
      expect(gate.value.position, const Duration(seconds: 2));
    },
  );

  testWidgets(
    'defers progress while interacting and flushes latest when idle',
    (tester) async {
      final session = _session('one');
      final coordinator = UiInteractionCoordinator();
      final source = Object();
      final gate = PlaybackPositionUiGate(
        session: session,
        interactionCoordinator: coordinator,
        minUpdateInterval: Duration.zero,
      );
      addTearDown(gate.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(session.dispose);

      var notifications = 0;
      gate.addListener(() => notifications++);

      coordinator.beginInteraction(source);
      session.applyNativeProgress(
        const NativePlaybackProgressUpdate(
          sessionId: 'one',
          position: Duration(seconds: 5),
          bufferedPosition: Duration(seconds: 7),
          duration: Duration(minutes: 1),
          nativeElapsedRealtimeMs: 5000,
        ),
      );
      await tester.pump();

      expect(notifications, 0);
      expect(gate.value.position, const Duration(seconds: 5));
      expect(gate.value.bufferedPosition, const Duration(seconds: 7));
      expect(gate.value.duration, const Duration(minutes: 1));

      coordinator.cancelInteraction(source);
      await tester.pump();
      expect(notifications, 1);
    },
  );

  testWidgets(
    'ticker disabled coalesces updates and flushes latest on resume',
    (tester) async {
      final session = _session('one');
      final gate = PlaybackPositionUiGate(
        session: session,
        minUpdateInterval: Duration.zero,
      );
      addTearDown(gate.dispose);
      addTearDown(session.dispose);

      var notifications = 0;
      gate.addListener(() => notifications++);

      gate.tickerModeEnabled = false;
      session.setOptimisticPosition(const Duration(seconds: 1));
      session.applyNativeProgress(
        const NativePlaybackProgressUpdate(
          sessionId: 'one',
          position: Duration(seconds: 2),
          bufferedPosition: Duration(seconds: 8),
          duration: Duration(minutes: 1),
          nativeElapsedRealtimeMs: 2000,
        ),
      );
      session.applyNativeProgress(
        const NativePlaybackProgressUpdate(
          sessionId: 'one',
          position: Duration(seconds: 3),
          bufferedPosition: Duration(seconds: 12),
          duration: Duration(minutes: 2),
          nativeElapsedRealtimeMs: 3000,
        ),
      );
      await tester.pump();

      expect(notifications, 0);
      expect(gate.value.position, const Duration(seconds: 3));
      expect(gate.value.bufferedPosition, const Duration(seconds: 12));
      expect(gate.value.duration, const Duration(minutes: 2));

      gate.tickerModeEnabled = true;
      await tester.pump();

      expect(notifications, 1);
      expect(gate.value.position, const Duration(seconds: 3));
    },
  );

  testWidgets(
    'can ignore buffered position updates for lightweight listeners',
    (tester) async {
      final session = _session('one');
      final gate = PlaybackPositionUiGate(
        session: session,
        minUpdateInterval: Duration.zero,
        includeBufferedPosition: false,
      );
      addTearDown(gate.dispose);
      addTearDown(session.dispose);

      var notifications = 0;
      gate.addListener(() => notifications++);

      session.applyNativeProgress(
        const NativePlaybackProgressUpdate(
          sessionId: 'one',
          position: Duration.zero,
          bufferedPosition: Duration(seconds: 8),
          nativeElapsedRealtimeMs: 2000,
        ),
      );
      await tester.pump();

      expect(notifications, 0);
      expect(gate.value.bufferedPosition, Duration.zero);

      session.applyNativeProgress(
        const NativePlaybackProgressUpdate(
          sessionId: 'one',
          position: Duration(seconds: 1),
          bufferedPosition: Duration(seconds: 8),
          nativeElapsedRealtimeMs: 3000,
        ),
      );
      await tester.pump();

      expect(notifications, 1);
      expect(gate.value.position, const Duration(seconds: 1));
      expect(gate.value.bufferedPosition, Duration.zero);
    },
  );

  test('subtitle cache only changes text when the active cue changes', () {
    final track = SubtitleTrack(
      sourcePath: '/audio/one.srt',
      cues: <SubtitleCue>[
        const SubtitleCue(
          start: Duration.zero,
          end: Duration(seconds: 5),
          text: 'first',
        ),
        const SubtitleCue(
          start: Duration(seconds: 5),
          end: Duration(seconds: 9),
          text: 'second',
        ),
      ],
    );
    final cache = SubtitleTextCache();

    expect(
      cache.resolve(
        trackPath: '/audio/one.mp3',
        position: const Duration(seconds: 1),
        track: track,
      ),
      'first',
    );
    expect(
      cache.resolve(
        trackPath: '/audio/one.mp3',
        position: const Duration(seconds: 4),
        track: track,
      ),
      'first',
    );
    expect(
      cache.resolve(
        trackPath: '/audio/one.mp3',
        position: const Duration(seconds: 5),
        track: track,
      ),
      'second',
    );
    expect(
      cache.resolve(
        trackPath: '/audio/one.mp3',
        position: const Duration(seconds: 10),
        track: track,
      ),
      isNull,
    );
  });
}
