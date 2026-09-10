import '../../core/platform/windows_desktop_service.dart';
import '../../features/asmr/presentation/asmr_providers.dart';
import '../../features/library/presentation/library_providers.dart';
import '../../features/player/presentation/playback_providers.dart';
import '../../features/settings/presentation/settings_providers.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:flutter_riverpod/misc.dart' show Override;

import '../application/app_persistence_coordinator.dart';
import '../application/audio_path_coordinator.dart';
import '../application/playback_queue_coordinator.dart';
import '../application/app_runtime_lifecycle.dart';
import '../application/audio_ui_warmup_coordinator.dart';
import '../application/playback_command_coordinator.dart';
import '../application/playback_keep_alive_coordinator.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/playback_time_segment_service.dart';
import '../../features/player/application/timer_facade.dart';
import '../../core/ui/ui_operation_service.dart';
import '../../core/ui/undoable_removal_service.dart';
import '../theme/theme_provider.dart';
import '../localization/app_language_provider.dart';
import '../../features/settings/application/permission_status_service.dart';
import '../../features/settings/application/settings_command_controller.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/data_support/application/data_support_file_service.dart';
import '../../features/data_support/application/data_backup_service.dart';
import '../../features/data_support/application/storage_usage_service.dart';
import '../../core/ui/interaction_deferred_stream.dart';
import '../../core/platform/file_cache_platform_gateway.dart';
import '../../core/platform/app_lifecycle_platform_service.dart';
import '../../core/platform/power_platform_gateway.dart';
import '../../core/platform/power_platform_service.dart';
import '../../core/platform/video_display_platform_gateway.dart';
import '../../core/platform/video_display_platform_service.dart';
import '../../features/video_converter/application/video_conversion_coordinator.dart';

final themeProviderInstanceProvider = ChangeNotifierProvider<ThemeProvider>(
  (ref) => ThemeProvider(),
);

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

final permissionStatusServiceProvider = Provider<PermissionStatusService>((
  ref,
) {
  final overlay = ref.watch(subtitleOverlayControllerProvider);
  final updates = ref.watch(appUpdateServiceProvider);
  return PermissionStatusService(
    subtitleOverlayController: overlay,
    appUpdateService: updates,
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

final videoDisplayPlatformGatewayProvider =
    Provider<VideoDisplayPlatformGateway>((_) => VideoDisplayPlatformService());

final powerPlatformGatewayProvider = Provider<PowerPlatformGateway>(
  (_) => PowerPlatformService(),
);

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
    library: ref.watch(libraryFacadeProvider),
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

final settingsCommandControllerProvider = Provider<SettingsCommandController>((
  ref,
) {
  return SettingsCommandController(
    settings: ref.watch(settingsRepositoryProvider),
    playback: ref.watch(playbackFacadeProvider),
    notifications: ref.watch(notificationFacadeProvider),
    library: ref.watch(libraryFacadeProvider),
  );
});

final uiOperationServiceProvider = Provider<UiOperationService>((ref) {
  throw UnimplementedError(
    'uiOperationServiceProvider must be overridden in ProviderScope.',
  );
});

final undoableRemovalServiceProvider = Provider<UndoableRemovalService>((ref) {
  return UndoableRemovalService.instance;
});

final _undoableRemovalChangesProvider = StreamProvider<UndoableRemovalState>((
  ref,
) {
  return ref.watch(undoableRemovalServiceProvider).changes;
});

final undoableRemovalStateProvider = Provider<UndoableRemovalState>((ref) {
  ref.watch(_undoableRemovalChangesProvider);
  return ref.watch(undoableRemovalServiceProvider).state;
});

final isUndoableRemovalHiddenProvider = Provider.autoDispose
    .family<bool, UndoableRemovalKey>((ref, key) {
      return ref.watch(undoableRemovalStateProvider).isHidden(key);
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

final videoConversionCoordinatorProvider =
    ChangeNotifierProvider<VideoConversionCoordinator>((ref) {
      final uiOps = ref.watch(uiOperationServiceProvider);
      return VideoConversionCoordinator(uiOperationService: uiOps);
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
  UndoableRemovalService? undoableRemovalService,
  PowerPlatformGateway? powerPlatformGateway,
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
    powerPlatformGatewayProvider.overrideWithValue(
      powerPlatformGateway ?? timer.powerPlatformService,
    ),
    uiOperationServiceProvider.overrideWithValue(
      uiOperationService ?? UiOperationService.instance,
    ),
    undoableRemovalServiceProvider.overrideWithValue(
      undoableRemovalService ?? UndoableRemovalService.instance,
    ),
  ];
}

final windowsFullscreenSetterProvider = Provider<Future<void> Function(bool)>(
  (ref) => WindowsDesktopService.instance.setFullscreen,
);
