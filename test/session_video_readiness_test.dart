import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_video_widgets.dart';
import 'package:flutter/foundation.dart';
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
}

PlaybackSessionSnapshot _session(String currentPath, String? loadedPath) {
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
    state: const PlaybackStatus(
      playing: true,
      processing: PlaybackProcessingStatus.ready,
    ),
    effectivePlaying: true,
    playbackRequested: true,
    isLoading: false,
    isPlaybackLoading: false,
    playbackError: null,
    currentQueueIndex: 0,
    playbackQueue: null,
    customQueueTracks: null,
    positionStream: const Stream<Duration>.empty(),
    durationStream: const Stream<Duration?>.empty(),
    bufferedPositionStream: const Stream<Duration>.empty(),
  );
}
