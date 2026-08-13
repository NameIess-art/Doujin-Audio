import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/ui/app_interaction_feedback_settings.dart';
import '../../core/platform/file_cache_platform_gateway.dart';
import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/settings/application/settings_repository.dart';
import 'app_lifecycle_binding.dart';
import 'app_persistence_coordinator.dart';
import 'app_runtime_lifecycle.dart';
import 'audio_path_coordinator.dart';
import 'audio_ui_warmup_coordinator.dart';
import 'library_runtime_binding.dart';
import 'notification_runtime_binding.dart';
import 'playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';
import 'playback_runtime_binding.dart';
import 'persisted_uri_permission_coordinator.dart';
import 'runtime_binding.dart';
import 'timer_runtime_binding.dart';

typedef AppRuntimeGraph = ({
  AudioPathCoordinator audioPaths,
  AppRuntimeLifecycle runtime,
  AudioUiWarmupCoordinator warmup,
  AppPersistenceCoordinator persistence,
  LibraryFacade library,
  NotificationFacade notifications,
  PlaybackFacade playback,
  PlaybackCommandCoordinator playbackCommands,
  PlaybackKeepAliveCoordinator keepAlive,
  PlaybackSubtitleService subtitles,
  SettingsRepository settings,
  TimerFacade timer,
});

/// Creates feature owners and aggregates their disposable runtime bindings.
AppRuntimeGraph createAppRuntimeGraph({
  required LibraryFacade library,
  required PlaybackFacade playback,
  required TimerFacade timer,
  required NotificationFacade notifications,
  required SettingsRepository settings,
  AsmrDownloadManager? asmrDownloads,
  FileCachePlatformGateway? fileCacheGateway,
  bool persistenceEnabled = true,
}) {
  final audioPaths = AudioPathCoordinator(library: library, playback: playback);
  final subtitles = PlaybackSubtitleService(
    trackResolver: audioPaths.trackByPath,
    onTrackLoaded: notifications.handleSubtitleTrackLoaded,
  );
  final warmup = AudioUiWarmupCoordinator(
    library: library,
    playback: playback,
    notifications: notifications,
    subtitles: subtitles,
  );
  final keepAlive = PlaybackKeepAliveCoordinator(
    playback: playback,
    settings: settings,
    enterBackgroundWarmup: warmup.enterBackground,
    resumeForegroundWarmup: warmup.resumeForeground,
  );

  void syncLibraryState() {
    library.syncPresentationState();
    unawaited(library.ensureCardSnapshot());
  }

  void syncPlaybackState() {
    playback.syncPresentationState(
      focusedSessionId: notifications.focusedSessionId,
      multiThreadPlaybackEnabled: settings.multiThreadPlaybackEnabled,
      coverGeneration: library.coverArtworkCacheService.generation,
    );
    notifications.syncPresentationState(
      activeQueueLength: playback.activeSessions.length,
    );
  }

  void syncTimerState() => timer.syncPresentationState();

  void syncSettingsState() {
    settings.syncSlice(isInitialized: settings.slice.state.isInitialized);
    AppInteractionFeedbackSettings.hapticFeedbackEnabled =
        settings.hapticFeedbackEnabled;
  }

  void syncAllState() {
    syncLibraryState();
    syncPlaybackState();
    syncTimerState();
    syncSettingsState();
  }

  final playbackCommands = PlaybackCommandCoordinator(
    library: library,
    playback: playback,
    timer: timer,
    notifications: notifications,
    settings: settings,
    audioPaths: audioPaths,
    subtitles: subtitles,
    keepAlive: keepAlive,
    notifyPlaybackChanged: syncPlaybackState,
    syncNotificationState: notifications.syncPlaybackState,
  );

  library.configurePersistence(enabled: persistenceEnabled);
  playback.configurePersistence(enabled: persistenceEnabled);
  final bindings = <RuntimeBinding>[
    LibraryRuntimeBinding.attach(
      library: library,
      playback: playback,
      notifications: notifications,
      syncLibraryState: syncLibraryState,
      syncPlaybackState: syncPlaybackState,
      preferEmbeddedAudioCover: () => settings.preferEmbeddedAudioCover,
    ),
    PlaybackRuntimeBinding.attach(
      library: library,
      playback: playback,
      notifications: notifications,
      settings: settings,
      playbackCommands: playbackCommands,
      keepAlive: keepAlive,
      syncPlaybackState: syncPlaybackState,
    ),
    TimerRuntimeBinding.attach(
      timer: timer,
      playback: playback,
      notifications: notifications,
      playbackCommands: playbackCommands,
      keepAlive: keepAlive,
      syncTimerState: syncTimerState,
    ),
    NotificationRuntimeBinding.attach(
      library: library,
      playback: playback,
      notifications: notifications,
      settings: settings,
      playbackCommands: playbackCommands,
      keepAlive: keepAlive,
      subtitles: subtitles,
      syncAllState: syncAllState,
      syncPlaybackState: syncPlaybackState,
    ),
  ];
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      asmrDownloads != null) {
    bindings.add(
      PersistedUriPermissionCoordinator.attach(
        library: library,
        playback: playback,
        downloads: asmrDownloads,
        gateway: fileCacheGateway,
      ),
    );
  }
  final persistence = AppPersistenceCoordinator(
    library: library,
    playback: playback,
    settings: settings,
    timer: timer,
    notifications: notifications,
    playbackCommands: playbackCommands,
    keepAlive: keepAlive,
    uiWarmup: warmup,
    subtitles: subtitles,
  );
  final runtime = AppLifecycleBinding.attach(
    persistence: persistence,
    library: library,
    playback: playback,
    timer: timer,
    notifications: notifications,
    settings: settings,
    warmup: warmup,
    keepAlive: keepAlive,
    playbackCommands: playbackCommands,
    asmrDownloads: asmrDownloads,
    bindings: bindings,
  );
  syncAllState();
  return (
    audioPaths: audioPaths,
    runtime: runtime,
    warmup: warmup,
    persistence: persistence,
    library: library,
    notifications: notifications,
    playback: playback,
    playbackCommands: playbackCommands,
    keepAlive: keepAlive,
    subtitles: subtitles,
    settings: settings,
    timer: timer,
  );
}
