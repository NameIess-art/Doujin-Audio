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
  bool keepAliveSyncDeferred = false;
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
    required VoidCallback flushKeepAliveSync,
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
        if (keepAliveSyncDeferred) {
          keepAliveSyncDeferred = false;
          flushKeepAliveSync();
        }
        syncNotificationState();
        notify();
      }
    });
  }

  Future<void> guardNotificationAction(
    Future<void> Function() action, {
    required VoidCallback notify,
    required VoidCallback flushKeepAliveSync,
    required VoidCallback syncNotificationState,
  }) async {
    beginNotificationAction(
      notify: notify,
      flushKeepAliveSync: flushKeepAliveSync,
      syncNotificationState: syncNotificationState,
    );
    try {
      await action();
    } finally {
      scheduleNotificationActionRefresh(
        notify: notify,
        flushKeepAliveSync: flushKeepAliveSync,
        syncNotificationState: syncNotificationState,
      );
    }
  }

  void scheduleNotificationActionRefresh({
    required VoidCallback notify,
    required VoidCallback flushKeepAliveSync,
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
        if (keepAliveSyncDeferred) {
          keepAliveSyncDeferred = false;
          flushKeepAliveSync();
        }
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

class SettingsRepository {
  Future<void> Function()? _persist;
  Future<void> Function()? _persistConverter;
  static const converterFormats = <String>['mp3', 'flac', 'wav', 'aac', 'ogg'];
  static const converterBitrates = <String>['128k', '192k', '256k', '320k'];
  String converterFormat = 'mp3';
  String converterBitrate = '320k';
  bool multiThreadPlaybackEnabled = false;
  bool notificationsEnabled = true;
  bool showPlaybackCard = true;
  bool autoPlayAddedSessions = true;
  bool autoCheckUpdates = false;
  ContentLanguagePreference dlsiteMetadataLanguage =
      ContentLanguagePreference.followPage;
  List<CardInfoField> cardInfoFields = CardInfoField.defaults;
  bool cardPositionsLocked = true;
  List<EqPreset> customEqPresets = const <EqPreset>[];
  int maxCacheBytes = 300 * 1024 * 1024;
  bool asmrPlaybackCacheEnabled = false;
  bool keepCpuAwake = false;
  bool recordPlaybackProgress = true;
  bool blurPlayerBackgroundEnabled = true;
  bool uiBlurEffectEnabled = true;
  bool hapticFeedbackEnabled = true;
  StartupPage startupPage = StartupPage.library;
  BottomNavigationStyle bottomNavigationStyle = BottomNavigationStyle.capsule;
  CoverImageResolution coverImageResolution = CoverImageResolution.balanced;
  String? asmrDownloadDestinationRoot;
  AsmrDownloadConflictPolicy asmrDownloadConflictPolicy =
      AsmrDownloadConflictPolicy.overwrite;
  final AudioStateSlice<SettingsState> slice = AudioStateSlice<SettingsState>(
    const SettingsState(),
  );

  void attachPersistence(Future<void> Function() persist) {
    _persist ??= persist;
  }

  void attachConverterPersistence(Future<void> Function() persist) {
    _persistConverter ??= persist;
  }

  Future<void> persist() async {
    await _persist?.call();
  }

  Future<void> setConverterSettings({String? format, String? bitrate}) async {
    var changed = false;
    if (format != null &&
        converterFormats.contains(format) &&
        format != converterFormat) {
      converterFormat = format;
      changed = true;
    }
    if (bitrate != null &&
        converterBitrates.contains(bitrate) &&
        bitrate != converterBitrate) {
      converterBitrate = bitrate;
      changed = true;
    }
    if (!changed) return;
    syncSlice(isInitialized: slice.state.isInitialized);
    await _persistConverter?.call();
  }

  Future<void> setAsmrDownloadDestinationRoot(String? destinationRoot) async {
    final normalized = destinationRoot?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (asmrDownloadDestinationRoot == next) return;
    asmrDownloadDestinationRoot = next;
    syncSlice(isInitialized: slice.state.isInitialized);
    await _persist?.call();
  }

  Future<void> setCardInfoFields(Iterable<CardInfoField> fields) async {
    final normalized = CardInfoField.normalize(fields);
    if (listEquals(cardInfoFields, normalized)) return;
    cardInfoFields = normalized;
    syncSlice(isInitialized: slice.state.isInitialized);
    await _persist?.call();
  }

  Future<void> setCardPositionsLocked(bool locked) async {
    if (cardPositionsLocked == locked) return;
    cardPositionsLocked = locked;
    syncSlice(isInitialized: slice.state.isInitialized);
    await _persist?.call();
  }

  Future<void> setMultiThreadPlaybackEnabled(bool enabled) => _setValue(
    unchanged: multiThreadPlaybackEnabled == enabled,
    update: () => multiThreadPlaybackEnabled = enabled,
  );

  Future<void> setShowPlaybackCard(bool enabled) => _setValue(
    unchanged: showPlaybackCard == enabled,
    update: () => showPlaybackCard = enabled,
  );

  Future<void> setAutoPlayAddedSessions(bool enabled) => _setValue(
    unchanged: autoPlayAddedSessions == enabled,
    update: () => autoPlayAddedSessions = enabled,
  );

  Future<void> setAutoCheckUpdates(bool enabled) => _setValue(
    unchanged: autoCheckUpdates == enabled,
    update: () => autoCheckUpdates = enabled,
  );

  Future<void> setDlsiteMetadataLanguage(ContentLanguagePreference language) =>
      _setValue(
        unchanged: dlsiteMetadataLanguage == language,
        update: () => dlsiteMetadataLanguage = language,
      );

  Future<void> setMaxCacheBytes(int bytes) => _setValue(
    unchanged: maxCacheBytes == bytes,
    update: () => maxCacheBytes = bytes,
  );

  Future<void> setAsmrPlaybackCacheEnabled(bool enabled) => _setValue(
    unchanged: asmrPlaybackCacheEnabled == enabled,
    update: () => asmrPlaybackCacheEnabled = enabled,
  );

  Future<void> setRecordPlaybackProgress(bool enabled) => _setValue(
    unchanged: recordPlaybackProgress == enabled,
    update: () => recordPlaybackProgress = enabled,
  );

  Future<void> setBlurPlayerBackgroundEnabled(bool enabled) => _setValue(
    unchanged: blurPlayerBackgroundEnabled == enabled,
    update: () => blurPlayerBackgroundEnabled = enabled,
  );

  Future<void> setUiBlurEffectEnabled(bool enabled) => _setValue(
    unchanged: uiBlurEffectEnabled == enabled,
    update: () => uiBlurEffectEnabled = enabled,
  );

  Future<void> setHapticFeedbackEnabled(bool enabled) => _setValue(
    unchanged: hapticFeedbackEnabled == enabled,
    update: () => hapticFeedbackEnabled = enabled,
  );

  Future<void> setStartupPage(StartupPage page) => _setValue(
    unchanged: startupPage == page,
    update: () => startupPage = page,
  );

  Future<void> setBottomNavigationStyle(BottomNavigationStyle style) =>
      _setValue(
        unchanged: bottomNavigationStyle == style,
        update: () => bottomNavigationStyle = style,
      );

  Future<void> setCoverImageResolution(CoverImageResolution resolution) =>
      _setValue(
        unchanged: coverImageResolution == resolution,
        update: () => coverImageResolution = resolution,
      );

  Future<void> setAsmrDownloadConflictPolicy(
    AsmrDownloadConflictPolicy policy,
  ) => _setValue(
    unchanged: asmrDownloadConflictPolicy == policy,
    update: () => asmrDownloadConflictPolicy = policy,
  );

  Future<void> _setValue({
    required bool unchanged,
    required void Function() update,
  }) async {
    if (unchanged) return;
    update();
    syncSlice(isInitialized: slice.state.isInitialized);
    await _persist?.call();
  }

  void syncSlice({bool isInitialized = false}) {
    slice.update(
      SettingsState(
        converterFormat: converterFormat,
        converterBitrate: converterBitrate,
        multiThreadPlaybackEnabled: multiThreadPlaybackEnabled,
        notificationsEnabled: notificationsEnabled,
        showPlaybackCard: showPlaybackCard,
        autoPlayAddedSessions: autoPlayAddedSessions,
        autoCheckUpdates: autoCheckUpdates,
        dlsiteMetadataLanguage: dlsiteMetadataLanguage,
        cardInfoFields: List<CardInfoField>.unmodifiable(cardInfoFields),
        cardPositionsLocked: cardPositionsLocked,
        customEqPresets: List<EqPreset>.unmodifiable(customEqPresets),
        maxCacheBytes: maxCacheBytes,
        asmrPlaybackCacheEnabled: asmrPlaybackCacheEnabled,
        recordPlaybackProgress: recordPlaybackProgress,
        blurPlayerBackgroundEnabled: blurPlayerBackgroundEnabled,
        uiBlurEffectEnabled: uiBlurEffectEnabled,
        hapticFeedbackEnabled: hapticFeedbackEnabled,
        startupPage: startupPage,
        bottomNavigationStyle: bottomNavigationStyle,
        coverImageResolution: coverImageResolution,
        asmrDownloadDestinationRoot: asmrDownloadDestinationRoot,
        asmrDownloadConflictPolicy: asmrDownloadConflictPolicy,
        isInitialized: isInitialized,
      ),
    );
  }

  Future<void> dispose() => slice.dispose();
}
