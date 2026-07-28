import 'dart:async';
import 'dart:convert';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../library/application/cover_artwork_cache_service.dart';

import 'audio_state_services.dart';
import 'playback_facade.dart';
import 'playback_notification_service.dart';
import 'playback_session.dart';
import 'playback_subtitle_service.dart';

part 'notification_facade_covers.dart';
part 'notification_facade_subtitles.dart';
part 'notification_facade_sync.dart';

typedef NotificationSessionResolver =
    PlaybackSession? Function([String? sessionId]);
typedef NotificationTrackResolver = MusicTrack? Function(String trackPath);

abstract interface class NotificationPlaybackCommands {
  Future<bool> prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay,
    bool forceStartAtZero,
    bool showLoading,
    int? targetQueueIndex,
  });

  Future<bool> startSession(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  });

  bool hasAdjacent(PlaybackSession session, {required bool forward});
}

/// Owns notification synchronization state and the notification gateway.
final class NotificationFacade {
  NotificationFacade({
    required PlaybackNotificationService service,
    required NotificationCoordinatorService stateService,
  }) : _service = service,
       _stateService = stateService;

  factory NotificationFacade.create({
    required PlaybackNotificationService service,
    NotificationCoordinatorService? stateService,
  }) {
    return NotificationFacade(
      service: service,
      stateService: stateService ?? NotificationCoordinatorService(),
    );
  }

  final PlaybackNotificationService _service;
  final NotificationCoordinatorService _stateService;
  static const Duration _notificationProgressRefreshInterval = Duration(
    milliseconds: 750,
  );
  static const Duration _multiSessionNotificationRefreshInterval = Duration(
    milliseconds: 700,
  );
  static const Duration _unifiedNotificationDebounceInterval = Duration(
    milliseconds: 90,
  );
  Future<void> Function() _undismissNotifications = _noopAsync;
  void Function() _onNotificationsRestored = _noop;
  PlaybackFacade? _playback;
  NotificationSessionResolver _resolveSession = _noopSessionResolver;
  PlaybackSession? Function() _resolveActionSession = _noopActionSession;
  Future<void> Function(PlaybackSession session) _resumeSession =
      _noopResumeSession;
  bool Function() _multiThreadPlaybackEnabledResolver = _alwaysFalse;
  void Function(String? sessionId) _setFocusSessionId = _ignoreSessionId;
  void Function() _notify = _noop;
  void Function() _syncKeepAlive = _noop;
  bool Function() _hasPlaybackToKeepAliveResolver = _alwaysFalse;
  Future<void> Function() _clearUnifiedNotifications = _noopAsync;
  String? Function() _preferredSessionId = _noSessionId;
  void Function() _notifyNotificationChanged = _noop;
  NotificationTrackResolver _trackByPath = _noTrack;
  late NotificationPlaybackCommands _playbackCommands;
  late PlaybackSubtitleService _subtitleService;
  late CoverArtworkCacheService _coverArtworkCacheService;
  bool Function() _notificationsEnabledResolver = _alwaysFalse;
  bool _synchronizationAttached = false;

  NotificationCoordinatorService get _notificationStateService => _stateService;
  PlaybackNotificationService get _notificationService => _service;
  Map<String, PlaybackSession> get _sessions =>
      _playback?.sessions ?? const <String, PlaybackSession>{};
  List<PlaybackSession> get activeSessions =>
      _playback?.activeSessions ?? const <PlaybackSession>[];
  bool get _multiThreadPlaybackEnabled => _multiThreadPlaybackEnabledResolver();
  bool get _hasPlaybackToKeepAlive => _hasPlaybackToKeepAliveResolver();
  bool get _notificationsEnabled => _notificationsEnabledResolver();

  String? get _notificationFocusSessionId =>
      _stateService.notificationFocusSessionId;
  set _notificationFocusSessionId(String? value) {
    _stateService.notificationFocusSessionId = value;
  }

