/// Channel names and method names for all platform channel communication.
///
/// These constants are the single source of truth for Dart↔Kotlin protocol strings.
/// Keep them in sync with the Kotlin side (MainActivity.kt and NativePlaybackBridge.kt).
library;

// ---------------------------------------------------------------------------
// Channel names
// ---------------------------------------------------------------------------
abstract final class NativePlaybackChannel {
  static const String name = 'nameless_audio/native_playback';
  static const String eventName = 'nameless_audio/native_playback/events';
}

abstract final class PowerChannel {
  static const String name = 'nameless_audio/power';
}

abstract final class FileCacheChannel {
  static const String name = 'nameless_audio/file_cache';
}

abstract final class NotificationsChannel {
  static const String name = 'nameless_audio/notifications';
}

abstract final class UpdateChannel {
  static const String name = 'nameless_audio/update';
}

// ---------------------------------------------------------------------------
// Method names — native_playback
// ---------------------------------------------------------------------------
abstract final class NativePlaybackMethod {
  static const String prepareSession = 'prepareSession';
  static const String play = 'play';
  static const String pause = 'pause';
  static const String stop = 'stop';
  static const String seek = 'seek';
  static const String setVolume = 'setVolume';
  static const String setRepeatOne = 'setRepeatOne';
  static const String setChannelSwap = 'setChannelSwap';
  static const String removeSession = 'removeSession';
  static const String pauseAll = 'pauseAll';
  static const String clearAll = 'clearAll';
  static const String setForegroundEnabled = 'setForegroundEnabled';
  static const String dismissNotifications = 'dismissNotifications';
  static const String undismissNotifications = 'undismissNotifications';
  static const String snapshot = 'snapshot';
}

abstract final class NativePlaybackMethods {
  static const String prepareSession = NativePlaybackMethod.prepareSession;
  static const String play = NativePlaybackMethod.play;
  static const String pause = NativePlaybackMethod.pause;
  static const String stop = NativePlaybackMethod.stop;
  static const String seek = NativePlaybackMethod.seek;
  static const String setVolume = NativePlaybackMethod.setVolume;
  static const String setRepeatOne = NativePlaybackMethod.setRepeatOne;
  static const String setChannelSwap = NativePlaybackMethod.setChannelSwap;
  static const String removeSession = NativePlaybackMethod.removeSession;
  static const String pauseAll = NativePlaybackMethod.pauseAll;
  static const String clearAll = NativePlaybackMethod.clearAll;
  static const String setForegroundEnabled =
      NativePlaybackMethod.setForegroundEnabled;
  static const String dismissNotifications =
      NativePlaybackMethod.dismissNotifications;
  static const String undismissNotifications =
      NativePlaybackMethod.undismissNotifications;
  static const String snapshot = NativePlaybackMethod.snapshot;
}

// ---------------------------------------------------------------------------
// Method names — power
// ---------------------------------------------------------------------------
abstract final class PowerMethod {
  static const String stopPlaybackKeepAlive = 'stopPlaybackKeepAlive';
  static const String syncPlaybackTimerAlarms = 'syncPlaybackTimerAlarms';
  static const String setKeepCpuAwake = 'setKeepCpuAwake';
  static const String canManageAllFilesAccess = 'canManageAllFilesAccess';
  static const String openManageAllFilesAccessSettings =
      'openManageAllFilesAccessSettings';
  static const String isIgnoringBatteryOptimizations =
      'isIgnoringBatteryOptimizations';
  static const String openBatteryOptimizationSettings =
      'openBatteryOptimizationSettings';
  static const String openBackgroundRunSettings = 'openBackgroundRunSettings';
  static const String canScheduleExactAlarms = 'canScheduleExactAlarms';
  static const String openExactAlarmSettings = 'openExactAlarmSettings';
  static const String getNativeTimerRuntimeState = 'getNativeTimerRuntimeState';
  static const String executeTimerExpiredNow = 'executeTimerExpiredNow';
  static const String executeAutoResumeNow = 'executeAutoResumeNow';
}

// ---------------------------------------------------------------------------
// Method names — file_cache
// ---------------------------------------------------------------------------
abstract final class FileCacheMethod {
  static const String discoverRootImages = 'discoverRootImages';
  static const String resolveTrackCover = 'resolveTrackCover';
  static const String resolveVideoFrame = 'resolveVideoFrame';
  static const String cacheFromUri = 'cacheFromUri';
  static const String scanFolder = 'scanFolder';
  static const String listChildFolders = 'listChildFolders';
  static const String renameDocument = 'renameDocument';
  static const String readAudioDetailBackup = 'readAudioDetailBackup';
  static const String writeAudioDetailBackup = 'writeAudioDetailBackup';
  static const String readSingleFileDetailBackup = 'readSingleFileDetailBackup';
  static const String writeSingleFileDetailBackup =
      'writeSingleFileDetailBackup';
  static const String writeFileBytesToFolder = 'writeFileBytesToFolder';
  static const String documentPathExists = 'documentPathExists';
  static const String ensureFolderPath = 'ensureFolderPath';
  static const String copyFileToFolder = 'copyFileToFolder';
  static const String deleteDocumentPath = 'deleteDocumentPath';
  static const String clearApplicationCache = 'clearApplicationCache';
  static const String setApplicationCacheLimit = 'setApplicationCacheLimit';
  static const String enforceApplicationCacheLimit =
      'enforceApplicationCacheLimit';
  static const String pickAudioSource = 'pickAudioSource';
  static const String pickAudioFiles = 'pickAudioFiles';
  static const String pickAudioFolder = 'pickAudioFolder';
}

// ---------------------------------------------------------------------------
// Method names — notifications
// ---------------------------------------------------------------------------
abstract final class NotificationsMethod {
  static const String syncUnifiedPlaybackNotifications =
      'syncUnifiedPlaybackNotifications';
  static const String clearUnifiedPlaybackNotifications =
      'clearUnifiedPlaybackNotifications';
  static const String areNotificationsEnabled = 'areNotificationsEnabled';
  static const String openNotificationSettings = 'openNotificationSettings';
  static const String consumePendingNotificationSessionId =
      'consumePendingNotificationSessionId';

  /// Sent from Kotlin to Dart (not invoked from Dart).
  static const String openSessionFromNotification =
      'openSessionFromNotification';
}

// ---------------------------------------------------------------------------
// Method names — update
// ---------------------------------------------------------------------------
abstract final class UpdateMethod {
  static const String getAppVersion = 'getAppVersion';
  static const String canInstallUnknownApps = 'canInstallUnknownApps';
  static const String openInstallPermissionSettings =
      'openInstallPermissionSettings';
  static const String installApk = 'installApk';
}
