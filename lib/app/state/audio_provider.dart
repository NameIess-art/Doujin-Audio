import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;

import '../../core/widgets/app_feedback.dart';
import '../application/audio_runtime_coordinator.dart';
import '../application/app_persistence_coordinator.dart';
import '../application/audio_path_coordinator.dart';
import '../application/audio_ui_warmup_coordinator.dart';
import '../application/playback_keep_alive_coordinator.dart';

import '../../core/app_language.dart';
import '../../features/asmr/domain/asmr_download.dart';
import '../../features/library/domain/audio_library_category.dart';
import '../../features/player/domain/audio_effects.dart';
import '../../core/media/card_info_field.dart';
import '../../features/library/domain/library_entry.dart';
import '../../features/library/domain/library_node.dart';
import '../../core/media/music_track.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/player/application/playback_session.dart';
import '../../core/platform/app_platform.dart';
import '../../features/settings/application/app_cache_service.dart';
import '../../core/logging/app_log_service.dart';
import '../../features/library/application/audio_detail_cache_service.dart';
import '../../features/library/application/cover_artwork_cache_service.dart';
import '../../core/persistence/audio_database_repository.dart';
import '../../features/library/application/audio_detail_repository.dart';
import '../../features/player/application/audio_state_services.dart';
import '../../features/asmr/application/asmr_api_service.dart';
import '../../features/asmr/application/asmr_metadata_service.dart';
import '../../features/asmr/application/asmr_playback_cache_service.dart';
import '../../features/library/application/dlsite_metadata_service.dart';
import '../../features/library/application/library_snapshot_cache_service.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/application/library_service.dart';
import '../../features/library/application/library_scan_models.dart';
import '../../features/library/application/library_state_models.dart';
import '../../features/player/application/native_playback_repository.dart';
import '../../features/player/application/playback_queue_resolver.dart';
import '../../core/platform/power_platform_service.dart';
import '../../features/library/application/cover_image_cache_policy.dart';
import '../../core/ui/ui_interaction_coordinator.dart';

export '../../features/library/domain/library_node.dart';
export '../../features/library/domain/library_entry.dart';
export '../../core/media/audio_detail.dart';
export '../../features/library/domain/audio_library_category.dart';
export '../../features/player/domain/audio_effects.dart';
export '../../core/media/card_info_field.dart';
export '../../core/media/dlsite_metadata.dart';
export '../../core/media/music_track.dart';
export '../../features/player/domain/playback_mode.dart';
export '../../features/player/domain/playback_queue.dart';
export '../../features/player/application/playback_session.dart';
export '../../features/player/domain/time_segment_label.dart';
export '../../features/settings/application/settings_state.dart'
    show StartupPage, BottomNavigationStyle, CoverImageResolution;
export '../../features/asmr/domain/asmr_download.dart';
import '../../features/player/application/native_playback_bridge.dart';
import '../../features/player/application/playback_notification_service.dart';
import '../../features/player/application/playback_command_runner.dart';
import '../../core/media/path_matcher.dart';
import '../../features/player/application/system_media_controls_service.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/settings/application/settings_state.dart';
import '../../core/media/subtitle_parser.dart';

part 'audio_provider_persistence.dart';
part 'audio_provider_library.dart';
part 'audio_provider_library_categories.dart';
part 'audio_provider_playback.dart';
part 'audio_provider_playback_sessions.dart';
part 'audio_provider_playback_keepalive.dart';
part 'audio_provider_playback_engine.dart';
part 'audio_provider_notification_covers.dart';
part 'audio_provider_notification_sync.dart';
part 'audio_provider_notification_subtitles.dart';
part 'audio_provider_persistence_sessions.dart';
part 'audio_provider_state.dart';
part 'audio_provider_native_bridge.dart';
part 'audio_provider_queues.dart';

class AudioProvider with ChangeNotifier {
  static const Duration _notificationProgressRefreshInterval = Duration(
    milliseconds: 750,
  );
  static const Duration _multiSessionNotificationRefreshInterval = Duration(
    milliseconds: 700,
  );
  static const Duration _unifiedNotificationDebounceInterval = Duration(
    milliseconds: 90,
  );
  final LibraryFacade _libraryFacade;
  final PlaybackFacade _playbackFacade;
  final TimerFacade _timerFacade;
  final NotificationFacade _notificationFacade;
  final SettingsRepository _settingsRepository;
  late final PlaybackSubtitleService _subtitleService;
  late final AudioPathCoordinator _audioPathCoordinator;
  late final AudioRuntimeCoordinator _runtimeCoordinator;
  late final AppPersistenceCoordinator _persistenceCoordinator;
  late final AudioUiWarmupCoordinator _uiWarmupCoordinator;
  late final PlaybackKeepAliveCoordinator _keepAliveCoordinator;
  final AppLanguage Function() _pageLanguageResolver;