  String? get _unifiedNotificationSyncKey =>
      _stateService.unifiedNotificationSyncKey;
  set _unifiedNotificationSyncKey(String? value) {
    _stateService.unifiedNotificationSyncKey = value;
  }

  Timer? get _notificationProgressRefreshTimer =>
      _stateService.notificationProgressRefreshTimer;
  set _notificationProgressRefreshTimer(Timer? value) {
    _stateService.notificationProgressRefreshTimer = value;
  }

  Timer? get _unifiedNotificationSyncTimer =>
      _stateService.unifiedNotificationSyncTimer;
  set _unifiedNotificationSyncTimer(Timer? value) {
    _stateService.unifiedNotificationSyncTimer = value;
  }

  bool get _unifiedNotificationSyncInFlight =>
      _stateService.unifiedNotificationSyncInFlight;
  set _unifiedNotificationSyncInFlight(bool value) {
    _stateService.unifiedNotificationSyncInFlight = value;
  }

  bool get _unifiedNotificationSyncPending =>
      _stateService.unifiedNotificationSyncPending;
  set _unifiedNotificationSyncPending(bool value) {
    _stateService.unifiedNotificationSyncPending = value;
  }

  bool get _notificationActionRefreshPending =>
      _stateService.notificationActionRefreshPending;
  String? get _queuedNotificationRefreshSessionId =>
      _stateService.queuedNotificationRefreshSessionId;
  set _queuedNotificationRefreshSessionId(String? value) {
    _stateService.queuedNotificationRefreshSessionId = value;
  }

  bool get _notificationsDismissedWhilePaused =>
      _stateService.notificationsDismissedWhilePaused;
  Map<String, String?> get _notificationSubtitleTexts =>
      _stateService.notificationSubtitleTexts;
  Map<String, String> get _notificationSubtitleTrackPaths =>
      _stateService.notificationSubtitleTrackPaths;

  MusicTrack? trackByPath(String trackPath) => _trackByPath(trackPath);

  void handleSubtitleTrackLoaded(String trackPath, SubtitleTrack? track) =>
      _handleSubtitleTrackLoaded(trackPath, track);

  void syncPlaybackState({bool immediateUnifiedSync = false}) =>
      _syncNotificationState(immediateUnifiedSync: immediateUnifiedSync);

  String? get focusedSessionId => _stateService.notificationFocusSessionId;

  void setFocusedSession(String? sessionId) {
    _stateService.notificationFocusSessionId = sessionId;
  }

  void clearFocusIfMatches(String sessionId) {
    if (_stateService.notificationFocusSessionId == sessionId) {
      _stateService.notificationFocusSessionId = null;
    }
  }

  void registerSessionFocus(String sessionId) {
    _stateService
      ..notificationsDismissedWhilePaused = false
      ..notificationFocusSessionId = sessionId;
  }

  void markNotificationsAvailable() {
    _stateService.notificationsDismissedWhilePaused = false;
  }

  void syncPresentationState({required int activeQueueLength}) {
    _stateService.syncSlice(activeQueueLength: activeQueueLength);
  }

  void setSynchronizationPaused(bool paused) {
    if (_stateService.synchronizationPaused == paused) return;
    _stateService.synchronizationPaused = paused;
    if (paused) {
      final hasPendingSynchronization =
          _unifiedNotificationSyncTimer != null ||
          _notificationProgressRefreshTimer != null ||
          _queuedNotificationRefreshSessionId != null ||
          _unifiedNotificationSyncPending;
      if (hasPendingSynchronization) {
        _stateService.synchronizationPendingWhilePaused = true;
      }
      _unifiedNotificationSyncTimer?.cancel();
      _unifiedNotificationSyncTimer = null;
      _notificationProgressRefreshTimer?.cancel();
      _notificationProgressRefreshTimer = null;
      _queuedNotificationRefreshSessionId = null;
      return;
    }
    if (!_stateService.synchronizationPendingWhilePaused) return;
    _stateService.synchronizationPendingWhilePaused = false;
    _syncNotificationState(immediateUnifiedSync: true);
  }

