import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';

import '../application/app_persistence_coordinator.dart';
import '../application/persisted_state_reloader.dart';
import '../application/audio_path_coordinator.dart';
import '../application/playback_queue_coordinator.dart';
import '../application/audio_runtime_coordinator.dart';
import '../application/audio_ui_warmup_coordinator.dart';
import '../application/playback_command_coordinator.dart';
import '../application/playback_keep_alive_coordinator.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/application/library_state_models.dart';
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
import '../presentation/screen_view_models.dart';
import '../theme/theme_provider.dart';
import '../localization/app_language_provider.dart';
import '../../features/settings/application/app_update_service.dart';
import '../../features/settings/application/settings_command_controller.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/data_support/application/backup_restore_coordinator.dart';
import '../../features/data_support/application/data_support_file_service.dart';
import '../../features/asmr/application/asmr_download_manager.dart';
import '../../features/asmr/application/asmr_library_controller.dart';
import '../../features/asmr/application/asmr_playback_coordinator.dart';
import '../../features/asmr/domain/asmr_models.dart';
import 'subtitle_settings_provider.dart';

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
  final states = StreamController<AppLanguageState>.broadcast(sync: true);
  void emit() => states.add(AppLanguageState.from(controller));
  controller.addListener(emit);
  emit();
  ref.onDispose(() {
    controller.removeListener(emit);
    states.close();
  });
  return states.stream;
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
  );
});

final asmrDownloadManagerProvider = Provider<AsmrDownloadManager?>((ref) {
  return null;
});

final asmrLibraryControllerProvider = Provider<AsmrLibraryController?>((ref) {
  return null;
});

final backupRestoreCoordinatorProvider = Provider<BackupRestoreCoordinator>((
  ref,
) {
  final reloaders = <PersistedStateReloader>[
    ref.watch(appPersistenceCoordinatorProvider),
  ];
  final asmr = ref.watch(asmrLibraryControllerProvider);
  if (asmr != null) reloaders.add(asmr);
  return BackupRestoreCoordinator(
    fileService: ref.watch(dataSupportFileServiceProvider),
    reloaders: reloaders,
  );
});

final asmrLibraryGlobalStateProvider =
    StreamProvider<AsmrLibraryGlobalViewState?>((ref) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      final states = StreamController<AsmrLibraryGlobalViewState>.broadcast(
        sync: true,
      );
      void emit() => states.add(controller.globalViewState);
      controller.addListener(emit);
      emit();
      ref.onDispose(() {
        controller.removeListener(emit);
        states.close();
      });
      return states.stream;
    });

final asmrCategoryStateProvider =
    StreamProvider.family<AsmrCategoryViewState?, AsmrCategoryType>((
      ref,
      category,
    ) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      final states = StreamController<AsmrCategoryViewState?>.broadcast(
        sync: true,
      );

      void emit() => states.add(controller.categoryViewState(category));
      controller.addListener(emit);
      emit();
      ref.onDispose(() {
        controller.removeListener(emit);
        states.close();
      });
      return states.stream;
    });

final asmrAuthStateProvider = StreamProvider<AsmrAuthViewState?>((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return Stream<AsmrAuthViewState?>.multi((events) {
    void emit() => events.add(controller.authViewState);
    controller.addListener(emit);
    events.onCancel = () {
      controller.removeListener(emit);
    };
    emit();
  });
});

final asmrTrackTreeStateProvider =
    StreamProvider.family<AsmrTrackTreeViewState?, int>((ref, workId) {
      final controller = ref.watch(asmrLibraryControllerProvider);
      if (controller == null) return Stream.value(null);
      final states = StreamController<AsmrTrackTreeViewState?>.broadcast(
        sync: true,
      );
      void emit() => states.add(controller.trackTreeViewState(workId));
      controller.addListener(emit);
      emit();
      ref.onDispose(() {
        controller.removeListener(emit);
        states.close();
      });
      return states.stream;
    });

final asmrSyncStateProvider = StreamProvider<AsmrSyncViewState?>((ref) {
  final controller = ref.watch(asmrLibraryControllerProvider);
  if (controller == null) return Stream.value(null);
  return Stream<AsmrSyncViewState?>.multi((events) {
    void emit() => events.add(controller.syncViewState);
    controller.addListener(emit);
    events.onCancel = () {
      controller.removeListener(emit);
    };
    emit();
  });
});

