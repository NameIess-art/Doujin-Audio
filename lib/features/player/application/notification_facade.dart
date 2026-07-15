import 'dart:async';

import 'audio_state_services.dart';
import 'playback_facade.dart';
import 'playback_notification_service.dart';
import 'playback_session.dart';

typedef NotificationSessionResolver =
    PlaybackSession? Function([String? sessionId]);

/// Owns notification synchronization state and the notification gateway.
final class NotificationFacade {
  NotificationFacade({required this.service, required this.stateService});

  factory NotificationFacade.create({
    required PlaybackNotificationService service,
    NotificationCoordinatorService? stateService,
  }) {
    return NotificationFacade(
      service: service,
      stateService: stateService ?? NotificationCoordinatorService(),
    );
  }

  final PlaybackNotificationService service;
  final NotificationCoordinatorService stateService;
  Future<void> Function() _undismissNotifications = _noopAsync;
  void Function() _onNotificationsRestored = _noop;
  PlaybackFacade? _playback;
  NotificationSessionResolver _resolveSession = _noopSessionResolver;
  PlaybackSession? Function() _resolveActionSession = _noopActionSession;
  Future<void> Function(PlaybackSession session) _resumeSession =
      _noopResumeSession;
  bool Function() _multiThreadPlaybackEnabled = _alwaysFalse;
  void Function(String? sessionId) _setFocusSessionId = _ignoreSessionId;
  void Function() _notify = _noop;
  void Function() _syncKeepAlive = _noop;
  void Function() _syncNotificationState = _noop;
  bool Function() _hasPlaybackToKeepAlive = _alwaysFalse;
  Future<void> Function() _clearUnifiedNotifications = _noopAsync;
  Future<void> Function() _stopPlaybackKeepAlive = _noopAsync;
  String? Function() _preferredSessionId = _noSessionId;
  void Function() _notifyNotificationChanged = _noop;

  NotificationState get state => stateService.slice.state;
  Stream<NotificationState> get states => stateService.slice.stream;

  void attachRuntime({
    required Future<void> Function() undismissNotifications,
    required void Function() onNotificationsRestored,
  }) {
    _undismissNotifications = undismissNotifications;
    _onNotificationsRestored = onNotificationsRestored;
  }

  void attachActions({
    required PlaybackFacade playback,
    required NotificationSessionResolver resolveSession,
    required PlaybackSession? Function() resolveActionSession,
    required Future<void> Function(PlaybackSession session) resumeSession,
    required bool Function() multiThreadPlaybackEnabled,
    required void Function(String? sessionId) setFocusSessionId,
    required void Function() notify,
    required void Function() syncKeepAlive,
    required void Function() syncNotificationState,
    required bool Function() hasPlaybackToKeepAlive,
    required Future<void> Function() clearUnifiedNotifications,
    required Future<void> Function() stopPlaybackKeepAlive,
    required String? Function() preferredSessionId,
    required void Function() notifyNotificationChanged,
  }) {
    _playback ??= playback;
    _resolveSession = resolveSession;
    _resolveActionSession = resolveActionSession;
    _resumeSession = resumeSession;
    _multiThreadPlaybackEnabled = multiThreadPlaybackEnabled;
    _setFocusSessionId = setFocusSessionId;
    _notify = notify;
    _syncKeepAlive = syncKeepAlive;
    _syncNotificationState = syncNotificationState;
    _hasPlaybackToKeepAlive = hasPlaybackToKeepAlive;
    _clearUnifiedNotifications = clearUnifiedNotifications;
    _stopPlaybackKeepAlive = stopPlaybackKeepAlive;
    _preferredSessionId = preferredSessionId;
    _notifyNotificationChanged = notifyNotificationChanged;
  }

  Future<void> playPrimarySession() {
    return _guardAction(() async {
      final session = _resolveSession();
      if (session == null) return;
      await _resumeSession(session);
    });
  }

  Future<void> playSessionById(String sessionId) {
    return _guardAction(() async {
      final session = _resolveSession(sessionId);
      if (session == null) return;
      await _resumeSession(session);
    });
  }

  Future<void> pausePrimarySession() {
    return _guardAction(() async {
      final session = _resolveActionSession();
      final playback = _playback;
      if (session == null || playback == null || !session.state.playing) return;
      _setFocusSessionId(session.id);
      await playback.nativeRepository.pause(session.id);
      session.setOptimisticState(playing: false);
    });
  }