  LibraryFacade get libraryFacade => _libraryFacade;
  PlaybackFacade get playbackFacade => _playbackFacade;
  TimerFacade get timerFacade => _timerFacade;
  NotificationFacade get notificationFacade => _notificationFacade;
  SettingsRepository get settingsRepository => _settingsRepository;
  PlaybackSubtitleService get subtitleService => _subtitleService;
  AudioRuntimeCoordinator get runtimeCoordinator => _runtimeCoordinator;
  AppPersistenceCoordinator get persistenceCoordinator =>
      _persistenceCoordinator;
  AudioUiWarmupCoordinator get uiWarmupCoordinator => _uiWarmupCoordinator;
  PlaybackKeepAliveCoordinator get keepAliveCoordinator =>
      _keepAliveCoordinator;

  PlaybackNotificationService get _notificationService =>
      _notificationFacade.service;
  AudioDatabaseRepository get _audioDatabaseRepository =>
      _libraryFacade.databaseRepository;
  AudioDetailCacheService get _audioDetailCacheService =>
      _libraryFacade.detailCacheService;
  AsmrPlaybackCacheService get _asmrPlaybackCacheService =>
      _playbackFacade.playbackCacheService;
  NativePlaybackRepository get _nativePlaybackRepository =>
      _playbackFacade.nativeRepository;
  PlaybackCommandRunner get _playbackCommandRunner =>
      _playbackFacade.commandRunner;
  PowerPlatformService get _powerPlatformService =>
      _timerFacade.powerPlatformService;
  LibraryService get _libraryService => _libraryFacade.service;
  LibrarySnapshotCacheService get _librarySnapshotCacheService =>
      _libraryFacade.snapshotCacheService;
  CoverArtworkCacheService get _coverArtworkCacheService =>
      _libraryFacade.coverArtworkCacheService;
  PlaybackSessionService get _playbackService => _playbackFacade.service;
  TimerService get _timerService => _timerFacade.service;
  NotificationCoordinatorService get _notificationStateService =>
      _notificationFacade.stateService;
  SystemMediaControlsService get _systemMediaControlsService =>
      _playbackFacade.systemMediaControlsService;

  bool _isInitialized = false;
  bool _settingsInitialized = false;
  bool _libraryInitialized = false;
  bool _playbackInitialized = false;
  bool _notifyListenersQueued = false;
  bool _isDisposed = false;
  bool _isReloadingPersistedState = false;
  Future<void>? _postStartupLibraryMaintenance;

  final Random _random = Random();

  List<MusicTrack> get _library => _libraryService.library;
  Map<String, MusicTrack> get _libraryByPath => _libraryService.libraryByPath;
  Map<String, List<MusicTrack>> get _tracksByGroup =>
      _libraryService.tracksByGroup;
  List<String> get _sortedLibraryTrackPaths =>
      _libraryService.sortedLibraryTrackPaths;
  List<String> get _watchedFolders => _libraryService.watchedFolders;
  List<String> get _watchedLibraries => _libraryService.watchedLibraries;
  Map<String, Set<String>> get _excludedLibraryFolders =>
      _libraryService.excludedLibraryFolders;
  Map<String, Set<String>> get _excludedLibraryTracks =>
      _libraryService.excludedLibraryTracks;
  bool get _isScanning => _libraryService.isScanning;
  bool get _isBackgroundScanning => _libraryService.isBackgroundScanning;
  String get _scanCurrentFolder => _libraryService.scanCurrentFolder;
  int get _scanFoundCount => _libraryService.scanFoundCount;
  int get _scanDuplicateCount => _libraryService.scanDuplicateCount;
  int get _scanFailureCount => _libraryService.scanFailureCount;
  int get _scanGeneration => _libraryService.scanGeneration;
  FolderScanStage get _scanStage => _libraryService.scanStage;
  int get _scanProcessed => _libraryService.scanProcessed;
  int? get _scanTotal => _libraryService.scanTotal;
  Timer? get _scanProgressNotifyTimer =>
      _libraryService.scanProgressNotifyTimer;
  set _scanProgressNotifyTimer(Timer? value) {
    _libraryService.scanProgressNotifyTimer = value;
  }

