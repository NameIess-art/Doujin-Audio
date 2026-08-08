import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';

import '../application/app_persistence_coordinator.dart';
import '../application/audio_path_coordinator.dart';
import '../application/playback_queue_coordinator.dart';
import '../application/app_runtime_lifecycle.dart';
import '../application/audio_ui_warmup_coordinator.dart';
import '../application/playback_command_coordinator.dart';
import '../application/playback_keep_alive_coordinator.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/application/library_state_models.dart';
import '../../features/library/presentation/library_cover_ui_controller.dart';
import '../../features/player/application/audio_state_services.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_session.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/playback_time_segment_service.dart';
import '../../features/player/application/subtitle_overlay_controller.dart';
import '../../features/player/application/timer_facade.dart';
import '../../core/ui/ui_operation_service.dart';
import '../presentation/audio_ui_controllers.dart';
import '../presentation/app_interaction_effects_controller.dart';
import '../presentation/screen_view_models.dart';
import '../theme/theme_provider.dart';
import '../localization/app_language_provider.dart';
import '../../features/settings/application/app_update_service.dart';
import '../../features/settings/application/settings_command_controller.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/data_support/application/data_support_file_service.dart';
import '../../features/data_support/application/data_backup_service.dart';
import '../../features/data_support/application/storage_usage_service.dart';
import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/asmr/application/asmr_library_controller.dart';
import '../../features/asmr/application/asmr_playback_coordinator.dart';
import '../../features/asmr/domain/asmr_models.dart';
import 'subtitle_settings_provider.dart';
import 'interaction_deferred_stream.dart';
import '../../core/platform/file_cache_platform_gateway.dart';
import '../../core/platform/app_lifecycle_platform_service.dart';

final themeProviderInstanceProvider = Provider<ThemeProvider>((ref) {
  throw UnimplementedError(
    'themeProviderInstanceProvider must be overridden in ProviderScope.',
  );
});

final appLanguageProviderInstanceProvider = Provider<AppLanguageProvider>((
  ref,
) {
  throw UnimplementedError(
    'appLanguageProviderInstanceProvider must be overridden in ProviderScope.',
  );
});

final appLanguageStateProvider = StreamProvider<AppLanguageState>((ref) {
  final controller = ref.watch(appLanguageProviderInstanceProvider);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => AppLanguageState.from(controller),
  );
});

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  throw UnimplementedError(
    'appUpdateServiceProvider must be overridden in ProviderScope.',
  );
});

final appPersistenceCoordinatorProvider = Provider<AppPersistenceCoordinator>((
  ref,
) {
  throw UnimplementedError(
    'appPersistenceCoordinatorProvider must be overridden in ProviderScope.',
  );
});

final dataSupportFileServiceProvider = Provider<DataSupportFileService>((ref) {
  return DataSupportFileService(
    appUpdateService: ref.watch(appUpdateServiceProvider),
    backupService: ref.watch(dataBackupServiceProvider),
  );
});

final appLifecyclePlatformServiceProvider =
    Provider<AppLifecyclePlatformService>((_) => AppLifecyclePlatformService());

final dataBackupServiceProvider = Provider<DataBackupService>((ref) {
  return DataBackupService(
    appUpdateService: ref.watch(appUpdateServiceProvider),
    beforeExport: () async {
      await ref.read(libraryFacadeProvider).flushPendingPersistence();
      await ref.read(playbackFacadeProvider).flushSessionStatePersistence();
      await ref.read(asmrDownloadManagerProvider)?.flushPersistence();
    },
  );
});

final dataSupportStorageUsageServiceProvider = Provider<StorageUsageService>((
  ref,
) {
  final library = ref.watch(libraryFacadeProvider);
  return StorageUsageService(
    fileCacheGateway: FileCachePlatformGateway.instance,
    libraryTracks: () => library.library,
  );
});

final asmrDownloadManagerProvider = Provider<AsmrDownloadManager?>((ref) {
  return null;
});

final asmrLibraryControllerProvider = Provider<AsmrLibraryController?>((ref) {
  return null;
});

final asmrLibraryGlobalStateProvider =
    StreamProvider<AsmrLibraryGlobalViewState?>((ref) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      return interactionDeferredListenableStream(
        source: controller,
        read: () => controller.globalViewState,
      );
    });

typedef AsmrCategoryStateRequest = ({
  AsmrCategoryType category,
  String searchQuery,
});

