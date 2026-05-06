import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music_player/providers/audio_provider.dart';
import 'package:music_player/services/native_playback_bridge.dart';
import 'package:music_player/services/playback_notification_handler.dart';
import 'package:music_player/services/playback_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  late AudioProvider provider;
  late PlaybackNotificationHandler handler;
  late PlaybackNotificationService notificationService;

  setUp(() async {
    handler = PlaybackNotificationHandler();
    notificationService = PlaybackNotificationService(handler);
    provider = AudioProvider.test(notificationService: notificationService);
  });

  tearDown(() => provider.dispose);

  // ── multi-session playback stability ──────────────────────────

  group('multi-session playback stability', () {
    test('initial state has no active sessions', () {
      expect(provider.activeSessions, isEmpty);
    });

    test('toggling play-pause with unknown id does not throw', () {
      provider.toggleSessionPlayPause('non_existent_session');
      expect(provider.activeSessions, isEmpty);
    });

    test('sessionById returns null for unknown id', () {
      expect(provider.sessionById('nonexistent'), isNull);
    });

    test('trackByPath returns null for unknown path', () {
      expect(provider.trackByPath('/nonexistent/path.mp3'), isNull);
    });
  });

  // ── native snapshot isolation ──────────────────────────────────

  group('native bridge session isolation', () {
    test('native snapshot updates only its target session', () async {
      final first = PlaybackSession(
        id: 'native_1',
        currentTrackPath: '/audio/first.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1.0,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.idle),
      );
      final second = PlaybackSession(
        id: 'native_2',
        currentTrackPath: '/audio/second.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 0.5,
        createdAt: DateTime(2026, 1, 2),
        state: PlayerState(false, ProcessingState.idle),
      );
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      final secondStates = <PlayerState>[];
      second.stateStream.listen(secondStates.add);

      first.applyNativeSnapshot(
        const NativePlaybackSnapshot(
          sessionId: 'native_1',
          uri: 'file:///audio/first.mp3',
          playing: true,
          playWhenReady: true,
          processingState: 'ready',
          position: Duration(seconds: 5),
          bufferedPosition: Duration(seconds: 10),
          duration: Duration(minutes: 2),
          volume: 0.8,
          channelSwapEnabled: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(first.state.playing, isTrue);
      expect(first.volume, closeTo(0.8, 0.001));
      expect(second.state.playing, isFalse);
      expect(secondStates, isEmpty);
    });
  });

  // ── notification integration ───────────────────────────────────

  group('playback notification integration', () {
    test('notification state initializes with idle controls', () {
      final state = handler.playbackState.value;
      expect(state.playing, isFalse);
      expect(state.processingState, AudioProcessingState.idle);
    });

    test('notification snapshot populates queue and media item', () {
      handler.updateSnapshot(
        const PlaybackNotificationSnapshot(
          queue: <MediaItem>[MediaItem(id: 's1', title: 'One')],
          queueIndex: 0,
          mediaItem: MediaItem(id: 's1', title: 'One'),
          playing: false,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          speed: 1.0,
          hasPrevious: false,
          hasNext: false,
        ),
      );

      expect(handler.queue.value, hasLength(1));
      expect(handler.mediaItem.value!.id, 's1');
    });

    test('notification delete invokes callback', () async {
      var called = false;
      handler.bindCallbacks(
        onNotificationDeleted: () async {
          called = true;
        },
      );
      await handler.onNotificationDeleted();
      expect(called, isTrue);
    });

    test('clearing notification resets to empty idle state', () {
      handler.updateSnapshot(
        const PlaybackNotificationSnapshot(
          queue: <MediaItem>[MediaItem(id: 's1', title: 'One')],
          queueIndex: 0,
          mediaItem: MediaItem(id: 's1', title: 'One'),
          playing: true,
          processingState: AudioProcessingState.ready,
          updatePosition: Duration(seconds: 1),
          bufferedPosition: Duration(seconds: 2),
          speed: 1.0,
          hasPrevious: false,
          hasNext: false,
        ),
      );
      handler.updateSnapshot(null);

      expect(handler.queue.value, isEmpty);
      expect(handler.mediaItem.value, isNull);
      expect(
        handler.playbackState.value.controls.single.action,
        MediaAction.play,
      );
    });
  });

  // ── optimistic playback state dedup ───────────────────────────

  group('optimistic playback state dedup', () {
    test('setOptimisticState only emits when values differ', () async {
      final session = PlaybackSession(
        id: 'opt_1',
        currentTrackPath: '/audio/opt.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1.0,
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
      // Identical values should not produce a second emission.
      session.setOptimisticState(
        playing: true,
        processingState: ProcessingState.ready,
      );
      await Future<void>.delayed(Duration.zero);

      expect(states, hasLength(1));
      expect(session.state.playing, isTrue);
      expect(session.state.processingState, ProcessingState.ready);

      // A genuinely different processing state should emit.
      session.setOptimisticState(
        playing: true,
        processingState: ProcessingState.completed,
      );
      await Future<void>.delayed(Duration.zero);

      expect(states, hasLength(2));
      expect(session.state.processingState, ProcessingState.completed);
    });
  });
}