  Map<String, PlaybackSession> get _sessions => _playbackService.sessions;

  Map<String, String?> get _notificationSubtitleTexts =>
      _notificationStateService.notificationSubtitleTexts;
  Map<String, String> get _notificationSubtitleTrackPaths =>
      _notificationStateService.notificationSubtitleTrackPaths;
  String? get _notificationFocusSessionId =>
      _notificationStateService.notificationFocusSessionId;
  set _notificationFocusSessionId(String? value) {
    _notificationStateService.notificationFocusSessionId = value;
  }

  String? get _unifiedNotificationSyncKey =>
      _notificationStateService.unifiedNotificationSyncKey;
  set _unifiedNotificationSyncKey(String? value) {
    _notificationStateService.unifiedNotificationSyncKey = value;
  }

  Timer? get _notificationProgressRefreshTimer =>
      _notificationStateService.notificationProgressRefreshTimer;
  set _notificationProgressRefreshTimer(Timer? value) {
    _notificationStateService.notificationProgressRefreshTimer = value;
  }

  Timer? get _unifiedNotificationSyncTimer =>
      _notificationStateService.unifiedNotificationSyncTimer;
  set _unifiedNotificationSyncTimer(Timer? value) {
    _notificationStateService.unifiedNotificationSyncTimer = value;
  }

  bool get _unifiedNotificationSyncInFlight =>
      _notificationStateService.unifiedNotificationSyncInFlight;
  set _unifiedNotificationSyncInFlight(bool value) {
    _notificationStateService.unifiedNotificationSyncInFlight = value;
  }

  bool get _unifiedNotificationSyncPending =>
      _notificationStateService.unifiedNotificationSyncPending;
  set _unifiedNotificationSyncPending(bool value) {
    _notificationStateService.unifiedNotificationSyncPending = value;
  }

  bool get _notificationActionRefreshPending =>
      _notificationStateService.notificationActionRefreshPending;

  set _keepAliveSyncDeferred(bool value) {
    _notificationStateService.keepAliveSyncDeferred = value;
  }

  String? get _queuedNotificationRefreshSessionId =>
      _notificationStateService.queuedNotificationRefreshSessionId;
  set _queuedNotificationRefreshSessionId(String? value) {
    _notificationStateService.queuedNotificationRefreshSessionId = value;
  }

  bool get _notificationsDismissedWhilePaused =>
      _notificationStateService.notificationsDismissedWhilePaused;
  set _notificationsDismissedWhilePaused(bool value) {
    _notificationStateService.notificationsDismissedWhilePaused = value;
  }

  Timer? get _notificationActionRefreshTimer =>
      _notificationStateService.notificationActionRefreshTimer;

  Timer? get _notificationActionGuardTimeout =>
      _notificationStateService.notificationActionGuardTimeout;

  String get _converterFormat => _settingsRepository.converterFormat;
  String get _converterBitrate => _settingsRepository.converterBitrate;
  bool get _multiThreadPlaybackEnabled =>
      _settingsRepository.multiThreadPlaybackEnabled;

  bool get _notificationsEnabled => _settingsRepository.notificationsEnabled;
  set _notificationsEnabled(bool value) {
    _settingsRepository.notificationsEnabled = value;
  }

  bool get _showPlaybackCard => _settingsRepository.showPlaybackCard;
  StartupPage get _startupPage => _settingsRepository.startupPage;
  BottomNavigationStyle get _bottomNavigationStyle =>
      _settingsRepository.bottomNavigationStyle;
  bool get _autoPlayAddedSessions => _settingsRepository.autoPlayAddedSessions;

  ContentLanguagePreference get _dlsiteMetadataLanguagePreference =>
      _settingsRepository.dlsiteMetadataLanguage;

  AppLanguage get _dlsiteMetadataLanguage =>
      _dlsiteMetadataLanguagePreference.resolve(_pageLanguageResolver());

  int get _maxCacheBytes => _settingsRepository.maxCacheBytes;

