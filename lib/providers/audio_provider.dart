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

import '../widgets/app_feedback.dart';

import '../i18n/app_language_provider.dart';
import '../models/audio_detail.dart';
import '../models/asmr_download.dart';
import '../models/audio_library_category.dart';
import '../models/audio_effects.dart';
import '../models/card_info_field.dart';
import '../models/dlsite_metadata.dart';
import '../models/library_entry.dart';
import '../models/library_node.dart';
import '../models/music_track.dart';
import '../models/playback_mode.dart';
import '../models/playback_queue.dart';
import '../models/playback_session.dart';
import '../models/time_segment_label.dart';
import '../platform/app_platform.dart';
import '../services/app_cache_service.dart';
import '../services/app_log_service.dart';
import '../services/audio_detail_cache_service.dart';
import '../services/cover_artwork_cache_service.dart';
import '../services/audio_database_repository.dart';
import '../services/audio_detail_repository.dart';
import '../services/audio_state_services.dart';
import '../services/app_database.dart' show PersistedSession;
import '../services/asmr_metadata_service.dart';
import '../services/asmr_playback_cache_service.dart';
import '../services/dlsite_metadata_service.dart';
import '../services/file_cache_platform_gateway.dart';
import '../services/library_snapshot_cache_service.dart';
import '../services/library_organizer.dart';
import '../services/media_file_support.dart';
import '../services/native_result.dart';
import '../services/native_playback_repository.dart';
import '../services/playback_queue_resolver.dart';
import '../services/power_platform_service.dart';
import '../services/timer_runtime_calculator.dart';
import '../services/ui_interaction_coordinator.dart';
import '../services/warmup_scheduler.dart';

