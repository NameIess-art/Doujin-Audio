part of 'audio_state_services.dart';

@immutable
class PlaybackAggregateState {
  const PlaybackAggregateState({
    this.sessionCount = 0,
    this.playingSessionCount = 0,
    this.hasPlayingAudioSession = false,
    this.hasPlaybackToKeepAlive = false,
    this.focusedSessionId,
    this.isInitialized = false,
  });

  final int sessionCount;
  final int playingSessionCount;
  final bool hasPlayingAudioSession;
  final bool hasPlaybackToKeepAlive;
  final String? focusedSessionId;
  final bool isInitialized;

  @override
  bool operator ==(Object other) =>
      other is PlaybackAggregateState &&
      other.sessionCount == sessionCount &&
      other.playingSessionCount == playingSessionCount &&
      other.hasPlayingAudioSession == hasPlayingAudioSession &&
      other.hasPlaybackToKeepAlive == hasPlaybackToKeepAlive &&
      other.focusedSessionId == focusedSessionId &&
      other.isInitialized == isInitialized;

  @override
  int get hashCode => Object.hash(
    sessionCount,
    playingSessionCount,
    hasPlayingAudioSession,
    hasPlaybackToKeepAlive,
    focusedSessionId,
    isInitialized,
  );
}

/// Directory snapshots change only when membership or display structure changes.
@immutable
class PlaybackCatalogState {
  PlaybackCatalogState({
    List<PlaybackSessionSnapshot> sessions = const [],
    List<PlaybackSessionSnapshot> nowPlayingSessions = const [],
    this.isInitialized = false,
  }) : sessions = immutableList(sessions),
       nowPlayingSessions = immutableList(nowPlayingSessions);

  final List<PlaybackSessionSnapshot> sessions;
  final List<PlaybackSessionSnapshot> nowPlayingSessions;
  final bool isInitialized;

  @override
  bool operator ==(Object other) =>
      other is PlaybackCatalogState &&
      listEquals(other.sessions, sessions) &&
      listEquals(other.nowPlayingSessions, nowPlayingSessions) &&
      other.isInitialized == isInitialized;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(sessions),
    Object.hashAll(nowPlayingSessions),
    isInitialized,
  );
}

/// An explicitly requested read view; never broadcast for runtime updates.
@immutable
class PlaybackStateSliceData {
  PlaybackStateSliceData({
    List<PlaybackSessionSnapshot> activeSessions =
        const <PlaybackSessionSnapshot>[],
    this.playingSessionCount = 0,
    this.focusedSessionId,
    this.coverGeneration = 0,
    this.isInitialized = false,
  }) : activeSessions = immutableList(activeSessions);

  final List<PlaybackSessionSnapshot> activeSessions;
  final int playingSessionCount;
  final String? focusedSessionId;
  final int coverGeneration;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is PlaybackStateSliceData &&
        listEquals(other.activeSessions, activeSessions) &&
        other.playingSessionCount == playingSessionCount &&
        other.focusedSessionId == focusedSessionId &&
        other.coverGeneration == coverGeneration &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(activeSessions),
    playingSessionCount,
    focusedSessionId,
    coverGeneration,
    isInitialized,
  );
}

@immutable
class TimerStateSliceData {
  TimerStateSliceData({
    this.mode,
    this.duration,
    this.draftMode = TimerMode.manual,
    this.draftDuration = const Duration(minutes: 30),
    this.active = false,
    this.remaining,
    this.autoResumeEnabled = false,
    this.autoResumeHour = 7,
    this.autoResumeMinute = 0,
    this.autoResumeAt,
    List<String> pausedByTimerSessionIds = const <String>[],
    this.stopAfterCurrentTrack = false,
    this.isInitialized = false,
  }) : pausedByTimerSessionIds = immutableList(pausedByTimerSessionIds);

  final TimerMode? mode;
  final Duration? duration;
  final TimerMode draftMode;
  final Duration draftDuration;
  final bool active;
  final Duration? remaining;
  final bool autoResumeEnabled;
  final int autoResumeHour;
  final int autoResumeMinute;

  /// Wall-clock time at which auto-resume will fire, or null if not scheduled.
  final DateTime? autoResumeAt;
  final List<String> pausedByTimerSessionIds;
  final bool stopAfterCurrentTrack;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is TimerStateSliceData &&
        other.mode == mode &&
        other.duration == duration &&
        other.draftMode == draftMode &&
        other.draftDuration == draftDuration &&
        other.active == active &&
        other.remaining == remaining &&
        other.autoResumeEnabled == autoResumeEnabled &&
        other.autoResumeHour == autoResumeHour &&
        other.autoResumeMinute == autoResumeMinute &&
        other.autoResumeAt == autoResumeAt &&
        listEquals(other.pausedByTimerSessionIds, pausedByTimerSessionIds) &&
        other.stopAfterCurrentTrack == stopAfterCurrentTrack &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    duration,
    draftMode,
    draftDuration,
    active,
    remaining,
    autoResumeEnabled,
    autoResumeHour,
    autoResumeMinute,
    autoResumeAt,
    Object.hashAll(pausedByTimerSessionIds),
    stopAfterCurrentTrack,
    isInitialized,
  );
}

@immutable
class NotificationState {
  const NotificationState({
    this.focusedSessionId,
    this.notificationsDismissedWhilePaused = false,
    this.notificationActionRefreshPending = false,
    this.activeQueueLength = 0,
  });

  final String? focusedSessionId;
  final bool notificationsDismissedWhilePaused;
  final bool notificationActionRefreshPending;
  final int activeQueueLength;

  @override
  bool operator ==(Object other) {
    return other is NotificationState &&
        other.focusedSessionId == focusedSessionId &&
        other.notificationsDismissedWhilePaused ==
            notificationsDismissedWhilePaused &&
        other.notificationActionRefreshPending ==
            notificationActionRefreshPending &&
        other.activeQueueLength == activeQueueLength;
  }

  @override
  int get hashCode => Object.hash(
    focusedSessionId,
    notificationsDismissedWhilePaused,
    notificationActionRefreshPending,
    activeQueueLength,
  );
}