  factory AudioProvider({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notification,
    required SettingsRepository settings,
    AppLanguage Function()? pageLanguageResolver,
    bool deferRuntimeStart = false,
  }) => AudioProvider._(
    library: library,
    playback: playback,
    timer: timer,
    notification: notification,
    settings: settings,
    pageLanguageResolver: pageLanguageResolver,
    skipDisposePersistence: false,
    startNativeRuntime: !deferRuntimeStart,
  );

  @visibleForTesting
  factory AudioProvider.test({
    LibraryFacade? library,
    PlaybackFacade? playback,
    TimerFacade? timer,
    NotificationFacade? notification,
    SettingsRepository? settings,
    PlaybackNotificationService? notificationService,
    AudioDatabaseRepository? audioDatabaseRepository,
    AudioDetailRepository? audioDetailRepository,
    AudioDetailCacheService? audioDetailCacheService,
    CoverArtworkCacheService? coverArtworkCacheService,
    DlsiteMetadataService? dlsiteMetadataService,
    AsmrMetadataService? asmrMetadataService,
    AsmrPlaybackCacheService asmrPlaybackCacheService =
        const AsmrPlaybackCacheService(),
    NativePlaybackRepository? nativePlaybackRepository,
    PlaybackCommandRunner playbackCommandRunner = const PlaybackCommandRunner(),
    PowerPlatformService? powerPlatformService,
    LibraryService? libraryService,
    LibrarySnapshotCacheService? librarySnapshotCacheService,
    PlaybackSessionService? playbackService,
    TimerService? timerService,
    NotificationCoordinatorService? notificationStateService,
    SettingsRepository? settingsRepository,
    SystemMediaControlsService? systemMediaControlsService,
    bool skipPersistence = true,
    bool startRuntime = false,
    AppLanguage Function()? pageLanguageResolver,
  }) {
    final resolvedAudioDatabaseRepository =
        audioDatabaseRepository ?? AudioDatabaseRepository();
    final resolvedAudioDetailCacheService =
        audioDetailCacheService ??
        AudioDetailCacheService(
          repository:
              audioDetailRepository ??
              AudioDetailRepository(
                databaseRepository: resolvedAudioDatabaseRepository,
              ),
        );
    final resolvedLibraryService = libraryService ?? LibraryService();
    final resolvedLibrary =
        library ??
        LibraryFacade.create(
          databaseRepository: resolvedAudioDatabaseRepository,
          detailCacheService: resolvedAudioDetailCacheService,
          metadataService: dlsiteMetadataService,
          asmrMetadataService: asmrMetadataService,
          service: resolvedLibraryService,
          snapshotCacheService: librarySnapshotCacheService,
          coverArtworkCacheService: coverArtworkCacheService,
        );
    final resolvedPlayback =
        playback ??
        PlaybackFacade.create(
          databaseRepository: resolvedLibrary.databaseRepository,
          nativeRepository: nativePlaybackRepository,
          commandRunner: playbackCommandRunner,
          playbackCacheService: asmrPlaybackCacheService,
          service: playbackService,
          systemMediaControlsService: systemMediaControlsService,
        );
    return AudioProvider._(
      library: resolvedLibrary,
      playback: resolvedPlayback,
      timer:
          timer ??
          TimerFacade.create(
            service: timerService,
            powerPlatformService: powerPlatformService,
          ),
      notification:
          notification ??
          NotificationFacade.create(
            service: notificationService ?? PlaybackNotificationService(),
            stateService: notificationStateService,
          ),
      settings: settings ?? settingsRepository ?? SettingsRepository(),
      pageLanguageResolver: pageLanguageResolver,
      skipDisposePersistence: skipPersistence,
      startNativeRuntime: startRuntime,
    );
  }