final asmrCategoryStateProvider = StreamProvider.autoDispose
    .family<AsmrCategoryViewState?, AsmrCategoryStateRequest>((ref, request) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      return interactionDeferredListenableStream(
        source: controller,
        read: () => controller.categoryViewState(
          request.category,
          searchQuery: request.searchQuery,
        ),
      );
    });

final asmrAuthStateProvider = StreamProvider<AsmrAuthViewState?>((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => controller.authViewState,
  );
});

final asmrTrackTreeStateProvider = StreamProvider.autoDispose
    .family<AsmrTrackTreeViewState?, int>((ref, workId) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      return interactionDeferredListenableStream(
        source: controller,
        read: () => controller.trackTreeViewState(workId),
      );
    });

final asmrSyncStateProvider = StreamProvider<AsmrSyncViewState?>((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => controller.syncViewState,
  );
});

final asmrPlaybackCoordinatorProvider = Provider<AsmrPlaybackCoordinator?>(
  (ref) => null,
);

final asmrDownloadStateProvider = StreamProvider<AsmrDownloadState>((ref) {
  final manager = ref.watch(asmrDownloadManagerProvider);
  if (manager == null) return Stream.value(AsmrDownloadState.empty);
  return interactionDeferredListenableStream(
    source: manager,
    read: () => manager.state,
  );
});

final asmrDownloadTaskProvider = Provider.autoDispose
    .family<AsmrDownloadTaskSnapshot?, int>((ref, workId) {
      final manager = ref.watch(asmrDownloadManagerProvider);
      return ref.watch(asmrDownloadStateProvider).value?.taskFor(workId) ??
          manager?.getTask(workId);
    });

final themeStateProvider = StreamProvider<ThemeState>((ref) {
  final controller = ref.watch(themeProviderInstanceProvider);
  return interactionDeferredListenableStream(
    source: controller,
    read: () => ThemeState.from(controller),
  );
});

final audioRuntimeCoordinatorProvider = Provider<AppRuntimeLifecycle>((ref) {
  throw UnimplementedError(
    'audioRuntimeCoordinatorProvider must be overridden in ProviderScope.',
  );
});

final audioUiWarmupCoordinatorProvider = Provider<AudioUiWarmupCoordinator>((
  ref,
) {
  throw UnimplementedError(
    'audioUiWarmupCoordinatorProvider must be overridden in ProviderScope.',
  );
});

final playbackCommandCoordinatorProvider = Provider<PlaybackCommandCoordinator>(
  (ref) {
    throw UnimplementedError(
      'playbackCommandCoordinatorProvider must be overridden in ProviderScope.',
    );
  },
);

final playbackKeepAliveCoordinatorProvider =
    Provider<PlaybackKeepAliveCoordinator>((ref) {
      throw UnimplementedError(
        'playbackKeepAliveCoordinatorProvider must be overridden in ProviderScope.',
      );
    });

final libraryFacadeProvider = Provider<LibraryFacade>((ref) {
  throw UnimplementedError(
    'libraryFacadeProvider must be overridden in ProviderScope.',
  );
});

final playbackFacadeProvider = Provider<PlaybackFacade>((ref) {
  throw UnimplementedError(
    'playbackFacadeProvider must be overridden in ProviderScope.',
  );
});

final playbackSubtitleServiceProvider = Provider<PlaybackSubtitleService>((
  ref,
) {
  throw UnimplementedError(
    'playbackSubtitleServiceProvider must be overridden in ProviderScope.',
  );
});

final audioPathCoordinatorProvider = Provider<AudioPathCoordinator>((ref) {
  return AudioPathCoordinator(
    library: ref.watch(libraryFacadeProvider),
    playback: ref.watch(playbackFacadeProvider),
  );
});

final playbackQueueCoordinatorProvider = Provider<PlaybackQueueCoordinator>((
  ref,
) {
  return PlaybackQueueCoordinator(
    playback: ref.watch(playbackFacadeProvider),
    paths: ref.watch(audioPathCoordinatorProvider),
  );
});

final playbackTimeSegmentServiceProvider = Provider<PlaybackTimeSegmentService>(
  (ref) {
    final service = PlaybackTimeSegmentService(
      database: ref.watch(playbackFacadeProvider).databaseRepository,
      playback: ref.watch(playbackFacadeProvider),
      paths: ref.watch(audioPathCoordinatorProvider),
    );
    ref.onDispose(service.dispose);
    return service;
  },
);

final subtitleOverlayControllerProvider = Provider<SubtitleOverlayController>((
  ref,
) {
  final controller = SubtitleOverlayController();
  ref.onDispose(controller.dispose);
  return controller;
});