  void clearSessionSubtitle(String sessionId) =>
      _clearNotificationSubtitleForSession(sessionId);

  bool updateSessionSubtitle({
    required String sessionId,
    required String trackPath,
    required String? text,
    bool syncNotification = true,
  }) {
    final previousText = _stateService.notificationSubtitleTexts[sessionId];
    final previousTrackPath =
        _stateService.notificationSubtitleTrackPaths[sessionId];
    if (previousTrackPath == trackPath && previousText == text) return false;
    _stateService.notificationSubtitleTexts[sessionId] = text;
    _stateService.notificationSubtitleTrackPaths[sessionId] = trackPath;
    if (syncNotification && focusedSessionId == sessionId) {
      syncPlaybackState();
    }
    return true;
  }

  bool isFocusedSessionId(String sessionId) =>
      _isNotificationFocusedSessionId(sessionId);

  bool refreshSessionSubtitle(
    PlaybackSession session, {
    Duration? position,
    bool syncNotification = true,
  }) => _refreshNotificationSubtitleForSession(
    session,
    position: position,
    syncNotification: syncNotification,
  );

  void scheduleFocusedRefresh(String sessionId, {bool immediate = false}) =>
      _scheduleFocusedNotificationRefresh(sessionId, immediate: immediate);

  PlaybackSession? resolveNotificationSession([String? sessionId]) =>
      _resolveNotificationSession(sessionId);
  PlaybackSession? get notificationActionSession => _notificationActionSession;
  Future<void> resumeNotificationSession(PlaybackSession session) =>
      _resumeNotificationSession(session);
  Future<void> clearUnifiedNotificationsOnPlatform() =>
      _clearUnifiedPlaybackNotificationsOnPlatform();
  bool isActiveCoverKey(String key) => _isActiveCoverKey(key);
  void ensureSubtitleTrackLoaded(String trackPath) =>
      _ensureSubtitleTrackLoaded(trackPath);

  void prepareForPersistenceReset() {
    _stateService.notificationProgressRefreshTimer?.cancel();
    _stateService.notificationProgressRefreshTimer = null;
    _stateService.unifiedNotificationSyncTimer?.cancel();
    _stateService.unifiedNotificationSyncTimer = null;
    _stateService.notificationActionRefreshTimer?.cancel();
    _stateService.notificationActionRefreshTimer = null;
    _stateService.notificationActionGuardTimeout?.cancel();
    _stateService.notificationActionGuardTimeout = null;
  }

  Future<void> resetForBackupRestore() async {
    _stateService
      ..notificationFocusSessionId = null
      ..unifiedNotificationSyncKey = null
      ..unifiedNotificationSyncInFlight = false
      ..unifiedNotificationSyncPending = false
      ..queuedNotificationRefreshSessionId = null
      ..notificationsDismissedWhilePaused = false
      ..notificationActionRefreshPending = false;
    _stateService.notificationSubtitleTexts.clear();
    _stateService.notificationSubtitleTrackPaths.clear();
    _subtitleService.clear();
    _coverArtworkCacheService.invalidateAll();
    await _clearUnifiedPlaybackNotificationsOnPlatform();
    _syncKeepAlive();
    _notifyNotificationChanged();
  }

  NotificationState get state => _stateService.slice.state;
  Stream<NotificationState> get states => _stateService.slice.stream;

  void refreshState() {
    _syncNotificationState();
    _notifyNotificationChanged();
  }

