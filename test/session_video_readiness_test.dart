import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_video_widgets.dart';
import 'package:doujin_audio/features/player/presentation/session_video_surface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    group(platform.name, () {
      late MusicTrack track;

      setUp(() {
        debugDefaultTargetPlatformOverride = platform;
        track = MusicTrack(
          path: platform == TargetPlatform.windows
              ? r'C:\媒体文件\Video Clip.mp4'
              : '/storage/emulated/0/媒体文件/Video Clip.mp4',
          displayName: 'Video Clip',
          groupKey: 'videos',
          groupTitle: 'Videos',
          groupSubtitle: '',
          isSingle: true,
          isVideo: true,
        );
      });

      test('loaded video can create its session surface', () {
        expect(
          isSessionVideoReady(_session(track.path, track.path), track),
          isTrue,
        );
      });

      test('pending load does not show a stale surface', () {
        expect(isSessionVideoReady(_session(track.path, null), track), isFalse);
      });

      test('paused loaded video keeps its native surface', () {
        expect(
          isSessionVideoReady(
            _session(track.path, track.path, playing: false),
            track,
          ),
          isTrue,
        );
      });

      test('previous loaded track is not shown during a track switch', () {
        expect(
          isSessionVideoReady(_session(track.path, '${track.path}.old'), track),
          isFalse,
        );
      });

      test('audio tracks and missing tracks do not create a video surface', () {
        final session = _session(track.path, track.path);
        expect(
          isSessionVideoReady(session, track.copyWith(isVideo: false)),
          isFalse,
        );
        expect(isSessionVideoReady(session, null), isFalse);
      });

      if (platform == TargetPlatform.windows) {
        test('drive casing and separators preserve the loaded video match', () {
          expect(
            isSessionVideoReady(
              _session(track.path, 'c:/媒体文件/video clip.mp4'),
              track,
            ),
            isTrue,
          );
        });
      }
    });
  }

  group('Android fixed-aspect video surface sizing', () {
    test('keeps identical logical size across portrait and landscape displays', () {
      final portrait = resolveAndroidVideoSurfaceLogicalSize(
        videoSize: (width: 1920, height: 1080),
        displayPhysicalSize: const Size(1080, 2310),
        devicePixelRatio: 3.0,
      );
      final landscape = resolveAndroidVideoSurfaceLogicalSize(
        videoSize: (width: 1920, height: 1080),
        displayPhysicalSize: const Size(2310, 1080),
        devicePixelRatio: 3.0,
      );
      expect(portrait, const Size(640, 360));
      expect(landscape, portrait);
    });

    test('caps 4K video to display bounds and preserves vertical video aspect', () {
      final uhd = resolveAndroidVideoSurfaceLogicalSize(
        videoSize: (width: 3840, height: 2160),
        displayPhysicalSize: const Size(1080, 2310),
        devicePixelRatio: 3.0,
      );
      final vertical = resolveAndroidVideoSurfaceLogicalSize(
        videoSize: (width: 1080, height: 1920),
        displayPhysicalSize: const Size(1080, 2310),
        devicePixelRatio: 3.0,
      );
      expect(uhd, const Size(640, 360));
      expect(vertical, const Size(360, 640));
    });

    test('parses videoWidth and videoHeight from native playback snapshots', () {
      final snapshot = NativePlaybackSnapshot.fromMap(const <String, Object?>{
        'sessionId': 's1',
        'playing': true,
        'playWhenReady': true,
        'processingState': 'ready',
        'positionMs': 1000,
        'bufferedPositionMs': 2000,
        'volume': 1.0,
        'boostGain': 1.0,
        'channelSwap': false,
        'videoWidth': 1920,
        'videoHeight': 1080,
      });
      expect(snapshot.videoWidth, 1920);
      expect(snapshot.videoHeight, 1080);
    });
  });
}

PlaybackSessionSnapshot _session(
  String currentPath,
  String? loadedPath, {
  bool playing = true,
}) {
  return PlaybackSessionSnapshot(
    id: 'video-session',
    createdAt: DateTime(2026),
    lastPlayedAt: null,
    currentTrackPath: currentPath,
    loadedPath: loadedPath,
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.crossSequential,
    volume: 1,
    channelSwapEnabled: false,
    position: Duration.zero,
    duration: const Duration(minutes: 1),
    bufferedPosition: Duration.zero,
    speed: 1,
    audioEffects: AudioEffectsState.flat,
    eqCapabilities: EqCapabilities.unsupported,
    state: PlaybackStatus(
      playing: playing,
      processing: PlaybackProcessingStatus.ready,
    ),
    effectivePlaying: playing,
    playbackRequested: playing,
    isLoading: false,
    isPlaybackLoading: false,
    playbackError: null,
    currentQueueIndex: 0,
    playbackQueue: null,
    customQueueTracks: null,
    positionStream: const Stream<Duration>.empty(),
    durationStream: const Stream<Duration?>.empty(),
    progressStream: const Stream.empty(),
  );
}