final timerFacadeProvider = Provider<TimerFacade>((ref) {
  throw UnimplementedError(
    'timerFacadeProvider must be overridden in ProviderScope.',
  );
});

final notificationFacadeProvider = Provider<NotificationFacade>((ref) {
  throw UnimplementedError(
    'notificationFacadeProvider must be overridden in ProviderScope.',
  );
});

final mainScreenControllerProvider = Provider<MainScreenController>((ref) {
  final controller = MainScreenController();
  ref.onDispose(controller.dispose);
  return controller;
});

final playlistUiControllerProvider = Provider<PlaylistUiController>((ref) {
  final controller = PlaylistUiController(
    ref.watch(playbackFacadeProvider).sessionActivations,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError(
    'settingsRepositoryProvider must be overridden in ProviderScope.',
  );
});

final settingsCommandControllerProvider = Provider<SettingsCommandController>((
  ref,
) {
  return SettingsCommandController(
    settings: ref.watch(settingsRepositoryProvider),
    playback: ref.watch(playbackFacadeProvider),
    notifications: ref.watch(notificationFacadeProvider),
  );
});

final uiOperationServiceProvider = Provider<UiOperationService>((ref) {
  throw UnimplementedError(
    'uiOperationServiceProvider must be overridden in ProviderScope.',
  );
});

final _uiOperationScopeStateChangesProvider = StreamProvider.autoDispose
    .family<UiOperationState, UiOperationScope>((ref, scope) {
      final service = ref.watch(uiOperationServiceProvider);
      return service.changes
          .where((changedScope) => changedScope == scope)
          .map((_) => service.operationFor(scope));
    });

final uiOperationForScopeProvider = Provider.autoDispose
    .family<UiOperationState, UiOperationScope>((ref, scope) {
      ref.watch(_uiOperationScopeStateChangesProvider(scope));
      return ref.watch(uiOperationServiceProvider).operationFor(scope);
    });

final libraryStateProvider = StreamProvider<LibraryState>((ref) {
  return interactionDeferredValueStream(
    ref.watch(libraryFacadeProvider).states,
  );
});

final libraryCoverUiControllerProvider = Provider<LibraryCoverUiController>((
  ref,
) {
  final controller = LibraryCoverUiController(
    library: ref.watch(libraryFacadeProvider),
  );
  ref.onDispose(() => unawaited(controller.dispose()));
  return controller;
});

final appInteractionEffectsControllerProvider =
    Provider<AppInteractionEffectsController>((ref) {
      final controller = AppInteractionEffectsController(
        library: ref.watch(libraryFacadeProvider),
        libraryCovers: ref.watch(libraryCoverUiControllerProvider),
        notifications: ref.watch(notificationFacadeProvider),
        warmup: ref.watch(audioUiWarmupCoordinatorProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final playbackStateProvider = StreamProvider<PlaybackStateSliceData>((ref) {
  return ref.watch(playbackFacadeProvider).states;
});

final timerStateProvider = StreamProvider<TimerStateSliceData>((ref) {
  return ref.watch(timerFacadeProvider).states;
});

final settingsStateProvider = StreamProvider<SettingsState>((ref) {
  return ref.watch(settingsRepositoryProvider).slice.stream;
});

final notificationStateProvider = StreamProvider<NotificationState>((ref) {
  return ref.watch(notificationFacadeProvider).states;
});

final libraryHeaderUiProvider = Provider<LibraryHeaderState>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  final state = ref.watch(libraryStateProvider).value ?? serviceState;
  final refreshOperation = ref.watch(
    uiOperationForScopeProvider(UiOperationScope.libraryRefresh),
  );
  final libraryState = LibraryState(
    libraryTrackCount: state.libraryTrackCount,
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isInitialized: state.isInitialized,
  );
  return libraryHeaderStateFromSlice(
    libraryState,
    isRefreshing: refreshOperation.isBusy || state.isScanning,
    operationProgress: refreshOperation.progress,
    operationError: refreshOperation.error,
  );
});

final libraryListUiProvider = Provider<LibraryListState>((ref) {
  final facade = ref.watch(libraryFacadeProvider);
  final serviceState = facade.state;
  final state = ref.watch(libraryStateProvider).value ?? serviceState;
  final refreshOperation = ref.watch(
    uiOperationForScopeProvider(UiOperationScope.libraryRefresh),
  );
  final showForegroundScan = state.isScanning && !state.isBackgroundScanning;
  final libraryState = LibraryState(
    watchedFolderCount: state.watchedFolderCount,
    watchedLibraryCount: state.watchedLibraryCount,
    isScanning: showForegroundScan,
    isBackgroundScanning: state.isBackgroundScanning,
    scanCurrentFolder: showForegroundScan ? state.scanCurrentFolder : '',
    scanFoundCount: showForegroundScan ? state.scanFoundCount : 0,
    scanDuplicateCount: showForegroundScan ? state.scanDuplicateCount : 0,
    scanFailureCount: showForegroundScan ? state.scanFailureCount : 0,
    structureRevision: state.treeSnapshotRevision,
    contentRevision: state.contentRevision,
    isInitialized: state.isInitialized,
  );
  return LibraryListState(
    rawTree: facade.libraryCards,
    watchedFolders: facade.watchedFolders,
    watchedLibraries: facade.watchedLibraries,
    watchedFolderCount: libraryState.watchedFolderCount,
    watchedLibraryCount: libraryState.watchedLibraryCount,
    isScanning: libraryState.isScanning,
    isBackgroundScanning: libraryState.isBackgroundScanning,
    structureRevision: libraryState.structureRevision,
    isInitialized: libraryState.isInitialized,
    isRefreshing: refreshOperation.isBusy || state.isScanning,
    operationProgress: refreshOperation.progress,
    operationError: refreshOperation.error,
  );
});

final libraryScanUiProvider = Provider<LibraryScanUiState>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  final state = ref.watch(libraryStateProvider).value ?? serviceState;
  return LibraryScanUiState(
    isScanning: state.isScanning,
    isBackgroundScanning: state.isBackgroundScanning,
    source: state.scanCurrentFolder,
    stage: state.scanStage,
    processed: state.scanProcessed,
    total: state.scanTotal,
    foundCount: state.scanFoundCount,
    duplicateCount: state.scanDuplicateCount,
    failureCount: state.scanFailureCount,
  );
});

final libraryDetailRevisionProvider = Provider<int>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  return ref.watch(libraryStateProvider).value?.detailRevision ??
      serviceState.detailRevision;
});

