import 'package:flutter/foundation.dart';

import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_session.dart';
import '../application/audio_state_services.dart';

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
class PlaylistListState {
  const PlaylistListState({
    required this.sessions,
    required this.cardStates,
    required this.coverGeneration,
    required this.isInitialized,
  });

  final List<PlaybackSession> sessions;
  final Map<String, PlaylistSessionCardState> cardStates;
  final int coverGeneration;
  final bool isInitialized;

  bool get hasSessions => sessions.isNotEmpty;

  PlaylistSessionCardState? cardStateFor(String sessionId) =>
      cardStates[sessionId];

  @override
  bool operator ==(Object other) {
    return other is PlaylistListState &&
        listEquals(other.sessions, sessions) &&
        mapEquals(other.cardStates, cardStates) &&
        other.coverGeneration == coverGeneration &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(sessions),
    Object.hashAllUnordered(
      cardStates.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    coverGeneration,
    isInitialized,
  );
}

@immutable
class MainOverlayUiState {
  const MainOverlayUiState({
    required this.overlaySessions,
    required this.visibleSessions,
    required this.playingSessionCount,
    required this.activeSessionCount,
    required this.showPlaybackCard,
    required this.isInitialized,
    required this.startupReady,
  });

  final List<PlaybackSession> overlaySessions;
  final List<PlaybackSession> visibleSessions;
  final int playingSessionCount;
  final int activeSessionCount;
  final bool showPlaybackCard;
  final bool isInitialized;
  final bool startupReady;

  bool get hasPlayingSession => playingSessionCount > 0;
  bool get hasNowPlaying => visibleSessions.isNotEmpty;

  @override
  bool operator ==(Object other) {
    return other is MainOverlayUiState &&
        listEquals(other.overlaySessions, overlaySessions) &&
        listEquals(other.visibleSessions, visibleSessions) &&
        other.playingSessionCount == playingSessionCount &&
        other.activeSessionCount == activeSessionCount &&
        other.showPlaybackCard == showPlaybackCard &&
        other.isInitialized == isInitialized &&
        other.startupReady == startupReady;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(overlaySessions),
    Object.hashAll(visibleSessions),
    playingSessionCount,
    activeSessionCount,
    showPlaybackCard,
    isInitialized,
    startupReady,
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
  final bool channelSwapEnabled;
  final double volume;
  final double speed;
  final AudioEffectsState audioEffects;
  final EqCapabilities eqCapabilities;
  final String? playbackError;

  bool get showPauseIcon => isPlaying || isLoading || playbackError != null;

  @override
  bool operator ==(Object other) {
    return other is SessionDetailViewState &&
        other.sessionId == sessionId &&
        other.trackPath == trackPath &&
        other.loopMode == loopMode &&
        other.isPlaying == isPlaying &&
        other.isLoading == isLoading &&
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

List<PlaybackSession> overlaySessionsFromPlaybackState(
  PlaybackStateSliceData playbackState,
) {
  final sessions = playbackState.activeSessions
      .where((session) => session.currentTrackPath.isNotEmpty)
      .toList(growable: false);
  if (playbackState.multiThreadPlaybackEnabled || sessions.isEmpty) {
    return sessions;
  }
  final retainedSession = sessions.firstWhere(
    (session) => session.effectivePlaying || session.isLoading,
    orElse: () => sessions.first,
  );
  return <PlaybackSession>[retainedSession];
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
      isPlaying: session.effectivePlaying,
      isLoading: session.isLoading,
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
      session.id: PlaylistSessionCardState(
        sessionId: session.id,
        trackPath: session.currentTrackPath,
        loopMode: session.loopMode,
        isPlaying: session.effectivePlaying,
        isLoading: session.isLoading,
        channelSwapEnabled: session.channelSwapEnabled,
        audioEffects: session.audioEffects,
        speed: session.speed,
        playbackError: session.playbackError,
        queueColorValue: session.playbackQueue?.colorValue,
      ),
  });
}
