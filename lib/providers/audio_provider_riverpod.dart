import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_database_repository.dart';
import '../services/audio_state_services.dart';
import '../services/native_playback_repository.dart';
import '../services/playback_command_runner.dart';
import '../services/ui_operation_service.dart';
import '../screens/screen_view_models.dart';
import 'audio_provider.dart';
import 'subtitle_settings_provider.dart';

// AudioProvider remains the single mutable UI facade. Riverpod providers below
// only expose repositories, service slices, and derived UI projections; they
// must not introduce a second mutable source for playback or library state.
final audioProviderFacadeProvider = Provider<AudioProvider>((ref) {
  throw UnimplementedError(
    'audioProviderFacadeProvider must be overridden in ProviderScope.',
  );
});

final audioDatabaseRepositoryProvider = Provider<AudioDatabaseRepository>((
  ref,
) {
  throw UnimplementedError(
    'audioDatabaseRepositoryProvider must be overridden in ProviderScope.',
  );
});

final nativePlaybackRepositoryProvider = Provider<NativePlaybackRepository>((
  ref,
) {
  throw UnimplementedError(
    'nativePlaybackRepositoryProvider must be overridden in ProviderScope.',
  );
});

final playbackCommandRunnerProvider = Provider<PlaybackCommandRunner>((ref) {
  throw UnimplementedError(
    'playbackCommandRunnerProvider must be overridden in ProviderScope.',
  );
});

final libraryServiceProvider = Provider<LibraryService>((ref) {
  throw UnimplementedError(
    'libraryServiceProvider must be overridden in ProviderScope.',
  );
});

final playbackSessionServiceProvider = Provider<PlaybackSessionService>((ref) {
  throw UnimplementedError(
    'playbackSessionServiceProvider must be overridden in ProviderScope.',
  );
});

final timerServiceProvider = Provider<TimerService>((ref) {
  throw UnimplementedError(
    'timerServiceProvider must be overridden in ProviderScope.',
  );
});

final notificationCoordinatorServiceProvider =
    Provider<NotificationCoordinatorService>((ref) {
      throw UnimplementedError(
        'notificationCoordinatorServiceProvider must be overridden in ProviderScope.',
      );
    });

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError(
    'settingsRepositoryProvider must be overridden in ProviderScope.',
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
      final serviceState = ref.watch(uiOperationServiceProvider).state;
      final asyncState = ref.watch(uiOperationStateProvider).valueOrNull;
      return (asyncState ?? serviceState).forScope(scope);
    });

final libraryStateProvider = StreamProvider<LibraryState>((ref) {
  return ref.watch(libraryServiceProvider).slice.stream;
});

final playbackStateProvider = StreamProvider<PlaybackStateSliceData>((ref) {
  return ref.watch(playbackSessionServiceProvider).slice.stream;
});

final timerStateProvider = StreamProvider<TimerStateSliceData>((ref) {
  return ref.watch(timerServiceProvider).slice.stream;
});

final settingsStateProvider = StreamProvider<SettingsState>((ref) {
  return ref.watch(settingsRepositoryProvider).slice.stream;
});

final notificationStateProvider = StreamProvider<NotificationState>((ref) {
  return ref.watch(notificationCoordinatorServiceProvider).slice.stream;
});

final libraryHeaderUiProvider = Provider<LibraryHeaderState>((ref) {
  final serviceState = ref.watch(libraryServiceProvider).slice.state;
  final state = ref.watch(libraryStateProvider).valueOrNull ?? serviceState;
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
  final serviceState = ref.watch(libraryServiceProvider).slice.state;
  final state = ref.watch(libraryStateProvider).valueOrNull ?? serviceState;
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
    structureRevision: state.structureRevision,
    contentRevision: state.contentRevision,
    isInitialized: state.isInitialized,
  );
  final provider = ref.watch(audioProviderFacadeProvider);
  return LibraryListState(
    rawTree: provider.libraryTree,
    watchedFolders: provider.watchedFolders,
    watchedLibraries: provider.watchedLibraries,
    watchedFolderCount: libraryState.watchedFolderCount,
    watchedLibraryCount: libraryState.watchedLibraryCount,
    isScanning: libraryState.isScanning,
    isBackgroundScanning: libraryState.isBackgroundScanning,
    scanCurrentFolder: libraryState.scanCurrentFolder,
    scanFoundCount: libraryState.scanFoundCount,
    scanDuplicateCount: libraryState.scanDuplicateCount,
    scanFailureCount: libraryState.scanFailureCount,
    structureRevision: libraryState.contentRevision,
    isInitialized: libraryState.isInitialized,
    isRefreshing: refreshOperation.isBusy || state.isScanning,
    operationProgress: refreshOperation.progress,
    operationError: refreshOperation.error,
  );
});