final libraryCategoryRevisionProvider = Provider<int>((ref) {
  final serviceState = ref.watch(libraryFacadeProvider).state;
  return ref.watch(libraryStateProvider).value?.categorySnapshotRevision ??
      serviceState.categorySnapshotRevision;
});

final libraryDetailForTargetProvider = FutureProvider.autoDispose
    .family<AudioDetail, AudioDetailTarget>((ref, target) async {
      ref.watch(libraryDetailRevisionProvider);
      final facade = ref.read(libraryFacadeProvider);
      final canonicalTarget = facade.canonicalAudioDetailTarget(target);
      final snapshot = facade.categorySnapshot;
      final detail =
          facade.resolvedAudioDetail(canonicalTarget) ??
          snapshot?.detailFor(canonicalTarget);
      if (detail != null) return detail;
      return (await facade.loadAudioDetail(canonicalTarget)).detail;
    });

final libraryCoverForTrackProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, trackPath) async {
      ref.watch(coverGenerationProvider);
      final facade = ref.read(libraryFacadeProvider);
      final track = facade.trackByPath(trackPath);
      if (track == null || track.isVideo) return null;
      final resolved = facade.resolvedCoverPathForTrack(track);
      if (resolved != null && resolved.isNotEmpty) return resolved;
      return ref
          .read(libraryCoverUiControllerProvider)
          .deferredTrackCover(track);
    });

final playlistHeaderUiProvider = Provider<PlaylistHeaderState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  final timerState =
      ref.watch(timerStateProvider).value ??
      ref.watch(timerFacadeProvider).state;
  return playlistHeaderStateFromSlices(playbackState, timerState);
});

final playlistListUiProvider = Provider<PlaylistListState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  return PlaylistListState(
    sessions: playbackState.activeSessions,
    cardStates: playlistSessionCardStatesFromPlaybackState(playbackState),
    coverGeneration: playbackState.coverGeneration,
    isInitialized: playbackState.isInitialized,
  );
});

final playlistStructureUiProvider = Provider<PlaylistStructureState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  return playlistStructureStateFromPlaybackState(playbackState);
});

final playlistSessionCardStateProvider = Provider.autoDispose
    .family<PlaylistSessionCardState?, String>((ref, sessionId) {
      final playbackState =
          ref.watch(playbackStateProvider).value ??
          ref.watch(playbackFacadeProvider).state;
      for (final session in playbackState.activeSessions) {
        if (session.id == sessionId) {
          return playlistSessionCardStateFromSession(session);
        }
      }
      return null;
    });

final coverGenerationProvider = Provider<int>((ref) {
  return ref.watch(playbackStateProvider).value?.coverGeneration ??
      ref.watch(playbackFacadeProvider).state.coverGeneration;
});

