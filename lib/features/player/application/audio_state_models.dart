part of 'audio_state_services.dart';

@immutable
class PlaybackStateSliceData {
  PlaybackStateSliceData({
    List<PlaybackSession> activeSessions = const <PlaybackSession>[],
    this.playingSessionCount = 0,
    this.focusedSessionId,
    this.multiThreadPlaybackEnabled = false,
    this.coverGeneration = 0,
    this.sessionStateVersion = 0,
    this.isInitialized = false,
  }) : activeSessions = immutableList(activeSessions);

  final List<PlaybackSession> activeSessions;
  final int playingSessionCount;
  final String? focusedSessionId;
  final bool multiThreadPlaybackEnabled;
  final int coverGeneration;
  final int sessionStateVersion;
  final bool isInitialized;

  @override
  bool operator ==(Object other) {
    return other is PlaybackStateSliceData &&
        other.sessionStateVersion == sessionStateVersion &&
        listEquals(other.activeSessions, activeSessions) &&
        other.playingSessionCount == playingSessionCount &&
        other.focusedSessionId == focusedSessionId &&
        other.multiThreadPlaybackEnabled == multiThreadPlaybackEnabled &&
        other.coverGeneration == coverGeneration &&
        other.isInitialized == isInitialized;
  }

  @override
  int get hashCode => Object.hash(
    sessionStateVersion,
    Object.hashAll(activeSessions),
    playingSessionCount,
    focusedSessionId,
    multiThreadPlaybackEnabled,
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
