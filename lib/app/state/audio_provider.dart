import 'dart:async';
import 'dart:collection';
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

import '../../core/widgets/app_feedback.dart';

import '../../core/app_language.dart';
import '../../core/media/audio_detail.dart';
import '../../features/asmr/domain/asmr_download.dart';
import '../../features/library/domain/audio_library_category.dart';
import '../../features/player/domain/audio_effects.dart';
import '../../core/media/card_info_field.dart';
import '../../core/media/dlsite_metadata.dart';
import '../../features/library/domain/library_entry.dart';
import '../../features/library/domain/library_node.dart';
import '../../core/media/music_track.dart';
import '../../features/player/domain/playback_mode.dart';
import '../../features/player/domain/playback_queue.dart';
import '../../features/player/application/playback_session.dart';
import '../../features/player/domain/time_segment_label.dart';
import '../../core/platform/app_platform.dart';
import '../../features/settings/application/app_cache_service.dart';
import '../../core/logging/app_log_service.dart';
import '../../features/library/application/audio_detail_cache_service.dart';
import '../../features/library/application/cover_artwork_cache_service.dart';
import '../../core/persistence/audio_database_repository.dart';
import '../../features/library/application/audio_detail_repository.dart';
import '../../features/player/application/audio_state_services.dart';
import '../../core/persistence/app_database.dart' show PersistedSession;
import '../../features/asmr/application/asmr_api_service.dart';
import '../../features/asmr/application/asmr_metadata_service.dart';
import '../../features/asmr/application/asmr_playback_cache_service.dart';
import '../../features/library/application/dlsite_metadata_service.dart';
import '../../features/library/application/dlsite_metadata_query.dart';
import '../../core/platform/file_cache_platform_gateway.dart';
import '../../features/library/application/library_snapshot_cache_service.dart';
import '../../features/library/application/library_facade.dart';
import 'library_catalog_compatibility.dart';
import '../../features/library/application/library_scan_models.dart';
import '../../features/library/application/library_organizer.dart';
import '../../core/media/media_file_support.dart';
import '../../core/errors/native_result.dart';
import '../../features/player/application/native_playback_repository.dart';
import '../../features/player/application/playback_queue_resolver.dart';
import '../../core/platform/power_platform_service.dart';
import '../../features/library/application/cover_image_cache_policy.dart';
import '../../features/player/application/timer_runtime_calculator.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/ui/warmup_scheduler.dart';

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
export '../../features/player/application/audio_state_services.dart'
    show StartupPage;
export '../../features/asmr/domain/asmr_download.dart';
import '../../features/player/application/native_playback_bridge.dart';
import '../../features/player/application/playback_notification_service.dart';
import '../../features/player/application/playback_command_runner.dart';
import '../../core/media/path_matcher.dart';
import '../../core/media/path_display.dart';
import '../../features/player/application/system_media_controls_service.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../core/media/subtitle_parser.dart';