  Future<void> togglePrimarySessionPlayPause() {
    return _guardAction(() async {
      final session = _resolveSession();
      final playback = _playback;
      if (session == null || playback == null || session.isLoading) return;
      if (session.state.playing) {
        await playback.nativeRepository.pause(session.id);
        session.setOptimisticState(playing: false);
        return;
      }
      await _resumeSession(session);
    });
  }

  Future<void> stopPrimarySession() {
    return _guardAction(() async {
      final session = _resolveActionSession();
      final playback = _playback;
      if (session == null || playback == null) return;
      _setFocusSessionId(session.id);
      await playback.nativeRepository.pause(session.id);
      session.setOptimisticState(playing: false);
    });
  }

  Future<void> skipPrimarySessionToNext() {
    return _guardAction(() async {
      final session = _resolveActionSession();
      final playback = _playback;
      if (session == null || playback == null) return;
      _setFocusSessionId(session.id);
      await playback.seekSessionToNext(session.id);
    });
  }

  Future<void> skipPrimarySessionToPrevious() {
    return _guardAction(() async {
      final session = _resolveActionSession();
      final playback = _playback;
      if (session == null || playback == null) return;
      _setFocusSessionId(session.id);
      await playback.seekSessionToPrev(session.id);
    });
  }

  Future<void> toggleSessionPlayback(String sessionId) {
    return _guardAction(() async {
      final playback = _playback;
      final session = playback?.sessionById(sessionId);
      if (session == null || playback == null) return;
      _focusExplicitSession(session);
      await playback.toggleSessionPlayPause(session.id);
    });
  }

  Future<void> skipSessionToPrevious(String sessionId) {
    return _guardAction(() async {
      final playback = _playback;
      final session = playback?.sessionById(sessionId);
      if (session == null || playback == null) return;
      _focusExplicitSession(session);
      await playback.seekSessionToPrev(session.id);
    });
  }

  Future<void> skipSessionToNext(String sessionId) {
    return _guardAction(() async {
      final playback = _playback;
      final session = playback?.sessionById(sessionId);
      if (session == null || playback == null) return;
      _focusExplicitSession(session);
      await playback.seekSessionToNext(session.id);
    });
  }

  Future<void> seekPrimarySession(Duration position) {
    return _guardAction(() async {
      final session = _resolveActionSession();
      final playback = _playback;
      if (session == null || playback == null) return;
      _setFocusSessionId(session.id);
      await playback.seekSession(session.id, position);
    });
  }

  Future<void> dismissAfterPauseAll() async {
    final playback = _playback;
    if (playback == null) return;
    stateService.notificationsDismissedWhilePaused = true;
    await playback.nativeRepository.dismissNotifications();
    if (_hasPlaybackToKeepAlive()) {
      await _clearUnifiedNotifications();
      _syncKeepAlive();
      _notifyNotificationChanged();
      return;
    }
    await _clearUnifiedNotifications();
    await _stopPlaybackKeepAlive();
    await playback.pauseAllSessions();
    _setFocusSessionId(_preferredSessionId());
    _syncKeepAlive();
    _notifyNotificationChanged();
  }

  Future<void> _guardAction(Future<void> Function() action) {
    return stateService.guardNotificationAction(
      action,
      notify: _notify,
      flushKeepAliveSync: _syncKeepAlive,
      syncNotificationState: _syncNotificationState,
    );
  }

  void _focusExplicitSession(PlaybackSession session) {
    if (!_multiThreadPlaybackEnabled()) {
      _setFocusSessionId(session.id);
    }
  }

  Future<void> restoreAfterSystemClear() async {
    stateService.notificationsDismissedWhilePaused = false;
    stateService.unifiedNotificationSyncKey = null;
    await _undismissNotifications();
    _onNotificationsRestored();
  }

  void resyncAfterForegroundResume() {
    if (!stateService.notificationsDismissedWhilePaused) return;
    stateService.notificationsDismissedWhilePaused = false;
    stateService.unifiedNotificationSyncKey = null;
    unawaited(_undismissNotifications());
    _onNotificationsRestored();
  }

  Future<void> dispose() => stateService.dispose();
}

void _noop() {}
Future<void> _noopAsync() async {}
PlaybackSession? _noopSessionResolver([String? sessionId]) => null;
PlaybackSession? _noopActionSession() => null;
Future<void> _noopResumeSession(PlaybackSession session) async {}
bool _alwaysFalse() => false;
void _ignoreSessionId(String? sessionId) {}
String? _noSessionId() => null;
