import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import 'playback_session.dart';

enum PlaybackProcessingStatus { idle, loading, buffering, ready, completed }

@immutable
class PlaybackStatus {
  const PlaybackStatus({required this.playing, required this.processing});

  final bool playing;
  final PlaybackProcessingStatus processing;

  @override
  bool operator ==(Object other) =>
      other is PlaybackStatus &&
      other.playing == playing &&
      other.processing == processing;

  @override
  int get hashCode => Object.hash(playing, processing);
}

/// Immutable, SDK-independent view of a mutable playback runtime.
@immutable
class PlaybackSessionSnapshot {
  PlaybackSessionSnapshot({
    required this.id,
    required this.createdAt,
    required this.lastPlayedAt,
    required this.currentTrackPath,
    required this.loadedPath,
    required this.loopMode,
    required this.nonSingleLoopMode,
    required this.volume,
    required this.channelSwapEnabled,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.speed,
    required this.audioEffects,
    required this.eqCapabilities,
    required this.state,
    required this.effectivePlaying,
    required this.playbackRequested,
    required this.isLoading,
    required this.isPlaybackLoading,
    required this.playbackError,
    required this.currentQueueIndex,
    required this.playbackQueue,
    required List<MusicTrack>? customQueueTracks,
    required this.positionStream,
    required this.durationStream,
    required this.bufferedPositionStream,
  }) : customQueueTracks = customQueueTracks == null
           ? null
           : immutableList(customQueueTracks);

  factory PlaybackSessionSnapshot.fromRuntime(PlaybackSession session) {
    return PlaybackSessionSnapshot(
      id: session.id,
      createdAt: session.createdAt,
      lastPlayedAt: session.lastPlayedAt,
      currentTrackPath: session.currentTrackPath,
      loadedPath: session.loadedPath,
      loopMode: session.loopMode,
      nonSingleLoopMode: session.nonSingleLoopMode,
      volume: session.volume,
      channelSwapEnabled: session.channelSwapEnabled,
      position: session.position,
      duration: session.duration,
      bufferedPosition: session.bufferedPosition,
      speed: session.speed,
      audioEffects: session.audioEffects,
      eqCapabilities: session.eqCapabilities,
      state: PlaybackStatus(
        playing: session.state.playing,
        processing: PlaybackProcessingStatus.values.byName(
          session.state.processingState.name,
        ),
      ),
      effectivePlaying: session.effectivePlaying,
      playbackRequested: session.playbackRequested,
      isLoading: session.isLoading,
      isPlaybackLoading: session.isPlaybackLoading,
      playbackError: session.playbackError,
      currentQueueIndex: session.currentQueueIndex,
      playbackQueue: session.playbackQueue,
      customQueueTracks: session.customQueueTracks,
      positionStream: session.positionStream,
      durationStream: session.durationStream,
      bufferedPositionStream: session.bufferedPositionStream,
    );
  }

  final String id;
  final DateTime createdAt;
  final DateTime? lastPlayedAt;
  final String currentTrackPath;
  final String? loadedPath;
  final SessionLoopMode loopMode;
  final SessionLoopMode nonSingleLoopMode;
  final double volume;
  final bool channelSwapEnabled;
  final Duration position;
  final Duration? duration;
  final Duration bufferedPosition;
  final double speed;
  final AudioEffectsState audioEffects;
  final EqCapabilities eqCapabilities;
  final PlaybackStatus state;
  final bool effectivePlaying;
  final bool playbackRequested;
  final bool isLoading;
  final bool isPlaybackLoading;
  final String? playbackError;
  final int currentQueueIndex;
  final PlaybackQueueDefinition? playbackQueue;
  final List<MusicTrack>? customQueueTracks;
  final Stream<Duration> positionStream;
  final Stream<Duration?> durationStream;
  final Stream<Duration> bufferedPositionStream;

  bool get isPlaybackQueue => playbackQueue != null;

  @override
  bool operator ==(Object other) {
    return other is PlaybackSessionSnapshot &&
        other.id == id &&
        other.createdAt == createdAt &&
        other.lastPlayedAt == lastPlayedAt &&
        other.currentTrackPath == currentTrackPath &&
        other.loadedPath == loadedPath &&
        other.loopMode == loopMode &&
        other.nonSingleLoopMode == nonSingleLoopMode &&
        other.volume == volume &&
        other.channelSwapEnabled == channelSwapEnabled &&
        other.position == position &&
        other.duration == duration &&
        other.bufferedPosition == bufferedPosition &&
        other.speed == speed &&
        other.audioEffects == audioEffects &&
        other.eqCapabilities == eqCapabilities &&
        other.state == state &&
        other.effectivePlaying == effectivePlaying &&
        other.playbackRequested == playbackRequested &&
        other.isLoading == isLoading &&
        other.isPlaybackLoading == isPlaybackLoading &&
        other.playbackError == playbackError &&
        other.currentQueueIndex == currentQueueIndex &&
        other.playbackQueue == playbackQueue &&
        listEquals(other.customQueueTracks, customQueueTracks);
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    createdAt,
    lastPlayedAt,
    currentTrackPath,
    loadedPath,
    loopMode,
    nonSingleLoopMode,
    volume,
    channelSwapEnabled,
    position,
    duration,
    bufferedPosition,
    speed,
    audioEffects,
    eqCapabilities,
    state,
    effectivePlaying,
    playbackRequested,
    isLoading,
    isPlaybackLoading,
    playbackError,
    currentQueueIndex,
    playbackQueue,
    Object.hashAll(customQueueTracks ?? const <MusicTrack>[]),
  ]);
}
