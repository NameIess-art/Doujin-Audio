import 'package:flutter/foundation.dart';

import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../application/playback_session_snapshot.dart';
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

  final List<PlaybackSessionSnapshot> sessions;
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
        other.session.lastPlayedAt == session.lastPlayedAt &&
        other.queueColorValue == queueColorValue &&
        other.queueContentSignature == queueContentSignature;
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    trackPath,
    isPlaybackQueue,
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
    required this.visibleSessions,
    required this.playingSessionCount,
    required this.activeSessionCount,
    required this.showPlaybackCard,
    required this.isInitialized,
    required this.startupReady,
  });

  final List<PlaybackSessionSnapshot> overlaySessions;
  final List<PlaybackSessionSnapshot> visibleSessions;
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

  bool get showPauseIcon => isPlaying;

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
  return playbackState.activeSessions
      .where((session) => session.currentTrackPath.isNotEmpty)
      .toList(growable: false);
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
      isLoading: session.isPlaybackLoading && session.playbackRequested,
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

PlaylistStructureState playlistStructureStateFromListState(
  PlaylistListState listState,
) {
  return PlaylistStructureState(
    entries: List<PlaylistStructureEntry>.unmodifiable(
      listState.sessions.map((session) {
        final cardState = listState.cardStateFor(session.id);
        return PlaylistStructureEntry(
          session: session,
          sessionId: session.id,
          trackPath: cardState?.trackPath ?? session.currentTrackPath,
          isPlaybackQueue: session.isPlaybackQueue,
          queueColorValue:
              cardState?.queueColorValue ?? session.playbackQueue?.colorValue,
          queueContentSignature: _playlistQueueContentSignature(session),
        );
      }),
    ),
    coverGeneration: listState.coverGeneration,
    isInitialized: listState.isInitialized,
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
    queueContentSignature: _playlistQueueContentSignature(session),
  );
}

int? _playlistQueueContentSignature(PlaybackSessionSnapshot session) {
  final queue = session.playbackQueue;
  if (queue == null) return null;
  return Object.hash(
    queue.name,
    Object.hashAll(
      queue.entries.map(
        (entry) => Object.hash(
          entry.id,
          entry.kind,
          entry.title,
          entry.workRootPath,
          Object.hashAll(entry.tracks.map((track) => track.path)),
        ),
      ),
    ),
  );
}