part 'audio_provider_notifications.dart';
part 'audio_provider_persistence.dart';
part 'audio_provider_library.dart';
part 'audio_provider_audio_details.dart';
part 'audio_provider_library_categories.dart';
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
part 'audio_provider_library_covers.dart';
part 'audio_provider_warmup.dart';
part 'audio_provider_time_segments.dart';
part 'audio_provider_queues.dart';

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
  static const Duration _notificationProgressRefreshInterval = Duration(
    milliseconds: 750,
  );
  static const Duration _multiSessionNotificationRefreshInterval = Duration(
    milliseconds: 700,
  );
  static const Duration _unifiedNotificationDebounceInterval = Duration(
    milliseconds: 90,
  );
  static final FileCachePlatformGateway _fileCacheGateway =
      FileCachePlatformGateway.instance;
  final LibraryFacade _libraryFacade;
  final PlaybackFacade _playbackFacade;
  final TimerFacade _timerFacade;
  final NotificationFacade _notificationFacade;
  final SettingsRepository _settingsRepository;
  final AppLanguage Function() _pageLanguageResolver;
  final bool _skipDisposePersistence;
  SharedPreferences? _cachedPrefs;

  LibraryFacade get libraryFacade => _libraryFacade;
  PlaybackFacade get playbackFacade => _playbackFacade;
  TimerFacade get timerFacade => _timerFacade;
  NotificationFacade get notificationFacade => _notificationFacade;
  SettingsRepository get settingsRepository => _settingsRepository;

  PlaybackNotificationService get _notificationService =>
      _notificationFacade.service;
  AudioDatabaseRepository get _audioDatabaseRepository =>
      _libraryFacade.databaseRepository;
  AudioDetailCacheService get _audioDetailCacheService =>
      _libraryFacade.detailCacheService;
  DlsiteMetadataService get _dlsiteMetadataService =>
      _libraryFacade.metadataService;
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
  static const List<double> playbackSpeedOptions = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];
  static const List<EqPreset> builtInEqPresets = [
    EqPreset(
      id: 'flat',
      labelKey: 'eq_preset_flat',
      bandLevels: <int, double>{},
    ),
    EqPreset(
      id: 'asmr_immersive',
      labelKey: 'eq_preset_asmr_immersive',
      bandLevels: <int, double>{
        60: 2.5,
        170: 1.5,
        310: -1.0,
        3000: 1.5,
        6000: 2.5,
        12000: 3.5,
      },
    ),
    EqPreset(
      id: 'voice_clear',
      labelKey: 'eq_preset_voice_clear',
      bandLevels: <int, double>{
        170: -2.0,
        310: -1.0,
        1000: 1.5,
        3000: 3.0,
        6000: 1.5,
      },
    ),
    EqPreset(
      id: 'ear_massage',
      labelKey: 'eq_preset_ear_massage',
      bandLevels: <int, double>{
        60: 3.0,
        170: 1.0,
        1000: -1.5,
        3000: 1.0,
        6000: 3.5,
        12000: 4.5,
      },
    ),
    EqPreset(
      id: 'night_soft',
      labelKey: 'eq_preset_night_soft',
      bandLevels: <int, double>{
        60: -2.0,
        170: -1.5,
        3000: -1.5,
        6000: -3.0,
        12000: -4.5,
      },
    ),
    EqPreset(
      id: 'bass_boost',
      labelKey: 'eq_preset_bass_boost',
      bandLevels: <int, double>{60: 4.5, 170: 3.0, 310: 1.0, 6000: -1.0},
    ),
  ];

  int _sessionSeed = 0;
  bool _isInitialized = false;
  bool _settingsInitialized = false;
  bool _libraryInitialized = false;
  bool _playbackInitialized = false;
  final Set<String> _deferredVolumeReloadSessionIds = <String>{};
  final Map<String, String> _retargetedPathAliases = <String, String>{};
  final Map<String, _TimeSegmentLoopRuntime> _timeSegmentLoopsBySessionId =
      <String, _TimeSegmentLoopRuntime>{};
  final Set<String> _timeSegmentLoopBoundSessionIds = <String>{};
  final Set<String> _timeSegmentLoopSeekPendingSessionIds = <String>{};
  bool _notifyListenersQueued = false;
  bool _isDisposed = false;
  bool _nativeRuntimeStarted = false;
  bool _warmupPausedForLifecycle = false;
  int _transportCommandSequence = 0;
  int _persistenceLoadEpoch = 0;
  Future<void>? _postStartupLibraryMaintenance;

  final Random _random = Random();

  StreamSubscription<NativePlaybackSnapshot>? _nativePlaybackSubscription;
  StreamSubscription<NativePlaybackProgressUpdate>?
  _nativePlaybackProgressSubscription;

  List<MusicTrack> get _library => _libraryService.library;
  Map<String, MusicTrack> get _libraryByPath => _libraryService.libraryByPath;
  Map<String, int> get _libraryIndexByPath =>
      _libraryService.libraryIndexByPath;
  Map<String, List<MusicTrack>> get _tracksByGroup =>
      _libraryService.tracksByGroup;
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
  int get _scanGeneration => _libraryService.scanGeneration;
  FolderScanStage get _scanStage => _libraryService.scanStage;
  int get _scanProcessed => _libraryService.scanProcessed;
  int? get _scanTotal => _libraryService.scanTotal;
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

  int get _libraryDerivedGeneration => _libraryService.libraryDerivedGeneration;
  set _libraryDerivedGeneration(int value) {
    _libraryService.libraryDerivedGeneration = value;
  }

  List<MusicTrack> get _libraryBatchPersistTracks =>
      _libraryService.libraryBatchPersistTracks;
  Map<String, LibraryEntry> get _libraryBatchPersistEntriesByKey =>
      _libraryService.libraryBatchPersistEntriesByKey;
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
  StartupPage get _startupPage => _settingsRepository.startupPage;
  set _startupPage(StartupPage value) =>
      _settingsRepository.startupPage = value;
  BottomNavigationStyle get _bottomNavigationStyle =>
      _settingsRepository.bottomNavigationStyle;
  set _bottomNavigationStyle(BottomNavigationStyle value) =>
      _settingsRepository.bottomNavigationStyle = value;
  bool get _autoPlayAddedSessions => _settingsRepository.autoPlayAddedSessions;
  set _autoPlayAddedSessions(bool value) {
    _settingsRepository.autoPlayAddedSessions = value;
  }

  bool get _autoCheckUpdates => _settingsRepository.autoCheckUpdates;
  set _autoCheckUpdates(bool value) {
    _settingsRepository.autoCheckUpdates = value;
  }

  ContentLanguagePreference get _dlsiteMetadataLanguagePreference =>
      _settingsRepository.dlsiteMetadataLanguage;
  set _dlsiteMetadataLanguagePreference(ContentLanguagePreference value) {
    _settingsRepository.dlsiteMetadataLanguage = value;
  }

  AppLanguage get _dlsiteMetadataLanguage =>
      _dlsiteMetadataLanguagePreference.resolve(_pageLanguageResolver());

  int get _maxCacheBytes => _settingsRepository.maxCacheBytes;
  set _maxCacheBytes(int value) {
    _settingsRepository.maxCacheBytes = value;
  }

  bool get _keepCpuAwake => _settingsRepository.keepCpuAwake;
  set _keepCpuAwake(bool value) => _settingsRepository.keepCpuAwake = value;
  bool get _keepAliveHasPlayback => _timerFacade.keepAliveHasPlayback;
  set _keepAliveHasPlayback(bool value) {
    _timerFacade.keepAliveHasPlayback = value;
  }

  bool get _keepAliveHasTimer => _timerFacade.keepAliveHasTimer;
  set _keepAliveHasTimer(bool value) => _timerFacade.keepAliveHasTimer = value;
  bool get _keepAliveUsesUnifiedNotifications =>
      _timerFacade.keepAliveUsesUnifiedNotifications;
  set _keepAliveUsesUnifiedNotifications(bool value) {
    _timerFacade.keepAliveUsesUnifiedNotifications = value;
  }

  bool get _keepAliveKeepsForegroundService =>
      _timerFacade.keepAliveKeepsForegroundService;
  set _keepAliveKeepsForegroundService(bool value) {
    _timerFacade.keepAliveKeepsForegroundService = value;
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
       _pageLanguageResolver = pageLanguageResolver ?? (() => AppLanguage.zh),
       _skipDisposePersistence = skipDisposePersistence {
    _settingsRepository.attachPersistence(_savePlaybackSettings);
    _libraryFacade.attachCatalog(AudioProviderCompatibilityCatalog(this));
    _playbackFacade.attachSessionLauncher(spawnSessionWithQueue);
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
    UiInteractionCoordinator.instance.addListener(
      _handleWarmupInteractionChanged,
    );
    _syncWarmupPauseState();
    if (startNativeRuntime) {
      _startNativeRuntime();
    }
    _syncAllStateSlices();
  }

  void _startNativeRuntime() {
    if (_nativeRuntimeStarted || _isDisposed) return;
    _nativeRuntimeStarted = true;
    _nativePlaybackRepository.startListening();
    _nativePlaybackSubscription = _nativePlaybackRepository.snapshots.listen(
      _handleNativePlaybackSnapshot,
    );
    _nativePlaybackProgressSubscription = _nativePlaybackRepository
        .progressUpdates
        .listen(_handleNativePlaybackProgress);
    _loadData();
  }

  void startRuntime() => _startNativeRuntime();

  @override
  void dispose() {
    _isDisposed = true;
    _persistenceLoadEpoch++;
    UiInteractionCoordinator.instance.removeListener(
      _handleWarmupInteractionChanged,
    );
    _countdownTimer?.cancel();
    _autoResumeTimer?.cancel();
    _saveSessionStateTimer?.cancel();
    _saveSessionOrderTimer?.cancel();
    _scanProgressNotifyTimer?.cancel();
    _deferredWarmupTimer?.cancel();
    unawaited(_warmupScheduler.shutdown());
    _notificationProgressRefreshTimer?.cancel();
    _unifiedNotificationSyncTimer?.cancel();
    _notificationActionRefreshTimer?.cancel();
    _notificationActionGuardTimeout?.cancel();
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
    unawaited(_nativePlaybackProgressSubscription?.cancel());
    unawaited(_libraryFacade.dispose());
    unawaited(_playbackFacade.dispose());
    unawaited(_timerFacade.dispose());
    unawaited(_notificationFacade.dispose());
    unawaited(_settingsRepository.dispose());
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    _timeSegmentLoopsBySessionId.clear();
    _timeSegmentLoopBoundSessionIds.clear();
    _timeSegmentLoopSeekPendingSessionIds.clear();
    super.dispose();
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

  void _invalidateResolvedCoverScopes(Iterable<String?> scopes) {
    _coverArtworkCacheService.invalidateFolders(scopes);
  }
}
