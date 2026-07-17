part of 'audio_state_services.dart';

class NotificationCoordinatorService {
  final Map<String, String?> notificationSubtitleTexts = <String, String?>{};
  final Map<String, String> notificationSubtitleTrackPaths = <String, String>{};
  String? notificationFocusSessionId;
  String? unifiedNotificationSyncKey;
  Timer? notificationProgressRefreshTimer;
  Timer? unifiedNotificationSyncTimer;
  bool unifiedNotificationSyncInFlight = false;
  bool unifiedNotificationSyncPending = false;
  bool notificationActionRefreshPending = false;
  String? queuedNotificationRefreshSessionId;
  bool notificationsDismissedWhilePaused = false;
  Timer? notificationActionRefreshTimer;
  Timer? notificationActionGuardTimeout;
  final AudioStateSlice<NotificationState> slice =
      AudioStateSlice<NotificationState>(const NotificationState());

  List<PlaybackSession> singleThreadNotificationSessions(
    List<PlaybackSession> activeSessions,
  ) {
    return activeSessions
        .where(
          (session) =>
              session.state.playing ||
              session.isPlaybackStarting ||
              session.state.processingState == ProcessingState.idle ||
              session.state.processingState == ProcessingState.ready ||
              session.state.processingState == ProcessingState.completed,
        )
        .toList(growable: false);
  }

  List<PlaybackSession> notificationQueueSessions({
    required List<PlaybackSession> activeSessions,
    required bool multiThreadPlaybackEnabled,
  }) {
    return multiThreadPlaybackEnabled
        ? activeSessions
        : singleThreadNotificationSessions(activeSessions);
  }

  PlaybackSession? focusedSessionFrom(Iterable<PlaybackSession> sessions) {
    final focusedId = notificationFocusSessionId;
    if (focusedId != null) {
      for (final session in sessions) {
        if (session.id == focusedId) return session;
      }
    }
    final fallback = sessions.isNotEmpty ? sessions.first : null;
    notificationFocusSessionId = fallback?.id;
    return fallback;
  }

  PlaybackSession? notificationActionSession({
    required List<PlaybackSession> activeSessions,
    required List<PlaybackSession> queueSessions,
  }) {
    final focused = focusedSessionFrom(activeSessions);
    return focused ?? focusedSessionFrom(queueSessions);
  }

  PlaybackSession? resolveNotificationSession({
    required Map<String, PlaybackSession> sessions,
    required List<PlaybackSession> activeSessions,
    required List<PlaybackSession> queueSessions,
    String? sessionId,
  }) {
    if (sessionId != null) {
      final matchedSession = sessions[sessionId];
      if (matchedSession != null) {
        notificationFocusSessionId = matchedSession.id;
        return matchedSession;
      }
    }
    final focusedSession = notificationActionSession(
      activeSessions: activeSessions,
      queueSessions: queueSessions,
    );
    if (focusedSession != null) {
      notificationFocusSessionId = focusedSession.id;
    }
    return focusedSession;
  }

  void beginNotificationAction({
    required VoidCallback notify,
    required VoidCallback syncNotificationState,
  }) {
    unifiedNotificationSyncKey = null;
    unifiedNotificationSyncTimer?.cancel();
    unifiedNotificationSyncTimer = null;
    notificationActionRefreshTimer?.cancel();
    notificationActionRefreshTimer = null;
    notificationActionRefreshPending = true;

    notificationActionGuardTimeout?.cancel();
    notificationActionGuardTimeout = Timer(const Duration(seconds: 5), () {
      notificationActionGuardTimeout = null;
      if (notificationActionRefreshPending) {
        AppLogService.warning('notification_action_guard_timed_out');
        notificationActionRefreshPending = false;
        syncNotificationState();
        notify();
      }
    });
  }

  Future<void> guardNotificationAction(
    Future<void> Function() action, {
    required VoidCallback notify,
    required VoidCallback syncNotificationState,
  }) async {
    beginNotificationAction(
      notify: notify,
      syncNotificationState: syncNotificationState,
    );
    try {
      await action();
    } finally {
      scheduleNotificationActionRefresh(
        notify: notify,
        syncNotificationState: syncNotificationState,
      );
    }
  }

  void scheduleNotificationActionRefresh({
    required VoidCallback notify,
    required VoidCallback syncNotificationState,
  }) {
    notificationActionGuardTimeout?.cancel();
    notificationActionGuardTimeout = null;
    notificationActionRefreshTimer?.cancel();
    notificationActionRefreshTimer = Timer(
      const Duration(milliseconds: 120),
      () {
        notificationActionRefreshTimer = null;
        notificationActionRefreshPending = false;
        syncNotificationState();
        notify();
      },
    );

    notify();
  }

  void syncSlice({required int activeQueueLength}) {
    slice.update(
      NotificationState(
        focusedSessionId: notificationFocusSessionId,
        notificationsDismissedWhilePaused: notificationsDismissedWhilePaused,
        notificationActionRefreshPending: notificationActionRefreshPending,
        activeQueueLength: activeQueueLength,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
