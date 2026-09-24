import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../application/playback_session_snapshot.dart';
import '../application/audio_state_services.dart';
import '../../../core/media/music_track.dart';

@immutable
class PlaylistHeaderState {
  const PlaylistHeaderState({
    required this.sessionCount,
    required this.playingCount,
    required this.timerDuration,
    required this.timerRemaining,
    required this.timerActive,
    this.autoResumeAt,
  });

  final int sessionCount;
  final int playingCount;
  final Duration? timerDuration;
  final Duration? timerRemaining;
  final bool timerActive;

  /// When the timer has expired and auto-resume is scheduled, this holds the
  /// wall-clock time at which playback will resume. Null otherwise.
  final DateTime? autoResumeAt;

  bool get hasTimer => timerDuration != null || autoResumeAt != null;

  @override
  bool operator ==(Object other) {
    return other is PlaylistHeaderState &&
        other.sessionCount == sessionCount &&
        other.playingCount == playingCount &&
        other.timerDuration == timerDuration &&
        other.timerRemaining == timerRemaining &&
        other.timerActive == timerActive &&
        other.autoResumeAt == autoResumeAt;
  }

  @override
  int get hashCode => Object.hash(
    sessionCount,
    playingCount,
    timerDuration,
    timerRemaining,
    timerActive,
    autoResumeAt,
  );
}

@immutable
class PlaylistStructureEntry {
  const PlaylistStructureEntry({
    required this.session,
    required this.sessionId,
    required this.trackPath,
    required this.isPlaybackQueue,
    required this.queueColorValue,
    required this.queueContentSignature,
  });

  final PlaybackSessionSnapshot session;
  final String sessionId;
  final String trackPath;
  final bool isPlaybackQueue;
  final int? queueColorValue;
  final int? queueContentSignature;

  @override
  bool operator ==(Object other) {
    return other is PlaylistStructureEntry &&
        other.sessionId == sessionId &&
        other.trackPath == trackPath &&
        other.isPlaybackQueue == isPlaybackQueue &&
        other.session.isTemporary == session.isTemporary &&
        other.session.lastPlayedAt == session.lastPlayedAt &&
        other.queueColorValue == queueColorValue &&
        other.queueContentSignature == queueContentSignature;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    trackPath,
    isPlaybackQueue,
    session.isTemporary,
    session.lastPlayedAt,
    queueColorValue,
    queueContentSignature,
  );
}

@immutable
class PlaylistStructureState {
  const PlaylistStructureState({
    required this.entries,
    required this.coverGeneration,
    required this.isInitialized,
  });

  final List<PlaylistStructureEntry> entries;
  final int coverGeneration;
  final bool isInitialized;

  bool get hasSessions => entries.isNotEmpty;

  @override
  bool operator ==(Object other) {
    return other is PlaylistStructureState &&
        listEquals(other.entries, entries) &&
        other.coverGeneration == coverGeneration &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(entries), coverGeneration, isInitialized);
}

@immutable
class MainOverlayUiState {
  const MainOverlayUiState({
    required this.overlaySessions,
    required this.playingSessionCount,
    required this.activeSessionCount,
    required this.isInitialized,
    required this.startupReady,
  });

  final List<PlaybackSessionSnapshot> overlaySessions;
  final int playingSessionCount;
  final int activeSessionCount;
  final bool isInitialized;
  final bool startupReady;

  bool get hasPlayingSession => playingSessionCount > 0;
  bool get hasNowPlaying => overlaySessions.isNotEmpty;

  @override
  bool operator ==(Object other) {
    return other is MainOverlayUiState &&
        listEquals(other.overlaySessions, overlaySessions) &&
        other.playingSessionCount == playingSessionCount &&
        other.activeSessionCount == activeSessionCount &&
        other.isInitialized == isInitialized &&
        other.startupReady == startupReady;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(overlaySessions),
    playingSessionCount,
    activeSessionCount,
    isInitialized,
    startupReady,
  );
}