final asmrPlaybackCoordinatorProvider = Provider<AsmrPlaybackCoordinator?>(
  (ref) => null,
);

final asmrDownloadStateProvider = StreamProvider<AsmrDownloadState>((ref) {
  final manager = ref.watch(asmrDownloadManagerProvider);
  if (manager == null) return Stream.value(AsmrDownloadState.empty);
  final states = StreamController<AsmrDownloadState>.broadcast(sync: true);
  void emit() => states.add(manager.state);
  manager.addListener(emit);
  emit();
  ref.onDispose(() {
    manager.removeListener(emit);
    states.close();
  });
  return states.stream;
});

final asmrDownloadTaskProvider =
    Provider.family<AsmrDownloadTaskSnapshot?, int>((ref, workId) {
      final manager = ref.watch(asmrDownloadManagerProvider);
      return ref.watch(asmrDownloadStateProvider).value?.taskFor(workId) ??
          manager?.getTask(workId);
    });

final themeStateProvider = StreamProvider<ThemeState>((ref) {
  final controller = ref.watch(themeProviderInstanceProvider);
  final states = StreamController<ThemeState>.broadcast(sync: true);
  void emit() => states.add(ThemeState.from(controller));
  controller.addListener(emit);
  emit();
  ref.onDispose(() {
    controller.removeListener(emit);
    states.close();
  });
  return states.stream;
});

final audioRuntimeCoordinatorProvider = Provider<AudioRuntimeCoordinator>((
  ref,
) {
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
      database: ref.watch(libraryFacadeProvider).databaseRepository,
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

final uiOperationStateProvider = StreamProvider<UiOperationRegistryState>((
  ref,
) {
  return ref.watch(uiOperationServiceProvider).stream;
});

final uiOperationForScopeProvider =
    Provider.family<UiOperationState, UiOperationScope>((ref, scope) {
      ref.watch(uiOperationStateProvider);
      return ref.watch(uiOperationServiceProvider).state.forScope(scope);
    });

final libraryStateProvider = StreamProvider<LibraryState>((ref) {
  return ref.watch(libraryFacadeProvider).states;
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

typedef LibraryDetailUiState = ({AudioDetail? detail, bool isLoading});

final libraryDetailForTargetProvider =
    Provider.family<LibraryDetailUiState, AudioDetailTarget>((ref, target) {
      ref.watch(libraryCategoryRevisionProvider);
      ref.watch(libraryDetailRevisionProvider);
      final facade = ref.read(libraryFacadeProvider);
      final snapshot = facade.categorySnapshot;
      final detail =
          facade.resolvedAudioDetail(target) ?? snapshot?.detailFor(target);
      return (detail: detail, isLoading: detail == null);
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

final coverGenerationProvider = Provider<int>((ref) {
  return ref.watch(playbackStateProvider).value?.coverGeneration ??
      ref.watch(playbackFacadeProvider).state.coverGeneration;
});

final coverImageResolutionProvider = Provider<CoverImageResolution>((ref) {
  return ref.watch(settingsStateProvider).value?.coverImageResolution ??
      ref.watch(settingsRepositoryProvider).slice.state.coverImageResolution;
});

final libraryTrackProvider = Provider.family<MusicTrack?, String>((
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

final isTrackActiveProvider = Provider.family<bool, String>((ref, trackPath) {
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

final sessionDetailUiProvider = Provider.family<SessionDetailUiState, String>((
  ref,
  sessionId,
) {
  final playbackState =
      ref.watch(playbackStateProvider).value ??
      ref.watch(playbackFacadeProvider).state;
  return SessionDetailUiState(
    sessionOrder: sessionOrderStateFromPlaybackState(playbackState),
    detail: sessionDetailViewStateFromPlaybackState(playbackState, sessionId),
    coverGeneration: playbackState.coverGeneration,
  );
});

final sessionDetailTransportProvider =
    Provider.family<SessionDetailViewState?, String>((ref, sessionId) {
      return ref.watch(
        sessionDetailUiProvider(sessionId).select((state) => state.detail),
      );
    });

List<Override> createAppRuntimeOverrides({
  required AppPersistenceCoordinator persistence,
  required AudioRuntimeCoordinator runtime,
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