  AudioProvider._({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notification,
    required SettingsRepository settings,
    AppLanguage Function()? pageLanguageResolver,
    required bool skipDisposePersistence,
    required bool startNativeRuntime,
  }) : _libraryFacade = library,
       _playbackFacade = playback,
       _timerFacade = timer,
       _notificationFacade = notification,
       _settingsRepository = settings,
       _pageLanguageResolver = pageLanguageResolver ?? (() => AppLanguage.zh) {
    _audioPathCoordinator = AudioPathCoordinator(
      library: _libraryFacade,
      playback: _playbackFacade,
    );
    _subtitleService = PlaybackSubtitleService(
      trackResolver: _libraryFacade.trackByPath,
      onTrackLoaded: _handleSubtitleTrackLoaded,
    );
    _uiWarmupCoordinator = AudioUiWarmupCoordinator(
      library: _libraryFacade,
      playback: _playbackFacade,
      notifications: _notificationFacade,
      subtitles: _subtitleService,
    );
    _keepAliveCoordinator = PlaybackKeepAliveCoordinator(
      playback: _playbackFacade,
      timer: _timerFacade,
      notifications: _notificationFacade,
      settings: _settingsRepository,
      enterBackgroundWarmup: _uiWarmupCoordinator.enterBackground,
      resumeForegroundWarmup: _uiWarmupCoordinator.resumeForeground,
    );
    _libraryFacade.configurePersistence(enabled: !skipDisposePersistence);
    _playbackFacade.configurePersistence(enabled: !skipDisposePersistence);
    _libraryFacade.attachTrackRemovalHandler(_handleLibraryTracksRemoved);
    _libraryFacade.attachCoverChangeHandler(() {
      _playbackService.markActiveSessionsDirty();
      _syncNotificationState();
      _notifyLibraryAndPlaybackChanged();
    });
    _playbackFacade.attachSessionDefaults(
      autoPlayAddedSessions: () => _autoPlayAddedSessions,
    );
    _playbackFacade.attachPersistenceRuntime(
      trackByPath: _libraryFacade.trackByPath,
      recordPlaybackProgress: () => _settingsRepository.recordPlaybackProgress,
      restoreRuntime: _restorePersistedPlaybackRuntime,
      updatePlaybackHistory: _libraryFacade.updatePlaybackHistory,
      onFocusChanged: (sessionId) {
        _notificationFocusSessionId = sessionId;
      },
    );
    _playbackFacade.attachSessionRuntime(
      onSessionRegistered: (session) {
        _notificationsDismissedWhilePaused = false;
        _notificationFocusSessionId = session.id;
        _syncKeepCpuAwake();
        _syncNotificationState();
        _notifyPlaybackChanged();
      },
      onSessionsRemoved: (sessions) {
        for (final session in sessions) {
          _clearNotificationSubtitleForSession(session.id);
          if (_notificationFocusSessionId == session.id) {
            _notificationFocusSessionId = null;
          }
        }
      },
      onSessionsReordered: () {
        _syncNotificationState();
        _notifyPlaybackChanged();
        _playbackFacade.scheduleSessionOrderPersistence();
      },
      onSessionStateChanged: _notifyPlaybackChanged,
      onRuntimeStateChanged: () {
        _syncKeepCpuAwake();
        _syncNotificationState();
      },
      onSessionPositionChanged: (session, position) {
        if (!_isNotificationFocusedSessionId(session.id)) return;
        final changed = _refreshNotificationSubtitleForSession(
          session,
          position: position,
          syncNotification: false,
        );
        if (!changed) return;
        _scheduleFocusedNotificationRefresh(session.id, immediate: true);
      },
      onSessionCompleted: _handleSessionCompleted,
      onSessionDurationChanged: (sessionId) {
        _scheduleFocusedNotificationRefresh(sessionId);
      },
      onSessionSettingsChanged: () {
        _notifyPlaybackChanged();
        _syncNotificationState();
      },
    );
    _playbackFacade.attachPlaybackQueueSynchronizer(_syncPlaybackQueueSession);
    _playbackFacade.attachPlaybackCommands(
      prepareSession: _prepareAndPlay,
      pauseSession: _pauseSessionPlayback,
      startSession: _startSessionPlayback,
      resolveAdvance: (session, {required forward}) =>
          _nextPathFor(session, forward: forward),
      hasAdjacent: (session, {required forward}) =>
          _hasAdjacentPathFor(session, forward: forward),
    );
    _playbackFacade.attachLoopModeSynchronizer((session, mode) {
      return _nativePlaybackRepository.setRepeatOne(
        session.id,
        mode == SessionLoopMode.single,
        queue: _nativePlaybackQueueFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        queueStartIndex: _nativePlaybackQueueStartIndexFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        repeatAll: mode != SessionLoopMode.single,
        shuffle: mode.isShuffle,
      );
    });
    _timerFacade.attachRuntime(
      hasPlayingSession: () => _hasPlayingSession,
      sessions: () => _sessions.values,
      pauseSession: _pauseSessionPlayback,
      activateAudioSession: _activateAudioSessionForPlayback,
      resumeSession: (session) =>
          _startSessionPlayback(session, shouldStartTriggerCountdown: false),
      onStateChanged: () {
        _syncKeepCpuAwake();
        _notifyListeners();
      },
      onRuntimeRestored: () {
        _syncNotificationState();
        _syncKeepCpuAwake();
        _notifyListeners();
      },
      applyFadeMultiplier: (multiplier) {
        for (final session in _sessions.values) {
          if (session.state.playing) {
            unawaited(
              _nativePlaybackRepository.setFadeMultiplier(
                session.id,
                multiplier,
              ),
            );
          }
        }
      },
    );
    _notificationFacade.attachRuntime(
      undismissNotifications: _nativePlaybackRepository.undismissNotifications,
      onNotificationsRestored: () {
        _syncNotificationState(immediateUnifiedSync: true);
        _notifyNotificationChanged();
      },
    );
    _notificationFacade.attachActions(
      playback: _playbackFacade,
      resolveSession: _resolveNotificationSession,
      resolveActionSession: () => _notificationActionSession,
      resumeSession: _resumeNotificationSession,
      multiThreadPlaybackEnabled: () => _multiThreadPlaybackEnabled,
      setFocusSessionId: (sessionId) {
        _notificationFocusSessionId = sessionId;
      },
      notify: _notifyListeners,
      syncKeepAlive: _syncKeepCpuAwake,
      syncNotificationState: () {
        _syncNotificationState(immediateUnifiedSync: true);
      },
      hasPlaybackToKeepAlive: () => _hasPlaybackToKeepAlive,
      clearUnifiedNotifications: _clearUnifiedPlaybackNotificationsOnPlatform,
      stopPlaybackKeepAlive: _stopPlaybackKeepAliveOnPlatform,
      preferredSessionId: () => _preferredSingleSessionId,
      notifyNotificationChanged: _notifyNotificationChanged,
    );
    _libraryFacade.attachCoverArtworkCacheService(
      () => CoverArtworkCacheService(
        libraryService: _libraryService,
        databaseRepository: _audioDatabaseRepository,
        audioDetailCacheService: _audioDetailCacheService,
        isActiveCoverKey: _isActiveCoverKey,
        onActiveCoverChanged: () {
          _syncNotificationState();
          _notifyNotificationChanged();
        },
      ),
    );
    _persistenceCoordinator = AppPersistenceCoordinator(
      library: _libraryFacade,
      playback: _playbackFacade,
      settings: _settingsRepository,
      timer: _timerFacade,
      beforeReset: _beforePersistenceReset,
      afterReset: _afterPersistenceReset,
      onSettingsLoaded: _onPersistedSettingsLoaded,
      onLibraryLoaded: _onPersistedLibraryLoaded,
      onPlaybackLoaded: _onPersistedPlaybackLoaded,
      onLoadCompleted: _onPersistedLoadCompleted,
    );
    _runtimeCoordinator = AudioRuntimeCoordinator(
      snapshots: _nativePlaybackRepository.snapshots,
      progressUpdates: _nativePlaybackRepository.progressUpdates,
      startListening: _nativePlaybackRepository.startListening,
      stopListening: _nativePlaybackRepository.stopListening,
      onSnapshot: _handleNativePlaybackSnapshot,
      onProgress: _playbackFacade.applyNativeProgress,
      onStart: _persistenceCoordinator.loadPersistedState,
      onEnterBackground: syncKeepAliveBeforeBackground,
      onResumeForeground: () async {
        syncKeepAliveAfterForegroundResume();
        _notificationFacade.resyncAfterForegroundResume();
        await _timerFacade.syncRuntimeFromNative();
        _timerFacade.retryOverdueAutoResume();
      },
      onDispose: _disposeOwnedServices,
    );
    if (startNativeRuntime) {
      unawaited(_runtimeCoordinator.start());
    }
    _syncAllStateSlices();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _persistenceCoordinator.dispose();
    _timerService.countdownTimer?.cancel();
    _timerService.autoResumeTimer?.cancel();
    _playbackFacade.cancelScheduledPersistence();
    _scanProgressNotifyTimer?.cancel();
    unawaited(_uiWarmupCoordinator.shutdown());
    _notificationProgressRefreshTimer?.cancel();
    _unifiedNotificationSyncTimer?.cancel();
    _notificationActionRefreshTimer?.cancel();
    _notificationActionGuardTimeout?.cancel();
    unawaited(_keepAliveCoordinator.shutdown());
    unawaited(_runtimeCoordinator.dispose());
    super.dispose();
  }

