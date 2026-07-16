import 'dart:async';
import 'dart:convert';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/music_track.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/media/subtitle_parser.dart';
import '../../library/application/cover_artwork_cache_service.dart';

import 'audio_state_services.dart';
import 'playback_facade.dart';
import 'playback_notification_service.dart';
import 'playback_session.dart';
import 'playback_subtitle_service.dart';
import 'system_media_controls_service.dart';

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
  Future<void> Function() _stopPlaybackKeepAlive = _noopAsync;
  String? Function() _preferredSessionId = _noSessionId;
  void Function() _notifyNotificationChanged = _noop;
  NotificationTrackResolver _trackByPath = _noTrack;
  late NotificationPlaybackCommands _playbackCommands;
  late PlaybackSubtitleService _subtitleService;
  late CoverArtworkCacheService _coverArtworkCacheService;
  bool Function() _notificationsEnabledResolver = _alwaysFalse;
  bool _synchronizationAttached = false;

  NotificationFacade get _notificationFacade => this;
  PlaybackFacade get _playbackFacade => _playback!;
  NotificationCoordinatorService get _notificationStateService => stateService;
  PlaybackNotificationService get _notificationService => service;
  SystemMediaControlsService get _systemMediaControlsService =>
      _playbackFacade.systemMediaControlsService;
  Map<String, PlaybackSession> get _sessions =>
      _playbackFacade.service.sessions;
  List<PlaybackSession> get activeSessions =>
      _playbackFacade.service.activeSessions;
  bool get _multiThreadPlaybackEnabled => _multiThreadPlaybackEnabledResolver();
  bool get _hasPlaybackToKeepAlive => _hasPlaybackToKeepAliveResolver();
  bool get _notificationsEnabled => _notificationsEnabledResolver();

  String? get _notificationFocusSessionId =>
      stateService.notificationFocusSessionId;
  set _notificationFocusSessionId(String? value) {
    stateService.notificationFocusSessionId = value;
  }

  String? get _unifiedNotificationSyncKey =>
      stateService.unifiedNotificationSyncKey;
  set _unifiedNotificationSyncKey(String? value) {
    stateService.unifiedNotificationSyncKey = value;
  }

  Timer? get _notificationProgressRefreshTimer =>
      stateService.notificationProgressRefreshTimer;
  set _notificationProgressRefreshTimer(Timer? value) {
    stateService.notificationProgressRefreshTimer = value;
  }

  Timer? get _unifiedNotificationSyncTimer =>
      stateService.unifiedNotificationSyncTimer;
  set _unifiedNotificationSyncTimer(Timer? value) {
    stateService.unifiedNotificationSyncTimer = value;
  }

  bool get _unifiedNotificationSyncInFlight =>
      stateService.unifiedNotificationSyncInFlight;
  set _unifiedNotificationSyncInFlight(bool value) {
    stateService.unifiedNotificationSyncInFlight = value;
  }

  bool get _unifiedNotificationSyncPending =>
      stateService.unifiedNotificationSyncPending;
  set _unifiedNotificationSyncPending(bool value) {
    stateService.unifiedNotificationSyncPending = value;
  }

  bool get _notificationActionRefreshPending =>
      stateService.notificationActionRefreshPending;
  String? get _queuedNotificationRefreshSessionId =>
      stateService.queuedNotificationRefreshSessionId;
  set _queuedNotificationRefreshSessionId(String? value) {
    stateService.queuedNotificationRefreshSessionId = value;
  }

  bool get _notificationsDismissedWhilePaused =>
      stateService.notificationsDismissedWhilePaused;
  Map<String, String?> get _notificationSubtitleTexts =>
      stateService.notificationSubtitleTexts;
  Map<String, String> get _notificationSubtitleTrackPaths =>
      stateService.notificationSubtitleTrackPaths;

  MusicTrack? trackByPath(String trackPath) => _trackByPath(trackPath);

  void handleSubtitleTrackLoaded(String trackPath, SubtitleTrack? track) =>
      _handleSubtitleTrackLoaded(trackPath, track);

  void syncPlaybackState({bool immediateUnifiedSync = false}) =>
      _syncNotificationState(immediateUnifiedSync: immediateUnifiedSync);

  void clearSessionSubtitle(String sessionId) =>
      _clearNotificationSubtitleForSession(sessionId);

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
  Future<void> stopPlaybackKeepAliveOnPlatform() =>
      _stopPlaybackKeepAliveOnPlatform();
  bool isActiveCoverKey(String key) => _isActiveCoverKey(key);
  void ensureSubtitleTrackLoaded(String trackPath) =>
      _ensureSubtitleTrackLoaded(trackPath);

  void prepareForPersistenceReset() {
    stateService.notificationProgressRefreshTimer?.cancel();
    stateService.notificationProgressRefreshTimer = null;
    stateService.unifiedNotificationSyncTimer?.cancel();
    stateService.unifiedNotificationSyncTimer = null;
    stateService.notificationActionRefreshTimer?.cancel();
    stateService.notificationActionRefreshTimer = null;
    stateService.notificationActionGuardTimeout?.cancel();
    stateService.notificationActionGuardTimeout = null;
  }

  Future<void> resetForBackupRestore() async {
    stateService
      ..notificationFocusSessionId = null
      ..unifiedNotificationSyncKey = null
      ..unifiedNotificationSyncInFlight = false
      ..unifiedNotificationSyncPending = false
      ..queuedNotificationRefreshSessionId = null
      ..notificationsDismissedWhilePaused = false
      ..notificationActionRefreshPending = false
      ..keepAliveSyncDeferred = false;
    stateService.notificationSubtitleTexts.clear();
    stateService.notificationSubtitleTrackPaths.clear();
    _subtitleService.clear();
    _coverArtworkCacheService.invalidateAll();
    await _clearUnifiedPlaybackNotificationsOnPlatform();
    _syncKeepAlive();
    _notifyNotificationChanged();
  }

  NotificationState get state => stateService.slice.state;
  Stream<NotificationState> get states => stateService.slice.stream;

  void refreshState() {
    _syncNotificationState();
    _notifyNotificationChanged();
  }

  Future<void> handlePlaybackModeChanged() async {
    stateService.unifiedNotificationSyncKey = null;
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
    required Future<void> Function() stopPlaybackKeepAlive,
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
    _stopPlaybackKeepAlive = stopPlaybackKeepAlive;
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
    if (_hasPlaybackToKeepAlive) {
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
MusicTrack? _noTrack(String trackPath) => null;