export '../models/library_node.dart';
export '../models/library_entry.dart';
export '../models/audio_detail.dart';
export '../models/audio_library_category.dart';
export '../models/audio_effects.dart';
export '../models/card_info_field.dart';
export '../models/dlsite_metadata.dart';
export '../models/music_track.dart';
export '../models/playback_mode.dart';
export '../models/playback_queue.dart';
export '../models/playback_session.dart';
export '../models/time_segment_label.dart';
export '../services/audio_state_services.dart' show StartupPage;
export '../models/asmr_download.dart';
import '../services/native_playback_bridge.dart';
import '../services/playback_notification_service.dart';
import '../services/playback_command_runner.dart';
import '../services/path_matcher.dart';
import '../services/path_display.dart';
import '../services/subtitle_parser.dart';

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
part 'audio_provider_controllers.dart';
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
  final PlaybackNotificationService _notificationService;
  final AudioDatabaseRepository _audioDatabaseRepository;
  final AudioDetailCacheService _audioDetailCacheService;
  final DlsiteMetadataService _dlsiteMetadataService;
  final AsmrMetadataService _asmrMetadataService;
  final AsmrPlaybackCacheService _asmrPlaybackCacheService;
  final NativePlaybackRepository _nativePlaybackRepository;
  final PlaybackCommandRunner _playbackCommandRunner;
  final PowerPlatformService _powerPlatformService;
  final LibraryService _libraryService;
  final LibrarySnapshotCacheService _librarySnapshotCacheService;
  late final CoverArtworkCacheService _coverArtworkCacheService;
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
  final Set<String> _deferredVolumeReloadSessionIds = <String>{};
  final Map<String, String> _retargetedPathAliases = <String, String>{};
  final Map<String, _TimeSegmentLoopRuntime> _timeSegmentLoopsBySessionId =
      <String, _TimeSegmentLoopRuntime>{};
  final Set<String> _timeSegmentLoopBoundSessionIds = <String>{};
  final Set<String> _timeSegmentLoopSeekPendingSessionIds = <String>{};
  final ValueNotifier<int?> _scrollToTopTabNotifier = ValueNotifier<int?>(null);
  ValueListenable<int?> get scrollToTopTabListenable => _scrollToTopTabNotifier;
  final ValueNotifier<String?> _carouselSnapNotifier = ValueNotifier<String?>(
    null,
  );
  ValueListenable<String?> get carouselSnapListenable => _carouselSnapNotifier;
  bool _notifyListenersQueued = false;
  bool _isDisposed = false;
  bool _nativeRuntimeStarted = false;
  int _transportCommandSequence = 0;

  void requestCarouselSnapTo(String sessionId) {
    _carouselSnapNotifier.value = sessionId;
  }

  final Random _random = Random();

  StreamSubscription<NativePlaybackSnapshot>? _nativePlaybackSubscription;
  StreamSubscription<NativePlaybackProgressUpdate>?
  _nativePlaybackProgressSubscription;

  late final LibraryController libraryController;
  late final PlaybackSessionController playbackSessionController;
  late final TimerController timerController;
  late final NotificationCoordinator notificationCoordinator;

  List<MusicTrack> get _library => _libraryService.library;
  Map<String, MusicTrack> get _libraryByPath => _libraryService.libraryByPath;
  Map<String, int> get _libraryIndexByPath =>
      _libraryService.libraryIndexByPath;
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

  AppLanguage get _dlsiteMetadataLanguage =>
      _settingsRepository.dlsiteMetadataLanguage;
  set _dlsiteMetadataLanguage(AppLanguage value) {
    _settingsRepository.dlsiteMetadataLanguage = value;
  }

  int get _maxCacheBytes => _settingsRepository.maxCacheBytes;
  set _maxCacheBytes(int value) {
    _settingsRepository.maxCacheBytes = value;
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

  factory AudioProvider({
    required PlaybackNotificationService notificationService,
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
    bool deferRuntimeStart = false,
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
    return AudioProvider._(
      notificationService: notificationService,
      audioDatabaseRepository: resolvedAudioDatabaseRepository,
      audioDetailCacheService: resolvedAudioDetailCacheService,
      dlsiteMetadataService: dlsiteMetadataService ?? DlsiteMetadataService(),
      asmrMetadataService: asmrMetadataService ?? AsmrMetadataService(),
      asmrPlaybackCacheService: asmrPlaybackCacheService,
      nativePlaybackRepository:
          nativePlaybackRepository ?? NativePlaybackRepository(),
      playbackCommandRunner: playbackCommandRunner,
      powerPlatformService: powerPlatformService ?? PowerPlatformService(),
      libraryService: resolvedLibraryService,
      librarySnapshotCacheService:
          librarySnapshotCacheService ??
          LibrarySnapshotCacheService(
            libraryService: resolvedLibraryService,
            detailCacheService: resolvedAudioDetailCacheService,
          ),
      coverArtworkCacheService: coverArtworkCacheService,
      playbackService: playbackService ?? PlaybackSessionService(),
      timerService: timerService ?? TimerService(),
      notificationStateService:
          notificationStateService ?? NotificationCoordinatorService(),
      settingsRepository: settingsRepository ?? SettingsRepository(),
      skipDisposePersistence: false,
      startNativeRuntime: !deferRuntimeStart,
    );
  }

  @visibleForTesting
  factory AudioProvider.test({
    required PlaybackNotificationService notificationService,
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
    bool skipPersistence = true,
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
    return AudioProvider._(
      notificationService: notificationService,
      audioDatabaseRepository: resolvedAudioDatabaseRepository,
      audioDetailCacheService: resolvedAudioDetailCacheService,
      dlsiteMetadataService: dlsiteMetadataService ?? DlsiteMetadataService(),
      asmrMetadataService: asmrMetadataService ?? AsmrMetadataService(),
      asmrPlaybackCacheService: asmrPlaybackCacheService,
      nativePlaybackRepository:
          nativePlaybackRepository ?? NativePlaybackRepository(),
      playbackCommandRunner: playbackCommandRunner,
      powerPlatformService: powerPlatformService ?? PowerPlatformService(),
      libraryService: resolvedLibraryService,
      librarySnapshotCacheService:
          librarySnapshotCacheService ??
          LibrarySnapshotCacheService(
            libraryService: resolvedLibraryService,
            detailCacheService: resolvedAudioDetailCacheService,
          ),
      coverArtworkCacheService: coverArtworkCacheService,
      playbackService: playbackService ?? PlaybackSessionService(),
      timerService: timerService ?? TimerService(),
      notificationStateService:
          notificationStateService ?? NotificationCoordinatorService(),
      settingsRepository: settingsRepository ?? SettingsRepository(),
      skipDisposePersistence: skipPersistence,
      startNativeRuntime: false,
    );
  }

  AudioProvider._({
    required PlaybackNotificationService notificationService,
    required AudioDatabaseRepository audioDatabaseRepository,
    required AudioDetailCacheService audioDetailCacheService,
    required DlsiteMetadataService dlsiteMetadataService,
    required AsmrMetadataService asmrMetadataService,
    required AsmrPlaybackCacheService asmrPlaybackCacheService,
    required NativePlaybackRepository nativePlaybackRepository,
    required PlaybackCommandRunner playbackCommandRunner,
    required PowerPlatformService powerPlatformService,
    required LibraryService libraryService,
    required LibrarySnapshotCacheService librarySnapshotCacheService,
    required CoverArtworkCacheService? coverArtworkCacheService,
    required PlaybackSessionService playbackService,
    required TimerService timerService,
    required NotificationCoordinatorService notificationStateService,
    required SettingsRepository settingsRepository,
    required bool skipDisposePersistence,
    required bool startNativeRuntime,
  }) : _notificationService = notificationService,
       _audioDatabaseRepository = audioDatabaseRepository,
       _audioDetailCacheService = audioDetailCacheService,
       _dlsiteMetadataService = dlsiteMetadataService,
       _asmrMetadataService = asmrMetadataService,
       _asmrPlaybackCacheService = asmrPlaybackCacheService,
       _nativePlaybackRepository = nativePlaybackRepository,
       _playbackCommandRunner = playbackCommandRunner,
       _powerPlatformService = powerPlatformService,
       _libraryService = libraryService,
       _librarySnapshotCacheService = librarySnapshotCacheService,
       _playbackService = playbackService,
       _timerService = timerService,
       _notificationStateService = notificationStateService,
       _settingsRepository = settingsRepository,
       _skipDisposePersistence = skipDisposePersistence {
    _coverArtworkCacheService =
        coverArtworkCacheService ??
        CoverArtworkCacheService(
          libraryService: _libraryService,
          isActiveCoverKey: _isActiveCoverKey,
          onActiveCoverChanged: () {
            _syncNotificationState();
            _notifyNotificationChanged();
          },
        );
    _initializeControllers();
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
    _isDisposed = true;
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
    unawaited(_nativePlaybackProgressSubscription?.cancel());
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
          _isInitialized ||
          (preserveSliceInitialized &&
              _libraryService.slice.state.isInitialized),
      detailRevision: _audioDetailCacheService.revision,
      treeSnapshotRevision: _librarySnapshotCacheService.treeSnapshotRevision,
      categorySnapshotRevision:
          _librarySnapshotCacheService.categorySnapshotRevision,
    );
    unawaited(_ensureLibraryTreeSnapshot());
  }

  void _syncPlaybackStateSlice() {
    _playbackService.syncSlice(
      activeSessions: activeSessions,
      playingSessionCount: playingSessionCount,
      focusedSessionId: _notificationFocusSessionId,
      multiThreadPlaybackEnabled: _multiThreadPlaybackEnabled,
      coverGeneration: _coverArtworkCacheService.generation,
      isInitialized: _isInitialized,
    );
  }

  void _syncTimerStateSlice() {
    _timerService.syncSlice(isInitialized: _isInitialized);
  }

  void _syncSettingsStateSlice() {
    _settingsRepository.syncSlice();
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

  void _invalidateResolvedCoverScope(String? scope) {
    _coverArtworkCacheService.invalidateFolder(scope);
  }

  void _invalidateResolvedCoverScopes(Iterable<String?> scopes) {
    _coverArtworkCacheService.invalidateFolders(scopes);
  }
}