  Future<void> _disposeOwnedServices() async {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    await _libraryFacade.dispose();
    await _playbackFacade.dispose();
    await _timerFacade.dispose();
    await _notificationFacade.dispose();
    await _settingsRepository.dispose();
  }

  void _notifyListeners() {
    _syncAllStateSlices();
    _scheduleNotifyListeners();
  }

  void _notifyLibraryChanged() {
    _syncLibraryStateSlice();
    _scheduleNotifyListeners();
  }

  void _notifyLibraryAndPlaybackChanged() {
    _syncLibraryStateSlice();
    _syncPlaybackStateSlice();
    _syncNotificationStateSlice();
    _scheduleNotifyListeners();
  }

  void _notifyPlaybackChanged() {
    _playbackService.markSessionStateDirty();
    _syncPlaybackStateSlice();
    _syncNotificationStateSlice();
    _scheduleNotifyListeners();
  }

  void _notifySettingsChanged() {
    _syncSettingsStateSlice();
    _syncPlaybackStateSlice();
    _syncNotificationStateSlice();
    _scheduleNotifyListeners();
  }

  void _notifyNotificationChanged() {
    _syncNotificationStateSlice();
    _syncPlaybackStateSlice();
    _scheduleNotifyListeners();
  }

  void _notifyPresentationListeners() {
    _scheduleNotifyListeners();
  }

