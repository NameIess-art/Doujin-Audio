import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audio_detail.dart';
import '../models/dlsite_metadata.dart';
import '../models/library_node.dart';
import '../models/music_track.dart';
import '../models/playback_mode.dart';
import '../models/playback_session.dart';
import '../services/audio_database_repository.dart';
import '../services/audio_detail_repository.dart';
import '../services/audio_state_services.dart';
import '../services/app_database.dart';
import '../services/dlsite_metadata_service.dart';
import '../services/library_organizer.dart';
import '../services/native_playback_repository.dart';
import '../services/playback_queue_resolver.dart';
import '../services/platform_channels.dart';
import '../services/timer_runtime_calculator.dart';
import '../services/warmup_scheduler.dart';

export '../models/library_node.dart';
export '../models/audio_detail.dart';
export '../models/dlsite_metadata.dart';
export '../models/music_track.dart';
export '../models/playback_mode.dart';
export '../models/playback_session.dart';
import '../services/native_playback_bridge.dart';
import '../services/playback_notification_service.dart';
import '../services/playback_command_runner.dart';
import '../services/path_matcher.dart';
import '../services/subtitle_parser.dart';

part 'audio_provider_notifications.dart';
part 'audio_provider_persistence.dart';
part 'audio_provider_library.dart';
part 'audio_provider_audio_details.dart';
part 'audio_provider_playback.dart';
part 'audio_provider_playback_sessions.dart';
part 'audio_provider_playback_timer.dart';
part 'audio_provider_playback_keepalive.dart';
part 'audio_provider_playback_engine.dart';
part 'audio_provider_notification_covers.dart';
part 'audio_provider_notification_sync.dart';
part 'audio_provider_notification_subtitles.dart';
part 'audio_provider_persistence_sessions.dart';
part 'audio_provider_persistence_timer.dart';
part 'audio_provider_state.dart';
part 'audio_provider_native_bridge.dart';
part 'audio_provider_controllers.dart';
part 'audio_provider_library_covers.dart';
part 'audio_provider_warmup.dart';

const _kLibraryKey = 'library_v1';
const _kSessionsKey = 'sessions_v1';
const _kGroupOrderKey = 'group_order_v1';
const _kLibraryNodeOrderKey = 'library_node_order_v1';
const _kSessionOrderKey = 'session_order_v1';
const _kWatchedFoldersKey = 'watched_folders_v1';
const _kWatchedLibrariesKey = 'watched_libraries_v1';
const _kLibraryExclusionsKey = 'library_exclusions_v1';
const _kTimerSettingsKey = 'timer_settings_v1';
const _kTimerRuntimeKey = 'timer_runtime_v1';
const _kConverterSettingsKey = 'converter_settings_v1';
const _kPlaybackSettingsKey = 'playback_settings_v1';