final coverImageResolutionProvider = Provider<CoverImageResolution>((ref) {
  return ref.watch(settingsStateProvider).value?.coverImageResolution ??
      ref.watch(settingsRepositoryProvider).slice.state.coverImageResolution;
});

final coverImageDisplayModeProvider = Provider<CoverImageDisplayMode>((ref) {
  return ref.watch(settingsStateProvider).value?.coverImageDisplayMode ??
      ref.watch(settingsRepositoryProvider).slice.state.coverImageDisplayMode;
});

final libraryTrackProvider = Provider.autoDispose.family<MusicTrack?, String>((
  ref,
  trackPath,
) {
  ref.watch(
    libraryStateProvider.select((state) => state.value?.contentRevision ?? 0),
  );
  return ref.read(libraryFacadeProvider).trackByPath(trackPath);
});

final activeTrackPathsProvider = Provider<ActiveTrackPaths>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  return ActiveTrackPaths(
    playbackState.activeSessions
        .map((session) => session.currentTrackPath)
        .where((path) => path.isNotEmpty)
        .toSet(),
  );
});

final isTrackActiveProvider = Provider.autoDispose.family<bool, String>((
  ref,
  trackPath,
) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  return playbackState.activeSessions.any(
    (session) => session.currentTrackPath == trackPath,
  );
});

final mainOverlayUiProvider = Provider<MainOverlayUiState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  final settingsState =
      ref.watch(settingsStateProvider).value ??
      ref.watch(settingsRepositoryProvider).slice.state;
  ref.watch(subtitleSettingsProvider);
  final overlaySessions = overlaySessionsFromPlaybackState(playbackState);
  final visibleSessions = settingsState.showPlaybackCard
      ? overlaySessions
      : const <PlaybackSession>[];
  final startupReady = settingsState.isInitialized;
  return MainOverlayUiState(
    overlaySessions: overlaySessions,
    visibleSessions: visibleSessions,
    playingSessionCount: playbackState.playingSessionCount,
    activeSessionCount: playbackState.activeSessions.length,
    showPlaybackCard: settingsState.showPlaybackCard,
    isInitialized: playbackState.isInitialized,
    startupReady: startupReady,
  );
});

final sessionDetailUiProvider = Provider.autoDispose
    .family<SessionDetailUiState, String>((ref, sessionId) {
      final playbackState =
          ref.watch(playbackStateProvider).value ??
          ref.watch(playbackFacadeProvider).state;
      return SessionDetailUiState(
        sessionOrder: sessionOrderStateFromPlaybackState(playbackState),
        detail: sessionDetailViewStateFromPlaybackState(
          playbackState,
          sessionId,
        ),
        coverGeneration: playbackState.coverGeneration,
      );
    });

final sessionDetailTransportProvider = Provider.autoDispose
    .family<SessionDetailViewState?, String>((ref, sessionId) {
      return ref.watch(
        sessionDetailUiProvider(sessionId).select((state) => state.detail),
      );
    });

List<Override> createAppRuntimeOverrides({
  required AppPersistenceCoordinator persistence,
  required AppRuntimeLifecycle runtime,
  required AudioUiWarmupCoordinator warmup,
  required PlaybackCommandCoordinator playbackCommands,
  required PlaybackKeepAliveCoordinator keepAlive,
  required LibraryFacade library,
  required PlaybackFacade playback,
  required PlaybackSubtitleService subtitles,
  required TimerFacade timer,
  required NotificationFacade notifications,
  required SettingsRepository settings,
  UiOperationService? uiOperationService,
}) {
  return <Override>[
    appPersistenceCoordinatorProvider.overrideWithValue(persistence),
    audioRuntimeCoordinatorProvider.overrideWithValue(runtime),
    audioUiWarmupCoordinatorProvider.overrideWithValue(warmup),
    playbackCommandCoordinatorProvider.overrideWithValue(playbackCommands),
    playbackKeepAliveCoordinatorProvider.overrideWithValue(keepAlive),
    libraryFacadeProvider.overrideWithValue(library),
    playbackFacadeProvider.overrideWithValue(playback),
    playbackSubtitleServiceProvider.overrideWithValue(subtitles),
    timerFacadeProvider.overrideWithValue(timer),
    notificationFacadeProvider.overrideWithValue(notifications),
    settingsRepositoryProvider.overrideWithValue(settings),
    uiOperationServiceProvider.overrideWithValue(
      uiOperationService ?? UiOperationService.instance,
    ),
  ];
}