  void _scheduleNotifyListeners() {
    if (_isDisposed || _notifyListenersQueued) return;
    _notifyListenersQueued = true;
    scheduleMicrotask(() {
      _notifyListenersQueued = false;
      if (_isDisposed) return;
      notifyListeners();
    });
  }

  Stream<LibraryState> get libraryStateStream => _libraryService.slice.stream;
  Stream<PlaybackStateSliceData> get playbackStateStream =>
      _playbackService.slice.stream;
  Stream<TimerStateSliceData> get timerStateStream =>
      _timerService.slice.stream;
  Stream<SettingsState> get settingsStateStream =>
      _settingsRepository.slice.stream;
  Stream<NotificationState> get notificationStateStream =>
      _notificationStateService.slice.stream;

  void _syncAllStateSlices() {
    _syncLibraryStateSlice();
    _syncPlaybackStateSlice();
    _syncTimerStateSlice();
    _syncSettingsStateSlice();
    _syncNotificationStateSlice();
  }

  void _syncLibraryStateSlice({bool preserveSliceInitialized = false}) {
    _libraryService.syncSlice(
      isInitialized:
          _libraryInitialized ||
          _isInitialized ||
          (preserveSliceInitialized &&
              _libraryService.slice.state.isInitialized),
      detailRevision: _audioDetailCacheService.revision,
      treeSnapshotRevision: _librarySnapshotCacheService.cardSnapshotRevision,
      categorySnapshotRevision:
          _librarySnapshotCacheService.categorySnapshotRevision,
    );
    unawaited(_ensureLibraryCardSnapshot());
  }

  void _syncPlaybackStateSlice() {
    _playbackService.syncSlice(
      activeSessions: activeSessions,
      playingSessionCount: playingSessionCount,
      focusedSessionId: _notificationFocusSessionId,
      multiThreadPlaybackEnabled: _multiThreadPlaybackEnabled,
      coverGeneration: _coverArtworkCacheService.generation,
      isInitialized: _playbackInitialized || _isInitialized,
    );
  }

  void _syncTimerStateSlice() {
    _timerService.syncSlice(
      isInitialized: _playbackInitialized || _isInitialized,
    );
  }

  void _syncSettingsStateSlice() {
    _settingsRepository.syncSlice(
      isInitialized: _settingsInitialized || _isInitialized,
    );
    AppInteractionFeedback.hapticFeedbackEnabled =
        _settingsRepository.hapticFeedbackEnabled;
  }

  void _syncNotificationStateSlice() {
    _notificationStateService.syncSlice(
      activeQueueLength: activeSessions.length,
    );
  }

  int get coverGeneration => _coverArtworkCacheService.generation;

  void _clearResolvedCoverPaths() {
    _coverArtworkCacheService.invalidateAll();
  }
}