/// Keeps progress-only playback updates from replacing the overlay list.
final class PlaybackSessionOverlayList
    extends ListBase<PlaybackSessionSnapshot> {
  PlaybackSessionOverlayList(Iterable<PlaybackSessionSnapshot> sessions)
    : _items = List<PlaybackSessionSnapshot>.unmodifiable(sessions);

  final List<PlaybackSessionSnapshot> _items;

  @override
  int get length => _items.length;

  @override
  set length(int value) => throw UnsupportedError('read-only');

  @override
  PlaybackSessionSnapshot operator [](int index) => _items[index];

  @override
  void operator []=(int index, PlaybackSessionSnapshot value) {
    throw UnsupportedError('read-only');
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PlaybackSessionOverlayList || other.length != length) {
      return false;
    }
    for (var index = 0; index < length; index++) {
      final left = this[index];
      final right = other[index];
      if (left.id != right.id ||
          left.currentTrackPath != right.currentTrackPath ||
          left.playbackRequested != right.playbackRequested ||
          left.isLoading != right.isLoading ||
          left.isPlaybackLoading != right.isPlaybackLoading ||
          left.playbackError != right.playbackError ||
          left.currentQueueIndex != right.currentQueueIndex ||
          left.queueVersion != right.queueVersion ||
          left.playbackQueue != right.playbackQueue ||
          !listEquals(left.customQueueTracks, right.customQueueTracks)) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(
    _items.map(
      (session) => Object.hash(
        session.id,
        session.currentTrackPath,
        session.playbackRequested,
        session.isLoading,
        session.isPlaybackLoading,
        session.playbackError,
        session.currentQueueIndex,
        session.queueVersion,
        session.playbackQueue,
        Object.hashAll(session.customQueueTracks ?? const <MusicTrack>[]),
      ),
    ),
  );
}

@immutable
class SessionOrderState {
  const SessionOrderState({required this.sessionIds});

  final List<String> sessionIds;

  @override
  bool operator ==(Object other) {
    return other is SessionOrderState &&
        listEquals(other.sessionIds, sessionIds);
  }

  @override
  int get hashCode => Object.hashAll(sessionIds);
}

@immutable
class SessionDetailViewState {
  const SessionDetailViewState({
    required this.sessionId,
    required this.trackPath,
    required this.loopMode,
    required this.isPlaying,
    required this.isLoading,
    required this.isPlaybackLoading,
    required this.channelSwapEnabled,
    required this.volume,
    required this.speed,
    required this.audioEffects,
    required this.eqCapabilities,
    required this.playbackError,
  });

  final String sessionId;
  final String trackPath;
  final SessionLoopMode loopMode;
  final bool isPlaying;
  final bool isLoading;
  final bool isPlaybackLoading;
  final bool channelSwapEnabled;
  final double volume;
  final double speed;
  final AudioEffectsState audioEffects;
  final EqCapabilities eqCapabilities;
  final String? playbackError;

  bool get showPauseIcon => isPlaying;

  @override
  bool operator ==(Object other) {
    return other is SessionDetailViewState &&
        other.sessionId == sessionId &&
        other.trackPath == trackPath &&
        other.loopMode == loopMode &&
        other.isPlaying == isPlaying &&
        other.isLoading == isLoading &&
        other.isPlaybackLoading == isPlaybackLoading &&
        other.channelSwapEnabled == channelSwapEnabled &&
        other.volume == volume &&
        other.speed == speed &&
        other.audioEffects == audioEffects &&
        other.eqCapabilities == eqCapabilities &&
        other.playbackError == playbackError;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    trackPath,
    loopMode,
    isPlaying,
    isLoading,
    isPlaybackLoading,
    channelSwapEnabled,
    volume,
    speed,
    audioEffects,
    eqCapabilities,
    playbackError,
  );
}

@immutable
class SessionDetailUiState {
  const SessionDetailUiState({
    required this.sessionOrder,
    required this.detail,
    required this.coverGeneration,
  });

  final SessionOrderState sessionOrder;
  final SessionDetailViewState? detail;
  final int coverGeneration;

  @override
  bool operator ==(Object other) {
    return other is SessionDetailUiState &&
        other.sessionOrder == sessionOrder &&
        other.detail == detail &&
        other.coverGeneration == coverGeneration;
  }

  @override
  int get hashCode => Object.hash(sessionOrder, detail, coverGeneration);
}

@immutable
class PlaylistSessionCardState {
  const PlaylistSessionCardState({
    required this.sessionId,
    required this.trackPath,
    required this.loopMode,
    required this.isPlaying,
    required this.isLoading,
    required this.channelSwapEnabled,
    required this.audioEffects,
    required this.speed,
    required this.playbackError,
    required this.queueColorValue,
  });

  final String sessionId;
  final String trackPath;
  final SessionLoopMode loopMode;
  final bool isPlaying;
  final bool isLoading;
  final bool channelSwapEnabled;
  final AudioEffectsState audioEffects;
  final double speed;
  final String? playbackError;
  final int? queueColorValue;

  @override
  bool operator ==(Object other) {
    return other is PlaylistSessionCardState &&
        other.sessionId == sessionId &&
        other.trackPath == trackPath &&
        other.loopMode == loopMode &&
        other.isPlaying == isPlaying &&
        other.isLoading == isLoading &&
        other.channelSwapEnabled == channelSwapEnabled &&
        other.audioEffects == audioEffects &&
        other.speed == speed &&
        other.playbackError == playbackError &&
        other.queueColorValue == queueColorValue;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    trackPath,
    loopMode,
    isPlaying,
    isLoading,
    channelSwapEnabled,
    audioEffects,
    speed,
    playbackError,
    queueColorValue,
  );
}

@immutable
class ActiveTrackPaths {
  const ActiveTrackPaths(this.paths);

  final Set<String> paths;

  bool contains(String path) => paths.contains(path);

  @override
  bool operator ==(Object other) {
    return other is ActiveTrackPaths && setEquals(other.paths, paths);
  }

  @override
  int get hashCode => Object.hashAllUnordered(paths);
}

String buildSessionCoverPrecacheKey({
  required String sessionId,
  required String trackPath,
  required int? cacheWidth,
  required int? cacheHeight,
  required int coverGeneration,
}) {
  final widthKey = cacheWidth?.toString() ?? 'native';
  final heightKey = cacheHeight?.toString() ?? 'native';
  return '$sessionId|$trackPath|$widthKey|$heightKey|$coverGeneration';
}

double playlistListCacheExtent({
  required double headerHeight,
  required double viewportWidth,
  required bool isLandscape,
}) {
  if (!isLandscape && viewportWidth < 760) return 320;
  return (headerHeight + 800).clamp(headerHeight + 4, 1600.0).toDouble();
}

PlaylistHeaderState playlistHeaderStateFromSlices(
  PlaybackStateSliceData playbackState,
  TimerStateSliceData timerState,
) {
  return PlaylistHeaderState(
    sessionCount: playbackState.activeSessions.length,
    playingCount: playbackState.playingSessionCount,
    timerDuration: timerState.duration,
    timerRemaining: timerState.remaining,
    timerActive: timerState.active,
    autoResumeAt: timerState.autoResumeAt,
  );
}

List<PlaybackSessionSnapshot> overlaySessionsFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  return PlaybackSessionOverlayList(
    playbackState.activeSessions
      .where(
        (session) =>
            session.currentTrackPath.isNotEmpty &&
            (session.isTemporary ||
                session.retainInNowPlaying ||
                (session.playbackRequested &&
                    (session.isLoading ||
                        session.isPlaybackLoading ||
                        session.state.processing ==
                            PlaybackProcessingStatus.loading ||
                        session.state.processing ==
                            PlaybackProcessingStatus.buffering ||
                        session.state.processing ==
                            PlaybackProcessingStatus.ready))),
      )
      .toList(growable: false),
  );
}