class AudioProvider with ChangeNotifier {
  static const Set<String> _supportedImageExtensions = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
  };
  static const Duration _notificationProgressRefreshInterval = Duration(
    milliseconds: 750,
  );
  static const Duration _multiSessionNotificationRefreshInterval = Duration(
    milliseconds: 700,
  );
  static const Duration _unifiedNotificationDebounceInterval = Duration(
    milliseconds: 90,
  );
  static const MethodChannel _powerChannel = MethodChannel(PowerChannel.name);
  static const MethodChannel _fileCacheChannel = MethodChannel(
    FileCacheChannel.name,
  );
  final PlaybackNotificationService _notificationService;
  final AudioDatabaseRepository _audioDatabaseRepository;
  final AudioDetailRepository _audioDetailRepository;
  final DlsiteMetadataService _dlsiteMetadataService;
  final NativePlaybackRepository _nativePlaybackRepository;
  final PlaybackCommandRunner _playbackCommandRunner;
  final LibraryService _libraryService;
  final PlaybackSessionService _playbackService;
  final TimerService _timerService;
  final NotificationCoordinatorService _notificationStateService;
  final SettingsRepository _settingsRepository;
  final bool _skipDisposePersistence;
  SharedPreferences? _cachedPrefs;

  static const List<String> converterFormats = [
    'mp3',
    'flac',
    'wav',
    'aac',
    'ogg',
  ];
  static const List<String> converterBitrates = [
    '128k',
    '192k',
    '256k',
    '320k',
  ];

  int _sessionSeed = 0;
  bool _isInitialized = false;
  final ValueNotifier<int?> _scrollToTopTabNotifier = ValueNotifier<int?>(null);
  ValueListenable<int?> get scrollToTopTabListenable => _scrollToTopTabNotifier;
  final ValueNotifier<String?> _carouselSnapNotifier = ValueNotifier<String?>(
    null,
  );
  ValueListenable<String?> get carouselSnapListenable => _carouselSnapNotifier;

  void requestCarouselSnapTo(String sessionId) {
    _carouselSnapNotifier.value = sessionId;
  }

  final Random _random = Random();

  StreamSubscription<NativePlaybackSnapshot>? _nativePlaybackSubscription;

  late final LibraryController libraryController;
  late final PlaybackSessionController playbackSessionController;
  late final TimerController timerController;
  late final NotificationCoordinator notificationCoordinator;

  List<MusicTrack> get _library => _libraryService.library;
  Map<String, MusicTrack> get _libraryByPath => _libraryService.libraryByPath;
  Map<String, List<MusicTrack>> get _tracksByGroup =>
      _libraryService.tracksByGroup;
  List<MusicTrack> get _sortedLibraryTracks =>
      _libraryService.sortedLibraryTracks;
  set _sortedLibraryTracks(List<MusicTrack> value) {
    _libraryService.sortedLibraryTracks = value;
  }

  List<String> get _sortedLibraryTrackPaths =>
      _libraryService.sortedLibraryTrackPaths;
  set _sortedLibraryTrackPaths(List<String> value) {
    _libraryService.sortedLibraryTrackPaths = value;
  }

  List<String> get _groupOrder => _libraryService.groupOrder;
  Set<String> get _groupOrderSet => _libraryService.groupOrderSet;
  List<String> get _libraryNodeOrder => _libraryService.libraryNodeOrder;
  List<String> get _watchedFolders => _libraryService.watchedFolders;
  List<String> get _watchedLibraries => _libraryService.watchedLibraries;
  Map<String, Set<String>> get _excludedLibraryFolders =>
      _libraryService.excludedLibraryFolders;
  Map<String, Set<String>> get _excludedLibraryTracks =>
      _libraryService.excludedLibraryTracks;
  bool get _isScanning => _libraryService.isScanning;
  set _isScanning(bool value) => _libraryService.isScanning = value;
  bool get _isBackgroundScanning => _libraryService.isBackgroundScanning;
  set _isBackgroundScanning(bool value) {
    _libraryService.isBackgroundScanning = value;
  }

  String get _scanCurrentFolder => _libraryService.scanCurrentFolder;
  set _scanCurrentFolder(String value) =>
      _libraryService.scanCurrentFolder = value;
  int get _scanFoundCount => _libraryService.scanFoundCount;
  set _scanFoundCount(int value) => _libraryService.scanFoundCount = value;
  int get _scanDuplicateCount => _libraryService.scanDuplicateCount;
  set _scanDuplicateCount(int value) =>
      _libraryService.scanDuplicateCount = value;
  int get _scanFailureCount => _libraryService.scanFailureCount;
  set _scanFailureCount(int value) => _libraryService.scanFailureCount = value;
  bool get _libraryTreeDirty => _libraryService.libraryTreeDirty;
  set _libraryTreeDirty(bool value) => _libraryService.libraryTreeDirty = value;
  List<LibraryNode> get _cachedLibraryTree => _libraryService.cachedLibraryTree;
  set _cachedLibraryTree(List<LibraryNode> value) {
    _libraryService.cachedLibraryTree = value;
  }

  int get _cachedLibraryLeafFolderCount =>
      _libraryService.cachedLibraryLeafFolderCount;
  set _cachedLibraryLeafFolderCount(int value) {
    _libraryService.cachedLibraryLeafFolderCount = value;
  }

  int get _libraryBatchDepth => _libraryService.libraryBatchDepth;
  set _libraryBatchDepth(int value) =>
      _libraryService.libraryBatchDepth = value;
  bool get _libraryBatchChanged => _libraryService.libraryBatchChanged;
  set _libraryBatchChanged(bool value) {
    _libraryService.libraryBatchChanged = value;
  }

  bool get _libraryBatchChangedGroupOrder =>
      _libraryService.libraryBatchChangedGroupOrder;
  set _libraryBatchChangedGroupOrder(bool value) {
    _libraryService.libraryBatchChangedGroupOrder = value;
  }

  List<MusicTrack> get _libraryBatchPersistTracks =>
      _libraryService.libraryBatchPersistTracks;
  Timer? get _scanProgressNotifyTimer =>
      _libraryService.scanProgressNotifyTimer;
  set _scanProgressNotifyTimer(Timer? value) {
    _libraryService.scanProgressNotifyTimer = value;
  }

  Map<String, PlaybackSession> get _sessions => _playbackService.sessions;
  List<String> get _sessionOrder => _playbackService.sessionOrder;

  Future<void> get _sessionPreparationQueue =>
      _playbackService.sessionPreparationQueue;

  Timer? get _saveSessionStateTimer => _playbackService.saveSessionStateTimer;
  set _saveSessionStateTimer(Timer? value) {
    _playbackService.saveSessionStateTimer = value;
  }

  Timer? get _saveSessionOrderTimer => _playbackService.saveSessionOrderTimer;
  set _saveSessionOrderTimer(Timer? value) {
    _playbackService.saveSessionOrderTimer = value;
  }

  Map<String, Future<SubtitleTrack?>> get _subtitleTrackFutures =>
      _notificationStateService.subtitleTrackFutures;
  Map<String, SubtitleTrack?> get _subtitleTracks =>
      _notificationStateService.subtitleTracks;
  Map<String, Future<SubtitleTrack?>> get _subtitleTrackResultFutures =>
      _notificationStateService.subtitleTrackResultFutures;
  Map<String, String?> get _notificationSubtitleTexts =>
      _notificationStateService.notificationSubtitleTexts;
  Map<String, String> get _notificationSubtitleTrackPaths =>
      _notificationStateService.notificationSubtitleTrackPaths;
  Map<String, Future<String?>> get _coverPathFutures =>
      _notificationStateService.coverPathFutures;
  Map<String, String?> get _resolvedCoverPaths =>
      _notificationStateService.resolvedCoverPaths;
  Map<String, Future<String?>> get _resolvedCoverPathFutures =>
      _notificationStateService.resolvedCoverPathFutures;
  Map<String, Future<String?>> get _notificationCoverPathFutures =>
      _notificationStateService.notificationCoverPathFutures;
  Map<String, String?> get _resolvedNotificationCoverPaths =>
      _notificationStateService.resolvedNotificationCoverPaths;
  Map<String, Future<String?>> get _resolvedNotificationCoverPathFutures =>
      _notificationStateService.resolvedNotificationCoverPathFutures;
  Set<String> get _notificationCoverSearchMisses =>
      _notificationStateService.notificationCoverSearchMisses;
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

  Timer? get _deferredWarmupTimer =>
      _notificationStateService.deferredWarmupTimer;
  set _deferredWarmupTimer(Timer? value) {
    _notificationStateService.deferredWarmupTimer = value;
  }

  WarmupScheduler get _warmupScheduler =>
      _notificationStateService.warmupScheduler;
  int get _warmupGeneration => _notificationStateService.warmupGeneration;
  set _warmupGeneration(int value) {
    _notificationStateService.warmupGeneration = value;
  }

  Timer? get _notificationActionRefreshTimer =>
      _notificationStateService.notificationActionRefreshTimer;

  Timer? get _notificationActionGuardTimeout =>
      _notificationStateService.notificationActionGuardTimeout;

  String get _converterFormat => _settingsRepository.converterFormat;
  set _converterFormat(String value) =>
      _settingsRepository.converterFormat = value;
  String get _converterBitrate => _settingsRepository.converterBitrate;
  set _converterBitrate(String value) =>
      _settingsRepository.converterBitrate = value;
  bool get _multiThreadPlaybackEnabled =>
      _settingsRepository.multiThreadPlaybackEnabled;
  set _multiThreadPlaybackEnabled(bool value) {
    _settingsRepository.multiThreadPlaybackEnabled = value;
  }

  bool get _notificationsEnabled => _settingsRepository.notificationsEnabled;
  set _notificationsEnabled(bool value) {
    _settingsRepository.notificationsEnabled = value;
  }

  bool get _showPlaybackCard => _settingsRepository.showPlaybackCard;
  set _showPlaybackCard(bool value) =>
      _settingsRepository.showPlaybackCard = value;
  bool get _autoPlayAddedSessions => _settingsRepository.autoPlayAddedSessions;
  set _autoPlayAddedSessions(bool value) {
    _settingsRepository.autoPlayAddedSessions = value;
  }

  bool get _isPageTransitioning => _settingsRepository.isPageTransitioning;
  set _isPageTransitioning(bool value) {
    _settingsRepository.isPageTransitioning = value;
  }

  bool get _keepCpuAwake => _settingsRepository.keepCpuAwake;
  set _keepCpuAwake(bool value) => _settingsRepository.keepCpuAwake = value;
  bool get _keepAliveHasPlayback => _settingsRepository.keepAliveHasPlayback;
  set _keepAliveHasPlayback(bool value) {
    _settingsRepository.keepAliveHasPlayback = value;
  }

  bool get _keepAliveHasTimer => _settingsRepository.keepAliveHasTimer;
  set _keepAliveHasTimer(bool value) =>
      _settingsRepository.keepAliveHasTimer = value;
  bool get _keepAliveUsesUnifiedNotifications =>
      _settingsRepository.keepAliveUsesUnifiedNotifications;
  set _keepAliveUsesUnifiedNotifications(bool value) {
    _settingsRepository.keepAliveUsesUnifiedNotifications = value;
  }

  bool get _keepAliveKeepsForegroundService =>
      _settingsRepository.keepAliveKeepsForegroundService;
  set _keepAliveKeepsForegroundService(bool value) {
    _settingsRepository.keepAliveKeepsForegroundService = value;
  }

  TimerMode? get _timerMode => _timerService.timerMode;
  set _timerMode(TimerMode? value) => _timerService.timerMode = value;
  Duration? get _timerDuration => _timerService.timerDuration;
  set _timerDuration(Duration? value) => _timerService.timerDuration = value;
  bool get _timerActive => _timerService.timerActive;
  set _timerActive(bool value) => _timerService.timerActive = value;
  Duration? get _timerRemaining => _timerService.timerRemaining;
  set _timerRemaining(Duration? value) => _timerService.timerRemaining = value;
  DateTime? get _timerEndsAt => _timerService.timerEndsAt;
  set _timerEndsAt(DateTime? value) => _timerService.timerEndsAt = value;
  Timer? get _countdownTimer => _timerService.countdownTimer;
  set _countdownTimer(Timer? value) => _timerService.countdownTimer = value;
  bool get _timerWaitingForPlayback => _timerService.timerWaitingForPlayback;
  set _timerWaitingForPlayback(bool value) {
    _timerService.timerWaitingForPlayback = value;
  }

  TimerMode get _timerDraftMode => _timerService.timerDraftMode;
  set _timerDraftMode(TimerMode value) => _timerService.timerDraftMode = value;
  Duration get _timerDraftDuration => _timerService.timerDraftDuration;
  set _timerDraftDuration(Duration value) {
    _timerService.timerDraftDuration = value;
  }

  int get _timerGeneration => _timerService.timerGeneration;
  set _timerGeneration(int value) => _timerService.timerGeneration = value;
  List<String> get _pausedByTimerSessionIds =>
      _timerService.pausedByTimerSessionIds;
  bool get _autoResumeEnabled => _timerService.autoResumeEnabled;
  set _autoResumeEnabled(bool value) => _timerService.autoResumeEnabled = value;
  int get _autoResumeHour => _timerService.autoResumeHour;
  set _autoResumeHour(int value) => _timerService.autoResumeHour = value;
  int get _autoResumeMinute => _timerService.autoResumeMinute;
  set _autoResumeMinute(int value) => _timerService.autoResumeMinute = value;
  Timer? get _autoResumeTimer => _timerService.autoResumeTimer;
  set _autoResumeTimer(Timer? value) => _timerService.autoResumeTimer = value;
  DateTime? get _autoResumeAt => _timerService.autoResumeAt;
  set _autoResumeAt(DateTime? value) => _timerService.autoResumeAt = value;

  void triggerScrollToTop(int index) {
    _scrollToTopTabNotifier.value = index;
    // Reset to null in the next frame so it can be triggered again with the same index
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollToTopTabNotifier.value != null) {
        _scrollToTopTabNotifier.value = null;
      }
    });
  }

  AudioProvider({
    required PlaybackNotificationService notificationService,
    AudioDatabaseRepository? audioDatabaseRepository,
    AudioDetailRepository? audioDetailRepository,
    DlsiteMetadataService? dlsiteMetadataService,
    NativePlaybackRepository? nativePlaybackRepository,
    PlaybackCommandRunner playbackCommandRunner = const PlaybackCommandRunner(),
    LibraryService? libraryService,
    PlaybackSessionService? playbackService,
    TimerService? timerService,
    NotificationCoordinatorService? notificationStateService,
    SettingsRepository? settingsRepository,
  }) : _notificationService = notificationService,
       _audioDatabaseRepository =
           audioDatabaseRepository ?? AudioDatabaseRepository(),
       _audioDetailRepository =
           audioDetailRepository ??
           AudioDetailRepository(
             databaseRepository:
                 audioDatabaseRepository ?? AudioDatabaseRepository(),
           ),
       _dlsiteMetadataService =
           dlsiteMetadataService ?? DlsiteMetadataService(),
       _nativePlaybackRepository =
           nativePlaybackRepository ?? NativePlaybackRepository(),
       _playbackCommandRunner = playbackCommandRunner,
       _libraryService = libraryService ?? LibraryService(),
       _playbackService = playbackService ?? PlaybackSessionService(),
       _timerService = timerService ?? TimerService(),
       _notificationStateService =
           notificationStateService ?? NotificationCoordinatorService(),
       _settingsRepository = settingsRepository ?? SettingsRepository(),
       _skipDisposePersistence = false {
    _initializeControllers();
    _nativePlaybackRepository.startListening();
    _nativePlaybackSubscription = _nativePlaybackRepository.snapshots.listen(
      _handleNativePlaybackSnapshot,
    );
    _bindNotificationHandler();
    _syncAllStateSlices();
    _loadData();
  }

  @visibleForTesting
  AudioProvider.test({
    required PlaybackNotificationService notificationService,
    AudioDatabaseRepository? audioDatabaseRepository,
    AudioDetailRepository? audioDetailRepository,
    DlsiteMetadataService? dlsiteMetadataService,
    NativePlaybackRepository? nativePlaybackRepository,
    PlaybackCommandRunner playbackCommandRunner = const PlaybackCommandRunner(),
    LibraryService? libraryService,
    PlaybackSessionService? playbackService,
    TimerService? timerService,
    NotificationCoordinatorService? notificationStateService,
    SettingsRepository? settingsRepository,
  }) : _notificationService = notificationService,
       _audioDatabaseRepository =
           audioDatabaseRepository ?? AudioDatabaseRepository(),
       _audioDetailRepository =
           audioDetailRepository ??
           AudioDetailRepository(
             databaseRepository:
                 audioDatabaseRepository ?? AudioDatabaseRepository(),
           ),
       _dlsiteMetadataService =
           dlsiteMetadataService ?? DlsiteMetadataService(),
       _nativePlaybackRepository =
           nativePlaybackRepository ?? NativePlaybackRepository(),
       _playbackCommandRunner = playbackCommandRunner,
       _libraryService = libraryService ?? LibraryService(),
       _playbackService = playbackService ?? PlaybackSessionService(),
       _timerService = timerService ?? TimerService(),
       _notificationStateService =
           notificationStateService ?? NotificationCoordinatorService(),
       _settingsRepository = settingsRepository ?? SettingsRepository(),
       _skipDisposePersistence = true {
    _initializeControllers();
    _syncAllStateSlices();
  }

  void _initializeControllers() {
    libraryController = LibraryController(
      beginBatch: beginLibraryBatch,
      endBatch: ({bool notify = true}) => endLibraryBatch(notify: notify),
      setScanning: setScanning,
      setScanProgress:
          ({
            String? currentFolder,
            int? foundCount,
            int? duplicateCount,
            int? failureCount,
          }) => setScanProgress(
            currentFolder: currentFolder,
            foundCount: foundCount,
            duplicateCount: duplicateCount,
            failureCount: failureCount,
          ),
      addTracks:
          (
            List<MusicTrack> tracks, {
            bool notify = true,
            bool persist = true,
          }) => addTracks(tracks, notify: notify, persist: persist),
    );
    playbackSessionController = PlaybackSessionController(
      spawn: (MusicTrack track, {bool? autoPlay}) =>
          spawnSession(track, autoPlay: autoPlay),
      toggle: toggleSessionPlayPause,
      pauseAll: pauseAllSessions,
      clearAll: clearAllSessions,
    );
    timerController = TimerController(
      configure: configureTimer,
      startCountdown: startCountdown,
      cancel: cancelTimer,
      setAutoResume: setAutoResume,
    );
    notificationCoordinator = NotificationCoordinator(
      resyncAfterResume: resyncNotificationsAfterResume,
      restoreAfterSystemClear: restoreNotificationsAfterSystemClear,
      dismissAfterPauseAll: dismissNotificationsAfterPauseAll,
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _autoResumeTimer?.cancel();
    _saveSessionStateTimer?.cancel();
    _saveSessionOrderTimer?.cancel();
    _scanProgressNotifyTimer?.cancel();
    _deferredWarmupTimer?.cancel();
    _notificationProgressRefreshTimer?.cancel();
    _unifiedNotificationSyncTimer?.cancel();
    _notificationActionRefreshTimer?.cancel();
    _notificationActionGuardTimeout?.cancel();
    if (!_skipDisposePersistence) {
      unawaited(_saveSessionState());
      unawaited(_saveSessionOrder());
    }
    unawaited(
      _setKeepCpuAwake(
        false,
        hasActivePlayback: false,
        hasActiveTimer: false,
        usesUnifiedPlaybackNotifications: false,
        keepForegroundServiceAlive: false,
      ),
    );
    unawaited(_deactivateAudioSession());
    unawaited(_nativePlaybackSubscription?.cancel());
    unawaited(_nativePlaybackRepository.dispose());
    unawaited(_libraryService.dispose());
    unawaited(_playbackService.dispose());
    unawaited(_timerService.dispose());
    unawaited(_notificationStateService.dispose());
    unawaited(_settingsRepository.dispose());
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    super.dispose();
  }

  void _notifyListeners() {
    _syncAllStateSlices();
    notifyListeners();
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
    _libraryService.syncSlice(isInitialized: _isInitialized);
    _playbackService.syncSlice(
      activeSessions: activeSessions,
      playingSessionCount: playingSessionCount,
      focusedSessionId: _notificationFocusSessionId,
      multiThreadPlaybackEnabled: _multiThreadPlaybackEnabled,
      isInitialized: _isInitialized,
    );
    _timerService.syncSlice(isInitialized: _isInitialized);
    _settingsRepository.syncSlice();
    _notificationStateService.syncSlice(
      activeQueueLength: activeSessions.length,
    );
  }

  int _coverGeneration = 0;

  int get coverGeneration => _coverGeneration;

  void _clearResolvedCoverPaths() {
    _coverGeneration++;
    _coverPathFutures.clear();
    _resolvedCoverPaths.clear();
    _resolvedCoverPathFutures.clear();
    _notificationCoverPathFutures.clear();
    _resolvedNotificationCoverPaths.clear();
    _resolvedNotificationCoverPathFutures.clear();
    _notificationCoverSearchMisses.clear();
  }
}
