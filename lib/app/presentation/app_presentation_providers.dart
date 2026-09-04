import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/ui/ui_operation_service.dart';
import '../../features/library/application/library_state_models.dart';
import '../../features/library/presentation/library_cover_ui_controller.dart';
import '../../features/player/application/playback_session_snapshot.dart';
import '../../features/settings/application/settings_state.dart';
import '../state/app_runtime_providers.dart';
import '../state/subtitle_settings_provider.dart';
import 'app_interaction_effects_controller.dart';
import 'audio_ui_controllers.dart';
import 'screen_view_models.dart';

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
  ref.watch(playbackStateProvider);
  final playbackState = ref.watch(playbackFacadeProvider).state;
  final timerState =
      ref.watch(timerStateProvider).value ??
      ref.watch(timerFacadeProvider).state;
  return playlistHeaderStateFromSlices(playbackState, timerState);
});

final playlistStructureUiProvider = Provider<PlaylistStructureState>((ref) {
  ref.watch(playbackStateProvider);
  final playbackState = ref.watch(playbackFacadeProvider).state;
  return playlistStructureStateFromPlaybackState(playbackState);
});

final playlistSessionCardStateProvider = Provider.autoDispose
    .family<PlaylistSessionCardState?, String>((ref, sessionId) {
      ref.watch(playbackStateProvider);
      final playbackState = ref.watch(playbackFacadeProvider).state;
      for (final session in playbackState.activeSessions) {
        if (session.id == sessionId) {
          return playlistSessionCardStateFromSession(session);
        }
      }
      return null;
    });

final coverGenerationProvider = Provider<int>((ref) {
  ref.watch(playbackStateProvider);
  return ref.watch(playbackFacadeProvider).state.coverGeneration;
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
  ref.watch(playbackStateProvider);
  final playbackState = ref.watch(playbackFacadeProvider).state;
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
  ref.watch(playbackStateProvider);
  final playbackState = ref.watch(playbackFacadeProvider).state;
  return playbackState.activeSessions.any(
    (session) => session.currentTrackPath == trackPath,
  );
});

final mainOverlayUiProvider = Provider<MainOverlayUiState>((ref) {
  ref.watch(playbackStateProvider);
  final playbackState = ref.watch(playbackFacadeProvider).state;
  final settingsState =
      ref.watch(settingsStateProvider).value ??
      ref.watch(settingsRepositoryProvider).slice.state;
  ref.watch(subtitleSettingsProvider);
  final overlaySessions = overlaySessionsFromPlaybackState(playbackState);
  final visibleSessions = settingsState.showPlaybackCard
      ? overlaySessions
      : const <PlaybackSessionSnapshot>[];
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
      ref.watch(playbackStateProvider);
      final playbackState = ref.watch(playbackFacadeProvider).state;
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