SessionOrderState sessionOrderStateFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  return SessionOrderState(
    sessionIds: playbackState.activeSessions
        .map((session) => session.id)
        .toList(growable: false),
  );
}

SessionDetailViewState? sessionDetailViewStateFromPlaybackState(
  PlaybackStateSliceData playbackState,
  String sessionId,
) {
  for (final session in playbackState.activeSessions) {
    if (session.id != sessionId) continue;
    return SessionDetailViewState(
      sessionId: session.id,
      trackPath: session.currentTrackPath,
      loopMode: session.loopMode,
      isPlaying: session.playbackRequested,
      isLoading: session.isLoading,
      isPlaybackLoading: session.isPlaybackLoading && session.playbackRequested,
      channelSwapEnabled: session.channelSwapEnabled,
      volume: session.volume,
      speed: session.speed,
      audioEffects: session.audioEffects,
      eqCapabilities: session.eqCapabilities,
      playbackError: session.playbackError,
    );
  }
  return null;
}

Map<String, PlaylistSessionCardState>
playlistSessionCardStatesFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  return Map<String, PlaylistSessionCardState>.unmodifiable({
    for (final session in playbackState.activeSessions)
      session.id: playlistSessionCardStateFromSession(session),
  });
}

PlaylistSessionCardState playlistSessionCardStateFromSession(
  PlaybackSessionSnapshot session,
) {
  return PlaylistSessionCardState(
    sessionId: session.id,
    trackPath: session.currentTrackPath,
    loopMode: session.loopMode,
    isPlaying: session.playbackRequested,
    isLoading: session.isPlaybackLoading && session.playbackRequested,
    channelSwapEnabled: session.channelSwapEnabled,
    audioEffects: session.audioEffects,
    speed: session.speed,
    playbackError: session.playbackError,
    queueColorValue: session.playbackQueue?.colorValue,
  );
}

PlaylistStructureState playlistStructureStateFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  return PlaylistStructureState(
    entries: List<PlaylistStructureEntry>.unmodifiable(
      playbackState.activeSessions.map(_playlistStructureEntry),
    ),
    coverGeneration: playbackState.coverGeneration,
    isInitialized: playbackState.isInitialized,
  );
}

PlaylistStructureEntry _playlistStructureEntry(
  PlaybackSessionSnapshot session,
) {
  return PlaylistStructureEntry(
    session: session,
    sessionId: session.id,
    trackPath: session.currentTrackPath,
    isPlaybackQueue: session.isPlaybackQueue,
    queueColorValue: session.playbackQueue?.colorValue,
    queueContentSignature: session.playbackQueue?.contentSignature,
  );
}