final libraryDetailRevisionProvider = Provider<int>((ref) {
  final serviceState = ref.watch(libraryServiceProvider).slice.state;
  return ref.watch(libraryStateProvider).valueOrNull?.detailRevision ??
      serviceState.detailRevision;
});

final libraryCategoryRevisionProvider = Provider<int>((ref) {
  final serviceState = ref.watch(libraryServiceProvider).slice.state;
  return ref
          .watch(libraryStateProvider)
          .valueOrNull
          ?.categorySnapshotRevision ??
      serviceState.categorySnapshotRevision;
});

final playlistHeaderUiProvider = Provider<PlaylistHeaderState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      ref.watch(playbackSessionServiceProvider).slice.state;
  final timerState =
      ref.watch(timerStateProvider).valueOrNull ??
      ref.watch(timerServiceProvider).slice.state;
  return playlistHeaderStateFromSlices(playbackState, timerState);
});

final playlistListUiProvider = Provider<PlaylistListState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      ref.watch(playbackSessionServiceProvider).slice.state;
  return PlaylistListState(
    sessions: playbackState.activeSessions,
    isInitialized: playbackState.isInitialized,
  );
});

final coverGenerationProvider = Provider<int>((ref) {
  return ref.watch(playbackStateProvider).valueOrNull?.coverGeneration ??
      ref.watch(playbackSessionServiceProvider).slice.state.coverGeneration;
});

final activeTrackPathsProvider = Provider<ActiveTrackPaths>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      ref.watch(playbackSessionServiceProvider).slice.state;
  return ActiveTrackPaths(
    playbackState.activeSessions
        .map((session) => session.currentTrackPath)
        .where((path) => path.isNotEmpty)
        .toSet(),
  );
});

final playlistSessionCardUiProvider =
    Provider.family<PlaylistSessionCardState?, String>((ref, sessionId) {
      final playbackState =
          ref.watch(playbackStateProvider).valueOrNull ??
          ref.watch(playbackSessionServiceProvider).slice.state;
      return playlistSessionCardStateFromPlaybackState(
        playbackState,
        sessionId,
      );
    });

final mainOverlayUiProvider = Provider<MainOverlayUiState>((ref) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      ref.watch(playbackSessionServiceProvider).slice.state;
  final settingsState =
      ref.watch(settingsStateProvider).valueOrNull ??
      ref.watch(settingsRepositoryProvider).slice.state;
  ref.watch(subtitleSettingsProvider);
  final overlaySessions = overlaySessionsFromPlaybackState(playbackState);
  final visibleSessions = settingsState.showPlaybackCard
      ? overlaySessions
      : const <PlaybackSession>[];
  return MainOverlayUiState(
    overlaySessions: overlaySessions,
    visibleSessions: visibleSessions,
    playingSessionCount: playbackState.playingSessionCount,
    activeSessionCount: playbackState.activeSessions.length,
    showPlaybackCard: settingsState.showPlaybackCard,
    isInitialized: playbackState.isInitialized,
  );
});

final sessionDetailUiProvider = Provider.family<SessionDetailUiState, String>((
  ref,
  sessionId,
) {
  final playbackState =
      ref.watch(playbackStateProvider).valueOrNull ??
      ref.watch(playbackSessionServiceProvider).slice.state;
  return SessionDetailUiState(
    sessionOrder: sessionOrderStateFromPlaybackState(playbackState),
    detail: sessionDetailViewStateFromPlaybackState(playbackState, sessionId),
    coverGeneration: playbackState.coverGeneration,
  );
});

List<Override> createAudioProviderOverrides({
  required AudioProvider audioProvider,
  required AudioDatabaseRepository audioDatabaseRepository,
  required NativePlaybackRepository nativePlaybackRepository,
  required PlaybackCommandRunner playbackCommandRunner,
  required LibraryService libraryService,
  required PlaybackSessionService playbackService,
  required TimerService timerService,
  required NotificationCoordinatorService notificationCoordinatorService,
  required SettingsRepository settingsRepository,
  UiOperationService? uiOperationService,
}) {
  return <Override>[
    audioProviderFacadeProvider.overrideWithValue(audioProvider),
    audioDatabaseRepositoryProvider.overrideWithValue(audioDatabaseRepository),
    nativePlaybackRepositoryProvider.overrideWithValue(
      nativePlaybackRepository,
    ),
    playbackCommandRunnerProvider.overrideWithValue(playbackCommandRunner),
    libraryServiceProvider.overrideWithValue(libraryService),
    playbackSessionServiceProvider.overrideWithValue(playbackService),
    timerServiceProvider.overrideWithValue(timerService),
    notificationCoordinatorServiceProvider.overrideWithValue(
      notificationCoordinatorService,
    ),
    settingsRepositoryProvider.overrideWithValue(settingsRepository),
    uiOperationServiceProvider.overrideWithValue(
      uiOperationService ?? UiOperationService.instance,
    ),
  ];
}