  Future<void> handlePlaybackModeChanged() async {
    _stateService.unifiedNotificationSyncKey = null;
    _setFocusSessionId(null);
    await _clearUnifiedNotifications();
    _syncKeepAlive();
    _syncNotificationState();
    _notifyNotificationChanged();
  }

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
    required bool Function() hasPlaybackToKeepAlive,
    required Future<void> Function() clearUnifiedNotifications,
    required String? Function() preferredSessionId,
    required void Function() notifyNotificationChanged,
  }) {
    _playback ??= playback;
    _resolveSession = resolveSession;
    _resolveActionSession = resolveActionSession;
    _resumeSession = resumeSession;
    _multiThreadPlaybackEnabledResolver = multiThreadPlaybackEnabled;
    _setFocusSessionId = setFocusSessionId;
    _notify = notify;
    _syncKeepAlive = syncKeepAlive;
    _hasPlaybackToKeepAliveResolver = hasPlaybackToKeepAlive;
    _clearUnifiedNotifications = clearUnifiedNotifications;
    _preferredSessionId = preferredSessionId;
    _notifyNotificationChanged = notifyNotificationChanged;
  }

  void attachSynchronization({
    required NotificationPlaybackCommands playbackCommands,
    required PlaybackSubtitleService subtitles,
    required NotificationTrackResolver trackByPath,
    required CoverArtworkCacheService coverArtworkCacheService,
    required bool Function() notificationsEnabled,
  }) {
    _playbackCommands = playbackCommands;
    _subtitleService = subtitles;
    _trackByPath = trackByPath;
    _coverArtworkCacheService = coverArtworkCacheService;
    _notificationsEnabledResolver = notificationsEnabled;
    _synchronizationAttached = true;
  }

  void detachRuntime() {
    _playback = null;
    _resolveSession = _noopSessionResolver;
    _resolveActionSession = _noopActionSession;
    _resumeSession = _noopResumeSession;
    _multiThreadPlaybackEnabledResolver = _alwaysFalse;
    _setFocusSessionId = _ignoreSessionId;
    _notify = _noop;
    _syncKeepAlive = _noop;
    _hasPlaybackToKeepAliveResolver = _alwaysFalse;
    _clearUnifiedNotifications = _noopAsync;
    _preferredSessionId = _noSessionId;
    _notifyNotificationChanged = _noop;
    _trackByPath = _noTrack;
    _notificationsEnabledResolver = _alwaysFalse;
    _synchronizationAttached = false;
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
    _stateService.notificationsDismissedWhilePaused = true;
    await playback.nativeRepository.dismissNotifications();
    if (_hasPlaybackToKeepAlive) {
      await _clearUnifiedNotifications();
      _syncKeepAlive();
      _notifyNotificationChanged();
      return;
    }
    await _clearUnifiedNotifications();
    await playback.pauseAllSessions();
    _setFocusSessionId(_preferredSessionId());
    _syncKeepAlive();
    _notifyNotificationChanged();
  }

  Future<void> _guardAction(Future<void> Function() action) {
    return _stateService.guardNotificationAction(
      action,
      notify: _notify,
      syncNotificationState: () =>
          _syncNotificationState(immediateUnifiedSync: true),
    );
  }

  void _focusExplicitSession(PlaybackSession session) {
    if (!_multiThreadPlaybackEnabled) {
      _setFocusSessionId(session.id);
    }
  }

  Future<void> restoreAfterSystemClear() async {
    _stateService.notificationsDismissedWhilePaused = false;
    _stateService.unifiedNotificationSyncKey = null;
    await _undismissNotifications();
    _onNotificationsRestored();
  }

  void resyncAfterForegroundResume() {
    if (!_stateService.notificationsDismissedWhilePaused) return;
    _stateService.notificationsDismissedWhilePaused = false;
    _stateService.unifiedNotificationSyncKey = null;
    unawaited(_undismissNotifications());
    _onNotificationsRestored();
  }

  Future<void> dispose() => _stateService.dispose();
}

void _noop() {}
Future<void> _noopAsync() async {}
PlaybackSession? _noopSessionResolver([String? sessionId]) => null;
PlaybackSession? _noopActionSession() => null;
Future<void> _noopResumeSession(PlaybackSession session) async {}
bool _alwaysFalse() => false;
void _ignoreSessionId(String? sessionId) {}
String? _noSessionId() => null;
MusicTrack? _noTrack(String trackPath) => null;
