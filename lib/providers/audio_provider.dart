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
import '../services/app_database.dart';

export '../models/music_track.dart';
import '../services/native_playback_bridge.dart';
import '../services/playback_notification_service.dart';
import '../services/subtitle_parser.dart';

part 'audio_provider_models.dart';
part 'audio_provider_notifications.dart';
part 'audio_provider_persistence.dart';
part 'audio_provider_library.dart';
part 'audio_provider_playback.dart';

const _kLibraryKey = 'library_v1';
const _kSessionsKey = 'sessions_v1';
const _kGroupOrderKey = 'group_order_v1';
const _kLibraryNodeOrderKey = 'library_node_order_v1';
const _kSessionOrderKey = 'session_order_v1';
const _kWatchedFoldersKey = 'watched_folders_v1';
const _kWatchedLibrariesKey = 'watched_libraries_v1';
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

  String _converterFormat = 'mp3';
  String _converterBitrate = '320k';
  bool _multiThreadPlaybackEnabled = false;
  bool _notificationsEnabled = true;
  bool _showPlaybackCard = true;

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
  String _scanCurrentFolder = '';
  int _scanFoundCount = 0;
  int _scanDuplicateCount = 0;
  int _scanFailureCount = 0;
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
  Timer? _saveSessionStateTimer;
  Timer? _saveSessionOrderTimer;
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

  TimerMode? get timerMode => _timerMode;
  Duration? get timerDuration => _timerDuration;
  TimerMode get timerDraftMode => _timerDraftMode;
  Duration get timerDraftDuration => _timerDraftDuration;
  bool get timerActive => _timerActive;
  Duration? get timerRemaining => _timerRemaining;
  bool get autoResumeEnabled => _autoResumeEnabled;
  int get autoResumeHour => _autoResumeHour;
  int get autoResumeMinute => _autoResumeMinute;
  List<String> get pausedByTimerPaths => List.unmodifiable(_pausedByTimerPaths);
  String get converterFormat => _converterFormat;
  String get converterBitrate => _converterBitrate;
  bool get multiThreadPlaybackEnabled => _multiThreadPlaybackEnabled;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get showPlaybackCard => _showPlaybackCard;

  List<MusicTrack> get library => List.unmodifiable(_library);
  int get libraryTrackCount => _library.length;
  List<String> get watchedFolders => List.unmodifiable(_watchedFolders);
  List<String> get watchedLibraries => List.unmodifiable(_watchedLibraries);
  int get watchedFolderCount => _watchedFolders.length;
  List<LibraryNode> get libraryTree {
    if (_libraryTreeDirty) {
      final snapshot = _buildLibraryTreeSnapshot();
      _cachedLibraryTree = snapshot.tree;
      _cachedLibraryLeafFolderCount = snapshot.leafFolderCount;
      _libraryTreeDirty = false;
    }
    return _cachedLibraryTree;
  }

  int get libraryLeafFolderCount {
    if (_libraryTreeDirty) {
      final _ = libraryTree;
    }
    return _cachedLibraryLeafFolderCount;
  }

  int get playingSessionCount =>
      _sessions.values.where((session) => session.state.playing).length;

  List<PlaybackSession> get activeSessions {
    if (_activeSessionsDirty) {
      final result = <PlaybackSession>[];
      final orderSet = _sessionOrder.toSet();
      for (final id in _sessionOrder) {
        final session = _sessions[id];
        if (session != null) {
          result.add(session);
        }
      }
      for (final session in _sessions.values) {
        if (!orderSet.contains(session.id)) {
          result.add(session);
        }
      }
      _activeSessionsCache = List<PlaybackSession>.unmodifiable(result);
      _activeSessionsDirty = false;
    }
    return _activeSessionsCache;
  }

  bool get isScanning => _isScanning;
  String get scanCurrentFolder => _scanCurrentFolder;
  int get scanFoundCount => _scanFoundCount;
  int get scanDuplicateCount => _scanDuplicateCount;
  int get scanFailureCount => _scanFailureCount;

  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
  }) {
    if (currentFolder != null) _scanCurrentFolder = currentFolder;
    if (foundCount != null) _scanFoundCount = foundCount;
    if (duplicateCount != null) _scanDuplicateCount = duplicateCount;
    if (failureCount != null) _scanFailureCount = failureCount;
    _notifyListeners();
  }

  void cancelScan() {
    if (!_isScanning) return;
    _isScanning = false;
    _notifyListeners();
  }

  AudioProvider({required PlaybackNotificationService notificationService})
    : _notificationService = notificationService {
    NativePlaybackBridge.instance.startListening();
    _nativePlaybackSubscription = NativePlaybackBridge.instance.snapshots
        .listen(_handleNativePlaybackSnapshot);
    _bindNotificationHandler();
    _loadData();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _autoResumeTimer?.cancel();
    _saveSessionStateTimer?.cancel();
    _saveSessionOrderTimer?.cancel();
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

  void _markActiveSessionsDirty() {
    _activeSessionsDirty = true;
  }

  void _markLibraryStructureDirty() {
    _libraryTreeDirty = true;
  }

  void _rebuildLibraryIndexes() {
    final tracksByGroup = <String, List<MusicTrack>>{};
    _libraryByPath
      ..clear()
      ..addEntries(_library.map((track) => MapEntry(track.path, track)));
    for (final track in _library) {
      tracksByGroup
          .putIfAbsent(track.groupKey, () => <MusicTrack>[])
          .add(track);
    }
    for (final entry in tracksByGroup.entries) {
      entry.value.sort(getTrackComparator);
    }
    _tracksByGroup
      ..clear()
      ..addAll(
        tracksByGroup.map(
          (groupKey, tracks) =>
              MapEntry(groupKey, List<MusicTrack>.unmodifiable(tracks)),
        ),
      );
    _sortedLibraryTracks = List<MusicTrack>.unmodifiable(
      _library.toList()..sort(getTrackComparator),
    );
    _sortedLibraryTrackPaths = List<String>.unmodifiable(
      _sortedLibraryTracks.map((t) => t.path),
    );
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);
    _markLibraryStructureDirty();
  }

  void _syncGroupOrderFromLibrary() {
    final activeGroupKeys = _library.map((track) => track.groupKey).toSet();
    _groupOrder.removeWhere((groupKey) => !activeGroupKeys.contains(groupKey));
    for (final groupKey in activeGroupKeys) {
      if (_groupOrderSet.add(groupKey)) {
        _groupOrder.add(groupKey);
      }
    }
    _groupOrderSet
      ..clear()
      ..addAll(_groupOrder);
  }

  Future<SharedPreferences> get _prefs async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  void _notifyListeners() {
    notifyListeners();
  }

  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    final session = _sessions[snapshot.sessionId];
    if (session == null) return;
    session.applyNativeSnapshot(snapshot);
  }
}
