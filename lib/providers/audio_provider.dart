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

import '../models/music_track.dart';
import '../models/library_node.dart';
import '../models/playback_mode.dart';
import '../services/app_database.dart';
import '../services/library_organizer.dart';
import '../services/playback_queue_resolver.dart';
import '../services/timer_runtime_calculator.dart';

export '../models/library_node.dart';
export '../models/music_track.dart';
export '../models/playback_mode.dart';
import '../services/native_playback_bridge.dart';
import '../services/playback_notification_service.dart';
import '../services/subtitle_parser.dart';

part 'audio_provider_models.dart';
part 'audio_provider_notifications.dart';
part 'audio_provider_persistence.dart';
part 'audio_provider_library.dart';
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
  static const MethodChannel _powerChannel = MethodChannel(
    'music_player/power',
  );
  static const MethodChannel _fileCacheChannel = MethodChannel(
    'music_player/file_cache',
  );
  final PlaybackNotificationService _notificationService;
  SharedPreferences? _cachedPrefs;
  final List<MusicTrack> _library = [];
  final Map<String, MusicTrack> _libraryByPath = {};
  final Map<String, List<MusicTrack>> _tracksByGroup = {};
  List<MusicTrack> _sortedLibraryTracks = const <MusicTrack>[];
  List<String> _sortedLibraryTrackPaths = const <String>[];
  final Map<String, PlaybackSession> _sessions = {};
  final Map<String, Future<SubtitleTrack?>> _subtitleTrackFutures = {};
  final Map<String, SubtitleTrack?> _subtitleTracks = {};
  final Map<String, String?> _notificationSubtitleTexts = {};
  final Map<String, String> _notificationSubtitleTrackPaths = {};
  final Map<String, Future<String?>> _coverPathFutures = {};
  final Map<String, String?> _resolvedCoverPaths = {};
  final Map<String, Future<String?>> _notificationCoverPathFutures = {};
  final Map<String, String?> _resolvedNotificationCoverPaths = {};
  final Set<String> _notificationCoverSearchMisses = <String>{};
  String? _notificationFocusSessionId;
  String? _unifiedNotificationSyncKey;
  Timer? _notificationProgressRefreshTimer;
  Timer? _unifiedNotificationSyncTimer;
  bool _unifiedNotificationSyncInFlight = false;
  bool _unifiedNotificationSyncPending = false;
  bool _notificationActionRefreshPending = false;
  bool _keepAliveSyncDeferred = false;
  String? _queuedNotificationRefreshSessionId;
  bool _notificationsDismissedWhilePaused = false;

  final List<String> _groupOrder = [];
  final Set<String> _groupOrderSet = <String>{};
  final List<String> _libraryNodeOrder = [];
  final List<String> _sessionOrder = [];
  final List<String> _watchedFolders = [];
  final List<String> _watchedLibraries = [];
  final Map<String, Set<String>> _excludedLibraryFolders = {};
  final Map<String, Set<String>> _excludedLibraryTracks = {};

  String _converterFormat = 'mp3';
  String _converterBitrate = '320k';
  bool _multiThreadPlaybackEnabled = false;
  bool _notificationsEnabled = true;
  bool _showPlaybackCard = true;
  bool _autoPlayAddedSessions = true;

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
  bool _isScanning = false;
  bool _isBackgroundScanning = false;
  String _scanCurrentFolder = '';
  int _scanFoundCount = 0;
  int _scanDuplicateCount = 0;
  int _scanFailureCount = 0;
  bool _isPageTransitioning = false;
  final Random _random = Random();

  TimerMode? _timerMode;
  Duration? _timerDuration;
  bool _timerActive = false;
  Duration? _timerRemaining;
  DateTime? _timerEndsAt;
  Timer? _countdownTimer;
  bool _timerWaitingForPlayback = false;
  TimerMode _timerDraftMode = TimerMode.manual;
  Duration _timerDraftDuration = const Duration(minutes: 30);
  int _timerGeneration = 0;
  bool _keepCpuAwake = false;
  bool _keepAliveHasPlayback = false;
  bool _keepAliveHasTimer = false;
  bool _keepAliveUsesUnifiedNotifications = false;
  bool _keepAliveKeepsForegroundService = false;
  bool _activeSessionsDirty = true;
  List<PlaybackSession> _activeSessionsCache = const <PlaybackSession>[];
  bool _libraryTreeDirty = true;
  List<LibraryNode> _cachedLibraryTree = const <LibraryNode>[];
  int _cachedLibraryLeafFolderCount = 0;
  int _libraryBatchDepth = 0;
  bool _libraryBatchChanged = false;
  bool _libraryBatchChangedGroupOrder = false;
  final List<MusicTrack> _libraryBatchPersistTracks = [];
  Timer? _saveSessionStateTimer;
  Timer? _saveSessionOrderTimer;
  Timer? _scanProgressNotifyTimer;
  Timer? _cacheWarmupTimer;
  Future<void> _sessionPreparationQueue = Future<void>.value();
  Timer? _notificationActionRefreshTimer;
  Timer? _notificationActionGuardTimeout;
  StreamSubscription<NativePlaybackSnapshot>? _nativePlaybackSubscription;

  final List<String> _pausedByTimerPaths = [];

  bool _autoResumeEnabled = false;
  int _autoResumeHour = 7;
  int _autoResumeMinute = 0;
  Timer? _autoResumeTimer;
  DateTime? _autoResumeAt;

  late final LibraryController libraryController;
  late final PlaybackSessionController playbackSessionController;
  late final TimerController timerController;
  late final NotificationCoordinator notificationCoordinator;

  AudioProvider({required PlaybackNotificationService notificationService})
    : _notificationService = notificationService {
    _initializeControllers();
    NativePlaybackBridge.instance.startListening();
    _nativePlaybackSubscription = NativePlaybackBridge.instance.snapshots
        .listen(_handleNativePlaybackSnapshot);
    _bindNotificationHandler();
    _loadData();
  }

  @visibleForTesting
  AudioProvider.test({required PlaybackNotificationService notificationService})
    : _notificationService = notificationService {
    _initializeControllers();
  }

  void _initializeControllers() {
    libraryController = LibraryController._(this);
    playbackSessionController = PlaybackSessionController._(this);
    timerController = TimerController._(this);
    notificationCoordinator = NotificationCoordinator._(this);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _autoResumeTimer?.cancel();
    _saveSessionStateTimer?.cancel();
    _saveSessionOrderTimer?.cancel();
    _scanProgressNotifyTimer?.cancel();
    _cacheWarmupTimer?.cancel();
    _notificationProgressRefreshTimer?.cancel();
    _unifiedNotificationSyncTimer?.cancel();
    _notificationActionRefreshTimer?.cancel();
    _notificationActionGuardTimeout?.cancel();
    unawaited(_saveSessionState());
    unawaited(_saveSessionOrder());
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
    unawaited(NativePlaybackBridge.instance.stopListening());
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    super.dispose();
  }

  void _notifyListeners() {
    notifyListeners();
  }
}
